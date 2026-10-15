#!/usr/bin/env python3
"""Check the rendered landing page, documentation mount, and internal links."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

WWW = Path(__file__).resolve().parents[1]
DIST = WWW / "dist"
ORIGIN = "https://built-site.invalid"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if "id" in attributes:
            self.ids.add(attributes["id"])
        if tag in {"a", "use"} and attributes.get("href"):
            self.links.append(attributes["href"])
        if tag in {"script", "img"} and attributes.get("src"):
            self.links.append(attributes["src"])
        if tag == "link" and attributes.get("rel") == "stylesheet":
            self.links.append(attributes["href"])
        if attributes.get("data-nav-src"):
            self.links.append(attributes["data-nav-src"])


def main():
    landing = WWW / "index.html"
    assert (DIST / "index.html").read_text().strip() == landing.read_text().strip(), (
        "The build must serve www/index.html unchanged at /."
    )
    assert (DIST / "docs/index.html").is_file(), "Missing /docs overview."

    pages = {}
    for path in DIST.rglob("index.html"):
        if path.relative_to(DIST).parts[0] == "blume-nav":
            continue  # Partial navigation fragments use their containing page's SVG IDs.
        route = "/" if path.parent == DIST else "/" + path.parent.relative_to(DIST).as_posix()
        assert route == "/" or route == "/docs" or route.startswith("/docs/"), (
            f"Documentation escaped its /docs mount: {route}"
        )
        pages[route] = Page(path)

    # Check every generated content page, rather than just representative routes.
    for source in (WWW / "content").rglob("*.md"):
        path = source.relative_to(WWW / "content").with_suffix("")
        if path.name == "index":
            path = path.parent
        route = "/docs" + ("/" + path.as_posix() if path.as_posix() != "." else "")
        assert route in pages, f"Missing published page: {route}"

    checked = 0
    for route, page in pages.items():
        for href in page.links:
            target = urlsplit(urljoin(ORIGIN + route, href))
            if target.netloc != "built-site.invalid" or target.scheme not in {"http", "https"}:
                continue
            path = unquote(target.path).rstrip("/") or "/"
            if path in pages:
                if target.fragment:
                    assert unquote(target.fragment) in pages[path].ids, (
                        f"Broken anchor on {route}: {href}"
                    )
            else:
                asset = DIST / path.lstrip("/")
                assert asset.is_file() or (asset / "index.html").is_file(), (
                    f"Broken internal link on {route}: {href}"
                )
            checked += 1

    assert "/docs" in pages["/"].links, "The landing page must link to documentation."
    assert "/" in pages["/docs"].links, "Documentation must link back to the landing page."
    print(f"Built site: landing + {len(pages) - 1} docs; {checked} internal links/assets checked.")


if __name__ == "__main__":
    main()
