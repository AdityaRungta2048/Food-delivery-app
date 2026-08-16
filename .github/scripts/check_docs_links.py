#!/usr/bin/env python3
"""
Cross-reference checker for the specification documents.

Every deliverable in this repository is Markdown that links to other Markdown,
so a renamed heading silently breaks navigation with no other symptom. This
verifies that each relative link resolves to a file that exists, and that each
`#fragment` matches a heading actually present in the target document.

External (http/https) links are not fetched -- that would make CI dependent on
the availability of third-party sites.

    python3 .github/scripts/check_docs_links.py
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$", re.MULTILINE)
FENCE_RE = re.compile(r"```.*?```", re.DOTALL)


def slugify(heading):
    """Approximate GitHub's heading-anchor algorithm."""
    text = heading.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text).strip("-")


def markdown_files():
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in sorted(filenames):
            if name.endswith(".md"):
                yield os.path.join(dirpath, name)


def main():
    files = list(markdown_files())
    if not files:
        print("No Markdown files found -- nothing to check.")
        return 0

    # Pre-compute the anchor set for every document.
    anchors = {}
    for path in files:
        body = open(path, encoding="utf-8").read()
        anchors[path] = {slugify(h) for h in HEADING_RE.findall(body)}

    failures = []
    checked = 0

    for path in files:
        rel = os.path.relpath(path, REPO_ROOT)
        # Strip fenced code blocks so wireframes and sample snippets are not
        # mistaken for real links.
        body = FENCE_RE.sub("", open(path, encoding="utf-8").read())

        for _text, link in LINK_RE.findall(body):
            link = link.strip()
            if link.startswith(("http://", "https://", "mailto:")):
                continue

            checked += 1
            file_part, _, fragment = link.partition("#")

            if file_part:
                target = os.path.normpath(os.path.join(os.path.dirname(path), file_part))
                if not os.path.exists(target):
                    failures.append(f"{rel}: broken file link -> {link}")
                    continue
            else:
                target = path  # same-document anchor

            if fragment and target.endswith(".md"):
                if fragment not in anchors.get(target, set()):
                    failures.append(f"{rel}: broken anchor -> {link}")

    for failure in failures:
        print(f"  FAIL  {failure}")

    print(
        f"\n  {checked - len(failures)}/{checked} relative links resolve "
        f"across {len(files)} document(s)"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
