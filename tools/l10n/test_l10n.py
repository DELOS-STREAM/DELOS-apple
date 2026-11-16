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


if __name__ == "__main__":
    unittest.main()
