# RTCM 3 broadcast-ephemeris decoders:
#   1019 — GPS LNAV
#   1020 — GLONASS
#   1045 — Galileo F/NAV (E5a)
#   1042 — BeiDou D1/D2
#
# Each decoded record is stored in the same 39-column layout that PPPHVA's
# readbrod() builds (so the bridge can drop straight in), keyed by PRN.

const _NAV_ROW_LEN = 39

struct EphemerisRecord
    sys::Char
    prn::Int
    row::Vector{Float64}        # length 39, matches PPPHVA nav.gps[prn, :] etc.
    valid::Bool
end

# ---- 1019 — GPS LNAV ---------------------------------------------------------
# Layout per RTCM 10403.3 §3.5.5. Decoded into the same column convention as
# PPPHVA's readbrod: row[1]=PRN, row[8..10]=clock af0/af1/af2, row[13]=Δn,
# row[14]=M0, row[15]=Cuc, row[16]=e, row[17]=Cus, row[18]=sqrt(A),
# row[19]=toe, row[20]=Cic, row[21]=OMEGA0, row[22]=Cis, row[23]=i0,
# row[24]=Crc, row[25]=omega, row[26]=OMEGA_dot, row[27]=IDOT, row[39]=toc(sod)

function decode_1019(payload::AbstractVector{UInt8})
    br = BitReader(payload)
    skipbits!(br, 12)                       # msg number
    prn = Int(readu(br, 6))                 # GPS satellite ID 1..32
    week = Int(readu(br, 10))
    sv_acc = readu(br, 4)
    code_l2 = readu(br, 2)
    idot = reads(br, 14) * (π / (2.0^43))
    iode = readu(br, 8)
    toc_raw = readu(br, 16); toc_sow = Float64(toc_raw)*16
    # PPPHVA's readbrod stores TOC at col 39 as seconds-of-DAY (derived from
    # the RINEX hh:mm:ss fields). RTCM 1019 gives TOC as seconds-of-WEEK; we
    # reduce mod 86400 so col 39 has matching units and `_orb_cal`'s
    # `dt = tt - brd[39]` produces a small, sensible offset.
    toc = mod(toc_sow, 86400.0)
    af2 = reads(br, 8) * (1 / (2.0^55))
    af1 = reads(br, 16) * (1 / (2.0^43))
    af0 = reads(br, 22) * (1 / (2.0^31))
    iodc = readu(br, 10)
    crs = reads(br, 16) * (1 / (2.0^5))
    delta_n = reads(br, 16) * (π / (2.0^43))
    m0 = reads(br, 32) * (π / (2.0^31))
    cuc = reads(br, 16) * (1 / (2.0^29))
    e   = readu(br, 32)   * (1 / (2.0^33))
    cus = reads(br, 16) * (1 / (2.0^29))
    sqrtA = readu(br, 32) * (1 / (2.0^19))
    toe_raw = readu(br, 16); toe = Float64(toe_raw)*16
    cic = reads(br, 16) * (1 / (2.0^29))
    OMEGA0 = reads(br, 32) * (π / (2.0^31))
    cis = reads(br, 16) * (1 / (2.0^29))
    i0  = reads(br, 32) * (π / (2.0^31))
    crc = reads(br, 16) * (1 / (2.0^5))
    omega = reads(br, 32) * (π / (2.0^31))
    OMEGA_dot = reads(br, 24) * (π / (2.0^43))
    tgd = reads(br, 8) * (1 / (2.0^31))

    row = fill(NaN, _NAV_ROW_LEN)
    row[1]  = Float64(prn)
    row[8]  = af0;       row[9]  = af1;     row[10] = af2
    row[11] = Float64(iode)               # ← so calcsatnav can IODE-match SSR
    row[12] = crs;       row[13] = delta_n; row[14] = m0
    row[15] = cuc;       row[16] = e;       row[17] = cus
    row[18] = sqrtA;     row[19] = toe
    row[20] = cic;       row[21] = OMEGA0;  row[22] = cis
    row[23] = i0;        row[24] = crc;     row[25] = omega
    row[26] = OMEGA_dot; row[27] = idot
    row[39] = toc                          # PPPHVA stores time-of-clock at col 39
    # Col 2 is unused by PPPHVA's nav table — repurpose it as a side
    # channel for the absolute GPS week number (un-wrapped from the 10-bit
    # field using current wall-clock as the rollover anchor). Lets the
    # bridge / GUI compute the true stream date instead of guessing from
    # the receiver's local clock.
    row[2] = Float64(_unwrap_gps_week(week))
    return EphemerisRecord('G', prn, row, true)
end

# Convert the wall-clock UTC `now` into an absolute (un-wrapped) GPS week
# number — the count of complete weeks since 1980-01-06.
function _current_gps_week_anchor()
    gps_epoch = DateTime(1980, 1, 6)
    ms = Dates.value(Dates.now(Dates.UTC) - gps_epoch)
    return div(ms, 7 * 86_400_000)
end

# Unwrap the 10-bit GPS week into an absolute week number using the
# wall-clock anchor — picks the multiple-of-1024 closest to now. Works
# unambiguously as long as the captured data is within ±512 weeks
# (~10 years) of the system clock, which covers every realistic scenario.
function _unwrap_gps_week(w10::Integer)
    anchor = _current_gps_week_anchor()
    base   = anchor - mod(anchor, 1024)
    cand   = base + Int(w10)
    while cand >  anchor + 512; cand -= 1024; end
    while cand <  anchor - 512; cand += 1024; end
    return cand
end

# ---- 1020 — GLONASS ----------------------------------------------------------
# GLONASS uses ECEF position/velocity/acceleration. PPPHVA's readbrod stores
# px/vx/ax in cols 11/12/13, py/vy/ay in 15/16/17, pz/vz/az in 19/20/21 (km).

function decode_1020(payload::AbstractVector{UInt8})
    br = BitReader(payload)
    skipbits!(br, 12)                       # msg number
    prn  = Int(readu(br, 6))                # slot number 1..24
    freq_chn = Int(readu(br, 5)) - 7
    # DF104 almanac health (1) + DF105 health availability (1) + DF106 P1
    # (2) = 4 bits. The decoder used to skip 5 here, which shifted every
    # following field by one bit (garbage state vectors, tb hours off).
    skipbits!(br, 1 + 1 + 2)
    tk_h = readu(br, 5); tk_m = readu(br, 6); tk_s = readu(br, 1)*30
    skipbits!(br, 1 + 1)                    # health flags etc.
    tb = readu(br, 7)                       # 15-min units from start of day
    # x, y, z and their derivatives — each (sign + 23 bits)
    function _glo_signed_scaled(nbits::Int, scale::Float64)
        sign_bit = readu(br, 1)
        mag = readu(br, nbits-1)
        v = Float64(mag) * scale
        return sign_bit == 0 ? v : -v
    end
    xn_dot  = _glo_signed_scaled(24, 1.0 / (2.0^20))   # km/s
    xn      = _glo_signed_scaled(27, 1.0 / (2.0^11))   # km
    xn_dd   = _glo_signed_scaled(5,  1.0 / (2.0^30))   # km/s^2
    yn_dot  = _glo_signed_scaled(24, 1.0 / (2.0^20))
    yn      = _glo_signed_scaled(27, 1.0 / (2.0^11))
    yn_dd   = _glo_signed_scaled(5,  1.0 / (2.0^30))
    zn_dot  = _glo_signed_scaled(24, 1.0 / (2.0^20))
    zn      = _glo_signed_scaled(27, 1.0 / (2.0^11))
    zn_dd   = _glo_signed_scaled(5,  1.0 / (2.0^30))

    skipbits!(br, 1)                                    # P3
    gamma_n = _glo_signed_scaled(11, 1.0 / (2.0^40))    # relative frequency bias
    skipbits!(br, 2 + 1)                                # M_P, M_ln3
    tau_n   = _glo_signed_scaled(22, 1.0 / (2.0^30))    # clock bias (s)
    # (Δτn, En, P4, FT, NT, M, ... follow; not needed.)

    row = fill(NaN, _NAV_ROW_LEN)
    row[1] = Float64(prn)
    row[11] = xn;  row[15] = yn;  row[19] = zn      # position (km)
    row[12] = xn_dot; row[16] = yn_dot; row[20] = zn_dot  # vel (km/s)
    row[13] = xn_dd;  row[17] = yn_dd;  row[21] = zn_dd   # accel (km/s^2)
    # Col 39 is the epoch the state vector is valid at: t_b, given in 15-min
    # units of the UTC(SU)+3h day. PPPHVA's _orb_calglo integrates from it
    # to the observation time (`data.obs.ep`, GPS scale), so express it in
    # GPS-scale seconds of day exactly as readbrod does for RINEX 'R'
    # records (UTC + (leap − 19)). The message frame time t_k is NOT the
    # reference; using it (the previous decoder did) started the integration
    # up to 15 min away from where the state vector is valid.
    row[39] = mod(Float64(tb) * 900.0 - 3*3600.0 + GPS_UTC_LEAP_S, 86400.0)
    # Clock in the RINEX convention PPPHVA expects: −τn (bias) and +γn (drift).
    row[8] = -tau_n; row[9] = gamma_n
    row[2] = Float64(freq_chn)                          # FDMA channel, informational
    return EphemerisRecord('R', prn, row, true)
end

# ---- 1042 — BeiDou -----------------------------------------------------------
# RTCM 10403.3 §3.5.?? (DF488..DF515), 511 bits. Same Keplerian layout as
# 1019 into the readbrod column convention. Times: toc/toe are BDT seconds
# of week (BDT = GPST − 14 s). Column 39 (toc, seconds of day) is shifted
# by +14 s into the GPS scale, exactly as PPPHVA's readbrod does for RINEX
# 'C' records, because `data.obs.ep` is GPS-scale; column 19 (toe) stays in
# BDT seconds of week since `_orb_cal` uses it only in the ωe·toe term,
# which is referenced to the BDT week start like Ω0 is.
function decode_1042(payload::AbstractVector{UInt8})
    br = BitReader(payload)
    skipbits!(br, 12)                       # msg number
    prn  = Int(readu(br, 6))                # BDS satellite ID 1..63
    week = Int(readu(br, 13))
    skipbits!(br, 4)                        # URAI
    idot = reads(br, 14) * (π / (2.0^43))
    aode = readu(br, 5)
    toc  = Float64(readu(br, 17)) * 8
    af2  = reads(br, 11) * (1 / (2.0^66))
    af1  = reads(br, 22) * (1 / (2.0^50))
    af0  = reads(br, 24) * (1 / (2.0^33))
    skipbits!(br, 5)                        # AODC
    crs      = reads(br, 18) * (1 / (2.0^6))
    delta_n  = reads(br, 16) * (π / (2.0^43))
    m0       = reads(br, 32) * (π / (2.0^31))
    cuc      = reads(br, 18) * (1 / (2.0^31))
    e        = readu(br, 32) * (1 / (2.0^33))
    cus      = reads(br, 18) * (1 / (2.0^31))
    sqrtA    = readu(br, 32) * (1 / (2.0^19))
    toe      = Float64(readu(br, 17)) * 8
    cic      = reads(br, 18) * (1 / (2.0^31))
    OMEGA0   = reads(br, 32) * (π / (2.0^31))
    cis      = reads(br, 18) * (1 / (2.0^31))
    i0       = reads(br, 32) * (π / (2.0^31))
    crc      = reads(br, 18) * (1 / (2.0^6))
    omega    = reads(br, 32) * (π / (2.0^31))
    OMEGA_dot = reads(br, 24) * (π / (2.0^43))
    skipbits!(br, 10 + 10)                  # TGD1, TGD2
    health = readu(br, 1)

    row = fill(NaN, _NAV_ROW_LEN)
    row[1]  = Float64(prn)
    row[8]  = af0;       row[9]  = af1;     row[10] = af2
    row[11] = Float64(aode)
    row[12] = crs;       row[13] = delta_n; row[14] = m0
    row[15] = cuc;       row[16] = e;       row[17] = cus
    row[18] = sqrtA;     row[19] = toe
    row[20] = cic;       row[21] = OMEGA0;  row[22] = cis
    row[23] = i0;        row[24] = crc;     row[25] = omega
    row[26] = OMEGA_dot; row[27] = idot
    row[39] = mod(toc, 86400.0) + 14.0     # BDT → GPS-scale seconds of day
    row[2]  = Float64(week + 1356)         # BDT week 0 = GPS week 1356
    return EphemerisRecord('C', prn, row, health == 0)
end

# ---- 1045 — Galileo F/NAV (E5a) ---------------------------------------------

function decode_1045(payload::AbstractVector{UInt8})
    br = BitReader(payload)
    skipbits!(br, 12)
    prn = Int(readu(br, 6))                # 1..36
    week = Int(readu(br, 12))
    iodnav = readu(br, 10)
    sisa = readu(br, 8)
    idot = reads(br, 14) * (π / (2.0^43))
    toc_raw = readu(br, 14); toc_sow = Float64(toc_raw)*60
    # Same unit harmonisation as GPS — see decode_1019 comment.
    toc = mod(toc_sow, 86400.0)
    af2 = reads(br, 6) * (1 / (2.0^59))
    af1 = reads(br, 21) * (1 / (2.0^46))
    af0 = reads(br, 31) * (1 / (2.0^34))
    crs = reads(br, 16) * (1 / (2.0^5))
    delta_n = reads(br, 16) * (π / (2.0^43))
    m0 = reads(br, 32) * (π / (2.0^31))
    cuc = reads(br, 16) * (1 / (2.0^29))
    e   = readu(br, 32)   * (1 / (2.0^33))
    cus = reads(br, 16) * (1 / (2.0^29))
    sqrtA = readu(br, 32) * (1 / (2.0^19))
    toe_raw = readu(br, 14); toe = Float64(toe_raw)*60
    cic = reads(br, 16) * (1 / (2.0^29))
    OMEGA0 = reads(br, 32) * (π / (2.0^31))
    cis = reads(br, 16) * (1 / (2.0^29))
    i0 = reads(br, 32) * (π / (2.0^31))
    crc = reads(br, 16) * (1 / (2.0^5))
    omega = reads(br, 32) * (π / (2.0^31))
    OMEGA_dot = reads(br, 24) * (π / (2.0^43))

    row = fill(NaN, _NAV_ROW_LEN)
    row[1]  = Float64(prn)
    row[8]  = af0;  row[9]  = af1;     row[10] = af2
    row[11] = Float64(iodnav)             # ← for SSR IODE matching
    row[12] = crs;  row[13] = delta_n; row[14] = m0
    row[15] = cuc;  row[16] = e;       row[17] = cus
    row[18] = sqrtA; row[19] = toe
    row[20] = cic;  row[21] = OMEGA0;  row[22] = cis
    row[23] = i0;   row[24] = crc;     row[25] = omega
    row[26] = OMEGA_dot; row[27] = idot
    row[39] = toc
    return EphemerisRecord('E', prn, row, true)
end
