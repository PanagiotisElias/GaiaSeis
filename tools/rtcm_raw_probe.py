#!/usr/bin/env python3
"""Decoder-independent NTRIP/RTCM3 stream probe (stdlib only).

Connects to the obs caster of one profile from config/ntrip_profiles.toml,
CRC-checks every RTCM3 frame and reports, for a fixed duration:

  * message-type histogram (is 1005/1006 present? 1008/1033 cadence?)
  * the station ECEF from 1005/1006, converted to lat/lon/h
  * GPS MSM epoch completeness from the 30-bit TOW (missing %, gap list)

Use it to tell a receiver/caster problem from a GaiaSeis problem: if THIS
counts missing epochs, GaiaSeis cannot invent them.

    python3 tools/rtcm_raw_probe.py UPA10Z            # 60 s
    python3 tools/rtcm_raw_probe.py "ΝΟΑ10Ζ" 180      # 3 min
    python3 tools/rtcm_raw_probe.py UPA10Z 60 /path/to/ntrip_profiles.toml

Credentials are read from the TOML and never printed. A GGA sentence built
from the profile's gga_* fields is sent once after connect (harmless for
plain station mounts, required by VRS mounts).
"""
import base64, collections, datetime, math, re, socket, sys, time

def main():
    prof = sys.argv[1] if len(sys.argv) > 1 else "UPA10Z"
    dur  = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    path = sys.argv[3] if len(sys.argv) > 3 else "config/ntrip_profiles.toml"
    toml = open(path, encoding="utf-8").read()
    # Header match is on the exact name, then on an ASCII prefix so that
    # look-alike Greek letters in a name (PAT01Ζ) still resolve.
    hdrs = list(re.finditer(r'(?m)^\[profiles\."?([^"\]]*)"?\]\n', toml))
    m = next((h for h in hdrs if h.group(1) == prof), None) or \
        next((h for h in hdrs if h.group(1).startswith(prof[:5])), None)
    if m is None:
        sys.exit(f"profile {prof!r} not found in {path}")
    sec = toml[m.end():]; nxt = re.search(r'(?m)^\[', sec); sec = sec[:nxt.start()] if nxt else sec
    def g(k, default=None):
        r = re.search(r'^\s*%s\s*=\s*"?([^"\n]*)"?' % k, sec, re.M)
        return r.group(1).strip() if r else default
    host, port, mp = g("caster"), int(g("port")), g("mountpoint")
    user, pw = g("user", ""), g("password", "")
    lat, lon, hgt = float(g("gga_lat_deg", 0)), float(g("gga_lon_deg", 0)), float(g("gga_height_m", 0))
    print(f"profile {m.group(1)}  ->  {host}:{port}/{mp}  ({dur:.0f} s)")

    def gga():
        u = datetime.datetime.now(datetime.timezone.utc); la, lo = abs(lat), abs(lon)
        body = (f"GPGGA,{u:%H%M%S}.00,{int(la):02d}{(la-int(la))*60:07.4f},{'N' if lat>=0 else 'S'},"
                f"{int(lo):03d}{(lo-int(lo))*60:07.4f},{'E' if lon>=0 else 'W'},1,10,1.0,{hgt:.1f},M,0.0,M,,")
        c = 0
        for ch in body: c ^= ord(ch)
        return f"${body}*{c:02X}\r\n"

    def crc24(d):
        c = 0
        for b in d:
            c ^= b << 16
            for _ in range(8):
                c <<= 1
                if c & 0x1000000: c ^= 0x1864CFB
        return c & 0xFFFFFF

    def ecef_to_plh(X, Y, Z):
        a, e2 = 6378137.0, 6.69437999014e-3
        lo = math.atan2(Y, X); pr = math.hypot(X, Y); la = math.atan2(Z, pr * (1 - e2)); h = 0.0
        for _ in range(8):
            N = a / math.sqrt(1 - e2 * math.sin(la) ** 2); h = pr / math.cos(la) - N
            la = math.atan2(Z, pr * (1 - e2 * N / (N + h)))
        return math.degrees(la), math.degrees(lo), h

    try:
        s = socket.create_connection((host, port), timeout=10)
    except OSError as err:
        sys.exit(f"cannot connect to {host}:{port}: {err} (caster down / port closed / firewall)")
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    s.sendall(f"GET /{mp} HTTP/1.0\r\nUser-Agent: NTRIP GaiaSeis-rawprobe/1.0\r\nAuthorization: Basic {auth}\r\n\r\n".encode())
    buf = b""; t0 = time.time(); hdr = False; epochs = set(); types = collections.Counter(); nbytes = 0; station = None
    while time.time() - t0 < dur:
        try: d = s.recv(4096)
        except socket.timeout: continue
        except OSError as err:
            print(f"connection lost after {time.time()-t0:.1f} s: {err}"); break
        if not d: print("server closed the connection"); break
        nbytes += len(d); buf += d
        if not hdr:
            i = buf.find(b"\r\n\r\n")
            if i < 0: continue
            print("server:", buf[:i].decode(errors="replace").splitlines()[0]); buf = buf[i+4:]; hdr = True
            s.sendall(gga().encode())
        while True:
            i = buf.find(b"\xd3")
            if i < 0: buf = b""; break
            if len(buf) < i + 6: buf = buf[i:]; break
            ln = ((buf[i+1] & 3) << 8) | buf[i+2]
            if len(buf) < i + 6 + ln: buf = buf[i:]; break
            fr = buf[i:i+3+ln]; crc = int.from_bytes(buf[i+3+ln:i+6+ln], "big")
            if crc24(fr) != crc: buf = buf[i+1:]; continue
            p = fr[3:]; mt = (p[0] << 4) | (p[1] >> 4); types[mt] += 1
            if mt in (1005, 1006):
                bits = int.from_bytes(p, "big"); nb = len(p) * 8
                def sb(off, n):
                    v = (bits >> (nb - off - n)) & ((1 << n) - 1); return v - (1 << n) if v >> (n - 1) else v
                X, Y, Z = sb(34, 38) * 1e-4, sb(74, 38) * 1e-4, sb(114, 38) * 1e-4
                station = (X, Y, Z) + ecef_to_plh(X, Y, Z)
            if 1071 <= mt <= 1077:   # GPS MSM: 30-bit TOW ms after the 12+12-bit header
                v = int.from_bytes(p[:8], "big"); epochs.add((v >> (64 - 24 - 30)) & ((1 << 30) - 1))
            buf = buf[i+6+ln:]
    print(f"bytes={nbytes}  types={dict(sorted(types.items()))}")
    if station:
        print("1005/1006 station: X=%.4f Y=%.4f Z=%.4f  ->  lat=%.7f lon=%.7f h=%.3f" % station)
        print("   profile GGA seed: lat=%.7f lon=%.7f h=%.3f" % (lat, lon, hgt))
    else:
        print("no 1005/1006 seen (bridge will seed the position from the profile GGA fields)")
    e = sorted(epochs)
    if len(e) > 1:
        span = (e[-1] - e[0]) / 1000; step = min(b - a for a, b in zip(e, e[1:])) or 100
        exp = int(round(span * 1000 / step)) + 1
        print(f"GPS MSM epochs: got={len(e)} expected={exp} over {span:.1f} s  ->  missing={exp-len(e)} ({100*(exp-len(e))/exp:.1f} %)")
        gaps = [(a, b) for a, b in zip(e, e[1:]) if b - a > 1.5 * step]
        print("gaps:", len(gaps), " first:", [(round(a % 86400000 / 1000, 1), (b - a) / 1000) for a, b in gaps[:8]])

if __name__ == "__main__":
    main()
