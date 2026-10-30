#!/usr/bin/env python3
"""Compare GaiaSeis link-metrics CSVs (logs/<profile>_metrics_<ts>.csv).

    python3 tools/metrics_compare.py logs/UPA10Z_metrics_*.csv logs/ΝΟΑ10Ζ_metrics_*.csv

Prints one column per file: connection (from the header line), epochs,
missing %, arrival latency / solve time / total delay / miniSEED latency /
SSR age (median, p95, max), jitter, outliers, re-baselined, backpressure
skips, throughput. Use it to compare connection types (caster, port, TLS,
network path, message set) run against run. stdlib only.
"""
import re, sys, statistics as st

def pct(v, p):
    if not v: return float('nan')
    s = sorted(v); return s[min(len(s)-1, max(0, round(p*(len(s)-1))))]

def load(path):
    hdr = ""; link = ""; rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                hdr = line[1:].strip()
                m = re.search(r'link="([^"]*)"', hdr); link = m.group(1) if m else ""
                hdr = re.sub(r'\s*link="[^"]*"', "", hdr); continue
            if line.startswith("sod,"): continue
            p = line.rstrip("\n").split(",")
            if len(p) < 14: continue
            try: rows.append([float(x) if x not in ("NaN", "") else float('nan') for x in p])
            except ValueError: pass
    return (hdr, link), rows

def col(rows, i): return [r[i] for r in rows if r[i] == r[i]]   # drop NaN

def summarise(path):
    (hdr, link), rows = load(path)
    if not rows: return None
    arr, solve, ms, ssr = col(rows, 2), col(rows, 3), col(rows, 4), col(rows, 5)
    tot = [r[2] + r[3]/1000 for r in rows if r[2] == r[2]]
    span = rows[-1][1] - rows[0][1]
    if span < 0: span += 86400
    miss = rows[-1][7] - rows[0][7]; n = len(rows)
    b = [rows[-1][11]-rows[0][11], rows[-1][12]-rows[0][12], rows[-1][13]-rows[0][13]]
    return {
        "file": path, "connection": hdr, "link": link, "duration_s": span, "epochs": n,
        "missing": int(miss), "missing_pct": 100*miss/max(n+miss, 1),
        "arrival_med": pct(arr, .5), "arrival_p95": pct(arr, .95), "arrival_max": max(arr) if arr else float('nan'),
        "jitter": st.pstdev(arr) if len(arr) > 1 else float('nan'),
        "solve_med_ms": pct(solve, .5), "solve_p95_ms": pct(solve, .95),
        "total_med": pct(tot, .5), "total_p95": pct(tot, .95),
        "mseed_med": pct(ms, .5), "mseed_p95": pct(ms, .95), "mseed_n": len(ms),
        "ssr_age_med": pct(ssr, .5), "ssr_age_max": max(ssr) if ssr else float('nan'),
        "outliers": int(rows[-1][10]-rows[0][10]), "rebaselined": int(rows[-1][8]-rows[0][8]), "backpressure": int(rows[-1][9]-rows[0][9]),
        "kBps_obs": b[0]/max(span,1)/1000, "kBps_ssr": b[1]/max(span,1)/1000, "kBps_eph": b[2]/max(span,1)/1000,
    }

def main(paths):
    S = [s for s in (summarise(p) for p in paths) if s]
    if not S: sys.exit("no usable metrics files")
    keys = [("duration_s","%.0f"),("epochs","%d"),("missing","%d"),("missing_pct","%.2f"),
            ("arrival_med","%.3f"),("arrival_p95","%.3f"),("arrival_max","%.3f"),("jitter","%.3f"),
            ("solve_med_ms","%.1f"),("solve_p95_ms","%.1f"),("total_med","%.3f"),("total_p95","%.3f"),
            ("mseed_med","%.3f"),("mseed_p95","%.3f"),("mseed_n","%d"),("ssr_age_med","%.1f"),("ssr_age_max","%.1f"),
            ("outliers","%d"),("rebaselined","%d"),("backpressure","%d"),("kBps_obs","%.2f"),("kBps_ssr","%.2f"),("kBps_eph","%.2f")]
    for i, s in enumerate(S): print(f"[{i+1}] {s['file']}\n    link: {s['link'] or '(none)'}\n    {s['connection']}")
    print(); print("%-16s" % "metric" + "".join("%14s" % f"[{i+1}]" for i in range(len(S))))
    for k, fmt in keys:
        print("%-16s" % k + "".join("%14s" % (fmt % s[k]) for s in S))

if __name__ == "__main__":
    main(sys.argv[1:] or sys.exit(__doc__))
