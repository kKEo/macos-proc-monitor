#!/usr/bin/env python3
"""0.3.1 — validate every sample of the top soak log and summarise its cost."""
import csv, re
EXPECT = "PID %CPU TIME MEM CMPRS PAGEINS CSW #TH IDLEW POWER INSTRS CYCLES FAULTS UID PPID".split()
samples, bad_rows, bad_headers, rows_total, stamps, hour_fmt = 0, [], 0, 0, [], 0
in_rows = False
for line in open("out/top_stream.log"):
    line = line.rstrip("\n")
    if line.startswith("Processes:"): samples += 1; in_rows = False; continue
    if re.match(r"^20\d\d/\d\d/\d\d \d\d:\d\d:\d\d$", line): stamps.append(line); continue
    if line.startswith("PID"):
        in_rows = True
        if line.split() != EXPECT: bad_headers += 1
        continue
    if in_rows and line.strip():
        f = line.split(); rows_total += 1
        ok = (len(f) == 15 and f[0].isdigit() and re.fullmatch(r"[\d.]+", f[1]) and re.fullmatch(r"\d+:\d\d[.:]\d\d(:\d\d)?", f[2])
              and re.fullmatch(r"[\d.]+[BKMGT]?[+-]?", f[3]) and re.fullmatch(r"\d+(/\d+)?", f[7]) and f[13].isdigit() and f[14].isdigit())
        if not ok: bad_rows.append(line)
        elif f[2].count(":") == 2: hour_fmt += 1
from datetime import datetime
ts = [datetime.strptime(s, "%Y/%m/%d %H:%M:%S") for s in stamps]
gaps = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
cost = list(csv.DictReader(open("out/top_cost.csv")))
def secs(s): m, r = s.split(":"); return int(m) * 60 + float(r)
first, last = cost[0], cost[-1]
cpu_total = secs(last["utime"]) + secs(last["stime"]); cpu_first = secs(first["utime"]) + secs(first["stime"])
dur = (ts[-1] - ts[0]).total_seconds()
print(f"samples={samples} duration={dur/60:.1f} min rows={rows_total} bad_headers={bad_headers} bad_rows={len(bad_rows)} rows_in_HH:MM:SS_format={hour_fmt}")
print(f"sample gap s: min={min(gaps):.0f} max={max(gaps):.0f} mean={sum(gaps)/len(gaps):.2f}")
print(f"top CPU total={cpu_total:.2f} s (startup incl. first sample ~{cpu_first:.2f} s); steady per sample={(cpu_total-cpu_first)/(samples-1):.3f} s => {(cpu_total-cpu_first)/dur*100:.2f} % of a core")
print(f"top RSS kB: min={min(int(r['rss_kb']) for r in cost)} max={max(int(r['rss_kb']) for r in cost)}")
for r in bad_rows[:5]: print("BAD:", r)
