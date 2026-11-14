#!/usr/bin/env python3
"""Model packaging failures must recover without accepting unpinned bytes."""
import contextlib
import hashlib
import http.client
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


spec = importlib.util.spec_from_file_location('fetch_models', Path(__file__).with_name('fetch-speech-models.py'))
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)
GOOD = b'pinned model fixture'
DIGEST = hashlib.sha256(GOOD).hexdigest()
MANIFEST = {'repository': 'owner/model', 'revision': 'a' * 40, 'subdirectory': 'variant',
            'files': {'encoder/weight.bin': DIGEST}}


class Response(io.BytesIO):
    def __init__(self, content=GOOD, length='automatic'):
        super().__init__(content)
        self.headers = {} if length is None else {'Content-Length': str(len(content)) if length == 'automatic' else length}


class InterruptedResponse(Response):
    def read(self, size=-1):
        raise http.client.IncompleteRead(b'partial', len(GOOD))


class Downloads(unittest.TestCase):
    def run_fetch(self, root, responses):
        with patch.object(models.urllib.request, 'urlopen', side_effect=responses) as request, contextlib.redirect_stderr(io.StringIO()):
            models.fetch(MANIFEST, root)
        return request

    def test_complete_pinned_transfer_and_existing_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            request = self.run_fetch(root, [Response()])
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)
            self.assertEqual(request.call_count, 1)
            request = self.run_fetch(root, [])
            request.assert_not_called()
            self.assertFalse(list(root.rglob('*.download')))

    def test_corrupt_same_length_transfer_retries_the_same_pin(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            request = self.run_fetch(root, [Response(b'x' * len(GOOD)), Response()])
            self.assertEqual(request.call_count, 2)
            self.assertEqual(request.call_args_list[0], request.call_args_list[1])
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)

    def test_truncated_declared_length_cannot_pass_even_with_matching_hash(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            request = self.run_fetch(root, [Response(length=str(len(GOOD) + 1)), Response()])
            self.assertEqual(request.call_count, 2)
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)

    def test_transfer_interruptions_and_transient_http_errors_recover(self):
        for first in [InterruptedResponse(), urllib.error.URLError('offline'), TimeoutError('timeout'),
                      urllib.error.HTTPError('https://example.test', 503, 'Unavailable', {}, None)]:
            with self.subTest(failure=type(first).__name__), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                request = self.run_fetch(root, [first, Response()])
                self.assertEqual(request.call_count, 2)
                self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)
                self.assertFalse(list(root.rglob('*.download')))

    def test_permanent_http_failure_is_not_retried(self):
        for code in [403, 404, 429]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temp:
                error = urllib.error.HTTPError('https://example.test', code, 'Rejected', {}, None)
                with patch.object(models.urllib.request, 'urlopen', side_effect=error) as request:
                    with self.assertRaises(urllib.error.HTTPError): models.fetch(MANIFEST, Path(temp))
                self.assertEqual(request.call_count, 1)
                self.assertFalse(list(Path(temp).rglob('*.download')))

    def test_server_requested_wait_is_not_bypassed_with_an_immediate_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            error = urllib.error.HTTPError('https://example.test', 503, 'Wait', {'Retry-After': '60'}, None)
            with patch.object(models.urllib.request, 'urlopen', side_effect=error) as request:
                with self.assertRaises(urllib.error.HTTPError): models.fetch(MANIFEST, Path(temp))
            self.assertEqual(request.call_count, 1)

    def test_repeated_corruption_stops_and_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); target = root / 'encoder/weight.bin'
            target.parent.mkdir(); target.write_bytes(b'previous invalid cache')
            with patch.object(models.urllib.request, 'urlopen', side_effect=[Response(b'wrong') for _ in range(3)]) as request, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit): models.fetch(MANIFEST, root)
            self.assertEqual(request.call_count, 3)
            self.assertEqual(target.read_bytes(), b'previous invalid cache')
            self.assertFalse(list(root.rglob('*.download')))

    def test_missing_length_still_requires_exact_checksum(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            request = self.run_fetch(root, [Response(b'wrong', length=None), Response(length=None)])
            self.assertEqual(request.call_count, 2)
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)

    def test_disk_failure_is_not_retried_or_published(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(models.urllib.request, 'urlopen', return_value=Response()) as request, patch.object(Path, 'replace', side_effect=PermissionError('fixture')), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(PermissionError): models.fetch(MANIFEST, root)
            self.assertEqual(request.call_count, 1)
            self.assertFalse((root / 'encoder/weight.bin').exists())
            self.assertFalse(list(root.rglob('*.download')))


if __name__ == '__main__':
    unittest.main()
