#!/usr/bin/env python3
"""Install the independent daily, AC-only HelloChat Drive backup LaunchAgent."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LABEL = "com.ethansk.hello-chat-transcript-backup"


def configuration(home, script, rclone_config=None, destination=None):
    arguments = ["/usr/bin/python3", str(script)]
    if rclone_config:
        arguments.extend(["--rclone-config", str(rclone_config)])
    if destination:
        arguments.extend(["--destination", destination])
    return {
        "Label": LABEL,
        "ProgramArguments": arguments,
        "StartInterval": 86400,
        "RunAtLoad": True,
        "ProcessType": "Background",
        "Nice": 10,
        "LowPriorityIO": True,
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": str(home / "Library/Logs/HelloChat/transcript-backup.stdout.log"),
        "StandardErrorPath": str(home / "Library/Logs/HelloChat/transcript-backup.stderr.log"),
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/bin:/bin"},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Write and load the user LaunchAgent; otherwise print its plist")
    parser.add_argument("--rclone-config", type=Path)
    parser.add_argument("--destination")
    args = parser.parse_args()
    home = Path.home()
    script = Path(__file__).resolve().with_name("backup-transcripts.py")
    if args.rclone_config and not args.rclone_config.is_file():
        parser.error("Dedicated rclone configuration does not exist")
    contents = plistlib.dumps(configuration(home, script, args.rclone_config, args.destination))
    if not args.install:
        sys.stdout.buffer.write(contents)
        return
    os.umask(0o077)
    agents = home / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    logs = home / "Library/Logs/HelloChat"
    logs.mkdir(mode=0o700, parents=True, exist_ok=True)
    logs.chmod(0o700)
    path = agents / (LABEL + ".plist")
    descriptor, name = tempfile.mkstemp(prefix=".hello-chat-backup-", dir=agents)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(contents)
    os.replace(name, path)
    domain = "gui/%d" % os.getuid()
    # This label is exclusively owned by HelloChat; leave Codex's backup alone.
    subprocess.run(["/bin/launchctl", "bootout", domain + "/" + LABEL],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(path)], check=True)
    subprocess.run(["/bin/launchctl", "print", domain + "/" + LABEL], check=True)


if __name__ == "__main__":
    main()
