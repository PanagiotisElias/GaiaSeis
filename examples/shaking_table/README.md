# Earthquakes on the shaking table: GaiaSeis offline against a known motion

A 10 Hz GNSS receiver on a shaking table that plays the accelerogram of a real
earthquake is the closest thing to a seismogeodetic field test with a known
answer: the table's own accelerometer records what the antenna really did.
These examples replay two such runs through the GaiaSeis platform (decoder
adapters, bridge, GaiaVario engine) and compare the displacement with the
accelerometer. They need no caster, no credentials and no Python packages.

| event | wrapper | input motion | table run (row of EVENTS_summary) |
|---|---|---|---|
| `samos_2020` | `examples/samos_2020/run.sh` | HL.TNSA, Samos earthquake 2020-10-30, Mw 7.0, 302 s | TM0, start 10:44:41 UTC (row 6) |
| `norcia_2016` | `examples/norcia_2016/run.sh` | IT.CIT (Cittareale), Norcia earthquake 2016-10-30, Mw 6.6, 65 s | TM0, start 11:06:13 UTC (row 10) |

Both use the same receiver, the same day, the same three data files.

## The data set

Kudłacik, I., Kapłon, J., Nastase, E. I., Tiganescu, A., Kaczmarek, A.,
Elias, P., Karakonstantis, A., Zuliani, D., Nistor, S. (2026). *High-Rate GNSS
and Multi-Sensor Benchmark Dataset from Earthquake Simulation Experiments*
(v1) [Data set]. Zenodo. https://doi.org/10.5281/zenodo.18847292. Licence
CC BY 4.0. The data are not part of this repository; cite the record when you
use them.

The record documents the shaking-table campaign of October 2025 at the
Timisoara Seismological Observatory (TRANSFORM² project): GNSS receivers of
several makes on the table, the table accelerometers, the input motions and
real-time results. The examples use three of its files, fetched by HTTP range
requests out of the zip archives (about 116 MB in total, nothing else is
downloaded, both events share them):

| member | content |
|---|---|
| `GNSS_observations/TM0/TM0J13ROU_R_20252940834_04H_10Z_MO.crx.gz` | receiver TM0J13ROU: Topcon NET-G5 with an external rubidium clock, Javad RingAnt-G5T antenna, 10 Hz Hatanaka RINEX log of 2025-10-21 08:35-12:19 GPS time (GPS, GLONASS, Galileo, BeiDou) |
| `RealTime_RTCM_otherFiles/EPH_NTRIP/TM0/BRDC00WRD_S_20252940000_01D_MN.rnx` | daily broadcast ephemerides (RINEX 3 navigation, mixed GNSS) of that day |
| `Accelerometer_records/Corrected/TM0/RO_TIME_2025_294_TM0_cor.mseed` | table accelerometer RO.TIME, 200 Hz, HNE/HNN/HNZ in m/s², float64 miniSEED, 09:52-12:18 UTC |

The input motions are in the record's `Input_data.zip`
(`Input_data/GR_Samos2020/HL_TNSA_2020_HN?_302.0.txt` and
`Input_data/IT_Norcia2016/IT.CIT..HG?.D.EMSC-20161030_0000029.ACC.MP.ASC`);
the start times of the table runs come from the `EVENTS_summary` sheet of
`Dataset_Readme.xlsx` (column TM0). TM0J13ROU is the only NET-G5 that logged
at 10 Hz during both runs (TM0J12ROU, the unit without clock, has a 10 Hz log
until 09:20 UTC only and 1 Hz afterwards).

## What the scripts do

`run.sh` (POSIX shell; `python3` and `julia` on the path, or `PYTHON` and
`JULIA` set; `EVENT=samos_2020|norcia_2016`) performs:

1. **Fetch** the three members into `examples/data/shaking_table/` with
   `tools/fetch_members.py` of GaiaVario.jl (stdlib Python; skipped when the
   files are present).
2. **Decode** the Hatanaka RINEX log into an observation dump for the event
   window with `tools/crx_to_dump.py` (stdlib Python, 40-50 s: it walks the
   file from 08:35 to the end of the window). The dump is read by
   `tools/obs_dump.jl` into the platform's own `MsmEpoch` objects, so the
   observations enter through the adapters used for RTCM.
3. **Replay** (`replay.jl`) through the bridge with the GaiaVario engine,
   observable `l1gf` (L1 with the smoothed geometry-free correction), mask
   10°, all four constellations: the broadcast ephemerides are served by time
   of clock as a stream would deliver them; the station position and antenna
   come from the RINEX header, the antenna phase-centre model from
   `igs14_2163.atx`. The window is solved 30 s beyond both ends (filter
   margin) after one minute of warm-up.
4. **Compare**: the per-epoch increments are summed to displacement and
   band-passed 0.1-2 Hz (zero phase, fourth-order Butterworth magnitude); the
   accelerometer is integrated twice inside the same pass-band. The table
   axes are taken as north and east (an earlier fit of the orientation on
   the four receivers of the table gave 350-359°, i.e. aligned). The
   "strong motion" statistics cover 60 s around the peak of the table's
   horizontal envelope; the "quiet" RMS is taken before the event.

Windows (UTC seconds of day of 2025-10-21, chosen so that the margins stay
clear of the neighbouring table runs):

| event | window | why |
|---|---|---|
| `samos_2020` | 10:43:30-10:50:30 (38610-39030) | 71 s lead, the 302 s record, coda; next run (Friuli S435) at 10:53:29 |
| `norcia_2016` | 11:05:00-11:08:20 (39900-40100) | 73 s lead, the 65 s record, coda; previous run (AM05) ends 11:04:19, next (CPS) starts 11:08:53 |

Outputs in `examples/shaking_table/out/`, prefix `<event>_tm0j13`:

- `_solution.csv`: one row per epoch, `utc, sod_gps, dN, dE, dU, N, E, U,
  nsat_used, pdop, rms_m` (as `examples/replay_capture.jl`);
- `_displacement.csv`: the 10 Hz grid with the band-passed GNSS and table
  displacement in mm;
- `.png`: three panels (N, E, U), GNSS in blue, table in black (written with
  Cairo from the package environment; an `.svg` with the same content when
  Cairo cannot be loaded);
- the summary on the terminal.

```sh
sh examples/samos_2020/run.sh
sh examples/norcia_2016/run.sh
# equivalently
EVENT=norcia_2016 sh examples/shaking_table/run.sh
```

Environment: `GAIAVARIO_DIR` (checkout of GaiaVario.jl; default the sibling
directory `../GaiaVario.jl` of this package, else the installed package),
`T0_UTC`, `T1_UTC` (override the window; the dump is rebuilt for a new one).

## Expected results

Reference runs on Julia 1.12, one core, data already present; the download
comes on top the first time.

### Samos 2020 (HL.TNSA), 74 s in total (40 s Hatanaka decoding, 23 s replay)

```
Samos 2020 (HL.TNSA) on the shaking table, TM0J13ROU (TPS NET-G5): GaiaVario mode=l1gf mask=10.0° weights=sin2 through the GaiaSeis bridge
epochs    : 4712 solved of 4712 in 10:43:00-10:51:00 UTC (100.0 %), 28.5 satellites used, RMS increments 1.13/0.88/1.85 mm, 0 step errors
GNSS peak : N   19.1 mm at 10:45:53.2   E   12.9 mm at 10:45:38.2   U   22.1 mm at 10:45:54.8   horizontal 19.6 mm at 10:45:53.2
table peak: N   23.9 mm at 10:45:52.9   E   13.0 mm at 10:45:38.2   U  -20.0 mm at 10:45:51.4   horizontal 24.1 mm at 10:45:52.9
agreement : correlation N 0.968  E 0.918  U 0.961, RMSE 2.2/1.6/2.2 mm over the 60 s of strong motion (10:45:27-10:46:27)
quiet     : displacement RMS before the event, GNSS 1.17/0.70/1.89 mm, table 0.09/0.05/0.04 mm (10:43:40-10:45:12)
```

Every epoch is solved with about 28 satellites; the GNSS displacement follows
the table with a correlation of 0.97 / 0.92 / 0.96 (N / E / U) and an RMS
difference of about 2 mm during the minute of strong motion, on a noise floor
of 1-2 mm; the peaks coincide in time to one or two samples. The north peak
of the GNSS is 20 % below the table's (19.1 vs 23.9 mm) while east and up
agree within 10 %; this horizontal deficit is common to all receivers and
engines on this table run and is not resolved here (reference or set-up
rather than GNSS).

![Samos 2020: GNSS against the table accelerometer](out/samos_2020_tm0j13.png)

### Norcia 2016 (IT.CIT), 76 s in total (47 s Hatanaka decoding, 20 s replay)

```
Norcia 2016 (IT.CIT) on the shaking table, TM0J13ROU (TPS NET-G5): GaiaVario mode=l1gf mask=10.0° weights=sin2 through the GaiaSeis bridge
epochs    : 2592 solved of 2592 in 11:04:30-11:08:50 UTC (100.0 %), 25.9 satellites used, RMS increments 1.26/1.46/2.50 mm, 0 step errors
GNSS peak : N   28.6 mm at 11:06:34.6   E  -38.9 mm at 11:06:39.7   U  -20.6 mm at 11:06:36.8   horizontal 41.5 mm at 11:06:39.7
table peak: N   31.1 mm at 11:06:34.7   E  -41.4 mm at 11:06:39.7   U   19.3 mm at 11:06:38.6   horizontal 41.8 mm at 11:06:39.7
agreement : correlation N 0.935  E 0.992  U 0.885, RMSE 1.9/1.2/2.1 mm over the 60 s of strong motion (11:06:14-11:07:14)
quiet     : displacement RMS before the event, GNSS 0.90/0.73/1.85 mm, table 0.03/0.02/0.03 mm (11:05:10-11:05:59)
```

A shorter and stronger motion (41.8 mm horizontal peak on the table, 65 s
record): the GNSS reproduces the peaks within 1-3 mm and at the same sample
(E -38.9 vs -41.4 mm, N 28.6 vs 31.1 mm, horizontal 41.5 vs 41.8 mm), with a
correlation of 0.99 in east, the axis that carries most of the motion. The
vertical peaks differ in sign and time because the up component is small
(about 20 mm) against a 1.9 mm GNSS noise floor and shows no single dominant
pulse; its correlation is 0.89.

![Norcia 2016: GNSS against the table accelerometer](out/norcia_2016_tm0j13.png)

(The figures appear after the first run of each event.)
