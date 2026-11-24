# Troubleshooting

| Symptom | What to check |
|---|---|
| `pmon status` says the daemon is not running | `tail ~/Library/Application\ Support/pmon/pmond.log`, then `pmon install` again. With Homebrew: `tail /opt/homebrew/var/log/pmond.log`, then `brew services restart pmon` |
| `brew install` asks for newer Command Line Tools | The release has no bottle for your Mac (an Intel Mac, or macOS older than 14, is not supported). Otherwise update them in Software Update and try again |
| `pmon status` says two LaunchAgents start the daemon | Both `pmon install` and Homebrew set it up; keep one (`pmon uninstall`, or `brew services stop pmon`) |
| "version" line in `pmon status` | The daemon and the CLI differ: run `pmon install` from the newer build |
| "update" line in `pmon status` | A newer release exists: `pmon update` installs it |
| `pmon update` fails with HTTP 403 | GitHub's limit of 60 unauthenticated API requests an hour per address was reached; try again later |
| An update started from the menu failed | The reason is in the menu and in `~/Library/Application Support/pmon/update.log` |
| System processes show "coarser data" | Normal without the helper; see above |
| A slowdown you felt was not recorded | Run `pmon mark` when it happens; marks are used to tune detection (`pmon calibrate`) |
| An episode names "Kernel and short-lived processes" | Switch on the `shortLived` collector: `pmon config set shortLived triggered` |
| Notifications do not appear | Allow notifications for "Script Editor" in System Settings › Notifications |
