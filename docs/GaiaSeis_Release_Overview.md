# GaiaSeis and GaiaVario: public release 0.5.0

**Panagiotis Elias**, Deforming Gaia Lab, Department of Geology, University of Patras, Greece, <pelias@upatras.gr>
30 October 2026

## 1. What is released

Two open-source Julia packages for GNSS-based real-time seismogeodesy, published on GitHub and archived on Zenodo in the TRANSFORM² community:

| Package | Role | Version | Repository |
|---|---|---|---|
| **GaiaSeis** | the platform: NTRIP client, RTCM 3 decoder, epoch grouping and quality gates, engine plug-in interface, miniSEED / SeedLink / web / GUI outputs | 0.5.0 | <https://github.com/PanagiotisElias/GaiaSeis> |
| **GaiaVario.jl** | the default displacement engine: a variometric engine working from broadcast ephemerides, written for the platform | 0.1.0 | <https://github.com/PanagiotisElias/GaiaVario.jl> |

GaiaSeis reads the raw RTCM 3 stream of a geodetic GNSS receiver (1–10 Hz) through an NTRIP caster, decodes the observations and the broadcast ephemerides of GPS, GLONASS, Galileo and BeiDou, and hands each receiver epoch to an engine. The engine returns the displacement of the station between consecutive epochs; the platform integrates, gates and publishes it as a seismological data stream: miniSEED files, a SeedLink feed (through an EarthScope ringserver), a web page and a GTK 4 graphical interface. The output can be read by SeisComP, ObsPy or any SeedLink client like the record of a seismometer.

The engine is a **plug-in**. The small interface package `GaiaSeisEngineAPI` (inside the platform repository) defines what an engine receives (station, broadcast records, one receiver epoch with all constellations on the GPS time scale) and what it returns (displacement, clocks, per-satellite residuals, quality figures, the parameters it offers to the user). Anyone can write another engine as a separate Julia package and select it with one line in the profile.

## 2. GaiaVario in brief

For every satellite seen at two consecutive epochs with continuous lock, GaiaVario differences the carrier phase minus everything modelled (geometric range with signal transit time and Earth rotation, broadcast satellite clock with relativity, troposphere, solid Earth tide, phase wind-up) and solves the station displacement over the pair by weighted least squares with per-satellite rejection. Its design follows the lessons of a year of continuous operation: GPS time kept exactly as week and seconds of week (no day-boundary wrap), both epochs of a pair modelled with the same broadcast record (an ephemeris changeover never enters a difference), satellites flagged and left out for one pair instead of blanking the epoch. The default observable, `l1gf`, is the L1 phase corrected per satellite with the smoothed rate of the geometry-free combination: it has the low noise of a single-frequency solution (25–27 % below the ionosphere-free combination on a 10 Hz station) while keeping the ionospheric drift small when the ionosphere is disturbed. The models are implemented from the published sources (GNSS interface control documents, IERS Conventions 2010, Niell 1996, Wu et al. 1993) and need no external data files.

## 3. Getting and running the software

Requirements: Julia ≥ 1.10 (Linux or Windows), GTK 4 for the graphical interface (installed automatically by the Julia package), ringserver only for SeedLink.

```
git clone https://github.com/PanagiotisElias/GaiaSeis.git
cd GaiaSeis
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.add(url="https://github.com/PanagiotisElias/GaiaVario.jl")'
cp config/ntrip_profiles.example.toml config/ntrip_profiles.toml   # enter caster, mount, credentials
julia -t auto --project=. examples/gui.jl                            # or examples/stream_and_serve.jl for the web page
```

Two offline examples run without any caster account: the replay of a published 10-minute, 10 Hz, four-constellation capture of a Topcon NET-G5 through the whole platform, and the replays of the shaking-table reproductions of the Samos 2020 and Norcia 2016 earthquakes (Zenodo record 18847292, doi:10.5281/zenodo.18847292, TRANSFORM² campaign at the Timișoara Seismological Observatory, October 2025, by Kudłacik, Kapłon, Nastase, Tiganescu, Kaczmarek, Elias, Karakonstantis, Zuliani and Nistor) through the platform and the engine, compared with the table's accelerometer. A Linux bundle with an installer can be built with `bundle/linux/make-bundle.sh`; it lists the licences of every component it contains.

The user manual (`docs/MANUAL.md`, also as .docx) covers the theory, the engines and how to write one, every component, the configuration reference, SeisComP integration, recipes and troubleshooting.

## 4. Licences and citation

- **Code** (GaiaSeis, GaiaSeisEngineAPI, GaiaVario): GNU Affero General Public License v3.0 only. Anyone may use the software, including commercially, and modify it; modified versions, including those offered as a network service, must be made available with their source under the same licence. The copyright holder is Panagiotis Elias, Deforming Gaia Lab, Department of Geology, University of Patras (2026).
- **Documents** (manual, reports, leaflet, guides, figures): Creative Commons Attribution-NonCommercial 4.0 International.
- **PPPH-VA.** The code keeps an in-bridge path for the author's Julia translation of PPPH-VA (Bahadur, Bezcioglu & Yigit, *GPS Solutions* 28:31, 2024). It is not distributed and the public platform does not depend on it; it runs only where that package is installed, pending its authors' agreement on a licence.
- **Third-party data** (ANTEX antenna calibrations, the GPT3 grid) are not redistributed; the manual says where to obtain them.
- **Citing.** Each repository carries a `CITATION.cff`; the Zenodo DOIs are added to the files and to the READMEs with the first archived release.

## 5. Status and plans

Version 0.5.0 is the state of the software in continuous operation at the University of Patras (a 10 Hz Topcon NET-G5 station served to SeisComP through SeedLink). A 48-hour run comparing the two engines on the same stream, a validation of the `l1gf` observable under a disturbed ionosphere and the documentation of the engine interface for external contributors are planned before version 1.0.0. Issues and contributions are welcome through GitHub (`CONTRIBUTING.md`).

## Acknowledgements

GaiaSeis grew out of the TRANSFORM² project, and it would not exist without the GNSS partners I worked with there. What I learned from them during the project (in the shaking-table experiment at Timișoara, in the Geo-INQUIRE Transnational Access activities, and in the many discussions on high-rate GNSS, variometric processing and the operation of near-fault observatories) shaped the design of this software. I warmly thank Jan Kapłon, Iwona Kudłacik and Adrian Kaczmarek (Wrocław University of Environmental and Life Sciences, Poland), Eduard Ilie Nastase and Alexandru Tiganescu (National Institute for Earth Physics, Romania), David Zuliani and Paolo Fabris (National Institute of Oceanography and Applied Geophysics, OGS, Italy), Antonio Avallone (National Institute of Geophysics and Volcanology, INGV, Italy), Pierre Briole and Simon Bufferal (École normale supérieure, France), Vassilis Sakkas (National and Kapodistrian University of Athens, Greece), Semih Ergintav (Boğaziçi University, Türkiye), and Efthimios Sokos and Andreas Karakonstantis (University of Patras, Greece).

## Funding

This work is part of the [TRANSFORM²](https://www.transform2-project.eu/) project which aims to improve physical and digital infrastructure across Near-Fault Observatories (NFOs) in Europe. TRANSFORM² is funded by the European Union under project number 101188365 within the HORIZON-INFRA-2024-DEV-01-01 call.

Views and opinions expressed are however those of the author(s) only and do not necessarily reflect those of the European Union or the European Research Executive Agency (REA). Neither the European Union nor the granting authority can be held responsible for them.
