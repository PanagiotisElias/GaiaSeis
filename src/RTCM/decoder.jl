# Stateful RTCM3 decoder that turns a byte stream into typed events.
# Owns: a FrameBuffer, the latest station coordinates, and a per-system
# scratch dict for accumulating multi-MSM7 epochs (some casters split GPS+GLO
# into two messages with the same epoch timestamp).

mutable struct RtcmDecoder
    fb::FrameBuffer
    station::Union{StationCoord,Nothing}
    descriptor::Union{StationDescriptor,Nothing}
    # Epochs in flight, keyed by system char; flushed when "more_to_follow"=0
    pending::Dict{Char,MsmEpoch}
    # Most recent ephemeris per (sys, prn). Bridge converts on demand.
    eph::Dict{Tuple{Char,Int},EphemerisRecord}
    # Most recent SSR orbit / clock correction per (sys, prn). Refreshed each
    # time the products caster pushes a new 1057/1058/1063/1064/1240/1241.
    ssr_orb::Dict{Tuple{Char,Int},SsrOrbitCorrection}
    ssr_clk::Dict{Tuple{Char,Int},SsrClockCorrection}
    msg_counts::Dict{Int,Int}
    frames_crc_failed::Int
    bytes_seen::Int
    # Per-system diagnostic counters so the GUI debug panel can show why a
    # constellation might not be producing observation codes.
    msm_frames::Dict{Char,Int}        # frames received per system
    msm_epochs::Dict{Char,Int}        # EvEpoch events emitted per system
    msm_last_satmask::Dict{Char,UInt64}
    msm_last_sigmask::Dict{Char,UInt32}
    msm_last_mmf::Dict{Char,Bool}
    # One framer per NTRIP stream. The obs, SSR and ephemeris sockets are
    # read by separate tasks that all decode into this one object; with a
    # single FrameBuffer an obs frame split across two reads was corrupted
    # by the SSR/eph bytes appended in between, failed its CRC and was
    # dropped silently — ~15 % of epochs lost one constellation's frame
    # (2026-09-10). `fb` stays the :obs buffer.
    fbs::Dict{Symbol,FrameBuffer}
    ssr_version::Int      # bumped on every SSR orbit/clock message applied
    # Message counts per NTRIP stream (:obs / :ssr / :eph); `msg_counts` is the sum.
    msg_counts_by::Dict{Symbol,Dict{Int,Int}}
end
RtcmDecoder() = RtcmDecoder(FrameBuffer(), nothing, nothing,
                            Dict{Char,MsmEpoch}(),
                            Dict{Tuple{Char,Int},EphemerisRecord}(),
                            Dict{Tuple{Char,Int},SsrOrbitCorrection}(),
                            Dict{Tuple{Char,Int},SsrClockCorrection}(),
                            Dict{Int,Int}(), 0, 0,
                            Dict{Char,Int}(), Dict{Char,Int}(),
                            Dict{Char,UInt64}(), Dict{Char,UInt32}(),
                            Dict{Char,Bool}(), Dict{Symbol,FrameBuffer}(), 0,
                            Dict{Symbol,Dict{Int,Int}}())

# A small sum-type-ish union the bridge dispatches on.
abstract type RtcmEvent end
struct EvStation     <: RtcmEvent; coord::StationCoord; end
struct EvDescriptor  <: RtcmEvent; desc::StationDescriptor; end
struct EvEpoch       <: RtcmEvent; sys::Char; epoch::MsmEpoch; end
struct EvEphemeris   <: RtcmEvent; record::EphemerisRecord; end
struct EvSsrOrbit    <: RtcmEvent; corrections::Vector{SsrOrbitCorrection}; end
struct EvSsrClock    <: RtcmEvent; corrections::Vector{SsrClockCorrection}; end
struct EvOther       <: RtcmEvent; msg_type::Int; end

"""
    feed_bytes!(dec, bytes) -> Vector{RtcmEvent}

Push raw NTRIP bytes through the framer + per-message decoders, returning
high-level events the bridge can react to.
"""
function feed_bytes!(dec::RtcmDecoder, bytes::AbstractVector{UInt8}; stream::Symbol = :obs)
    dec.bytes_seen += length(bytes)
    events = RtcmEvent[]
    fb = stream === :obs ? dec.fb : get!(FrameBuffer, dec.fbs, stream)
    frames = feed!(fb, bytes)
    dec.frames_crc_failed = dec.fb.crc_failed + sum(b -> b.crc_failed, values(dec.fbs); init = 0)
    for fr in frames
        mt = fr.msg_type
        dec.msg_counts[mt] = get(dec.msg_counts, mt, 0) + 1
        let d = get!(dec.msg_counts_by, stream, Dict{Int,Int}())
            d[mt] = get(d, mt, 0) + 1
        end
        try
            if mt == 1005 || mt == 1006
                coord = decode_1005_1006(fr.payload, mt)
                dec.station = coord
                push!(events, EvStation(coord))
            elseif mt == 1033
                desc = decode_1033(fr.payload)
                dec.descriptor = desc
                push!(events, EvDescriptor(desc))
            elseif mt == 1007 || mt == 1008
                desc = decode_1008(fr.payload)
                # Only overwrite if we don't have a richer 1033 record already
                dec.descriptor === nothing && (dec.descriptor = desc)
                push!(events, EvDescriptor(desc))
            elseif _is_msm_obs(mt)
                # Generic MSM4/5/6/7 observation message — covers high-rate
                # streams that compress to MSM5 (e.g. NOA10Z) as well as the
                # original 1-Hz MSM7 mounts (PAT0, EUREF, …).
                epoch = decode_msm(fr.payload, mt)
                # Per-system diagnostic counters
                dec.msm_frames[epoch.sys]      = get(dec.msm_frames, epoch.sys, 0) + 1
                dec.msm_last_satmask[epoch.sys] = epoch.sat_mask_raw
                dec.msm_last_sigmask[epoch.sys] = epoch.sig_mask_raw
                dec.msm_last_mmf[epoch.sys]    = epoch.more_to_follow

                # If the buffered epoch is for a *different* timestamp, the
                # caster never bothered to flip MMF=0 (some firmware does
                # this — observed on the Patras CORS for GPS/GLO). Treat the
                # previous one as implicitly closed and emit it first.
                if haskey(dec.pending, epoch.sys)
                    prev = dec.pending[epoch.sys]
                    if prev.epoch_ms != epoch.epoch_ms
                        delete!(dec.pending, epoch.sys)
                        dec.msm_epochs[epoch.sys] = get(dec.msm_epochs, epoch.sys, 0) + 1
                        push!(events, EvEpoch(epoch.sys, prev))
                    end
                end
                # Aggregate cells across multi-message bit, then emit on last
                if haskey(dec.pending, epoch.sys)
                    append!(dec.pending[epoch.sys].obs, epoch.obs)
                else
                    dec.pending[epoch.sys] = epoch
                end
                if !epoch.more_to_follow
                    full = dec.pending[epoch.sys]
                    delete!(dec.pending, epoch.sys)
                    dec.msm_epochs[epoch.sys] = get(dec.msm_epochs, epoch.sys, 0) + 1
                    push!(events, EvEpoch(epoch.sys, full))
                end
            elseif mt == 1019
                rec = decode_1019(fr.payload)
                dec.eph[(rec.sys, rec.prn)] = rec
                push!(events, EvEphemeris(rec))
            elseif mt == 1020
                rec = decode_1020(fr.payload)
                dec.eph[(rec.sys, rec.prn)] = rec
                push!(events, EvEphemeris(rec))
            elseif mt == 1045
                rec = decode_1045(fr.payload)
                dec.eph[(rec.sys, rec.prn)] = rec
                push!(events, EvEphemeris(rec))
            elseif mt == 1042
                rec = decode_1042(fr.payload)
                # Unhealthy satellites are not stored (the bridge would
                # otherwise happily propagate them).
                if rec.valid
                    dec.eph[(rec.sys, rec.prn)] = rec
                    push!(events, EvEphemeris(rec))
                end
            elseif mt == 1057 || mt == 1063 || mt == 1240 || mt == 1258
                corrs = decode_ssr_orbit(fr.payload, mt)
                for c in corrs; dec.ssr_orb[(c.sys, c.prn)] = c; end
                dec.ssr_version += 1
                push!(events, EvSsrOrbit(corrs))
            elseif mt == 1058 || mt == 1064 || mt == 1241 || mt == 1259
                corrs = decode_ssr_clock(fr.payload, mt)
                for c in corrs; dec.ssr_clk[(c.sys, c.prn)] = c; end
                dec.ssr_version += 1
                push!(events, EvSsrClock(corrs))
            else
                push!(events, EvOther(mt))
            end
        catch err
            @warn "decode failure on message $(mt)" err
        end
    end
    return events
end
