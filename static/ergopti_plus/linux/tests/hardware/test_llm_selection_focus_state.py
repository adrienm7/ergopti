#!/usr/bin/env python3
# tests/hardware/test_llm_selection_focus_state.py

"""Check the AI destination proof's state exchange without a graphical desktop.

run_llm_selection_focus.py read state.json while the GTK child was rewriting
it with write_text(), which truncates first: the proof failed with a
JSONDecodeError at char 0 (run 43105583384). The child now publishes each
document whole and the reader waits, within a deadline, for a complete one.
"""

import importlib.util
import json
import os
import pathlib
import tempfile
import threading
import time
import unittest

PROOF = pathlib.Path(__file__).with_name("run_llm_selection_focus.py")
SPEC = importlib.util.spec_from_file_location("run_llm_selection_focus", PROOF)
FOCUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FOCUS)


class StateExchangeTest(unittest.TestCase):
    """The reader never parses a partial document and names a missing one."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "state.json"

    def tearDown(self):
        self.directory.cleanup()

    def test_an_empty_file_is_waited_for_then_named(self):
        self.path.write_text("")
        started = time.monotonic()
        with self.assertRaisesRegex(AssertionError, "state.json held no complete document"):
            FOCUS.read_complete(self.path, seconds=0.3)
        self.assertGreaterEqual(time.monotonic() - started, 0.3)

    def test_a_partial_file_is_never_parsed(self):
        self.path.write_text('{"focused": 0, "texts": ["ORIG')
        with self.assertRaisesRegex(AssertionError, "no complete document"):
            FOCUS.read_complete(self.path, seconds=0.2)

    def test_a_document_completed_during_the_wait_is_returned(self):
        self.path.write_text("")

        def complete():
            time.sleep(0.1)
            FOCUS.publish(self.path, {"focused": 1, "texts": ["A", "B"]})

        writer = threading.Thread(target=complete)
        writer.start()
        try:
            self.assertEqual(
                FOCUS.read_complete(self.path, seconds=5), {"focused": 1, "texts": ["A", "B"]}
            )
        finally:
            writer.join()

    def test_a_missing_file_is_waited_for(self):
        with self.assertRaisesRegex(AssertionError, "state.json held no complete document"):
            FOCUS.read_complete(self.path, seconds=0.1)

    def test_publish_replaces_the_document_whole(self):
        FOCUS.publish(self.path, {"focused": 0, "texts": ["old"]})
        inode = os.stat(self.path).st_ino
        FOCUS.publish(self.path, {"focused": 2, "texts": ["new"]})
        self.assertEqual(json.loads(self.path.read_text()), {"focused": 2, "texts": ["new"]})
        # A rename publishes a new file; an in-place rewrite would keep the inode.
        self.assertNotEqual(os.stat(self.path).st_ino, inode)
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), ["state.json"])


if __name__ == "__main__":
    unittest.main()
