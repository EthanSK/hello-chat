#!/usr/bin/env python3
"""Install HelloChat's independent AC-only Drive backup at 05:45 local time."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LABEL = "com.ethansk.hello-chat-transcript-backup"


def saved_route(path):
    if not path.exists():
        return None, None
    settings = plistlib.loads(path.read_bytes())
    arguments = settings.get("ProgramArguments", [])
    if settings.get("Label") != LABEL or len(arguments) < 2 or Path(arguments[1]).name != "backup-transcripts.py":
        raise ValueError("Existing backup job is not owned by this installer")
    parsed = argparse.ArgumentParser(add_help=False)
    parsed.add_argument("--rclone-config", type=Path)
    parsed.add_argument("--destination")
    values, extra = parsed.parse_known_args(arguments[2:])
    if extra:
        raise ValueError("Existing backup job has custom arguments; refusing to replace them")
    return values.rclone_config, values.destination


def configuration(home, script, rclone_config=None, destination=None):
    arguments = ["/usr/bin/python3", str(script)]
    if rclone_config:
        arguments.extend(["--rclone-config", str(rclone_config)])
    if destination:
        arguments.extend(["--destination", destination])
    return {
        "Label": LABEL,
        "ProgramArguments": arguments,
        "StartCalendarInterval": {"Hour": 5, "Minute": 45},  # Keep backups overnight at a fixed time, rather than drifting or starting again at login.
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
    path = home / "Library/LaunchAgents" / (LABEL + ".plist")
    # An ordinary reinstall refreshes the script/schedule, not the private Drive
    # account or destination. Only explicitly supplied route options replace it.
    saved_config, saved_destination = saved_route(path)
    rclone_config = args.rclone_config if args.rclone_config is not None else saved_config
    destination = args.destination if args.destination is not None else saved_destination
    if rclone_config and not rclone_config.is_file():
        parser.error("Dedicated rclone configuration does not exist")
    contents = plistlib.dumps(configuration(home, script, rclone_config, destination))
    if not args.install:
        sys.stdout.buffer.write(contents)
        return
    os.umask(0o077)
    agents = home / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    logs = home / "Library/Logs/HelloChat"
    logs.mkdir(mode=0o700, parents=True, exist_ok=True)
    logs.chmod(0o700)
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
