#!/usr/bin/env python3
"""Local NTRIP relay: one connection to a receiver's mount, any number of local clients (stdlib only).

A receiver's built-in caster degrades with each extra client: on UPC10Z a second GaiaSeis session cut
every client from 10.3 to 8.0 kB/s, with 18-22 % of epochs missing and latencies of minutes (2026-10-21).
This relay connects to the receiver ONCE and serves the same bytes to every local client, so the receiver
sees a single client however many sessions, probes and monitors run here (the "local relay" option of the
causes report, section 3).

    python3 tools/ntrip_relay.py UPC10Z --listen-port 2199 [--toml config/ntrip_profiles.toml] [--listen-host 127.0.0.1]

Point other profiles at caster 127.0.0.1, port 2199, mountpoint = the same mount (credentials are ignored
locally). The relay reconnects upstream by itself (5 s back-off, or after 30 s without data), keeps accepting
clients while upstream is down (they get data when it returns) and drops the oldest queued chunks for a client
that cannot keep up, so one slow client never delays another or the upstream read. It prints a status line
every 60 s. Upstream credentials are read from the TOML and never printed.
"""
import argparse, asyncio, base64, re, sys, time

QUEUE_CHUNKS = 4000          # per client, about 30 s of a 10 kB/s stream at 8 kB chunks


def read_profile(name, path):
    toml = open(path, encoding="utf-8").read()
    hdrs = list(re.finditer(r'(?m)^\[profiles\."?([^"\]]*)"?\]\n', toml))
    m = next((h for h in hdrs if h.group(1) == name), None)
    if m is None:
        sys.exit(f"profile {name!r} not found in {path}")
    sec = toml[m.end():]
    nxt = re.search(r'(?m)^\[', sec)
    sec = sec[:nxt.start()] if nxt else sec

    def g(k, default=None):
        r = re.search(r'^\s*%s\s*=\s*"?([^"\n]*)"?' % k, sec, re.M)
        return r.group(1).strip() if r else default
    return dict(host=g("caster"), port=int(g("port")), mount=g("mountpoint"), user=g("user", ""), pw=g("password", ""),
                lat=float(g("gga_lat_deg", 0)), lon=float(g("gga_lon_deg", 0)), hgt=float(g("gga_height_m", 0)))


def gga(p):
    import datetime as dt
    u = dt.datetime.now(dt.timezone.utc); la, lo = abs(p["lat"]), abs(p["lon"])
    body = (f"GPGGA,{u:%H%M%S}.00,{int(la):02d}{(la-int(la))*60:07.4f},{'N' if p['lat']>=0 else 'S'},"
            f"{int(lo):03d}{(lo-int(lo))*60:07.4f},{'E' if p['lon']>=0 else 'W'},1,10,1.0,{p['hgt']:.1f},M,0.0,M,,")
    c = 0
    for ch in body:
        c ^= ord(ch)
    return f"${body}*{c:02X}\r\n".encode()


class Relay:
    def __init__(self, prof):
        self.p = prof
        self.clients = set()                 # asyncio.Queue per connected client
        self.up_bytes = 0; self.up_connected = False; self.reconnects = 0; self.dropped = 0
        self.t_last_rx = 0.0

    def publish(self, chunk):
        for q in self.clients:
            if q.full():
                try: q.get_nowait(); self.dropped += 1
                except asyncio.QueueEmpty: pass
            q.put_nowait(chunk)

    async def upstream(self):
        p = self.p
        while True:
            try:
                r, w = await asyncio.wait_for(asyncio.open_connection(p["host"], p["port"]), 10)
                auth = base64.b64encode(f"{p['user']}:{p['pw']}".encode()).decode()
                w.write(f"GET /{p['mount']} HTTP/1.0\r\nUser-Agent: NTRIP GaiaSeis-relay/1.0\r\n"
                        f"Authorization: Basic {auth}\r\n\r\n".encode()); await w.drain()
                buf = b""
                while b"\r\n\r\n" not in buf:
                    d = await asyncio.wait_for(r.read(4096), 10)
                    if not d: raise ConnectionError("closed before the response header")
                    buf += d
                head, _, rest = buf.partition(b"\r\n\r\n")
                first = head.decode(errors="replace").splitlines()[0]
                if "200" not in first: raise ConnectionError("upstream said: " + first)
                w.write(gga(p)); await w.drain()
                self.up_connected = True; self.t_last_rx = time.time()
                print(f"[relay] upstream connected ({first})", flush=True)
                if rest: self.publish(rest)
                while True:
                    d = await asyncio.wait_for(r.read(8192), 30)
                    if not d: raise ConnectionError("upstream closed the stream")
                    self.up_bytes += len(d); self.t_last_rx = time.time(); self.publish(d)
            except Exception as err:
                print(f"[relay] upstream error: {err!r}; reconnecting in 5 s", flush=True)
            self.up_connected = False; self.reconnects += 1
            await asyncio.sleep(5)

    async def client(self, r, w):
        peer = w.get_extra_info("peername")
        q = asyncio.Queue(QUEUE_CHUNKS)
        try:
            buf = b""
            while b"\r\n\r\n" not in buf:
                d = await asyncio.wait_for(r.read(4096), 10)
                if not d: return
                buf += d
            w.write(b"HTTP/1.1 200 OK\r\nContent-Type: gnss/data\r\nConnection: close\r\n\r\n"); await w.drain()
            self.clients.add(q)
            print(f"[relay] client {peer} connected ({len(self.clients)} now)", flush=True)

            async def swallow():             # GGA etc. from the client: read and discard, detect disconnect
                while await r.read(4096): pass
            sw = asyncio.create_task(swallow())
            while not sw.done():
                try: chunk = await asyncio.wait_for(q.get(), 1.0)
                except asyncio.TimeoutError: continue
                w.write(chunk); await asyncio.wait_for(w.drain(), 30)
        except Exception:
            pass
        finally:
            self.clients.discard(q)
            print(f"[relay] client {peer} gone ({len(self.clients)} left)", flush=True)
            try: w.close()
            except Exception: pass

    async def status(self):
        last = 0; t0 = time.time()
        while True:
            await asyncio.sleep(60)
            rate = (self.up_bytes - last) / 60; last = self.up_bytes
            print(f"[relay] {time.strftime('%H:%M:%S', time.gmtime())}Z upstream {'up' if self.up_connected else 'DOWN'} "
                  f"{rate:.0f} B/s  clients {len(self.clients)}  reconnects {self.reconnects}  dropped chunks {self.dropped}", flush=True)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("profile"); ap.add_argument("--toml", default="config/ntrip_profiles.toml")
    ap.add_argument("--listen-port", type=int, default=2199); ap.add_argument("--listen-host", default="127.0.0.1")
    a = ap.parse_args()
    rel = Relay(read_profile(a.profile, a.toml))
    srv = await asyncio.start_server(rel.client, a.listen_host, a.listen_port)
    print(f"[relay] {a.profile} -> {rel.p['host']}:{rel.p['port']}/{rel.p['mount']}  serving {a.listen_host}:{a.listen_port}", flush=True)
    await asyncio.gather(rel.upstream(), rel.status(), srv.serve_forever())


if __name__ == "__main__":
    try: asyncio.run(main())
    except KeyboardInterrupt: pass
