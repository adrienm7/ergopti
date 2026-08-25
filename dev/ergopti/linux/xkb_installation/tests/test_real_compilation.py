"""Optional real-compilation test using the python xkbcommon bindings.

When the ``xkbcommon`` package is importable (its wheels bundle a recent
libxkbcommon), this test compiles every shipped layout through the real RMLVO
pipeline - including the extensions-directory environment variables our
installer relies on. A keymap that fails to compile is exactly what users
experience as dead layers, so this is the strongest automated signal we have.

The test skips silently when the binding or the bundled library is too old to
know about extensions directories: the structural coherence tests then remain
the active fence.
"""

import os
import sys
import unittest
from pathlib import Path

LAYOUT_DIR = Path(__file__).resolve().parents[2]
INSTALLER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INSTALLER_DIR))

from layout_package import build_evdev_post, patch_symbols_default, variant_for_filename  # noqa: E402

try:
    from xkbcommon.keymap import Keymap  # type: ignore
    from xkbcommon import xkbcommon  # type: ignore  # noqa: F401

    HAVE_XKBCOMMON = True
except Exception:  # pragma: no cover - depends on the environment
    HAVE_XKBCOMMON = False


@unittest.skipUnless(HAVE_XKBCOMMON, "python xkbcommon binding not installed")
class RealCompilationTests(unittest.TestCase):
    def compile_rmlvo(self, staging_root: Path, layout: str, variant: str | None) -> None:
        env_extensions = str(staging_root)
        old_unversioned = os.environ.get("XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH")
        old_versioned = os.environ.get("XKB_CONFIG_VERSIONED_EXTENSIONS_PATH")
        os.environ["XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH"] = env_extensions
        # Isolate the staged tree from any versioned host configuration.
        os.environ["XKB_CONFIG_VERSIONED_EXTENSIONS_PATH"] = ""
        try:
            Keymap.from_names(
                rules="evdev",
                model="pc105",
                layout=layout,
                variant=variant,
            )
        finally:
            for name, value in (
                ("XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH", old_unversioned),
                ("XKB_CONFIG_VERSIONED_EXTENSIONS_PATH", old_versioned),
            ):
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value

    def test_every_variant_compiles_through_its_staged_package(self):
        data_types = (
            LAYOUT_DIR / "xkb_generation" / "data" / "xkb_types.txt"
        ).read_text(encoding="utf-8")
        for version_dir in sorted(LAYOUT_DIR.glob("v*")):
            for symbols_path in sorted(version_dir.glob("*.xkb")):
                if variant_for_filename(symbols_path.name) is None:
                    continue
                with self.subTest(symbols=symbols_path.name):
                    with tempfile_staging(symbols_path, data_types) as staging_root:
                        self.compile_rmlvo(staging_root, "ergopti", None)


import contextlib  # noqa: E402


@contextlib.contextmanager
def tempfile_staging(symbols_path: Path, types_content: str):
    """Materialise the exact package produced for one selected layout."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp)
        package = staging_root / "ergopti"
        (package / "symbols").mkdir(parents=True)
        (package / "types").mkdir()
        (package / "rules").mkdir()
        content = patch_symbols_default(symbols_path.read_text(encoding="utf-8"))
        (package / "symbols" / "ergopti").write_text(content, encoding="utf-8")
        (package / "types" / "ergopti").write_text(types_content, encoding="utf-8")
        (package / "rules" / "evdev.xml").write_text(
            "<xkbConfigRegistry version='1.1'><layoutList/></xkbConfigRegistry>",
            encoding="utf-8",
        )
        (package / "rules" / "evdev.post").write_text(
            build_evdev_post("ergopti"), encoding="utf-8"
        )
        yield staging_root


if __name__ == "__main__":
    unittest.main()
