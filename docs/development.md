# Development

```
swift build
swift test                    # 150+ tests; a few start short-lived child processes
Support/release.sh            # release build, optional signing and notarisation, tarball in dist/
```

GitHub Actions runs the build and the tests on every push to `master` and every pull request (`.github/workflows/ci.yml`), and attaches the packaged tarball to the run.

## Releasing

Releases are made by `.github/workflows/release.yml`; nothing needs to run on a Mac.

1. In GitHub, open **Actions › Release › Run workflow** and enter the version, such as `0.2.0` (`0.2.0-rc.1` makes a pre-release).
2. The workflow sets `PmonVersion` in `Sources/PmonCore/Config/Config.swift`, commits `Release v0.2.0` to `master` and tags `v0.2.0`.
3. It then builds, runs the tests, signs, notarises when it can, and publishes a GitHub release with the tarball, its SHA-256, install instructions and notes generated from the merged changes.

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
