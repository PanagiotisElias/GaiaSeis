#!/usr/bin/env python3
"""Minimal SeedLink v3 client to verify the GaiaSeis ringserver feed, no ObsPy.

    python3 tools/seedlink_check.py [host] [port] [seconds] [NET] [STA]

Connects, requests the station's streams, and prints every 512-byte record
it receives (channel, start time, samples) for `seconds`, then the rate.
Exit 0 if at least one record for each of LNN/LNE/LNZ arrived, else 1.
"""
import socket, struct, sys, time

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18000
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 30
net = sys.argv[4] if len(sys.argv) > 4 else "CL"
sta = sys.argv[5] if len(sys.argv) > 5 else "UPA10"

def cmd(s, line, expect=True):
    s.sendall((line + "\r\n").encode())
    if expect:
        r = s.recv(256)
        return r.decode(errors="replace").strip()

s = socket.create_connection((host, port), timeout=10)
print("HELLO ->", cmd(s, "HELLO").replace("\r\n", " | "))
print(f"STATION {sta} {net} ->", cmd(s, f"STATION {sta} {net}"))
print("SELECT ->", cmd(s, "SELECT ?LN?.D"))
print("DATA ->", cmd(s, "DATA"))
s.sendall(b"END\r\n")

seen = {}
first = {}
deadline = time.time() + secs
s.settimeout(max(5, secs))
buf = b""
nrec = 0
while time.time() < deadline:
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    buf += chunk
    while len(buf) >= 520:
        pkt, buf = buf[:520], buf[520:]
        if pkt[:2] != b"SL":
            # resync: drop a byte
            buf = pkt[1:] + buf
            continue
        seq = pkt[2:8].decode(errors="replace")
        rec = pkt[8:]
        sta_r = rec[8:13].decode().strip(); loc = rec[13:15].decode().strip()
        cha = rec[15:18].decode().strip(); net_r = rec[18:20].decode().strip()
        year, doy, hh, mm, ss, _, tms = struct.unpack(">HHBBBBH", rec[20:30])
        nsamp = struct.unpack(">H", rec[30:32])[0]
        t = f"{year}.{doy:03d} {hh:02d}:{mm:02d}:{ss:02d}.{tms//10:03d}"
        nrec += 1
        seen[cha] = seen.get(cha, 0) + 1
        first.setdefault(cha, time.time())
        if nrec <= 12 or nrec % 50 == 0:
            print(f"seq {seq}  {net_r}.{sta_r}.{loc}.{cha}  start {t} UTC  {nsamp} samples")
s.close()
el = secs
print(f"\n{nrec} records in {el:.0f} s: " + ", ".join(f"{k}={v}" for k, v in sorted(seen.items())))
ok = all(seen.get(c, 0) > 0 for c in ("LNN", "LNE", "LNZ"))
print("OK: all three channels streaming" if ok else "FAIL: missing channels")
sys.exit(0 if ok else 1)
