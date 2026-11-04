#!/usr/bin/env python3
"""Reject altered Sparkle 2.10.1 tools before the signing Mac executes them."""
import hashlib
from pathlib import Path
import sys

expected = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
actual = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit('Sparkle 2.10.1 archive checksum does not match')
print('Sparkle 2.10.1 archive verified')
