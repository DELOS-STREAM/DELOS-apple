#!/usr/bin/env python3
"""Checks the String Catalogs of DELOS for Apple: every string the Swift code reads with L("name") or LPlural("name", count)
is in the package's catalog, every entry of it and of the app's Info.plist catalog has all ten languages, and no text
names DELOS for Android's platform (Android, Snapdragon, SGSR, MediaCodec, Vulkan): Apple texts use the neutral strings.

    python3 tools/l10n/check_usage.py

Exit code 0: all hold; 1: a problem (one line each). Standard library only.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Packages/DelosKit/Sources"
CATALOG = ROOT / "Packages/DelosKit/Sources/DelosUI/Resources/Localizable.xcstrings"
INFO_PLIST = ROOT / "App/Shared/InfoPlist.xcstrings"
LANGUAGES = {"en", "cs", "de", "es", "fr", "ja", "ko", "pt-BR", "uk", "zh-Hans"}
USE = re.compile(r'\bL(?:Plural)?\("([a-z0-9_]+)"')
ANDROID_ONLY = re.compile(r"Android|Snapdragon|SGSR|MediaCodec|Vulkan|Adreno|Qualcomm", re.IGNORECASE)


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


def incomplete(catalog: dict, file: str) -> list[str]:
    """Every entry of [catalog] that lacks a language."""
    found = []
    for name, entry in sorted(catalog.get("strings", {}).items()):
        missing = sorted(LANGUAGES - set(entry.get("localizations", {})))
        if missing:
            found.append(f"{file}: '{name}' has no {', '.join(missing)} text")
    return found


def texts(node: object) -> list[str]:
    """Every text of a catalog entry: its string units, its plural and substitution variations."""
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        own = [unit["value"]] if isinstance(unit, dict) and "value" in unit else []
        return own + [text for key, value in node.items() if key != "stringUnit" for text in texts(value)]
    return []


def android_only(catalog: dict, file: str) -> list[str]:
    """Every entry of [catalog] whose text in some language names DELOS for Android's platform."""
    found = []
    for name, entry in sorted(catalog.get("strings", {}).items()):
        for language, localization in sorted(entry.get("localizations", {}).items()):
            words = sorted({m.group(0) for text in texts(localization) for m in ANDROID_ONLY.finditer(text)})
            if words:
                found.append(f"{file}: '{name}' ({language}) names {', '.join(words)}; use a platform-neutral string")
    return found


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    info = json.loads(INFO_PLIST.read_text(encoding="utf-8"))
    names = used_names(SOURCES)
    found = problems(names, catalog)
    for file, entries in ((CATALOG, catalog), (INFO_PLIST, info)):
        where = str(file.relative_to(ROOT))
        found += incomplete(entries, where) + android_only(entries, where)
    for line in found:
        print(line)
    print(f"check_usage: {len(names)} names used, {len(found)} problem(s)", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
