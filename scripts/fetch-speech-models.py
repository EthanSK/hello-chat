#!/usr/bin/env python3
"""Reproduce pinned model assets during packaging, never microphone capture."""
import argparse
import hashlib
import json
import pathlib
import urllib.request


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(manifest, destination):
    base = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{manifest['subdirectory']}"
    for relative, digest in manifest['files'].items():
        target = destination / relative
        if target.exists() and checksum(target) == digest:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + '.download')
        with urllib.request.urlopen(base + '/' + relative, timeout=120) as response, temporary.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        if checksum(temporary) != digest:
            temporary.unlink()
            raise SystemExit(f'Model checksum failed: {relative}')
        temporary.replace(target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    manifest = json.loads((pathlib.Path(__file__).resolve().parents[1] / 'Resources/SpeechModels.json').read_text())
    fetch(manifest, args.output)
    for name, variant in manifest.get('variants', {}).items():
        fetch(variant, args.output / name)
    print('Verified pinned local speech model files.')
