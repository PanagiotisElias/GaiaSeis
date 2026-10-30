#!/usr/bin/env python3
"""Compare the spikes of two GaiaSeis session logs recorded on the SAME stream at the same time
(for example the old stable code and the new development code on one receiver). stdlib only.

    python3 tools/spike_compare.py logs/ab/UPC10Z_old_<stamp>.txt logs/ab/UPC10Z_new_<stamp>.txt \
        [--metrics logs/ab/UPC10Z_new_metrics_<stamp>.csv] [--lat 38.2837 --lon 21.7868] [--thr 50]

A spike is a run of consecutive epochs whose |displacement per epoch| exceeds --thr mm (default 50).
For each log it prints epochs, blank (NaN) rows, spike events per UTC hour and the largest events; then
it pairs events of the two logs that start within 5 s of each other and lists the ones that only one log
has. With --metrics (the NEW run's metrics CSV) the satellite flags, quality-gate blanks and amplitude
flags raised around each event of the new log are shown (columns satflag_cum, qgate_cum, outliers_cum).
Log rows: SOD (GPS seconds of day), nsat, dX dY dZ [m] ...; UTC = GPS - 18 s.
"""
import argparse, collections, csv, math, statistics, sys

LEAP = 18.0


def load(path):
    rows = []
    for ln in open(path, errors="replace"):
        if ln.startswith("#") or not ln.strip():
            continue
        p = ln.split()
        try:
            sod = float(p[0]); d = [float(v) for v in p[2:5]]
        except (ValueError, IndexError):
            continue
        rows.append((sod, d))
    return rows


def events(rows, thr_m):
    """Runs of consecutive logged epochs above the threshold: (start_sod, n_epochs, peak_m)."""
    ev = []; cur = None
    for sod, d in rows:
        bad = not any(math.isnan(v) for v in d) and math.sqrt(sum(v * v for v in d)) > thr_m
        if bad:
            m = math.sqrt(sum(v * v for v in d))
            if cur is None:
                cur = [sod, 1, m, sod]
            else:
                cur[1] += 1; cur[2] = max(cur[2], m); cur[3] = sod
        elif cur is not None:
            ev.append(tuple(cur[:3])); cur = None
    if cur is not None:
        ev.append(tuple(cur[:3]))
    return ev


def hms(sod):
    s = (sod - LEAP) % 86400
    return "%02d:%02d:%04.1f" % (s // 3600, (s % 3600) // 60, s % 60)


def report(name, rows, ev):
    nan = sum(1 for _, d in rows if any(math.isnan(v) for v in d))
    print(f"\n== {name}: {len(rows)} rows, {nan} blank ({100*nan/max(len(rows),1):.2f} %), {len(ev)} spike events")
    byh = collections.Counter(int(((s - LEAP) % 86400) // 3600) for s, _, _ in ev)
    if byh:
        print("   events per UTC hour:", "  ".join(f"{h:02d}h:{n}" for h, n in sorted(byh.items())))
    for s, n, m in sorted(ev, key=lambda e: -e[2])[:10]:
        print(f"   {hms(s)} UTC  {n:4d} epochs  peak {1000*m:9.0f} mm")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old"); ap.add_argument("new")
    ap.add_argument("--metrics", default="")
    ap.add_argument("--thr", type=float, default=50.0)
    a = ap.parse_args()
    thr = a.thr / 1000.0
    ro, rn = load(a.old), load(a.new)
    eo, en = events(ro, thr), events(rn, thr)
    report("OLD  " + a.old.split("/")[-1], ro, eo)
    report("NEW  " + a.new.split("/")[-1], rn, en)
    # pair events within 5 s
    only_old, only_new, both = [], [], []
    used = set()
    for e in eo:
        j = next((k for k, f in enumerate(en) if k not in used and abs(f[0] - e[0]) <= 5.0), None)
        if j is None: only_old.append(e)
        else: used.add(j); both.append((e, en[j]))
    only_new = [f for k, f in enumerate(en) if k not in used]
    print(f"\n== pairing (start within 5 s): in both {len(both)}, only in OLD {len(only_old)}, only in NEW {len(only_new)}")
    for e in sorted(only_old, key=lambda e: -e[2])[:12]:
        print(f"   only OLD  {hms(e[0])} UTC  {e[1]:4d} epochs  peak {1000*e[2]:9.0f} mm")
    for e in sorted(only_new, key=lambda e: -e[2])[:12]:
        print(f"   only NEW  {hms(e[0])} UTC  {e[1]:4d} epochs  peak {1000*e[2]:9.0f} mm")
    for o, n in both[:12]:
        print(f"   both      {hms(o[0])} UTC  old {1000*o[2]:8.0f} mm ({o[1]} ep)   new {1000*n[2]:8.0f} mm ({n[1]} ep)")
    if a.metrics and en + eo:
        r = [l for l in open(a.metrics) if not l.startswith("#")]
        rows = list(csv.DictReader(r))
        sod = [float(x["sod"]) for x in rows]
        def at(k, t):   # value of a cumulative column at the row nearest t
            i = min(range(len(sod)), key=lambda i: abs(sod[i] - t)); return float(rows[i][k] or 0)
        print("\n== what the new code recorded around each NEW event (+-3 s): flags / gate blanks / amplitude flags")
        for s, n, m in sorted(en, key=lambda e: -e[2])[:12]:
            d = {k: at(k, s + 3) - at(k, s - 3) for k in ("satflag_cum", "qgate_cum", "outliers_cum")}
            print(f"   {hms(s)} UTC  peak {1000*m:8.0f} mm   satellite flags {d['satflag_cum']:.0f}  gate blanks {d['qgate_cum']:.0f}  amplitude flags {d['outliers_cum']:.0f}")
        mz = [float(x["satflag_maxz_mm"]) for x in rows if x.get("satflag_maxz_mm") not in (None, "", "NaN")]
        mz = [v for v in mz if not math.isnan(v)]
        if mz:
            s2 = sorted(mz)
            print(f"   satflag_maxz_mm over the run: median {statistics.median(mz):.1f}  p99 {s2[int(.99*len(s2))]:.1f}  p99.9 {s2[int(.999*len(s2))]:.1f}  max {s2[-1]:.1f}  (flag gate: >= 25 mm)")
        print(f"   totals at the end: satellite flags {rows[-1]['satflag_cum']}, gate blanks {rows[-1]['qgate_cum']}, amplitude flags {rows[-1]['outliers_cum']}")


if __name__ == "__main__":
    main()
