# Reading pmon's output

## The sluggishness index

Every sample gets six sub-scores from 0 (no problem) to 100 (saturated). The index is the **highest** of them: one saturated resource makes a Mac slow however healthy the others are.

| Sub-score | What raises it |
|---|---|
| cpu | Foreground threads waiting for a core; performance cores fully busy; pmon's own timer firing late |
| memory | Sustained paging (decompression, page-ins, swap); little memory left; the kernel's pressure level |
| disk | Requests queueing on the disk; a nearly full system volume (capped at 30) |
| thermal | The system's thermal state: fair 20, serious 70, critical 100 |
| gpu | GPU utilisation above 70 %, reaching 100 at 98 % (only if the `gpu` collector is on) |
| ui | The system reported an app as hung: 100 if it is the app in focus, 50 otherwise |

A standing index of 20–30 with "disk" as the cause usually means the system volume is nearly full. That is a condition, not a slowdown, and never opens an episode by itself.

## Episodes

An **episode** is a slowdown: it opens when three of the last five samples are at 60 or above, and closes after the index has stayed below 40 for 45 seconds. Brief dips do not split it. Its length runs to the last sample that was still elevated.

While an episode is forming or open, the daemon samples every 2 seconds instead of every 5–10.

## Blame

When an episode closes, pmon works out who caused it, separately for each resource that was under pressure:

| Resource | An app's share is… |
|---|---|
| cpu | Its CPU time, with background work counted at 20 % and utility work at 50 % (it competes less with what you are doing) |
| memory | 60 % its share of memory held, 40 % its share of growth in the ten minutes before |
| disk | Its share of bytes read and written |
| thermal | Its share of energy used in the five minutes before and during |
| gpu | Its share of GPU time (needs the `gpuProcess` collector) |
| ui | The app the system reported as hung |

`pmon why` reports shares as "93 % of it". `pmon top` multiplies each share by how bad and how long the episode was, giving **sluggish-minutes caused**, which can be added up across episodes and compared between apps.

**Culprit or victim.** An app with many page-ins but little memory of its own is being squeezed by something else. An app that mostly waits for a core while using little CPU is being starved. Both are listed as "affected rather than responsible" and carry no blame.

## Confidence

Every blame line rests on a particular source of data, and says so when the source is weaker:

| Shown as | Meaning |
|---|---|
| (nothing) | High. Counters read directly from the kernel for that process, at the full sampling rate |
| "system-owned, coarser data" | Medium. The process belongs to another user (usually the system), so it was measured through `top` every 30 s or `ps`. CPU and memory are right; disk, energy and waiting time are not available per process |
| "estimate" | Low. The activity could not be tied to a process at all: kernel work, processes that lived and died between two samples, or system disk activity. Also used for CPU moved to an app because it started many short-lived processes |

Installing the root helper turns "medium" into "high" for system processes. Switching on the `shortLived` collector replaces much of the "estimate" for CPU with the name of the app that started the processes.

In the database the same idea appears as `fidelity` on every row: 0 native, 1 `top` stream, 2 `ps` (CPU only), 3 residual. A value pmon could not measure is stored as NULL, never as 0, so a report can tell "none" from "unknown".

## Synthetic apps

Three names are not real applications:

| Name | What it is |
|---|---|
| Kernel and short-lived processes | CPU the system used that no sampled process accounts for |
| System processes (combined) | Disk activity not accounted for by processes pmon can read |
| Idle apps (combined) | Apps too quiet in a given sample to deserve their own row; kept so totals add up |

## Findings

Findings are chronic problems, checked hourly, independent of episodes:

| Finding | Rule |
|---|---|
| Possible memory leak | Memory rose steadily for 6 hours or more, by over 200 MB in total |
| Runaway background process | Over 80 % of a core for 10 minutes while not in focus |
| Wakeup storm | Over 1,000 CPU wakeups a second for 10 minutes (costs battery) |
| Heavy background disk writer | 5 GB or more written in a day while in focus under 5 % of the time |
| Unusual activity | More than three times the app's own normal for that hour of the week |
| Crash loop | Three or more crash reports for one app within an hour |
| Disk nearly full | Under 10 % free on the system volume |

A finding stays "active" while its condition holds and closes by itself a day after it was last seen.

## The HTML report

`pmon report --since 7d --open` writes one self-contained file:

- **Timeline:** the index over time. The line is the average per bucket, the shaded band reaches the peak. Hovering shows the numbers; the table view below the chart lists them.
- **Top offenders:** apps by sluggish-minutes caused.
- **Slowdowns:** each episode with its bottleneck and main cause.
- **Findings** and **background cost:** what ran while not in focus, in core-minutes and peak memory.

Buckets are aligned to UTC, so in day-level views the edges are shifted by your timezone offset.

## Evidence

If optional collectors are on, `pmon why` ends with an "Evidence" section: a one-line summary of each capture taken when the episode opened (the hottest functions, the busiest threads, the largest memory categories) and the path of the full file. Files are gzip-compressed text or JSON: `gunzip -c <file> | less`.
