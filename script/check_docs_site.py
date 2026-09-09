#!/usr/bin/env python3
"""Check built documentation links without network requests or dependencies."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import sys


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "name" in attrs:
            self.ids.add(attrs["name"])
        for key in ("href", "src"):
            if attrs.get(key):
                self.links.append(attrs[key])


def main():
    root = Path(sys.argv[1]).resolve()
    prefix = sys.argv[2].rstrip("/") if len(sys.argv) > 2 else ""
    pages = {p: Page(p) for p in root.rglob("*.html")}
    errors = []
    if root / "index.html" not in pages:
        errors.append("Missing index.html")
    count = 0
    for source, page in pages.items():
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            count += 1
            path = unquote(url.path)
            if path.startswith("/"):
                if prefix and not (path == prefix or path.startswith(prefix + "/")):
                    errors.append(f"{source.relative_to(root)}: outside site prefix: {link}")
                    continue
                target = root / path[len(prefix):].lstrip("/")
            else:
                target = source.parent / path if path else source
            target = target.resolve()
            if target.is_dir():
                target /= "index.html"
            if not target.is_relative_to(root) or not target.is_file():
                errors.append(f"{source.relative_to(root)}: missing target: {link}")
            elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
                errors.append(f"{source.relative_to(root)}: missing anchor: {link}")
    for error in errors:
        print(error)
    print(f"Checked {len(pages)} pages and {count} local links; {len(errors)} errors.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
