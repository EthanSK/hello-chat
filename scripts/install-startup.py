#!/usr/bin/env python3
"""Register the installed app for login and abnormal-exit recovery."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import uuid


def configuration(executable, logs):
    return {
        "Label": "com.ethansk.hello-chat",
        "ProgramArguments": [str(executable)],
        "RunAtLoad": True,
        # An explicit Quit remains possible; crashes are restarted by launchd.
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 30,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "app.stdout.log"),
        "StandardErrorPath": str(logs / "app.stderr.log"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    executable = Path("/Applications/HelloChat.app/Contents/MacOS/HelloChat")
    logs = Path.home() / "Library/Logs/HelloChat"
    payload = plistlib.dumps(configuration(executable, logs))
    if args.dry_run:
        print(payload.decode())
        return
    # Validate all paths and configurations before changing either startup job.
    if not executable.is_file():
        raise SystemExit("Installed HelloChat executable is missing")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(executable.parents[2])], check=True)
    agents = Path.home() / "Library/LaunchAgents"
    target = agents / "com.ethansk.hello-chat.plist"
    if target.exists() and target.read_bytes() != payload:
        raise SystemExit("Existing startup configuration differs; inspect before replacing")
    domain = f"gui/{os.getuid()}"
    job = f"{domain}/com.ethansk.hello-chat"
    loaded = subprocess.run(["launchctl", "print", job], capture_output=True)
    if loaded.returncode != 0:
        running = subprocess.run(["pgrep", "-fx", str(executable)], capture_output=True)
        if running.returncode == 0:
            raise SystemExit("HelloChat is already running outside launchd; finish the safe update before registering startup")
    # Previously com.ethansk.hey-chat. Preserve its plist; never quit an app here.
    legacy = agents / "com.ethansk.hey-chat.plist"
    if legacy.exists():
        old = plistlib.loads(legacy.read_bytes())
        expected = "/Applications/Hey Chat.app/Contents/MacOS/HeyChat"
        if old.get("Label") != "com.ethansk.hey-chat" or old.get("ProgramArguments") != [expected]:
            raise SystemExit("Legacy startup configuration differs; inspect before replacing")
        if subprocess.run(["pgrep", "-fx", expected], capture_output=True).returncode == 0:
            raise SystemExit("Quit Hey Chat before installing HelloChat startup")
    registrar = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
    subprocess.run([str(registrar), "-f", str(executable.parents[2])], check=True)
    if legacy.exists():
        oldjob = f"{domain}/com.ethansk.hey-chat"
        if subprocess.run(["launchctl", "print", oldjob], capture_output=True).returncode == 0:
            subprocess.run(["launchctl", "bootout", oldjob], check=True)
        legacy.rename(legacy.with_name(legacy.name + ".disabled-" + uuid.uuid4().hex[:8]))
    agents.mkdir(exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    target.chmod(0o600)
    if loaded.returncode != 0:
        subprocess.run(["launchctl", "bootstrap", domain, str(target)], check=True)
    print(target)


if __name__ == "__main__":
    main()
