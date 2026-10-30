# Examples

All commands are run from the package directory (the one with `Project.toml`),
after `julia --project=. -e 'using Pkg; Pkg.instantiate()'`.

| file | what it does | needs |
|---|---|---|
| `replay_capture.jl` | replays a raw RTCM capture through the platform (decoder, bridge, GaiaVario engine), writes a per-epoch CSV and optionally miniSEED | the release asset (below) |
| `fetch_example_data.sh` | downloads that asset into `examples/data/` | curl |
| `shaking_table/` | replays an earthquake record played on a shaking table (Zenodo 18847292, receiver TM0J13ROU) through the bridge with GaiaVario and compares the GNSS displacement with the table accelerometer; `EVENT` selects the run | python3, about 116 MB from Zenodo (shared by both events) |
| `samos_2020/run.sh` | wrapper: Samos 2020 (HL.TNSA record, Mw 7.0) on the table at 10:44:41 UTC | as above |
| `norcia_2016/run.sh` | wrapper: Norcia 2016 (IT.CIT record, Mw 6.6) on the table at 11:06:13 UTC | as above |
| `gui.jl` | the desktop GUI | a profile with caster credentials |
| `stream_and_serve.jl` | headless stream with the web interface | a profile with caster credentials |
| `headless_stream.jl` | headless stream printing the status line | a profile with caster credentials |

The replays need no caster, no credentials and no receiver.

## Offline replay of a captured stream

The platform's raw logger writes every byte it receives from the caster to
`logs/rtcm_raw_<stamp>.bin` (records of wall time, stream id, length, bytes).
Such a capture replays through exactly the code path of a live session: the
RTCM decoder, the epoch grouping across constellations, the bridge with its
warm-up, holes, quality gate and the engine plug-in.

The example capture is a release asset: ten minutes of a Topcon NET-G5 at
10 Hz on 2026-10-29 (13:43-13:53 UTC), MSM7 of GPS, GLONASS, Galileo and
BeiDou with the broadcast ephemerides and the station position in the stream,
10 MB.

```sh
sh examples/fetch_example_data.sh
# or by hand:
curl -L -o examples/data/upc10z_10min_20261029.bin \
     https://github.com/PanagiotisElias/GaiaSeis/releases/download/v0.5.0/upc10z_10min_20261029.bin

julia --project=. examples/replay_capture.jl examples/data/upc10z_10min_20261029.bin --out solution.csv
```

Options: `--mode l1gf|single|dual|mean` (the GaiaVario observable; default
`l1gf`), `--minutes N` (replay only the first N minutes), `--mseed DIR`
(also write the solution as miniSEED with the platform's writer: channels
`XX.RPLAY..LNN/LNE/LNZ`, counts = metres x 1e7, timestamps of the capture).

The CSV has one row per solved epoch group: `utc, sod_gps, dN, dE, dU, N, E,
U, nsat_used, pdop, rms_m`. `dN dE dU` are the per-epoch displacement
increments in metres that the platform logs, plots and streams (NaN when the
quality gate blanked the epoch), `N E U` their running sum, `rms_m` the
weighted RMS of the post-fit residuals.

Expected summary (Julia 1.12, one core, 24 s including compilation):

```
capture   : upc10z_10min_20261029.bin  9.8 min of data, GaiaVario mode=l1gf mask=10.0° weights=sin2
epochs    : 5951 solved by the bridge, 5950 with a displacement (100.0 %), 0 step errors
increments: RMS dN 0.70  dE 0.59  dU 2.35 mm per epoch
satellites: 31.0 used on average
output    : solution.csv  (22.1 s of processing)
```

The first epoch has no displacement (the variometric solution needs two
epochs). With `--mode single` the figures are identical (the geometry-free
correction of `l1gf` is inactive in a quiet ionosphere); `--mode dual`
(ionosphere-free) gives 1.09 / 1.02 / 2.86 mm, i.e. 1.2-1.7 times noisier
per epoch.

## Earthquakes on the shaking table

```sh
sh examples/samos_2020/run.sh      # Samos 2020, HL.TNSA record
sh examples/norcia_2016/run.sh     # Norcia 2016, IT.CIT record
```

Each run fetches three members of the Zenodo record (once, shared by both
events), decodes the receiver's 10 Hz RINEX log for the event window, replays
it through the bridge with GaiaVario and writes the solution, a figure against
the table accelerometer and a summary; about 75 s per event after the
download. See `shaking_table/README.md` for the data, the windows and the
expected results.

Data set: Kudłacik, I., Kapłon, J., Nastase, E. I., Tiganescu, A., Kaczmarek,
A., Elias, P., Karakonstantis, A., Zuliani, D., Nistor, S. (2026). High-Rate
GNSS and Multi-Sensor Benchmark Dataset from Earthquake Simulation Experiments
(v1) [Data set]. Zenodo. https://doi.org/10.5281/zenodo.18847292 (CC BY 4.0),
from the TRANSFORM² shaking-table campaign at the Timișoara Seismological
Observatory, October 2025. The data are not part of this repository; cite the
record when you use them.
