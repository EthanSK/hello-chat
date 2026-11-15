#!/usr/bin/env python3
"""Check README-to-website references without building assets or using the network.

Run directly or through scripts/test.sh. Malformed source must fail instead of
quietly publishing an empty reference, and Markdown text must stay escaped.
"""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("prepare_site", Path(__file__).with_name("prepare-site.py"))
assert spec is not None and spec.loader is not None
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


class ReferenceTests(unittest.TestCase):
    header = "| Say | What happens |"
    table = header + "\n| --- | --- |\n| **Open app** | Open `Code` or [help](https://example.com/?a=1&b=2) |\n"

    def test_complete_reference_keeps_format_and_link(self):
        result = site.reference_table(self.table, self.header)
        self.assertIn('<th scope="col">Say</th>', result)
        self.assertIn("<strong>Open app</strong>", result)
        self.assertIn("<code>Code</code>", result)
        self.assertIn('href="https://example.com/?a=1&amp;b=2"', result)

    def test_untrusted_markup_is_text(self):
        result = site.inline_markdown('<script>alert("x")</script> **<b>text</b>**')
        self.assertNotIn("<script>", result)
        self.assertIn("<strong>&lt;b&gt;text&lt;/b&gt;</strong>", result)

    def test_non_https_links_are_not_active(self):
        self.assertNotIn("href=", site.inline_markdown('[bad](javascript:alert)'))

    def test_missing_or_duplicate_table_fails(self):
        for text in ["", self.table + self.table]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                site.reference_table(text, self.header)

    def test_missing_divider_or_rows_fails(self):
        for text in [self.header, self.header + "\n| --- | --- |\n", self.header + "\n| bad | divider |\n| a | b |"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                site.reference_table(text, self.header)

    def test_extra_columns_fail(self):
        with self.assertRaises(ValueError):
            site.reference_table(self.table + "| a | b | c |\n", self.header)


if __name__ == "__main__":
    unittest.main()
