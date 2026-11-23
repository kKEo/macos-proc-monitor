# Configuration reference

The configuration file is `~/Library/Application Support/pmon/config.json`. It is optional: every setting has a default, and any subset may be given. The daemon reads it at start; `pmon config set …` `pmon config notifications …` and `pmon config updates …` edit it and restart the daemon for you. After editing by hand:

```
launchctl kickstart -k gui/$(id -u)/dev.pmon.daemon
```

A file that does not parse stops the daemon from starting; the reason is in `pmond.log`.

```json
{
  "processIntervalSeconds": 10,
  "collectors": { "stack": "triggered", "shortLived": "triggered" },
  "notifications": { "enabled": true },
  "thresholds": { "openAt": 70 }
}
```

## Sampling

| Key | Default | Meaning |
|---|---|---|
| `systemIntervalSeconds` | 5 | System-wide counters (CPU, memory, disk, network, session state) |
| `processIntervalSeconds` | 10 | Per-process sweep |
| `slowIntervalSeconds` | 60 | Volume free space, battery |
| `foreignIntervalSeconds` | 30 | Interval of the `top` child that covers other users' processes |
| `topStreamEnabled` | true | false: cover other users' processes with `ps` only (costlier, CPU only) |
| `relaxWhenIdle` | true | Sample a third as often when idle for 5 minutes or on battery in Low Power Mode; once a minute with the display off |
| `recordingCapMB` | 256 | Size limit of a `pmond --record` file |
| `helperSocket` | `/var/run/dev.pmon.helper.sock` | Where to look for the optional root helper |

During a slowdown both intervals drop to 2 seconds regardless of these values.

## Optional collectors (`collectors`)

Each is `"off"`, `"triggered"` (only around a slowdown, within the budget) or `"always"`. `pmon config` lists them with the cost measured on your machine.

| Key | Default | What it does |
|---|---|---|
| `gpu` | always | GPU utilisation on every sample; feeds the gpu score |
| `gpuProcess` | off | GPU time per app, so a GPU slowdown has a named cause |
| `stack` | off | Call stacks of the busiest process when a slowdown starts (3 s of `sample`) |
| `threads` | off | Per-thread CPU, thread count and open files of the five busiest processes |
| `footprint` | off | Memory composition of the largest process, in memory slowdowns |
| `shortLived` | off | 10-second scan for short-lived processes when CPU goes unattributed |
| `network` | off | Top network talkers during a slowdown (one `nettop` run, about 1.4 s of CPU) |
| `diskProbe` | off | Time of one uncached 16 KB read, once a minute |
| `args` | off | Include command-line arguments in the `threads` capture. They can contain secrets |
| `spindump` | off | System-wide stacks when an app hangs. Needs the root helper |
| `powermetrics` | off | Power figures in a thermal slowdown. Needs the root helper |

`pmon config set --recommended` sets `stack`, `threads`, `footprint`, `shortLived` and `gpuProcess` to `triggered`.

| Key | Default | Meaning |
|---|---|---|
| `maxCaptureSetsPerHour` | 6 | Budget shared by all triggered captures (one set per slowdown) |
| `minBatteryPct` | 20 | No triggered captures on battery below this level |
| `captureCapMB` | 500 | Oldest capture files are deleted beyond this size |
| `shortLivedCpuShare` | 0.25 | Unattributed CPU, in cores, that starts a short-lived process scan |

## Notifications (`notifications`)

| Key | Default | Meaning |
|---|---|---|
| `enabled` | false | Master switch |
| `longEpisodes` | true | Notify when a slowdown has lasted `longEpisodeSeconds` while you are at the Mac |
| `longEpisodeSeconds` | 120 | |
| `findings` | true | Notify about new findings |
| `minGapMinutes` | 30 | At most one notification in this many minutes; others are dropped, not queued |

## Updates (`updates`)

| Key | Default | What it does |
|---|---|---|
| `autoCheck` | true | Let the daemon ask GitHub for a newer release. `pmon update` works either way |
| `checkIntervalHours` | 24 | How often (at least 1) |
| `notify` | true | One notification per new version; independent of the `notifications` switch |
| `repository` | `kKEo/macos-proc-monitor` | GitHub repository the releases come from, as owner/name (for a fork) |

## Retention (`retention`)

| Key | Default | Meaning |
|---|---|---|
| `rawHours` | 48 | Raw samples |
| `episodeDays` | 30 | Raw samples around a slowdown, and capture files |
| `episodeMarginSeconds` | 300 | How much either side of a slowdown counts as "around" |
| `minuteRollupDays` | 14 | Per-minute summaries |
| `hourRollupDays` | 400 | Per-hour summaries. Daily summaries are kept indefinitely |

## Detection and blame (`thresholds`)

Change these only with evidence: `pmon mark` when the Mac feels slow, record a session with `pmond --record`, then compare candidates with `pmon calibrate <recording> --thresholds <file>`.

Each sub-score rises linearly from 0 at the low value to 100 at the high value.

| Keys | Default | Meaning |
|---|---|---|
| `waitShareLow`, `waitShareHigh` | 0.05, 0.75 | Foreground threads waiting for a core, as a share of all core time |
| `pBusyLow`, `pBusyHigh`, `pBusyMax` | 0.85, 1.0, 50 | Performance cores busy; contributes at most `pBusyMax` |
| `canaryLowMs`, `canaryHighMs` | 10, 150 | Lateness of pmon's own timer |
| `thrashLow`, `thrashHigh` | 4000, 30000 | Paging activity, pages per second (median of three samples) |
| `memLevelHigh`, `memLevelLow`, `memLevelMax` | 30, 8, 60 | Percent of memory still available; contributes at most `memLevelMax` |
| `pressureWarnScore`, `pressureCriticalScore` | 25, 75 | Score for the kernel's memory pressure levels |
| `queueLow`, `queueHigh` | 0.5, 3.0 | Disk queue depth (median of three samples) |
| `diskFreeHighPct`, `diskFreeLowPct`, `diskFreeMax` | 10, 2, 30 | Free space on the system volume; contributes at most `diskFreeMax` |
| `thermalScores` | [0, 20, 70, 100] | Score per thermal state: nominal, fair, serious, critical |
| `gpuLow`, `gpuHigh` | 70, 98 | GPU utilisation in percent (median of three samples) |
| `hangSeconds`, `uiOtherAppScore` | 30, 50 | How long a hang report counts, and its score when the app is not in focus |
| `openAt`, `closeAt` | 60, 40 | Index that opens an episode; index it must stay below to close |
| `openNeeded`, `openWindow` | 3, 5 | Open when this many of the last so many samples reach `openAt` |
| `calmSeconds` | 45 | Time below `closeAt` before an episode closes |
| `presentIdleSeconds` | 120 | You count as present if input is more recent than this |
| `qosWeightUtility`, `qosWeightBackground` | 0.5, 0.2 | Weight of utility and background CPU time in blame |
| `memoryHoldWeight`, `memoryGrowthWeight` | 0.6, 0.4 | Memory blame: held versus recently grown |
| `memoryLeadSeconds`, `thermalLeadSeconds` | 600, 300 | How far before an episode growth and energy are counted |
| `minShare` | 0.02 | Blame shares below this are not stored |
| `minDimensionScore` | 30 | A resource must average at least this over an episode to be blamed at all |
