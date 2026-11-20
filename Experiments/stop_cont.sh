#!/bin/zsh
# 0.3.3 — pause a top stream with SIGSTOP, resume with SIGCONT, inspect the samples around the gap.
cd "$(dirname "$0")"
WS=$(pgrep -x WindowServer)
top -l 7 -s 5 -stats pid,time,mem,idlew,instrs,cpu > out/top_stopcont.log &
TP=$!
sleep 12; kill -STOP $TP; echo "stopped at $(date +%T)"; sleep 30; kill -CONT $TP; echo "resumed at $(date +%T)"
wait $TP
echo "samples: $(grep -c '^Processes:' out/top_stopcont.log)"
echo "sample timestamps and WindowServer row (pid time mem idlew instrs cpu):"
awk -v ws=$WS '/^20[0-9][0-9]\//{ts=$2} $1==ws{print ts, $0}' out/top_stopcont.log
