# Troubleshooting

| Symptom | What to check |
|---|---|
| `pmon status` says the daemon is not running | `tail ~/Library/Application\ Support/pmon/pmond.log`, then `pmon install` again |
| "version" line in `pmon status` | The daemon and the CLI differ: run `pmon install` from the newer build |
| "update" line in `pmon status` | A newer release exists: `pmon update` installs it |
| `pmon update` fails with HTTP 403 | GitHub's limit of 60 unauthenticated API requests an hour per address was reached; try again later |
| An update started from the menu failed | The reason is in the menu and in `~/Library/Application Support/pmon/update.log` |
| System processes show "coarser data" | Normal without the helper; see above |
| A slowdown you felt was not recorded | Run `pmon mark` when it happens; marks are used to tune detection (`pmon calibrate`) |
| An episode names "Kernel and short-lived processes" | Switch on the `shortLived` collector: `pmon config set shortLived triggered` |
| Notifications do not appear | Allow notifications for "Script Editor" in System Settings › Notifications |
