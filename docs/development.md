# Development

```
swift build
swift test                    # 150+ tests; a few start short-lived child processes
Support/release.sh            # release build, optional signing and notarisation, tarball in dist/
```

GitHub Actions runs the build and the tests on every push to `master` and every pull request (`.github/workflows/ci.yml`), and attaches the packaged tarball to the run.

## Releasing

Releases are made by `.github/workflows/release.yml`; nothing needs to run on a Mac.

1. Run `make release` to release the next patch version, `make release BUMP=minor` (or `major`) for a bigger step, or `make release VERSION=0.2.0` for an exact one (`0.2.0-rc.1` makes a pre-release). It checks that `master` is pushed and the version is not tagged or released yet, asks for confirmation, starts the workflow and follows it to the end; `WATCH=0` returns at once, `DRY_RUN=1` only runs the checks, `YES=1` skips the question. The same can be done in GitHub: **Actions › Release › Run workflow**.
2. The workflow sets `PmonVersion` in `Sources/PmonCore/Config/Config.swift`, commits `Release v0.2.0` to `master` and tags `v0.2.0`.
3. It then builds, runs the tests, signs, notarises when it can, and publishes a GitHub release with the tarball, its SHA-256, install instructions and notes generated from the merged changes.

`make` alone lists the targets. The other release targets:

| Target | What it does |
|---|---|
| `make releases` | Every version tagged on GitHub, newest first, with its release date, or a note when the tag has no release |
| `make last-release` | The latest release, and a newer pre-release if there is one |
| `make next-version [BUMP=minor]` | The version `make release` would pick: the latest tag bumped by one step (a pre-release such as `0.3.0-rc.1` steps to `0.3.0`); the version in the code when nothing is tagged yet or when it is already ahead |
| `make check VERSION=0.2.0` | Whether that version is free: not tagged on GitHub, not released, no stale local tag |

Pushing a tag by hand (`git tag v0.2.0 && git push origin v0.2.0`) runs step 3 alone. The binaries then take their version from the tag; if `PmonVersion` in the code differs, the run warns and the code is not changed, so prefer the workflow.

Signing and notarisation switch on when these repository secrets exist (Settings › Secrets and variables › Actions):

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | A Developer ID Application certificate with its private key, exported as `.p12`, then `base64 -i cert.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` password |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | An Apple ID, its team, and an app-specific password, for `notarytool` |

Without them the binaries are ad-hoc signed and the release notes tell users how to clear the quarantine flag. `Support/release.sh` takes the same settings as environment variables (`SIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`) for a local release.

`pmond --record <file>` writes every raw reading to a file; `pmon replay <file> --db <scratch.db>` runs it through the same pipeline and produces identical rows. Most tests work this way. `pmon-stress` generates known CPU, memory, disk and process-churn loads.

## Documentation

This book is built with [mdBook](https://rust-lang.github.io/mdBook/) from `docs/` (the chapter list is `docs/SUMMARY.md`; the Design chapter includes `DESIGN.md`). To preview it locally:

```
mdbook serve --open
```

`.github/workflows/docs.yml` builds it on every pull request and publishes it to GitHub Pages on every push to `master`.
