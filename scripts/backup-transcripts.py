#!/usr/bin/env python3
"""Incrementally copy HelloChat's JSON transcript archive to the existing Drive account.

Changed days become compact, immutable JSON snapshots, one upload per day rather
than per recognition context. No audio, deletions or persistent local mirror.
Receipts contain metadata, not transcript text.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

SUPPORT = Path.home() / "Library/Application Support/HelloChat"
DESTINATION = "gdrive:HelloChat Backup/Transcripts"
FORMAT = "hey-chat-daily-snapshots-v1"


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def signature(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def write_json(path, value):
    descriptor, name = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(value, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def on_ac_power():
    result = subprocess.run(["/usr/bin/pmset", "-g", "batt"],
                            capture_output=True, text=True, timeout=10, check=True)
    return "Now drawing from 'AC Power'" in result.stdout


def eligible(source):
    """Never follow links or include hidden/atomic-write temporary files."""
    if source.is_symlink():
        raise RuntimeError("Transcript archive must not be a symbolic link")
    if not source.exists():
        return {}
    files = {}
    for day in source.iterdir():
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day.name) or day.is_symlink() or not day.is_dir():
            continue
        for path in day.iterdir():
            if path.name.startswith(".") or path.suffix != ".json" or "\n" in path.name or "\r" in path.name:
                continue
            info = path.lstat()
            if stat.S_ISREG(info.st_mode):
                files[str(path.relative_to(source))] = signature(info)
    return files


def capture(source, relative, wanted):
    """Hold an immutable, valid JSON snapshot while the app atomically revises it."""
    path = source / relative
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        before = os.fstat(handle.fileno())
        if signature(before) != wanted or not stat.S_ISREG(before.st_mode):
            return None
        data = handle.read()
        if signature(os.fstat(handle.fileno())) != wanted:
            return None
    # A replacement after these checks cannot alter this open descriptor's
    # bytes. Its original receipt ensures the next run sees the new revision.
    document = json.loads(data)
    return {"signature": wanted, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}, document


def copy_command(args, source, listing):
    # copy (never sync) preserves remote-only history. An explicit file list
    # excludes .atomic files, locks, receipts and anything outside the archive.
    command = [args.rclone, "copy", str(source), args.destination,
            "--files-from-raw", str(listing), "--checksum", "--no-traverse",
            "--transfers", "1", "--checkers", "1", "--drive-chunk-size", "8M",
            "--bwlimit", "1M", "--tpslimit", "1", "--tpslimit-burst", "1",
            "--contimeout", "15s", "--timeout", "30s", "--retries", "1",
            "--max-duration", "120s", "--cutoff-mode", "HARD",
            "--low-level-retries", "2", "--no-update-dir-modtime", "--log-level", "ERROR"]
    if getattr(args, "rclone_config", None):
        command.extend(["--config", str(args.rclone_config)])
    return command


def daily_snapshots(args, selected, changed, root):
    """Capture complete changed days; never replace or delete prior cloud history."""
    snapshots, captured, backed_changes = {}, {}, set()
    output = root / "snapshots"
    output.mkdir(mode=0o700)
    changed_days = {relative.split("/", 1)[0] for relative in changed}
    grouped = {}
    for relative, wanted in selected.items():
        day = relative.split("/", 1)[0]
        if day in changed_days:
            grouped.setdefault(day, []).append((relative, wanted))
    for day, day_files in sorted(grouped.items()):
        records, day_entries = [], {}
        for relative, wanted in sorted(day_files):
            try:
                captured_context = capture(args.source, relative, wanted)
            except FileNotFoundError:
                captured_context = None
            if captured_context is None:
                break  # Retry the entire day, never label a partial day complete.
            entry, document = captured_context
            records.append({"path": relative, "sha256": entry["sha256"],
                            "transcript": document})
            day_entries[relative] = entry
        else:
            value = {"format": FORMAT, "day": day,
                     "retention": "Immutable snapshot. Earlier snapshots remain; merge contexts by path and updatedAt.",
                     "records": records}
            data = (json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
            digest = hashlib.sha256(data).hexdigest()
            # Content-addressed names make retries idempotent. Revised/deleted
            # local contexts cannot overwrite their earlier backed-up versions.
            name = day + "--" + digest + ".json"
            (output / name).write_bytes(data)
            snapshots[name] = {"sha256": digest, "size": len(data), "day": day, "contexts": len(records)}
            captured.update({p: {**entry, "snapshot": name} for p, entry in day_entries.items()})
            backed_changes.update(set(day_entries) & set(changed))
    return output, snapshots, captured, backed_changes


def run(args):
    os.umask(0o077)
    args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.state.chmod(0o700)
    started = time.monotonic()
    with (args.state / "run.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"status": "already-running"}
        try:
            if getattr(args, "rclone_config", None) and not args.rclone_config.is_file():
                raise RuntimeError("Dedicated Drive configuration is missing; refusing to use another account")
            if not args.allow_battery and not on_ac_power():
                result = {"status": "waiting-for-ac", "checked_at_utc": utc()}
                write_json(args.state / "last-check.json", result)
                return result
            previous = read_json(args.state / "last-success.json")
            if (previous.get("source") != str(args.source) or previous.get("destination") != args.destination
                    or previous.get("format") != FORMAT):
                previous = {}
            old = previous.get("entries", {})
            selected = eligible(args.source)
            changed = {p: value for p, value in selected.items() if old.get(p, {}).get("signature") != value}
            entries = dict(old)  # Retain receipts and remote history if local files disappear.
            captured, snapshots, backed_changes = {}, {}, set()
            # Small text only, ephemeral changed-file staging; removed on exit.
            with tempfile.TemporaryDirectory(prefix="hello-chat-drive-") as temporary:
                root = Path(temporary)
                source, snapshots, captured, backed_changes = daily_snapshots(args, selected, changed, root)
                if snapshots:
                    listing = root / "files.txt"
                    listing.write_text("\n".join(sorted(snapshots)) + "\n")
                    completed = subprocess.run(copy_command(args, source, listing),
                                               stdout=subprocess.DEVNULL,
                                               stderr=subprocess.PIPE, text=True, timeout=150)
                    if completed.returncode:
                        # Classify errors without storing transcript text, paths,
                        # credentials or the raw service response in receipts.
                        detail = getattr(completed, "stderr", "") or ""
                        if re.search(r"quota|rate.?limit", detail, re.IGNORECASE):
                            reason = "Google Drive query quota or rate limit"
                        elif re.search(r"invalid_grant|unauthorized|Error 401", detail, re.IGNORECASE):
                            reason = "Google Drive authentication"
                        elif re.search(r"permission|forbidden|Error 403", detail, re.IGNORECASE):
                            reason = "Google Drive access denied"
                        else:
                            reason = "Drive copy"
                        raise RuntimeError("%s failed (rclone exit %d); next run will retry" % (reason, completed.returncode))
                    entries.update(captured)
            deferred = len(changed) - len(backed_changes)
            status = "copied" if snapshots else "no-change"
            if deferred:
                status = "copied-with-deferred-files" if captured else "deferred"
            result = {"status": status,
                      "finished_at_utc": utc(), "changed_files": len(backed_changes),
                      "uploaded_snapshots": len(snapshots), "captured_contexts": len(captured),
                      "deferred_files": deferred,
                      "copied_bytes": sum(e["size"] for e in snapshots.values()),
                      "elapsed_seconds": round(time.monotonic() - started, 3)}
            if captured or (not previous and not deferred):
                write_json(args.state / "last-success.json", {
                    **result, "format": FORMAT, "source": str(args.source), "destination": args.destination,
                    "entries": entries, "snapshots": {**previous.get("snapshots", {}), **snapshots}})
            write_json(args.state / "last-check.json", result)
            if not deferred:
                (args.state / "last-failure.json").unlink(missing_ok=True)
            return result
        except Exception as error:
            # Never emit transcript contents or rclone configuration/credentials.
            message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
            write_json(args.state / "last-failure.json", {
                "status": "failed", "failed_at_utc": utc(), "error": message})
            raise


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SUPPORT / "Transcripts")
    parser.add_argument("--state", type=Path, default=SUPPORT / "BackupState")
    parser.add_argument("--destination", default=DESTINATION)
    parser.add_argument("--rclone", default=shutil.which("rclone") or "/opt/homebrew/bin/rclone")
    parser.add_argument("--rclone-config", type=Path, help="Dedicated private rclone configuration; never falls back to the global account")
    parser.add_argument("--allow-battery", action="store_true", help="Explicitly run a manual backup on battery")
    return parser.parse_args()


if __name__ == "__main__":
    try:
        print(json.dumps(run(parse_args()), separators=(",", ":")))
    except Exception as error:
        print("HelloChat transcript backup failed (%s); see private BackupState receipt" % type(error).__name__, file=sys.stderr)
        sys.exit(1)
