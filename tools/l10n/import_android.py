#!/usr/bin/env python3
"""Builds the String Catalog of DELOS for Apple from the string resources of DELOS for Android.

    python3 tools/l10n/import_android.py /path/to/DELOS            # write the catalog
    python3 tools/l10n/import_android.py /path/to/DELOS --check    # exit 1 if the catalog is not up to date

The names listed in tools/l10n/keys.txt are looked up in app/src/main/res/values*/strings*.xml (strings and plurals)
of the Android checkout. The catalog keys are the Android names; Swift code reads them with `L("name")` (DelosUI).
Placeholders are converted to Apple's format (`%1$s` -> `%1$@`, `%s` -> `%@`; numbers stay), Android escapes are
resolved (`\\'`, `\\"`, `\\n`, `\\@`, `\\?`), and a plural becomes a variation by plural category. Every name must have an
English text; a missing translation is left out (the app shows English) and listed on standard error.
Standard library only. Tests: python3 -m unittest discover -s tools/l10n
"""
from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEYS = ROOT / "tools/l10n/keys.txt"
CATALOG = ROOT / "Packages/DelosKit/Sources/DelosUI/Resources/Localizable.xcstrings"
RES = "app/src/main/res"
# Android resource qualifier -> Apple language code
LANGUAGES = {"": "en", "cs": "cs", "de": "de", "es": "es", "fr": "fr", "ja": "ja", "ko": "ko",
             "pt-rBR": "pt-BR", "uk": "uk", "zh-rCN": "zh-Hans"}
PLACEHOLDER = re.compile(r"%(\d+\$)?([-#+ 0,(]*\d*(?:\.\d+)?)([a-zA-Z%])")


def convert_text(text: str) -> str:
    """An Android string resource's text as an Apple format string."""
    text = text.strip()
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    text = "".join(out)

    def placeholder(m: re.Match) -> str:
        position, flags, kind = m.group(1) or "", m.group(2), m.group(3)
        if kind == "%":
            return "%%"
        if kind == "s":
            kind = "@"
        return f"%{position}{flags}{kind}"

    return PLACEHOLDER.sub(placeholder, text)


def element_text(element: ET.Element) -> str:
    """The text of an element including inline markup such as <xliff:g> (markup itself is dropped)."""
    return "".join(element.itertext())


def read_resources(android: Path) -> dict[str, dict[str, object]]:
    """language -> name -> text (str) or plural (dict category -> text)."""
    result: dict[str, dict[str, object]] = {}
    for qualifier, language in LANGUAGES.items():
        folder = android / RES / ("values" if not qualifier else f"values-{qualifier}")
        entries: dict[str, object] = {}
        for file in sorted(folder.glob("strings*.xml")):
            for element in ET.parse(file).getroot():
                name = element.get("name")
                if not name or element.get("translatable") == "false" and qualifier:
                    continue
                if element.tag == "string":
                    entries[name] = convert_text(element_text(element))
                elif element.tag == "plurals":
                    entries[name] = {item.get("quantity"): convert_text(element_text(item)) for item in element}
        result[language] = entries
    return result


def unit(text: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": text}}


def build(android: Path, keys: list[str]) -> tuple[dict, list[str]]:
    resources = read_resources(android)
    strings: dict[str, dict] = {}
    problems: list[str] = []
    for key in keys:
        if key not in resources["en"]:
            raise SystemExit(f"import_android: '{key}' has no English text in {android / RES}/values")
        localizations = {}
        for language in LANGUAGES.values():
            value = resources[language].get(key)
            if value is None:
                problems.append(f"{key}: no {language} translation")
                continue
            if isinstance(value, dict):
                localizations[language] = {"variations": {"plural": {q: unit(t) for q, t in value.items()}}}
            else:
                localizations[language] = unit(value)
        strings[key] = {"extractionState": "manual", "localizations": localizations}
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}, problems


def read_keys() -> list[str]:
    return [line.strip() for line in KEYS.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")]


def render(catalog: dict) -> str:
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main(argv: list[str]) -> int:
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 2
    catalog, problems = build(Path(argv[0]), read_keys())
    for problem in problems:
        print(f"import_android: {problem}", file=sys.stderr)
    text = render(catalog)
    if "--check" in argv:
        if not CATALOG.exists() or CATALOG.read_text(encoding="utf-8") != text:
            print(f"import_android: {CATALOG.relative_to(ROOT)} is not up to date; run without --check", file=sys.stderr)
            return 1
        return 0
    CATALOG.write_text(text, encoding="utf-8")
    print(f"{CATALOG.relative_to(ROOT)}: {len(catalog['strings'])} strings")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
