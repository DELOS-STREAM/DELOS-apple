import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_usage  # noqa: E402
import import_android  # noqa: E402


class ConvertTextTest(unittest.TestCase):
    def test_placeholders_become_apple_format(self):
        self.assertEqual(import_android.convert_text("Hi, %1$s"), "Hi, %1$@")
        self.assertEqual(import_android.convert_text("%s of %d"), "%@ of %d")
        self.assertEqual(import_android.convert_text("%1$.1f GB, %2$d%%"), "%1$.1f GB, %2$d%%")

    def test_android_escapes_are_resolved(self):
        self.assertEqual(import_android.convert_text(r"Don\'t \"quote\"\nnext"), "Don't \"quote\"\nnext")
        self.assertEqual(import_android.convert_text(r"\@home \?"), "@home ?")

    def test_surrounding_quotes_keep_the_spaces(self):
        self.assertEqual(import_android.convert_text('"  padded "'), "  padded ")


class ReadElementsTest(unittest.TestCase):
    def test_a_string_array_gives_one_name_per_item(self):
        root = import_android.ET.fromstring(
            '<resources><string name="s">One</string>'
            '<string-array name="lines"><item>Hi %1$s</item><item>Bye</item></string-array></resources>')
        self.assertEqual(import_android.read_elements(root, translated=False),
                         {"s": "One", "lines_0": "Hi %1$@", "lines_1": "Bye"})

    def test_untranslatable_names_are_skipped_in_translations_only(self):
        root = import_android.ET.fromstring('<resources><string name="n" translatable="false">X</string></resources>')
        self.assertEqual(import_android.read_elements(root, translated=False), {"n": "X"})
        self.assertEqual(import_android.read_elements(root, translated=True), {})


class PluralTest(unittest.TestCase):
    def test_a_plural_with_its_number_is_a_variation(self):
        entry = import_android.plural({"one": "%d day ago", "other": "%d days ago"})
        self.assertEqual(entry["variations"]["plural"]["other"]["stringUnit"]["value"], "%d days ago")

    def test_a_plural_whose_quantity_is_the_second_argument_swaps_its_placeholders(self):
        self.assertEqual(import_android.swap_quantity({"other": "%1$d of %2$d covers"}), {"other": "%2$d of %1$d covers"})
        self.assertEqual(import_android.swap_quantity({"one": "%1$@ has %2$d cover"}), {"one": "%2$@ has %1$d cover"})

    def test_a_plural_without_its_number_picks_its_form_by_a_substitution(self):
        entry = import_android.plural({"one": "hour", "other": "hours"})
        self.assertEqual(entry["stringUnit"]["value"], "%#@count@")
        substitution = entry["substitutions"]["count"]
        self.assertEqual((substitution["argNum"], substitution["formatSpecifier"]), (1, "d"))
        self.assertEqual(substitution["variations"]["plural"]["one"]["stringUnit"]["value"], "hour")


    def test_a_plural_with_a_text_shows_it_as_the_second_argument(self):
        entry = import_android.plural({"one": "%1$@ Hour", "other": "%1$@ Hours"})
        substitution = entry["substitutions"]["count"]
        self.assertEqual(substitution["variations"]["plural"]["other"]["stringUnit"]["value"], "%2$@ Hours")


class CheckUsageTest(unittest.TestCase):
    catalog = {"strings": {
        "full": {"localizations": {language: {} for language in check_usage.LANGUAGES}},
        "partial": {"localizations": {"en": {}}},
    }}

    def test_a_complete_name_passes(self):
        self.assertEqual(check_usage.problems({"full": "a.swift:1"}, self.catalog), [])

    def test_a_missing_name_and_a_missing_language_are_reported(self):
        found = check_usage.problems({"absent": "a.swift:1", "partial": "b.swift:2"}, self.catalog)
        self.assertEqual(len(found), 2)
        self.assertIn("'absent' is not in the catalog", found[0])
        self.assertIn("'partial' has no", found[1])

    def test_plurals_read_with_lplural_count_as_used(self):
        self.assertEqual(check_usage.USE.findall('LPlural("a", 1) + L("b") + XL("c")'), ["a", "b"])


if __name__ == "__main__":
    unittest.main()
