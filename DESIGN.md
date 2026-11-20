# pmon — local macOS process activity monitor: design

Status: design, nothing implemented yet. Target: macOS 14+ on Apple Silicon (developed on macOS 26.2, MacBook Air, 4P+4E cores, 8 GB RAM).

## 1. Goal

Answer one question well: **"Which application made my Mac sluggish, when, and why?"**

Everything else follows from that:

- Continuously record machine condition and per-process activity at a cost low enough to leave running forever.
- Detect *sluggishness episodes* (periods where the machine is actually bottlenecked) rather than just logging high numbers.
- Attribute each episode to applications, not PIDs, and separate *culprits* from *victims*.
- Keep the data in a shape where reports ("top offenders this week", "what happened at 14:32", "is Slack leaking?") are single, fast SQL queries.

Non-goals: remote monitoring, fleet management, killing or throttling processes, security auditing, a replacement for Instruments.

## 2. Measured facts the design rests on

Checked on the target machine before writing this; these are the load-bearing assumptions.

| Fact | Consequence |
|---|---|
| A full sweep of 560 processes with `proc_pidinfo` + `proc_pid_rusage` took **4.9 ms** (in Python; native will be lower). | Sweeping every process every 10 s costs about 0.05 % of one core. Collection is not the cost problem; storage volume is. |
| Without root, 358 of 560 processes are fully readable. For the other **~200 (processes owned by other users, "foreign" below) `proc_pid_rusage` and task info fail with `EPERM`**. | The foreign set includes `WindowServer`, `kernel_task`, `mds_stores`, `backupd` — frequent culprits. They need a different, unprivileged data path (section 4.1). |
| For foreign processes these still work without root: executable path, parent, uid, start time (`sysctl kern.proc`), kernel unique process id, coalition id. | Identity and app grouping are complete for every process without root. Only the *metrics* of foreign processes need a fallback. |
| The setuid system tools work for all processes without root. `ps` over the ~200 foreign processes: **60 ms CPU**, gives CPU time and RSS. `top`: **1.1 s CPU for the first sample, about 0.1 s for each further one**, gives footprint, compressed memory, page-ins, context switches, threads, idle wakeups, power score, instructions and cycles. | One long-lived `top -l 0` child is an affordable metric source for foreign processes; spawning `top` per sample is not. RSS from `ps` is misleading (WindowServer: 51 MB RSS vs. 436 MB footprint), so `ps` is used for CPU only. |
| Not obtainable for foreign processes without root: disk bytes, per-QoS CPU time, runnable-wait time, energy in nJ. `footprint`, `sample` and the responsibility API also refuse foreign targets. | These are covered as a single residual (system total minus the sum of own processes), not per process. |
| `rusage_info_v6` is populated: `ri_runnable_time`, `ri_energy_nj`, `ri_instructions`, P-core time and per-QoS CPU time were non-zero for essentially all readable processes. | CPU contention, energy and "how important was this work" are available from one cheap syscall. No `powermetrics` needed for the default tier. |
| `ri_user_time` and friends are in Mach time units, not nanoseconds. | Convert with `mach_timebase_info` (125/3 on Apple Silicon) or CPU is under-reported ~42×. |
| `responsibility_get_pid_responsible_for_pid` works and resolves a helper to its owning app. | App grouping can match Activity Monitor. It is private API, so it needs a fallback. |
| The machine was at memory pressure level 2 (warn) with 6.6 GB of 7.2 GB swap used. | On an 8 GB machine memory is the dominant sluggishness cause. Memory attribution needs the most care. |
| `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports` already hold dozens of `.diag` / `.ips` reports. | The OS already writes CPU-resource, wakeup, hang and crash reports. Ingesting them is free signal. |

### 2.1 Phase 0 findings

Measured on 2026-11-20 with the probes in `Experiments/` (raw data in `Experiments/out/`). "Adjusted" means the mechanism works but the design's original reading of it was wrong; the affected sections are already corrected.

| # | Assumption | Result | What was measured | Consequence |
|---|---|---|---|---|
| 1 | rusage CPU times need Mach timebase conversion | **Confirmed** | Converted value is 100.0 % of `CLOCK_PROCESS_CPUTIME_ID`; raw value is 2.4 % | Convert at the collector boundary |
| 2 | `ri_runnable_time` is time spent waiting for a core | **Adjusted** | It equals thread count × wall time at every load (2 threads → 2.00, 16 → 15.97, 32 → 31.94 core-seconds per second), so it includes time *on* a core | Wait time = `ri_runnable_time` − CPU time. With that, measured wait matches expected within 1 % (16 threads: 8.33 vs 8.36) |
| 3 | CPU time lands in the per-QoS counter of the thread's QoS | **Adjusted** | Background and utility land in their own counters. Default, user-initiated and user-interactive threads of a command-line process all landed in `legacy`, although the threads reported the requested QoS | Only three groups are trustworthy: foreground (interactive + initiated + default + legacy), utility, background. The design never needed finer |
| 4 | Background-QoS work stays off performance cores | **Confirmed** | P-core share 0.00 for background, 0.98–1.00 for every other class on an otherwise idle machine | Supports the low blame weight for background CPU |
| 5 | Memory pressure signals track real pressure | **Confirmed, with a caveat** | Allocating 768 MB of incompressible data moved the level from normal to warn as `memorystatus_level` fell from 45 % to 38 %. Compressions peaked at 5 k pages/s; re-touching the data produced 30 k decompressions/s. After freeing, the level **stayed at warn** although the memory level recovered to 44 % | The pressure level is sticky; use it as a floor and drive the score from `memorystatus_level` and the compression / decompression / swap rates. Swap-out behaviour was not exercised (no swap in use at the time) |
| 6 | IOKit disk time is a usable saturation signal | **Adjusted** | "Total Time" is summed per-request latency: 280–300 % of the interval at 1.9 GB/s, about 1 % when idle. Only one driver object exists on this machine | Treat time ÷ interval as mean queue depth, not a 0–100 % busy figure. The 1 GB test finished in under a second on this SSD, so sustained behaviour needs a longer load in phase 5 |
| 7 | `top` columns agree with native counters | **Confirmed** | Over 377 own processes: CPU time within 0.01 s (p95), footprint within 3.2 % (p95, display rounding), idle wakeups and page-ins exact | The top stream is a faithful source |
| 8 | `top` column semantics | **Adjusted** | `INSTRS` and `CYCLES` are per-interval deltas, not cumulative (0.5 % median difference from the native delta). `TIME` shows whole seconds once CPU time passes one hour | Three column kinds in the parser (section 4.1); `ps` for CPU of long-running processes |
| 9 | Pausing the stream is safe | **Confirmed** | After `SIGSTOP` for 30 s and `SIGCONT`, the next sample covered the full gap (cumulative columns continuous, delta columns summed over the gap), and later samples were normal | Pause on idle and display sleep as designed |
| 10 | `ps` burst is cheap | **Confirmed** | 28 ms CPU per call over 265 foreign processes: 0.55 % of a core at 5 s cadence | Acceptable for episodes only, as designed |
| 11 | A UI-less LaunchAgent sees session signals | **Confirmed, with a caveat** | App activation notifications arrived within 25 ms of the switch; input idle time, screen-lock, thermal and Low Power state were readable. The frontmost "app" was at times `com.apple.universalcontrol` (keyboard and mouse shared from another Mac) | Frontmost can be a background agent; treat those as "no app in focus on this Mac" rather than as a focus app |
| 12 | Diagnostic reports are watchable and readable | **Confirmed** | FSEvents delivered create and delete events for the user directory; report headers in both directories were readable without root | Diagnostic-report ingestion as designed |
| 13 | Timer canary | **Adjusted** | An ordinary sleep-based timer was a constant 5.0 ms late (p95 5.1 ms) on an idle machine | Use a strict zero-leeway timer and score lateness relative to the idle baseline |
| 14 | GPU utilisation is readable | **Confirmed for the device, open per process** | `Device Utilization %` is present; the per-client `AppUsage` lists were empty when sampled | Device-level GPU in the default slow tier; per-process GPU stays an optional, unproven collector |
| 16 | A long-lived `top` stream is stable and cheap | **Confirmed** | 100 samples over 49.6 minutes at 30 s: 63 175 rows, 0 malformed rows, 0 header changes, sample spacing 30–31 s. Cost 0.065 s CPU per sample = **0.22 % of a core**; memory at most 5.3 MB | Keep the top stream. An overnight run (`Experiments/soak_top.sh 960 30`) is an optional extra check |
| 15 | Counters and timers across sleep | **Not verified** | The machine did not sleep during the 45-minute watch (sleep was being prevented) | Check in subphase 1.2 by closing the lid during a recording |

**Decision (go / no-go): go.** Phase 3 is built on the `top` stream as designed, with `ps` as the burst source and the fallback. No assumption was dropped; five were adjusted, all in the interpretation of a counter rather than in the architecture. Two items remain open and are scheduled: sleep behaviour (subphase 1.2) and swap-out behaviour under heavy memory pressure (phase 5 scenario recordings).

## 3. What "sluggish" means here

A machine feels slow when the user's foreground work waits on something. There are six things it can wait on; each is a *pressure dimension* with its own cheap signals.

| Dimension | Primary signals | Why it hurts |
|---|---|---|
| **cpu** | Idle % per cluster, summed runnable-wait (`ri_runnable_time` − CPU time: time threads were ready but had no core), load / ncpu, scheduler-latency canary | Foreground threads queue behind others |
| **memory** | Kernel pressure level, swap-out and decompression rates, page-in rate, `memorystatus_level`, swap used / free disk | Every touch of compressed or swapped memory stalls the toucher |
| **disk** | Mean I/O queue depth (summed I/O time ÷ interval), latency per operation, throughput, free space on the data volume | I/O waits; a nearly full volume also blocks swap growth |
| **thermal** | Thermal pressure level, CPU speed limit | The OS caps frequency; all work slows (fanless Air: common) |
| **gpu** | Device utilisation %, WindowServer CPU | Compositing falls behind, UI stutters |
| **ui** | Hang / spin reports, frontmost app unresponsive | Direct evidence of a stalled main thread |

Context that modifies interpretation but is not itself pressure: Low Power Mode, battery vs. AC, user present or idle, display asleep, just woke from sleep, Rosetta-translated process.

## 4. Architecture

```
                         user session, no root
 ┌───────────────────────────────────────────────────────────────────┐
 │ pmond  (LaunchAgent)                                              │
 │                                                                   │
 │  session signals ─┐                                               │
 │  system counters ─┤                                               │
 │  own processes  ──┼─► delta engine ─► app attribution ─► scorer   │
 │  (libproc)        │   ─► episode detector ─► writer ─► SQLite     │
 │  foreign processes┘   ─► rollup + retention                       │
 │  (top stream, ps)     ─► triggered captures (optional)            │
 └───────────▲───────────────────────────────────────────▲───────────┘
             │ child process                             │ read only
      ┌──────┴───────┐                           ┌───────┴──────────┐
      │ top -l 0     │                           │ pmon CLI / HTML  │
      │ (setuid)     │                           └──────────────────┘
      └──────────────┘
             ┆ optional
      ┌──────┴──────────────────────┐
      │ pmon-helper (root, opt-in)  │  stateless: answers "metrics for these pids",
      └─────────────────────────────┘  runs privileged captures
```

**One unprivileged process is the product.** `pmond` runs as a per-user LaunchAgent. Because it lives in the GUI session it reads session signals (frontmost app, user input idle time, screen lock) directly, so no second agent is needed. Installation is copying a binary and a plist into the home directory; no password prompt, no system-wide files.

**Root is an opt-in upgrade, never a requirement.** `sudo pmon helper install` adds a small stateless helper. Nothing in the pipeline, schema or reports changes when it is present; some values simply move from "estimated" to "exact" (4.2).

**Language: Swift.** Direct access to libproc, Mach, IOKit, AppKit notifications and system `libsqlite3`, one binary, no runtime dependency.

### 4.1 Covering foreign processes without root

Three data paths feed the same delta engine. Each process is assigned one by whether `proc_pid_rusage` succeeds for it.

| Path | Processes | How | Cadence | Cost |
|---|---|---|---|---|
| **Native** | Own (about 2/3 of all, and nearly every app the user can quit) | libproc syscalls | 10 s | about 5 ms per sweep |
| **Top stream** | Foreign | One long-lived `top -l 0 -s 30 -stats …` child; `pmond` parses its output and keeps only foreign rows | 30 s | 0.065 s CPU per sample, 5 MB (measured over 50 min) |
| **ps burst** | Foreign | `ps -p <foreign pids> -o pid=,utime=,stime=` | Only while an episode is open or the index is above 40: every 5 s | 28 ms per call (measured) |

What each path yields:

| Metric | Native | Top stream | ps burst |
|---|---|---|---|
| CPU time (user, system) | yes | yes (total only) | yes |
| P-core time, per-QoS split, runnable-wait | yes | no | no |
| Footprint, page-ins | yes | yes, plus compressed size | no |
| Threads, context switches, idle wakeups | yes | yes | no |
| Instructions, cycles | yes | yes | no |
| Energy | exact, nJ | `top` power score (relative) | no |
| Disk bytes | yes | **no** | no |
| Identity, path, parent, coalition | yes | yes (native calls, not via `top`) | — |

**As built (phase 3).** The stream requests `pid,time,mem,cmprs,pageins,csw,threads,idlew,instrs,cycles,faults`. A sample is complete when the next one starts or the stream has been quiet for 0.3 s. A top sample arrives between ticks, so the system and own-process totals are interpolated to the sample's two end times before the residual is computed; in a live run the unexplained residual was 0.4–2.4 % of a core and never negative. While `ps` is active it is the only CPU source for foreign processes, so CPU is never counted twice. Until app rows exist (phase 4) the residuals live on `sys_sample` (`foreign_cpu_ms`, `unknown_cpu_ms`, `unattributed_disk_bytes`) rather than as synthetic apps. Whole-second `TIME` for long-running processes is accepted as unbiased noise (±1 s per sample) instead of an extra `ps` call; pausing the child on idle is wired in phase 4 with the cadence policy.

**Residual accounting closes the gaps.** For every interval the daemon computes *system total − sum over own processes* for CPU, disk bytes and energy-relevant counters, and stores it as rows for two synthetic apps:

- `system.foreign` — the foreign processes collectively. Its CPU is then broken down per process from `top`/`ps`; its disk I/O cannot be, and is reported as "system processes, combined".
- `system.unattributed` — what remains after all known processes: kernel work and short-lived processes.

So totals always reconcile, and blame can always land somewhere honest: either on a named app, or on "system processes combined" with the breakdown the data supports.

**Top stream details.** The child is started lazily, paused with `SIGSTOP` while the display is asleep or the user is idle, resumed with `SIGCONT`, and restarted if it exits. Verified: the first sample after a 30 s pause covers the whole gap correctly. Columns fall into three kinds, handled differently: cumulative (`TIME`, `IDLEW`, `PAGEINS`, `CSW`, `FAULTS`) go through the delta engine like native counters; per-interval deltas (`INSTRS`, `CYCLES`) are used as they are; rates (`%CPU`, `POWER`) are ignored. The `COMMAND` column is never requested — names contain spaces and would break column parsing; identity comes from native calls by pid. `TIME` drops to whole-second resolution once a process has over an hour of CPU, so for those processes CPU comes from `ps`, which always reports hundredths. Column set is pinned with `-stats`, and the parser validates the header on every start so an OS update that changes the format degrades to the `ps` path with an event, rather than writing wrong numbers.

**Budget in rootless mode:** about 0.3 % of one core on average (0.05 % native sweep, 0.22 % top stream measured, the rest system sampling and writes), about 30 MB including the child.

### 4.2 What the optional root helper changes

| Without root (default) | With helper |
|---|---|
| Foreign processes at 30 s resolution, 5 s for CPU during episodes | All processes at 10 s, same as own |
| Foreign disk I/O only as a combined residual | Per-process disk I/O for system daemons (`mds_stores`, `backupd`) |
| Foreign energy as relative power score | Exact energy; per-QoS and runnable-wait for system processes |
| Stack capture and memory composition for own processes only | Also for foreign processes; spindump, powermetrics, exec tracing become available |
| `top` child running | `top` child not needed |

The helper holds no state and no database access: it takes a list of pids and returns raw counters, or runs one of a fixed set of capture commands. If it is missing, crashes or is uninstalled, `pmond` falls back to 4.1 within one interval.

**Pipeline stages**

1. **Scheduler** — one timer per tier, coalesced, QoS `utility`. Detects sleep by comparing `mach_absolute_time` with `mach_continuous_time`; an interval that spans sleep is flagged and its deltas discarded.
2. **Collectors** — each implements `collect() -> raw counters`, declares its tier, required privilege and a cost budget.
3. **Delta engine** — kernel counters are cumulative. Keeps the previous reading per process instance in memory and emits per-interval deltas. A process instance is identified by `(boot, pid, start time)`, so PID reuse is harmless.
4. **App attribution** — maps each process to an app (section 7).
5. **Scorer** — turns a system sample into six sub-scores and one sluggishness index (section 8).
6. **Episode detector** — opens, extends and closes episodes with hysteresis; computes blame on close.
7. **Writer** — batches one transaction per sweep. Applies the selection rule in section 6 so only interesting processes are stored in detail.
8. **Rollup and retention** — incremental, runs once a minute.

**Self-limiting.** The daemon samples itself and its `top` child like any other process. If a sweep exceeds its budget (default 50 ms) or daemon plus child exceed 1 % CPU averaged over 5 minutes, it backs off one tier (first lengthening the top-stream interval) and records an event. A monitor that contributes to the problem it measures is a bug.

## 5. Collectors

### 5.1 Default tier — cheap, always on

Event-driven (zero polling cost):

| Signal | Source |
|---|---|
| Frontmost application changes | `NSWorkspace.didActivateApplicationNotification` |
| Memory pressure transitions | `DispatchSource.makeMemoryPressureSource` |
| Thermal state transitions | `ProcessInfo.thermalStateDidChangeNotification`, `notify` key `com.apple.system.thermalpressurelevel` |
| Sleep, wake, display sleep, screen lock | `NSWorkspace` notifications, IOKit power notifications |
| Power source and Low Power Mode changes | `IOPSNotificationCreateRunLoopSource`, `NSProcessInfoPowerStateDidChange` |
| New OS diagnostic reports (`.diag` cpu/wakeups resource, `.hang`, `.spin`, `.ips` crash) | FSEvents on both `DiagnosticReports` directories; parse header only |

System sample, every 5 s (about ten syscalls):

| Group | Metrics | Source |
|---|---|---|
| CPU | user / system / idle ticks per core, aggregated per P and E cluster | `host_processor_info` |
| Load | 1/5/15 min load | `getloadavg` |
| Memory | free, active, inactive, wired, compressed, compressor size; faults, page-ins, page-outs, swap-ins, swap-outs, compressions, decompressions | `host_statistics64(HOST_VM_INFO64)` |
| Pressure | pressure level, `memorystatus_level` | `sysctl kern.memorystatus_*` |
| Swap | total, used | `sysctl vm.swapusage` |
| Disk | bytes and ops read/written, summed I/O time per physical device (exceeds the interval when requests overlap) | IOKit `IOBlockStorageDriver` statistics |
| Network | bytes and packets in/out per interface | `sysctl NET_RT_IFLIST2` |
| Counts | processes, threads | from the process sweep |
| Canary | how late the daemon's own strict (zero-leeway) timer fired at `userInitiated` QoS, relative to its own idle baseline | self-measured; direct evidence of scheduler latency |
| Presence | seconds since last user input | `CGEventSourceSecondsSinceLastEventType` |

All of the above work without root. Process sweep, every 10 s, own processes (foreign processes: see 4.1):

| Group | Metrics | Source |
|---|---|---|
| CPU | user, system, P-core time; time by QoS class, stored as three groups: foreground (interactive, initiated, default, legacy), utility, background (background, maintenance) | `proc_pid_rusage` v6 |
| Contention | runnable-but-not-running time | `ri_runnable_time` minus CPU time (the counter includes time on a core) |
| Memory | physical footprint (what Activity Monitor shows), resident, wired, lifetime peak footprint, page-ins | `proc_pid_rusage` |
| Disk | bytes read, bytes written, logical writes | `proc_pid_rusage` |
| Energy | energy in nJ, idle and interrupt wakeups, instructions, cycles | `proc_pid_rusage` |
| Scheduling | thread count, running threads, context switches, syscalls, faults | `proc_pidinfo(PROC_PIDTASKINFO)` |
| Identity (once per new process, **all** processes) | parent, uid, start time, executable path, kernel unique id, coalition id, Rosetta flag; responsible pid for own processes | `sysctl kern.proc`, `proc_pidpath`, `PROC_PIDUNIQIDENTIFIERINFO`, `PROC_PIDCOALITIONINFO`, responsibility API |

Slow sample, every 60 s: free space per volume (`statfs`), battery level and cycle state, GPU device utilisation (IOKit `IOAccelerator` `PerformanceStatistics`).

**Adaptive cadence.** Intervals are a policy, not constants:

| Condition | System | Process |
|---|---|---|
| Normal | 5 s | 10 s |
| Episode open or index above 40 | 2 s | 2 s |
| User idle over 5 min, or on battery with Low Power Mode | 15 s | 30 s |
| Display asleep | 60 s | 60 s |

Every sample stores its actual interval length, so rates are always computed from real elapsed time.

**Context as built (phase 4).** Session state (frontmost app, input idle time, lock, display, thermal, power) is read on every system tick rather than through separate notification sources, and changes are turned into `event` rows by the pipeline. A change is therefore seen up to one tick (5 s) late, in exchange for one code path that replays exactly. Only a *regular* application counts as being in focus; when a background agent is frontmost the focus is empty. Diagnostic reports are the exception: they are watched with FSEvents and attached to an app by executable path or name.

**Cadence as built.** Display off or screen locked: one sample a minute and the top child suspended. User idle for five minutes, or on battery in Low Power Mode: a third of the normal rate. The top child is *not* suspended merely because the user is idle, so background activity while away is still attributed.

**Unattributed CPU.** System busy time minus the sum of all process CPU deltas is stored each sweep. A large residual means short-lived processes are being born and dying between sweeps (build tools, shell loops, crash loops). It is the cheap detector for something the sweep cannot see; the expensive fix is in 5.2.

### 5.2 Optional tier — heavier, off by default

Each is individually switchable and has a mode: `off`, `triggered` (only during an episode, rate-limited) or `always`.

| Collector | Adds | Cost and catch | Without root | Suggested mode |
|---|---|---|---|---|
| **Stack capture** (`sample <pid> 3` on the top culprit) | *What* the hog was doing | About 3 s of profiling the target, 100 KB–2 MB of output | Own processes | triggered |
| **Per-thread breakdown** | Which thread inside the top N processes burns CPU | One syscall per thread; only for the top 5 | Own processes | triggered |
| **Memory composition** (`footprint <pid>`) | Dirty vs. swapped vs. compressed, by region type | Tens to hundreds of ms per target; do not use `vmmap`, it suspends the target | Own processes | triggered, `memory` episodes |
| **Fast process-birth scan** | Names of short-lived processes | Pid-list diff every 250 ms for up to 60 s, about 1 % of a core while active | All (identity is unprivileged) | triggered when unattributed CPU is high |
| **Per-process network** | Bytes in/out per process | `nettop -L` subprocess or private NetworkStatistics framework | All | off |
| **Per-process GPU time** | GPU hog identification | IORegistry walk of accelerator clients, about 5–20 ms; format changes between OS releases | All | triggered, `gpu` episodes |
| **File-descriptor and port counts** | Descriptor leaks | One syscall per process, variable-size result | Own processes | always, at 5 min cadence |
| **Unified log mining** | Jetsam kills, app hang durations | `log show` is slow, seconds of CPU | Partial (admin users see system logs) | triggered, after an episode closes |
| **Disk latency probe** | Read latency of a small uncached file | A few ms; reads only, no SSD wear | Yes | off |
| **Command-line arguments** | Tell apart `node server.js` from `node build.js` | Cheap, but arguments can contain secrets | Own processes | off (privacy) |
| **Spindump** | System-wide stacks, hang diagnosis | Hundreds of ms of system-wide CPU; several MB | **Helper only** | triggered, `ui` episodes |
| **powermetrics** | Cluster frequency and residency, GPU power, package power, interrupt rates | A long-running subprocess at about 1–2 % of a core | **Helper only** | triggered, `thermal` episodes |
| **Exec tracing** (`eslogger exec exit`) | Every short-lived process, exactly | Also needs Full Disk Access; high volume during builds | **Helper only** | triggered when unattributed CPU is high |

The three helper-only collectors each have an unprivileged stand-in: the OS's own hang and spin reports in `DiagnosticReports` (readable without root, verified), the thermal pressure notifications, and the fast process-birth scan.

Triggered captures share one budget: at most one capture set per episode, at most six per hour, never while on battery below 20 %. Capture output goes to compressed files next to the database; the database stores only a reference.

## 6. What gets stored per sweep

Storing 560 process rows every 10 s is about 5 million rows a day, nearly all of them idle. Instead:

- **`app_sample` is complete.** Every app with any activity gets one aggregated row covering *all* its processes. Sums over this table reconcile with system totals.
- **`proc_sample` is selective.** A process gets a detail row only if, in this interval, it is in the top 5 of any dimension (CPU, footprint, footprint growth, disk bytes, wakeups, page-ins) or crosses a floor (over 2 % of a core, over 200 MB footprint, over 20 MB growth, over 5 MB disk I/O). A bitmask records which rule selected it.
- Typical result: 20–40 process rows and 30–60 app rows per sweep.

**As built (phase 4).**

- An app gets its own `app_sample` row when it used at least 0.05 % of a core, did any disk I/O, changed footprint by 1 MB, holds 100 MB or more, or is in focus. Everything else is summed into one synthetic app, `pmon.other` ("idle apps"), so sums still match the system totals. Measured: about 54 app rows and 28 process rows per sweep.
- Three synthetic apps carry what cannot be pinned on a real one: `pmon.other`, `system.unattributed` (unexplained CPU) and `system.foreign` (device bytes not accounted for by readable processes).
- Data from the top stream covers an interval that spans several process ticks and arrives after them. Its counters are split across the ticks it overlaps, in proportion to the overlap, by adding to rows already written; point-in-time values (footprint, process count) go to each tick exactly once. App rows for other users' processes are therefore complete up to one top interval behind the present.
- Process detail rows: top 5 in each of CPU, footprint, footprint growth, disk bytes, wakeups and page-ins, plus anything over 2 % of a core, 200 MB, 20 MB growth or 5 MB of I/O. The thresholds are constants for now, not configuration.
- Over a live run, the sum of all app rows' CPU matched system busy CPU to 99.9 %.

Counters are stored as **per-interval deltas**, gauges as point values. Rollups are then plain `SUM` and `MAX`, with no counter-reset logic in any report query.

## 7. From processes to applications

Reports must say "Chrome", not "Google Chrome Helper (Renderer) pid 4312". Resolution order, cached per process instance:

1. Responsible PID (private API — the same grouping Activity Monitor uses). Covers helpers and XPC services. Own processes only; it returns nothing for foreign ones, which fall through to rules 2–5 (all of which work unprivileged).
2. Enclosing `.app` bundle of the executable path, outermost bundle wins.
3. Launchd coalition ID (`PROC_PIDCOALITIONINFO`).
4. Parent chain up to the first process that resolved by rule 1 or 2. This puts `node` under the terminal or IDE that launched it.
5. Otherwise the executable itself is the app, of kind `daemon` or `cli`.

**As built (phase 4).**

- The collector reads the outermost `.app` bundle and its `Info.plist` once per bundle; the resolver itself is pure and works only from recorded identities, so a replay attributes identically.
- A child inherits its parent's app only when the parent belongs to a bundle. Children of a bare executable (a daemon's shell) do not inherit it.
- Coalition 1 holds the system's own daemons and is never used for attribution. A coalition is claimed by the first bundle process seen in it.
- Kinds: a bundle is `app`, unless it lives in `/System/Library`, `/Library/Apple` or `/usr`, in which case it is `system` (Dock, Finder, WindowManager). A bare executable is `system` under `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin` (and `kernel_task`), `daemon` when started by launchd, otherwise `cli`.
- An app's *main process* (for launch and quit events) is an executable directly in `Contents/MacOS`; helpers and extensions deeper in the bundle are not.
- On this machine: 574 processes resolved to about 400 apps — 409 by executable, 81 by responsible pid, 62 by bundle, 22 by coalition.

Each app has a kind (`app`, `daemon`, `cli`, `system`) so reports can separate "things you can quit" from "things the OS runs". `kernel_task`, `WindowServer`, `mds*`, `backupd` are tagged `system` and reported with an explanation rather than as blame targets — high `kernel_task` usually signals thermal management, not a kernel bug.

## 8. Scoring, episodes and blame

### 8.1 Sluggishness index

Each dimension maps its signals to a sub-score from 0 to 100 through piecewise-linear thresholds held in config (starting values below; tuned in phase 3 against recorded data).

| Dimension | 0 at | 100 at |
|---|---|---|
| cpu | Runnable-wait under 5 % of capacity and P-cluster idle over 30 % | Runnable-wait over 100 % of capacity, or canary latency over 100 ms |
| memory | Pressure normal, memory level above 45 %, no swap-outs | Pressure critical, or swap-outs plus decompressions over 20 k pages/s for 3+ samples (one burst of 30 k/s was measured from a single 768 MB re-touch and was harmless) |
| disk | Mean queue depth under 0.2 | Mean queue depth over 2 sustained (a saturating sequential load measured 2.8–3.0), or free space under 5 % |
| thermal | Nominal | Critical, or speed limit under 50 % |
| gpu | Utilisation under 50 % | Over 95 % sustained |
| ui | No reports | Hang or spin report for the frontmost app |

**Index = the maximum sub-score, not the average.** One saturated resource makes a machine slow regardless of how healthy the other five are. All six sub-scores are stored so the cause is never lost.

### 8.2 Episodes

- Opens when the index is at or above 60 in 3 of the last 5 samples.
- Closes after 30 s continuously below 40. Episodes separated by less than 60 s merge.
- Records: start, end, peak and mean index, mean of each sub-score, dominant dimension, whether the user was present, and the frontmost app.
- Episodes with no user present are kept but excluded from "what slowed me down" reports by default. A backup at 3 a.m. did not slow anyone down.

### 8.3 Blame

For each closed episode, for each app, for each dimension, compute a share from 0 to 1:

| Dimension | Share of an app |
|---|---|
| cpu | Its CPU time, weighted by QoS group (foreground — interactive, initiated, default, legacy: 1.0; utility: 0.5; background, maintenance: 0.2), divided by the weighted total. Measured: background-QoS threads ran 0 % on performance cores, so they compete far less with foreground work. |
| memory | 0.6 × share of total footprint during the episode + 0.4 × share of positive footprint growth over the 10 minutes before it. Holding memory and having just grabbed it both count. |
| disk | Share of bytes read plus written |
| thermal | Share of energy over the 5 minutes before and during the episode. Heat is a lagging effect. |
| gpu | Share of GPU time if that collector is on; otherwise WindowServer-adjacent CPU as a weak proxy, marked low confidence |
| ui | 1.0 for the app named in the hang report |

**Blame score** = Σ over dimensions of (dimension sub-score ÷ 100) × share. Summed over a period and weighted by episode duration, this gives one number per app: **sluggish-minutes caused**. That number is the headline of every report.

**Confidence follows the data path.** A blame row gets high confidence when it rests on native counters, medium when it rests on the top stream (coarser interval, relative energy), and low when it rests on a residual — for example disk blame on `system.foreign`, where the report can say "system processes wrote 4 GB" but not which one. `pmon why` states this in words and, when low-confidence blame dominates an episode, notes that the root helper would resolve it.

**Culprit vs. victim.** During memory episodes the process with the most page-ins is often the one being hurt, not the one causing harm. An app is marked `victim` when its page-in share is high but its footprint and growth shares are low, and `culprit` otherwise. The frontmost app in a memory episode is frequently a victim; reports say so explicitly.

### 8.5 As built (phase 5)

**Scores.** All numbers live in `Thresholds` and can be overridden under `thresholds` in the configuration file.

| Dimension | Signal | 0 at | 100 at | Notes |
|---|---|---|---|---|
| cpu | Foreground wait share: time foreground threads were ready without a core ÷ all core time | 0.05 | 0.75 | Each process's wait is scaled by the foreground share of its CPU, so background threads queueing on efficiency cores do not count |
| cpu | Performance cores busy | 85 % | 100 % → **50** | Busy cores with nothing waiting are capped below the episode threshold |
| cpu | Timer lateness | 10 ms | 150 ms | Idle baseline about 0.2 ms; one-off spikes to 60 ms were seen |
| memory | Kernel pressure level | — | warn 25, critical 75 | The level is sticky, so on its own it stays below an episode |
| memory | Paging: decompressions + page-ins + 4 × (swap-ins + swap-outs), per second, **median of three samples** | 4 000 | 30 000 | Idle baseline: median 90, 95th percentile 3 000, single spikes to 13 000 |
| memory | `memorystatus_level` | 30 % | 8 % → **60** | |
| disk | Queue depth, **median of three samples** | 0.5 | 3.0 | Idle baseline: 95th percentile 0.26, single spikes to 7.6 |
| disk | Free space | 10 % | 2 % → **30** | A full volume is a standing condition, not an episode; it becomes a finding in phase 6 |
| thermal | Thermal level | nominal | fair 20, serious 70, critical 100 | |
| ui | Hang or spin report | — | 100 for the focused app, 50 for another, for 30 s | |
| gpu | — | — | — | Stored as NULL until a GPU collector exists |

**Episodes.** One rule replaces "close after 30 s, merge within 60 s": an episode closes once the index has stayed below 40 for 45 s, and then *ends at the last sample that was still at or above 40*. A flapping signal therefore yields a single episode. An episode opens when 3 of the last 5 samples reach 60 and starts at the first of those. Sleep ends an open episode. An episode left open by a stopped daemon is closed at the last recorded sample when the daemon starts again (it does not continue across restarts).

**Fast cadence.** While an episode is open, or the index is at or above 40, the daemon samples system and processes every 2 s and runs `ps` on every sweep, overriding the relaxed and asleep cadences.

**Blame.** Computed from `app_sample` when the episode closes and once more 60 s later, when top-stream data covering its last seconds has arrived. Only dimensions that averaged at least 10 are blamed, and only shares of at least 2 % are stored. Victims are identified in two dimensions: memory (many page-ins while holding and growing little) and CPU (a large share of the waiting with a small share of the CPU); they are stored with role `victim` and a score of 0. `episode_blame.detail` holds the numbers behind each share (held and grown memory, CPU percentage, megabytes of I/O) so explanations do not depend on raw samples that expire. Thermal blame uses energy, which is only known for natively read processes.

**Commands.** `pmon why [--at TIME]`, `pmon episodes [--since 24h] [--all]`, `pmon mark [note]` (writes a `mark` event), and `pmon calibrate <recording> [--thresholds file] [--samples]`, which replays a recording with candidate thresholds and prints the episodes, their blame and how many marks fall inside them.

### 8.4 Findings outside episodes

Chronic problems that never trip an episode but are worth reporting. A once-a-minute pass over rollups writes rows to `finding`:

| Finding | Rule |
|---|---|
| Leak suspect | Footprint slope positive over 6+ hours of hourly rollups, R² over 0.8, growth over 200 MB |
| Runaway CPU | Over 80 % of a core for 10+ minutes while not frontmost |
| Wakeup storm | Over 1 000 idle wakeups/s sustained (battery and heat) |
| Disk writer | Over 5 GB written in a day by a non-frontmost app (SSD wear, I/O contention) |
| Anomaly vs. baseline | Any metric over 3× the app's own p95 for that hour-of-week |
| Crash loop | Same executable started over 10 times in 10 minutes |
| Background tax | Top apps by resource use while never frontmost in the period |

## 9. Data model

SQLite in WAL mode at `~/Library/Application Support/pmon/pmon.db`, owned by the user. The SQL below is the schema as of migration 2; migration 1 is frozen in `Schema.swift` and later changes are hand-written steps in `Migrations.swift`. One writer, any number of readers. Timestamps are Unix milliseconds UTC. Durations in ms, sizes in bytes, energy in µJ. All fact tables are `WITHOUT ROWID` with the time key first so range scans are sequential.

The shape is a star schema: small dimension tables, narrow fact tables at three resolutions, and derived tables that hold conclusions.

```
 boot ──< process >── executable >── app ──< app_sample / app_rollup_* / episode_blame / finding
              │                                         │
              └──────< proc_sample >── sample ──── sys_sample
                                         │
 event    focus_span    episode ──< episode_blame      capture >── episode
```

### 9.1 Dimensions

```sql
CREATE TABLE host (                 -- one row; static facts for report headers
  host_id INTEGER PRIMARY KEY, model TEXT, chip TEXT,
  p_cores INTEGER, e_cores INTEGER, mem_bytes INTEGER, page_size INTEGER,
  timebase_num INTEGER, timebase_den INTEGER
);

CREATE TABLE boot (                 -- kernel counters reset here
  boot_id INTEGER PRIMARY KEY, session_uuid TEXT NOT NULL UNIQUE,   -- kern.bootsessionuuid
  boot_ts INTEGER NOT NULL, os_version TEXT, os_build TEXT
);

CREATE TABLE app (                  -- the unit of blame
  app_id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,         -- bundle id, or executable path when there is no bundle
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('app','daemon','cli','system')),
  bundle_path TEXT, team_id TEXT, first_seen INTEGER, last_seen INTEGER
);

CREATE TABLE executable (
  exe_id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL
);

CREATE TABLE process (              -- one row per process instance
  proc_id INTEGER PRIMARY KEY,
  boot_id INTEGER NOT NULL REFERENCES boot, pid INTEGER NOT NULL, start_ts INTEGER NOT NULL,
  unique_id INTEGER,                -- kernel unique process id; never reused within a boot
  source INTEGER NOT NULL,          -- 0 native, 1 top stream / ps, 2 root helper
  exe_id INTEGER NOT NULL REFERENCES executable,
  app_id INTEGER NOT NULL REFERENCES app,
  parent_proc_id INTEGER, responsible_proc_id INTEGER,
  uid INTEGER, translated INTEGER NOT NULL DEFAULT 0,       -- running under Rosetta
  attribution TEXT,                 -- which rule in section 7 assigned the app
  args TEXT,                        -- NULL unless the optional collector is on
  first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, exited_ts INTEGER,
  UNIQUE (boot_id, pid, start_ts)
);
CREATE INDEX process_app ON process(app_id, last_seen);
```

### 9.2 Raw facts

```sql
CREATE TABLE sample (               -- one row per collection tick
  sample_id INTEGER PRIMARY KEY,    -- monotonically increasing, time-ordered
  ts INTEGER NOT NULL, boot_id INTEGER NOT NULL,
  dt_ms INTEGER NOT NULL,           -- real elapsed time covered by the system deltas
  proc_dt_ms INTEGER,               -- time covered by this tick's natively read process rows (NULL on tier 1)
  foreign_dt_ms INTEGER,            -- time covered by this tick's top-stream rows (NULL unless a new top sample arrived)
  tier INTEGER NOT NULL,            -- 1 system only, 2 system + processes
  flags INTEGER NOT NULL DEFAULT 0  -- 1 after_wake, 2 degraded, 4 helper_present, 8 foreign_fresh,
);                                  -- 16 episode_open, 32 foreign CPU from ps (covers proc_dt_ms)
CREATE INDEX sample_ts ON sample(ts);

CREATE TABLE sys_sample (
  sample_id INTEGER PRIMARY KEY REFERENCES sample,
  -- cpu, in ms of core time over the interval
  cpu_user_ms INTEGER, cpu_sys_ms INTEGER, cpu_idle_ms INTEGER,
  p_busy_ms INTEGER, e_busy_ms INTEGER, runnable_wait_ms INTEGER,
  unattributed_cpu_ms INTEGER,      -- busy minus natively read processes, over proc_dt_ms
  foreign_cpu_ms INTEGER,           -- measured CPU of other users' processes (top or ps)
  unknown_cpu_ms INTEGER,           -- busy minus own minus foreign: kernel work, short-lived processes; signed
  unattributed_disk_bytes INTEGER,  -- device bytes minus natively read processes' bytes; approximate
  load1 REAL, canary_late_ms REAL,
  -- memory gauges, bytes
  mem_free INTEGER, mem_active INTEGER, mem_inactive INTEGER, mem_wired INTEGER,
  mem_compressed INTEGER, compressor_size INTEGER, swap_used INTEGER, swap_total INTEGER,
  pressure_level INTEGER, mem_level_pct INTEGER,
  -- memory deltas, pages
  d_pageins INTEGER, d_pageouts INTEGER, d_swapins INTEGER, d_swapouts INTEGER,
  d_compressions INTEGER, d_decompressions INTEGER, d_faults INTEGER,
  -- io deltas
  d_disk_read INTEGER, d_disk_write INTEGER, d_disk_ops INTEGER, disk_io_time_ms INTEGER,
  d_net_in INTEGER, d_net_out INTEGER,
  gpu_util_pct INTEGER,
  -- context
  thermal_level INTEGER, on_battery INTEGER, low_power INTEGER, battery_pct INTEGER,
  user_idle_s INTEGER, display_on INTEGER, screen_locked INTEGER, focus_app_id INTEGER,
  proc_count INTEGER, thread_count INTEGER,
  -- scores
  s_cpu INTEGER, s_mem INTEGER, s_disk INTEGER, s_thermal INTEGER, s_gpu INTEGER, s_ui INTEGER,
  slug_index INTEGER
);

CREATE TABLE proc_sample (          -- selective: top-K and above-floor processes only
  sample_id INTEGER NOT NULL, proc_id INTEGER NOT NULL,
  cpu_user_ms INTEGER, cpu_sys_ms INTEGER, cpu_p_ms INTEGER,
  cpu_fg_ms INTEGER,                -- interactive + initiated + default + legacy QoS
  cpu_util_ms INTEGER,              -- utility QoS
  cpu_bg_ms INTEGER,                -- background + maintenance QoS
  runnable_ms INTEGER,
  footprint INTEGER, rss INTEGER, d_footprint INTEGER, d_pageins INTEGER,
  d_disk_read INTEGER, d_disk_write INTEGER,
  d_wakeups INTEGER, d_csw INTEGER, d_energy_uj INTEGER, d_instructions INTEGER,
  threads INTEGER,
  d_net_in INTEGER, d_net_out INTEGER, d_gpu_ms INTEGER,    -- NULL unless optional collectors on
  mem_compressed INTEGER,           -- top stream only
                                    -- top rows: total CPU is in cpu_user_ms, cpu_sys_ms is 0 (top has no split)
  fidelity INTEGER NOT NULL DEFAULT 0,   -- 0 native, 1 top stream, 2 ps (CPU only)
  reason INTEGER NOT NULL,          -- bitmask: which selection rule kept this row
  PRIMARY KEY (sample_id, proc_id)  -- columns a path cannot supply are NULL, never 0
) WITHOUT ROWID;
CREATE INDEX proc_sample_proc ON proc_sample(proc_id, sample_id);

CREATE TABLE app_sample (           -- complete: every active app, all its processes summed
  sample_id INTEGER NOT NULL, app_id INTEGER NOT NULL,
  proc_count INTEGER,
  cpu_ms INTEGER, cpu_p_ms INTEGER, cpu_fg_ms INTEGER, cpu_util_ms INTEGER, cpu_bg_ms INTEGER, runnable_ms INTEGER,
  footprint INTEGER, d_footprint INTEGER, d_pageins INTEGER,
  d_disk_read INTEGER, d_disk_write INTEGER, d_wakeups INTEGER, d_energy_uj INTEGER,
  d_net_in INTEGER, d_net_out INTEGER, d_gpu_ms INTEGER,
  is_focus INTEGER NOT NULL DEFAULT 0,
  fidelity INTEGER NOT NULL DEFAULT 0,   -- 0 native, 1 top stream, 2 ps, 3 residual
  PRIMARY KEY (sample_id, app_id)   -- includes the synthetic apps system.foreign and system.unattributed
) WITHOUT ROWID;
CREATE INDEX app_sample_app ON app_sample(app_id, sample_id);

CREATE TABLE volume_sample (        -- slow tier
  sample_id INTEGER NOT NULL, mount TEXT NOT NULL, total INTEGER, free INTEGER,
  PRIMARY KEY (sample_id, mount)
) WITHOUT ROWID;

CREATE TABLE event (                -- anything that happens at a point in time
  event_id INTEGER PRIMARY KEY, ts INTEGER NOT NULL,
  kind TEXT NOT NULL,               -- focus, thermal, pressure, sleep, wake, power, proc_start,
                                    -- proc_exit, diag_report, hang, collector_backoff, config
  app_id INTEGER, proc_id INTEGER, value INTEGER, detail TEXT   -- detail is JSON
);
CREATE INDEX event_ts ON event(ts);
CREATE INDEX event_kind ON event(kind, ts);

CREATE TABLE focus_span (           -- derived from focus events; makes "was it frontmost?" a join
  start_ts INTEGER PRIMARY KEY, end_ts INTEGER, app_id INTEGER NOT NULL
) WITHOUT ROWID;
```

### 9.3 Conclusions

```sql
CREATE TABLE episode (
  episode_id INTEGER PRIMARY KEY,
  start_ts INTEGER NOT NULL, end_ts INTEGER,          -- NULL while open
  peak_index INTEGER, mean_index INTEGER,
  dominant TEXT,                                       -- cpu | memory | disk | thermal | gpu | ui
  m_cpu INTEGER, m_mem INTEGER, m_disk INTEGER, m_thermal INTEGER, m_gpu INTEGER, m_ui INTEGER,
  user_present INTEGER, focus_app_id INTEGER,
  on_battery INTEGER, low_power INTEGER, after_wake INTEGER
);
CREATE INDEX episode_ts ON episode(start_ts);

CREATE TABLE episode_blame (
  episode_id INTEGER NOT NULL, app_id INTEGER NOT NULL, dim TEXT NOT NULL,
  share REAL NOT NULL,              -- 0..1 of this dimension during the episode
  score REAL NOT NULL,              -- share × dimension weight; summable across dims and episodes
  role TEXT NOT NULL CHECK (role IN ('culprit','victim')),
  confidence INTEGER NOT NULL,      -- 0 low (proxy or reduced fidelity) .. 2 high
  top_proc_id INTEGER, peak_value INTEGER,
  detail TEXT,                      -- JSON: the numbers behind the share
  PRIMARY KEY (episode_id, app_id, dim)
) WITHOUT ROWID;
CREATE INDEX blame_app ON episode_blame(app_id);

CREATE TABLE capture (              -- heavy artefacts live in files; this is the pointer
  capture_id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, episode_id INTEGER,
  kind TEXT NOT NULL, proc_id INTEGER, path TEXT NOT NULL, bytes INTEGER, summary TEXT
);

CREATE TABLE finding (
  finding_id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL,
  app_id INTEGER NOT NULL, severity INTEGER NOT NULL,
  evidence TEXT NOT NULL,           -- JSON: the numbers that triggered it
  first_ts INTEGER, last_ts INTEGER, status TEXT NOT NULL DEFAULT 'open'
);

CREATE TABLE app_baseline (         -- what "normal" is for each app
  app_id INTEGER NOT NULL, metric TEXT NOT NULL, hour_of_week INTEGER NOT NULL,
  p50 REAL, p95 REAL, n INTEGER, updated INTEGER,
  PRIMARY KEY (app_id, metric, hour_of_week)
) WITHOUT ROWID;
```

### 9.4 Rollups and retention

Three grains with identical columns (`_1m`, `_1h`, `_1d`), so a report picks a table by time range and the query text does not change.

```sql
CREATE TABLE app_rollup_1h (
  bucket_ts INTEGER NOT NULL, app_id INTEGER NOT NULL,
  covered_ms INTEGER,               -- observed time in bucket; the denominator for rates
  cpu_ms INTEGER, cpu_fg_ms INTEGER, cpu_util_ms INTEGER, cpu_bg_ms INTEGER, cpu_pct_max REAL,
  footprint_avg INTEGER, footprint_max INTEGER, footprint_last INTEGER,
  disk_read INTEGER, disk_write INTEGER, wakeups INTEGER, energy_uj INTEGER, pageins INTEGER,
  net_in INTEGER, net_out INTEGER,
  focus_ms INTEGER,                 -- time frontmost
  sluggish_ms INTEGER,              -- time inside episodes while this app was running
  blame REAL,                       -- sluggish-minutes caused
  proc_max INTEGER, launches INTEGER,
  PRIMARY KEY (bucket_ts, app_id)
) WITHOUT ROWID;
CREATE INDEX app_rollup_1h_app ON app_rollup_1h(app_id, bucket_ts);

CREATE TABLE sys_rollup_1h (
  bucket_ts INTEGER PRIMARY KEY, covered_ms INTEGER,
  cpu_busy_pct_avg REAL, cpu_busy_pct_max REAL, runnable_wait_ms INTEGER,
  mem_compressed_max INTEGER, swap_used_max INTEGER, pressure_warn_ms INTEGER, pressure_crit_ms INTEGER,
  swapouts INTEGER, pageins INTEGER, disk_read INTEGER, disk_write INTEGER, disk_io_time_ms INTEGER,
  thermal_throttled_ms INTEGER, gpu_util_avg REAL,
  slug_index_avg REAL, slug_index_max INTEGER, sluggish_ms INTEGER, episodes INTEGER,
  awake_ms INTEGER, user_present_ms INTEGER, on_battery_ms INTEGER
);
```

| Data | Kept | Estimated size |
|---|---|---|
| `sys_sample`, `proc_sample`, `app_sample`, `sample` | 48 hours | about 50 MB |
| `*_rollup_1m` | 14 days | about 50 MB |
| `*_rollup_1h` | 13 months | about 45 MB |
| `*_rollup_1d`, `episode`, `episode_blame`, `finding`, `event` | Indefinitely | a few MB per year |
| Raw samples inside an episode, plus 5 min either side | 30 days | small |
| Capture files | 30 days or 500 MB cap | capped |

Steady state is under 200 MB. Deletion is by `sample_id` range, which is a cheap prefix delete on every fact table; `PRAGMA auto_vacuum=INCREMENTAL` returns the space.

### 9.5 Why this shape reports well

- **Blame is pre-computed and additive.** "Who slowed me down this month" is a `SUM` over `episode_blame`, not a re-analysis of raw samples that have already expired.
- **App-level facts are complete; process-level facts are detail.** Totals are always right; drill-down exists where it is interesting.
- **Deltas, not counters.** No report handles reboots, PID reuse or counter wrap.
- **`covered_ms` on every rollup.** Rates stay correct when the Mac slept for half the bucket.
- **Identical rollup grains.** One query template serves an hour, a week or a year.
- **Context is denormalised onto facts** (`focus_app_id`, `is_focus`, `user_present`). The common filters need no join.
- **Fidelity travels with the data.** Every fact and blame row says which path produced it, and missing metrics are `NULL` rather than zero. Reports can show a number, show it as approximate, or say "not measurable without the helper" — never a silently wrong zero. Installing or removing the helper needs no migration.

### 9.6 Report queries

Top offenders over the last 7 days — the headline report:

```sql
SELECT a.name, a.kind,
       ROUND(SUM(b.score * (e.end_ts - e.start_ts)) / 60000.0, 1) AS sluggish_min_caused,
       COUNT(DISTINCT e.episode_id)                               AS episodes,
       (SELECT dim FROM episode_blame b2 WHERE b2.app_id = a.app_id
         GROUP BY dim ORDER BY SUM(score) DESC LIMIT 1)           AS mostly_via
FROM episode e
JOIN episode_blame b USING (episode_id)
JOIN app a USING (app_id)
WHERE e.start_ts >= :since AND e.user_present = 1 AND b.role = 'culprit'
GROUP BY a.app_id ORDER BY sluggish_min_caused DESC LIMIT 10;
```

What was happening at a given moment:

```sql
SELECT a.name, s.cpu_ms * 100.0 / sm.dt_ms AS cpu_pct, s.footprint / 1048576 AS mb,
       s.d_disk_write / 1024 AS kb_written, s.is_focus
FROM sample sm JOIN app_sample s USING (sample_id) JOIN app a USING (app_id)
WHERE sm.sample_id = (SELECT sample_id FROM sample WHERE ts <= :ts AND tier = 2
                      ORDER BY ts DESC LIMIT 1)
ORDER BY s.cpu_ms DESC LIMIT 15;
```

Background tax — resources used by apps while not in front:

```sql
SELECT a.name, SUM(r.cpu_ms) / 60000 AS cpu_min, MAX(r.footprint_max) / 1048576 AS peak_mb,
       SUM(r.energy_uj) / 3.6e9 AS wh, SUM(r.focus_ms) * 100.0 / SUM(r.covered_ms) AS pct_in_front
FROM app_rollup_1h r JOIN app a USING (app_id)
WHERE r.bucket_ts >= :since AND a.kind = 'app'
GROUP BY a.app_id HAVING pct_in_front < 5 ORDER BY cpu_min DESC LIMIT 10;
```

## 10. Reporting surfaces

| Command | Shows |
|---|---|
| `pmon status` | Current index, sub-scores, top apps right now, collector health |
| `pmon why [--at TIME]` | The current or nearest episode: cause, culprits, victims, and one sentence in plain language |
| `pmon top --since 7d` | Offender ranking by sluggish-minutes caused |
| `pmon episodes --since 24h` | Episode timeline |
| `pmon app <name>` | One app: trend, baseline, episodes it caused, findings |
| `pmon findings` | Leaks, runaways, storms, anomalies |
| `pmon report --since 7d --html` | Self-contained HTML file: timeline, offenders, findings |
| `pmon export --format json\|csv` | Raw access for other tools |

Every command takes `--json`. The HTML report is a generated static file, not a server; nothing listens on a port. A menu-bar item showing the live index is a natural later addition and needs no schema change.

`pmon why` is the most important output. Example of the target wording:

> 14:28–14:41 (13 min), memory pressure, peak 84. Docker Desktop held 3.1 GB and Chrome grew by 900 MB in the 10 minutes before. Xcode (frontmost) was the main victim: 41 k page-ins. Swap was 92 % full.

## 11. Privacy and safety

- All data stays on the machine. No network code in the daemon.
- Database and captures are readable only by the owner (mode 0600 / 0700).
- Not collected by default: command-line arguments, window titles, URLs, file names, network peers.
- Stack captures can contain symbol names from the user's own code; they are local and expire after 30 days.
- The default install runs entirely as the user and touches nothing outside the home directory.
- The optional root helper accepts requests only from the installing user's `pmond` (code-signature and uid check), takes pids as its only input, and runs a fixed list of commands. It never executes caller-supplied paths or arguments.

## 12. Risks and open questions

| Risk | Mitigation |
|---|---|
| Private responsibility API changes or disappears | Four fallback rules in section 7; `process.attribution` records which rule was used so regressions are visible |
| Score thresholds are guesses | Thresholds live in config; phase 3 calibrates against recorded data and manual "it felt slow now" markers (`pmon mark`) |
| Memory blame is inherently fuzzy — pressure is a collective state | Report shares and culprit/victim roles with a confidence level, not a single guilty app |
| A process's CPU between its last sweep and its exit is never read (measured in phase 2: a 30 s, 4-thread load lost its final 1.6 s, 5.6 % of its total; complete intervals were within 2 %, and CPU plus wait matched wall time × threads within 0.1 %) | The loss lands in `unattributed_cpu_ms`, so totals still reconcile; exec tracing through the root helper is the only exact fix |
| Processes living under 10 s are invisible to the sweep | `unattributed_cpu_ms` detects it; triggered exec tracing identifies them |
| GPU per-process data is fragile across OS releases | Optional collector, low-confidence proxy otherwise |
| `top` output format changes with an OS update | Columns pinned with `-stats`, header validated at start, automatic fallback to `ps` (CPU only) with a visible event |
| `top` child is the largest single cost (about 0.3 % of a core) | 30 s interval, paused when idle or display asleep, first to be slowed by the self-limiter |
| A system daemon's disk I/O cannot be named without root | Reported as combined `system.foreign` with low confidence; the well-known suspects (`mds_stores`, `backupd`, `cloudd`) are listed with their CPU as a hint; the helper resolves it |
| Foreign processes sampled at 30 s can miss short bursts | `ps` burst at 5 s whenever the index rises; system-level counters still catch the burst itself at 5 s |
| Resolved in phase 0: `ri_runnable_time` includes on-core time | Wait is computed as runnable minus CPU time (section 2.1, row 2) |
| Open: counter and timer behaviour across sleep; swap-out rates under heavy pressure | Lid-close test in subphase 1.2; memory scenario recording in phase 5 |
| Open: per-core or per-cluster storage? | Per-cluster by default; revisit if single-thread saturation proves hard to see |

## 13. Implementation phases

**Phase 0 — Validate assumptions.** Throwaway Swift probes for the open questions in sections 2 and 12, under synthetic CPU, memory and disk load; a day-long run of the `top` stream to confirm its cost and parse stability. Outcome: confirmed metric list and corrected thresholds. No product code.

**Phase 1 — Collect and store (own processes).** Swift package skeleton, scheduler, system collectors, native process sweep, delta engine, sleep handling, schema, batched writer, LaunchAgent install, `pmon status`. Outcome: the daemon runs for days and the raw tables fill correctly for the user's processes.

**Phase 2 — Full coverage without root.** Top-stream child with supervision and pause/resume, `ps` burst, residual accounting with the two synthetic apps, fidelity flags end to end. Outcome: every process on the machine is represented, totals reconcile with system counters, combined cost stays under 0.5 % of a core.

**Phase 3 — Applications and context.** App attribution chain, session signals (frontmost app, user presence), event collectors, diagnostic-report ingestion, `focus_span`, selective `proc_sample` rule, `app_sample`. Outcome: `pmon status` shows apps, not PIDs, and matches Activity Monitor's grouping.

**Phase 4 — Detect and blame.** Scorer, episode detector, blame with culprit/victim roles and confidence, `pmon why`, `pmon episodes`, `pmon mark`, threshold calibration against a week of real data. Outcome: the tool explains real slowdowns correctly.

**Phase 5 — History and reports.** Rollups at three grains, retention, baselines, findings pass, `pmon top`, `pmon app`, `pmon findings`, HTML report, export. Outcome: weekly report answers the headline question.

**Phase 6 — Unprivileged optional collectors.** Triggered captures for own processes (stack, footprint, per-thread), fast process-birth scan, GPU and network collectors behind config switches, shared capture budget. Outcome: deep evidence for episodes, still without root.

**Phase 7 — Optional root helper.** Stateless helper with installer and uninstaller, native metrics for foreign processes, spindump, powermetrics, exec tracing. Outcome: estimated values become exact; removing the helper degrades cleanly.

**Phase 8 — Polish.** Menu-bar indicator, notifications for long episodes and new findings, schema migrations, documentation.
