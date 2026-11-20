# Install, upgrade, uninstall

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
| `sudo pmon helper install` | Exact data for system-owned processes (see [The root helper](helper.md)) |

**Upgrade:** build the new version and run `pmon install` again. Binaries are replaced and the database is migrated when the daemon starts. `pmon status` tells you if the running daemon and the `pmon` you typed are different versions.

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
| `~/Library/Application Support/pmon/pmond.log` | The daemon's log |
| `~/Library/Application Support/pmon/bin/` | Installed tools |
| `~/Library/LaunchAgents/dev.pmon.daemon.plist` | The daemon's LaunchAgent (`dev.pmon.menu.plist` for the menu item) |

Everything is readable by your user only.
