#!/usr/bin/env python3
"""Generate website references, PNG assets and content-derived cache keys.

Run after editing README's command/settings tables or website assets. --check
runs without writes after generation in the Website workflow, so published
references cannot silently drift from README. The icon generator remains authoritative for art.
"""
import argparse
import hashlib
import html
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

def inline_markdown(text: str) -> str:
    """Render the small inline vocabulary used by the canonical reference tables."""
    pattern = re.compile(r"\[([^\]]+)\]\((https://[^\s)]+)\)|\*\*([^*]+)\*\*|`([^`]+)`")
    parts: list[str] = []
    end = 0
    for match in pattern.finditer(text):
        parts.append(html.escape(text[end:match.start()]))
        if match[1] is not None:
            parts.append(f'<a href="{html.escape(match[2], quote=True)}">{html.escape(match[1])}</a>')
        elif match[3] is not None:
            parts.append(f"<strong>{html.escape(match[3])}</strong>")
        else:
            parts.append(f"<code>{html.escape(match[4])}</code>")
        end = match.end()
    parts.append(html.escape(text[end:]))
    return "".join(parts)

def reference_table(readme: str, header: str) -> str:
    lines = readme.splitlines()
    if lines.count(header) != 1:
        raise ValueError(f"Expected one README table headed {header}")
    start = lines.index(header)
    if start + 1 >= len(lines) or not re.fullmatch(r"\|\s*-+\s*\|\s*-+\s*\|", lines[start + 1]):
        raise ValueError("README reference table has no valid divider")
    rows = []
    for line in lines[start:]:
        if not line.startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) != 2:
            raise ValueError("README reference tables require two columns")
        rows.append(cells)
    if len(rows) < 3:
        raise ValueError("README reference table is empty")
    heading = "".join(f'<th scope="col">{inline_markdown(cell)}</th>' for cell in rows[0])
    body = "\n".join("<tr>" + "".join(f"<td>{inline_markdown(cell)}</td>" for cell in row) + "</tr>" for row in rows[2:])
    return f'<div class="reference-scroll"><table class="reference-table"><thead><tr>{heading}</tr></thead><tbody>\n{body}\n</tbody></table></div>'

def main() -> None:
    root = Path(__file__).resolve().parent.parent
    docs = root / "docs"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check references and assets without writing files")
    args = parser.parse_args()
    if not args.check:
        with tempfile.TemporaryDirectory(prefix="hellochat-site-") as temp:
            subprocess.run(["swift", str(root / "scripts/make-icon.swift"), temp], check=True)
            icon = Path(temp) / "icon-512.png"
            shutil.copyfile(icon, docs / "app-icon.png")
            subprocess.run(["swift", str(root / "scripts/render-site-image.swift"), str(icon), str(docs / "og.png")], check=True)
    stale: list[str] = []
    references = {"commands": "| Say | What happens |", "settings": "| Section | Contents |"}
    readme = (root / "README.md").read_text()
    pattern = re.compile(r'(?P<base>(?:https://ethansk\.github\.io)?(?:/hello-chat/|\./))(?P<asset>[A-Za-z0-9_.-]+)\?v=[A-Za-z0-9]+')
    for source in [docs / "site.webmanifest", *docs.glob("*.html")]:
        text = source.read_text()
        updated = text
        if source.name == "index.html":
            for name, header in references.items():
                marker = re.compile(rf"(<!-- README:{name}:start -->)\n.*?\n(<!-- README:{name}:end -->)", re.DOTALL)
                if len(marker.findall(updated)) != 1:
                    raise ValueError(f"Expected one {name} reference block in index.html")
                updated = marker.sub(lambda match: match[1] + "\n" + reference_table(readme, header) + "\n" + match[2], updated)
        def replace(match: re.Match) -> str:
            digest = hashlib.sha256((docs / match["asset"]).read_bytes()).hexdigest()[:12]
            return f'{match["base"]}{match["asset"]}?v={digest}'
        updated = pattern.sub(replace, updated)
        if updated != text:
            stale.append(source.name)
            if not args.check:
                source.write_text(updated)
    if args.check and stale:
        raise SystemExit("Stale website content; run scripts/prepare-site.py:\n" + "\n".join(stale))
    print("Website references and assets are current." if args.check else "Website references, PNGs and cache keys generated.")


if __name__ == "__main__":
    main()
