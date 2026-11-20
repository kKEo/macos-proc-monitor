# Development

```
swift build
swift test                    # 150+ tests; a few start short-lived child processes
Support/release.sh            # release build, optional signing, tarball in dist/
```

GitHub Actions runs the build and the tests on every push to `master` and every pull request (`.github/workflows/ci.yml`), and attaches the packaged tarball to the run. Pushing a tag such as `v0.1.0` publishes a release (`release.yml`); the tag must match `PmonVersion`.

`pmond --record <file>` writes every raw reading to a file; `pmon replay <file> --db <scratch.db>` runs it through the same pipeline and produces identical rows. Most tests work this way. `pmon-stress` generates known CPU, memory, disk and process-churn loads.

## Documentation

This book is built with [mdBook](https://rust-lang.github.io/mdBook/) from `docs/` (the chapter list is `docs/SUMMARY.md`; the Design chapter includes `DESIGN.md`). To preview it locally:

```
mdbook serve --open
```

`.github/workflows/docs.yml` builds it on every pull request and publishes it to GitHub Pages on every push to `master`.
