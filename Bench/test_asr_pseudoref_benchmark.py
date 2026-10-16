#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("asr_pseudoref_benchmark.py")
SPEC = importlib.util.spec_from_file_location("asr_pseudoref_benchmark", MODULE_PATH)
BENCH = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BENCH)


class PseudoReferenceBenchmarkTests(unittest.TestCase):
    def test_no_text_markers(self) -> None:
        for value in ("", "  ", "[BLANK_AUDIO]", "[blank audio]", "[silence]", "[NO SPEECH]", "<blank_audio>"):
            with self.subTest(value=value):
                self.assertTrue(BENCH.is_no_text(value))
        self.assertFalse(BENCH.is_no_text("blank audio was recorded"))

    def test_proportional_allocation_is_deterministic_and_bounded(self) -> None:
        groups = {
            ("engine-b", "short"): [{"id": f"b-{index}"} for index in range(2)],
            ("engine-a", "long"): [{"id": f"a-{index}"} for index in range(6)],
            ("engine-c", "normal"): [{"id": f"c-{index}"} for index in range(2)],
        }
        first = BENCH.allocate_proportionally(groups, 7)
        second = BENCH.allocate_proportionally(dict(reversed(list(groups.items()))), 7)
        self.assertEqual(first, second)
        self.assertEqual(sum(first.values()), 7)
        for key, count in first.items():
            self.assertLessEqual(count, len(groups[key]))

    def test_normalized_text(self) -> None:
        self.assertEqual(BENCH.normalized_text("Hello, WORLD!"), "hello world")
        self.assertEqual(BENCH.normalized_text("James’s test"), "james's test")

    def test_levenshtein_operation_counts(self) -> None:
        self.assertEqual(
            BENCH.alignment(["a", "b", "c"], ["a", "x", "c"]),
            {"errors": 1, "substitutions": 1, "deletions": 0, "insertions": 0, "matches": 2},
        )
        self.assertEqual(
            BENCH.alignment(["a", "b"], ["a", "x", "b"]),
            {"errors": 1, "substitutions": 0, "deletions": 0, "insertions": 1, "matches": 2},
        )
        self.assertEqual(
            BENCH.alignment(["a", "x", "b"], ["a", "b"]),
            {"errors": 1, "substitutions": 0, "deletions": 1, "insertions": 0, "matches": 2},
        )

    def test_nearest_rank_percentiles(self) -> None:
        values = [4.0, 1.0, 3.0, 2.0]
        self.assertEqual(BENCH.quantile(values, 0.50), 2.0)
        self.assertEqual(BENCH.quantile(values, 0.95), 4.0)
        self.assertEqual(BENCH.quantile(values, 0.99), 4.0)
        self.assertIsNone(BENCH.quantile([], 0.95))

    def test_punctuation_is_sequence_only(self) -> None:
        # The punctuation order is identical although the commas are attached
        # to different words. The metric must be named and documented as a
        # sequence metric, not positional punctuation accuracy.
        self.assertEqual(BENCH.punctuation_sequence_score("a, b.", "a b, ."), (2, 2, 2))


if __name__ == "__main__":
    unittest.main()
