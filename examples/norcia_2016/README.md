# Norcia 2016 on the shaking table

The strong-motion record of station IT.CIT (Cittareale) of the Norcia
earthquake of 2016-10-30 (Mw 6.6), played on the Timisoara shaking table on
2025-10-21 at 11:06:13 UTC (row 10 of the EVENTS_summary sheet of Zenodo
record 18847292) and recorded by a Topcon NET-G5 at 10 Hz, replayed through
GaiaSeis with the GaiaVario engine against the table accelerometer.

```sh
sh examples/norcia_2016/run.sh
```

`run.sh` is a wrapper of `examples/shaking_table/run.sh` with
`EVENT=norcia_2016`; the data set, the steps, the window, the expected summary
and the figure are described in `examples/shaking_table/README.md`. Outputs go
to `examples/shaking_table/out/norcia_2016_tm0j13*`. The three data files are
the same as for the Samos example (same receiver log, same day, same
accelerometer), so nothing more is downloaded when that example has run.

Data: Kudłacik, I., Kapłon, J., Nastase, E. I., Tiganescu, A., Kaczmarek, A.,
Elias, P., Karakonstantis, A., Zuliani, D., Nistor, S. (2026). High-Rate GNSS
and Multi-Sensor Benchmark Dataset from Earthquake Simulation Experiments (v1)
[Data set]. Zenodo. https://doi.org/10.5281/zenodo.18847292 (CC BY 4.0).
