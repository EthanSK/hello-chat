#!/usr/bin/env python3
"""Check release version ownership and signed-feed metadata without credentials."""
import base64
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
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
    def test_signed_source_rejects_new_public_work_dirty_code_and_unrecorded_floor(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            origin = root / 'origin'
            peer = root / 'peer'

            def git(repo, *args):
                return subprocess.check_output(['git', '-C', repo, *args],
                                               text=True, stderr=subprocess.DEVNULL).strip()

            origin.mkdir()
            git(origin, 'init', '-b', 'main')
            git(origin, 'config', 'user.name', 'Release fixture')
            git(origin, 'config', 'user.email', 'release@example.invalid')
            info = {'CFBundleIdentifier': 'com.ethansk.HeyChat',
                    'CFBundleShortVersionString': '1.9.5', 'CFBundleVersion': '1133'}
            (origin / 'Info.plist').write_bytes(plistlib.dumps(info))
            git(origin, 'add', 'Info.plist')
            git(origin, 'commit', '-m', 'Common version')
            git(root, 'clone', str(origin), str(peer))
            installed = root / 'InstalledInfo.plist'
            installed.write_bytes(plistlib.dumps(info))
            self.assertEqual(versions.verify_local_release_source(peer, installed), git(peer, 'rev-parse', 'HEAD'))

            installed.write_bytes(plistlib.dumps(dict(info, CFBundleVersion='1134')))
            with self.assertRaisesRegex(RuntimeError, 'installed H Chat build floor'):
                versions.verify_local_release_source(peer, installed)
            installed.write_bytes(plistlib.dumps(info))
            (peer / 'Sources').mkdir()
            dirty = peer / 'Sources/Voice.swift'
            dirty.write_text('// Uncommitted runtime source')
            with self.assertRaisesRegex(RuntimeError, 'Commit H Chat build inputs'):
                versions.verify_local_release_source(peer, installed)
            dirty.unlink()

            git(origin, 'commit', '--allow-empty', '-m', 'Peer update')
            with self.assertRaisesRegex(RuntimeError, 'Reconcile origin/main'):
                versions.verify_local_release_source(peer, installed)
            git(peer, 'merge', '--ff-only', 'origin/main')
            self.assertEqual(versions.verify_local_release_source(peer, installed), git(origin, 'rev-parse', 'HEAD'))

    def test_bundle_advertises_the_existing_command_receipt_protocol(self):
        info = plistlib.loads((Path(__file__).resolve().parent.parent / 'Info.plist').read_bytes())
        self.assertIs(type(info.get('HChatCommandReceiptVersion')), int)
        self.assertEqual(info['HChatCommandReceiptVersion'], 1)
        allocated = versions.local_release_info(info, info)
        self.assertEqual(allocated['HChatCommandReceiptVersion'], 1)

    def test_local_releases_advance_both_numbers_without_installing_each_build(self):
        source = {'CFBundleIdentifier': 'com.ethansk.HeyChat',
                  'CFBundleShortVersionString': '1.5.0', 'CFBundleVersion': '1069',
                  'SUPublicEDKey': 'unchanged'}
        first = versions.local_release_info(source, source)
        second = versions.local_release_info(first, source)
        self.assertEqual((first['CFBundleShortVersionString'], first['CFBundleVersion']), ('1.5.1', '1070'))
        self.assertEqual((second['CFBundleShortVersionString'], second['CFBundleVersion']), ('1.5.2', '1071'))
        self.assertEqual(second['SUPublicEDKey'], 'unchanged')

    def test_local_release_exceeds_newer_installed_versions_and_rejects_bad_floors(self):
        source = {'CFBundleIdentifier': 'com.ethansk.HeyChat',
                  'CFBundleShortVersionString': '1.5.0', 'CFBundleVersion': '1069'}
        installed = dict(source, CFBundleShortVersionString='1.5.9', CFBundleVersion='1090')
        allocated = versions.local_release_info(source, installed)
        self.assertEqual((allocated['CFBundleShortVersionString'], allocated['CFBundleVersion']), ('1.5.10', '1091'))
        for invalid in [dict(installed, CFBundleIdentifier='another.app'),
                        dict(installed, CFBundleVersion='bad'),
                        dict(installed, CFBundleShortVersionString='latest')]:
            with self.assertRaises(ValueError): versions.local_release_info(source, invalid)

    def test_local_cli_allocates_only_the_owned_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact, installed, output = [root / name for name in ['built.plist', 'installed.plist', 'manifest.json']]
            info = {'CFBundleIdentifier': 'com.ethansk.HeyChat',
                    'CFBundleShortVersionString': '1.5.0', 'CFBundleVersion': '1069'}
            for path in [artifact, installed]: path.write_bytes(plistlib.dumps(info))
            arguments = ['prepare-release', '--local', '--plist', str(artifact), '--installed-plist', str(installed),
                         '--commit', 'a' * 40, '--output', str(output)]
            with patch.object(sys, 'argv', arguments), contextlib.redirect_stdout(io.StringIO()): versions.main()
            self.assertEqual(plistlib.loads(installed.read_bytes()), info)
            self.assertEqual(plistlib.loads(artifact.read_bytes())['CFBundleVersion'], '1070')
            self.assertEqual(json.loads(output.read_text())['version'], '1.5.1')

    def test_signed_floor_preserves_other_fields_and_rejects_concurrent_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, baseline, built = [root / name for name in ['source.plist', 'baseline.plist', 'built.plist']]
            info = {'CFBundleIdentifier': 'com.ethansk.HeyChat', 'CFBundleShortVersionString': '1.5.0',
                    'CFBundleVersion': '1069', 'SUPublicEDKey': 'unchanged'}
            for path in [source, baseline]: path.write_bytes(plistlib.dumps(info))
            built.write_bytes(plistlib.dumps(dict(info, CFBundleShortVersionString='1.5.1', CFBundleVersion='1070',
                                                  GeneratedBundleOnly='not a source setting')))
            versions.record_local_release(source, baseline, built)
            self.assertEqual(plistlib.loads(source.read_bytes()), dict(info, CFBundleShortVersionString='1.5.1', CFBundleVersion='1070'))
            self.assertFalse(list(root.glob('.Info.release.*')))
            edited = dict(info, SUPublicEDKey='new user edit')
            source.write_bytes(plistlib.dumps(edited))
            with self.assertRaises(RuntimeError): versions.record_local_release(source, baseline, built)
            self.assertEqual(plistlib.loads(source.read_bytes()), edited)

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
        info = {"CFBundleName": "Hello Chat", "CFBundleDisplayName": "HelloChat",
                "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "1002",
                "SUPublicEDKey": base64.b64encode(bytes(32)).decode(), "LSMinimumSystemVersion": "15.0"}
        signature = base64.b64encode(bytes(64)).decode()
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "app.zip"
            archive.write_bytes(b"signed archive fixture")
            root = ET.fromstring(feeds.create_feed(info, archive, signature,
                "https://github.com/EthanSK/hello-chat/releases/download/v1.0.1/HelloChat-macOS-arm64.zip"))
            self.assertEqual(root.findtext("channel/title"), "Hello Chat updates")
            self.assertEqual(root.findtext("channel/item/title"), "Hello Chat 1.0.1")
            enclosure = root.find("channel/item/enclosure")
            self.assertEqual(enclosure.attrib["length"], str(archive.stat().st_size))
            self.assertEqual(enclosure.attrib["{" + feeds.SPARKLE + "}version"], "1002")
            self.assertEqual(enclosure.attrib["{" + feeds.SPARKLE + "}edSignature"], signature)
            for url in ["http://github.com/file", "https://example.com/file", "https://secret@github.com/file"]:
                with self.assertRaises(ValueError): feeds.create_feed(info, archive, signature, url)
            with self.assertRaises(ValueError): feeds.create_feed(info, archive, "bad signature", "https://github.com/file")


if __name__ == "__main__":
    unittest.main()
