# NTRIP v2 / v1 client.
#
# Casters speak HTTP-like protocol on port 2101 (sometimes 80, 443).
# A GET against `/` returns the source-table.  A GET against `/MOUNTPOINT`
# with `Ntrip-Version: Ntrip/2.0` and HTTP Basic auth, when accepted, switches
# the response body to a continuous RTCM stream.

const _USER_AGENT = "NTRIP GaiaSeis/" * _SOFTWARE_VERSION
# Note: many casters (BKG-derived in particular — products.igs-ip.net,
# some university casters) filter on User-Agent and return HTTP 403 if the
# string doesn't start with the literal "NTRIP". The NTRIP v2 spec
# (RFC document, §3) actually recommends this prefix. Earlier the agent
# was "NtripClient.jl/0.1" which accidentally satisfied the filter
# because it contains "Ntrip"; after the GaiaSeis rename we lost that
# substring and every BKG caster started replying 403.

"""
    fetch_source_table(profile) -> String

Fetch the caster's source-table (mount list). Returns the raw body — caller
can parse the STR / CAS / NET sections.
"""
function fetch_source_table(profile::NtripProfile; timeout=10)
    scheme = profile.use_tls ? "https" : "http"
    url = "$(scheme)://$(profile.caster):$(profile.port)/"
    headers = ["User-Agent" => _USER_AGENT,
               "Ntrip-Version" => "Ntrip/2.0",
               "Accept" => "*/*"]
    resp = HTTP.request("GET", url, headers; readtimeout = timeout, retry = false)
    return String(resp.body)
end

"""
    parse_source_table(body) -> Vector{NamedTuple}

Extract just the STR (stream) rows from a source-table body.
"""
function parse_source_table(body::AbstractString)
    rows = NamedTuple[]
    for line in eachline(IOBuffer(body))
        startswith(line, "STR;") || continue
        parts = split(line, ';')
        length(parts) >= 12 || continue
        push!(rows, (
            mountpoint = parts[2],
            identifier = parts[3],
            format     = parts[4],
            format_details = parts[5],
            country    = parts[9],
            lat        = tryparse(Float64, parts[10]),
            lon        = tryparse(Float64, parts[11]),
        ))
    end
    return rows
end

# Build an NMEA $GPGGA sentence from the profile's lat/lon/height — VRS mounts
# expect the rover to push its approximate position upstream.
function _gga_sentence(prof::NtripProfile)
    t = Dates.now(UTC)
    utc = Dates.format(t, dateformat"HHMMSS.00")
    lat = abs(prof.gga_lat_deg)
    lat_deg = floor(lat); lat_min = (lat - lat_deg)*60
    lon = abs(prof.gga_lon_deg)
    lon_deg = floor(lon); lon_min = (lon - lon_deg)*60
    ns = prof.gga_lat_deg >= 0 ? 'N' : 'S'
    ew = prof.gga_lon_deg >= 0 ? 'E' : 'W'
    body = @sprintf("GPGGA,%s,%02d%07.4f,%c,%03d%07.4f,%c,1,12,1.0,%.1f,M,0.0,M,,",
                    utc, Int(lat_deg), lat_min, ns,
                    Int(lon_deg), lon_min, ew, prof.gga_height_m)
    # NMEA checksum: XOR of all bytes between $ and *
    csum = UInt8(0)
    for c in body; csum ⊻= UInt8(c); end
    return @sprintf("\$%s*%02X\r\n", body, csum)
end

"""
    open_stream(profile) -> HTTP.Stream

Open a streaming HTTP connection to the chosen mount point. Caller reads raw
bytes from the returned stream with `readbytes!`.
"""
function open_stream(profile::NtripProfile)
    isempty(profile.caster)    && error("NTRIP profile has no caster set")
    isempty(profile.mountpoint) && error("NTRIP profile has no mountpoint set")
    scheme = profile.use_tls ? "https" : "http"
    url = "$(scheme)://$(profile.caster):$(profile.port)/$(profile.mountpoint)"
    auth = base64encode(string(profile.user, ':', profile.password))
    headers = ["User-Agent"    => _USER_AGENT,
               "Ntrip-Version" => "Ntrip/2.0",
               "Authorization" => "Basic $auth",
               "Accept"        => "*/*",
               "Connection"    => "close"]
    # `open` returns the underlying HTTP.Stream so we can read incrementally.
    return HTTP.open("GET", url, headers; readtimeout = 0, status_exception = true)
end

"""
    run_stream!(profile, on_bytes; stop_flag = Threads.Atomic{Bool}(false))

Blocking loop: open the mount-point, optionally push a GGA on connect, and
deliver every received byte chunk to `on_bytes(::Vector{UInt8})` until either
the server hangs up or `stop_flag` is set.
"""
function run_stream!(profile::NtripProfile, on_bytes::Function;
                     stop_flag::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false),
                     on_status::Union{Function,Nothing} = nothing)
    # NTRIP v2 over raw TCP. HTTP.jl's high-level streaming choked on the
    # BKG-caster's chunked transfer (it tags Accept-Encoding: gzip and then
    # the chunked decoder fails), so we speak the protocol directly.
    auth = base64encode(string(profile.user, ':', profile.password))
    sock = Sockets.connect(profile.caster, profile.port)
    on_status === nothing || on_status(:connected)

    # ---- Stall watchdog ----
    # A silently half-open TCP connection is the normal failure mode here:
    # the caster (or a NAT box in between) stops forwarding without sending
    # FIN, so `readavailable`/`readbytes!` block forever and `eof(sock)`
    # never returns true. Nothing below would ever notice. The watchdog
    # closes the socket out from under the blocked read, which turns the
    # hang into an exception the caller's supervisor can reconnect from.
    last_activity = Ref(time())
    stalled       = Ref(false)
    watch_done    = Ref(false)
    stall_to      = profile.stall_timeout_sec
    if stall_to > 0
        @async begin
            while !watch_done[] && !stop_flag[]
                sleep(1.0)
                watch_done[] && break
                quiet = time() - last_activity[]
                if quiet > stall_to
                    stalled[] = true
                    @warn("NTRIP stream stalled — dropping socket to force a reconnect",
                          caster = profile.caster,
                          mountpoint = profile.mountpoint,
                          quiet_s = round(quiet; digits = 1))
                    try; close(sock); catch; end
                    break
                end
            end
        end
    end
    # Every byte that arrives — header included — counts as liveness.
    track = function(chunk)
        last_activity[] = time()
        on_bytes(chunk)
    end
    stall_err() = error("NTRIP stream stalled: no data for " *
                        string(round(stall_to; digits = 1)) * " s from " *
                        profile.caster * "/" * profile.mountpoint)
    try
        # NTRIP request
        request = "GET /$(profile.mountpoint) HTTP/1.1\r\n" *
                  "Host: $(profile.caster):$(profile.port)\r\n" *
                  "Ntrip-Version: Ntrip/2.0\r\n" *
                  "User-Agent: $(_USER_AGENT)\r\n" *
                  "Authorization: Basic $auth\r\n" *
                  "Accept: */*\r\n" *
                  "Connection: close\r\n\r\n"
        write(sock, request)
        flush(sock)

        # Read and discard the HTTP response head ("HTTP/1.1 200 OK\r\n...\r\n\r\n")
        header_bytes = UInt8[]
        while !eof(sock)
            byte = read(sock, UInt8)
            last_activity[] = time()
            push!(header_bytes, byte)
            n = length(header_bytes)
            if n >= 4 && header_bytes[n-3] == UInt8('\r') &&
               header_bytes[n-2] == UInt8('\n') &&
               header_bytes[n-1] == UInt8('\r') &&
               header_bytes[n]   == UInt8('\n')
                break
            end
            if n > 16_384      # safety
                error("NTRIP response header > 16 KB without terminator")
            end
        end
        header = String(header_bytes)
        if !occursin("200 OK", header) && !occursin("ICY 200 OK", header)
            error("NTRIP caster refused stream: \n" * header)
        end
        chunked = occursin(r"transfer-encoding:\s*chunked"i, header)

        # GGA upload for VRS mounts (after request, before reading body)
        if profile.send_gga
            try
                write(sock, _gga_sentence(profile))
                flush(sock)
            catch err
                @warn "GGA upload failed (continuing)" err
            end
        end

        # Read the body. Some casters emit chunked HTTP, others (NTRIP 1.x style)
        # send raw bytes after the header.
        try
            while !stop_flag[]
                eof(sock) && break
                if chunked
                    _drain_chunk!(sock, track, stop_flag) || break
                else
                    chunk = readavailable(sock)
                    isempty(chunk) && break
                    track(chunk)
                end
            end
        catch err
            # The watchdog's `close(sock)` surfaces here as an IOError; report
            # what actually happened instead of the closed-socket symptom.
            stalled[] && stall_err()
            rethrow()
        end
        # Watchdog fired between iterations — the loop exited via `eof`.
        stalled[] && stall_err()
    finally
        watch_done[] = true
        close(sock)
        on_status === nothing || on_status(:disconnected)
    end
end

# Read one HTTP chunked-transfer chunk, push it through on_bytes, return true if
# more chunks may follow.
function _drain_chunk!(sock, on_bytes::Function, stop_flag)
    # Chunk size line: hex digits, then optional ;extension, then CRLF
    sizeline = readline(sock; keep = false)
    s = strip(split(sizeline, ';')[1])
    isempty(s) && return true       # tolerate stray blank line
    n = tryparse(Int, s, base = 16)
    n === nothing && error("Bad chunk size: $(sizeline)")
    n == 0 && return false          # end-of-stream marker
    remaining = n
    buf = Vector{UInt8}(undef, 4096)
    while remaining > 0
        stop_flag[] && return false
        want = min(length(buf), remaining)
        nread = readbytes!(sock, buf, want)
        nread == 0 && return false
        on_bytes(view(buf, 1:nread))
        remaining -= nread
    end
    # Trailing CRLF after the chunk
    _ = readline(sock; keep = false)
    return true
end
