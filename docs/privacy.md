# Privacy and cost

## What is recorded

- All data stays in your home directory. pmon makes no network connections.
- It records process names, executable paths, app names and resource counters. It does not record window titles, file names, network destinations or keystrokes.
- Command-line arguments are not collected unless you switch the `args` collector on, and then only into capture files, never the database.
- Stack captures (the `stack` collector, off by default) contain function names from the sampled program.

## What it costs

In normal use the daemon takes about 0.3 % of one core and 30 MB of memory, including the `top` child process it uses to see system-owned processes. It samples less often when you are away, when the display is off, and on battery in Low Power Mode. If its own sweeps become slow it backs off by itself and records that it did.

The database stays under roughly 200 MB: raw samples are kept for 48 hours (30 days around a slowdown), per-minute summaries for 14 days, hourly ones for about 13 months, daily ones indefinitely.
