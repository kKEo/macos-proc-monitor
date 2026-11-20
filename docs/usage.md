# Everyday use

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

How to read the output, and what "confidence" means: [Reading the output](READING-REPORTS.md). Every setting: [Configuration](CONFIGURATION.md).
