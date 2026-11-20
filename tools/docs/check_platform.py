#!/usr/bin/env python3
"""Fails when the user-facing documents name the other platform (AGENTS.md, "Keep the platforms apart").

    python3 tools/docs/check_platform.py

CHANGELOG.md and README.md describe DELOS for Apple on its own; port notes belong in issues. Exit code 0: clean;
1: one `path:line: text` per offending line on standard output.

Standard library only. Tests: python3 -m unittest discover -s tools/docs
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCUMENTS = ("CHANGELOG.md", "README.md")
FORBIDDEN = re.compile(r"android", re.IGNORECASE)


def offences(text: str) -> list[tuple[int, str]]:
    """The 1-based line numbers and lines that name the other platform."""
    return [(number, line) for number, line in enumerate(text.splitlines(), 1) if FORBIDDEN.search(line)]


def main() -> int:
    found = False
    for name in DOCUMENTS:
        for number, line in offences((ROOT / name).read_text(encoding="utf-8")):
            print(f"{name}:{number}: {line.strip()}")
            found = True
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
