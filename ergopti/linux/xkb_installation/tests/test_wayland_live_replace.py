"""The live replacement of a layout on a GNOME or KDE Wayland session.

``apply-wayland`` installs a new build under the live slot the desktop does not
use, moves the desktop setting to it and succeeds only once XWayland, which
receives the compositor's keymap, holds that slot with the installed cells.

No GNOME or KDE runs here. The desktop setting is a fake ``gsettings`` (or
``kreadconfig6``/``kwriteconfig6``) backed by files, and the compositor is a
stand-in that, like mutter and KWin, compiles the first listed layout when the
setting's value changes and hands it to an Xvfb server playing XWayland. What
this proves: the slot alternation, the setting writes and read-backs, the
restoration on every refusal and the read-back of the loaded cells. What it
cannot prove: that mutter and KWin read the user tree and recompile on that
change (W1 to W3 of docs/design/layout-option-emulation.md), which needs a real
desktop.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

TESTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))
sys.path.insert(0, str(TESTS_DIR.parent))

import desktop_activation  # noqa: E402
import user_layout_installer as installer  # noqa: E402
from layout_package import (  # noqa: E402
    LayoutSpec,
    parse_gsettings_sources,
    parse_kde_layouts,
)
from test_user_layout_installer import (  # noqa: E402
    X11_TOOLS,
    XvfbServer,
    convert,
)

FAKE_GSETTINGS = """#!/usr/bin/env python3
import os, pathlib, sys
store = pathlib.Path(os.environ["FAKE_DESKTOP_STORE"])
args = sys.argv[1:]
if args[0] == "list-schemas":
    print("org.gnome.desktop.input-sources")
elif args[0] == "get":
    path = store / ("gnome-" + args[2])
    print(path.read_text() if path.exists() else "@a(ss) []")
elif args[0] == "set":
    (store / ("gnome-" + args[2])).write_text(args[3])
else:
    sys.exit(1)
"""

# kreadconfig6/kwriteconfig6 --file kxkbrc --group Layout --key KEY [VALUE]
FAKE_KCONFIG = """#!/usr/bin/env python3
import os, pathlib, sys
store = pathlib.Path(os.environ["FAKE_DESKTOP_STORE"])
args = sys.argv[1:]
key = args[args.index("--key") + 1]
path = store / ("kde-" + key)
if pathlib.Path(sys.argv[0]).name.startswith("kwrite"):
    path.write_text(args[-1])
else:
    print(path.read_text() if path.exists() else "")
"""


class FakeCompositor:
    """Compiles the first layout of the desktop setting into the Xvfb server each
    time the setting's value changes, as mutter and KWin do with their own setting;
    an unchanged value is no event. ``ignore`` plays a compositor that never
    reloads (one that does not read the user tree)."""

    def __init__(self, store: Path, desktop: str, root: Path, display: str) -> None:
        self.store, self.desktop, self.root, self.display = store, desktop, root, display
        self.ignore = False
        self.loads: list[str] = []
        self._stop = threading.Event()
        self._last: str | None = self._value()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _value(self) -> str | None:
        name = "gnome-sources" if self.desktop == "gnome" else "kde-LayoutList"
        path = self.store / name
        return path.read_text() if path.exists() else None

    def _first(self, value: str) -> str | None:
        if self.desktop == "gnome":
            sources = parse_gsettings_sources(value) or []
            return next((ident for kind, ident in sources if kind == "xkb"), None)
        layouts = parse_kde_layouts(value, "")
        return layouts[0].layout if layouts else None

    def _run(self) -> None:
        while not self._stop.wait(0.05):
            value = self._value()
            if value == self._last or value is None:
                continue
            self._last = value
            first = self._first(value)
            if self.ignore or first is None:
                continue
            environ = {"XDG_SESSION_TYPE": "x11", "DISPLAY": self.display}
            desktop_activation.apply_x11_user_tree(LayoutSpec(first), self.root, environ)
            self.loads.append(first)

    def __enter__(self) -> "FakeCompositor":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        self._thread.join()


@unittest.skipUnless(X11_TOOLS, "Xvfb, setxkbmap and xkbcomp are not installed")
class WaylandLiveReplaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = Path(tempfile.mkdtemp(prefix="ergopti-wayland-live-"))
        self.root = self.scratch / "config" / "xkb"
        self.home = self.scratch / "home"
        self.home.mkdir()
        self.store = self.scratch / "desktop"
        self.store.mkdir()
        self.bin = self.scratch / "bin"
        self.bin.mkdir()
        for name, text in (
            ("gsettings", FAKE_GSETTINGS),
            ("kreadconfig6", FAKE_KCONFIG),
            ("kwriteconfig6", FAKE_KCONFIG),
        ):
            path = self.bin / name
            path.write_text(text, encoding="utf-8")
            path.chmod(0o755)
        self.source = self.scratch / "converted" / "ergol"
        convert("ergol", self.source)
        installer.install("ergol", "ergol", self.source, ["fr"], self.root, self.home, {})
        self.path = mock.patch.dict(
            os.environ,
            {
                "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
                "FAKE_DESKTOP_STORE": str(self.store),
            },
        )
        self.path.start()
        patched = mock.patch.object(desktop_activation, "WAYLAND_READBACK_SECONDS", 3.0)
        patched.start()
        self.addCleanup(patched.stop)

    def tearDown(self) -> None:
        self.path.stop()
        shutil.rmtree(self.scratch, ignore_errors=True)

    def environ(self, server: XvfbServer, desktop: str) -> dict:
        return {
            "XDG_SESSION_TYPE": "wayland",
            "XDG_CURRENT_DESKTOP": desktop,
            "WAYLAND_DISPLAY": "wayland-0",
            "DISPLAY": server.display,
        }

    def gnome(self, key: str) -> list:
        return parse_gsettings_sources((self.store / ("gnome-" + key)).read_text()) or []

    def rewrite_first_digit(self, keysym: str) -> None:
        symbols = self.source / "ergol.xkb"
        text = symbols.read_text(encoding="utf-8")
        start = text.index("key <AE01>")
        bracket = text.index('", [', start) + len('", [')
        end = text.index(",", bracket)
        symbols.write_text(text[:bracket] + keysym + text[end:], encoding="utf-8")

    def apply(self, environ: dict) -> dict:
        with mock.patch.dict(os.environ, environ):
            return installer.apply_wayland(
                "ergol", "ergol", self.source, ["fr"], self.root, self.home, environ
            )

    def test_each_build_moves_gnome_to_the_other_slot_and_is_read_back(self) -> None:
        (self.store / "gnome-sources").write_text("[('xkb', 'us'), ('xkb', 'ergol')]")
        (self.store / "gnome-mru-sources").write_text("[('xkb', 'ergol'), ('xkb', 'us')]")
        with XvfbServer() as server, FakeCompositor(
            self.store, "gnome", self.root, server.display
        ) as compositor:
            environ = self.environ(server, "GNOME")
            expected_slots = ("ergol_live", "ergol", "ergol_live")
            for build, (slot, digit) in enumerate(zip(expected_slots, ("7", "8", "9"))):
                self.rewrite_first_digit(digit)
                report = self.apply(environ)
                self.assertTrue(report["ok"], report)
                self.assertEqual(report["slot"], slot, "build %d" % build)
                self.assertEqual(
                    server.levels("AE01")[0], digit, "the server holds build %d" % build
                )
                self.assertEqual(self.gnome("sources"), [("xkb", slot), ("xkb", "us")])
                self.assertEqual(self.gnome("mru-sources")[0], ("xkb", slot))
            self.assertEqual(compositor.loads, list(expected_slots))
        manifest = installer.read_manifest(self.root)
        self.assertEqual(sorted(manifest), ["ergol", "ergol_live"], "two copies at most")
        for slot in ("ergol", "ergol_live"):
            text = (self.root / "symbols" / slot).read_text(encoding="utf-8")
            self.assertIn("[9,", text, "the unused copy holds the last build too")

    def test_a_compositor_that_does_not_reload_puts_the_setting_back(self) -> None:
        before = "[('xkb', 'ergol'), ('xkb', 'us')]"
        (self.store / "gnome-sources").write_text(before)
        (self.store / "gnome-mru-sources").write_text(before)
        with XvfbServer() as server, FakeCompositor(
            self.store, "gnome", self.root, server.display
        ) as compositor:
            compositor.ignore = True
            held = server.levels("AE01")
            report = self.apply(self.environ(server, "GNOME"))
            self.assertFalse(report["ok"], report)
            self.assertEqual(report["code"], desktop_activation.WAYLAND_NOT_LOADED)
            self.assertEqual(server.levels("AE01"), held)
        self.assertEqual(self.gnome("sources"), parse_gsettings_sources(before))
        self.assertEqual(self.gnome("mru-sources"), parse_gsettings_sources(before))

    def test_a_setting_that_does_not_read_back_is_refused_and_restored(self) -> None:
        before = "[('xkb', 'us')]"
        (self.store / "gnome-sources").write_text(before)
        (self.store / "gnome-mru-sources").write_text(before)
        with XvfbServer() as server:
            with mock.patch.object(desktop_activation, "_gnome_set", return_value=False):
                report = self.apply(self.environ(server, "GNOME"))
        self.assertEqual(report["code"], desktop_activation.WAYLAND_SELECT_REFUSED)
        self.assertEqual(self.gnome("sources"), [("xkb", "us")])

    def test_kde_moves_the_layout_list_and_is_read_back(self) -> None:
        (self.store / "kde-LayoutList").write_text("us,ergol")
        (self.store / "kde-VariantList").write_text(",")
        (self.store / "kde-Use").write_text("true")
        with XvfbServer() as server, FakeCompositor(
            self.store, "kde", self.root, server.display
        ) as compositor:
            self.rewrite_first_digit("7")
            report = self.apply(self.environ(server, "KDE"))
            self.assertTrue(report["ok"], report)
            self.assertEqual(report["slot"], "ergol_live")
            self.assertEqual(server.levels("AE01")[0], "7")
            self.assertEqual(compositor.loads, ["ergol_live"])
        self.assertEqual((self.store / "kde-LayoutList").read_text(), "ergol_live,us")
        self.assertEqual((self.store / "kde-VariantList").read_text(), ",")

    def test_other_sessions_are_refused_before_anything_is_written(self) -> None:
        (self.store / "gnome-sources").write_text("[('xkb', 'ergol')]")
        with XvfbServer() as server:
            for environ in (
                self.environ(server, "sway"),
                {**self.environ(server, "GNOME"), "XDG_SESSION_TYPE": "x11"},
            ):
                report = self.apply(environ)
                self.assertEqual(report["code"], desktop_activation.WAYLAND_SESSION_UNSUPPORTED)
            no_display = {**self.environ(server, "GNOME")}
            del no_display["DISPLAY"]
            report = self.apply(no_display)
            self.assertEqual(report["code"], desktop_activation.WAYLAND_NO_DISPLAY)
        self.assertEqual(self.gnome("sources"), [("xkb", "ergol")])
        self.assertNotIn("ergol_live", installer.read_manifest(self.root))

    def test_uninstall_removes_both_copies(self) -> None:
        (self.store / "gnome-sources").write_text("[('xkb', 'ergol')]")
        (self.store / "gnome-mru-sources").write_text("[('xkb', 'ergol')]")
        with XvfbServer() as server, FakeCompositor(self.store, "gnome", self.root, server.display):
            self.assertTrue(self.apply(self.environ(server, "GNOME"))["ok"])
        with mock.patch.object(
            installer, "deactivate_layouts", return_value=installer.CleanupStatus.CHANGED
        ):
            installer.uninstall("ergol", self.root, self.home)
        self.assertEqual(installer.read_manifest(self.root), {})
        self.assertFalse((self.root / "symbols" / "ergol_live").exists())


if __name__ == "__main__":
    unittest.main()
