#!/bin/bash
# Launch the GaiaSeis GUI with its console captured and an exit report.
#   tools/run_gui_watched.sh [script.jl]      (default: examples/gui.jl)
# Console  -> logs/gui_console_<stamp>.log   (stdout+stderr, incl. SIGUSR1 stack snapshots)
# Exit     -> logs/gui_exit_<stamp>.txt      (exit code / signal, last 300 console lines, OOM check)
# PID      -> logs/gui.pid                   (read by tools/gui_watchdog.sh)
cd "$(dirname "$0")/.." || exit 1
SCRIPT="${1:-examples/gui.jl}"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="logs/gui_console_${STAMP}.log"
mkdir -p logs
echo "[watched] $(date -Is) launching $SCRIPT  console -> $LOG"
julia -t auto --heap-size-hint=8G $GAIASEIS_JULIA_ARGS --project=. "$SCRIPT" > "$LOG" 2>&1 &
PID=$!
echo $PID > logs/gui.pid
echo "[watched] pid $PID"
wait $PID; RC=$?
REP="logs/gui_exit_${STAMP}.txt"
{
  echo "GaiaSeis GUI exit report  $(date -Is)"
  echo "script   : $SCRIPT"
  echo "pid      : $PID"
  if [ $RC -ge 128 ]; then echo "exit     : killed by signal $((RC-128)) ($(kill -l $((RC-128)) 2>/dev/null))  (rc=$RC)"; else echo "exit     : code $RC"; fi
  echo "console  : $LOG"
  echo "--- dmesg (OOM / segfault lines, last 20) ---"
  dmesg -T 2>/dev/null | grep -iE 'oom|killed process|segfault|julia' | tail -20
  echo "--- last 300 console lines ---"
  tail -300 "$LOG"
} > "$REP"
rm -f logs/gui.pid
echo "[watched] exited rc=$RC  report -> $REP"
