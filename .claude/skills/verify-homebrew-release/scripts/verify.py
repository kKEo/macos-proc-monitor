#!/usr/bin/env python3
"""Check that a pmon release reached Homebrew correctly.

    verify.py [version] [--repo owner/name] [--tap owner/name] [--keep DIR]

Reads only: the GitHub release, its files, the formula in the tap and the Release workflow run.
Nothing is installed and nothing on GitHub is changed. Needs the GitHub CLI (gh), signed in.

Prints one line per check (PASS, FAIL, WARN, SKIP) and a summary; exits 1 when any check failed.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tarfile
import tempfile

TOOLS = ["pmon", "pmond", "pmon-menu", "pmon-helper"]
OLDEST_BOTTLE_TAG = "arm64_sonoma"
results = []


def report(status, name, detail=""):
    results.append(status)
    print(f"{status:<4} {name}" + (f": {detail}" if detail else ""))


def check(ok, name, good="", bad=""):
    report("PASS" if ok else "FAIL", name, good if ok else bad)
    return ok


def gh(*args, binary=False):
    """Run gh; return (ok, output)."""
    p = subprocess.run(["gh", *args], capture_output=True)
    out = p.stdout if binary else p.stdout.decode(errors="replace")
    return p.returncode == 0, (out if p.returncode == 0 else p.stderr.decode(errors="replace").strip())


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def strip_release_specifics(formula):
    """A formula without what differs per release: url, sha256 and the bottle block."""
    text = re.sub(r"^  bottle do\n.*?^  end\n\n?", "", formula, flags=re.M | re.S)
    text = re.sub(r'^  url ".*"$', "  url", text, flags=re.M)
    text = re.sub(r'^  sha256 ".*"$', "  sha256", text, flags=re.M)
    return text.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", nargs="?", help="version to check, e.g. 0.2.3 (default: the latest release)")
    ap.add_argument("--repo", default="kKEo/macos-proc-monitor")
    ap.add_argument("--tap", default="kKEo/homebrew-tap")
    ap.add_argument("--keep", metavar="DIR", help="keep the downloaded files in DIR")
    a = ap.parse_args()

    ok, _ = gh("auth", "status")
    if not ok:
        sys.exit("the GitHub CLI is missing or not signed in: brew install gh && gh auth login")

    # ---- 1. The release -------------------------------------------------------------------
    print("== release")
    if a.version:
        version = a.version.lstrip("v")
        ok, out = gh("release", "view", f"v{version}", "--repo", a.repo, "--json", "tagName,isDraft,isPrerelease,assets,publishedAt")
    else:
        ok, out = gh("release", "view", "--repo", a.repo, "--json", "tagName,isDraft,isPrerelease,assets,publishedAt")
    if not ok:
        report("FAIL", "release exists", out)
        return finish()
    rel = json.loads(out)
    tag = rel["tagName"]
    version = tag.lstrip("v")
    base = f"https://github.com/{a.repo}/releases/download/{tag}"
    assets = {x["name"]: x for x in rel["assets"]}
    report("PASS", "release exists", f"{tag}, published {rel.get('publishedAt', '?')[:10]}")
    check(not rel["isDraft"], "release is published", bad="it is still a draft, so its files cannot be downloaded")
    prerelease = rel["isPrerelease"] or "-" in version
    if prerelease:
        report("WARN", "pre-release", "the workflow leaves the formula on the latest stable release; the formula checks below are expected to show the previous version")

    tarball, shafile = f"pmon-{version}.tar.gz", f"pmon-{version}.tar.gz.sha256"
    have_tarball = check(tarball in assets, f"asset {tarball}", bad="missing from the release")
    have_sha = check(shafile in assets, f"asset {shafile}", bad="missing from the release")
    bottles = sorted(n for n in assets if re.fullmatch(rf"pmon-{re.escape(version)}\.[a-z0-9_]+\.bottle\.tar\.gz", n))
    check(bool(bottles), "bottle asset", ", ".join(bottles), "no pmon-<version>.<tag>.bottle.tar.gz in the release: the homebrew job did not run or failed")

    work = a.keep or tempfile.mkdtemp(prefix="pmon-verify-")
    os.makedirs(work, exist_ok=True)
    wanted = [n for n in [tarball, shafile, *bottles] if n in assets]
    if wanted:
        patterns = [x for n in wanted for x in ("--pattern", n)]
        ok, out = gh("release", "download", tag, "--repo", a.repo, "--dir", work, "--clobber", *patterns)
        if not ok:
            report("FAIL", "download the release files", out)
            return finish()

    tarball_sha = None
    if have_tarball:
        tarball_sha = sha256(os.path.join(work, tarball))
        if have_sha:
            published = open(os.path.join(work, shafile)).read().split()[0].lower()
            check(published == tarball_sha, "tarball matches its .sha256 file", tarball_sha[:16] + "…",
                  f"the file says {published}, the tarball is {tarball_sha}")
        with tarfile.open(os.path.join(work, tarball)) as t:
            names = set(t.getnames())
        missing = [x for x in TOOLS if f"pmon-{version}/bin/{x}" not in names]
        check(not missing, "tarball holds the four tools", bad="missing: " + ", ".join(missing))

    # ---- 2. The formula in the tap -----------------------------------------------------------
    print("== formula in the tap")
    ok, out = gh("api", f"repos/{a.tap}/contents/Formula/pmon.rb", "-H", "Accept: application/vnd.github.raw")
    if not ok:
        report("FAIL", "Formula/pmon.rb exists in the tap", f"{a.tap}: {out.splitlines()[0] if out else 'not found'}")
        return finish(workflow=(a, tag))
    formula = out
    report("PASS", "Formula/pmon.rb exists in the tap", a.tap)

    url = re.search(r'^  url "(.*)"$', formula, re.M)
    fsha = re.search(r'^  sha256 "([0-9a-f]{64})"$', formula, re.M)
    url, fsha = (url.group(1) if url else None), (fsha.group(1) if fsha else None)
    fversion = (re.search(r"/pmon-([0-9][^/]*?)\.tar\.gz$", url or "") or [None, None])[1]
    if prerelease:
        check(fversion != version, "formula is not on the pre-release", f"it is on {fversion}", f"the formula points at pre-release {version}")
        return finish(workflow=(a, tag))
    check(fversion == version, "formula version", version, f"the formula is for {fversion}, the release is {version}: the tap was not updated")
    check(url == f"{base}/{tarball}", "formula url is the release tarball", bad=f"{url}, expected {base}/{tarball}")
    if tarball_sha:
        check(fsha == tarball_sha, "formula sha256 is the tarball's", bad=f"formula {fsha}, tarball {tarball_sha}: brew install would refuse the download")

    block = re.search(r"^  bottle do\n(.*?)^  end$", formula, re.M | re.S)
    if not check(bool(block), "formula has a bottle block", bad="without one Homebrew builds from source and demands current Command Line Tools"):
        return finish(workflow=(a, tag), formula=(formula, tag, a))
    body = block.group(1)
    root = re.search(r'root_url "(.*)"', body)
    check(bool(root) and root.group(1) == base, "bottle root_url is this release", bad=f"{root.group(1) if root else 'none'}, expected {base}")
    tags = re.findall(r'([a-z0-9_]+): +"([0-9a-f]{64})"', body)
    check(bool(tags), "bottle block lists a bottle", bad="no '<tag>: \"<sha256>\"' line")
    check("cellar: :any_skip_relocation" in body, "bottle is relocatable (any_skip_relocation)", bad="the binaries should need no relocation")
    for btag, bsha in tags:
        name = f"pmon-{version}.{btag}.bottle.tar.gz"
        path = os.path.join(work, name)
        if not check(name in assets, f"bottle {btag} is attached to the release", name, f"the formula lists {name} but the release does not have it: brew install fails with 404"):
            continue
        actual = sha256(path)
        check(actual == bsha, f"bottle {btag} sha256 matches the formula", bad=f"formula {bsha}, file {actual}")
        # What brew does: GET <root_url>/<name>.
        p = subprocess.run(["curl", "-fsSIL", "-o", "/dev/null", "-w", "%{http_code}", f"{base}/{name}"], capture_output=True, text=True)
        check(p.returncode == 0 and p.stdout.strip() == "200", f"bottle {btag} downloads from its URL", bad=f"HTTP {p.stdout.strip() or p.stderr.strip()}")
        check_bottle(path, version)
    extra = [b for b in bottles if b not in {f"pmon-{version}.{t}.bottle.tar.gz" for t, _ in tags}]
    if extra:
        report("WARN", "bottles in the release that the formula does not list", ", ".join(extra))
    if tags and OLDEST_BOTTLE_TAG not in {t for t, _ in tags}:
        report("WARN", "bottle label", f"{', '.join(t for t, _ in tags)}; without {OLDEST_BOTTLE_TAG} users on older macOS get no bottle (BOTTLE_TAG in release.yml)")

    return finish(workflow=(a, tag), formula=(formula, tag, a))


def check_bottle(path, version):
    """The bottle unpacks to pmon/<version>/bin/* with valid signatures and the right version."""
    with tarfile.open(path) as t:
        names = set(t.getnames())
        missing = [x for x in TOOLS if f"pmon/{version}/bin/{x}" not in names]
        if not check(not missing, "bottle holds the four tools", bad="missing: " + ", ".join(missing)):
            return
        check(f"pmon/{version}/INSTALL_RECEIPT.json" in names, "bottle has its install receipt", bad="no INSTALL_RECEIPT.json")
        out = tempfile.mkdtemp(prefix="pmon-bottle-")
        for x in TOOLS:
            t.extract(f"pmon/{version}/bin/{x}", out)
    bindir = os.path.join(out, "pmon", version, "bin")
    if platform.system() != "Darwin":
        report("SKIP", "bottle binaries run and are signed", "not on macOS")
        return
    bad = [x for x in TOOLS if subprocess.run(["codesign", "--verify", "--strict", os.path.join(bindir, x)], capture_output=True).returncode != 0]
    check(not bad, "bottle binaries are validly signed", bad="codesign rejects: " + ", ".join(bad))
    if platform.machine() != "arm64":
        report("SKIP", "bottle pmon reports the version", "the binaries are Apple Silicon only")
        return
    p = subprocess.run([os.path.join(bindir, "pmon"), "--version"], capture_output=True, text=True)
    check(p.stdout.strip() == version, "bottle pmon reports the version", version, f"it says '{p.stdout.strip() or p.stderr.strip()}'")


def finish(workflow=None, formula=None):
    if formula:
        text, tag, a = formula
        print("== formula source")
        ok, src = gh("api", f"repos/{a.repo}/contents/Support/homebrew/pmon.rb?ref={tag}", "-H", "Accept: application/vnd.github.raw")
        if not ok:
            report("WARN", "formula source at the tag", f"no Support/homebrew/pmon.rb at {tag}")
        else:
            same = strip_release_specifics(src) == strip_release_specifics(text)
            report("PASS" if same else "WARN", "tap formula matches Support/homebrew/pmon.rb at the tag",
                   "" if same else "they differ beyond url, sha256 and bottle: the tap was edited by hand, or written from another commit")
        ok, out = gh("api", f"repos/{a.tap}/commits?path=Formula/pmon.rb&per_page=1", "--jq", ".[0] | [.commit.message, .commit.author.date] | @tsv")
        if ok and out.strip():
            message, date = (out.strip().split("\t") + [""])[:2]
            expected = f"pmon {tag.lstrip('v')}"
            report("PASS" if message.splitlines()[0] == expected else "WARN", "last tap commit for the formula", f"'{message.splitlines()[0]}' on {date[:10]}")
    if workflow:
        a, tag = workflow
        print("== release workflow")
        ok, out = gh("run", "list", "--repo", a.repo, "--workflow", "release.yml", "--limit", "30",
                     "--json", "databaseId,headBranch,headSha,event,conclusion,status,createdAt,displayTitle")
        runs = json.loads(out) if ok else []
        ok2, tagsha = gh("api", f"repos/{a.repo}/commits/{tag}", "--jq", ".sha")
        tagsha = tagsha.strip() if ok2 else None
        # A manual run starts on master and creates the tag, so match the tag name or the commit after it.
        run = next((r for r in runs if r["headBranch"] == tag), None)
        if run is None and tagsha:
            ok3, parent = gh("api", f"repos/{a.repo}/commits/{tag}", "--jq", ".parents[0].sha")
            candidates = {tagsha, parent.strip() if ok3 else ""}
            run = next((r for r in runs if r["headSha"] in candidates), None)
        if run is None:
            report("WARN", "Release workflow run for the tag", "none found among the last 30 runs")
        else:
            check(run["conclusion"] == "success", "Release workflow run", f"run {run['databaseId']} succeeded",
                  f"run {run['databaseId']} is {run['conclusion'] or run['status']}: gh run view {run['databaseId']} --repo {a.repo} --log-failed")
            ok, out = gh("run", "view", str(run["databaseId"]), "--repo", a.repo, "--json", "jobs")
            jobs = json.loads(out)["jobs"] if ok else []
            job = next((j for j in jobs if "omebrew" in j["name"]), None)
            if job is None:
                report("FAIL", "homebrew job", "the run has no Homebrew job: it ran a workflow from before the Homebrew step was added")
            else:
                skipped = [s["name"] for s in job.get("steps", []) if s.get("conclusion") == "skipped"]
                if job["conclusion"] != "success":
                    report("FAIL", "homebrew job", f"{job['conclusion']}: gh run view {run['databaseId']} --repo {a.repo} --log-failed")
                elif any("Push the formula" in s for s in skipped):
                    report("FAIL", "homebrew job", "it skipped publishing: HOMEBREW_TAP_TOKEN is not set (or this is a pre-release)")
                else:
                    report("PASS", "homebrew job", "published the bottle and the formula")
    fails, warns = results.count("FAIL"), results.count("WARN")
    print(f"\n{results.count('PASS')} passed, {fails} failed, {warns} warnings")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
