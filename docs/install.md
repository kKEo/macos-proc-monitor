# Install, upgrade, uninstall

There are three ways to install pmon. Pick one: they keep their files apart, but each starts its own daemon, and only one daemon can run.

## With Homebrew

```
brew install kkeo/tap/pmon
brew services start pmon       # the daemon, now and at every login
pmon menu install              # optional: the menu-bar item, also at every login
```

Homebrew puts `pmon` on your `PATH` and runs the daemon as the `brew services` service `sh.brew.pmon`. Upgrade with `brew upgrade pmon`; `pmon update` defers to it. Uninstall with `brew services stop pmon && brew uninstall pmon`, after `pmon menu uninstall` if you added the menu item. Your data in `~/Library/Application Support/pmon` stays either way; `pmon uninstall --purge` deletes it.

If you installed pmon before with `pmon install` or `install.sh`, run `pmon uninstall` first (your data is kept). `pmon status` warns when both daemons are registered.

## From a release archive

Download `pmon-<version>.tar.gz` from the [releases](https://github.com/kKEo/macos-proc-monitor/releases), then:

```
tar -xzf pmon-<version>.tar.gz
cd pmon-<version> && ./install.sh
```

## From source

```
swift build -c release
.build/release/pmon install
```

## What `pmon install` does

`pmon install` copies the tools to `~/Library/Application Support/pmon/bin`, registers the daemon as a per-user LaunchAgent and starts it. It prints a line you can use to put `pmon` on your `PATH`. Check that it is recording:

```
pmon status
```

Optional extras:

| Command | What it adds |
|---|---|
| `pmon menu install` | A menu-bar item: live index, the busiest app, and a dashboard window with live charts, history, slowdowns, findings and apps |
| `pmon config notifications on` | A notification when a slowdown lasts two minutes, and for new findings |
| `pmon config set --recommended` | Deeper evidence during slowdowns: call stacks, threads, short-lived processes, GPU time per app |
| `sudo pmon helper install` | Exact data for system-owned processes (see [The root helper](helper.md)) |

**Upgrade:** with Homebrew, `brew upgrade pmon`. Otherwise run `pmon update`, or choose **Update to pmon …** in the menu-bar item. It downloads the latest release from GitHub, checks its SHA-256 against the published `.sha256` file and the code signatures of the binaries (when your pmon is signed with a Developer ID, the new one must be signed by the same team), then runs the new version's `pmon install`. The daemon checks for a new release once a day and shows a notification once per version; `pmon status` and the menu show it too.

| Command | What it does |
|---|---|
| `pmon update` | Install the latest release, after asking (`--yes` to skip the question) |
| `pmon update --check` | Only tell whether a newer release exists (`--json` for scripts) |
| `pmon update --version 0.2.2` | Install a specific release, also to reinstall or go back |
| `pmon update --dry-run` | Download and verify, but do not install |
| `pmon config updates off` | Stop the daily check; `pmon update` still works |

If the root helper is installed, update it afterwards with `sudo pmon helper install`; `pmon update` reminds you.

To upgrade from source instead, build the new version and run `pmon install` again. Either way binaries are replaced and the database is migrated when the daemon starts. `pmon status` tells you if the running daemon and the `pmon` you typed are different versions.

**Uninstall:**

```
sudo pmon helper uninstall     # only if you installed the helper; do this first
pmon uninstall                 # stops the daemon and menu item, keeps your data
pmon uninstall --purge         # also deletes the database, captures, log and configuration
```

After `--purge` nothing of pmon remains outside the build directory.

## Where things are

| Path | Contents |
|---|---|
| `~/Library/Application Support/pmon/pmon.db` | The database (SQLite; readable with any SQLite tool) |
| `~/Library/Application Support/pmon/config.json` | Configuration (optional; absent means defaults) |
| `~/Library/Application Support/pmon/captures/` | Evidence files from optional collectors |
| `~/Library/Application Support/pmon/pmond.log` | The daemon's log (`/opt/homebrew/var/log/pmond.log` with Homebrew) |
| `~/Library/Application Support/pmon/update.json` | What the last update check found |
| `~/Library/Application Support/pmon/update.log` | Output of an update started from the menu |
| `~/Library/Application Support/pmon/bin/` | Installed tools |
| `~/Library/LaunchAgents/dev.pmon.daemon.plist` | The daemon's LaunchAgent (`dev.pmon.menu.plist` for the menu item) |

Everything is readable by your user only.
