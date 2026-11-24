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

## Quick start

With [Homebrew](https://brew.sh):

```
brew install kkeo/tap/pmon
brew services start pmon
pmon status
```

Or from source:

```
swift build -c release
.build/release/pmon install
pmon status
```

No root is needed. `pmon uninstall` stops it and keeps your data; `pmon uninstall --purge` removes everything.

## Documentation

The full documentation is published at <https://kkeo.github.io/macos-proc-monitor/> and lives in [`docs/`](docs/):

| Topic | Page |
|---|---|
| Install, upgrade, uninstall, file locations | [docs/install.md](docs/install.md) |
| Everyday commands | [docs/usage.md](docs/usage.md) |
| The index, episodes, blame, confidence, findings | [docs/READING-REPORTS.md](docs/READING-REPORTS.md) |
| Every setting and its default | [docs/CONFIGURATION.md](docs/CONFIGURATION.md) |
| The optional root helper | [docs/helper.md](docs/helper.md) |
| What is recorded, and what it costs | [docs/privacy.md](docs/privacy.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Building, testing, releasing | [docs/development.md](docs/development.md) |
| How it works | [DESIGN.md](DESIGN.md) |
