#!/bin/bash
# Freeze detector for the GaiaSeis GUI started via tools/run_gui_watched.sh.
# Every 10 s: if the GUI pid is alive, a session had been writing its
# auto-dump, and that dump has not been updated for STALL_S seconds, the
# GUI's thread 1 (Gtk loop + decoder + solver) is stuck. Then it writes
# logs/gui_freeze_<stamp>.txt with process/socket state and sends SIGUSR1,
# which makes Julia print every thread's stack into the console log.
cd "$(dirname "$0")/.." || exit 1
STALL_S=${STALL_S:-45}
WLOG=logs/gui_watchdog.log
last_report=0
echo "[watchdog] $(date -Is) started (stall threshold ${STALL_S}s)" >> $WLOG
while true; do
  sleep 10
  PID=$(cat logs/gui.pid 2>/dev/null)
  [ -z "$PID" ] && continue
  if ! kill -0 "$PID" 2>/dev/null; then continue; fi          # exit report is written by the launcher
  DUMP=$(ls -t logs/auto_debug_*.txt 2>/dev/null | head -1)
  [ -z "$DUMP" ] && continue
  AGE=$(( $(date +%s) - $(stat -c %Y "$DUMP") ))
  CON=$(ls -t logs/gui_console_*.log 2>/dev/null | head -1)
  START=$(stat -c %Y "$CON" 2>/dev/null || echo 0)
  # Only a dump written by THIS process counts (newer than the console log's creation).
  [ "$(stat -c %Y "$DUMP")" -lt "$(stat -c %W "$CON" 2>/dev/null || echo 0)" ] && continue
  if [ "$AGE" -gt "$STALL_S" ]; then
    NOW=$(date +%s)
    if [ $((NOW - last_report)) -gt 300 ]; then
      last_report=$NOW
      STAMP=$(date +%Y%m%d_%H%M%S); REP="logs/gui_freeze_${STAMP}.txt"
      {
        echo "GaiaSeis GUI freeze report  $(date -Is)"
        echo "pid $PID alive, auto-dump $DUMP not updated for ${AGE}s"
        echo "--- process ---"; ps -o pid,etime,rss,vsz,nlwp,%cpu,stat -p "$PID"
        echo "--- threads by CPU (top 8) ---"; top -H -b -n1 -p "$PID" 2>/dev/null | sed -n '8,16p'
        echo "--- sockets to caster ---"; ss -tnp 2>/dev/null | grep "pid=$PID" | awk '{print $1, "RecvQ="$2, "SendQ="$3, $5}'
        echo "--- memory ---"; free -m | head -2
        echo "--- sending SIGUSR1: all-thread stacks + 1 s profile go to $CON ---"
      } > "$REP"
      kill -USR1 "$PID" 2>/dev/null
      sleep 4
      { echo "--- console tail after SIGUSR1 (last 400 lines) ---"; tail -400 "$CON"; } >> "$REP"
      echo "[watchdog] $(date -Is) FREEZE suspected (dump age ${AGE}s) -> $REP" >> $WLOG
    fi
  fi
done
