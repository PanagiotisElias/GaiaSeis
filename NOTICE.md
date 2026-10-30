# Notices

GaiaSeis: GNSS-based real-time seismogeodesy platform
Copyright (C) 2026 Panagiotis Elias, Deforming Gaia Lab, Department of Geology, University of Patras

Licensed under the GNU Affero General Public License v3.0 only (`LICENSE`).
The documents under `docs/` are licensed under CC BY-NC 4.0 (`docs/LICENSE-DOCS`).

## Engines

GaiaSeis is a platform with an engine plug-in interface (`GaiaSeisEngineAPI/`).
The default engine is **GaiaVario** (<https://github.com/PanagiotisElias/GaiaVario.jl>,
AGPL-3.0-only, same author), an in-house variometric engine whose models follow
published sources:

- Broadcast orbits and clocks: IS-GPS-200 (table 20-IV); Galileo OS SIS ICD;
  BeiDou SIS ICD (B1I; GEO rotation 5.2.4.12); GLONASS ICD 5.1, appendix 3.
- Troposphere: Saastamoinen (1972) zenith delays; Niell (1996) mapping functions.
- Solid Earth tide: IERS Conventions 2010, eq. 7.5 (degree 2); Sun and Moon from
  the low-precision series of Montenbruck & Gill, *Satellite Orbits* (2000).
- Phase wind-up: Wu, Hajj, Bertiger & Lichten (1993), nominal yaw attitude.

The historical in-bridge engine path `engine = "ppphva"` runs the Julia
translation of **PPPH-VA** (Bahadur, Bezcioglu & Yigit, *GPS Solutions* 28:31, 2024,
doi:10.1007/s10291-023-01560-z; built on PPPH, Bahadur & Nohutcu, *GPS
Solutions* 22:113, 2018). That translation is **not part of this repository
or of any GaiaSeis release**: it is loaded only where its package is installed
beside the platform, and its licence is subject to the agreement of the PPPH-VA
authors. Results obtained with that path must cite the PPPH-VA paper.

## Third-party data not redistributed

- ANTEX antenna calibrations (IGS `igs14.atx`/`igs20.atx`, manufacturer files):
  obtain them from the IGS or the manufacturer; set `antex_file` in the profile.
- GPT3 grid (`gpt3_5.grd`, TU Wien): used only by the PPPH-VA path.

## Third-party software

The platform depends on Julia packages distributed under the MIT licence
(HTTP.jl, Gtk4.jl and their dependencies, as listed in `Manifest.toml`) and,
for the GUI, on the GTK 4, GLib, Cairo and Pango libraries (LGPL-2.1-or-later,
dynamically linked). The SeedLink service is provided by
[ringserver](https://github.com/EarthScope/ringserver) (EarthScope,
Apache-2.0), installed separately by `tools/ringserver/install.sh`. The RTCM 3
decoder is original work written from RTCM Standard 10403.3. The Linux bundle
ships a `THIRD_PARTY_LICENSES.md` with the full texts of the licences of every
package it contains.

## Funding

This work is part of the [TRANSFORM²](https://www.transform2-project.eu/)
project which aims to improve physical and digital infrastructure across
Near-Fault Observatories (NFOs) in Europe. TRANSFORM² is funded by the European
Union under project number 101188365 within the HORIZON-INFRA-2024-DEV-01-01 call.

Views and opinions expressed are however those of the author(s) only and do not
necessarily reflect those of the European Union or the European Research
Executive Agency (REA). Neither the European Union nor the granting authority
can be held responsible for them.
