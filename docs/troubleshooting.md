# Troubleshooting

| Symptom | What to check |
|---|---|
| `pmon status` says the daemon is not running | `tail ~/Library/Application\ Support/pmon/pmond.log`, then `pmon install` again |
| "version" line in `pmon status` | The daemon and the CLI differ: run `pmon install` from the newer build |
| System processes show "coarser data" | Normal without the helper; see above |
| A slowdown you felt was not recorded | Run `pmon mark` when it happens; marks are used to tune detection (`pmon calibrate`) |
| An episode names "Kernel and short-lived processes" | Switch on the `shortLived` collector: `pmon config set shortLived triggered` |
| Notifications do not appear | Allow notifications for "Script Editor" in System Settings › Notifications |
