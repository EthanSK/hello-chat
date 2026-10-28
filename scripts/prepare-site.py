#!/usr/bin/env python3
"""Generate website PNG assets and refresh/check content-derived cache keys.

Run on macOS after changing the app icon, sharing image, CSS, or JavaScript.
The Swift app icon generator and website source remain authoritative.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
docs = root / "docs"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="Check asset references without writing files")
args = parser.parse_args()

if not args.check:
    with tempfile.TemporaryDirectory(prefix="hellochat-site-") as temp:
        subprocess.run(["swift", str(root / "scripts/make-icon.swift"), temp], check=True)
        icon = Path(temp) / "icon-512.png"
        shutil.copyfile(icon, docs / "app-icon.png")
        subprocess.run(["swift", str(root / "scripts/render-site-image.swift"), str(icon), str(docs / "og.png")], check=True)

stale = []
pattern = re.compile(r'(?P<base>(?:https://ethansk\.github\.io)?(?:/hello-chat/|\./))(?P<asset>[A-Za-z0-9_.-]+)\?v=[A-Za-z0-9]+')
for source in [docs / "site.webmanifest", *docs.glob("*.html")]:
    text = source.read_text()
    def replace(match):
        asset = docs / match["asset"]
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()[:12]
        expected = f'{match["base"]}{match["asset"]}?v={digest}'
        if match[0] != expected:
            stale.append(f"{source.name}: {match['asset']}")
        return expected
    updated = pattern.sub(replace, text)
    if not args.check and updated != text:
        source.write_text(updated)
if args.check and stale:
    raise SystemExit("Stale website assets; run scripts/prepare-site.py:\n" + "\n".join(stale))
print("Website asset references are current." if args.check else "Website PNGs and cache keys generated.")
