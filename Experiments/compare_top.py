#!/usr/bin/env python3
"""0.3.2 — compare `top` columns with native counters for own processes.
Sweep A -> top (2 samples, 10 s apart) -> sweep B; top sample 2 should match sweep B."""
import csv, re, subprocess, statistics as st

def sweep(path):
    subprocess.run(["out/probe", "sweep", path], check=True, capture_output=True)
    return {int(r["pid"]): {k: int(v) for k, v in r.items()} for r in csv.DictReader(open(path))}

def size(s):
    s = s.rstrip("+-")
    m = re.fullmatch(r"([\d.]+)([BKMGT]?)", s)
    if not m: return None
    return float(m.group(1)) * {"": 1, "B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}[m.group(2)]

def cputime(s):
    p = s.split(":")
    if len(p) == 2: return int(p[0]) * 60 + float(p[1]), 0.01          # MM:SS.cc
    if len(p) == 3: return int(p[0]) * 3600 + int(p[1]) * 60 + float(p[2]), 1.0  # HH:MM:SS
    return None, None

def num(s):
    s = s.rstrip("+-")
    return int(s) if s.isdigit() else None

A = sweep("out/sweepA.csv")
out = subprocess.run(["top", "-l", "2", "-s", "10", "-stats", "pid,time,mem,idlew,instrs,cycles,pageins"],
                     capture_output=True, text=True).stdout
B = sweep("out/sweepB.csv")
open("out/top_cmp.log", "w").write(out)
rows = out.split("\nPID")[-1].splitlines()[1:]
top = {}
for line in rows:
    f = line.split()
    if len(f) != 7 or not f[0].isdigit(): continue
    top[int(f[0])] = f
print(f"top rows: {len(top)}, own pids in both sweeps and top: {len(set(top) & set(A) & set(B))}")

def report(name, errs, unit, tol, rel=True):
    if not errs: print(f"{name}: no comparable rows"); return
    e = sorted(errs)
    p50, p95, mx = e[len(e) // 2], e[int(len(e) * 0.95)], e[-1]
    ok = p95 <= tol
    print(f"[{'PASS' if ok else 'ADJUST'}] {name}: n={len(e)} median={p50:.3g}{unit} p95={p95:.3g}{unit} max={mx:.3g}{unit} (tolerance p95 <= {tol}{unit})")

t_err, t_err_long, m_err, w_err, p_err, i_delta, i_cum = [], [], [], [], [], [], []
hour_format = 0
for pid in set(top) & set(A) & set(B):
    f, a, b = top[pid], A[pid], B[pid]
    t, res = cputime(f[1])
    if t is not None:
        d = abs(t - b["cpu_ns"] / 1e9)
        (t_err if res < 1 else t_err_long).append(d)
        hour_format += res >= 1
    m = size(f[2])
    if m and b["footprint"] > 10 << 20: m_err.append(abs(m - b["footprint"]) / b["footprint"] * 100)
    w = num(f[3])
    if w is not None and b["idle_wkups"] > 1000: w_err.append(abs(w - b["idle_wkups"]) / b["idle_wkups"] * 100)
    pg = num(f[6])
    if pg is not None and b["pageins"] > 100: p_err.append(abs(pg - b["pageins"]) / b["pageins"] * 100)
    ins = num(f[4]); dn = b["instructions"] - a["instructions"]
    if ins and dn > 50_000_000:
        i_delta.append(abs(ins - dn) / dn * 100); i_cum.append(abs(ins - b["instructions"]) / b["instructions"] * 100)

report("TIME vs native CPU time (MM:SS.cc rows)", t_err, " s", 0.05)
if t_err_long: report(f"TIME vs native CPU time (HH:MM:SS rows, {hour_format} procs)", t_err_long, " s", 1.0)
else: print("TIME: no process has over 1 h of CPU yet, so the HH:MM:SS (1 s resolution) case was not exercised")
report("MEM vs native footprint (>10 MB)", m_err, " %", 5)
report("IDLEW vs native idle wakeups (>1000)", w_err, " %", 5)
report("PAGEINS vs native page-ins (>100)", p_err, " %", 5)
report("INSTRS as per-interval delta vs native delta", i_delta, " %", 25)
report("INSTRS as cumulative vs native cumulative", i_cum, " %", 25)
