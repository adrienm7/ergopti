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
            with tempfile_staging(version_dir, data_types) as staging:
                self.compile_rmlvo(staging, "ergopti", None)
                self.compile_rmlvo(staging, "ergopti", "plus")


import contextlib  # noqa: E402


@contextlib.contextmanager
def tempfile_staging(version_dir: Path, types_content: str):
    """Materialise a per-package extensions tree for one version."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp) / "ergopti"
        (staging / "symbols").mkdir(parents=True)
        (staging / "types").mkdir()
        (staging / "rules").mkdir()
        for symbols_path in sorted(version_dir.glob("*.xkb")):
            content = symbols_path.read_text(encoding="utf-8")
            # Mirror the installer's default-section patch.
            content = content.replace(
                f'xkb_symbols "{symbols_path.stem}"', 'xkb_symbols "default"', 1
            )
            (staging / "symbols" / "ergopti").write_text(content, encoding="utf-8")
        (staging / "types" / "ergopti").write_text(types_content, encoding="utf-8")
        (staging / "rules" / "evdev.xml").write_text(
            "<xkbConfigRegistry version='1.1'><layoutList/></xkbConfigRegistry>",
            encoding="utf-8",
        )
        yield staging


if __name__ == "__main__":
    unittest.main()
