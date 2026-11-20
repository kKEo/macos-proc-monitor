# The root helper

pmon is designed to work without root. Unprivileged, it reads your own processes exactly, and system-owned processes (WindowServer, Spotlight, system daemons) through `top` every 30 seconds, with their disk activity known only as a combined total.

The optional helper removes that gap. It is a small root daemon that does two things for your user's `pmond` only: return counters for a list of process ids, and run one of four fixed diagnostic commands (`sample`, `footprint`, `spindump`, `powermetrics`). It holds no state and writes no files.

```
sudo pmon helper install
pmon helper                  # shows whether it is answering
sudo pmon helper uninstall
```

It adds two files, both removed by `uninstall`: `/Library/PrivilegedHelperTools/dev.pmon.helper` and `/Library/LaunchDaemons/dev.pmon.helper.plist`. If the helper stops for any reason, the daemon goes back to the unprivileged sources within one sampling interval.

What the helper trusts: connections from your user account, from the installed `pmond` binary with an intact code signature. Builds from source are ad-hoc signed and `pmond` lives in your home directory, so in practice the helper trusts your user account. Do not install it on a machine where you would not also trust every program running as you with read-only process statistics and system-wide stack samples.
