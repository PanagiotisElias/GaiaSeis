#!/bin/bash
# Build (if needed) and install ringserver as a systemd user service for the
# GaiaSeis SeedLink feed.
#   tools/ringserver/install.sh [path/to/ringserver-binary]
# Without an argument the script downloads and builds ringserver 4.5.6 from
# EarthScope's GitHub (needs gcc, make, curl). Idempotent: re-running
# re-installs the config template only if ~/.config/gaiaseis/ringserver.conf
# does not exist yet (your edits are kept).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VER=v4.5.6
BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  WORK="$(mktemp -d)"
  echo "==> downloading ringserver $VER"
  curl -sL -m 300 -o "$WORK/rs.tgz" "https://api.github.com/repos/EarthScope/ringserver/tarball/$VER"
  mkdir -p "$WORK/src" && tar xzf "$WORK/rs.tgz" -C "$WORK/src" --strip-components=1
  echo "==> building"
  (cd "$WORK/src" && make -j"$(nproc)" >/dev/null)
  BIN="$WORK/src/ringserver"
fi
mkdir -p ~/.local/bin ~/.config/gaiaseis ~/.config/systemd/user \
         ~/.local/share/gaiaseis/ring ~/.local/share/gaiaseis/ringserver-logs
install -m 755 "$BIN" ~/.local/bin/ringserver
[[ -f ~/.config/gaiaseis/ringserver.conf ]] || \
  sed "s#__HOME__#$HOME#g" "$HERE/ringserver.conf" > ~/.config/gaiaseis/ringserver.conf
install -m 644 "$HERE/gaiaseis-ringserver.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gaiaseis-ringserver
sleep 1
systemctl --user --no-pager status gaiaseis-ringserver | head -5
echo "==> SeedLink on port 18000, DataLink on 16000. Set datalink_host = \"127.0.0.1\" in the profile."
echo "    Lingering must be on for the service to outlive logouts: loginctl enable-linger $USER"
