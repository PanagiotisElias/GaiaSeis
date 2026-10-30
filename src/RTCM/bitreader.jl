# MSB-first bit reader for RTCM 3 payloads.

mutable struct BitReader
    data::Vector{UInt8}
    pos::Int  # bit index (1-based), next bit to consume
end

BitReader(data::AbstractVector{UInt8}) = BitReader(Vector{UInt8}(data), 1)

bits_remaining(br::BitReader) = length(br.data)*8 - br.pos + 1

"""Read `n` unsigned bits (n ≤ 64), MSB-first, and advance."""
function readu(br::BitReader, n::Integer)
    @assert n >= 0 && n <= 64
    v = UInt64(0)
    for _ in 1:n
        byte_idx = ((br.pos - 1) >> 3) + 1
        bit_idx  = 7 - ((br.pos - 1) & 0x7)   # MSB-first
        b = (br.data[byte_idx] >> bit_idx) & 0x1
        v = (v << 1) | UInt64(b)
        br.pos += 1
    end
    return v
end

"""Read `n` bits as signed two's-complement."""
function reads(br::BitReader, n::Integer)
    u = readu(br, n)
    n == 0 && return Int64(0)
    sign_bit = UInt64(1) << (n-1)
    if (u & sign_bit) != 0
        # extend sign by reinterpreting the sign-extended pattern as Int64
        return reinterpret(Int64, u | (~UInt64(0) << n))
    else
        return Int64(u)
    end
end

readbool(br::BitReader) = readu(br, 1) != 0

"""Skip n bits forward."""
function skipbits!(br::BitReader, n::Integer)
    br.pos += n
    return br
end
