#!/bin/sh
# Downloads the raw RTCM capture used by examples/replay_capture.jl into
# examples/data/ (git-ignored). Ten minutes of a Topcon NET-G5 at 10 Hz
# (GPS, GLONASS, Galileo, BeiDou MSM7 with broadcast ephemerides), about 10 MB.
#
#   sh examples/fetch_example_data.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DATA="$HERE/data"
ASSET=upc10z_10min_20261029.bin
URL=${GAIASEIS_EXAMPLE_URL:-https://github.com/PanagiotisElias/GaiaSeis/releases/download/v0.5.0/$ASSET}
mkdir -p "$DATA"
if [ -s "$DATA/$ASSET" ]; then
    echo "present: $DATA/$ASSET"
else
    echo "downloading $URL"
    curl -L --fail --progress-bar -o "$DATA/$ASSET.part" "$URL"
    mv "$DATA/$ASSET.part" "$DATA/$ASSET"
    echo "saved: $DATA/$ASSET"
fi
echo "replay with:  julia --project=. examples/replay_capture.jl examples/data/$ASSET --out solution.csv"
