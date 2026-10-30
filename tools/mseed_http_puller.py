#!/usr/bin/env python3
"""
Pull GaiaSeis miniSEED over HTTP into a local directory, continuously.

Runs on the CONSUMER machine (e.g. seis2k). Stdlib only - no obspy, no
requests, nothing to install.

GaiaSeis serves three relevant endpoints from its plot web server:

  /mseed.json            list of files, with size + a "live" flag
  /mseed/download?f=NAME whole file, Content-Length, terminates
  /mseed/live?f=NAME     the file from byte 0, then tailed forever

This uses /mseed/live. That endpoint never returns EOF on its own, which
is why a tool that reads-to-EOF-then-parses (pandas, wget, a plain
SeisComP file reader) appears to hang on it: the bytes arrive, but the
end never does. Here that is the point - we consume incrementally and
append to a local file, which slarchive/scart/obspy can then read as an
ordinary growing SDS-style file.

Resume is by byte offset: the stream always restarts at 0, so whatever we
already hold locally is skipped. Both sides are 512-byte record aligned
and the server only ever appends, so the offsets line up exactly.

Usage:
  ./mseed_http_puller.py --host gaiaseis.example.org --port 8766 --out ./mseed_in
  ./mseed_http_puller.py --host gaiaseis.example.org --port 8766 --out ./in \
      --match CL.PAT0 --once

Options:
  --host/--port   GaiaSeis web server (PAT01Z=8766, NOA10Z=8765)
  --out           local directory to write into
  --match         substring filter on filename (repeatable)
  --live-only     only files GaiaSeis still holds open
  --rescan        seconds between /mseed.json rescans (default 60)
  --once          pull current contents and exit, do not tail
"""

import argparse
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

RECORD_LEN = 512
READ_TIMEOUT = 600   # s without data before reconnecting; must exceed the record cadence
RETRY_MIN, RETRY_MAX = 2.0, 60.0


def log(msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


def http_json(base, path, timeout=30):
    with urllib.request.urlopen(base + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def list_files(base, matches, live_only):
    info = http_json(base, "/mseed.json")
    if not info.get("exists"):
        raise RuntimeError(f"server reports no miniSEED dir: {info.get('dir')}")
    out = []
    for f in info.get("files", []):
        if live_only and not f.get("live"):
            continue
        if matches and not any(m in f["name"] for m in matches):
            continue
        out.append(f)
    return out


def pull_one(base, name, out_dir, once, stop):
    """Stream one file, resuming by byte offset, reconnecting as needed."""
    dest = os.path.join(out_dir, name)
    backoff = RETRY_MIN
    while not stop.is_set():
        have = os.path.getsize(dest) if os.path.exists(dest) else 0

        # If the server file is now SHORTER than ours, GaiaSeis rotated or
        # flushed it (Flush data deletes the current .mseed). Our offsets no
        # longer refer to the same bytes, so archive ours and start clean.
        try:
            remote = next((f for f in list_files(base, [name], False)
                           if f["name"] == name), None)
            if remote and remote["size"] < have:
                aside = f"{dest}.{int(time.time())}.rotated"
                os.rename(dest, aside)
                log(f"[{name}] server file shrank ({remote['size']} < {have}); "
                    f"kept ours as {os.path.basename(aside)}")
                have = 0
        except Exception as e:
            log(f"[{name}] rescan before connect failed: {e}")

        # `from=` makes the server start at our offset instead of re-sending
        # the whole file (a 200 MB day file was re-sent on every reconnect
        # before). The read timeout must exceed the record cadence: a 1 Hz
        # channel yields one 512-byte record every ~2 minutes, and a 60 s
        # timeout made this client reconnect every minute, which leaked a
        # server task per attempt (2026-09-12).
        url = (base + "/mseed/live?f=" + urllib.parse.quote(name, safe="")
               + "&from=" + str(have))
        try:
            with urllib.request.urlopen(url, timeout=READ_TIMEOUT) as r:
                # read1(), never read(): on a never-ending chunked stream
                # read(n) blocks until it has exactly n bytes, so it hangs
                # forever whenever fewer than n are outstanding. read1()
                # returns whatever has already arrived.
                log(f"[{name}] streaming (resumed at {have} bytes)")
                backoff = RETRY_MIN
                pending = b""
                with open(dest, "ab", buffering=0) as fh:
                    while not stop.is_set():
                        chunk = r.read1(65536)
                        if not chunk:
                            break
                        pending += chunk
                        # Only ever write whole 512-byte records.
                        n = (len(pending) // RECORD_LEN) * RECORD_LEN
                        if n:
                            fh.write(pending[:n])
                            pending = pending[n:]
                        if once and not pending:
                            # --once: stop as soon as we are caught up.
                            remote = next((f for f in list_files(base, [name], False)
                                           if f["name"] == name), None)
                            if remote and fh.tell() >= remote["size"]:
                                log(f"[{name}] caught up at {fh.tell()} bytes")
                                return
        except Exception as e:
            if stop.is_set():
                return
            log(f"[{name}] {type(e).__name__}: {e}; retry in {backoff:.0f}s")
            stop.wait(backoff)
            backoff = min(backoff * 2, RETRY_MAX)
            continue

        if once:
            return
        log(f"[{name}] stream closed by server; reconnecting")
        stop.wait(RETRY_MIN)


def main():
    ap = argparse.ArgumentParser(description="Pull GaiaSeis miniSEED over HTTP.")
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--match", action="append", default=[])
    ap.add_argument("--live-only", action="store_true")
    ap.add_argument("--rescan", type=float, default=60.0)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()

    base = f"http://{a.host}:{a.port}"
    os.makedirs(a.out, exist_ok=True)
    stop = threading.Event()
    workers = {}

    try:
        while not stop.is_set():
            try:
                files = list_files(base, a.match, a.live_only)
            except Exception as e:
                log(f"rescan failed: {e}; retrying in {a.rescan:.0f}s")
                stop.wait(a.rescan)
                continue

            if not files:
                log("no matching files on the server yet")

            for f in files:
                name = f["name"]
                if name in workers and workers[name].is_alive():
                    continue
                t = threading.Thread(target=pull_one, name=name,
                                     args=(base, name, a.out, a.once, stop),
                                     daemon=True)
                workers[name] = t
                t.start()
                log(f"[{name}] worker started ({f['size']} bytes on server)")

            if a.once:
                for t in workers.values():
                    t.join()
                return 0
            # Rescan so a UTC day rollover (new filename) is picked up.
            stop.wait(a.rescan)
    except KeyboardInterrupt:
        log("stopping")
        stop.set()
        for t in workers.values():
            t.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
