# Minimal pure-Julia miniSEED v2 record writer.
#
# Scope: enough to feed `ringserver` / `slarchive` / obspy without going
# through Python. The encoding is INT32 (SEED encoding format 3) — every
# sample becomes 4 big-endian bytes inside a 512-byte record. STEIM2
# compression would reduce file size by ~4× but is intricate enough that
# it's deferred; users who want it can post-process with `msrepack` or
# obspy's `Trace.write(..., encoding='STEIM2')`.
#
# Reference: SEED Manual v2.4, Appendix A (data record format) and
# Appendix C (blockette 1000).
#
# Output naming follows the SDS convention (without the directory tree):
#     <NET>.<STA>.<LOC>.<CHA>.D.<YYYY>.<DOY>
# All files for a session live in `miniseed_mseed_dir`. The writer rotates
# automatically across UTC day boundaries.

const MSEED_RECORD_LEN     = 512
const MSEED_DATA_OFFSET    = 64                                   # 2-power aligned
const MSEED_SAMPLES_PER_REC = (MSEED_RECORD_LEN - MSEED_DATA_OFFSET) ÷ 4  # 112

# Per-channel ring buffer + file handle. The writer flushes whenever EITHER
# - the buffer reaches `samples_per_record` samples (a "full" 512-byte
#   record, ~112 samples), OR
# - `flush_interval_sec` seconds have elapsed since the first buffered
#   sample, so consumers see data even at low rates (default 10 s flush
#   means ~10 samples per record at 1 Hz). Without the time-based flush
#   files stay 0 bytes for ~2 min after stream start.
mutable struct MiniSEEDWriter
    base_dir::String
    network::String
    station::String
    location::String
    channel::String
    sample_rate_hz::Float64
    record_len::Int
    samples_per_record::Int
    flush_interval_sec::Float64
    sequence::Int
    buffer::Vector{Int32}
    buffer_starttime::Union{DateTime,Nothing}
    current_doy::Int
    current_year::Int
    io::Union{IOStream,Nothing}
    # Optional tee: called with (record_bytes, t_first_sample, t_last_sample)
    # after every record is written to the file. The DataLink push to
    # ringserver hangs off this (src/datalink.jl). Must not throw.
    on_record::Any
end

function MiniSEEDWriter(base_dir::AbstractString,
                         network::AbstractString,
                         station::AbstractString,
                         location::AbstractString,
                         channel::AbstractString,
                         sample_rate_hz::Float64;
                         record_len::Int = MSEED_RECORD_LEN,
                         flush_interval_sec::Float64 = 10.0,
                         on_record = nothing)
    spr = (record_len - MSEED_DATA_OFFSET) ÷ 4
    MiniSEEDWriter(String(base_dir),
                    String(network), String(station),
                    String(location), String(channel),
                    sample_rate_hz, record_len, spr,
                    flush_interval_sec,
                    1, Int32[], nothing, 0, 0, nothing, on_record)
end

function _mseed_path(w::MiniSEEDWriter, year::Int, doy::Int)
    fn = @sprintf("%s.%s.%s.%s.D.%04d.%03d",
                  w.network, w.station, w.location, w.channel, year, doy)
    return joinpath(w.base_dir, fn)
end

function _ensure_open!(w::MiniSEEDWriter, ts::DateTime)
    y = Dates.year(ts); d = Dates.dayofyear(ts)
    if w.io === nothing || y != w.current_year || d != w.current_doy
        # Day rollover (or first open) — flush whatever's pending under the
        # previous date, then re-open under the new one.
        if !isempty(w.buffer)
            _flush_record!(w)
        end
        if w.io !== nothing
            try; close(w.io); catch; end
            w.io = nothing
        end
        mkpath(w.base_dir)
        path = _mseed_path(w, y, d)
        w.io = open(path, "a")
        w.current_year = y; w.current_doy = d
    end
    return w.io
end

"""
Append one sample (Int32 counts) at the given UTC timestamp. The writer
buffers up to `samples_per_record` samples and flushes either when the
buffer is full OR when `flush_interval_sec` has elapsed since the first
buffered sample, whichever comes first. Day rollover (UTC midnight)
automatically rotates the file.
"""
function append_sample!(w::MiniSEEDWriter, ts::DateTime, count::Int32)
    # Open / rotate file as needed BEFORE buffering, so the first sample of
    # a new day lands in the new file.
    _ensure_open!(w, ts)
    # Time tear: a miniSEED record declares one start time and a fixed
    # sample rate, so every buffered sample is implicitly at
    # start + i/rate. A missing epoch (caster drop, outlier-blanked NaN,
    # reconnect) must therefore close the current record and open a new one
    # at the true time — otherwise every later sample in the record is
    # time-shifted by k/rate and consumers see compressed records followed
    # by a phantom gap at the boundary. Tolerance is half a sample.
    if w.buffer_starttime !== nothing && !isempty(w.buffer)
        expect_ms = Dates.value(w.buffer_starttime) + length(w.buffer) * 1000 / w.sample_rate_hz
        if abs(Dates.value(ts) - expect_ms) > 500 / w.sample_rate_hz
            _flush_record!(w)
        end
    end
    if w.buffer_starttime === nothing
        w.buffer_starttime = ts
    end
    push!(w.buffer, count)
    # Flush if the buffer is full OR enough wall-clock time has elapsed.
    if length(w.buffer) >= w.samples_per_record
        _flush_record!(w)
    elseif w.buffer_starttime !== nothing
        age_ms = Dates.value(ts - w.buffer_starttime)
        if age_ms >= w.flush_interval_sec * 1000
            _flush_record!(w)
        end
    end
    return
end

"""
Flush any pending samples (producing a short last record) and close the
file. Safe to call multiple times.
"""
function close_writer!(w::MiniSEEDWriter)
    if !isempty(w.buffer)
        try; _flush_record!(w); catch err; @debug "mseed flush failed" err; end
    end
    if w.io !== nothing
        try; close(w.io); catch; end
        w.io = nothing
    end
    return
end

function _flush_record!(w::MiniSEEDWriter)
    isempty(w.buffer) && return
    w.io === nothing && error("MiniSEEDWriter has no open file")
    record = _build_record(w, w.buffer, w.buffer_starttime)
    write(w.io, record)
    Base.flush(w.io)
    if w.on_record !== nothing
        t0 = w.buffer_starttime
        t1 = t0 + Dates.Millisecond(round(Int64, (length(w.buffer) - 1) * 1000 / w.sample_rate_hz))
        try
            w.on_record(record, t0, t1)
        catch err
            @debug "mseed on_record hook failed" err
        end
    end
    empty!(w.buffer)
    w.buffer_starttime = nothing
    w.sequence = (w.sequence + 1) % 1_000_000
    return
end

# ---------- Header packing ----------

# Big-endian write helpers. Julia 1.x has ntoh/hton but writing to a Vector
# byte-by-byte is the clearest way to match the SEED layout.
@inline _be16!(buf, off, v::UInt16) = (buf[off+1] = UInt8(v >> 8); buf[off+2] = UInt8(v & 0xff))
@inline _be32!(buf, off, v::UInt32) = (
    buf[off+1] = UInt8((v >> 24) & 0xff); buf[off+2] = UInt8((v >> 16) & 0xff);
    buf[off+3] = UInt8((v >> 8)  & 0xff); buf[off+4] = UInt8(v & 0xff))

function _btime_bytes(t::DateTime)
    y    = Dates.year(t)
    doy  = Dates.dayofyear(t)
    h    = Dates.hour(t); m = Dates.minute(t); s = Dates.second(t)
    ms   = Dates.millisecond(t)
    # SEED BTIME records fractional seconds in 0.0001-s units (0..9999).
    tenth_ms = clamp(ms * 10, 0, 9999)
    b = Vector{UInt8}(undef, 10)
    b[1] = UInt8((y >> 8) & 0xff);   b[2] = UInt8(y & 0xff)
    b[3] = UInt8((doy >> 8) & 0xff); b[4] = UInt8(doy & 0xff)
    b[5] = UInt8(h); b[6] = UInt8(m); b[7] = UInt8(s); b[8] = 0  # reserved
    b[9] = UInt8((tenth_ms >> 8) & 0xff); b[10] = UInt8(tenth_ms & 0xff)
    return b
end

# SEED sample-rate encoding: when rate ≥ 1 Hz, store (factor=rate, mult=1).
# Lower rates store (factor=-period_s, mult=1) so the decoded value is
# `factor * mult` for rates ≥ 1 and `-1/(factor*mult)` for sub-Hz rates.
function _encode_rate(rate_hz::Float64)
    if rate_hz >= 1.0
        return (Int16(round(rate_hz)), Int16(1))
    else
        return (Int16(-round(1.0/rate_hz)), Int16(1))
    end
end

function _log2_record_len(rl::Int)
    n = 0; v = rl
    while v > 1
        v >>= 1; n += 1
    end
    return UInt8(n)
end

function _build_record(w::MiniSEEDWriter, samples::Vector{Int32}, t::DateTime)
    buf = zeros(UInt8, w.record_len)

    # ---- Fixed Header (48 bytes) ----
    # Sequence number: 6 ASCII digits, zero-padded.
    seq_str = lpad(string(w.sequence), 6, '0')
    copyto!(buf, 1, codeunits(seq_str), 1, 6)
    buf[7] = UInt8('D')        # data quality indicator
    buf[8] = UInt8(' ')        # reserved
    # Station (5) / Location (2) / Channel (3) / Network (2). ASCII, space-padded.
    _copy_fixed!(buf,  9, w.station,  5)
    _copy_fixed!(buf, 14, w.location, 2)
    _copy_fixed!(buf, 16, w.channel,  3)
    _copy_fixed!(buf, 19, w.network,  2)
    # Start time (BTIME, 10 bytes, big-endian)
    bt = _btime_bytes(t)
    copyto!(buf, 21, bt, 1, 10)
    # Number of samples (UInt16 BE)
    _be16!(buf, 30, UInt16(length(samples)))
    # Sample rate factor + multiplier (Int16 BE; reinterpret signed)
    f, m = _encode_rate(w.sample_rate_hz)
    _be16!(buf, 32, reinterpret(UInt16, f))
    _be16!(buf, 34, reinterpret(UInt16, m))
    buf[37] = 0                # activity flags
    buf[38] = 0                # IO flags
    buf[39] = 0                # data quality flags
    buf[40] = 1                # number of blockettes that follow
    _be32!(buf, 40, UInt32(0)) # time correction = 0 (offsets 41..44)
    _be16!(buf, 44, UInt16(MSEED_DATA_OFFSET))  # data-start offset
    _be16!(buf, 46, UInt16(48))                 # first blockette offset

    # ---- Blockette 1000 (8 bytes, offset 48) ----
    _be16!(buf, 48, UInt16(1000))   # blockette type
    _be16!(buf, 50, UInt16(0))      # next blockette offset (none)
    buf[53] = UInt8(3)              # encoding: 3 = INT32
    buf[54] = UInt8(1)              # word order: 1 = big-endian
    buf[55] = _log2_record_len(w.record_len)
    buf[56] = 0                     # reserved

    # ---- Data (offset 64..) ----
    for (i, s) in enumerate(samples)
        off = MSEED_DATA_OFFSET + (i-1)*4
        _be32!(buf, off, reinterpret(UInt32, s))
    end
    return buf
end

# Truncate or space-pad `s` to exactly `n` bytes and write into `buf` at
# `off` (1-based, just like copyto!).
function _copy_fixed!(buf, off::Int, s::AbstractString, n::Int)
    bytes = codeunits(s)
    k = min(length(bytes), n)
    copyto!(buf, off, bytes, 1, k)
    for j in (k+1):n
        buf[off + j - 1] = UInt8(' ')
    end
    return
end
