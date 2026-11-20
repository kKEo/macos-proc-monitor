#!/bin/zsh
# 0.3.1 — soak test of a long-lived `top` stream. Usage: soak_top.sh <samples> <interval_s>
cd "$(dirname "$0")"
N=${1:-100}; S=${2:-30}
STATS=pid,cpu,time,mem,cmprs,pageins,csw,threads,idlew,power,instrs,cycles,faults,uid,ppid
top -l $N -s $S -stats $STATS > out/top_stream.log 2>out/top_stream.err &
TP=$!
echo "epoch,top_pid,utime,stime,rss_kb" > out/top_cost.csv
while kill -0 $TP 2>/dev/null; do
  echo "$(date +%s),$TP,$(ps -p $TP -o utime=,stime=,rss= | awk '{print $1","$2","$3}')" >> out/top_cost.csv
  sleep 30
done
echo "top exited: $(date)" >> out/top_stream.err
