# ---------------------------------------------------------------------------
# Causes panel: why epochs go missing, get skipped or come out as spikes.
#
# Every place in the pipeline that drops, blanks or passes a bad epoch calls
# `_cause_event!(kind, count, note)` at the moment it happens. The panel
# (`_draw_causes`) shows, for the kind chosen in the toolbar / page dropdown,
# a description of the mechanism, the cases recorded in this session, and a
# 24-hour UTC histogram of when they occur, with the known windows marked.
# ---------------------------------------------------------------------------

const _CAUSE_KINDS = (:missing, :skips, :rebaseline, :outlier, :qualgate, :spike, :satflag, :ephswitch, :partial,
                      :overload, :outage, :alarm, :livecap)

const _CAUSE_INFO = Dict{Symbol,NamedTuple{(:label, :unit, :text),Tuple{String,String,String}}}(
    :missing => (label = "Missing epochs (caster)", unit = "epochs",
        text = "Holes in the primary constellation's epoch sequence as it arrives from the caster, counted before any processing. GaiaSeis cannot recover an epoch the caster never sent. On mount B the loss is diurnal: it peaks around 18h UTC and 01–03h UTC, when the caster stalls for a few seconds and then bursts, and it grows with the number of clients connected to the mount."),
    :skips => (label = "Skipped solves (catch-up)", unit = "epochs",
        text = "Epochs that arrived but were not solved: when the newest epoch of a batch is more than 1.5 s behind the wall clock AND the backlog is larger than the time budget allows (about 1 s of solving at the running per-epoch time, between 10 and 300 epochs), the session solves only the newest and drops the older ones to stay real-time. A smaller backlog is solved in full since 2026-10-21 (status.json epochs_caught_up). Two triggers: a caster burst after a stall (the epochs were solvable), and a CPU overload by other processes (the data thread could not keep up). The red note beside the version label tells which."),
    :rebaseline => (label = "Re-baselined after a hole", unit = "epochs",
        text = "The first epoch after a hole longer than max_gap_epochs gets no displacement (blank) because the variometric difference would span the hole; the next epoch differences against it. Also counted here: the two warm-up epochs withheld after every start and after SSR corrections switch on."),
    :outlier => (label = "Amplitude outliers (flagged, not blanked)", unit = "epochs",
        text = "Epochs whose dXYZ deviated from the rolling median by more than the MAD threshold. Since 2026-10-20 these epochs are KEPT and only counted: a genuine strong-motion pulse looks the same, and the old guard would have blanked it. The rolling baseline follows the excursion. Real faults are blanked by the quality gate (next kind). outlier_mad_threshold = 0 switches this flag off."),
    :qualgate => (label = "Epochs blanked by the quality gate", unit = "epochs",
        text = "Epochs written as NaN because the solution was not trustworthy: fewer than min_sats_used satellites or min_constellations constellations in the fit, PDOP above max_pdop, weighted post-fit residual RMS above max_fit_rms_m, or a step larger than max_velocity_mps x the epoch interval (no ground motion does that). The note gives the reason and the values. These are profile fields; a value of 0 disables its check. Spikes below the physical limit are not blanked: they are flagged here and in the satellite-flag kind."),
    :spike => (label = "Spikes passed to the output (|dXYZ| > 50 mm)", unit = "epochs",
        text = "Displacements above 50 mm that reached the plot and the miniSEED files. Known sources: single-epoch jumps at :00 and :30 (GPS/BeiDou ephemeris changeover), 1–2.5 s blocks 2–3 min past every 10-minute mark (Galileo ephemeris changeover; broadcast IODE vs SSR IOD not matched), and metre-level values between 21:00 and 24:00 UTC that vanish at midnight (ephemeris day-rollover defect in the orbit routine: dt = tt - toc without a +-86400 wrap)."),
    :satflag => (label = "Satellites flagged by residual", unit = "epochs",
        text = "Epochs in which one or more satellites had a post-fit residual far from the others: the residual of each satellite in the least-squares fit, scaled by its weight, more than 5 robust sigmas (MAD, floor 5 mm) from that epoch's median. A bad ephemeris, a cycle slip or a Galileo/BeiDou changeover hits single satellites and shows here; real ground motion moves every satellite together and leaves the residuals small. FLAG ONLY: the epoch is still solved and written. The note lists the satellites with their scaled residual in mm. The metrics CSV carries satflag_n, satflag_cum and satflag_maxz_mm per epoch."),
    :ephswitch => (label = "Ephemeris changeovers (pmodel rebuilt)", unit = "events",
        text = "A satellite's broadcast ephemeris record changed between two epochs (GPS and BeiDou on the hour and half hour, Galileo every 10 minutes, GLONASS every 30 minutes). The variometric difference would have used the old orbit for one epoch and the new one for the next; the orbit step shows up as a displacement (spike families A and B). The previous epoch's model is rebuilt with the current records so both epochs use the same ephemeris. The note lists the satellites that changed. Compare the times with the spike cases and the satellite flags."),
    :partial => (label = "Epochs solved with a constellation missing", unit = "epochs",
        text = "One constellation's frame did not arrive for the epoch and the solve went ahead on the others (GPS present). Fewer satellites, 2-3x the vertical scatter of a full epoch: fuzz rather than spikes. If GPS itself is missing the epoch is skipped unless 'Solve epochs missing GPS' is ticked."),
    :overload => (label = "CPU overload by other processes", unit = "seconds",
        text = "Time during which other processes held at least half the CPU and GaiaSeis was measurably delayed (load above the core count, solve longer than 70 % of the epoch, or the stream processed more than 2 s late). Solves skipped in these minutes are the cost of the other job; ISCE2/InSAR stacks on this machine did this on 11–12 September."),
    :outage => (label = "Stream drops / reconnects", unit = "events",
        text = "The observation, SSR or ephemeris connection ended or stalled and was reopened. The hole in the data lasts from the drop to the first epoch after reconnect. Reasons (EOF from the caster, stall watchdog, DNS) are in the diagnostic dump."),
    :alarm => (label = "Alarms (stream down, stalled, constellation missing)", unit = "alarms",
        text = "Raised when a stream the profile uses has been refused or down for 30 s or more (the note gives the caster's answer, e.g. HTTP 404 on a missing mount), when a stream is connected but has delivered no bytes for 30 s, or when an enabled constellation has been absent from the solution for 10 s. Each alarm is also shown in red beside the profile name and in /status.json (alarms, sats_used, constellations_used, ssr_mode). A first case is logged when the alarm starts; the red note stays while it lasts. This exists because an SSR mount that answered 404 for 40 hours in October went unnoticed."),
    :livecap => (label = "Live-stream cap reached (web clients)", unit = "requests",
        text = "A /mseed/live or /metrics/live request was refused with 503 because 8 streams were already open. A client that reconnects every minute (an old puller with a 60 s timeout) does this continuously; it does not affect the solution, but each accepted replay costs disk reads and CPU."),
)

mutable struct _CauseLog
    bins::Dict{Symbol,Vector{Float64}}                  # 144 × 10-min UTC bins, session total
    recent::Dict{Symbol,Vector{Tuple{Float64,String}}}  # (wall UTC sod, note), newest last
    total::Dict{Symbol,Float64}
    days::Set{Int}                                       # UTC days seen (for the caption)
end
const _CAUSES = _CauseLog(Dict(k => zeros(144) for k in _CAUSE_KINDS),
                          Dict(k => Tuple{Float64,String}[] for k in _CAUSE_KINDS),
                          Dict(k => 0.0 for k in _CAUSE_KINDS), Set{Int}())
const _CAUSES_LOCK = ReentrantLock()

function _cause_event!(kind::Symbol, count::Real = 1, note::AbstractString = "")
    haskey(_CAUSE_INFO, kind) || return
    u = Dates.now(Dates.UTC)
    sod = Dates.hour(u) * 3600 + Dates.minute(u) * 60 + Dates.second(u)
    lock(_CAUSES_LOCK) do
        _CAUSES.bins[kind][clamp(sod ÷ 600 + 1, 1, 144)] += count
        _CAUSES.total[kind] += count
        push!(_CAUSES.days, Dates.value(Dates.Date(u)))
        r = _CAUSES.recent[kind]
        # collapse bursts: same note within 2 s is one case with a growing count
        if !isempty(r) && abs(r[end][1] - sod) <= 2.0 && startswith(r[end][2], "×")
            n = parse(Int, split(r[end][2][nextind(r[end][2], 1):end])[1]) + 1
            r[end] = (r[end][1], "×$(n) " * note)
        else
            push!(r, (Float64(sod), isempty(note) ? "" : "×1 " * note))
            length(r) > 40 && popfirst!(r)
        end
    end
    return
end

_cause_symbol(s::AbstractString) = (k = Symbol(s); k in _CAUSE_KINDS ? k : :missing)

# Wrap `text` to `maxw` pixels with the current font; returns lines.
function _wrap_text(cr, text::AbstractString, maxw::Float64)
    C = Main.Cairo; lines = String[]; cur = ""
    for w in split(text)
        cand = isempty(cur) ? String(w) : cur * " " * w
        if C.text_extents(cr, cand)[3] > maxw && !isempty(cur)
            push!(lines, cur); cur = String(w)
        else
            cur = cand
        end
    end
    isempty(cur) || push!(lines, cur)
    return lines
end

function _draw_causes(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    G = Main.Gtk4; C = Main.Cairo
    G.set_source_rgb(cr, 1.0, 1.0, 1.0); G.rectangle(cr, 0, 0, w, h); G.fill(cr)
    C.select_font_face(cr, "sans-serif", 0, 0); C.set_font_size(cr, 11.0)
    txt(x, y, s; rgb = (0.15, 0.15, 0.15), size = 11.0, bold = false) = (C.select_font_face(cr, "sans-serif", 0, bold ? 1 : 0); C.set_font_size(cr, size); G.set_source_rgb(cr, rgb...); G.move_to(cr, x, y); C.show_text(cr, s))
    kind = settings.cause_view in _CAUSE_KINDS ? settings.cause_view : :missing
    info = _CAUSE_INFO[kind]
    bins, recent, total, ndays = lock(_CAUSES_LOCK) do
        (copy(_CAUSES.bins[kind]), copy(_CAUSES.recent[kind]), _CAUSES.total[kind], length(_CAUSES.days))
    end
    ml = 16.0; y = 24.0
    # ---- title + session count ----
    extra = ""
    if kind === :outlier && sess !== nothing && sess.profile.outlier_mad_threshold <= 0
        extra = "   — FLAG IS OFF (outlier_mad_threshold = 0 in the profile)"
    end
    txt(ml, y, info.label * @sprintf("   ·   this session: %s %s", total == round(total) ? string(round(Int, total)) : @sprintf("%.0f", total), info.unit) * extra;
        size = 14.0, bold = true, rgb = isempty(extra) ? (0.1, 0.1, 0.1) : (0.8, 0.1, 0.1))
    y += 22
    # ---- description ----
    C.select_font_face(cr, "sans-serif", 0, 0); C.set_font_size(cr, 11.0)
    for l in _wrap_text(cr, info.text, w - 2ml)
        txt(ml, y, l; rgb = (0.25, 0.25, 0.25)); y += 15
    end
    y += 8
    # ---- cases ----
    txt(ml, y, "Cases in this session (UTC, newest last)"; bold = true); y += 16
    hist_top = max(h * 0.52, y + 40)
    if isempty(recent)
        txt(ml, y, "none recorded since start"; rgb = (0.1, 0.5, 0.1)); y += 15
    else
        nrows = max(1, floor(Int, (hist_top - 10 - y) / 14))
        show = recent[max(1, end - nrows + 1):end]
        for (t, note) in show
            hh = floor(Int, t / 3600); mm = floor(Int, (t % 3600) / 60); ss = floor(Int, t % 60)
            txt(ml, y, @sprintf("%02d:%02d:%02d   %s", hh, mm, ss, first(note, 110))); y += 14
        end
        length(recent) > length(show) && (txt(ml, y, @sprintf("… %d earlier cases not shown", length(recent) - length(show)); rgb = (0.5, 0.5, 0.5)); y += 14)
    end
    # ---- 24 h histogram ----
    hy0 = max(y + 14, hist_top); hh_ = h - hy0 - 78
    hh_ < 40 && return
    hx0 = ml + 30; hw = w - hx0 - 14
    txt(ml, hy0 - 4, @sprintf("When it happens — %s per 10-minute bin of the UTC day, summed over %d day%s", info.unit, ndays, ndays == 1 ? "" : "s"); bold = true)
    G.set_source_rgb(cr, 0.95, 0.95, 0.95); G.rectangle(cr, hx0, hy0, hw, hh_); G.fill(cr)
    bmax = max(maximum(bins), 1.0)
    G.set_source_rgb(cr, 0.15, 0.45, 0.85)
    for i in 1:144
        v = bins[i]; v <= 0 && continue
        bh = hh_ * v / bmax
        G.rectangle(cr, hx0 + hw * (i - 1) / 144, hy0 + hh_ - bh, max(hw / 144 - 1, 1.0), bh); G.fill(cr)
    end
    G.set_source_rgb(cr, 0.6, 0.6, 0.6); G.set_line_width(cr, 0.6); G.rectangle(cr, hx0, hy0, hw, hh_); G.stroke(cr)
    for hr in 0:3:24
        x = hx0 + hw * hr / 24
        G.set_source_rgb(cr, 0.8, 0.8, 0.8); G.move_to(cr, x, hy0); G.line_to(cr, x, hy0 + hh_); G.stroke(cr)
        txt(x - 10, hy0 + hh_ + 12, @sprintf("%02d:00", hr % 24); rgb = (0.35, 0.35, 0.35), size = 10.0)
    end
    txt(hx0 + hw - 24, hy0 + hh_ + 24, "UTC"; rgb = (0.35, 0.35, 0.35), size = 10.0)
    txt(ml, hy0 + 10, @sprintf("max %.0f", bmax); rgb = (0.4, 0.4, 0.4), size = 9.0)
    # current UTC time marker
    u = Dates.now(Dates.UTC); now_h = Dates.hour(u) + Dates.minute(u) / 60
    xn = hx0 + hw * now_h / 24
    G.set_source_rgb(cr, 0.85, 0.1, 0.1); G.set_line_width(cr, 1.2); G.move_to(cr, xn, hy0); G.line_to(cr, xn, hy0 + hh_); G.stroke(cr)
    txt(min(xn + 3, w - 40), hy0 + 10, "now"; rgb = (0.85, 0.1, 0.1), size = 9.0)
    # ---- known windows strip ----
    sy = hy0 + hh_ + 32; sh = 14.0
    band(a, b, rgb) = (C.set_source_rgba(cr, rgb[1], rgb[2], rgb[3], 0.35); G.rectangle(cr, hx0 + hw * a / 24, sy, hw * (b - a) / 24, sh); G.fill(cr))
    band(21.0, 24.0, (0.85, 0.15, 0.15))                    # ephemeris day-rollover defect
    band(17.5, 19.0, (0.95, 0.6, 0.15)); band(1.0, 3.5, (0.95, 0.6, 0.15))   # caster loss, typical
    G.set_source_rgb(cr, 0.4, 0.4, 0.4); G.set_line_width(cr, 0.8)
    for k in 0:47                                           # :00 / :30 ephemeris changeover
        x = hx0 + hw * k / 48; G.move_to(cr, x, sy + sh); G.line_to(cr, x, sy + sh + 4); G.stroke(cr)
    end
    G.set_source_rgb(cr, 0.6, 0.6, 0.6); G.rectangle(cr, hx0, sy, hw, sh); G.stroke(cr)
    txt(ml, sy + 11, "known"; rgb = (0.35, 0.35, 0.35), size = 9.0)
    ly = sy + sh + 16
    legend = [((0.85, 0.15, 0.15), "21-24h UTC: ephemeris day-rollover (defect), metre-level spikes"),
              ((0.95, 0.6, 0.15), "about 18h and 01-03h UTC: caster loss (typical)"),
              ((0.4, 0.4, 0.4), "ticks: :00/:30 ephemeris changeover spikes; Galileo every 10 min at +2-3 min"),
              ((0.4, 0.4, 0.4), "CPU overload: whenever other jobs run on this machine")]
    lx = ml
    C.select_font_face(cr, "sans-serif", 0, 0); C.set_font_size(cr, 9.5)
    for (rgb, lab) in legend
        tw = C.text_extents(cr, lab)[3] + 24
        if lx > ml && lx + tw > w - ml; lx = ml; ly += 13; end
        G.set_source_rgb(cr, rgb...); G.rectangle(cr, lx, ly - 8, 9, 9); G.fill(cr)
        txt(lx + 12, ly, lab; rgb = (0.3, 0.3, 0.3), size = 9.5)
        lx += tw
    end
    return
end
