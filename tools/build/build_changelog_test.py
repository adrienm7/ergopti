# tools/build/build_changelog_test.py
"""Keep tool attribution and private agent session links out of release notes."""

import unittest

from build_changelog import clean_body


class CleanBodyTests(unittest.TestCase):
    def test_tool_attribution_never_reaches_the_release_body(self):
        body = (
            "Explain why the change was needed.\n"
            "\n"
            "Co-Authored-By: Some Tool <noreply@example.invalid>\n"
            "co-authored-by: Other Tool <bot@example.invalid>\n"
            "Claude-Session: https://claude.ai/code/session_01ABCDEF\n"
            "See https://claude.ai/code/session_01ABCDEF for the transcript.\n"
        )
        self.assertEqual(clean_body(body), "  Explain why the change was needed.")

    def test_ordinary_body_lines_survive(self):
        body = "First line.\n\nSee https://claude.ai/ for the product.\n"
        self.assertEqual(
            clean_body(body),
            "  First line.\n  \n  See https://claude.ai/ for the product.",
        )


if __name__ == "__main__":
    unittest.main()
