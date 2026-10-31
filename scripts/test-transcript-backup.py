#!/usr/bin/env python3
"""Isolated transcript-copy safety checks; never contacts the real Drive account."""
import argparse
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("backup", Path(__file__).with_name("backup-transcripts.py"))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class TranscriptBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.args = argparse.Namespace(source=root / "archive", state=root / "state",
                                       destination="mock:preserved", rclone="mock-rclone", allow_battery=False)
        self.day = self.args.source / "2026-10-18"
        self.day.mkdir(parents=True)
        self.path = self.day / "session.json"
        self.path.write_text('{"text":"first words"}')
        self.calls = []
        self.power = patch.object(backup, "on_ac_power", return_value=True)
        self.power.start()
        self.addCleanup(self.power.stop)
        self.runner = patch.object(backup.subprocess, "run", side_effect=self.copied)
        self.runner.start()
        self.addCleanup(self.runner.stop)

    def copied(self, command, **kwargs):
        listing = Path(command[command.index("--files-from-raw") + 1]).read_text().splitlines()
        snapshots = {name: (Path(command[2]) / name).read_bytes() for name in listing}
        self.calls.append((command, snapshots))
        return types.SimpleNamespace(returncode=0)

    def test_changed_copy_then_zero_read_noop_and_atomic_revision(self):
        result = backup.run(self.args)
        self.assertEqual(result["changed_files"], 1)
        self.assertEqual(json.loads(next(iter(self.calls[0][1].values())))["records"][0]["transcript"]["text"], "first words")
        with patch.object(backup, "capture", side_effect=AssertionError("unchanged content read")):
            self.assertEqual(backup.run(self.args)["status"], "no-change")
        replacement = self.day / ".write"
        replacement.write_text('{"text":"revised words"}')
        replacement.replace(self.path)
        self.assertEqual(backup.run(self.args)["changed_files"], 1)
        self.assertEqual(len(self.calls), 2)

    def test_only_regular_visible_json_in_day_directories(self):
        (self.day / ".pending.json").write_text('{}')
        (self.day / "audio.wav").write_bytes(b"audio")
        (self.day / "link.json").symlink_to(self.path)
        (self.args.source / "secrets.json").write_text('{}')
        (self.args.source / "2026-10-19").symlink_to(self.day)
        result = backup.run(self.args)
        self.assertEqual(result["changed_files"], 1)
        command = self.calls[0][0]
        self.assertEqual(command[1], "copy")
        self.assertNotIn("--delete-excluded", command)
        payload = json.loads(next(iter(self.calls[0][1].values())))
        self.assertEqual([r["path"] for r in payload["records"]], ["2026-10-18/session.json"])

    def test_battery_skips_without_scanning_or_networking(self):
        with patch.object(backup, "on_ac_power", return_value=False), patch.object(backup, "eligible", side_effect=AssertionError):
            self.assertEqual(backup.run(self.args)["status"], "waiting-for-ac")
        self.assertFalse(self.calls)
        self.assertFalse((self.args.state / "last-success.json").exists())

    def test_failure_retains_success_and_retries_changed_file(self):
        backup.run(self.args)
        prior = (self.args.state / "last-success.json").read_bytes()
        self.path.write_text('{"text":"another revision"}')
        with patch.object(backup.subprocess, "run", return_value=types.SimpleNamespace(returncode=5)):
            with self.assertRaises(RuntimeError):
                backup.run(self.args)
        self.assertEqual((self.args.state / "last-success.json").read_bytes(), prior)
        self.assertTrue((self.args.state / "last-failure.json").exists())
        self.assertEqual(backup.run(self.args)["changed_files"], 1)
        self.assertFalse((self.args.state / "last-failure.json").exists())

    def test_deleted_local_keeps_remote_receipt(self):
        backup.run(self.args)
        self.path.unlink()
        self.assertEqual(backup.run(self.args)["status"], "no-change")
        entries = json.loads((self.args.state / "last-success.json").read_text())["entries"]
        self.assertIn("2026-10-18/session.json", entries)
        self.assertEqual(len(self.calls), 1)

    def test_invalid_json_refuses_upload_and_private_receipts(self):
        self.path.write_text('{"text":"unfinished secret')
        with self.assertRaises(ValueError):
            backup.run(self.args)
        self.assertFalse(self.calls)
        failure = self.args.state / "last-failure.json"
        self.assertNotIn("unfinished secret", failure.read_text())
        self.assertEqual(stat.S_IMODE(failure.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.args.state.stat().st_mode), 0o700)

    def test_atomic_replace_during_open_is_skipped_and_retried(self):
        wanted = backup.signature(self.path.stat())
        original_open = backup.os.open

        def replaced_after_open(path, flags):
            descriptor = original_open(path, flags)
            replacement = self.day / ".new"
            replacement.write_text('{"text":"later revision"}')
            replacement.replace(self.path)
            return descriptor

        with patch.object(backup.os, "open", side_effect=replaced_after_open):
            receipt = backup.capture(self.args.source, "2026-10-18/session.json", wanted)
        self.assertIsNone(receipt)
        wanted = backup.signature(self.path.stat())
        receipt = backup.capture(self.args.source, "2026-10-18/session.json", wanted)
        self.assertIsNotNone(receipt)
        self.assertEqual(receipt[1]["text"], "later revision")

    def test_raced_files_are_reported_deferred_instead_of_success(self):
        with patch.object(backup, "capture", return_value=None):
            result = backup.run(self.args)
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["deferred_files"], 1)
        self.assertFalse((self.args.state / "last-success.json").exists())
        self.assertFalse(self.calls)

    def test_destination_change_reuploads_and_lock_prevents_overlap(self):
        backup.run(self.args)
        self.args.destination = "mock:new-folder"
        self.assertEqual(backup.run(self.args)["changed_files"], 1)
        with (self.args.state / "run.lock").open("a") as lock:
            backup.fcntl.flock(lock, backup.fcntl.LOCK_EX | backup.fcntl.LOCK_NB)
            self.assertEqual(backup.run(self.args)["status"], "already-running")
        self.assertEqual(len(self.calls), 2)

    def test_many_contexts_use_one_immutable_snapshot_and_only_changed_days_are_read(self):
        for number in range(50):
            (self.day / (str(number) + ".json")).write_text(json.dumps({"text": "context " + str(number)}))
        other = self.args.source / "2026-10-19"; other.mkdir()
        (other / "later.json").write_text('{"text":"next day"}')
        result = backup.run(self.args)
        self.assertEqual(result["changed_files"], 52)
        self.assertEqual(result["uploaded_snapshots"], 2)
        self.assertEqual(len(self.calls[0][1]), 2)
        first_names = set(self.calls[0][1])
        self.path.write_text('{"text":"changed one context"}')
        original_capture = backup.capture
        paths = []
        def checked_capture(source, relative, wanted):
            paths.append(relative)
            return original_capture(source, relative, wanted)
        with patch.object(backup, "capture", side_effect=checked_capture):
            result = backup.run(self.args)
        self.assertEqual(result["changed_files"], 1)
        self.assertEqual(result["uploaded_snapshots"], 1)
        self.assertEqual(len(paths), 51)
        self.assertTrue(all(p.startswith("2026-10-18/") for p in paths))
        self.assertFalse(first_names & set(self.calls[-1][1]), "Revised daily data must not overwrite earlier snapshots")

    def test_raced_unchanged_context_defers_whole_changed_day(self):
        (self.day / "other.json").write_text('{"text":"other"}')
        backup.run(self.args)
        self.path.write_text('{"text":"new"}')
        prior = (self.args.state / "last-success.json").read_bytes()
        original_capture = backup.capture
        def race(source, relative, wanted):
            return None if relative.endswith("other.json") else original_capture(source, relative, wanted)
        with patch.object(backup, "capture", side_effect=race):
            result = backup.run(self.args)
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["deferred_files"], 1)
        self.assertEqual((self.args.state / "last-success.json").read_bytes(), prior)

    def test_quota_receipt_excludes_raw_response_and_has_bounded_command(self):
        completed = types.SimpleNamespace(returncode=1, stderr="Error403: rateLimitExceeded private-response-marker")
        with patch.object(backup.subprocess, "run", return_value=completed) as run:
            with self.assertRaises(RuntimeError): backup.run(self.args)
        failure = json.loads((self.args.state / "last-failure.json").read_text())["error"]
        self.assertIn("quota", failure)
        self.assertNotIn("private-response-marker", failure)
        self.assertEqual(run.call_args.kwargs["timeout"], 150)
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--max-duration") + 1], "120s")

    def test_dedicated_config_is_explicit_and_missing_config_never_falls_back(self):
        self.args.rclone_config = Path(self.temporary.name) / "private.conf"
        with self.assertRaisesRegex(RuntimeError, "refusing to use another account"):
            backup.run(self.args)
        self.assertFalse(self.calls)
        self.args.rclone_config.write_text("[private]\ntype = drive\n")
        backup.run(self.args)
        command = self.calls[0][0]
        self.assertEqual(command[command.index("--config") + 1], str(self.args.rclone_config))

    def test_installer_persists_dedicated_route_without_changing_schedule(self):
        spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install-transcript-backup.py"))
        installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
        config = installer.configuration(Path('/home/test'), Path('/project/backup.py'), Path('/private/rclone.conf'), 'heychat:transcripts')
        self.assertEqual(config['ProgramArguments'], ['/usr/bin/python3', '/project/backup.py', '--rclone-config', '/private/rclone.conf', '--destination', 'heychat:transcripts'])
        self.assertEqual(config['StartCalendarInterval'], {'Hour': 5, 'Minute': 45})
        self.assertNotIn('StartInterval', config)
        self.assertNotIn('RunAtLoad', config)
        self.assertTrue(config['LowPriorityIO'])


if __name__ == "__main__":
    unittest.main()
