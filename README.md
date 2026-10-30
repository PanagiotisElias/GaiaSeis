# GaiaSeis

**GNSS-based real-time seismogeodesy platform.** GaiaSeis connects to NTRIP
casters, decodes the RTCM 3 streams of a GNSS receiver (MSM4–7 observations,
broadcast ephemerides, optional SSR), groups each receiver epoch and hands it
to a **displacement engine plug-in**; the resulting displacement time series
is published as miniSEED files, a SeedLink feed (through ringserver), a web
page and a GTK 4 GUI. It runs at 1–10 Hz on a laptop or a small ARM board.

Deforming Gaia Lab, Department of Geology, University of Patras. Panagiotis
Elias (<pelias@upatras.gr>). Version 0.5.0 (2026-10-30), licence
**GNU AGPL-3.0-only** for the code, **CC BY-NC 4.0** for the documents.

- Platform (this repository): <https://github.com/PanagiotisElias/GaiaSeis>
- Default engine, **GaiaVario**: <https://github.com/PanagiotisElias/GaiaVario.jl>
- Archive and DOI: Zenodo (TRANSFORM² community); the DOI is added after the first release.

## How it is organised

| Layer | Where | What |
|---|---|---|
| NTRIP client | `src/ntrip.jl` | HTTP/NTRIP v2, Basic auth, TLS, optional GGA upload, up to three streams (observations, ephemerides, SSR) |
| RTCM 3 decoder | `src/RTCM/` | CRC-24Q frames; MSM4/5/6/7 for GPS, GLONASS, Galileo, BeiDou; 1005/1006 station; 1019/1020/1042/1045/1046 ephemerides; 1057–1068 SSR |
| Epoch grouping, gates | `src/bridge.jl` | one group per receiver epoch across constellations; warm-up, hole, satellite-flag, PDOP/RMS/velocity gates; Causes log |
| **Engine plug-in API** | `GaiaSeisEngineAPI/` | the small interface package an engine implements: `engine_nav!`, `engine_step!`, `engine_reset!`, `ParamSpec`, registry |
| Engine loading | `src/engine_api.jl` | profile field `engine = "gaiavario"`; package from the environment or `engine_path` |
| Outputs | `src/miniseed.jl`, `src/datalink.jl`, `src/GUI/` | miniSEED (512-byte INT32, UTC, time tears); DataLink push to ringserver (SeedLink); web page with PNG panels and `/status.json`; GTK 4 GUI with profile editor, plots, metrics, health |
| Session | `src/session.jl` | reader task, per-epoch log, reconnects, metrics |

**Engines.** The engine is chosen in the profile. `gaiavario` (default) is a
variometric engine written for this platform: for every satellite seen at two
consecutive epochs it differences the carrier phase minus everything modelled
(broadcast orbit and clock, troposphere, solid Earth tide, wind-up, Sagnac)
and solves the station displacement over the pair by weighted least squares
with per-satellite rejection. Its default observable `l1gf` is the L1 phase
corrected with the smoothed geometry-free rate; `single`, `dual`
(ionosphere-free) and `mean` are available. Anyone can add an engine: a Julia
package that depends only on `GaiaSeisEngineAPI` and registers itself under a
name (manual, chapter 3). The engine works from the MSM observations
(1074–1077, 1084–1087, 1094–1097, 1124–1127) and the broadcast ephemerides
(1019, 1020, 1042, 1045) with the 1005/1006 station position (manual §3.7).
The code also keeps an in-bridge path (`engine = "ppphva"`) for the author's
Julia translation of PPPH-VA, which is **not distributed** (manual §3.4,
`NOTICE.md`).

## Install

Requirements: Julia ≥ 1.10 (tested with 1.12), Linux or Windows; GTK 4 for
the GUI (installed by the Gtk4.jl artifacts); ringserver only if you want
SeedLink.

```bash
git clone https://github.com/PanagiotisElias/GaiaSeis.git
cd GaiaSeis
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.add(url="https://github.com/PanagiotisElias/GaiaVario.jl")'
julia --project=. test/smoke_test.jl        # ends with "All smoke checks passed."
```

(Alternatively clone GaiaVario.jl beside `GaiaSeis.jl` and set
`engine_path = "../GaiaVario.jl"` in the profile.)

## Configure

```bash
cp config/ntrip_profiles.example.toml config/ntrip_profiles.toml
```

Edit the caster, mount and credentials (the file is git-ignored). Every key
is documented in the example file and in the manual, chapter 9. The GUI
edits the same file.

## Run

```bash
# GUI
julia -t auto --project=. examples/gui.jl

# headless with the web page on port 7777 (same panels as the Plot window)
GAIASEIS_WEB_PORT=7777 julia -t auto --project=. examples/stream_and_serve.jl

# headless, status line on the terminal
julia --project=. examples/headless_stream.jl
```

The per-epoch solution goes to `logs/GaiaSeis-<profile>.log`; miniSEED files
to `miniseed_mseed_dir`; with `datalink_host = "127.0.0.1"` every record is
pushed to a local ringserver (`tools/ringserver/install.sh` builds and
installs it as a systemd user unit; SeedLink on port 18000; check with
`python3 tools/seedlink_check.py`). SeisComP inventory and bindings:
`docs/GaiaSeis_SeisComP_Integration.md`.

## Try it offline (no credentials)

`examples/` contains two replays that need no caster: a 10-minute 10 Hz
capture of a Topcon NET-G5 (release asset, four constellations) through the
whole platform, and the shaking-table replays of the Samos 2020 and Norcia 2016 earthquakes (Zenodo record
18847292, <https://doi.org/10.5281/zenodo.18847292>, by Kudłacik, Kapłon, Nastase, Tiganescu, Kaczmarek, Elias, Karakonstantis, Zuliani and Nistor, Timișoara campaign of October 2025; station TM0J13ROU)
through the platform with the GaiaVario engine, compared with the table's
accelerometer (peaks agree within 1–3 mm, correlation 0.92–0.99 horizontally).
See `examples/README.md`.

## Documents

- `docs/MANUAL.md` (also `.docx`): user manual: theory, engines, every
  component, installation, GUI, configuration reference, recipes,
  troubleshooting.
- `docs/CHANGELOG.md`: all versions.
- `docs/GaiaVario_vs_PPPHVA_2026-10-29.md`: engine comparison on live data.
- `docs/GaiaSeis_Licensing_Note.html`: why AGPL-3.0 for the code and CC BY-NC 4.0 for the documents.
- `docs/GaiaSeis_SeisComP_Integration.md` (also in Greek): taking the SeedLink feed into SeisComP.

## Linux bundle

`bundle/linux/make-bundle.sh` stages the platform, GaiaVario and a
`THIRD_PARTY_LICENSES.md` into a self-contained directory with an installer
(`install.sh`, desktop entry, launcher); see `bundle/linux/README_INSTALL.md`.

## Citing

See `CITATION.cff` (platform) and the GaiaVario repository; third-party
notices in `NOTICE.md`.

## Licence

Code: GNU Affero General Public License v3.0 only (`LICENSE`).
Documents under `docs/`: Creative Commons Attribution-NonCommercial 4.0 (`docs/LICENSE-DOCS`).
Third-party notices: `NOTICE.md`. Contributions: `CONTRIBUTING.md`.

Copyright (C) 2026 Panagiotis Elias, Deforming Gaia Lab, Department of Geology, University of Patras.

## Acknowledgements

GaiaSeis grew out of the TRANSFORM² project, and it would not exist without
the GNSS partners I worked with there. What I learned from them during the
project (in the shaking-table experiment at Timișoara, in the Geo-INQUIRE
Transnational Access activities, and in the many discussions on high-rate
GNSS, variometric processing and the operation of near-fault observatories)
shaped the design of this software. I warmly thank Jan Kapłon, Iwona Kudłacik
and Adrian Kaczmarek (Wrocław University of Environmental and Life Sciences,
Poland), Eduard Ilie Nastase and Alexandru Tiganescu (National Institute for
Earth Physics, Romania), David Zuliani and Paolo Fabris (National Institute of
Oceanography and Applied Geophysics, OGS, Italy), Antonio Avallone (National
Institute of Geophysics and Volcanology, INGV, Italy), Pierre Briole and Simon
Bufferal (École normale supérieure, France), Vassilis Sakkas (National and
Kapodistrian University of Athens, Greece), Semih Ergintav (Boğaziçi
University, Türkiye), and Efthimios Sokos and Andreas Karakonstantis
(University of Patras, Greece).

## Funding

This work is part of the [TRANSFORM²](https://www.transform2-project.eu/) project which aims to improve physical and digital infrastructure across Near-Fault Observatories (NFOs) in Europe. TRANSFORM² is funded by the European Union under project number 101188365 within the HORIZON-INFRA-2024-DEV-01-01 call.

<div align="center"><img src="https://www.transform2-project.eu/wp-content/uploads/2022/08/Logo_TRANSFORM2-round-logo-100x100-1.png" alt="TRANSFORM² logo"></div>

Views and opinions expressed are however those of the author(s) only and do not necessarily reflect those of the European Union or the European Research Executive Agency (REA). Neither the European Union nor the granting authority can be held responsible for them.
