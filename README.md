# pmon

A local macOS monitor that answers one question: **which application made my Mac sluggish, when, and why?**

A small background daemon samples the machine every few seconds, stores the results in a local SQLite database, detects slowdowns and works out which apps caused them. Nothing leaves the machine, nothing listens on a port, and no root access is needed.

```
$ pmon why --at 22:48
Fri 20 Nov 22:47:36–22:49:16 (1.7 min): CPU contention, peak 100 of 100.
Main cause: cmux — 93 % of it; used 93 % of a core itself and started short-lived processes that used the CPU (2370 seen in a scan).
Also: WindowServer — 2 % of it; used 15 % of a core (peak 26 %) (system-owned, coarser data).
Context: cmux was in focus; you were at the Mac; Low Power Mode was on.
```

Requirements: macOS 14 or later on Apple Silicon, and Swift 6 (Xcode 16 or the command-line tools) to build.

## Install

```
swift build -c release
.build/release/pmon install
```

`pmon install` copies the tools to `~/Library/Application Support/pmon/bin`, registers the daemon as a per-user LaunchAgent and starts it. It prints a line you can use to put `pmon` on your `PATH`. Check that it is recording:

```
pmon status
```

Optional extras:

| Command | What it adds |
|---|---|
| `pmon menu install` | A menu-bar item: live index, the busiest app, shortcuts to the explanation and the report |
| `pmon config notifications on` | A notification when a slowdown lasts two minutes, and for new findings |
| `pmon config set --recommended` | Deeper evidence during slowdowns: call stacks, threads, short-lived processes, GPU time per app |
| `sudo pmon helper install` | Exact data for system-owned processes (see [The root helper](#the-root-helper)) |

**Upgrade:** build the new version and run `pmon install` again. Binaries are replaced and the database is migrated when the daemon starts. `pmon status` tells you if the running daemon and the `pmon` you typed are different versions.

**Uninstall:**

```
sudo pmon helper uninstall     # only if you installed the helper; do this first
pmon uninstall                 # stops the daemon and menu item, keeps your data
pmon uninstall --purge         # also deletes the database, captures, log and configuration
```

After `--purge` nothing of pmon remains outside the build directory.

## Everyday use

| Question | Command |
|---|---|
| Is anything wrong right now? | `pmon status` |
| Why was it slow just now, or at 14:32? | `pmon why`, `pmon why --at 14:32` |
| What slowdowns were there this week? | `pmon episodes --since 7d` |
| Which apps cause the most trouble? | `pmon top --since 7d` |
| Is anything leaking, spinning or filling the disk? | `pmon findings` |
| What has one app been doing? | `pmon app Safari` |
| Give me the whole picture | `pmon report --since 7d --open` |
| Get the data into another tool | `pmon export episodes --format csv` |

`status`, `why`, `episodes`, `top` and `findings` accept `--json`.

By default, `episodes`, `top` and `report` leave out slowdowns that happened while nobody was at the Mac (screen locked, display off, or no input for two minutes). Add `--all` to include them.

How to read the output, and what "confidence" means: [docs/READING-REPORTS.md](docs/READING-REPORTS.md).
Every setting: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).
How it works inside: [DESIGN.md](DESIGN.md).

## What it costs

In normal use the daemon takes about 0.3 % of one core and 30 MB of memory, including the `top` child process it uses to see system-owned processes. It samples less often when you are away, when the display is off, and on battery in Low Power Mode. If its own sweeps become slow it backs off by itself and records that it did.

The database stays under roughly 200 MB: raw samples are kept for 48 hours (30 days around a slowdown), per-minute summaries for 14 days, hourly ones for about 13 months, daily ones indefinitely.

## Where things are

| Path | Contents |
|---|---|
| `~/Library/Application Support/pmon/pmon.db` | The database (SQLite; readable with any SQLite tool) |
| `~/Library/Application Support/pmon/config.json` | Configuration (optional; absent means defaults) |
| `~/Library/Application Support/pmon/captures/` | Evidence files from optional collectors |
| `~/Library/Application Support/pmon/pmond.log` | The daemon's log |
| `~/Library/Application Support/pmon/bin/` | Installed tools |
| `~/Library/LaunchAgents/dev.pmon.daemon.plist` | The daemon's LaunchAgent (`dev.pmon.menu.plist` for the menu item) |

Everything is readable by your user only.

## The root helper

pmon is designed to work without root. Unprivileged, it reads your own processes exactly, and system-owned processes (WindowServer, Spotlight, system daemons) through `top` every 30 seconds, with their disk activity known only as a combined total.

The optional helper removes that gap. It is a small root daemon that does two things for your user's `pmond` only: return counters for a list of process ids, and run one of four fixed diagnostic commands (`sample`, `footprint`, `spindump`, `powermetrics`). It holds no state and writes no files.

```
sudo pmon helper install
pmon helper                  # shows whether it is answering
sudo pmon helper uninstall
```

It adds two files, both removed by `uninstall`: `/Library/PrivilegedHelperTools/dev.pmon.helper` and `/Library/LaunchDaemons/dev.pmon.helper.plist`. If the helper stops for any reason, the daemon goes back to the unprivileged sources within one sampling interval.

What the helper trusts: connections from your user account, from the installed `pmond` binary with an intact code signature. Builds from source are ad-hoc signed and `pmond` lives in your home directory, so in practice the helper trusts your user account. Do not install it on a machine where you would not also trust every program running as you with read-only process statistics and system-wide stack samples.

## Privacy

- All data stays in your home directory. pmon makes no network connections.
- It records process names, executable paths, app names and resource counters. It does not record window titles, file names, network destinations or keystrokes.
- Command-line arguments are not collected unless you switch the `args` collector on, and then only into capture files, never the database.
- Stack captures (the `stack` collector, off by default) contain function names from the sampled program.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `pmon status` says the daemon is not running | `tail ~/Library/Application\ Support/pmon/pmond.log`, then `pmon install` again |
| "version" line in `pmon status` | The daemon and the CLI differ: run `pmon install` from the newer build |
| System processes show "coarser data" | Normal without the helper; see above |
| A slowdown you felt was not recorded | Run `pmon mark` when it happens; marks are used to tune detection (`pmon calibrate`) |
| An episode names "Kernel and short-lived processes" | Switch on the `shortLived` collector: `pmon config set shortLived triggered` |
| Notifications do not appear | Allow notifications for "Script Editor" in System Settings › Notifications |

## Development

```
swift build
swift test                    # 150+ tests; a few start short-lived child processes
Support/release.sh            # release build, optional signing, tarball in dist/
```

GitHub Actions runs the build and the tests on every push to `master` and every pull request (`.github/workflows/ci.yml`), and attaches the packaged tarball to the run. Pushing a tag such as `v0.1.0` publishes a release (`release.yml`); the tag must match `PmonVersion`.

`pmond --record <file>` writes every raw reading to a file; `pmon replay <file> --db <scratch.db>` runs it through the same pipeline and produces identical rows. Most tests work this way. `pmon-stress` generates known CPU, memory, disk and process-churn loads.
