# Privacy and cost

## What is recorded

- All data stays in your home directory. Nothing pmon records is ever sent anywhere.
- pmon's only network traffic is the update check: about once a day the daemon asks GitHub's API (`api.github.com`) for the latest release of pmon. The request carries no data about you or your Mac beyond what any HTTPS request does (your IP address and a `pmon/<version>` user agent). `pmon update` additionally downloads the release archive from GitHub. Switch the automatic check off with `pmon config updates off`; `pmon update` then contacts GitHub only when you run it.
- It records process names, executable paths, app names and resource counters. It does not record window titles, file names, network destinations or keystrokes.
- Command-line arguments are not collected unless you switch the `args` collector on, and then only into capture files, never the database.
- Stack captures (the `stack` collector, off by default) contain function names from the sampled program.

## What it costs

In normal use the daemon takes about 0.3 % of one core and 30 MB of memory, including the `top` child process it uses to see system-owned processes. It samples less often when you are away, when the display is off, and on battery in Low Power Mode. If its own sweeps become slow it backs off by itself and records that it did.

The database stays under roughly 200 MB: raw samples are kept for 48 hours (30 days around a slowdown), per-minute summaries for 14 days, hourly ones for about 13 months, daily ones indefinitely.
