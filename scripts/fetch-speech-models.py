#!/usr/bin/env python3
"""Reproduce pinned model assets during packaging, never microphone capture."""
import argparse
import hashlib
import http.client
import json
import pathlib
import re
import ssl
import sys
import urllib.error
import urllib.request

MAX_DOWNLOAD_ATTEMPTS = 3
DOWNLOAD_CHUNK_BYTES = 64 * 1024 * 1024


class ModelDownloadError(Exception):
    pass


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def transfer(url, temporary, label, progress):
    # Long model responses were truncated with a correct prefix. HTTP ranges
    # bound each real transfer; matching offsets/lengths and the final file hash
    # remain mandatory. Never append a server's ignored or out-of-order range.
    offset, total = progress['offset'], progress['total']
    with temporary.open('r+b' if temporary.exists() else 'wb') as output:
        # Keep only complete ranges checked during this invocation. A failed
        # later range must not throw away hundreds of MB already received.
        output.seek(offset)
        output.truncate()
        while True:
            requested_end = offset + DOWNLOAD_CHUNK_BYTES - 1
            request = urllib.request.Request(url, headers={'Range': f'bytes={offset}-{requested_end}'})
            with urllib.request.urlopen(request, timeout=120) as response:
                length = response.headers.get('Content-Length')
                if length is not None and not length.isdecimal():
                    raise ModelDownloadError('invalid response length')
                declared = int(length) if length is not None else None
                if response.status == 206:
                    value = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                    if not value:
                        raise ModelDownloadError('missing or invalid Content-Range')
                    start, end, size = map(int, value.groups())
                    if start != offset or size <= offset or end != min(requested_end, size - 1) or (total is not None and size != total):
                        raise ModelDownloadError('range offset or total mismatch')
                    total, expected = size, end - start + 1
                    if declared is not None and declared != expected:
                        raise ModelDownloadError('range length mismatch')
                elif response.status == 200 and offset == 0:
                    # Small files may ignore Range. Large files must honor it.
                    if declared is not None and declared > DOWNLOAD_CHUNK_BYTES:
                        raise ModelDownloadError('server ignored a required range')
                    expected = declared
                else:
                    raise ModelDownloadError('server ignored or rejected a continuation range')
                received = 0
                while chunk := response.read(1024 * 1024):
                    received += len(chunk)
                    if received > DOWNLOAD_CHUNK_BYTES or (expected is not None and received > expected):
                        raise ModelDownloadError('response exceeded the requested range')
                    output.write(chunk)
                if expected is not None and received != expected:
                    raise ModelDownloadError(f'response length mismatch (received {received}, expected {expected})')
                offset += received
                progress.update(offset=offset, total=total)
                if total is not None and total > DOWNLOAD_CHUNK_BYTES:
                    print(f'Model download {label}: {offset}/{total} bytes.', flush=True)
                if response.status == 200 or offset == total:
                    return


def download(url, target, digest, label):
    temporary = target.with_suffix(target.suffix + '.download')
    progress = {'offset': 0, 'total': None}
    # A release download may end early without read(size) raising. Retry only
    # failed transfers/validation, retaining the exact pin and atomic publish.
    # No extra settling delay, authentication retry or model/runtime change.
    try:
        for attempt in range(1, MAX_DOWNLOAD_ATTEMPTS + 1):
            try:
                transfer(url, temporary, label, progress)
                if checksum(temporary) != digest:
                    progress = {'offset': 0, 'total': None}
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
            reason = str(failure) if isinstance(failure, ModelDownloadError) else type(failure).__name__
            if attempt == MAX_DOWNLOAD_ATTEMPTS:
                raise SystemExit(f'Model download failed after {attempt} attempts: {label} ({reason})') from failure
            print(f'Model download failed ({reason}); retrying {label} ({attempt}/{MAX_DOWNLOAD_ATTEMPTS}).', file=sys.stderr)
    finally:
        temporary.unlink(missing_ok=True)


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
