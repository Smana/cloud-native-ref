#!/usr/bin/env python3
# requires: python3
"""A pvc-unbound operations page, reachable the way every other operations
page is reachable: linked from the cards block on the operations index
(website/content/docs/operations/_index.md).

The check that pins navigation is structural, not prose: the index must hold
a card whose `link` resolves to the page, and the target page must exist with
front matter that renders it in the docs site. It never greps body text --
what the page says is for humans, and the task's own acceptance is that the
page exists and the site builds.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
INDEX = ROOT / "website/content/docs/operations/_index.md"
PAGE = ROOT / "website/content/docs/operations/pvc-unbound.md"

fails = 0


def check(desc: str, ok: bool) -> None:
    global fails
    print(f"  {'ok  ' if ok else 'FAIL'} {desc}")
    if not ok:
        fails += 1


check("website/content/docs/operations/pvc-unbound.md exists", PAGE.is_file())

if INDEX.is_file():
    text = INDEX.read_text()
    cards = re.findall(r"\{\{<\s*card\s+([^>]*)>\}\}", text)
    links = []
    for attrs in cards:
        m = re.search(r'link="([^"]+)"', attrs)
        if m:
            links.append(m.group(1))
    check(f"the operations index links it with a card like flux-health's "
          f"(cards: {links})", "pvc-unbound" in links)
else:
    check("the operations index exists", False)

if PAGE.is_file():
    source = PAGE.read_text()
    fm = re.match(r"^---\n(.*?)\n---\n", source, re.S)
    check("the page has front matter (Hugo page, not a bare file)", fm is not None)
    if fm:
        check("the front matter carries a title", "title:" in fm.group(1))
else:
    check("the page has front matter (Hugo page, not a bare file)", False)

print("all checks passed" if fails == 0 else "FAILURES above")
sys.exit(fails)
