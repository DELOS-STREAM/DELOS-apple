#!/usr/bin/env python3
"""Builds the String Catalog of DELOS for Apple from the string resources of DELOS for Android.

    python3 tools/l10n/import_android.py /path/to/DELOS            # write the catalog
    python3 tools/l10n/import_android.py /path/to/DELOS --check    # exit 1 if the catalog is not up to date
    python3 tools/l10n/import_android.py /path/to/DELOS /path/to/android-worktree  # also strings of an unmerged Android branch

The names listed in tools/l10n/keys.txt are looked up in app/src/main/res/values*/strings*.xml (strings, plurals and
string arrays) of the Android checkout. The catalog keys are the Android names; item i of a string array is the name
`<array>_<i>`. Swift code reads them with `L("name")`, plurals with `LPlural("name", count)` (DelosUI).
Placeholders are converted to Apple's format (`%1$s` -> `%1$@`, `%s` -> `%@`; numbers stay), Android escapes are
resolved (`\\'`, `\\"`, `\\n`, `\\@`, `\\?`), and a plural becomes a variation by plural category (a substitution
when its forms do not show the number, which Apple's variations must). Every name must have an
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


def read_elements(root: ET.Element, translated: bool) -> dict[str, object]:
    """name -> text (str) or plural (dict category -> text) of one resource file; a string array gives one name per
    item (`<array>_<index>`). [translated]: a translation folder, where untranslatable names are skipped."""
    entries: dict[str, object] = {}
    for element in root:
        name = element.get("name")
        if not name or element.get("translatable") == "false" and translated:
            continue
        if element.tag == "string":
            entries[name] = convert_text(element_text(element))
        elif element.tag == "plurals":
            entries[name] = {item.get("quantity"): convert_text(element_text(item)) for item in element}
        elif element.tag == "string-array":
            for index, item in enumerate(element):
                entries[f"{name}_{index}"] = convert_text(element_text(item))
    return entries


def read_resources(android: Path) -> dict[str, dict[str, object]]:
    """language -> name -> text (str) or plural (dict category -> text). A name Android marks translatable="false" has
    its English text in every language, as Android shows it."""
    result: dict[str, dict[str, object]] = {}
    fixed: set[str] = set()
    for file in sorted((android / RES / "values").glob("strings*.xml")):
        fixed.update(e.get("name") for e in ET.parse(file).getroot() if e.get("translatable") == "false" and e.get("name"))
    for qualifier, language in LANGUAGES.items():
        folder = android / RES / ("values" if not qualifier else f"values-{qualifier}")
        entries: dict[str, object] = {}
        for file in sorted(folder.glob("strings*.xml")):
            entries.update(read_elements(ET.parse(file).getroot(), translated=bool(qualifier)))
        result[language] = entries
    for language, entries in result.items():
        if language != "en":
            entries.update({name: result["en"][name] for name in fixed if name in result["en"]})
    return result


# Plurals whose Android quantity is the second argument ("%1$d of %2$d covers" picks its form by %2$d). Apple picks a form
# by the first argument, so their first two placeholders swap numbers and Swift passes the quantity first.
QUANTITY_SECOND = ("artwork_count_of_", "artwork_filtered_has_", "filters_result_active", "shell_home_apps_filtered")
SWAP = re.compile(r"%([12])\$")
SHIFT = re.compile(r"%(\d+)\$")


def swap_quantity(forms: dict[str, str]) -> dict[str, str]:
    return {q: SWAP.sub(lambda m: "%" + ("2" if m.group(1) == "1" else "1") + "$", t) for q, t in forms.items()}


def unit(text: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": text}}


def plural(forms: dict[str, str]) -> dict:
    """A plural as a variation by plural category. Apple requires a plural variation to show its number; forms without
    one ("hour" / "hours", Android's getQuantityString for a unit beside a number) become a substitution that picks
    the form from the first argument and shows only the form. A form that shows texts ("%1$s Hours", the quantity an
    Android count apart from its text; "%1$s, %2$s log lines") takes them as the following arguments, after the count."""
    variations = {"plural": {q: unit(t) for q, t in forms.items()}}
    if any(PLACEHOLDER.search(t) for t in forms.values()):
        return {"variations": variations}
    variations = {"plural": {q: unit(SHIFT.sub(lambda m: f"%{int(m.group(1)) + 1}$", t)) for q, t in forms.items()}}
    return {"stringUnit": {"state": "translated", "value": "%#@count@"},
            "substitutions": {"count": {"argNum": 1, "formatSpecifier": "d", "variations": variations}}}


def build(android: Path, keys: list[str], extra: tuple[Path, ...] = ()) -> tuple[dict, list[str]]:
    resources = read_resources(android)
    # Strings that exist only on an Android feature branch (not merged yet) come from its worktree: they fill gaps only
    for root in extra:
        for language, entries in read_resources(root).items():
            for name, value in entries.items():
                resources[language].setdefault(name, value)
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
                if key.startswith(QUANTITY_SECOND):
                    value = swap_quantity(value)
                localizations[language] = plural(value)
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
    roots = [Path(a) for a in argv if not a.startswith("-")]
    catalog, problems = build(roots[0], read_keys(), tuple(roots[1:]))
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
