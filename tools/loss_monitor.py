#!/usr/bin/env python3
"""Long-running, like-for-like epoch-loss monitor for one or more NTRIP profiles (stdlib only).

Connects to the obs mount of each profile in config/ntrip_profiles.toml at the same time,
CRC-checks every RTCM3 frame and, per wall-clock-aligned block (default 300 s), counts the
distinct GPS MSM epochs received against the number expected at the stream's rate. It is a
raw-stream measurement independent of GaiaSeis' decoder and solver, like rtcm_raw_probe.py,
but continuous and for several receivers side by side, so the blocks line up.

    python3 tools/loss_monitor.py UPA10Z UPC10Z --hours 3
    python3 tools/loss_monitor.py UPA10Z UPC10Z --start 04:30 --hours 3     # wait until 04:30 UTC
    python3 tools/loss_monitor.py UPA10Z --seconds 60 --block 20 [--toml path] [--rate 10]

Output (stdout and logs/loss_monitor_<stamp>.csv, one row per block and profile):
  block_utc, profile, got, expected, missing_pct, gaps, max_gap_s,
  lat_med_s, lat_p95_s, lat_max_s, bytes, msgs/s (MSM frames), reconnects
Latency = arrival wall time - epoch time (GPS time - 18 s). At the end a summary per profile and
per UTC hour is printed. Credentials are read from the TOML and never printed. Every extra client
loads a receiver's caster: run it only while nothing else (GUI, dev session) is connected.
"""
import argparse, base64, collections, datetime as dt, math, os, re, signal, socket, statistics, sys, threading, time

LEAP = 18.0


def read_profile(name, path):
    toml = open(path, encoding="utf-8").read()
    hdrs = list(re.finditer(r'(?m)^\[profiles\."?([^"\]]*)"?\]\n', toml))
    m = next((h for h in hdrs if h.group(1) == name), None) or \
        next((h for h in hdrs if h.group(1).startswith(name[:5])), None)
    if m is None:
        sys.exit(f"profile {name!r} not found in {path}")
    sec = toml[m.end():]
    nxt = re.search(r'(?m)^\[', sec)
    sec = sec[:nxt.start()] if nxt else sec

    def g(k, default=None):
        r = re.search(r'^\s*%s\s*=\s*"?([^"\n]*)"?' % k, sec, re.M)
        return r.group(1).strip() if r else default
    return dict(name=m.group(1), host=g("caster"), port=int(g("port")), mount=g("mountpoint"),
                user=g("user", ""), pw=g("password", ""),
                lat=float(g("gga_lat_deg", 0)), lon=float(g("gga_lon_deg", 0)), hgt=float(g("gga_height_m", 0)))


def crc24(d):
    c = 0
    for b in d:
        c ^= b << 16
        for _ in range(8):
            c <<= 1
            if c & 0x1000000:
                c ^= 0x1864CFB
    return c & 0xFFFFFF


def gga(p):
    u = dt.datetime.now(dt.timezone.utc); la, lo = abs(p["lat"]), abs(p["lon"])
    body = (f"GPGGA,{u:%H%M%S}.00,{int(la):02d}{(la-int(la))*60:07.4f},{'N' if p['lat']>=0 else 'S'},"
            f"{int(lo):03d}{(lo-int(lo))*60:07.4f},{'E' if p['lon']>=0 else 'W'},1,10,1.0,{p['hgt']:.1f},M,0.0,M,,")
    c = 0
    for ch in body:
        c ^= ord(ch)
    return f"${body}*{c:02X}\r\n".encode()


class Mon:
    """Per-profile collector. Epochs are binned by their own time, so late arrivals count."""

    def __init__(self, p, block, step_ms):
        self.p, self.block, self.step = p, block, step_ms
        self.epochs = collections.defaultdict(set)      # block index -> set of TOW ms
        self.first_arr = {}                              # TOW ms -> arrival wall time
        self.bytes = collections.Counter()               # block index (arrival) -> bytes
        self.frames = collections.Counter()              # block index (arrival) -> MSM frames
        self.types = collections.Counter()
        self.reconnects = collections.Counter()          # block index -> reconnects
        self.lock = threading.Lock()
        self.stop = threading.Event()

    def epoch_utc(self, tow_ms, wall):
        """Absolute UTC epoch time of a GPS time-of-week, resolved to the day nearest the wall clock."""
        sod = (tow_ms / 1000.0) % 86400.0 - LEAP
        day0 = wall - (wall % 86400.0)
        best = min((day0 + sod + k * 86400.0 for k in (-1, 0, 1)), key=lambda t: abs(t - wall))
        return best

    def run(self):
        p = self.p
        while not self.stop.is_set():
            try:
                s = socket.create_connection((p["host"], p["port"]), timeout=10)
                s.settimeout(5)
                auth = base64.b64encode(f"{p['user']}:{p['pw']}".encode()).decode()
                s.sendall(f"GET /{p['mount']} HTTP/1.0\r\nUser-Agent: NTRIP GaiaSeis-lossmon/1.0\r\n"
                          f"Authorization: Basic {auth}\r\n\r\n".encode())
                self.session(s)
            except OSError as err:
                print(f"[{p['name']}] connect/read error: {err}", file=sys.stderr)
            if not self.stop.is_set():
                with self.lock:
                    self.reconnects[int(time.time() // self.block)] += 1
                time.sleep(5)

    def session(self, s):
        buf = bytearray(); hdr = False; last_rx = time.time()
        while not self.stop.is_set():
            try:
                d = s.recv(8192)
            except socket.timeout:
                if time.time() - last_rx > 30:
                    print(f"[{self.p['name']}] no data for 30 s, reconnecting", file=sys.stderr); return
                continue
            if not d:
                return
            now = time.time(); last_rx = now
            buf += d
            with self.lock:
                self.bytes[int(now // self.block)] += len(d)
            if not hdr:
                i = buf.find(b"\r\n\r\n")
                if i < 0:
                    continue
                first = bytes(buf[:i]).decode(errors="replace").splitlines()[0]
                if "200" not in first:
                    print(f"[{self.p['name']}] server: {first}", file=sys.stderr); return
                del buf[:i + 4]; hdr = True
                s.sendall(gga(self.p))
            while True:
                i = buf.find(b"\xd3")
                if i < 0:
                    buf.clear(); break
                if len(buf) < i + 6:
                    del buf[:i]; break
                ln = ((buf[i + 1] & 3) << 8) | buf[i + 2]
                if len(buf) < i + 6 + ln:
                    del buf[:i]; break
                fr = bytes(buf[i:i + 3 + ln]); crc = int.from_bytes(buf[i + 3 + ln:i + 6 + ln], "big")
                if crc24(fr) != crc:
                    del buf[:i + 1]; continue
                pl = fr[3:]; mt = (pl[0] << 4) | (pl[1] >> 4)
                with self.lock:
                    self.types[mt] += 1
                    if 1071 <= mt <= 1127 and (mt % 10) in (4, 5, 6, 7):
                        self.frames[int(now // self.block)] += 1
                    if 1071 <= mt <= 1077:       # GPS MSM: 30-bit TOW ms after the 12+12-bit header
                        v = int.from_bytes(pl[:8], "big"); tow = (v >> (64 - 24 - 30)) & ((1 << 30) - 1)
                        bi = int(self.epoch_utc(tow, now) // self.block)
                        if tow not in self.epochs[bi]:
                            self.epochs[bi].add(tow); self.first_arr[tow] = now
                del buf[:i + 6 + ln]

    def rows(self, upto_block):
        out = []
        with self.lock:
            for bi in sorted(b for b in set(self.epochs) | set(self.bytes) if b <= upto_block):
                e = sorted(self.epochs.get(bi, ()))
                exp = int(self.block * 1000 / self.step)
                gaps = [(b - a) for a, b in zip(e, e[1:]) if b - a > 1.5 * self.step]
                lat = sorted(self.first_arr[t] - self.epoch_utc(t, self.first_arr[t]) for t in e)
                q = lambda v, f: v[min(int(f * len(v)), len(v) - 1)] if v else float("nan")
                out.append(dict(block=bi * self.block, profile=self.p["name"], got=len(e), expected=exp,
                                missing_pct=100.0 * max(exp - len(e), 0) / exp, gaps=len(gaps),
                                max_gap_s=(max(gaps) / 1000 if gaps else 0.0),
                                lat_med=q(lat, .5), lat_p95=q(lat, .95), lat_max=(lat[-1] if lat else float("nan")),
                                bytes=self.bytes.get(bi, 0), frames_s=self.frames.get(bi, 0) / self.block,
                                reconnects=self.reconnects.get(bi, 0)))
        return out


HDR = "block_utc,profile,got,expected,missing_pct,gaps,max_gap_s,lat_med_s,lat_p95_s,lat_max_s,bytes,msm_frames_per_s,reconnects"


def fmt(r):
    return (f"{dt.datetime.fromtimestamp(r['block'], dt.timezone.utc):%Y-%m-%d %H:%M},{r['profile']},{r['got']},{r['expected']},"
            f"{r['missing_pct']:.1f},{r['gaps']},{r['max_gap_s']:.1f},{r['lat_med']:.2f},{r['lat_p95']:.2f},{r['lat_max']:.2f},"
            f"{r['bytes']},{r['frames_s']:.1f},{r['reconnects']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("profiles", nargs="+")
    ap.add_argument("--hours", type=float, default=0.0)
    ap.add_argument("--seconds", type=float, default=0.0)
    ap.add_argument("--block", type=int, default=300)
    ap.add_argument("--rate", type=float, default=10.0, help="epochs per second of the streams")
    ap.add_argument("--start", default="", help="UTC HH:MM to wait for (today, or tomorrow if already past)")
    ap.add_argument("--toml", default="config/ntrip_profiles.toml")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    dur = a.seconds or (a.hours * 3600 if a.hours else 3600.0)
    if a.start:
        hh, mm = map(int, a.start.split(":"))
        now = dt.datetime.now(dt.timezone.utc)
        tgt = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
        if tgt <= now:
            tgt += dt.timedelta(days=1)
        print(f"waiting until {tgt:%Y-%m-%d %H:%M} UTC ({(tgt-now).total_seconds()/3600:.2f} h)", flush=True)
        while dt.datetime.now(dt.timezone.utc) < tgt:
            time.sleep(min(30, max((tgt - dt.datetime.now(dt.timezone.utc)).total_seconds(), 0.1)))
    os.makedirs("logs", exist_ok=True)
    out = a.out or f"logs/loss_monitor_{dt.datetime.now(dt.timezone.utc):%Y%m%d_%H%M%S}.csv"
    mons = [Mon(read_profile(n, a.toml), a.block, 1000.0 / a.rate) for n in a.profiles]
    for m in mons:
        print(f"{m.p['name']}  ->  {m.p['host']}:{m.p['port']}/{m.p['mount']}", flush=True)
    threads = [threading.Thread(target=m.run, daemon=True) for m in mons]
    for t in threads:
        t.start()
    stop = {"now": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("now", True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("now", True))
    t0 = time.time(); done_upto = int(t0 // a.block) - 1; allrows = []
    with open(out, "w") as f:
        f.write(HDR + "\n"); print(HDR, flush=True)
        while not stop["now"] and time.time() - t0 < dur:
            time.sleep(1)
            cur = int((time.time() - 25) // a.block) - 1     # blocks closed >= 25 s ago (late arrivals in)
            if cur > done_upto:
                for m in mons:
                    for r in m.rows(cur):
                        if r["block"] // a.block > done_upto and r["block"] // a.block >= int(t0 // a.block) + 1:
                            allrows.append(r); line = fmt(r); f.write(line + "\n"); print(line, flush=True)
                f.flush(); done_upto = cur
        for m in mons:
            m.stop.set()
        time.sleep(1)
        cur = int(time.time() // a.block) - 1
        for m in mons:
            for r in m.rows(cur):
                if r["block"] // a.block > done_upto and r["block"] // a.block >= int(t0 // a.block) + 1:
                    allrows.append(r); line = fmt(r); f.write(line + "\n"); print(line, flush=True)
    print("\n== summary (complete blocks only; the first partial block is dropped) ==")
    for m in mons:
        rs = [r for r in allrows if r["profile"] == m.p["name"]]
        if not rs:
            print(f"{m.p['name']}: no complete block"); continue
        got = sum(r["got"] for r in rs); exp = sum(r["expected"] for r in rs)
        print(f"{m.p['name']}: blocks {len(rs)}  epochs {got}/{exp}  missing {100*(exp-got)/exp:.2f} %  "
              f"worst block {max(r['missing_pct'] for r in rs):.1f} %  mean rate {sum(r['bytes'] for r in rs)/(len(rs)*a.block):.0f} B/s  "
              f"reconnects {sum(r['reconnects'] for r in rs)}")
        byh = collections.defaultdict(lambda: [0, 0])
        for r in rs:
            h = dt.datetime.fromtimestamp(r["block"], dt.timezone.utc).strftime("%H"); byh[h][0] += r["got"]; byh[h][1] += r["expected"]
        print("   missing % by UTC hour:", "  ".join(f"{h}h {100*(e-g)/e:.1f}" for h, (g, e) in sorted(byh.items())))
        print("   message types:", dict(sorted(m.types.items())))
    print("csv:", out)


if __name__ == "__main__":
    main()
