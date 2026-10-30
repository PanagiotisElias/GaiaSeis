# GaiaSeis - Installation (Windows)

This bundle contains everything needed to run GaiaSeis on a Windows
machine that has the **Julia language** (≥ 1.10) installed.

---

## 1. Prerequisites

- **Windows 10 or 11** (64-bit).
- **Julia ≥ 1.10**. The recommended installer is **juliaup**:

  ```powershell
  winget install --id JuliaLang.Juliaup -e
  ```

  Restart PowerShell after install so `julia` is on `PATH`.
  Alternatively, download a stand-alone build from
  https://julialang.org/downloads/.

No other dependencies are required up-front - every Julia package the
software needs (GTK4, HTTP, etc.) is pulled in automatically by the
installer.

---

## 2. Install

1. Unzip this bundle anywhere convenient (e.g. `%USERPROFILE%\Downloads\GaiaSeis-0.2.0\`).
2. **Double-click `install.bat`.**

   A console window opens, runs the installer, and closes when finished.

   - The `.bat` is a thin wrapper that invokes PowerShell with
     `-ExecutionPolicy Bypass` so you don't have to lower Windows'
     default policy. The bypass is for that single invocation only -
     no system setting is changed.

   The installer will:

   - locate Julia on `PATH` (and stop with instructions if it's missing);
   - copy the source tree to `%LOCALAPPDATA%\GaiaSeis\`;
   - call `Pkg.instantiate()` + `Pkg.precompile()` to resolve and pre-
     build every dependency (first run takes 5-10 min);
   - create a **Start-Menu** entry and a **Desktop** shortcut, both
     pointing at `launch.bat`.

   Options (pass to either `install.bat` or `install.ps1`):

   ```powershell
   install.bat -InstallDir D:\Apps\GaiaSeis   # alternative location
   install.bat -NoShortcuts                   # skip menu / desktop links
   install.bat -NoPrecompile                  # skip the slow precompile step
   ```

   Re-running the installer overwrites the previous install but
   preserves `logs\`, `mseed\`, `mseed2\` and `ntrip_profiles.toml`
   from the older copy.

   **If you prefer to run the PowerShell script directly** (e.g.
   you've already loosened the policy or you want to see verbose
   output), open PowerShell in the unzipped folder and either:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   # or, one-time policy relax for your user account:
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   .\install.ps1
   ```

---

## 3. Launch

After installation, any of these work:

- **Start Menu →** type *GaiaSeis* → Enter.
- Double-click the **GaiaSeis** desktop icon.
- Run `launch.bat` from the install directory.
- Or directly:

  ```powershell
  julia -t auto --project="%LOCALAPPDATA%\GaiaSeis\GaiaSeis" -i `
                "%LOCALAPPDATA%\GaiaSeis\GaiaSeis\examples\gui.jl"
  ```

The GUI opens, with the **NTRIP profile picker** at the top.  Edit the
caster / mount-point fields, click **Save profile**, then **Start
stream** to begin decoding.

---

## 4. Uninstall

From the install directory (default `%LOCALAPPDATA%\GaiaSeis\`),
double-click **`uninstall.bat`** - or pass arguments through it:

```
uninstall.bat                 # asks before deleting user data
uninstall.bat -Force          # no prompts; deletes everything
uninstall.bat -KeepUserData   # archive logs / mseed to %USERPROFILE%
```

Like `install.bat`, `uninstall.bat` is just a wrapper that calls
`uninstall.ps1` with `-ExecutionPolicy Bypass`. The bare `.ps1`
script accepts the same switches if you'd rather invoke it directly.

This removes the shortcuts and the install directory.  Julia itself,
package depot caches under `~\.julia\`, and any external station data
you provided are left alone.

---

## 5. Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `install.ps1 cannot be loaded because running scripts is disabled on this system` | Windows PowerShell's default ExecutionPolicy is `Restricted`. Use `install.bat` (bundled) instead - it invokes PowerShell with `-ExecutionPolicy Bypass` just for that run. Or run `powershell -ExecutionPolicy Bypass -File .\install.ps1`. |
| `Julia was not found on PATH` | Install juliaup or re-open PowerShell after installing Julia. |
| `Pkg.instantiate` fails with HTTP errors | First run downloads packages from the General registry - make sure the machine has internet access (a corporate proxy may need `JULIA_PKG_*` env vars). |
| GUI opens but the taskbar shows the Julia logo | The installer registers GaiaSeis with its own AppUserModelID; if Windows still groups it under julia.exe, log out / log back in or restart explorer.exe. |
| Window doesn't appear at all | Open PowerShell, run `launch.bat`, and check for an `@error` line with a stack trace; share it with the maintainer. |
| `gpt3_5.grd not found` warning at startup | The tropospheric grid file shipped with the bundle under `PPPH_VA\PPPHVA.jl\data\` was not copied - re-run `install.bat`. |

---

## 6. What's in the bundle?

```
GaiaSeis-0.2.0/
├── GaiaSeis/                    GaiaSeis source tree (Julia package)
│   ├── src/                     Decoder + bridge + GUI source
│   ├── examples/gui.jl          The launcher script
│   ├── docs/assets/             Logos, icons, gaiaseis.ico
│   ├── Project.toml, Manifest.toml
│   └── LICENSE                  CC BY-NC 4.0
├── PPPH_VA/PPPHVA.jl/           Path-local PPPHVA dependency
│   ├── src/
│   └── data/gpt3_5.grd          GPT3 5°x5° tropospheric grid
├── install.bat                  Double-clickable installer (recommended)
├── install.ps1                  Same installer (PowerShell, run directly)
├── launch.bat                   One-click GUI launcher
├── uninstall.bat                Double-clickable uninstaller
├── uninstall.ps1                Same uninstaller (PowerShell, run directly)
└── README_INSTALL.md            This file
```

---

## 7. License & citation

GaiaSeis is © 2026 Panagiotis Elias, released under the
**Creative Commons Attribution-NonCommercial 4.0 International**
licence (CC BY-NC 4.0).  See `GaiaSeis\LICENSE` for the full text.

If you use it in scientific work, please cite:

> Elias P. (2026). *GaiaSeis: GNSS-based real-time seismogeodesy via
> PPP-VA.* Deforming Gaia Lab, University of Patras, Greece.

and the upstream PPP-VA toolkit:

> Bahadur B. & Nohutcu M., "PPPH: a MATLAB-based software for
> multi-GNSS precise point positioning analysis", *GPS Solutions* 22
> (2018), Art. 113.
