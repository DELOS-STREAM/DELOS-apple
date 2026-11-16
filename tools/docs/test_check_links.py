"""Tests of the Markdown link check: python3 -m unittest discover -s tools/docs (from the repository root)."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("check_links", Path(__file__).with_name("check_links.py"))
check_links = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_links)


class SlugTest(unittest.TestCase):
    def test_plain_heading(self):
        self.assertEqual("building", check_links.slug("Building"))
        self.assertEqual("build-test-and-lint", check_links.slug("Build, test and lint"))

    def test_punctuation_is_dropped_and_each_space_is_a_hyphen(self):
        self.assertEqual("pyrowave-link-guidance-18", check_links.slug("PyroWave link guidance (#18)"))
        self.assertEqual("variable-refresh-rate-vrr--arr", check_links.slug("Variable refresh rate (VRR / ARR)"))
        self.assertEqual("evidence-2026-10-26-first-device-feedback", check_links.slug("Evidence (2026-10-26): first device feedback"))

    def test_an_emoji_leaves_its_space(self):
        self.assertEqual("-what-is-delos", check_links.slug("✨ What is Delos?"))

    def test_formatting_is_removed_but_underscores_in_words_stay(self):
        self.assertEqual("the-list_vrr-key", check_links.slug("The `list_vrr` key"))
        self.assertEqual("bold-and-italic", check_links.slug("**Bold** and _italic_"))
        self.assertEqual("a-link", check_links.slug("A [link](https://example.org/x_y)"))

    def test_other_alphabets_are_kept(self):
        self.assertEqual("čeština-日本語", check_links.slug("Čeština 日本語"))


class AnchorsTest(unittest.TestCase):
    def test_repeated_headings_are_numbered(self):
        found = check_links.anchors("# Results\n\n## Results\n\n### Results\n")
        self.assertEqual({"results", "results-1", "results-2"}, found)

    def test_headings_in_code_blocks_do_not_count(self):
        found = check_links.anchors("# Real\n\n```sh\n# not a heading\n```\n\n~~~\n## neither\n~~~\n")
        self.assertEqual({"real"}, found)

    def test_explicit_ids_count(self):
        found = check_links.anchors('<a name="old-name"></a>\n<h2 id="by-id">Title</h2>\n')
        self.assertEqual({"old-name", "by-id"}, found)


class CheckTest(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        self.tracked = set()

    def tearDown(self):
        self._directory.cleanup()

    def write(self, name, text, tracked=True):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        if tracked:
            self.tracked.add(name)

    def problems(self, *files):
        return check_links.check(self.root, list(files), self.tracked)

    def test_good_links_pass(self):
        self.write("README.md", "# Top\n\n[docs](docs/GUIDE.md) [part](docs/GUIDE.md#part-two) [here](#top) [dir](docs/) [root](/LICENSE)\n")
        self.write("docs/GUIDE.md", "# Guide\n\n## Part two\n\n[up](../README.md#top) ![shot](img/shot.png)\n")
        self.write("docs/img/shot.png", "")
        self.write("LICENSE", "")
        self.assertEqual([], self.problems("README.md", "docs/GUIDE.md"))

    def test_missing_file_is_reported_with_its_line(self):
        self.write("README.md", "# Top\n\ntext\n[gone](docs/GONE.md)\n")
        self.assertEqual(["README.md:4: 'docs/GONE.md': docs/GONE.md does not exist"], self.problems("README.md"))

    def test_missing_anchor_is_reported(self):
        self.write("README.md", "[a](docs/GUIDE.md#feature-provenance) [b](#building)\n")
        self.write("docs/GUIDE.md", "# Guide\n")
        found = self.problems("README.md")
        self.assertEqual(2, len(found), found)
        self.assertIn("no heading or id '#feature-provenance' in docs/GUIDE.md", found[0])
        self.assertIn("no heading or id '#building' in README.md", found[1])

    def test_untracked_target_is_reported(self):
        self.write("README.md", "[notes](docs/LOCAL_NOTES.md)\n")
        self.write("docs/LOCAL_NOTES.md", "# Local\n", tracked=False)
        self.assertEqual(["README.md:1: 'docs/LOCAL_NOTES.md': docs/LOCAL_NOTES.md exists but is not tracked by git"], self.problems("README.md"))

    def test_link_out_of_the_repository_is_reported(self):
        self.write("docs/GUIDE.md", "[out](../../elsewhere.md)\n")
        self.assertEqual(["docs/GUIDE.md:1: '../../elsewhere.md' points outside the repository"], self.problems("docs/GUIDE.md"))

    def test_other_sites_and_schemes_are_not_checked(self):
        self.write("README.md", "[w](https://example.org/x#y) [m](mailto:a@example.org) [o](obtainium://add/https://example.org) [p](//example.org/x)\n")
        self.assertEqual([], self.problems("README.md"))

    def test_code_is_not_read(self):
        self.write("README.md", "`[x](missing.md)` and ``[y](missing2.md)``\n\n```md\n[z](missing3.md)\n```\n\n    [w](real-miss.md)\n")
        # An indented block is not recognised as code (it could be a list continuation), so only that link is read.
        self.assertEqual(["README.md:7: 'real-miss.md': real-miss.md does not exist"], self.problems("README.md"))

    def test_html_attributes_and_reference_definitions_are_checked(self):
        self.write("README.md", '<img src="docs/a.png"> <source srcset="docs/a.png 1x, docs/b.png 2x">\n<a href="docs/gone.html">x</a>\n\n[ref]: docs/c.md "Title"\n')
        self.write("docs/a.png", "")
        found = self.problems("README.md")
        self.assertEqual(["README.md:1: 'docs/b.png': docs/b.png does not exist",
                          "README.md:2: 'docs/gone.html': docs/gone.html does not exist",
                          "README.md:4: 'docs/c.md': docs/c.md does not exist"], found)

    def test_titles_brackets_and_escapes_in_links(self):
        self.write("README.md", '[a [b] c](docs/My%20Guide.md "the guide") [d](<docs/My Guide.md>) [e](docs/My%20Guide.md#caf%C3%A9)\n')
        self.write("docs/My Guide.md", "# Café\n")
        self.assertEqual([], self.problems("README.md"))

    def test_anchor_case_does_not_matter_and_non_markdown_anchors_are_not_checked(self):
        self.write("README.md", "[a](docs/GUIDE.md#Part-Two) [b](docs/page.html#anything)\n")
        self.write("docs/GUIDE.md", "## Part two\n")
        self.write("docs/page.html", "")
        self.assertEqual([], self.problems("README.md"))


class StructureTest(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)

    def tearDown(self):
        self._directory.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    INDEX = ("# Index\n\n## Start here\n\n[Build](BUILDING.md)\n\n## Living specifications\n\n"
             "| Document | Area |\n|---|---|\n| [GUI.md](GUI.md) | screens |\n| [Stream](STREAM.md#latency) | stream |\n"
             "| [site](https://example.org/x.md) | not ours |\n\n## Dated evidence\n\n[Research](RESEARCH.md)\n")

    def test_only_the_living_section_of_the_index_is_read(self):
        self.write("docs/README.md", self.INDEX)
        self.assertEqual(["docs/GUI.md", "docs/STREAM.md"], check_links.living_specifications(self.root))

    def test_no_index_means_no_living_specifications(self):
        self.assertEqual([], check_links.living_specifications(self.root))

    def test_a_complete_specification_has_no_warning(self):
        self.write("docs/GUI.md", "# GUI\n\n## Purpose\n\ntext\n\n## Behavior\n\n## Verification\n\n### Not verified\n\n- x\n")
        self.assertEqual([], check_links.structure_warnings(self.root, ["docs/GUI.md"]))

    def test_each_missing_section_is_one_warning(self):
        self.write("docs/GUI.md", "# GUI\n\nintro\n\n## Verification\n")
        self.assertEqual(["warning: docs/GUI.md: no '## Purpose' section",
                          "warning: docs/GUI.md: no '### Not verified' section"],
                         check_links.structure_warnings(self.root, ["docs/GUI.md"]))

    def test_heading_level_matters_and_code_blocks_do_not_count(self):
        self.write("docs/GUI.md", "# Purpose\n\n```md\n## Purpose\n## Verification\n### Not verified\n```\n\n### Verification\n")
        self.assertEqual(3, len(check_links.structure_warnings(self.root, ["docs/GUI.md"])))

    def test_a_listed_document_that_does_not_exist_is_left_to_the_link_check(self):
        self.assertEqual([], check_links.structure_warnings(self.root, ["docs/GONE.md"]))


if __name__ == "__main__":
    unittest.main()
