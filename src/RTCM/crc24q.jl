# CRC-24Q (Qualcomm) — the RTCM 3 frame CRC.
# Polynomial: 0x1864CFB, init=0, xor-out=0, not reflected.

const _CRC24Q_TABLE = let
    poly = UInt32(0x1864CFB)
    tbl = zeros(UInt32, 256)
    for i in 0:255
        c = UInt32(i) << 16
        for _ in 1:8
            c <<= 1
            if (c & 0x01000000) != 0
                c ⊻= poly
            end
        end
        tbl[i+1] = c & UInt32(0xFFFFFF)
    end
    tbl
end

"""Compute CRC-24Q over `bytes`; returns the 24-bit value as `UInt32`."""
function crc24q(bytes::AbstractVector{UInt8})
    c = UInt32(0)
    @inbounds for b in bytes
        idx = ((c >> 16) & 0xFF) ⊻ UInt32(b)
        c = ((c << 8) & UInt32(0xFFFFFF)) ⊻ _CRC24Q_TABLE[idx + 1]
    end
    return c
end
