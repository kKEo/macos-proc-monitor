# pmon — detailed phased implementation plan

Companion to `DESIGN.md`. The design says *what*; this says *in what order, in which files, and how each step is proven done*.

**Numbering:** phase `N` → subphase `N.M` → task `N.M.K`. A subphase is one logical group of work that can be reviewed and committed on its own. Each has a one-line purpose, its tasks, the files it touches and a "done when" check.

Toolchain on this machine: Swift 6.3.2, Xcode installed, system SQLite, git 2.46. The project directory is not yet a git repository.

## Ground rules

- **Every phase ends with something runnable** and an exit check that is measured, not judged.
- **Rootless first.** Nothing before phase 8 may require root.
- **Riskiest assumptions first.** Phase 0 exists to change the design cheaply if `top` streaming or the kernel counters do not behave as probed.
- **Record, then replay.** From phase 1 the daemon can dump raw collector readings to a file and the pipeline can run from one. Scoring, episodes and blame are developed against recordings.
- **Schema migrations from the first commit** (`PRAGMA user_version`).
- **One dependency at most:** `swift-argument-parser` for the CLI.

## Package layout

```
Package.swift
Sources/
  CPmonSys/          C shim: libproc, rusage_info_v6, kinfo_proc, private responsibility symbol
  PmonCore/
    Model/           RawReading, Delta, SystemSample, ProcSample, AppSample, Episode, Blame
    Collect/         Collector protocol; System*, NativeProcess, TopStream, PsBurst, Session, Events
    Engine/          Scheduler, Clock, DeltaEngine, Residuals, Selection, SelfLimiter, Pipeline
    Attribute/       ProcessIdentity, AppResolver
    Score/           Thresholds, Scorer, EpisodeDetector, BlameCalculator, Findings
    Store/           Database, Migrations, Writer, Rollup, Retention, Queries
    Replay/          Recorder, Replayer
    Config/          Config (Codable, JSON)
  pmond/             daemon entry point
  pmon/              CLI
  pmon-stress/       synthetic load tool (not shipped)
  pmon-helper/       optional root helper (phase 8)
Tests/PmonCoreTests/ unit and replay tests
Tests/Fixtures/      recorded readings, top output, process trees, diagnostic reports
Support/             LaunchAgent plist template, HTML report template
Experiments/         phase 0 throwaway probes
```

Dependency direction: `Model` ← `Collect`, `Engine`, `Attribute`, `Score` ← `Store` ← executables. `Score` never touches collectors, so it behaves identically live and in replay.

## Overview

| # | Phase | Subphases | Depends on | Size |
|---|---|---|---|---|
| 0 | Validate assumptions — **done 2026-11-20, decision: go** (findings in `DESIGN.md` 2.1) | 0.1 – 0.5 | — | 1–2 days |
| 1 | Foundation — **implemented 2026-11-20**; daemon installed, 24-hour exit check in progress | 1.1 – 1.7 | 0 | 3–5 days |
| 2 | Own processes — **implemented 2026-11-20** | 2.1 – 2.5 | 1 | 3–5 days |
| 3 | Full coverage without root — **implemented 2026-11-20** | 3.1 – 3.5 | 2 | 3–5 days |
| 4 | Applications and context — **implemented 2026-11-20** | 4.1 – 4.6 | 3 | 3–5 days |
| 5 | Detect and blame — **implemented 2026-11-20**; calibration against a week of real use still pending | 5.1 – 5.6 | 4 | 1–2 weeks |
| 6 | History and reports — **implemented 2026-11-20** | 6.1 – 6.6 | 5 | 1–2 weeks |
| 7 | Optional collectors, unprivileged | 7.1 – 7.5 | 5 | 3–5 days |
| 8 | Optional root helper | 8.1 – 8.4 | 3, 7.1 | 3–5 days |
| 9 | Polish | 9.1 – 9.4 | 6 | 1–2 days |

Phases 0–5 are the minimum useful product. Phases 6 and 7 are independent of each other.

---

# Phase 0 — Validate assumptions

Throwaway probes that answer the questions the design depends on. No product code until these are answered.

### 0.1 Experiment harness
*Purpose: a minimal place to run probes and capture their output.*

- 0.1.1 Create `Experiments/` with one Swift script per probe and a shared helper for 1 s sampling to CSV.
- 0.1.2 Write a minimal load generator (busy threads, memory allocate-and-touch, `dd` read/write) — the seed of `pmon-stress`.

**Files:** `Experiments/*.swift`. **Done when:** a probe can be run with one command and leaves a CSV.

### 0.2 Kernel counter behaviour
*Purpose: confirm the native per-process and system counters mean what the design assumes.*

- 0.2.1 `ri_runnable_time`: run 16 busy threads on 8 cores; compare the summed delta with the expected wait time.
- 0.2.2 Mach time conversion: confirm CPU time of a single busy thread equals wall time after applying the timebase.
- 0.2.3 Memory pressure: allocate until pressure reaches warn, then critical; record pressure level, `memorystatus_level`, swap-out, decompression and page-in rates at 1 s.
- 0.2.4 Disk: record IOKit busy-time and byte deltas during heavy sequential read and write.
- 0.2.5 Per-QoS CPU: run the same load at background and at user-initiated QoS; confirm it lands in the expected counters.

**Done when:** each counter is marked confirmed, adjusted (with the corrected interpretation) or dropped.

### 0.3 The `top` stream
*Purpose: prove the unprivileged path for system processes is stable and cheap.*

- 0.3.1 Run `top -l 0 -s 30 -stats …` for 8 hours; log its own CPU, memory, and every sample that fails to parse.
- 0.3.2 Compare cumulative columns (`TIME`, `IDLEW`, `INSTRS`, `MEM`) with native counters for the same own pids over 10 minutes.
- 0.3.3 `SIGSTOP` for 10 minutes then `SIGCONT`; inspect the next two samples.
- 0.3.4 Capture real output samples (normal, under load, with long process names) as parser fixtures.
- 0.3.5 Measure `ps -p <foreign pids>` cost at 5 s cadence for 10 minutes.

**Done when:** average cost per sample and the error rate are known; cumulative columns agree with native ones within 5 %.

### 0.4 Session and lifecycle behaviour
*Purpose: confirm a UI-less LaunchAgent can see what it needs, and what sleep does.*

- 0.4.1 Minimal LaunchAgent that logs `NSWorkspace` activation notifications and input idle time; switch apps and check the log.
- 0.4.2 Sleep the machine mid-recording; inspect timers, counters and the first sample after wake.
- 0.4.3 Confirm FSEvents delivery for both `DiagnosticReports` directories and that report headers are readable.

**Done when:** each signal is confirmed available from a LaunchAgent, or an alternative is noted.

### 0.5 Findings and go / no-go
*Purpose: fold the results back into the design before building on it.*

- 0.5.1 Append a findings table to `DESIGN.md` section 2.
- 0.5.2 Adjust starting thresholds in design section 8.1 from the recorded pressure curves.
- 0.5.3 Decide: keep the `top` stream, or plan phase 3 as `ps`-only.

**Phase exit check:** every open question in design sections 2 and 12 has an answer, and the phase 3 approach is fixed.

---

# Phase 1 — Foundation

The skeleton everything else plugs into, ending with a daemon that records machine-level condition.

### 1.1 Project skeleton
*Purpose: a building, testable package.*

- 1.1.1 `git init`, `.gitignore`, `Package.swift` with all targets (empty where not yet needed).
- 1.1.2 `CPmonSys`: module map and header exposing libproc, `rusage_info_v6`, `kinfo_proc`, and the responsibility symbol.
- 1.1.3 Add `swift-argument-parser`; `pmon --version` runs.
- 1.1.4 Test target with one passing test; `swift build && swift test` is the single verification command.

**Files:** `Package.swift`, `Sources/CPmonSys/*`, `Sources/pmon/main.swift`. **Done when:** clean checkout builds and tests pass.

### 1.2 Time and scheduling
*Purpose: deterministic, sleep-aware ticking.*

- 1.2.1 `Clock` protocol (wall, monotonic, continuous) with `SystemClock` and `FakeClock`.
- 1.2.2 `Scheduler`: named tiers with intervals, coalesced firing, `utility` QoS.
- 1.2.3 Sleep detection from the gap between monotonic and continuous time; affected ticks are flagged. Includes the lid-close test carried over from phase 0.
- 1.2.4 Canary: measure how late a strict zero-leeway `userInitiated` timer fires, relative to its idle baseline.

**Files:** `Engine/Clock.swift`, `Engine/Scheduler.swift`. **Done when:** fake-clock tests show correct tick order, interval lengths and sleep flags.

### 1.3 Storage core
*Purpose: a database layer that will not need rewriting later.*

- 1.3.1 `Database`: open, WAL, pragmas, prepared-statement cache, transaction helper, typed bind and read.
- 1.3.2 `Migrations`: runner on `user_version`; migration 1 creates the full schema from design section 9.
- 1.3.3 Dimension upsert helpers with in-memory id caches (`boot`, `host`, later `app`, `executable`, `process`).
- 1.3.4 Read-only connection mode for the CLI.

**Files:** `Store/Database.swift`, `Store/Migrations.swift`, `Store/Dimensions.swift`. **Done when:** migration applies to an empty file; a second run is a no-op; reader and writer work concurrently.

### 1.4 System collectors
*Purpose: every machine-level counter of the default tier.*

- 1.4.1 `Collector` protocol: tier, cost budget, `collect() -> RawReading`.
- 1.4.2 CPU ticks per core, aggregated per P and E cluster; load average.
- 1.4.3 VM statistics, pressure sysctls, swap usage.
- 1.4.4 Disk statistics from IOKit; network counters per interface.
- 1.4.5 Slow tier: volume free space, battery and power state.

**Files:** `Collect/Collector.swift`, `Collect/System*.swift`, `Model/RawReading.swift`. **Done when:** values agree with `vm_stat`, `iostat`, `netstat -ib` and `top` headers within rounding.

### 1.5 System delta engine and writer
*Purpose: turn cumulative readings into stored interval rows.*

- 1.5.1 `DeltaEngine` for system counters: per-interval deltas, counter reset and wrap handling.
- 1.5.2 Boot detection; `boot` and `host` rows.
- 1.5.3 `Pipeline`: collectors → deltas → sample model, driven by the scheduler.
- 1.5.4 `Writer`: one transaction per tick into `sample` and `sys_sample`.

**Files:** `Engine/DeltaEngine.swift`, `Engine/Pipeline.swift`, `Store/Writer.swift`. **Done when:** tests cover reset, wrap and a sleep-spanning interval being discarded.

### 1.6 Record and replay
*Purpose: make every later phase testable against recorded reality.*

- 1.6.1 `Recorder`: raw readings with timestamps to newline-delimited JSON, size-capped.
- 1.6.2 `Replayer`: feeds a recording into the pipeline using a fake clock.
- 1.6.3 Golden test: record → replay → identical database rows.

**Files:** `Replay/*.swift`. **Done when:** the golden test passes and a recording can be made with `pmond --record <file>`.

### 1.7 Daemon, install and first CLI
*Purpose: running under launchd and showing something.*

- 1.7.1 `Config`: Codable with defaults, loaded from `~/Library/Application Support/pmon/config.json`.
- 1.7.2 `pmond` entry point: run loop, `SIGTERM` handling, single-instance lock, minimal logging.
- 1.7.3 `pmon install` / `uninstall`: LaunchAgent plist in `~/Library/LaunchAgents`, load and unload.
- 1.7.4 `pmon status`: latest system sample and daemon health.

**Files:** `Config/Config.swift`, `Sources/pmond/main.swift`, `Sources/pmon/*`, `Support/*.plist`.

**Phase exit check:** the daemon runs 24 hours under launchd, survives a sleep/wake cycle, uses under 0.1 % of a core, and `sys_sample` has no gaps other than sleep.

---

# Phase 2 — Own processes

Per-process data for everything the user owns, from the native kernel interface.

### 2.1 Native process collector
*Purpose: one cheap sweep over all readable processes.*

- 2.1.1 Pid enumeration with a reusable buffer.
- 2.1.2 `proc_pid_rusage` v6 reading into a flat struct; Mach time conversion at the boundary.
- 2.1.3 Task info: threads, running threads, context switches, syscalls, faults.
- 2.1.4 Own / foreign classification from the call result, cached per process instance.

**Files:** `Collect/NativeProcess.swift`. **Done when:** sweep of 600 processes stays under 10 ms.

### 2.2 Process identity
*Purpose: a stable key and descriptive facts for every process, including foreign ones.*

- 2.2.1 Identity reader: path, parent, uid, start time, unique id, coalition id, Rosetta flag.
- 2.2.2 Instance key and cache; detection of new, exited and reused pids.
- 2.2.3 `executable` and `process` rows; `last_seen` and `exited_ts` maintenance, batched.

**Files:** `Attribute/ProcessIdentity.swift`, `Store/Dimensions.swift`. **Done when:** identity is filled for 100 % of pids, own and foreign.

### 2.3 Process delta engine
*Purpose: correct per-interval numbers per process instance.*

- 2.3.1 Per-instance previous-reading state with eviction on exit.
- 2.3.2 First-sight handling: a new process contributes its lifetime counters only if it started within the interval.
- 2.3.3 Derived values: foreground vs. background QoS CPU, footprint growth.
- 2.3.4 Temporary full write to `proc_sample` (selection arrives in 4.3).

**Files:** `Engine/DeltaEngine.swift`, `Model/ProcSample.swift`. **Done when:** pid reuse and exit never yield negative or absurd deltas in tests.

### 2.4 Self-limiting
*Purpose: the monitor never becomes the problem.*

- 2.4.1 Measure each collector's duration per tick.
- 2.4.2 `SelfLimiter`: sweep-time and 5-minute CPU budget; back-off ladder; `collector_backoff` event.
- 2.4.3 Self-cost shown in `pmon status`.

**Files:** `Engine/SelfLimiter.swift`. **Done when:** an artificially slowed collector triggers back-off in a test.

### 2.5 Stress tool and verification
*Purpose: known loads to check the numbers against.*

- 2.5.1 `pmon-stress cpu|memory|disk|forkstorm` with duration and intensity options.
- 2.5.2 `pmon status` lists top processes by CPU and footprint.
- 2.5.3 Accuracy checks: stress CPU matches wall time × threads within 5 %; footprint matches Activity Monitor within 5 %.

**Files:** `Sources/pmon-stress/*`.

**Phase exit check:** summed own-process CPU never exceeds system busy CPU for the same interval; accuracy checks in 2.5.3 pass.

---

# Phase 3 — Full coverage without root

Every process on the machine is represented and totals reconcile, with no privileges.

### 3.1 Top stream parser
*Purpose: turn `top` log output into readings safely.*

- 3.1.1 Incremental line parser: sample boundaries, header row, fixed-order columns.
- 3.1.2 Value parsing: unit suffixes, `+`/`-` trend markers, time formats, thread `n/m` form.
- 3.1.3 Header validation against the pinned `-stats` list.
- 3.1.4 Fixture tests: normal, truncated sample, changed header, very long names.

**Files:** `Collect/TopParser.swift`, `Tests/Fixtures/top/*`. **Done when:** all fixtures parse or fail explicitly; no silent misparse.

### 3.2 Top stream supervision
*Purpose: a child process that is always in a known state.*

- 3.2.1 Spawn with pipe, non-blocking read on a dispatch source.
- 3.2.2 Lifecycle: lazy start, restart with back-off, termination with the daemon, orphan cleanup at start.
- 3.2.3 Pause and resume with `SIGSTOP` / `SIGCONT` from the cadence policy.
- 3.2.4 The child's own cost is attributed to pmon in self-cost.

**Files:** `Collect/TopStream.swift`. **Done when:** killing the child, or the daemon, leaves no stray `top` and recovers within one interval.

### 3.3 Foreign processes in the delta engine
*Purpose: one engine, three sources.*

- 3.3.1 Map top rows to process instances via the identity cache; keep foreign rows only.
- 3.3.2 Deltas from cumulative columns only; rate columns ignored.
- 3.3.3 `PsBurstCollector`: CPU time for foreign pids, switched on and off by the engine.
- 3.3.4 Merge rule when both top and ps cover the same interval.

**Files:** `Collect/PsBurst.swift`, `Engine/DeltaEngine.swift`. **Done when:** a foreign process shows consistent CPU from both sources in a comparison test.

### 3.4 Residuals and fidelity
*Purpose: totals that always reconcile, and honesty about precision.*

- 3.4.1 `Residuals`: `system.foreign` and `system.unattributed` per interval for CPU and disk.
- 3.4.2 `fidelity` and `source` on every row; metrics a path cannot supply written as `NULL`.
- 3.4.3 Interval alignment: foreign data at 30 s spread over the 10 s ticks it covers, flagged `foreign_fresh`.

**Files:** `Engine/Residuals.swift`, `Store/Writer.swift`. **Done when:** residuals are never negative beyond rounding in a one-hour run.

### 3.5 Fallback and verification
*Purpose: degrade visibly, never wrongly.*

- 3.5.1 On parser or header failure: switch to `ps` only, write an event, retry `top` hourly.
- 3.5.2 `pmon status` shows coverage: counts of native, top, ps-only processes and current mode.
- 3.5.3 Reconciliation test over one hour.

**Phase exit check:** (own + foreign + unattributed CPU) equals system busy CPU within 2 % over an hour; daemon plus child stay under 0.5 % of a core and 40 MB.

---

# Phase 4 — Applications and context

Turns processes into applications and adds the context needed to interpret a sample.

### 4.1 App resolver
*Purpose: every process belongs to a named application.*

- 4.1.1 Rule 1: responsible pid. Rule 2: outermost enclosing `.app` bundle, with bundle id and name from `Info.plist`.
- 4.1.2 Rule 3: coalition. Rule 4: parent chain. Rule 5: executable as its own app.
- 4.1.3 Kind classification (`app`, `daemon`, `cli`, `system`) and the list of well-known system processes.
- 4.1.4 `app` rows; `process.attribution` records the rule used.
- 4.1.5 Fixture tests: browser helpers, XPC services, a terminal running `node`, a system daemon.

**Files:** `Attribute/AppResolver.swift`, `Tests/Fixtures/trees/*`. **Done when:** grouping matches Activity Monitor for the ten most active apps.

### 4.2 App aggregation
*Purpose: the complete, summable fact table.*

- 4.2.1 Aggregate process deltas per app per tick, including the two synthetic apps.
- 4.2.2 Lowest-fidelity-wins rule when an app mixes own and foreign processes.
- 4.2.3 Write `app_sample`.

**Files:** `Engine/Pipeline.swift`, `Model/AppSample.swift`. **Done when:** `SUM(app_sample.cpu_ms)` equals system busy CPU within 2 %.

### 4.3 Selective process storage
*Purpose: keep detail only where it is interesting.*

- 4.3.1 `Selection`: top-K per dimension and floor rules, thresholds in config.
- 4.3.2 `reason` bitmask; replace the temporary full write from 2.3.4.
- 4.3.3 Test that unselected processes are still counted in `app_sample`.

**Files:** `Engine/Selection.swift`. **Done when:** `proc_sample` averages under 40 rows per sweep.

### 4.4 Session signals
*Purpose: know what the user was doing.*

- 4.4.1 `SessionCollector`: frontmost app notifications, input idle time, screen lock, display state.
- 4.4.2 `focus_span` maintenance; `focus_app_id` and `is_focus` denormalised onto samples.
- 4.4.3 User-present rule (input within N seconds, display on, not locked).

**Files:** `Collect/Session.swift`. **Done when:** `focus_span` matches a hand-timed sequence of app switches.

### 4.5 Events
*Purpose: point-in-time facts the OS already announces.*

- 4.5.1 Memory pressure, thermal state, power source, Low Power Mode, sleep and wake → `event`.
- 4.5.2 Diagnostic-report watcher: FSEvents on both directories, header parser, link to app; `diag_report` and `hang` events.
- 4.5.3 Notable process starts and exits (apps, and anything that was selected).

**Files:** `Collect/Events.swift`, `Collect/DiagReports.swift`. **Done when:** each event type appears when triggered by hand.

### 4.6 Adaptive cadence and CLI
*Purpose: spend less when nobody is watching; show apps.*

- 4.6.1 Cadence policy from presence, power, display and index; drives scheduler intervals and the top-stream pause.
- 4.6.2 `pmon status` shows apps, focus and context.
- 4.6.3 `pmon app <name>`: its processes and last hour.

**Phase exit check:** the three "done when" checks of 4.1, 4.3 and 4.4 hold over a normal working day.

---

# Phase 5 — Detect and blame

The core of the product: recognise a slowdown and say who caused it. Developed almost entirely on replay.

### 5.1 Scenario recordings
*Purpose: ground truth before writing the logic.*

- 5.1.1 Record `pmon-stress` scenarios: CPU, memory, disk, mixed, and a quiet baseline.
- 5.1.2 Record flapping and short-burst cases.
- 5.1.3 `pmon mark` command ("it feels slow now") writing an event; start recording real days.

**Files:** `Tests/Fixtures/scenarios/*`. **Done when:** each scenario has a recording and an expected-outcome note.

### 5.2 Scorer
*Purpose: six sub-scores and one index per sample.*

- 5.2.1 `Thresholds` in config; piecewise-linear mapping helper.
- 5.2.2 One scoring function per dimension, each a pure function of the system sample and recent history.
- 5.2.3 Index = maximum sub-score; scores written to `sys_sample`.
- 5.2.4 `pmon status` shows the index and sub-scores.

**Files:** `Score/Thresholds.swift`, `Score/Scorer.swift`. **Done when:** each stress scenario drives the expected dimension above 60 and the quiet one stays below 30.

### 5.3 Episode detector
*Purpose: stable episodes, not noise.*

- 5.3.1 State machine: open on 3 of 5 samples above threshold, close after sustained calm, merge near neighbours.
- 5.3.2 Episode summary: peak, mean, dominant dimension, context flags, focus app.
- 5.3.3 Persistence: open episode survives a daemon restart; sleep closes it.
- 5.3.4 Detector raises cadence and switches the `ps` burst on.

**Files:** `Score/EpisodeDetector.swift`. **Done when:** each scenario yields exactly one episode; the flapping case yields one merged episode.

### 5.4 Blame
*Purpose: who caused it, by how much, how sure.*

- 5.4.1 Share per app per dimension: CPU with QoS weighting, disk bytes, GPU proxy, UI from hang reports.
- 5.4.2 Memory rule: holding share plus growth share over the 10-minute lead-up.
- 5.4.3 Thermal rule: energy share over the 5-minute lead-up.
- 5.4.4 Blame score, culprit or victim role, confidence from data path.
- 5.4.5 Write `episode_blame`; preserve the raw samples around each episode.

**Files:** `Score/BlameCalculator.swift`. **Done when:** in each scenario the stress tool is the top culprit in the right dimension.

### 5.5 Explanation commands
*Purpose: the answer in words.*

- 5.5.1 `pmon why [--at TIME]`: cause, culprits, victims, confidence.
- 5.5.2 Sentence generator with templates per dimension and for low-confidence cases.
- 5.5.3 `pmon episodes --since`.

**Files:** `Sources/pmon/Why.swift`, `Store/Queries.swift`. **Done when:** output for each scenario is correct and readable without knowing the schema.

### 5.6 Calibration
*Purpose: thresholds that match how the machine actually feels.*

- 5.6.1 Replay tool that runs a recording with candidate thresholds and reports episodes vs. marks.
- 5.6.2 One week of real recordings with manual marks.
- 5.6.3 Tune thresholds and blame weights; lock them into defaults and scenario tests.

**Phase exit check:** at least 80 % of manual marks fall inside an episode; fewer than one user-present episode per day has no mark and no obvious cause.

---

# Phase 6 — History and reports

Makes the data last and answers questions about weeks and months.

### 6.1 Rollups
*Purpose: three resolutions, always consistent.*

- 6.1.1 Incremental 1-minute rollup from raw samples for system and app tables, with `covered_ms`.
- 6.1.2 1-hour from 1-minute, 1-day from 1-hour; watermark per grain; idempotent and restart-safe.
- 6.1.3 Focus time, sluggish time and blame folded into app rollups.
- 6.1.4 Test: rollup of a replayed day equals direct aggregation of raw rows.

**Files:** `Store/Rollup.swift`. **Done when:** running the rollup twice changes nothing.

### 6.2 Retention
*Purpose: bounded size without losing evidence.*

- 6.2.1 Range deletes per table by policy.
- 6.2.2 Episode-window preservation for raw samples.
- 6.2.3 Incremental vacuum; capture-file expiry hook.

**Files:** `Store/Retention.swift`. **Done when:** a simulated 60 days ends under 200 MB and preserved windows are intact.

### 6.3 Baselines and findings
*Purpose: chronic problems that never trip an episode.*

- 6.3.1 `app_baseline` per hour-of-week from hourly rollups.
- 6.3.2 Rules: leak suspect, runaway CPU, wakeup storm, disk writer, anomaly, crash loop, background tax.
- 6.3.3 Finding lifecycle: open, update, auto-close, de-duplication.
- 6.3.4 Fixture tests: linear growth fires the leak rule, a sawtooth does not.

**Files:** `Score/Findings.swift`. **Done when:** each rule has a firing and a non-firing fixture.

### 6.4 Query layer
*Purpose: one function per report, shared by all outputs.*

- 6.4.1 Grain selection by time range.
- 6.4.2 Offender ranking, moment-in-time view, background tax, app trend, episode timeline.
- 6.4.3 Result types that carry fidelity and confidence.

**Files:** `Store/Queries.swift`. **Done when:** every query returns in under 200 ms on a two-week database.

### 6.5 Report commands
*Purpose: the answers on the command line.*

- 6.5.1 `pmon top --since`, `pmon findings`, extended `pmon app`.
- 6.5.2 `--json` on every command, with a stable output schema.
- 6.5.3 `pmon export` to JSON and CSV.

**Files:** `Sources/pmon/*`.

### 6.6 HTML report
*Purpose: one shareable page.*

- 6.6.1 Template: index timeline, episodes, offender ranking, findings, per-app drill-down.
- 6.6.2 `pmon report --since --html`: single self-contained file, no server.

**Files:** `Support/report.html`, `Sources/pmon/Report.swift`.

**Phase exit check:** after two weeks the database is under 200 MB, and the weekly report's top offender agrees with what `pmon why` said during the week.

---

# Phase 7 — Optional collectors, unprivileged

Deeper evidence, each behind a config switch, none needing root.

### 7.1 Capture framework
*Purpose: heavy collection under strict control.*

- 7.1.1 Collector modes `off` / `triggered` / `always` in config.
- 7.1.2 Budget: one capture set per episode, hourly cap, battery guard.
- 7.1.3 Compressed capture files, `capture` rows, expiry.
- 7.1.4 Budget test under a burst of synthetic episodes.

**Files:** `Collect/Capture.swift`.

### 7.2 Process evidence
*Purpose: what the culprit was doing.*

- 7.2.1 Stack capture of the top own-process culprit, with a summary of the hottest frames.
- 7.2.2 Per-thread breakdown for the top five processes.
- 7.2.3 Memory composition via `footprint` for memory episodes.

### 7.3 Short-lived processes
*Purpose: name what the sweep cannot see.*

- 7.3.1 Fast pid-list diff scan, triggered by high unattributed CPU.
- 7.3.2 Aggregate by executable and parent; write as events and fold into blame.
- 7.3.3 Test against `pmon-stress forkstorm`.

### 7.4 Additional metrics
*Purpose: dimensions the default tier lacks.*

- 7.4.1 GPU: device utilisation at slow tier; per-process GPU time when triggered.
- 7.4.2 Per-process network.
- 7.4.3 File-descriptor counts, disk latency probe, command-line arguments.

### 7.5 Surfacing
*Purpose: make the evidence visible and the cost known.*

- 7.5.1 `pmon why` links to captures and shows summaries.
- 7.5.2 `pmon config`: list collectors with mode and measured cost; switch them.

**Phase exit check:** with every optional collector set to `triggered`, average daemon cost outside episodes is unchanged from phase 5.

---

# Phase 8 — Optional root helper

Upgrades estimated values to exact ones. Fully removable.

### 8.1 Helper
*Purpose: the smallest possible privileged surface.*

- 8.1.1 `pmon-helper`: stateless; request is a list of pids or one of a fixed set of capture commands.
- 8.1.2 Transport, with caller verification by uid and code signature.
- 8.1.3 Input validation tests; rejection of other users.

**Files:** `Sources/pmon-helper/*`.

### 8.2 Install and removal
*Purpose: opt-in, reversible.*

- 8.2.1 `sudo pmon helper install` / `uninstall`; LaunchDaemon plist.
- 8.2.2 `pmon status` shows helper presence and version.

### 8.3 Engine integration
*Purpose: use it when present, never depend on it.*

- 8.3.1 Helper as a third process source with native fidelity for foreign pids.
- 8.3.2 Stop the `top` child while the helper is healthy; fall back within one interval if it disappears.
- 8.3.3 Test: kill the helper mid-run; next interval comes from the top stream with correct fidelity.

### 8.4 Privileged captures
*Purpose: evidence only root can gather.*

- 8.4.1 Spindump for UI episodes; powermetrics for thermal episodes.
- 8.4.2 Exec tracing when unattributed CPU is high.
- 8.4.3 Stack and memory captures of foreign processes.

**Phase exit check:** with the helper, residual `system.foreign` disk I/O drops to near zero; uninstalling leaves no files outside the home directory.

---

# Phase 9 — Polish

### 9.1 Menu-bar item
- 9.1.1 Live index and current top culprit.
- 9.1.2 Shortcuts to `why` and the HTML report.

### 9.2 Notifications
- 9.2.1 Long episodes and new findings, rate-limited and switchable.

### 9.3 Documentation
- 9.3.1 Install and uninstall.
- 9.3.2 Reading reports; what confidence and fidelity mean.
- 9.3.3 Configuration reference.

### 9.4 Release
- 9.4.1 Release build and signing.
- 9.4.2 Versioned install and upgrade, with migration test from a phase 1 database.

**Phase exit check:** a clean user account can install, run for a day and read a report using only the documentation.

---

## Cross-cutting test assets

| Asset | Built in | Used by |
|---|---|---|
| Fake clock | 1.2 | Scheduler, detector and rollup tests |
| Recorder / replayer | 1.6 | Everything from phase 5; calibration |
| `pmon-stress` | 0.1, 2.5 | Exit checks of phases 2, 3, 5, 7 |
| Fixture library | 0.3, 3.1, 4.1, 5.1 | Parser, resolver, scorer tests |
| Self-cost assertion | 2.4 | Exit check of every later phase |

## Decision points

| After | Decision |
|---|---|
| 0.5 | Keep the `top` stream, or `ps`-only coverage for foreign processes |
| 3.5 | Is 30 s resolution for system processes good enough, or should phase 8 move earlier |
| 5.6 | Are thresholds and blame trustworthy enough to build long-term reports on |
| 6.6 | Which optional collectors are worth building, based on poorly explained episodes |
