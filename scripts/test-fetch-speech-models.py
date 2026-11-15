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
    def __init__(self, content=GOOD, length='automatic', status=200, content_range=None):
        super().__init__(content)
        self.status = status
        self.headers = {} if length is None else {'Content-Length': str(len(content)) if length == 'automatic' else length}
        if content_range is not None: self.headers['Content-Range'] = content_range


class InterruptedResponse(Response):
    def read(self, size=-1):
        raise http.client.IncompleteRead(b'partial', len(GOOD))


class Downloads(unittest.TestCase):
    def run_fetch(self, root, responses):
        with patch.object(models.urllib.request, 'urlopen', side_effect=responses) as request, contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
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
            requests = [call.args[0] for call in request.call_args_list]
            self.assertEqual(requests[0].full_url, requests[1].full_url)
            self.assertEqual(requests[0].get_header('Range'), requests[1].get_header('Range'))
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

    def test_large_file_assembles_exact_bounded_ranges_before_hashing(self):
        ranges = []
        def response(request, **_):
            start, end = map(int, request.get_header('Range').removeprefix('bytes=').split('-'))
            end = min(end, len(GOOD) - 1); ranges.append((start, end))
            return Response(GOOD[start:end + 1], status=206, content_range=f'bytes {start}-{end}/{len(GOOD)}')
        with tempfile.TemporaryDirectory() as temp, patch.object(models, 'DOWNLOAD_CHUNK_BYTES', 4):
            root = Path(temp); self.run_fetch(root, response)
            self.assertEqual(ranges, [(0, 3), (4, 7), (8, 11), (12, 15), (16, len(GOOD) - 1)])
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)

    def test_ignored_large_range_and_wrong_offsets_never_publish(self):
        for response in [lambda: Response(), lambda: Response(GOOD[:4], status=206, content_range=f'bytes 1-4/{len(GOOD)}'),
                         lambda: Response(GOOD[:4], status=206, content_range='bytes 0-3/*')]:
            with self.subTest(response=response), tempfile.TemporaryDirectory() as temp, patch.object(models, 'DOWNLOAD_CHUNK_BYTES', 4):
                root = Path(temp)
                with patch.object(models.urllib.request, 'urlopen', side_effect=[response() for _ in range(3)]) as request, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit): models.fetch(MANIFEST, root)
                self.assertEqual(request.call_count, 3)
                self.assertFalse((root / 'encoder/weight.bin').exists())
                self.assertFalse(list(root.rglob('*.download')))

    def test_changed_total_and_ignored_continuation_never_mix_files(self):
        for second in [lambda: Response(GOOD[4:8], status=206, content_range=f'bytes 4-7/{len(GOOD) + 1}'), lambda: Response(GOOD[4:8])]:
            with self.subTest(second=second), tempfile.TemporaryDirectory() as temp, patch.object(models, 'DOWNLOAD_CHUNK_BYTES', 4):
                root = Path(temp)
                def response(request, **_):
                    if request.get_header('Range').startswith('bytes=0-'):
                        return Response(GOOD[:4], status=206, content_range=f'bytes 0-3/{len(GOOD)}')
                    return second()
                with patch.object(models.urllib.request, 'urlopen', side_effect=response) as request, contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit): models.fetch(MANIFEST, root)
                self.assertEqual(request.call_count, 4)
                self.assertFalse((root / 'encoder/weight.bin').exists())
                self.assertFalse(list(root.rglob('*.download')))

    def test_truncated_range_restarts_without_appending_a_partial_piece(self):
        requested = []
        def response(request, **_):
            start, end = map(int, request.get_header('Range').removeprefix('bytes=').split('-'))
            end = min(end, len(GOOD) - 1); requested.append(start)
            data = GOOD[start:end + 1] if len(requested) > 1 else GOOD[:2]
            return Response(data, length=str(end - start + 1), status=206, content_range=f'bytes {start}-{end}/{len(GOOD)}')
        with tempfile.TemporaryDirectory() as temp, patch.object(models, 'DOWNLOAD_CHUNK_BYTES', 4):
            root = Path(temp); self.run_fetch(root, response)
            self.assertEqual(requested[:2], [0, 0])
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)

    def test_correct_range_headers_cannot_bypass_the_whole_file_hash(self):
        def response(request, **_):
            start, end = map(int, request.get_header('Range').removeprefix('bytes=').split('-'))
            end = min(end, len(GOOD) - 1); data = bytearray(GOOD[start:end + 1])
            if end == len(GOOD) - 1: data[-1] ^= 1
            return Response(bytes(data), status=206, content_range=f'bytes {start}-{end}/{len(GOOD)}')
        with tempfile.TemporaryDirectory() as temp, patch.object(models, 'DOWNLOAD_CHUNK_BYTES', 4):
            root = Path(temp)
            with patch.object(models.urllib.request, 'urlopen', side_effect=response) as request, contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit): models.fetch(MANIFEST, root)
            self.assertEqual(request.call_count, 15)
            self.assertFalse((root / 'encoder/weight.bin').exists())
            self.assertFalse(list(root.rglob('*.download')))

    def test_later_truncation_retries_that_range_without_redownloading_good_ranges(self):
        requested, failed = [], False
        def response(request, **_):
            nonlocal failed
            start, end = map(int, request.get_header('Range').removeprefix('bytes=').split('-'))
            end = min(end, len(GOOD) - 1); requested.append(start)
            data = GOOD[start:end + 1]
            if start == 4 and not failed: failed = True; data = data[:2]
            return Response(data, length=str(end - start + 1), status=206, content_range=f'bytes {start}-{end}/{len(GOOD)}')
        with tempfile.TemporaryDirectory() as temp, patch.object(models, 'DOWNLOAD_CHUNK_BYTES', 4):
            root = Path(temp); self.run_fetch(root, response)
            self.assertEqual(requested, [0, 4, 4, 8, 12, 16])
            self.assertEqual((root / 'encoder/weight.bin').read_bytes(), GOOD)


if __name__ == '__main__':
    unittest.main()
