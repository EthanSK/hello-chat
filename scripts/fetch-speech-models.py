#!/usr/bin/env python3
"""Reproduce pinned model assets during packaging, never microphone capture."""
import argparse
import hashlib
import http.client
import json
import pathlib
import ssl
import sys
import urllib.error
import urllib.request

MAX_DOWNLOAD_ATTEMPTS = 3


class ModelDownloadError(Exception):
    pass


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, target, digest, label):
    temporary = target.with_suffix(target.suffix + '.download')
    # A release download may end early without read(size) raising. Retry only
    # failed transfers/validation, retaining the exact pin and atomic publish.
    # No extra settling delay, authentication retry or model/runtime change.
    for attempt in range(1, MAX_DOWNLOAD_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as output:
                length = response.headers.get('Content-Length')
                received = 0
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    received += len(chunk)
            if length is not None and (not length.isdecimal() or received != int(length)):
                raise ModelDownloadError('response length mismatch')
            if checksum(temporary) != digest:
                raise ModelDownloadError('checksum mismatch')
            temporary.replace(target)
            return
        except urllib.error.HTTPError as error:
            error.close()
            if error.code not in {408, 500, 502, 503, 504} or (error.headers or {}).get('Retry-After'):
                raise
            failure = error
        except (urllib.error.URLError, TimeoutError, ConnectionError,
                http.client.IncompleteRead, ssl.SSLError, ModelDownloadError) as error:
            failure = error
        finally:
            temporary.unlink(missing_ok=True)
        reason = str(failure) if isinstance(failure, ModelDownloadError) else type(failure).__name__
        if attempt == MAX_DOWNLOAD_ATTEMPTS:
            raise SystemExit(f'Model download failed after {attempt} attempts: {label} ({reason})') from failure
        print(f'Model download failed ({reason}); retrying {label} ({attempt}/{MAX_DOWNLOAD_ATTEMPTS}).', file=sys.stderr)


def fetch(manifest, destination):
    base = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{manifest['subdirectory']}"
    for relative, digest in manifest['files'].items():
        target = destination / relative
        if target.exists() and checksum(target) == digest:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        download(base + '/' + relative, target, digest, f"{manifest['repository']}/{manifest['subdirectory']}/{relative}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    manifest = json.loads((pathlib.Path(__file__).resolve().parents[1] / 'Resources/SpeechModels.json').read_text())
    fetch(manifest, args.output)
    for name, variant in manifest.get('variants', {}).items():
        fetch(variant, args.output / name)
    print('Verified pinned local speech model files.')
