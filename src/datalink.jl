# Minimal DataLink client: pushes every flushed miniSEED record to a
# `ringserver`, which then serves it to SeedLink clients (SeisComP, ObsPy,
# slinktool, slarchive) and keeps a disk ring for replay after reconnects.
#
# Wire protocol (libdali / ringserver dlclient.c):
#   packet   = 'D' 'L' <hdrlen:UInt8> <header:hdrlen bytes> [<data>]
#   handshake: client "ID <program>:<user>:<pid>:<arch>"
#              server "ID DataLink <ver> :: DLPROTO:1.0 PACKETSIZE:512 WRITE"
#   submit   : "WRITE <streamid> <hpstart> <hpend> <flags> <size>" + record
#              streamid "NN_SSSSS_LL_CCC/MSEED", times in microseconds since
#              the POSIX epoch, flags 'N' (no ack) or 'A' (ack, server replies
#              "OK ..." or "ERROR ...").
#
# ringserver grants write permission to localhost by default; any other
# address needs a `WriteIP` line in its config (see tools/ringserver/).
#
# Failure policy: a push never blocks or throws into the bridge. On any
# socket error the connection is dropped and the next record triggers a
# reconnect, rate-limited to one attempt per `reconnect_s`. Records that
# arrive while disconnected are lost for the ring (they are still in the
# day files); the ring is a live feed, the files are the archive.

const _DL_RECONNECT_S = 5.0
const _DL_IO_TIMEOUT_S = 3.0

mutable struct DataLinkClient
    host::String
    port::Int
    sock::Union{TCPSocket,Nothing}
    last_attempt::Float64
    records_sent::Int
    records_dropped::Int
    connects::Int
    last_error::String
    lock::ReentrantLock
end

DataLinkClient(host::AbstractString, port::Integer) =
    DataLinkClient(String(host), Int(port), nothing, -Inf, 0, 0, 0, "", ReentrantLock())

isconnected(c::DataLinkClient) = c.sock !== nothing && isopen(c.sock)

# ---- framing ---------------------------------------------------------------

function _dl_packet(header::AbstractString, data::Union{Nothing,AbstractVector{UInt8}} = nothing)
    h = codeunits(header)
    length(h) <= 255 || error("DataLink header too long ($(length(h)) bytes)")
    n = 3 + length(h) + (data === nothing ? 0 : length(data))
    buf = Vector{UInt8}(undef, n)
    buf[1] = UInt8('D'); buf[2] = UInt8('L'); buf[3] = UInt8(length(h))
    copyto!(buf, 4, h, 1, length(h))
    data === nothing || copyto!(buf, 4 + length(h), data, 1, length(data))
    return buf
end

# Read one reply packet; returns (header, data). Used only for the ID
# handshake and for acknowledged writes, both with a timeout.
function _dl_read_packet(sock::TCPSocket; timeout_s::Float64 = _DL_IO_TIMEOUT_S)
    t = @async begin
        pre = read(sock, 3)
        (pre[1] == UInt8('D') && pre[2] == UInt8('L')) || error("not a DataLink packet")
        hdr = String(read(sock, Int(pre[3])))
        # "OK 123 45" / "ERROR 0 45" / "ID ..." — data follows only when the
        # header's last token is a byte count after a value.
        parts = split(hdr)
        data = UInt8[]
        if length(parts) >= 3 && (parts[1] == "OK" || parts[1] == "ERROR")
            n = tryparse(Int, parts[end]); n === nothing || (data = read(sock, n))
        end
        (hdr, data)
    end
    deadline = time() + timeout_s
    while !istaskdone(t) && time() < deadline
        sleep(0.01)
    end
    istaskdone(t) || error("DataLink reply timed out after $(timeout_s) s")
    return fetch(t)
end

# ---- connection ------------------------------------------------------------

function _dl_connect!(c::DataLinkClient)
    now = time()
    now - c.last_attempt < _DL_RECONNECT_S && return false
    c.last_attempt = now
    try
        sock = Sockets.connect(c.host, c.port)
        arch = Sys.iswindows() ? "Windows" : Sys.isapple() ? "Darwin" : "Linux"
        user = get(ENV, "USER", get(ENV, "USERNAME", "gaiaseis"))
        write(sock, _dl_packet("ID GaiaSeis:$(user):$(getpid()):$(arch)"))
        hdr, _ = _dl_read_packet(sock)
        startswith(hdr, "ID ") || error("unexpected handshake reply: $hdr")
        occursin("WRITE", hdr) || error("server grants no write permission (add WriteIP for this host): $hdr")
        c.sock = sock
        c.connects += 1
        c.last_error = ""
        @info "DataLink connected" host=c.host port=c.port server=hdr
        return true
    catch err
        c.last_error = sprint(showerror, err)
        c.sock === nothing || (try; close(c.sock); catch; end; c.sock = nothing)
        @warn "DataLink connect failed — will retry" host=c.host port=c.port err=c.last_error maxlog=20
        return false
    end
end

function close_datalink!(c::DataLinkClient)
    lock(c.lock) do
        s = c.sock
        c.sock = nothing
        s === nothing && return
        # Non-blocking release. `close(::TCPSocket)` waits for libuv to confirm
        # the close; from the atexit hook (`_flush_all_live_sessions!`) that
        # confirmation never arrives and the GUI hung on SIGTERM at 34 % CPU
        # until SIGKILLed (2026-10-18). `uvfinalize` queues the close and
        # returns; the handle is freed when the loop next runs, or at exit.
        try; Base.uvfinalize(s); catch; end
    end
    return
end

# ---- submit ----------------------------------------------------------------

_hptime(t::DateTime) = (Dates.value(t) - Dates.value(DateTime(1970))) * 1000  # ms → µs

"""
    push_record!(c, record, net, sta, loc, cha, t_start, t_end)

Send one miniSEED record. `t_start`/`t_end` are the first and last sample
times (UTC). Never throws; returns true if the record went out.
"""
function push_record!(c::DataLinkClient, record::AbstractVector{UInt8},
                      net::AbstractString, sta::AbstractString,
                      loc::AbstractString, cha::AbstractString,
                      t_start::DateTime, t_end::DateTime)
    lock(c.lock) do
        if !isconnected(c)
            _dl_connect!(c) || (c.records_dropped += 1; return false)
        end
        sid = "$(net)_$(sta)_$(loc)_$(cha)/MSEED"
        hdr = "WRITE $sid $(_hptime(t_start)) $(_hptime(t_end)) N $(length(record))"
        try
            write(c.sock, _dl_packet(hdr, record))
            c.records_sent += 1
            return true
        catch err
            c.last_error = sprint(showerror, err)
            c.records_dropped += 1
            try; close(c.sock); catch; end
            c.sock = nothing
            @warn "DataLink write failed — connection dropped" err=c.last_error maxlog=20
            return false
        end
    end
end
