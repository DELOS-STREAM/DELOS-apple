#!/usr/bin/env python3
"""Checks that every string the Swift code reads with L("name") is in the String Catalog with all ten languages.

    python3 tools/l10n/check_usage.py

Exit code 0: every used name is there; 1: a name is missing or lacks a language (one line each). Standard library only.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Packages/DelosKit/Sources"
CATALOG = ROOT / "Packages/DelosKit/Sources/DelosUI/Resources/Localizable.xcstrings"
LANGUAGES = {"en", "cs", "de", "es", "fr", "ja", "ko", "pt-BR", "uk", "zh-Hans"}
USE = re.compile(r'\bL\("([a-z0-9_]+)"')


def used_names(sources: Path) -> dict[str, str]:
    """name -> the first file:line that uses it."""
    names: dict[str, str] = {}
    for file in sorted(sources.rglob("*.swift")):
        for number, line in enumerate(file.read_text(encoding="utf-8").splitlines(), 1):
            for name in USE.findall(line):
                names.setdefault(name, f"{file.relative_to(ROOT)}:{number}")
    return names


def problems(names: dict[str, str], catalog: dict) -> list[str]:
    found = []
    strings = catalog.get("strings", {})
    for name, where in sorted(names.items()):
        entry = strings.get(name)
        if entry is None:
            found.append(f"{where}: '{name}' is not in the catalog; add it to tools/l10n/keys.txt and run import_android.py")
            continue
        missing = sorted(LANGUAGES - set(entry.get("localizations", {})))
        if missing:
            found.append(f"{where}: '{name}' has no {', '.join(missing)} text")
    return found


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    names = used_names(SOURCES)
    found = problems(names, catalog)
    for line in found:
        print(line)
    print(f"check_usage: {len(names)} names used, {len(found)} problem(s)", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
