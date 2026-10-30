#!/bin/sh
# Offline replay of an earthquake record played on the Timisoara shaking table
# (Zenodo record 18847292, receiver TM0J13ROU: Topcon NET-G5 at 10 Hz) through
# the GaiaSeis platform with the GaiaVario engine, against the table
# accelerometer. See README.md in this directory.
#
#   EVENT=samos_2020  sh examples/shaking_table/run.sh      (from the package directory)
#   EVENT=norcia_2016 sh examples/shaking_table/run.sh
#
# examples/samos_2020/run.sh and examples/norcia_2016/run.sh are wrappers that set EVENT.
#
# Steps: 1. fetch three members of the Zenodo record (about 116 MB, shared by
# both events, skipped when present), 2. decode the Hatanaka RINEX log into an
# observation dump for the event window (pure-Python decoder of the GaiaVario
# tools), 3. replay the dump through the bridge with the GaiaVario engine, write
# the solution CSV, the figure and print the summary.
#
# Environment: EVENT (samos_2020 | norcia_2016), JULIA (default julia), PYTHON
# (default python3), GAIAVARIO_DIR (checkout of GaiaVario.jl; default: the sibling
# directory of this package or the installed package), T0_UTC / T1_UTC (override
# the event's window, UTC seconds of day).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/../.." && pwd)
DATA="$PKG/examples/data/shaking_table"
OUT="$HERE/out"
JULIA=${JULIA:-julia}
PYTHON=${PYTHON:-python3}
GV=${GAIAVARIO_DIR:-$PKG/../GaiaVario.jl}
if [ ! -f "$GV/tools/crx_to_dump.py" ]; then
    GV=$("$JULIA" --project="$PKG" -e 'import GaiaSeis; p = GaiaSeis.NtripProfile(engine = "gaiavario"); GaiaSeis._load_engine!(p); print(pkgdir(Main.GaiaVario))' 2>/dev/null || true)
fi
[ -f "$GV/tools/crx_to_dump.py" ] || { echo "GaiaVario.jl tools not found (set GAIAVARIO_DIR)"; exit 1; }

# The events: windows in UTC seconds of day of 2025-10-21 around the estimated
# start of the input motion on table TM0 (EVENTS_summary sheet of the record's
# Dataset_Readme.xlsx). The replay solves 30 s beyond the window on both sides
# (filter margin) and one more minute before that warms the engine.
case "${EVENT:-samos_2020}" in
    samos_2020)   # row 6: Samos 2020 (HL.TNSA, 302 s), start 10:44:41 UTC; next run (Friuli S435) at 10:53:29
        TITLE="Samos 2020 (HL.TNSA)"; T0D=38610; T1D=39030 ;;          # 10:43:30 - 10:50:30
    norcia_2016)  # row 10: Norcia 2016 (IT.CIT, 65 s), start 11:06:13 UTC; AM05 ends 11:04:19, CPS starts 11:08:53
        TITLE="Norcia 2016 (IT.CIT)"; T0D=39900; T1D=40100 ;;          # 11:05:00 - 11:08:20
    *) echo "unknown EVENT '$EVENT' (samos_2020 | norcia_2016)"; exit 1 ;;
esac
T0=${T0_UTC:-$T0D}
T1=${T1_UTC:-$T1D}
DOW=2                                    # 2025-10-21 is a Tuesday: GPS day of week 2
S0=$((DOW * 86400 + T0 + 18 - 90))       # GPS seconds of week (GPS time = UTC + 18 s)
S1=$((DOW * 86400 + T1 + 18 + 31))

CRX=TM0J13ROU_R_20252940834_04H_10Z_MO.crx.gz
NAV=BRDC00WRD_S_20252940000_01D_MN.rnx
ACC=RO_TIME_2025_294_TM0_cor.mseed
mkdir -p "$DATA" "$OUT"

# 1. data (HTTP range requests into the record's zip archives: nothing else is downloaded)
fetch() { # archive member
    name=$(basename "$2")
    if [ -s "$DATA/$name" ]; then echo "present: $name"; return; fi
    echo "fetching $name from $1 ..."
    "$PYTHON" "$GV/tools/fetch_members.py" --out "$DATA" "$1" "$2"
}
fetch GNSS_observations.zip GNSS_observations/TM0/$CRX
fetch RealTime_RTCM_otherFiles.zip RealTime_RTCM_otherFiles/EPH_NTRIP/TM0/$NAV
fetch Accelerometer_records.zip Accelerometer_records/Corrected/TM0/$ACC

# 2. Hatanaka RINEX -> observation dump of the window (and the header for position and antenna)
DUMP="$DATA/TM0J13ROU_${T0}_${T1}.dump"
if [ ! -s "$DUMP" ]; then
    echo "decoding $CRX for GPS seconds of week $S0 .. $S1 (a few minutes, pure Python) ..."
    "$PYTHON" "$GV/tools/crx_to_dump.py" "$DATA/$CRX" "$DUMP" $S0 $S1 GREC
fi
if [ ! -s "$DATA/TM0J13ROU_header.txt" ]; then
    "$PYTHON" -c 'import gzip,sys
with gzip.open(sys.argv[1], "rt", encoding="latin1") as f:
    for l in f:
        print(l.rstrip("\n"))
        if "END OF HEADER" in l: break' "$DATA/$CRX" > "$DATA/TM0J13ROU_header.txt"
fi

# 3. replay through the bridge, figure, summary
cd "$PKG"
GAIAVARIO_DIR="$GV" "$JULIA" --project=. "$HERE/replay.jl" "$DUMP" "$DATA/$NAV" "$DATA/TM0J13ROU_header.txt" "$DATA/$ACC" \
    "$OUT/${EVENT:-samos_2020}_tm0j13" 2025-10-21 $T0 $T1 "$TITLE"
