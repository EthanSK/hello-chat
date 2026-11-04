#!/usr/bin/env python3
"""Create Sparkle's feed from the signed archive and its actual bundle metadata."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def create_feed(info: dict, archive: Path, signature: str, url: str) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "github.com" or parsed.username or parsed.password:
        raise ValueError("Release enclosure must use GitHub HTTPS")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    if len(base64.b64decode(info["SUPublicEDKey"], validate=True)) != 32:
        raise ValueError("Missing Sparkle public key")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "HelloChat updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "HelloChat " + info["CFBundleShortVersionString"]
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "enclosure", {"url": url, "length": str(archive.stat().st_size),
        "type": "application/octet-stream", "{" + SPARKLE + "}version": info["CFBundleVersion"],
        "{" + SPARKLE + "}shortVersionString": info["CFBundleShortVersionString"],
        "{" + SPARKLE + "}edSignature": signature})
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--signature-file", type=Path, required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_bytes(create_feed(plistlib.loads(args.plist.read_bytes()), args.archive,
        args.signature_file.read_text().strip(), args.url))


if __name__ == "__main__":
    main()
