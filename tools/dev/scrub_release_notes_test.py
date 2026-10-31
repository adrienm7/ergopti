#!/usr/bin/env python3
# tools/dev/scrub_release_notes_test.py
"""Tests for scrub-release-notes.py: only attribution lines leave a body."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "scrub_release_notes", Path(__file__).with_name("scrub-release-notes.py")
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ScrubTests(unittest.TestCase):
    def test_removes_the_trailer_and_its_blank_line(self) -> None:
        body = "- **Fix**\n  detail.\n  \n  Claude-Session: https://claude.ai/code/session_01ABC\n- **Next**"
        self.assertEqual(MODULE.scrub(body), "- **Fix**\n  detail.\n- **Next**")

    def test_removes_a_co_author_line(self) -> None:
        body = "text\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nmore"
        self.assertEqual(MODULE.scrub(body), "text\nmore")

    def test_keeps_a_body_without_attribution(self) -> None:
        body = "## Changes\n\n- one\n\n- two"
        self.assertEqual(MODULE.scrub(body), body)

    def test_removes_a_bare_session_link(self) -> None:
        self.assertEqual(MODULE.scrub("a\nsee https://claude.ai/code/session_X\nb"), "a\nb")


if __name__ == "__main__":
    unittest.main()
