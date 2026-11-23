#!/usr/bin/env python3
"""Derive in-app repeat guidance from README, the website's existing original. — GPT-6.1 Sol"""
import argparse
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
rows = [line for line in (root / 'README.md').read_text().splitlines() if line.startswith('| **Zoom in three times**, **Zoom in 3** |')]
if len(rows) != 1:
    raise SystemExit('Expected one canonical repeat-count guidance row in README')
example, body = [cell.strip().replace('**', '') for cell in rows[0].strip('|').split('|')]
text = json.dumps({'examples': example, 'body': body}, ensure_ascii=False, indent=2) + '\n'
output = root / 'Resources/CommandRepetitionHelp.json'
if args.check:
    if not output.exists() or output.read_text() != text:
        raise SystemExit('Stale app guidance; run scripts/prepare-command-help.py')
else:
    output.write_text(text)
print('App repeat guidance matches README')
