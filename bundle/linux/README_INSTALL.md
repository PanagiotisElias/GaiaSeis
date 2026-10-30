# GaiaSeis: installation on Linux

Two ways to run GaiaSeis on Linux:

| | What you get | Needs Julia? | Where it comes from |
|---|---|---|---|
| **A. Script install** | The source tree + a launcher, precompiled | **Yes** (≥ 1.10) | `install.sh` in this bundle |
| **B. Standalone binary** | A single `bin/gaiaseis` with the Julia runtime and GTK baked in | **No** | you build it once with `build-app/build-app.sh` |

**A** is the one to start with. **B** is for deploying to machines where
you would rather not install Julia (the build itself still needs Julia,
and it has to run on Linux because Julia cannot cross-compile.

---

## A. Script install

### 1. Prerequisites

- A 64-bit Linux with a graphical session (X11 or Wayland).
- **Julia ≥ 1.10**, via juliaup:

  ```bash
  curl -fsSL https://install.julialang.org | sh
  ```

  Open a new shell afterwards so `julia` is on `PATH`.

Every Julia package, GTK4 included, is pulled in by the installer.
Gtk4.jl ships its own GTK libraries as artifacts, so distribution GTK
packages are **not** required. If you want the system ones anyway
(some themes and input methods integrate better):

```bash
sudo apt install -y libgtk-4-1 libcairo2 libpango-1.0-0
```

### 2. Install

```bash
tar xzf GaiaSeis-<version>-linux.tar.gz    # or: unzip GaiaSeis-<version>-linux.zip
cd GaiaSeis-<version>-linux
./install.sh
```

If your extractor dropped the executable bit (some graphical archive
managers do; `unzip` on the command line preserves it):

```bash
chmod +x install.sh launch.sh uninstall.sh
```

The installer will:

- locate Julia and check its version;
- copy the tree to `~/.local/share/GaiaSeis`;
- run `Pkg.instantiate()` + `Pkg.precompile()` for GaiaSeis and for the
  GaiaVario engine (5–10 min the first time);
- install the icon into `~/.local/share/icons/hicolor`, write
  `~/.local/share/applications/gaiaseis.desktop`, and link
  `~/.local/bin/gaiaseis`.

Options:

```bash
./install.sh --prefix /opt/gaiaseis    # system-wide (run under sudo)
./install.sh --no-desktop              # no menu entry, icon or symlink
./install.sh --no-precompile           # skip the slow precompile step
```

Re-running the installer replaces the program directory. It does **not**
touch your data (see below).

### 3. Where things live

The program directory is treated as read-only, so an upgrade or a
system-wide install cannot collide with your streams:

| | Path | Override |
|---|---|---|
| Program | `~/.local/share/GaiaSeis` | `install.sh --prefix` |
| Logs, miniSEED, profile TOML | `~/.local/state/gaiaseis` | `GAIASEIS_DATA_DIR` |
| Console log (stdout+stderr) | `~/.local/state/gaiaseis/logs/console_<timestamp>.log` | `GAIASEIS_CONSOLE_LOG=0` disables |

On first run the profile TOML is seeded from the bundled template into
`~/.local/state/gaiaseis/config/ntrip_profiles.toml`; from then on it is
yours and no upgrade overwrites it.

> The bundled template carries **no NTRIP username or password** and no
> caster of ours: fill in your caster, mount point and credentials through
> the GUI's profile editor.
>
> For the maintainer: `make-bundle.sh` refuses to ship editor/backup scratch
> (`*.bak`, `*.bak<N>`, `*.bak_*`, `*.pre_*`, `*~`, `*.orig`, `*.rej`,
> `*.swp`), scans **every** staged file except Markdown for a populated
> `password = "..."` field and every file for the addresses of the
> development installation; a hit aborts the build. Keep working backups of
> the profile TOML *outside* the source tree.

### 4. The displacement engine

The solution is computed by an **engine plug-in** selected per profile
(`engine = "..."` in the profile TOML, or the Engine field of the profile
editor).

- **GaiaVario** (`engine = "gaiavario"`, the default) is the variometric
  engine written for GaiaSeis. It ships in this bundle as the package
  `GaiaVario.jl/` beside `GaiaSeis/`; `launch.sh` puts it on the Julia load
  path, so nothing needs configuring. Its observable is chosen with
  `engine_mode` (`l1gf`, `single`, `dual`, `mean`).
- **PPPHVA** (`engine = "ppphva"`), the Julia translation of the PPPH-VA
  toolkit, is **not included** in the public bundle and is not needed. A
  bundle made with `make-bundle.sh --with-ppphva` carries it as
  `PPPH_VA/PPPHVA.jl/`, where the platform finds it on its own. A profile
  that selects `ppphva` without the package present fails to start with a
  message saying so; select `gaiavario` instead.
- Another engine package can be used by setting `engine` to its name and
  `engine_path` to its directory; see the manual's engine chapter.

An ANTEX file (antenna phase-centre corrections) is third-party data and is
not part of the bundle. Download the one you need (for example from the IGS)
and point the profile's `antex_file` at it; without one the solution runs
without phase-centre offsets.

### 5. Launch

Any of:

- the **GaiaSeis** entry in your application menu;
- `gaiaseis` from a terminal (if `~/.local/bin` is on `PATH`);
- `~/.local/share/GaiaSeis/launch.sh`.

Extra launcher modes:

```bash
gaiaseis --repl      # keep an interactive Julia REPL alongside the GUI
gaiaseis --check     # headless: load GaiaSeis and the engine, print the paths and the engines, exit
```

Headless with the web page only (no Gtk): run
`examples/stream_and_serve.jl [port]` from the installed source tree with
the same Julia flags the launcher uses (`-t auto --heap-size-hint=8G
--project=GaiaSeis`) and `JULIA_LOAD_PATH="@:<install>/GaiaVario.jl:@stdlib"`
so the engine is found.

**SeedLink service (optional).** To serve the solution to SeisComP / ObsPy
over SeedLink, run `tools/ringserver/install.sh` once (downloads and builds
EarthScope ringserver, installs the `gaiaseis-ringserver` systemd user unit,
SeedLink on port 18000), run `loginctl enable-linger $USER`, and set
`datalink_host = "127.0.0.1"` in the profile. Verify with
`python3 tools/seedlink_check.py`. Details: the manual and
`docs/GaiaSeis_SeisComP_Integration.md`.

### 6. Uninstall

```bash
~/.local/share/GaiaSeis/uninstall.sh              # keeps your data
~/.local/share/GaiaSeis/uninstall.sh --purge      # deletes it too
~/.local/share/GaiaSeis/uninstall.sh --keep-user-data ~/backup
```

Julia, the depot under `~/.julia`, and anything outside the two paths
above are left alone.

---

## B. Standalone binary

```bash
./build-app/build-app.sh --tar
```

Run this **on Linux**, on the oldest distribution you intend to deploy
to: the binary requires a glibc at least as new as the build machine's.
It needs Julia ≥ 1.10, a C compiler (`build-essential`), 10–30 minutes
and a few GB of RAM. The GaiaVario engine is compiled into the binary;
`--with-ppphva [path]` adds PPPHVA when you have it.

Result:

```
dist/gaiaseis-app/
├── bin/gaiaseis          the executable; copy the whole directory, not just this
├── lib/                  Julia runtime, sysimage, GTK artifacts
├── share/gaiaseis/       assets, config template, licences
└── gaiaseis.desktop      copy to ~/.local/share/applications/ to register
```

Deploy by copying `gaiaseis-app/` anywhere (`/opt/gaiaseis-app` is a good
default) and running `bin/gaiaseis`. The tree must stay intact: the
binary finds its data through `Sys.BINDIR`, so `bin/gaiaseis` cannot be
copied out on its own or symlinked from a `bin` directory elsewhere. Make
a wrapper instead:

```bash
sudo tee /usr/local/bin/gaiaseis >/dev/null <<'EOF'
#!/bin/sh
exec /opt/gaiaseis-app/bin/gaiaseis "$@"
EOF
sudo chmod +x /usr/local/bin/gaiaseis
```

Flags: `--root <dir>`, `--data-dir <dir>`, `--version`, `--help`. It
honours the same `GAIASEIS_ROOT` / `GAIASEIS_DATA_DIR` /
`GAIASEIS_PROFILES` variables as the script install, and defaults its data
to `~/.local/state/gaiaseis` as well.

---

## Migrating a Windows install

The profile TOML is portable except for three fields that hold absolute
Windows paths: `antex_file`, `miniseed_csv_path`, `miniseed_mseed_dir`.
Copy `%LOCALAPPDATA%\GaiaSeis\GaiaSeis\config\ntrip_profiles.toml` to
`~/.local/state/gaiaseis/config/` and rewrite them:

```bash
sed -i -E 's|"[A-Za-z]:\\\\[^"]*\\\\([^"\\]+)"|"./\1"|g' \
    ~/.local/state/gaiaseis/config/ntrip_profiles.toml
```

Leaving them empty is also fine: an empty `antex_file` runs without
phase-centre corrections, and an empty miniSEED directory disables that sink.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `bad interpreter: /usr/bin/env bash^M` | The scripts were checked out with CRLF endings. `sed -i 's/\r$//' *.sh` |
| `./install.sh: Permission denied` | The archive was unpacked by a tool that drops the executable bit. `chmod +x install.sh launch.sh uninstall.sh` |
| `julia: command not found` | juliaup installed but the shell is stale: open a new terminal, or `source ~/.bashrc` |
| Window never appears, no error | No display. Check `echo $DISPLAY $WAYLAND_DISPLAY`. Over SSH use `ssh -X`; headless, use `xvfb-run gaiaseis` |
| GUI stops repainting / ignores clicks, but the stream keeps writing | An exception killed the GTK event loop. The backtrace is in the newest `logs/console_*.log`. Restart the app; the loop cannot be revived. Callbacks are guarded, so check the console for `GUI callback raised` and report the backtrace |
| `Gtk-WARNING: cannot open display` | Same, or a Wayland session refusing X11 clients: `GDK_BACKEND=x11 gaiaseis` sometimes helps |
| Menu entry missing after install | `update-desktop-database ~/.local/share/applications` |
| Icon shows as a generic cog | `gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor`, then log out and back in |
| `engine "gaiavario": package GaiaVario could not be loaded` | The engine is not on the load path: start through `launch.sh` / `gaiaseis`, or set `engine_path` in the profile to the `GaiaVario.jl` directory of the install |
| `the "ppphva" engine is not available` | The profile asks for the PPPHVA engine, which is not in this bundle. Set `engine = "gaiavario"` |
| No solution, few satellites | The variometric solution needs enough satellites with continuous lock; enable the other constellations in the profile and check the receiver's elevation mask |
| Web server "address in use" | Change the web port in the GUI |
| Compiled binary: `libgtk-4.so.1: cannot open shared object file` | The app was built without lazy artifacts, or `lib/` was not copied along with `bin/`. Rebuild with `build-app.sh` and copy the whole directory |
| Compiled binary: `version GLIBC_2.xx not found` | Built on a newer distribution than the target. Rebuild on the oldest one you deploy to |

---

## Bundle contents

```
GaiaSeis-<version>-linux/     (from the .zip or the .tar.gz, same tree)
├── GaiaSeis/                 GaiaSeis source tree (Julia package)
│   ├── src/                  Decoder + bridge + GUI + web view
│   ├── GaiaSeisEngineAPI/    The engine plug-in interface (Julia package)
│   ├── examples/gui.jl       Launcher script; stream_and_serve.jl, headless_stream.jl
│   ├── tools/                mseed_http_puller.py (pull miniSEED over HTTP),
│   │                         rtcm_raw_probe.py (is the stream complete?),
│   │                         spp_estimate.jl (a-priori position),
│   │                         metrics_compare.py, ringserver/ (SeedLink service),
│   │                         seedlink_check.py (is the SeedLink feed alive?)
│   ├── docs/                 Manual, operator guides and reports (CC BY-NC 4.0, see docs/LICENSE-DOCS)
│   ├── docs/assets/          Logos + freedesktop icon tree
│   ├── config/               Profile TOML template (no credentials)
│   ├── test/                 Offline tests
│   ├── Project.toml, Manifest.toml
│   ├── LICENSE               AGPL-3.0-only
│   └── NOTICE.md
├── GaiaVario.jl/             The GaiaVario displacement engine (Julia package)
│   ├── src/, test/
│   ├── Project.toml, Manifest.toml
│   └── LICENSE
├── install.sh                Installer
├── launch.sh                 Launcher (also installed as `gaiaseis`)
├── uninstall.sh              Uninstaller
├── gaiaseis.desktop.in       Desktop-entry template
├── build-app/                PackageCompiler kit for the standalone binary
├── LICENSE, NOTICE.md        Licence of GaiaSeis and notices
├── THIRD_PARTY_LICENSES.md   Licences of the Julia packages, Julia, GTK, ringserver
└── README_INSTALL.md         This file
```

---

## Licences & citation

GaiaSeis, Copyright (C) 2026 Panagiotis Elias, Deforming Gaia Lab,
Department of Geology, University of Patras.

- **Code** (`GaiaSeis/`, `GaiaSeisEngineAPI/`): GNU Affero General Public
  License, version 3 only (AGPL-3.0-only), file `LICENSE`. If you run a
  modified GaiaSeis as a network service, the AGPL requires you to offer
  its source to the users of that service.
- **GaiaVario engine** (`GaiaVario.jl/`): see `GaiaVario.jl/LICENSE`.
- **Documents** (`GaiaSeis/docs/`): Creative Commons Attribution-NonCommercial
  4.0 International (CC BY-NC 4.0), file `GaiaSeis/docs/LICENSE-DOCS`.
- **Third-party software**: `THIRD_PARTY_LICENSES.md` lists every Julia
  package the installer pulls in with its licence text, plus the Julia
  runtime (MIT), the GTK 4 / GLib / Cairo / Pango libraries
  (LGPL-2.1-or-later, dynamically linked) and ringserver (Apache-2.0,
  installed separately by `tools/ringserver/install.sh`).

The complete corresponding source of this bundle is the tagged release at
https://github.com/PanagiotisElias/GaiaSeis and
https://github.com/PanagiotisElias/GaiaVario.jl .

If you use GaiaSeis in scientific work, please cite:

> Elias P. (2026). *GaiaSeis: GNSS-based real-time seismogeodesy with a
> variometric engine.* Deforming Gaia Lab, University of Patras, Greece.

When the optional PPPHVA engine is used, please also cite the upstream
PPPH toolkit:

> Bahadur B. & Nohutcu M., "PPPH: a MATLAB-based software for
> multi-GNSS precise point positioning analysis", *GPS Solutions* 22
> (2018), Art. 113.
