#!/usr/bin/env python3
# tests/hardware/test_x11_window_manager.py

"""Check the window-manager waits without an X server.

run_secure_focus_watch.py started openbox and mapped its GTK window at once; the
window mapped before openbox announced EWMH support, and xdotool windowactivate
aborted (desktop-webview job 133797159970). The harness now waits for the facts
openbox publishes: these cases pin what counts as ready and as managed.
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import x11_window_manager as WindowManager  # noqa: E402

ACTIVE = 301
CHECK = 0x400001
CLIENT = 0x800004


class Properties:
    """A fake X server: window -> property name -> 32-bit items."""

    def __init__(self, windows):
        self.windows = windows

    def atom(self, name):
        return {"_NET_ACTIVE_WINDOW": ACTIVE}[name]

    def __call__(self, window, name):
        return self.windows.get(window, {}).get(name)


def started_window_manager(supported=(ACTIVE,), check_target=CHECK):
    return {
        0: {"_NET_SUPPORTING_WM_CHECK": [CHECK], "_NET_SUPPORTED": list(supported)},
        CHECK: {"_NET_SUPPORTING_WM_CHECK": [check_target]},
    }


class ReadyTest(unittest.TestCase):
    """Ready means a live window manager that can activate windows."""

    def test_a_bare_x_server_is_not_ready(self):
        self.assertFalse(WindowManager.ready(Properties({})))

    def test_a_started_window_manager_is_ready(self):
        self.assertTrue(WindowManager.ready(Properties(started_window_manager())))

    def test_a_check_window_left_by_a_dead_window_manager_is_not_ready(self):
        windows = started_window_manager()
        del windows[CHECK]
        self.assertFalse(WindowManager.ready(Properties(windows)))

    def test_a_check_window_that_names_another_window_is_not_ready(self):
        self.assertFalse(
            WindowManager.ready(Properties(started_window_manager(check_target=CLIENT)))
        )

    def test_a_window_manager_without_active_window_support_is_not_ready(self):
        # The exact refusal xdotool reported: _NET_SUPPORTED lacks the atom.
        self.assertFalse(WindowManager.ready(Properties(started_window_manager(supported=(7, 8)))))


class ManagedTest(unittest.TestCase):
    """Managed means the window manager wrote WM_STATE NormalState."""

    def test_a_mapped_window_the_window_manager_has_not_taken_is_not_managed(self):
        self.assertFalse(WindowManager.managed(Properties({CLIENT: {}}), CLIENT))

    def test_an_iconic_window_is_not_managed(self):
        self.assertFalse(WindowManager.managed(Properties({CLIENT: {"WM_STATE": [3, 0]}}), CLIENT))

    def test_a_normal_window_is_managed(self):
        self.assertTrue(WindowManager.managed(Properties({CLIENT: {"WM_STATE": [1, 0]}}), CLIENT))


class WaitTest(unittest.TestCase):
    """A wait that never succeeds names what never happened."""

    def test_the_wait_fails_naming_the_window_manager(self):
        with self.assertRaisesRegex(AssertionError, "_NET_ACTIVE_WINDOW within 0.05 s"):
            WindowManager.wait_until_ready(Properties({}), seconds=0.05)

    def test_the_wait_returns_once_the_window_manager_published(self):
        windows = {}
        calls = []

        def appear():
            calls.append(True)
            if len(calls) == 3:
                windows.update(started_window_manager())
            return WindowManager.ready(Properties(windows))

        WindowManager.wait(appear, 5, "never")
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
