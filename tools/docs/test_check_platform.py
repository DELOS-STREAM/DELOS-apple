"""Tests of the platform check: python3 -m unittest discover -s tools/docs (from the repository root)."""

import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("check_platform", Path(__file__).with_name("check_platform.py"))
check_platform = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_platform)


class OffencesTest(unittest.TestCase):
    def test_a_clean_text_passes(self):
        self.assertEqual([], check_platform.offences("- The app icon.\n- Six touch modes on iPhone.\n"))

    def test_the_name_is_found_in_any_case(self):
        text = "fine\nas on DELOS for Android\nan ANDROID build\nthe delos-android repo\n"
        self.assertEqual([2, 3, 4], [number for number, _ in check_platform.offences(text)])

    def test_the_repository_documents_are_clean(self):
        self.assertEqual(0, check_platform.main())


if __name__ == "__main__":
    unittest.main()
