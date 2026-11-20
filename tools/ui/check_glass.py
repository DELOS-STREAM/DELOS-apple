#!/usr/bin/env python3
"""Fails when an interface surface has a translucent fill without Liquid Glass (docs/ARCHITECTURE.md, "Glass").

    python3 tools/ui/check_glass.py

Every semi-transparent surface (panel, pill, chip, card overlay, dialog, menu, info box, sheet, popover) is glass:
`GlassShape` or `CaretCardGlass` in Packages/DelosKit/Sources/DelosUI. A line is flagged when it fills a shape, sets a
background or is a bare color view, and the color is translucent: `.opacity(...)`, an `opacity:` component, a system
material, or a translucent token (`surface`, `surface2`, `surface3`, `scrim`). Lines with glass, gradients, strokes or a
blurred shadow copy (`.blur(radius:`) are not flagged.

What stays a flat translucent fill on purpose (scrims, focus plates, tracks of sliders and progress bars, tints inside a
glass surface, where a blur in a blur is not wanted) is listed in tools/ui/glass_allowlist.txt as
`File.swift | text of the line | reason`; an entry matches the lines of that file that contain the text. An entry that
matches nothing is reported too, so the list stays honest.

Exit code 0: clean; 1: one `path:line: text` per offending line (and `allowlist: …` per stale entry) on standard output.

Standard library only. Tests: python3 -m unittest discover -s tools/ui
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Packages/DelosKit/Sources/DelosUI"
ALLOWLIST = Path(__file__).with_name("glass_allowlist.txt")

SURFACE = re.compile(r"\.fill\(|\.background\(|^\s*(Color\.|Color\(|colors\.)")
TRANSLUCENT = re.compile(
    r"\.opacity\(|opacity:|Material\b|colors\.(surface[23]?|scrim)\b|\b(surface[23]?|scrim)\.color\b|RGBA\([^)]*alpha:")
EXEMPT = re.compile(r"GlassShape\(|CaretCardGlass\(|Gradient\b|stroke|\.blur\(radius:")


def candidates(text: str) -> list[tuple[int, str]]:
    """The 1-based line numbers and lines of [text] that fill a surface with a translucent color and no glass."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("//", 1)[0]
        if not code.strip() or code.lstrip().startswith("///"):
            continue
        if SURFACE.search(code) and TRANSLUCENT.search(code) and not EXEMPT.search(code):
            found.append((number, line))
    return found


def parse_allowlist(text: str) -> list[tuple[str, str]]:
    """The (file, text) pairs of the allowlist; blank lines and `#` comments are skipped, every entry needs a reason."""
    entries = []
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = [part.strip() for part in raw.split(" | ")]
        if len(parts) != 3 or not all(parts):
            raise ValueError(f"glass_allowlist.txt:{number}: expected `File.swift | text | reason`")
        entries.append((parts[0], parts[1]))
    return entries


def offences(files: dict[str, str], allowed: list[tuple[str, str]]) -> tuple[list[str], list[tuple[str, str]]]:
    """The flagged `name:line: text` strings that no entry allows, and the entries that allow nothing."""
    used: set[tuple[str, str]] = set()
    flagged = []
    for name in sorted(files):
        for number, line in candidates(files[name]):
            match = [entry for entry in allowed if entry[0] == name and entry[1] in line]
            used.update(match)
            if not match:
                flagged.append(f"{name}:{number}: {line.strip()}")
    return flagged, [entry for entry in allowed if entry not in used]


def main() -> int:
    files = {path.name: path.read_text(encoding="utf-8") for path in SOURCES.glob("*.swift")}
    flagged, stale = offences(files, parse_allowlist(ALLOWLIST.read_text(encoding="utf-8")))
    for line in flagged:
        print(line)
    for name, text in stale:
        print(f"allowlist: {name} | {text} matches nothing")
    return 1 if flagged or stale else 0


if __name__ == "__main__":
    sys.exit(main())
