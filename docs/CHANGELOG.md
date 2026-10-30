# GaiaSeis changelog

Versions in reverse order. Dates are the day a version was tagged or, before
tags existed (0.4.0), the day its changes went into service. The git history of
the stable repository starts at 0.4.0; earlier entries are reconstructed from
the manual's change notes and the engineering log (`LINUX_HANDOFF.md` §4).

## 0.5.0 (2026-10-30)

First public release (GitHub and Zenodo). Code under GNU AGPL-3.0-only,
documents under CC BY-NC 4.0.

- **PPPHVA is optional:** the platform loads and runs without it (its own
  `PStruct` type for the bridge containers; the engine name `ppphva` is
  offered only where the PPPHVA package is found at load time: in the
  environment, under `GAIASEIS_PPPHVA_PATH`, or as `../PPPH_VA/PPPHVA.jl`).
  PPPHVA.jl is not distributed pending the PPPH-VA authors' agreement on
  its licence.
- **Default engine `gaiavario`, default observable `l1gf`** (L1 corrected
  per satellite with the smoothed geometry-free rate; `single`, `dual` and
  `mean` remain available). GaiaVario.jl 0.1.0 is published as its own
  repository and installed with `Pkg.add(url=...)`; the engine interface
  `GaiaSeisEngineAPI` ships as a sub-package of the platform.
- **Version 0.5.0; public release on GitHub and Zenodo** (AGPL-3.0-only
  code, CC BY-NC 4.0 documents): `LICENSE`, `docs/LICENSE-DOCS`,
  `NOTICE.md`, `CITATION.cff`, `CONTRIBUTING.md`; the manual rewritten for
  the platform-and-engines structure (chapter 3 "Engines", installation
  from the public repositories, configuration reference with the engine
  fields); private hosts and credentials removed from every document.
- Residual statistics (2026-10-30): per accepted epoch the history keeps the
  engine's own σ̂, the weighted and the unweighted post-fit RMS of the
  satellites kept, and a smoothed σ̂ (cumulative mean for 300
  epochs, then 300-epoch/30-epoch exponential average with a 3× cap). The
  Plot window has a **Settings** page and the web page a selector to choose
  which one the Residual panel shows, with a one-line explanation of each.
  Plot window: a status line above the tabs (engine, profile, constellations,
  satellites used, rate, running time, missing epochs). Ground track: the
  North label and the statistics no longer overlap the axis numbers.
- Production UPC10Z profile: observable `l1gf` (2026-10-30).
- GaiaVario default observable set to `:l1gf` (2026-10-30; `:single` remains
  available). ringserver stays the external SeedLink server of the release.

- **Engine plug-in API** (2026-10-30): new interface package `GaiaSeisEngineAPI/`
  (types, `engine_nav!`, `engine_step!`, `engine_reset!`, registry); profile
  fields `engine`, `engine_mode`, `engine_path`, `engine_options`; the bridge
  stages the frames of each epoch group and, for `engine != "ppphva"`, hands
  them to the plug-in and runs the unchanged warm-up, hole, flag and gate
  logic on its result (`src/engine_api.jl`, `_plugin_solve!`). GaiaVario
  registers itself as `gaiavario` (`GaiaVario.jl/src/plugin.jl`; default
  observable `single` at that point, `l1gf` since 2026-10-30).
  `test/engine_plugin_replay.jl`: the plug-in path
  reproduces GaiaVario's direct replay on 1822 of 1822 epochs to < 0.1 mm.
  Manual 5.27, 9.
- Web page and GUI: engine shown in the header line and in `/status.json`
  (`engine`, `engine_info`); new "About engine" button/dialog (`/engine.txt`)
  describing the engine in use; About text brought up to date (AGPL-3.0,
  platform/engines, PPPH-VA 2023 citation with the correct authors, funding
  wording); skyplot and σ̂ panel fed by the plug-in's per-satellite results;
  latency panel hides the first minute of a session (catch-up outliers).
- GUI profile editor: notebook with the pages "Stream & outputs" and **"Engine"**.
  The Engine page offers the engines this installation can load, the plug-in
  directory, and the parameters each engine declares itself
  (`GaiaSeisEngineAPI.ParamSpec`: choice, number, flag or text with defaults
  and help); the PPPHVA path shows its process mode, elevation cut and ANTEX
  there. Values are stored in `engine_options`; the page is locked while a
  stream runs (the engine cannot change mid-stream).

- **GaiaVario.jl started** (2026-10-29): an in-house variometric engine as a
  sibling package (`GaiaVario.jl/`), written from the ICDs, IERS 2010, Niell
  (1996) and Wu et al. (1993), not from any existing variometric code. Time is
  kept as (week, seconds of week) with exact differences; both epochs of a pair
  use the broadcast record current at the previous epoch; per-satellite
  rejection on a MAD scale of the signed weighted residuals; formal NEU sigmas
  per solution. Synthetic-truth generator (prescribed motion, noise, slips,
  changeovers) and tests; `tools/record_brdc.jl` records real ephemerides from
  the local relay. Not yet selectable from a profile (plan
  `docs/GaiaVario_Engine_Plan.md`). First live comparison on UPC10Z through
  the relays, 10 min on 2026-10-29 (`GaiaVario.jl/tools/compare_live.jl`,
  `compare_report.py`, report `docs/GaiaVario_vs_PPPHVA_2026-10-29.md`):
  both engines solve 99.9 % of epochs, zero mean difference, GaiaVario 15–35 %
  noisier (1.27/0.87/3.27 vs 0.96/0.76/2.40 mm N/E/U), 0.2 ms per epoch.
  Later the same day (shaking-table replay of Zenodo 18847292 on four receivers, `GaiaVario.jl/tools/zenodo_replay.jl`,
  `docs/GaiaVario_continuity_options_2026-10-29.md`): observables `:single`, `:mean` and `:l1gf`; continuity options
  (`robust`, `taper_deg`, `admit_epochs`, `clock_model`); `:l1gf` is L1 corrected per satellite with a
  smoothed geometry-free rate (equal to plain L1 in a quiet ionosphere, 3-4 times better under a synthetic ionospheric ramp);
  after review the default observable was first set to `:single` (L1), with `:l1gf` as an option (changed to `:l1gf` on 2026-10-30);
  against the table accelerometer its correlation is 0.955 against 0.89 for PPPHVA and 0.84 for the ionosphere-free GaiaVario.
  Three runs and 16 replayed variants on a raw relay recording
  (`replay_gaiavario.jl`): GPS L2C instead of 2W halves the excess, weights
  and Galileo/BeiDou pairs do not matter, vertical equal to PPPHVA, horizontal
  +14 % unexplained; single-frequency is 20–35 % quieter than either
  dual-frequency engine at 10 Hz. Interactive viewer
  `docs/GaiaVario_vs_PPPHVA_interactive.html`.

- Documentation: SeisComP integration guide for UPC10Z and UPA10Z, in English
  and Greek (PDF and .docx); miniSEED operator guide updated; StationXML for
  `CL.UPC10` (`docs/UPC10.xml`); report *UPA10Z versus UPC10Z* (stream
  completeness, the 10 kB/s ceiling, the latency chain, streaming statistics);
  three-page leaflet; block diagram corrected (the solution now feeds the
  GaiaSeis chain; SeedLink real, external consumers dashed) and brought to 0.4.2.
- ringserver template: `AcceptIP` lines limiting DataLink and SeedLink to
  localhost and the department networks (applied to the production
  configuration on 2026-10-23).
- Operations: since 2026-10-23 11:02 UTC production UPC10Z reads the receiver and
  `BCEP00BKG0` through two local NTRIP relays (`tools/ntrip_relay.py` as the systemd
  user units `gaiaseis-relay-obs` on 2199 and `gaiaseis-relay-eph` on 2198, kept in
  the `pppar` repository); the receiver sees one client. Mitigation item 7 of the
  causes report is met for UPC10Z.

## 0.4.2 (2026-10-22)

Production moved to station UPC10Z (`CL.UPC10`, SSR off). Changes since 0.4.1:

- **Quality gate and flags replace amplitude blanking.** An epoch is withheld
  only for a fault: fewer than `min_sats_used` satellites, fewer than
  `min_constellations`, PDOP above `max_pdop` (of the satellites in the fit),
  weighted post-fit RMS above `max_fit_rms_m`, or a step above
  `max_velocity_mps` × epoch interval. The rolling-MAD test is kept as a flag
  only (epochs are never removed by amplitude; the self-reset latch is gone;
  defaults 8 × MAD over 200 epochs). Reason: the old guard would have blanked
  genuine strong motion.
- **Per-satellite residual flags** (`satflag`): the engine returns the
  post-fit residual of every satellite; a satellite more than 5 robust sigmas
  (floor 5 mm) from the epoch's median is flagged. Causes kind, metrics CSV
  columns and `/status.json` fields. Flag only.
- **Ephemeris consistency inside the variometric pair:** when a satellite's
  broadcast record changes between two epochs, the previous epoch's model is
  rebuilt with the current record so both epochs use one orbit (Causes kind
  *Ephemeris changeovers*). Removes the hour/half-hour and Galileo changeover
  spikes (families A and B).
- **Day wrap** in the broadcast orbit routines and the SSR time differences
  (`_wrapdt`, ±43 200 s). Removes the nightly band and the GPS-midnight burst
  (families C and D). Verified live at the 23:59:42 UTC boundary: 72 km burst
  in 0.4.1, none in 0.4.2.
- **Windowed σ̂ in the engine** (`_sigma_update`): cumulative mean for the
  first 300 epochs, then an exponential average (300 epochs up, 30 down) with a
  per-epoch cap; the 2.5-σ gate compares with the previous epochs. A poisoned
  value recovers in about 150 epochs instead of never.
- **Catch-up on queue length:** a late batch is solved in full when it fits a
  1 s budget at the running per-epoch time (10 to 300 epochs); only a larger
  backlog is shed. `epochs_caught_up`, `solve_ms_ema`.
- **Alarms:** stream refused or down for 30 s (with the caster's answer),
  stream stalled 30 s, constellation absent from the solution for 10 s; red
  note beside the profile name, web page, `/status.json` (`alarms`,
  `sats_used`, `constellations_used`, `ssr_mode`, `ssr_sats`), Causes kind.
- **SSR validity with broadcast fallback** (when SSR is used): a satellite is
  corrected only if orbit and clock corrections are younger than
  `ssr_max_age_s`; otherwise it uses its broadcast orbit (`ssr_fallback`)
  instead of being dropped. Prevents the 8 October 2026 collapse.
- **Forensics:** metrics CSV columns `ssr_msgs_cum`, `ssr_valid_sats`,
  `cpu_others_pct`, `cpu_self_pct`, `load1`, `mem_avail_mb` (27 columns);
  per-stream RTCM message counts in the debug dump; the previous session log
  is kept (`<name>_<time>.log`, pruned to `keep_session_logs`) instead of
  overwritten.
- **SeedLink:** the station code follows the profile (`miniseed_station`), so
  the production move to UPC10Z publishes `CL.UPC10` (CL.UPA10 stopped at the
  switch); end-to-end latency measured for the first time: 0.92 s median,
  1.42 s p95 from ground motion to a SeedLink consumer on the same host, of
  which about 0.5 s is the ringserver client service.
- **RTCM:** MSM4 and MSM6 decode correctly (the 4-bit extended satellite info
  exists only in MSM5/7; synthetic round-trip test for all four variants).
- **Tools:** `loss_monitor.py` (side-by-side raw-stream completeness and
  latency per 5-minute block), `spike_compare.py` (two session logs on the
  same stream), `ntrip_relay.py` (one upstream connection, any number of
  local clients; a NET-G5 caster degrades with every extra client).
- Manual sections 5.7, 5.23 to 5.26, 11.8 and 11.8a; causes report status
  note; tests for every item.

## 0.4.1 (2026-10-18)

- DataLink close made non-blocking: a SIGTERM no longer hangs the GUI in
  `wait_close` at exit.

## 0.4.0 (2026-10-18)

First tagged release; the stable repository starts here. Contents of the
0.3.b development period (2026-09-10 to 2026-10-16):

- **SeedLink service** (2026-10-06): every miniSEED record is pushed over
  DataLink to a ringserver (`datalink_host`/`datalink_port`; installer
  `tools/ringserver/install.sh`, user service `gaiaseis-ringserver`, DataLink
  16000, SeedLink 18000; `tools/seedlink_check.py`; SeisComP guide).
- **Solver 15× faster** (2026-10-16): the VMF3 mapping-function sums are
  memoised per station, bit-identical results; 33 → 2 ms median per 10 Hz
  epoch with four constellations. `tools/profile_solver.jl`.
- **Multi-constellation epoch grouping** (2026-09-10): each constellation's
  MSM frame is staged per timestamp and the solve runs once per epoch; holds
  an incomplete group one epoch; BeiDou/BDT time handling; GLONASS and BeiDou
  support fixed; Galileo signal table.
- **Causes panel** (2026-09-17): every mechanism that drops, blanks or passes a
  bad epoch is logged with its cases and a 24 h histogram (web page too).
- **Health panel and CPU-overload note**; **Metrics window** comparisons;
  `examples/stream_and_serve.jl` honours `GAIASEIS_WEB_PORT` and saved plot
  settings; `tools/run_gui_watched.sh` and `tools/gui_watchdog.sh`.
- Outlier guard defaults and the plot-window latch fixed (a threshold of 0 was
  being persisted); first-epoch warm-up withheld; `max_gap_epochs`
  re-baselining after holes.
- Reports: *Epoch_Anomalies_Report_2026-09*,
  *Causes_and_Mitigation_Report_2026-10*,
  *Constellation_Effect_Report_2026-10*; tools `constellation_test.jl`,
  `constellation_report.py`.

## 0.3 (2026-09-09)

- miniSEED writer: a missing or blanked epoch closes the record and starts a
  new one at the true time (time tear); earlier versions time-shifted the
  following samples inside the record. Files written before this date carry
  that error, and files before 2026-09-10 10:00 UTC are stamped in GPS time.
- SSR epoch time reduced from GPS time of week to seconds of day and unwrapped
  across midnight (2026-09-10); before, the rate terms produced tens of metres
  per satellite at every SSR update.
- Metrics window and per-epoch metrics CSV (arrival, solve and miniSEED
  latencies, SSR age, loss, outages, throughput; `/metrics.json|txt|png`;
  `tools/metrics_compare.py`).
- Missing input epochs counted and shown (main window, plot toolbar, red
  ticks, web header, `/status.json`); `/status.json` and `/clients.json`
  extended; live-stream producers stop when the client hangs up (fixes
  unbounded memory growth under a polling consumer); forced periodic GC off by
  default; min/max level-of-detail plotting; web panel cache.
- Tools `rtcm_raw_probe.py`, `spp_estimate.jl`; bundler sweeps backup files
  and scans for credentials.
- Reports: *N_vs_E_Noise*, *Outlier_Guard_and_MAD*,
  *miniSEED_Operator_Guide*, *Missing_Measurements_UPA10Z*.

## 0.1 and 0.2 (May to August 2026 (as NtripClient.jl))

- NTRIP v2 client (observations, SSR products and broadcast-ephemeris
  connections), RTCM 3 decoder (MSM observations, 1005/1006, 1019/1020/1042/
  1045/1046, SSR orbit and clock), bridge to PPPHVA (the Julia translation of
  variometric approach, SFV and DFV modes, VMF3/GPT3, ANTEX, cycle-slip detection).
- Gtk4 GUI with profile editor and the plot window (displacement, ground
  track, skyplot, residual σ̂, satellites/DOP); LAN web page; CSV and session
  log; miniSEED day files; rolling-MAD outlier guard; display filters
  (high-pass, Kalman, decimation); Windows, Linux and macOS installs; the
  user manual (May 2026) and the Windows binary bundle.
