---
name: verify-homebrew-release
description: Verify that a pmon release was distributed through Homebrew correctly - the GitHub release files (tarball, .sha256, bottle), the formula in kKEo/homebrew-tap (version, url, sha256, bottle block), that they agree with each other, and that the Release workflow's homebrew job really published. Use this after every `make release`, whenever the user asks whether a release "made it to brew", "is in the tap", "is the bottle ok", "can people brew install it", or wants to check, verify, validate or debug the Homebrew distribution, formula or bottle of a release - and when `brew install kkeo/tap/pmon` or `brew upgrade pmon` fails or installs the wrong version, even if they do not say "verify".
---

# Verify the Homebrew distribution of a pmon release

A release reaches Homebrew users in a chain, and each link can break on its own:

1. The Release workflow (`.github/workflows/release.yml`) publishes `pmon-<version>.tar.gz` and its `.sha256` on GitHub.
2. Its `homebrew` job runs `Support/homebrew.sh`: writes the formula from `Support/homebrew/pmon.rb`, builds a bottle, attaches the bottle to the release.
3. The job pushes `Formula/pmon.rb` to `kKEo/homebrew-tap`.
4. A user's `brew install kkeo/tap/pmon` reads the formula, downloads the bottle from the release and checks its SHA-256.

A broken link usually fails quietly: the job skips publishing when `HOMEBREW_TAP_TOKEN` is missing and the run still shows green, and a formula whose bottle is missing only fails on a user's Mac. So check the published result, not just the run's colour.

## Run the checks

```
python3 .claude/skills/verify-homebrew-release/scripts/verify.py            # the latest release
python3 .claude/skills/verify-homebrew-release/scripts/verify.py 0.2.3      # a given version
```

The script only reads: it downloads the release files to a temporary folder, fetches the formula from the tap, and inspects the workflow run. It installs nothing and changes nothing on GitHub. It needs `gh`, signed in. `--keep DIR` keeps the downloads for a closer look; `--repo` and `--tap` point it at a fork.

It prints one line per check - `PASS`, `FAIL`, `WARN` or `SKIP` - and exits 1 if any check failed. Run it once and read all of its output before investigating; one root cause typically produces several failures.

If the release was started moments ago, the workflow may still be running: check with `gh run list --workflow release.yml --limit 3` and wait for it rather than reporting failures that are only "not finished yet".

## What a failure means

| Failing check | Likely cause | What to do |
|---|---|---|
| `homebrew job`: skipped publishing | `HOMEBREW_TAP_TOKEN` secret is missing, expired, or lacks access | `gh secret list`; the user creates a fine-grained token for `kKEo/homebrew-tap` with Contents: read and write and sets the secret, then re-runs the job |
| `homebrew job`: no Homebrew job | The tag was built from a commit older than the Homebrew step | Release a newer version; an old tag cannot gain the job |
| `homebrew job`: failure | A step broke | `gh run view <id> --log-failed`; common: push rejected (token), `brew` trust or tool errors on the runner |
| `bottle asset` missing, formula fine or absent | The job stopped before "Attach the bottle" | Read the job log; re-run the failed job |
| `formula version` is older | The push to the tap did not happen | Same as a skipped or failed job; also confirm the push went to the tap's default branch (`gh repo view kKEo/homebrew-tap --json defaultBranchRef`) - Homebrew reads only that branch |
| `formula sha256 is the tarball's` | The tarball was re-uploaded after the formula was written (a re-run of the release job with `--clobber`) | Re-run the `homebrew` job so formula and bottle are rebuilt from the current tarball |
| `bottle … sha256 matches the formula` | The bottle was rebuilt and re-uploaded but the formula push failed, or the reverse | Re-run the `homebrew` job; never hand-edit one side only |
| `bottle … is attached to the release` | The formula lists a bottle file name the release lacks (label mismatch) | Compare the name in the formula with the release's files; check `BOTTLE_TAG` in `release.yml` |
| `tarball matches its .sha256 file` | A file was replaced by hand on the release page | Re-run the release for that tag |
| WARN `bottle label` | The bottle is not labelled `arm64_sonoma` | Users on macOS 14 fall back to a source build and need current Command Line Tools; set `BOTTLE_TAG=arm64_sonoma` |
| WARN `tap formula matches Support/homebrew/pmon.rb` | The tap was edited by hand | Move the change into `Support/homebrew/pmon.rb`; the next release overwrites the tap |

To re-run only the Homebrew part of a finished run: `gh run rerun <run-id> --job <job-id>` (job ids: `gh run view <run-id> --json jobs`). Re-running or changing anything on GitHub is the user's call - propose it, do not do it unasked.

Pre-releases (`0.3.0-rc.1`) are deliberately not published to Homebrew; the script then expects the formula to stay on the previous stable version.

## Optional: a real install

The script proves the published files are consistent; it does not prove Homebrew accepts them. Only when the user asks for an end-to-end check, or the script passes while users still report failures, try the real thing. Say what it changes first, because it touches the user's machine:

```
brew tap kkeo/tap                              # adds the tap, if not tapped
brew update                                    # so the tap is current
brew fetch --force kkeo/tap/pmon               # downloads; should say it fetched a bottle
brew install kkeo/tap/pmon                     # should print "Pouring pmon-<version>.<tag>.bottle.tar.gz"
brew test kkeo/tap/pmon
pmon --version
```

- "Pouring …bottle.tar.gz" is the line that matters: without it Homebrew built from source, which means the bottle was not used.
- Do not run `brew services start pmon` as part of a check. If the user already runs pmon from `pmon install` (`launchctl print gui/$(id -u)/dev.pmon.daemon`), a second daemon would compete with it for the database lock.
- Do not set `HOMEBREW_NO_INSTALL_FROM_API`: it makes Homebrew clone all of homebrew/core.
- If pmon was not installed through Homebrew before the check, offer to remove it again afterwards (`brew uninstall pmon`).

## Report

Lead with the verdict in one sentence: the release is correctly distributed through Homebrew, or it is not and why. Then:

- the version checked and the run id;
- each failure with its cause and the fix, grouped by root cause rather than listed check by check;
- warnings, briefly;
- what was not checked (for example the real install, if it was not run).

Do not report a pass on the strength of a green workflow run alone, and do not call it broken while the run is still in progress.
