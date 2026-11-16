#!/usr/bin/env python3
"""Checks the relative links and anchors of the tracked Markdown files, and the structure of the living specifications.

    python3 tools/docs/check_links.py            # every tracked *.md of the repository
    python3 tools/docs/check_links.py README.md  # only the named files (paths relative to the repository root)

A link is broken when its target is not a tracked file or directory of the repository, or when its `#anchor` is not
a heading (or an explicit `id` / `name`) of the target document. Links to other sites (`https:`, `mailto:`, ...) are
not fetched. Text inside code spans and code blocks is not read. Exit code 0: nothing broken; 1: broken links (one
line each on standard output); 2: the repository could not be read.

Structure (warnings only, they never change the exit code): every document listed under "Living specifications" in
docs/README.md has the headings `## Purpose` and `## Verification`, and `### Not verified` under the latter
(docs/ENGINEERING_RULES.md, "Documentation style").

Standard library only. Tests: python3 -m unittest discover -s tools/docs
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path, PurePosixPath

# Third-party documents that are vendored with their source and are not ours to fix.
VENDORED = ("app/src/main/jni/pyrowave/", "app/src/main/jni/moonlight-core/moonlight-common-c/")

# The index that names the living specifications, the heading of that list, and what each of them must contain.
INDEX = "docs/README.md"
LIVING_HEADING = "Living specifications"
REQUIRED_SECTIONS = ((2, "Purpose"), (2, "Verification"), (3, "Not verified"))

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(`+)(?!`).*?(?<!`)\1(?!`)")
INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(<[^>]*>|[^)\s]*)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
REFERENCE_DEFINITION = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
HTML_ATTRIBUTE = re.compile(r"\b(?:href|src|srcset)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')", re.IGNORECASE)
HTML_ANCHOR = re.compile(r"<[a-zA-Z][^>]*\b(?:id|name)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')", re.IGNORECASE)
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def slug(heading: str) -> str:
    """The anchor GitHub gives a heading: lower case, formatting removed, spaces to hyphens, punctuation dropped."""
    text = re.sub(r"!?\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\([^)]*\)", r"\1", heading)  # a link keeps its text
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("`", "")
    text = re.sub(r"(\*\*|__)(.+?)\1", r"\2", text)
    text = re.sub(r"(?<!\w)([*_])(.+?)\1(?!\w)", r"\2", text)
    out = []
    for char in text.strip().lower():
        if char.isalnum() or char in "_-":
            out.append(char)
        elif char == " ":
            out.append("-")
    return "".join(out)


def readable_lines(text: str):
    """(line number, line) of everything that is not inside a fenced code block, with code spans blanked."""
    fence = None
    for number, line in enumerate(text.split("\n"), 1):
        match = FENCE.match(line)
        if fence is None:
            if match:
                fence = match.group(1)
                continue
            yield number, CODE_SPAN.sub("", line)
        elif match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence) and line.strip() == match.group(1):
            fence = None


def anchors(text: str) -> set[str]:
    """Every anchor a document offers: its headings as GitHub slugs (repeats get -1, -2, ...) and explicit ids."""
    found: set[str] = set()
    seen: dict[str, int] = {}
    fence = None
    for line in text.split("\n"):
        match = FENCE.match(line)
        if fence is None and match:
            fence = match.group(1)
            continue
        if fence is not None:
            if match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence) and line.strip() == match.group(1):
                fence = None
            continue
        heading = HEADING.match(line)
        if heading:
            base = slug(heading.group(2))
            count = seen.get(base, 0)
            seen[base] = count + 1
            found.add(base if count == 0 else f"{base}-{count}")
        for explicit in HTML_ANCHOR.finditer(line):
            found.add(explicit.group(1) or explicit.group(2) or "")
    return found


def targets(text: str):
    """(line number, link target) of every Markdown link, image, reference definition and HTML href / src."""
    for number, line in readable_lines(text):
        for match in INLINE_LINK.finditer(line):
            yield number, match.group(1).strip("<>")
        definition = REFERENCE_DEFINITION.match(line)
        if definition:
            yield number, definition.group(1).strip("<>")
        for match in HTML_ATTRIBUTE.finditer(line):
            value = match.group(1) if match.group(1) is not None else match.group(2)
            # srcset may list several candidates ("a.png 1x, b.png 2x"): the address is the first word of each
            for candidate in value.split(","):
                words = candidate.split()
                if words:
                    yield number, words[0]


def check(root: Path, files: list[str], tracked: set[str]) -> list[str]:
    """The broken links of [files] (paths relative to [root], POSIX style); [tracked] is every tracked path."""
    directories = {str(parent) for path in tracked for parent in PurePosixPath(path).parents if str(parent) != "."}
    anchor_cache: dict[str, set[str]] = {}

    def anchors_of(path: str) -> set[str]:
        if path not in anchor_cache:
            anchor_cache[path] = anchors((root / path).read_text(encoding="utf-8"))
        return anchor_cache[path]

    problems = []
    for file in files:
        text = (root / file).read_text(encoding="utf-8")
        for number, raw in targets(text):
            if not raw or SCHEME.match(raw) or raw.startswith("//"):
                continue
            address, _, fragment = raw.partition("#")
            address = urllib.parse.unquote(address.split("?")[0])
            fragment = urllib.parse.unquote(fragment)
            if not address:
                target = file
            elif address.startswith("/"):
                target = normalize(address.lstrip("/"))
            else:
                target = normalize(str(PurePosixPath(file).parent / address))
            if target is None:
                problems.append(f"{file}:{number}: '{raw}' points outside the repository")
                continue
            target = target.rstrip("/")
            if target in ("", "."):
                continue  # the repository root
            if target not in tracked and target not in directories:
                exists = (root / target).exists()
                reason = "exists but is not tracked by git" if exists else "does not exist"
                problems.append(f"{file}:{number}: '{raw}': {target} {reason}")
                continue
            if fragment and target in tracked and target.lower().endswith(".md"):
                if fragment.lower() not in anchors_of(target):
                    problems.append(f"{file}:{number}: '{raw}': no heading or id '#{fragment}' in {target}")
    return problems


def normalize(path: str) -> str | None:
    """[path] with `.` and `..` resolved, or None when it leaves the repository."""
    parts: list[str] = []
    for part in PurePosixPath(path).parts:
        if part == "..":
            if not parts:
                return None
            parts.pop()
        elif part != ".":
            parts.append(part)
    return "/".join(parts)


def headings(text: str) -> list[tuple[int, str]]:
    """(level, text) of every heading outside code blocks."""
    found = []
    for _, line in readable_lines(text):
        match = HEADING.match(line)
        if match:
            found.append((len(match.group(1)), match.group(2).strip()))
    return found


def living_specifications(root: Path, index: str = INDEX) -> list[str]:
    """The documents linked from the "Living specifications" section of the index, as paths relative to [root]."""
    path = root / index
    if not path.is_file():
        return []
    listed: list[str] = []
    inside = False
    for _, line in readable_lines(path.read_text(encoding="utf-8")):
        heading = HEADING.match(line)
        if heading:
            inside = heading.group(2).strip().lower() == LIVING_HEADING.lower()
            continue
        if not inside:
            continue
        for match in INLINE_LINK.finditer(line):
            target = match.group(1).strip("<>").partition("#")[0]
            if not target or SCHEME.match(target) or not target.lower().endswith(".md"):
                continue
            resolved = normalize(str(PurePosixPath(index).parent / urllib.parse.unquote(target)))
            if resolved and resolved not in listed:
                listed.append(resolved)
    return listed


def structure_warnings(root: Path, documents: list[str]) -> list[str]:
    """One warning per required section that a living specification lacks."""
    warnings = []
    for document in documents:
        path = root / document
        if not path.is_file():
            continue
        present = {(level, text.lower()) for level, text in headings(path.read_text(encoding="utf-8"))}
        for level, name in REQUIRED_SECTIONS:
            if (level, name.lower()) not in present:
                warnings.append(f"warning: {document}: no '{'#' * level} {name}' section")
    return warnings


def tracked_files(root: Path) -> set[str]:
    listing = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True).stdout
    return {name for name in listing.decode("utf-8").split("\0") if name}


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Checks relative links and anchors in tracked Markdown files.")
    parser.add_argument("files", nargs="*", help="Markdown files relative to the repository root (default: all tracked)")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help="repository root")
    options = parser.parse_args(arguments)
    root = options.root.resolve()
    try:
        tracked = tracked_files(root)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"check_links: cannot list the tracked files of {root}: {error}", file=sys.stderr)
        return 2
    if options.files:
        files = [PurePosixPath(name).as_posix() for name in options.files]
        missing = [name for name in files if name not in tracked]
        if missing:
            print(f"check_links: not tracked: {', '.join(missing)}", file=sys.stderr)
            return 2
    else:
        files = sorted(name for name in tracked if name.lower().endswith(".md") and not name.startswith(VENDORED))
    # A file that is tracked but deleted in the working tree cannot be read; it is reported by git, not here.
    files = [name for name in files if (root / name).is_file()]
    problems = check(root, files, tracked)
    for problem in problems:
        print(problem)
    warnings = structure_warnings(root, [name for name in living_specifications(root) if name in files])
    for warning in warnings:
        print(warning)
    if problems:
        print(f"check_links: {len(problems)} broken link(s) in {len(files)} file(s)", file=sys.stderr)
        return 1
    print(f"check_links: {len(files)} files, no broken relative link or anchor, {len(warnings)} structure warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
