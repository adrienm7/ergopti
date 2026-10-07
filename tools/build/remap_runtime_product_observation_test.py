# tools/build/remap_runtime_product_observation_test.py
"""Actual filesystem/phase ownership controls with explicitly modeled lipo output."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SUBJECT_PATH = Path(__file__).with_name("remap_runtime_build.py")
SPEC = importlib.util.spec_from_file_location("product_observation_owned_subject", SUBJECT_PATH)
SUBJECT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUBJECT
SPEC.loader.exec_module(SUBJECT)

# Handwritten expected products; no expectations are generated from the subject.
PRODUCTS = (
    ("duktape", "vendor/duktape-src/build/Release/libduktape.a"),
    (
        "core",
        "src/apps/CoreService/build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
    ),
    (
        "console",
        "src/apps/ConsoleUserServer/build/Release/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
    ),
    ("cli", "src/bin/cli/build/Release/ergoptiplus_remap_cli"),
)


class ProductObservationOwnershipControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.root.chmod(0o700)
        self.source, self.owner = self.root / "compiled-source", self.root / "observation"
        self.source.mkdir(mode=0o700)
        self.owner.mkdir(mode=0o700)
        for label, relative in PRODUCTS:
            image = self.source / relative
            image.parent.mkdir(parents=True, mode=0o700)
            image.write_bytes(("MODELED image " + label + "\n").encode())
            if label in ("core", "console"):
                (image.parent.parent / "Info.plist").write_bytes(
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "com.ergoptiplus.remap." + label,
                            "CFBundleExecutable": image.name,
                        }
                    )
                )
        # The endpoint is an actual child; its architecture reply is modeled.
        driver = self.root / "modeled_lipo.py"
        driver.write_text("""import json, os, sys
from pathlib import Path
if len(sys.argv) != 4 or sys.argv[1:3] != ['lipo', '-archs']:
    raise SystemExit(9)
image = Path(sys.argv[3])
Path('observed-' + image.name + '.json').write_text(json.dumps({'cwd': str(Path.cwd().resolve()), 'image': str(image)}))
if os.environ.get('ERGOPTI_OBSERVER_MUTATE') == image.name:
    image.write_bytes(image.read_bytes() + b'changed by modeled endpoint\\n')
print('arm64 x86_64')
""")
        self.tool = self.root / "xcrun"
        self.tool.write_text(
            "#!/bin/sh\nexec "
            + shlex.quote(sys.executable)
            + " "
            + shlex.quote(str(driver))
            + ' "$@"\n'
        )
        self.tool.chmod(0o700)

    def observe(self):
        with (
            patch.object(SUBJECT.sys, "platform", "darwin"),
            patch.object(SUBJECT.shutil, "which", return_value=str(self.tool)),
        ):
            return SUBJECT.observe_products(self.source, self.owner)

    def test_four_products_use_the_observation_owner_as_actual_child_cwd(self):
        originals = {relative: (self.source / relative).read_bytes() for _, relative in PRODUCTS}
        products = self.observe()
        self.assertEqual([row["target"] for row in products], [row[0] for row in PRODUCTS])
        for row, (label, relative) in zip(products, PRODUCTS, strict=True):
            self.assertEqual(row["path"], relative)
            self.assertEqual(row["architectures"], ["arm64", "x86_64"])
            self.assertEqual(row["sha256"], hashlib.sha256(originals[relative]).hexdigest())
            self.assertEqual((self.source / relative).read_bytes(), originals[relative])
            receipt = json.loads(
                (self.owner / ("observed-" + Path(relative).name + ".json")).read_text()
            )
            self.assertEqual(
                receipt, {"cwd": str(self.owner), "image": str(self.source / relative)}
            )
        self.assertFalse(any(self.source.glob("observed-*.json")))

    def test_original_phase_boundary_still_refuses_a_sibling_cwd_before_effects(self):
        with self.assertRaises(SUBJECT.BASE.NativeBuildError) as caught:
            SUBJECT.BASE.run_phase(
                "foreign_cwd",
                [str(self.tool), "lipo", "-archs", str(self.source / PRODUCTS[0][1])],
                self.source,
                self.owner,
                time.monotonic() + 30,
            )
        self.assertEqual(caught.exception.code, "unsafe_path")
        self.assertEqual(list(self.owner.iterdir()), [])
        self.assertFalse(any(self.source.glob("observed-*.json")))

    def test_redirected_first_product_stays_refused_before_children(self):
        image = self.source / PRODUCTS[0][1]
        foreign = self.root / "foreign-image"
        foreign.write_bytes(b"foreign modeled bytes\n")
        image.unlink()
        image.symlink_to(foreign)
        with self.assertRaises(SUBJECT.BASE.NativeBuildError) as caught:
            self.observe()
        self.assertEqual(caught.exception.code, "unsafe_path")
        self.assertEqual(list(self.owner.iterdir()), [])
        self.assertEqual(foreign.read_bytes(), b"foreign modeled bytes\n")

    def test_actual_product_mutation_during_modeled_lipo_is_still_refused(self):
        with patch.dict(os.environ, {"ERGOPTI_OBSERVER_MUTATE": Path(PRODUCTS[0][1]).name}):
            with self.assertRaises(SUBJECT.BASE.NativeBuildError) as caught:
                self.observe()
        self.assertEqual(caught.exception.code, "source_identity")


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=1).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ProductObservationOwnershipControls)
    )
    passed = result.wasSuccessful() and result.testsRun == 4 and not result.skipped
    print(
        ("PASS" if passed else "FAIL")
        + " portable product observation ownership tests="
        + str(result.testsRun)
        + " failures="
        + str(len(result.failures))
        + " errors="
        + str(len(result.errors))
        + " skipped="
        + str(len(result.skipped))
        + " native=unexecuted"
    )
    raise SystemExit(0 if passed else 1)
