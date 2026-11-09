#!/usr/bin/env python3
"""Check release version ownership and signed-feed metadata without credentials."""
import base64
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


versions = load("release_version", "prepare-release.py")
feeds = load("release_feed", "create-appcast.py")


class Releases(unittest.TestCase):
    def test_repeated_main_pushes_keep_versions_unique_and_builds_above_installed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            info = root / 'Info.plist'; releases = root / 'releases.json'; output = root / 'manifest.json'
            source = {'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '72'}
            previous = []
            results = []
            for iteration in range(2):
                info.write_bytes(plistlib.dumps(source))
                releases.write_text(json.dumps(previous))
                arguments = ['prepare-release', '--releases', str(releases), '--plist', str(info),
                    '--run-number', '1', '--commit', str(iteration) * 40, '--output', str(output)]
                # Reusing run number 1 also exercises a restored CI counter or
                # rerun: the published manifest still forces increasing builds.
                receipt = json.dumps(results[-1] if results else {}).encode()
                with patch.object(sys, 'argv', arguments), patch.object(versions.urllib.request, 'urlopen', return_value=io.BytesIO(receipt)), contextlib.redirect_stdout(io.StringIO()):
                    versions.main()
                result = json.loads(output.read_text()); results.append(result)
                previous = [{'tag_name': result['tag'], 'assets': [{'name': 'release-manifest.json',
                    'browser_download_url': 'https://github.com/EthanSK/hello-chat/releases/download/' + result['tag'] + '/release-manifest.json'}]}]
            self.assertEqual([result['version'] for result in results], ['1.0.0', '1.0.1'])
            self.assertGreater(results[0]['build'], 72)
            self.assertGreater(results[1]['build'], results[0]['build'])

    def test_first_release_and_automatic_patch(self):
        self.assertEqual(versions.release_version("1.0.0", []), "1.0.0")
        self.assertEqual(versions.release_version("1.0.0", [{"tag_name": "v1.0.0"}]), "1.0.1")

    def test_public_update_exceeds_installed_preview_build(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            info = root / 'Info.plist'; releases = root / 'releases.json'; output = root / 'manifest.json'
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1026'}))
            releases.write_text('[]')
            arguments = ['prepare-release', '--releases', str(releases), '--plist', str(info),
                         '--run-number', '14', '--commit', 'a' * 40, '--output', str(output)]
            with patch.object(sys, 'argv', arguments), contextlib.redirect_stdout(io.StringIO()):
                versions.main()
            self.assertEqual(json.loads(output.read_text())['build'], 1027)

    def test_numeric_order_and_new_source_baseline(self):
        releases = [{"tag_name": "v1.0.9"}, {"tag_name": "v1.0.10"}]
        self.assertEqual(versions.release_version("1.0.0", releases), "1.0.11")
        self.assertEqual(versions.release_version("2.0.0", releases), "2.0.0")

    def test_draft_and_unrelated_tags_do_not_advance_public_version(self):
        self.assertEqual(versions.release_version("1.0.0", [
            {"tag_name": "v9.0.0", "draft": True}, {"tag_name": "v3.0.0", "prerelease": True},
            {"tag_name": "archive-before-rename"}]), "1.0.0")

    def test_feed_uses_archive_bytes_and_signed_bundle_identity(self):
        info = {"CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "1002",
                "SUPublicEDKey": base64.b64encode(bytes(32)).decode(), "LSMinimumSystemVersion": "15.0"}
        signature = base64.b64encode(bytes(64)).decode()
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "app.zip"
            archive.write_bytes(b"signed archive fixture")
            root = ET.fromstring(feeds.create_feed(info, archive, signature,
                "https://github.com/EthanSK/hello-chat/releases/download/v1.0.1/HelloChat-macOS-arm64.zip"))
            enclosure = root.find("channel/item/enclosure")
            self.assertEqual(enclosure.attrib["length"], str(archive.stat().st_size))
            self.assertEqual(enclosure.attrib["{" + feeds.SPARKLE + "}version"], "1002")
            self.assertEqual(enclosure.attrib["{" + feeds.SPARKLE + "}edSignature"], signature)
            for url in ["http://github.com/file", "https://example.com/file", "https://secret@github.com/file"]:
                with self.assertRaises(ValueError): feeds.create_feed(info, archive, signature, url)
            with self.assertRaises(ValueError): feeds.create_feed(info, archive, "bad signature", "https://github.com/file")


if __name__ == "__main__":
    unittest.main()
