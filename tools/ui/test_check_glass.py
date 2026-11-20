"""Tests of the glass check: python3 -m unittest discover -s tools/ui (from the repository root)."""

import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("check_glass", Path(__file__).with_name("check_glass.py"))
check_glass = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_glass)


def lines(text):
    return [number for number, _ in check_glass.candidates(text)]


class CandidatesTest(unittest.TestCase):
    def test_translucent_fills_are_found(self):
        text = "\n".join([
            ".background(Capsule().fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.55)))",
            "shape.fill(colors.surface2.color)",
            ".background(Color.black.opacity(0.5))",
            "Capsule().fill(.ultraThinMaterial)",
            "colors.scrim.color.ignoresSafeArea()",
            ".fill(RGBA(red: 1, green: 1, blue: 1, alpha: 0.78).color)",
        ])
        self.assertEqual([1, 2, 3, 4, 5, 6], lines(text))

    def test_glass_opaque_fills_gradients_strokes_and_shadows_pass(self):
        text = "\n".join([
            ".background(GlassShape(Capsule(), tint: colors.surface2))",
            "Capsule().fill(colors.accent.color)",
            "Capsule().fill(LinearGradient(colors: [a.opacity(0.5).color, b.color], startPoint: .leading, endPoint: .trailing))",
            ".overlay(Capsule().strokeBorder(colors.line.color, lineWidth: 1))",
            "shape.fill(.black.opacity(0.7)).blur(radius: 50)",
            "// shape.fill(colors.surface.color) in a comment",
            "/// `.fill(colors.surface.color)` in documentation",
        ])
        self.assertEqual([], lines(text))


class OffencesTest(unittest.TestCase):
    def test_an_allowed_line_passes_and_an_unused_entry_is_stale(self):
        files = {"A.swift": "x\nshape.fill(colors.surface2.color)\n.background(Color.black.opacity(0.5))\n"}
        allowed = [("A.swift", "colors.surface2"), ("B.swift", "anything")]
        flagged, stale = check_glass.offences(files, allowed)
        self.assertEqual(["A.swift:3: .background(Color.black.opacity(0.5))"], flagged)
        self.assertEqual([("B.swift", "anything")], stale)

    def test_an_entry_needs_a_reason(self):
        with self.assertRaises(ValueError):
            check_glass.parse_allowlist("A.swift | shape.fill(colors.surface2.color)\n")

    def test_the_interface_is_clean(self):
        self.assertEqual(0, check_glass.main())


if __name__ == "__main__":
    unittest.main()
