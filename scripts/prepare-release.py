#!/usr/bin/env python3
"""Choose the next public patch version for the serialized main-push release job."""
import argparse
import json
from pathlib import Path
import plistlib
import re
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases", type=Path, required=True)
    parser.add_argument("--plist", type=Path, required=True)
    parser.add_argument("--run-number", type=int, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{40}", args.commit) or args.run_number < 1:
        parser.error("Invalid release run identity")
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
