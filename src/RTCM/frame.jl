# RTCM 3 frame layout:
#   byte 0      : preamble 0xD3
#   byte 1 hi 6 : reserved (0)
#   byte 1 lo 2 + byte 2 : length N (10 bits, 0..1023)
#   N data bytes
#   3-byte CRC-24Q over preamble+header+data
#
# This module owns a tiny streaming framer: feed it bytes from the NTRIP
# socket, get back complete payloads (msg-id + body) one at a time.

struct RtcmFrame
    msg_type::Int
    payload::Vector{UInt8}
end

mutable struct FrameBuffer
    buf::Vector{UInt8}
    crc_failed::Int     # candidate frames (valid preamble + length) whose CRC did not match
end
FrameBuffer() = FrameBuffer(UInt8[], 0)

"""
    feed!(fb, bytes) -> Vector{RtcmFrame}

Append received bytes and yield every complete, CRC-valid frame they contain.
Frames with bad CRC are silently dropped (callers increment a counter using
the difference between bytes consumed and frames returned).
"""
function feed!(fb::FrameBuffer, bytes::AbstractVector{UInt8})
    append!(fb.buf, bytes)
    frames = RtcmFrame[]
    i = 1
    n = length(fb.buf)
    while i <= n
        # Resync on 0xD3
        if fb.buf[i] != 0xD3
            i += 1
            continue
        end
        # Need at least 3 bytes to read length
        if i + 2 > n
            break
        end
        # Reserved 6 bits must be zero
        if (fb.buf[i+1] & 0xFC) != 0
            i += 1
            continue
        end
        msg_len = (UInt16(fb.buf[i+1] & 0x03) << 8) | UInt16(fb.buf[i+2])
        total_len = 3 + Int(msg_len) + 3   # header + payload + CRC
        if i + total_len - 1 > n
            break   # need more bytes
        end
        # Verify CRC-24Q over header+payload (first total_len-3 bytes)
        body = @view fb.buf[i:i+total_len-4]
        crc_recv = (UInt32(fb.buf[i+total_len-3]) << 16) |
                   (UInt32(fb.buf[i+total_len-2]) << 8)  |
                    UInt32(fb.buf[i+total_len-1])
        crc_calc = crc24q(body)
        if crc_recv != crc_calc
            # Bad CRC: skip this preamble, try the next one
            fb.crc_failed += 1
            i += 1
            continue
        end
        # Extract 12-bit message type
        if msg_len >= 2
            mt = (UInt16(fb.buf[i+3]) << 4) | (UInt16(fb.buf[i+4]) >> 4)
            payload = collect(@view fb.buf[i+3 : i+3+msg_len-1])
            push!(frames, RtcmFrame(Int(mt), payload))
        end
        i += total_len
    end
    # Drop everything we've already consumed
    if i > 1
        deleteat!(fb.buf, 1:i-1)
    end
    return frames
end
