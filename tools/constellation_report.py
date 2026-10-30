#!/usr/bin/env python3
"""Compare the runs of tools/constellation_test.jl.
Usage: constellation_report.py OUTDIR [logs_dir] [skip_s]
Reads logs/UPA10Z_X<tag>_<stamp>.txt (per-epoch) and the matching
logs/UPA10Z_X<tag>_metrics_<stamp>.csv, discards the first `skip_s` seconds of
each run (warm-up, default 90), and writes OUTDIR/table.txt, *.dat and the
gnuplot figures fig_*.png."""
import sys, os, re, glob, math, statistics as st, subprocess, collections
OUT = sys.argv[1]; LOGS = sys.argv[2] if len(sys.argv) > 2 else "logs"; SKIP = float(sys.argv[3]) if len(sys.argv) > 3 else 90.0
os.makedirs(OUT, exist_ok=True)
LAT = math.radians(38.283226099); LON = math.radians(21.786237322)
sf, cf, sl, cl = math.sin(LAT), math.cos(LAT), math.sin(LON), math.cos(LON)
def neu(x, y, z): return (-sf*cl*x - sf*sl*y + cf*z, -sl*x + cl*y, cf*cl*x + cf*sl*y + sf*z)
def mad(v):
    if len(v) < 10: return float('nan')
    m = st.median(v); return 1.4826 * st.median([abs(a - m) for a in v])
def p(v, q):
    if not v: return float('nan')
    v = sorted(v); return v[min(len(v)-1, int(q*(len(v)-1)))]
ORDER = ["GPS", "GPSGLO", "GPSGAL", "GPSBDS", "GPSGALBDS", "ALL"]
LABEL = {"GPS": "GPS", "GPSGLO": "GPS+GLO", "GPSGAL": "GPS+GAL", "GPSBDS": "GPS+BDS", "GPSGALBDS": "GPS+GAL+BDS", "ALL": "GPS+GLO+GAL+BDS"}

runs = []
for log in sorted(glob.glob(os.path.join(LOGS, "UPA10Z_X*_20*.txt"))):
    m = re.match(r".*UPA10Z_X([A-Z]+)_(\d{8}_\d{6})\.txt$", log)
    if not m: continue
    tag, stamp = m.group(1), m.group(2)
    mets = sorted(glob.glob(os.path.join(LOGS, f"UPA10Z_X{tag}_metrics_*.csv")))
    # the metrics file created closest after the log stamp
    met = min(mets, key=lambda f: abs(int(re.search(r"(\d{8})_(\d{6})", f).group(1)+re.search(r"(\d{8})_(\d{6})", f).group(2)) - int(stamp.replace('_',''))), default=None)
    rows = []
    with open(log) as f:
        for line in f:
            if line[0] == '#': continue
            q = line.split()
            if len(q) < 5: continue
            rows.append((float(q[0]), int(q[1]), q[2], q[3], q[4]))
    if len(rows) < 100: continue
    t0 = rows[0][0]
    rows = [r for r in rows if r[0] - t0 >= SKIP]
    n = len(rows); blank = sum(1 for r in rows if r[2] == 'NaN')
    good = [(r[0], r[1], float(r[2]), float(r[3]), float(r[4])) for r in rows if r[2] != 'NaN']
    nsat = [r[1] for r in good]
    N, E, U, big = [], [], [], 0; mx = 0.0
    for _, ns, x, y, z in good:
        d = math.sqrt(x*x+y*y+z*z)*1000; mx = max(mx, d)
        if d > 50: big += 1; continue
        a, b, c = neu(x, y, z); N.append(a*1000); E.append(b*1000); U.append(c*1000)
    arr, solve, miss, skip, out = [], [], 0, 0, 0
    if met:
        last = None; first = None
        with open(met) as f:
            for line in f:
                if line[0] in '#s': continue
                q = line.rstrip().split(',')
                if len(q) < 17: continue
                try: sod = float(q[0]); a = float(q[2]); s_ = float(q[3]); mi = int(q[7]); bp = int(q[9]); ou = int(q[10])
                except ValueError: continue
                if sod - t0 < SKIP: continue
                if first is None: first = (mi, bp, ou)
                last = (mi, bp, ou); arr.append(a); solve.append(s_)
        if first and last: miss, skip, out = last[0]-first[0], last[1]-first[1], last[2]-first[2]
    span = (rows[-1][0] - rows[0][0]) if rows else 0
    runs.append(dict(tag=tag, stamp=stamp, n=n, span=span, blank=blank, nsat=st.mean(nsat) if nsat else 0, nsat_min=min(nsat) if nsat else 0,
                     sN=mad(N), sE=mad(E), sU=mad(U), stdN=st.pstdev(N) if N else 0, stdE=st.pstdev(E) if E else 0, stdU=st.pstdev(U) if U else 0,
                     big=big, mx=mx, miss=miss, skip=skip, out=out, arr95=p(arr,.95), solve50=p(solve,.5), solve95=p(solve,.95),
                     ngood=len(good)))
runs.sort(key=lambda r: r['stamp'])
lines = ["run  config            start(local)      epochs  miss  skip  blank  >50mm  max_mm  nsat  sigN  sigE  sigU  stdN  stdE  stdU  arr95  solve50  solve95  outl"]
for i, r in enumerate(runs, 1):
    lines.append(f"{i:3d}  {LABEL.get(r['tag'], r['tag']):17s} {r['stamp'][4:6]}-{r['stamp'][6:8]} {r['stamp'][9:11]}:{r['stamp'][11:13]}  {r['n']:6d} {r['miss']:5d} {r['skip']:5d} {r['blank']:6d} {r['big']:6d} {r['mx']:7.0f} {r['nsat']:5.1f} {r['sN']:5.2f} {r['sE']:5.2f} {r['sU']:5.2f} {r['stdN']:5.2f} {r['stdE']:5.2f} {r['stdU']:5.2f} {r['arr95']:6.2f} {r['solve50']:8.1f} {r['solve95']:8.1f} {r['out']:5d}")
# per-config means over rounds
agg = collections.OrderedDict()
for tag in ORDER:
    rs = [r for r in runs if r['tag'] == tag]
    if not rs: continue
    def m(k): return st.mean(r[k] for r in rs)
    def pct(k): return 100 * sum(r[k] for r in rs) / max(1, sum(r['n'] + r['miss'] for r in rs))
    agg[tag] = dict(runs=len(rs), nsat=m('nsat'), sN=m('sN'), sE=m('sE'), sU=m('sU'), stdN=m('stdN'), stdE=m('stdE'), stdU=m('stdU'),
                    big=sum(r['big'] for r in rs), big_rate=3600*sum(r['big'] for r in rs)/max(1, sum(r['span'] for r in rs)),
                    blank_pct=pct('blank'), miss_pct=pct('miss'), solve50=m('solve50'), solve95=m('solve95'), arr95=m('arr95'), out=sum(r['out'] for r in rs))
lines.append("\nconfig            runs  nsat  sigN  sigE  sigU   stdN  stdE  stdU  >50mm/h  blank%  miss%  solve50  solve95  arr95  outl")
for tag, a in agg.items():
    lines.append(f"{LABEL[tag]:17s} {a['runs']:4d} {a['nsat']:5.1f} {a['sN']:5.2f} {a['sE']:5.2f} {a['sU']:5.2f}  {a['stdN']:5.2f} {a['stdE']:5.2f} {a['stdU']:5.2f} {a['big_rate']:8.1f} {a['blank_pct']:7.2f} {a['miss_pct']:6.2f} {a['solve50']:8.1f} {a['solve95']:8.1f} {a['arr95']:6.2f} {a['out']:5d}")
open(os.path.join(OUT, "table.txt"), "w").write("\n".join(lines) + "\n"); print("\n".join(lines))
with open(os.path.join(OUT, "agg.dat"), "w") as f:
    for tag, a in agg.items():
        f.write(f"\"{LABEL[tag]}\" {a['nsat']:.2f} {a['sN']:.3f} {a['sE']:.3f} {a['sU']:.3f} {a['stdN']:.3f} {a['stdE']:.3f} {a['stdU']:.3f} {a['big_rate']:.2f} {a['blank_pct']:.3f} {a['solve50']:.1f} {a['solve95']:.1f} {a['arr95']:.2f}\n")
with open(os.path.join(OUT, "runs.dat"), "w") as f:
    for i, r in enumerate(runs, 1):
        f.write(f"{i} \"{LABEL.get(r['tag'], r['tag'])}\" {r['nsat']:.2f} {r['sN']:.3f} {r['sE']:.3f} {r['sU']:.3f} {r['big']} {r['solve50']:.1f}\n")
GP = 'set term pngcairo size 1000,%d font "DejaVu Sans,10"\nset output "%s"\nset grid\nset style fill solid 0.8 border -1\nset style data histogram\nset style histogram clustered gap 1\nset boxwidth 0.8\n'
plots = {
 "fig_sigma.png": GP % (420, "fig_sigma.png") + 'set title "Noise of the displacement per epoch (robust sigma, quiet epochs), mean of the rounds"\nset ylabel "mm"\nset key top left\nplot "agg.dat" using 3:xtic(1) title "N" lc rgb "#c0392b", "" using 4 title "E" lc rgb "#27ae60", "" using 5 title "U" lc rgb "#2980b9"\n',
 "fig_nsat.png": GP % (380, "fig_nsat.png") + 'set title "Satellites used per epoch (mean)"\nset ylabel "satellites"\nplot "agg.dat" using 2:xtic(1) notitle lc rgb "#8e44ad"\n',
 "fig_spikes.png": GP % (380, "fig_spikes.png") + 'set title "Epochs above 50 mm per hour, and blank epochs (%)"\nset ylabel "per hour"\nset y2label "%"\nset y2tics\nset key top left\nplot "agg.dat" using 9:xtic(1) title ">50 mm / h" lc rgb "#c0392b", "" using 10 axes x1y2 title "blank %" lc rgb "#7f8c8d"\n',
 "fig_solve.png": GP % (380, "fig_solve.png") + 'set title "Solve time per epoch (ms)"\nset ylabel "ms"\nset key top left\nplot "agg.dat" using 11:xtic(1) title "median" lc rgb "#27ae60", "" using 12 title "95th percentile" lc rgb "#e67e22"\n',
 "fig_runs.png": GP % (420, "fig_runs.png") + 'set title "Per run, in time order (round 1 then round 2 reversed): robust sigma"\nset ylabel "mm"\nset xtics rotate by -30 font ",8"\nset key top left\nplot "runs.dat" using 4:xtic(2) title "N" lc rgb "#c0392b", "" using 5 title "E" lc rgb "#27ae60", "" using 6 title "U" lc rgb "#2980b9"\n',
}
for name, body in plots.items():
    gp = os.path.join(OUT, name.replace('.png', '.gp')); open(gp, 'w').write(body)
    r = subprocess.run(["gnuplot", gp], cwd=OUT, capture_output=True, text=True)
    if r.returncode: print("gnuplot", name, r.stderr[:300])
