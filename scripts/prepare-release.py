#!/usr/bin/env python3
"""Allocate local or public app versions; build.sh and the Release job share this policy. — GPT-6.1 Sol"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import urllib.request


def release_version(base: str, releases: list[dict]) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", base):
        raise ValueError("Expected a three-part source version")
    parts = tuple(map(int, base.split(".")))
    if len(parts) != 3:
        raise ValueError("Expected a three-part source version")
    published = []
    for release in releases:
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", release.get("tag_name", ""))
        if match and not release.get("draft") and not release.get("prerelease"):
            published.append(tuple(map(int, match.groups())))
    latest = max(published, default=(-1, -1, -1))
    # Source owns the requested major/minor baseline. Every main push after a
    # published baseline advances its patch; no bot commit loops back to main.
    selected = parts if parts > latest else (latest[0], latest[1], latest[2] + 1)
    return ".".join(map(str, selected))


def local_release_info(source: dict, installed: dict | None) -> dict:
    """Advance both numbers above the last signed source and installed app. — GPT-6.1 Sol"""
    previous = [source] + ([installed] if installed else [])
    for info in previous:
        if info.get("CFBundleIdentifier") != "com.ethansk.HeyChat":
            raise ValueError("The local version floor must belong to H Chat")
        if not re.fullmatch(r"\d+\.\d+\.\d+", info.get("CFBundleShortVersionString", "")):
            raise ValueError("Invalid local version floor")
        if not re.fullmatch(r"[1-9]\d*", str(info.get("CFBundleVersion", ""))):
            raise ValueError("Invalid local build floor")
    latest = max(tuple(map(int, info["CFBundleShortVersionString"].split("."))) for info in previous)
    result = dict(source)
    result.update(CFBundleShortVersionString=".".join(map(str, (*latest[:2], latest[2] + 1))),
                  CFBundleVersion=str(max(int(info["CFBundleVersion"]) for info in previous) + 1))
    return result


def record_local_release(source: Path, baseline: Path, built: Path) -> None:
    """Record the signed version without overwriting edits made during compilation. — GPT-6.1 Sol"""
    if source.read_bytes() != baseline.read_bytes():
        raise RuntimeError("Source Info.plist changed during the build; its version was not overwritten")
    info = plistlib.loads(source.read_bytes())
    signed = plistlib.loads(built.read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        info[key] = signed[key]
    with tempfile.NamedTemporaryFile(dir=source.parent, prefix=".Info.release.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(plistlib.dumps(info, sort_keys=False))
    try:
        os.chmod(temporary, source.stat().st_mode & 0o777)
        os.replace(temporary, source)
    finally:
        temporary.unlink(missing_ok=True)


def verify_local_release_source(root: Path, installed: Path) -> str:
    """Reject signed builds from a stale Git base or an unrecorded build floor."""
    def git(*args: str) -> str:
        return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

    git('fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main')
    head = git('rev-parse', 'HEAD')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', 'origin/main', head], cwd=root).returncode:
        raise RuntimeError('Reconcile origin/main through Git before building a signed H Chat update.')
    if git('status', '--porcelain', '--untracked-files=normal', '--', 'Info.plist',
           'Package.swift', 'Package.resolved', 'Sources', 'Resources', 'scripts'):
        raise RuntimeError('Commit H Chat build inputs before signing so the release records their exact revision.')
    if installed.exists():
        source = plistlib.loads((root / 'Info.plist').read_bytes())
        previous = plistlib.loads(installed.read_bytes())
        local_release_info(source, previous)
        if int(source['CFBundleVersion']) < int(previous['CFBundleVersion']):
            raise RuntimeError('Reconcile the installed H Chat build floor in Git before signing its replacement.')
    return head


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases", type=Path)
    parser.add_argument("--plist", type=Path, required=True)
    parser.add_argument("--run-number", type=int)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--installed-plist", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{40}", args.commit):
        parser.error("Invalid release run identity")
    if args.local:
        if args.releases or args.run_number is not None:
            parser.error("Local allocation does not use public release inputs")
        info = plistlib.loads(args.plist.read_bytes())
        installed = (plistlib.loads(args.installed_plist.read_bytes())
                     if args.installed_plist and args.installed_plist.exists() else None)
        info = local_release_info(info, installed)
        args.plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        args.output.write_text(json.dumps({"version": info["CFBundleShortVersionString"],
            "build": int(info["CFBundleVersion"]), "commit": args.commit, "mode": "local"}, indent=2) + "\n")
        print(info["CFBundleShortVersionString"])
        return
    if args.releases is None or args.run_number is None or args.run_number < 1 or args.installed_plist:
        parser.error("Public allocation requires releases and a positive run number")
    releases = json.loads(args.releases.read_text())
    # gh api --paginate --slurp returns one array per API page.
    if releases and isinstance(releases[0], list):
        releases = [release for page in releases for release in page]
    info = plistlib.loads(args.plist.read_bytes())
    version = release_version(info["CFBundleShortVersionString"], releases)
    previous_build = 0
    # Release metadata is an immutable receipt, not another editable version
    # source. Reading it keeps retries and restored workflow run counts above
    # the build already offered to installed clients.
    published = [release for release in releases if not release.get("draft")
                 and not release.get("prerelease")
                 and re.fullmatch(r"v\d+\.\d+\.\d+", release.get("tag_name", ""))]
    latest = max(published, key=lambda release: tuple(map(int, release["tag_name"][1:].split("."))), default={})
    for asset in latest.get("assets", []):
        if asset.get("name") != "release-manifest.json":
            continue
        url = asset["browser_download_url"]
        if not url.startswith("https://github.com/EthanSK/hello-chat/releases/download/"):
            raise ValueError("Unexpected release manifest URL")
        with urllib.request.urlopen(url, timeout=30) as response:
            receipt = json.load(response)
        previous_build = int(receipt["build"])
    # Local signed previews can be ahead of the latest public release. Keep
    # the source's installed-build floor so their next update is offered too.
    build = max(1000 + args.run_number, previous_build + 1, int(info["CFBundleVersion"]) + 1)
    info.update(CFBundleShortVersionString=version, CFBundleVersion=str(build))
    args.plist.write_bytes(plistlib.dumps(info, sort_keys=False))
    args.output.write_text(json.dumps({"version": version, "build": build,
        "tag": "v" + version, "commit": args.commit}, indent=2) + "\n")
    print("v" + version)


if __name__ == "__main__":
    main()
