# tools/build/remap_runtime_build_test.py
"""Exercise portable four-target preparation; never qualify native compilation."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SPEC = importlib.util.spec_from_file_location(
    "owned_four_target_preparation", Path(__file__).with_name("remap_runtime_build.py")
)
SUBJECT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUBJECT
SPEC.loader.exec_module(SUBJECT)

BASELINE_PHASES = (
    "xcode_version",
    "xcodegen_acquisition",
    "xcodegen_version",
    "sdk_path",
    "acquisition",
    "checkout",
    "submodules",
    "identity_upstream",
    "identity_cpm",
    "identity_vhd",
    "source_clean",
    "version",
    "instrumentation",
    "duktape_generate",
    "duktape_build",
    "core_generate",
    "core_build",
    "cli_generate",
    "cli_build",
)
PRODUCTS = (
    ("duktape", "vendor/duktape-src", "build/Release/libduktape.a"),
    (
        "core",
        "src/apps/CoreService",
        "build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
    ),
    (
        "console",
        "src/apps/ConsoleUserServer",
        "build/Release/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
    ),
    ("cli", "src/bin/cli", "build/Release/ergoptiplus_remap_cli"),
)


class PreparationControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.source = self.root / "inputs"
        self.source.mkdir(mode=0o700)
        self.file = self.source / "recipe.yml"
        self.file.write_bytes(b"fixed original recipe\n")
        self.deadline = time.monotonic() + 10
        self.expected = {"recipe.yml": SUBJECT.BASE.digest(self.file.read_bytes())}

    def refusal(self, code, callback):
        with self.assertRaises(SUBJECT.BASE.NativeBuildError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def snapshot(self):
        return SUBJECT.snapshot_inputs(self.source, self.expected, self.deadline)

    def test_exact_four_targets(self):
        self.assertEqual(SUBJECT.TARGETS, PRODUCTS)

    def test_fixed_build_flags(self):
        command = SUBJECT.build_command("/usr/bin/xcodebuild", self.source)
        self.assertEqual(
            command,
            [
                "/usr/bin/xcodebuild",
                "-configuration",
                "Release",
                "-alltargets",
                "SYMROOT=" + str(self.source / "build"),
                "ARCHS=arm64 x86_64",
                "ONLY_ACTIVE_ARCH=NO",
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
                "SWIFT_ENABLE_EXPLICIT_MODULES=NO",
            ],
        )

    def test_actual_architecture_order_is_irrelevant(self):
        self.assertEqual(SUBJECT.architectures(b"x86_64 arm64\n"), ("arm64", "x86_64"))

    def test_architectures_are_closed_unique_and_real_text(self):
        for output in [
            b"",
            b"arm64\n",
            b"arm64 x86_64 arm64\n",
            b"arm64 x86_64 i386\n",
            b"\xff",
            "arm64 x86_64",
            b"arm64\x00 x86_64",
        ]:
            with self.subTest(output=output):
                self.refusal("product_architecture", lambda: SUBJECT.architectures(output))

    def test_deadline_before_any_work(self):
        for value in [True, float("nan"), float("inf"), 10**400, time.monotonic() - 1]:
            self.refusal("phase_deadline", lambda: SUBJECT.check_deadline(value))

    def test_current_snapshot_is_detached_and_immutable(self):
        snapshot = self.snapshot()
        self.expected["recipe.yml"] = "0" * 64
        self.assertEqual(snapshot.files[0].data, b"fixed original recipe\n")
        with self.assertRaises((AttributeError, TypeError)):
            snapshot.files[0].data = b"replacement"
        SUBJECT.current_inputs(snapshot, self.deadline)

    def test_missing_input_prevents_stage(self):
        self.refusal(
            "unsafe_path",
            lambda: SUBJECT.snapshot_inputs(self.source, {"missing": "0" * 64}, self.deadline),
        )
        self.assertFalse((self.root / "source-inputs").exists())

    def test_wrong_hash_refuses(self):
        self.refusal(
            "source_identity",
            lambda: SUBJECT.snapshot_inputs(self.source, {"recipe.yml": "0" * 64}, self.deadline),
        )

    def test_path_escape_and_alias_refuse(self):
        for name in [
            "../recipe.yml",
            "/recipe.yml",
            "a/../recipe.yml",
            "a//recipe.yml",
        ]:
            self.refusal(
                "unsafe_path",
                lambda: SUBJECT.snapshot_inputs(self.source, {name: "0" * 64}, self.deadline),
            )
        link = self.source / "link"
        link.symlink_to(self.file)
        self.refusal(
            "unsafe_path",
            lambda: SUBJECT.snapshot_inputs(
                self.source, {"link": self.expected["recipe.yml"]}, self.deadline
            ),
        )

    def test_hardlink_refuses(self):
        os.link(self.file, self.source / "alias")
        self.refusal("unsafe_path", self.snapshot)

    def test_parent_symlink_refuses(self):
        (self.source / "alias").symlink_to(self.source, target_is_directory=True)
        self.refusal(
            "unsafe_path",
            lambda: SUBJECT.snapshot_inputs(
                self.source,
                {"alias/recipe.yml": self.expected["recipe.yml"]},
                self.deadline,
            ),
        )

    def test_changed_content_prevents_publication(self):
        snapshot = self.snapshot()
        self.file.write_bytes(b"changed late\n")
        self.refusal(
            "source_identity",
            lambda: SUBJECT.stage_inputs(snapshot, self.root, self.deadline),
        )
        self.assertFalse((self.root / "source-inputs").exists())

    def test_same_bytes_new_inode_prevents_publication(self):
        snapshot = self.snapshot()
        self.file.rename(self.source / "old")
        self.file.write_bytes(b"fixed original recipe\n")
        self.refusal(
            "source_identity",
            lambda: SUBJECT.stage_inputs(snapshot, self.root, self.deadline),
        )
        self.assertFalse((self.root / "source-inputs").exists())

    def test_transactional_staging_copies_original_bytes(self):
        snapshot = self.snapshot()
        staged = SUBJECT.stage_inputs(snapshot, self.root, self.deadline)
        self.assertEqual(staged, self.root / "source-inputs")
        self.assertEqual((staged / "recipe.yml").read_bytes(), b"fixed original recipe\n")
        self.assertEqual(staged.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.file.read_bytes(), b"fixed original recipe\n")
        self.assertFalse((self.root / "native-build-result.json").exists())

    def test_existing_stage_never_replaced(self):
        snapshot = self.snapshot()
        target = self.root / "source-inputs"
        target.mkdir(mode=0o700)
        (target / "foreign").write_text("preserve")
        self.refusal(
            "unsafe_path",
            lambda: SUBJECT.stage_inputs(snapshot, self.root, self.deadline),
        )
        self.assertEqual((target / "foreign").read_text(), "preserve")

    def test_expired_stage_no_publication(self):
        self.refusal(
            "phase_deadline",
            lambda: SUBJECT.stage_inputs(self.snapshot(), self.root, time.monotonic() - 1),
        )
        self.assertFalse((self.root / "source-inputs").exists())

    def test_product_current_identity(self):
        first = SUBJECT.product_snapshot(self.file, self.source)
        self.file.write_bytes(b"changed product\n")
        self.refusal("source_identity", lambda: SUBJECT.current_product(first, self.source))

    def test_empty_or_aliased_product_refused(self):
        self.file.write_bytes(b"")
        self.refusal("product_identity", lambda: SUBJECT.product_snapshot(self.file, self.source))
        self.file.write_bytes(b"actual-image")
        (self.source / "alias").symlink_to(self.file)
        self.refusal(
            "unsafe_path",
            lambda: SUBJECT.product_snapshot(self.source / "alias", self.source),
        )

    def test_closed_product_cardinality(self):
        good = [
            {
                "target": row[0],
                "path": row[1] + "/" + row[2],
                "sha256": "1" * 64,
                "bytes": 12,
                "architectures": ["arm64", "x86_64"],
            }
            for row in PRODUCTS
        ]
        self.assertEqual(SUBJECT.validate_products(good), good)
        for mutation in [
            good[:3],
            good + [good[0]],
            list(reversed(good)),
            [{**good[0], "bytes": True}] + good[1:],
            [{**good[0], "extra": True}] + good[1:],
        ]:
            self.refusal("product_identity", lambda: SUBJECT.validate_products(mutation))

    def test_product_flags_cannot_be_forged_by_metadata(self):
        good = [
            {
                "target": row[0],
                "path": row[1] + "/" + row[2],
                "sha256": "1" * 64,
                "bytes": 12,
                "architectures": ["arm64", "x86_64"],
            }
            for row in PRODUCTS
        ]
        good[3]["architectures"] = ["arm64"]
        self.refusal("product_identity", lambda: SUBJECT.validate_products(good))

    def test_plist_actual_identifiers_and_executable(self):
        import plistlib

        data = plistlib.dumps(
            {
                "CFBundleIdentifier": "com.ergoptiplus.remap.console",
                "CFBundleExecutable": "ErgoptiPlus-Remap-Console",
            }
        )
        SUBJECT.validate_plist(data, "console")
        self.refusal("product_identity", lambda: SUBJECT.validate_plist(data, "core"))
        self.refusal("product_identity", lambda: SUBJECT.validate_plist(data, "cli"))

    def test_plist_malformed_and_wrong_identifier(self):
        self.refusal("product_identity", lambda: SUBJECT.validate_plist(b"not plist", "core"))
        import plistlib

        data = plistlib.dumps(
            {
                "CFBundleIdentifier": "org.pqrs.Karabiner-Core-Service",
                "CFBundleExecutable": "ErgoptiPlus-Remap-Core",
            }
        )
        self.refusal("product_identity", lambda: SUBJECT.validate_plist(data, "core"))

    def test_duplicate_escaped_keys_are_rejected(self):
        self.refusal(
            "duplicate_key",
            lambda: SUBJECT.parse_json(b'{"schema":1,"s\\u0063hema":1}'),
        )

    def test_unreleased_dependency_refuses_without_child_or_pass_receipt(self):
        repository = Path(__file__).resolve().parents[2]
        self.refusal(
            "dependency_unreleased",
            lambda: SUBJECT.preflight(repository, self.root, 300),
        )
        self.assertFalse((self.root / "native-build-result.json").exists())
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_unreviewed_factory_never_loaded(self):
        repository = self.root / "repository"
        (repository / "tools/build").mkdir(parents=True)
        sentinel = self.root / "forbidden"
        (repository / "tools/build/remap_runtime_source.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(sentinel)) + ").touch()\n"
        )
        self.refusal("source_identity", lambda: SUBJECT.preflight(repository, self.root, 300))
        self.assertFalse(sentinel.exists())

    def test_budget_is_the_exact_individual_300(self):
        for value in [True, 301, 600, 300.0, 0, 299]:
            self.refusal(
                "invalid_budget",
                lambda: SUBJECT.preflight(Path(__file__).resolve().parents[2], self.root, value),
            )

    def test_baseline_stdout_exact_actual_19_phases(self):
        stdout = "PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted\n"
        stdout += "".join("PHASE " + name + " seconds=0.125\n" for name in BASELINE_PHASES)
        stdout += "CANDIDATE none; actual diagnostic inputs compiled\n"
        SUBJECT.baseline_output(0, stdout, "")
        for status, output, error in [
            (True, stdout, ""),
            (0, stdout, "warning"),
            (1, stdout, ""),
            (0, stdout.replace("seconds=0.125", "seconds=nan", 1), ""),
            (0, stdout.replace("core_build", "console_build"), ""),
            (0, stdout.rstrip(), ""),
        ]:
            self.refusal(
                "baseline_refused",
                lambda: SUBJECT.baseline_output(status, output, error),
            )

    def test_portable_entrypoint_retains_typed_refusal(self):
        command = [
            sys.executable,
            str(Path(__file__).with_name("remap_runtime_build.py")),
            str(Path(__file__).resolve().parents[2]),
            str(self.root),
            "--preflight",
            "--budget",
            "300",
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr, "Owned runtime compilation refused: dependency_unreleased\n"
        )
        receipt = json.loads((self.root / "owned-build-refusal.json").read_text())
        self.assertEqual(
            receipt,
            {
                "schema": 1,
                "status": "refused",
                "code": "dependency_unreleased",
                "native_capture_executed": False,
                "installation_executed": False,
                "signing_executed": False,
                "auth_executed": False,
            },
        )

    def test_false_baseline_status_is_not_integer_zero(self):
        stdout = "PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted\n"
        stdout += "".join("PHASE " + name + " seconds=0.125\n" for name in BASELINE_PHASES)
        stdout += "CANDIDATE none; actual diagnostic inputs compiled\n"
        self.refusal("baseline_refused", lambda: SUBJECT.baseline_output(False, stdout, ""))

    def test_independent_actual_opened_fd_ancestry_aba(self):

        m, p, rows = SUBJECT, self.root, []
        # Actual filesystem read, with only deterministic timing of the foreign read endpoint modeled.
        root = Path(tempfile.mkdtemp(prefix="input-identity-", dir=p))
        root.chmod(0o700)
        first = root / "selected"
        second = root / "replacement"
        first.mkdir()
        second.mkdir()
        (first / "image").write_bytes(b"fixed")
        (second / "image").write_bytes(b"fixed")
        old_open = m.os.open
        opened = []

        def aba_open(path, flags, *args, **kwargs):
            if Path(path) != first / "image":
                return old_open(path, flags, *args, **kwargs)
            original = root / "held-original"
            replacement = root / "held-replacement"
            first.rename(original)
            second.rename(first)
            try:
                descriptor = old_open(path, flags, *args, **kwargs)
                opened.append(m._identity(m.os.fstat(descriptor)))
                return descriptor
            finally:
                first.rename(replacement)
                original.rename(first)

        m.os.open = aba_open
        before = m._identity((first / "image").lstat())
        refused = False
        code = None
        try:
            observed = m._ordinary(first / "image", root, 1024)
        except m.BASE.NativeBuildError as error:
            refused = True
            code = error.code
        finally:
            m.os.open = old_open
        rows.append(
            {
                "case": "opened-image-incarnation-ancestry-aba",
                "expected": "REFUSE",
                "actual": "REFUSED" if refused else "ACCEPTED",
                "refusal_code": code,
                "observed_prior_inode": before[1],
                "actual_opened_inode": opened[0][1],
                "returned_inode": None if refused else observed.identity[1],
                "actual_opened_same_identity": opened[0] == before,
                "native": "UNEXECUTED",
            }
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["actual"], "REFUSED")
        self.assertFalse(rows[0]["actual_opened_same_identity"])

    def test_independent_earlier_product_changed_by_later_phase(self):
        import plistlib

        m, p, rows = SUBJECT, self.root, []
        # Actual input snapshot/product-loop functions and physical product mutation; compile/lipo results explicitly modeled.
        owner = Path(tempfile.mkdtemp(prefix="product-loop-", dir=p))
        owner.chmod(0o700)
        source = owner / "source"
        source.mkdir(mode=0o700)
        (source / "marker").write_bytes(b"fixed")
        deadline = time.monotonic() + 30
        snapshot = m.snapshot_inputs(source, {"marker": m.BASE.digest(b"fixed")}, deadline)
        products = {label: source / recipe / relative for label, recipe, relative in m.TARGETS}
        tools = {
            name: str(Path(sys.executable).resolve())
            for name in ["xcodegen", "xcodebuild", "xcrun"]
        }
        native_platform = m.sys.platform
        old_run = m._RUN_PHASE
        phases = []
        build_commands = []

        def modeled_phase(name, command, project, owner, deadline):
            phases.append(name)
            if name.endswith("_build"):
                label = name.removesuffix("_build")
                build_commands.append((label, list(command)))
                output = products[label]
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(b"original-image-" + label.encode())
                if label in ["core", "console"]:
                    identifiers = m._identifiers()
                    (output.parents[1] / "Info.plist").write_bytes(
                        plistlib.dumps(
                            {
                                "CFBundleIdentifier": identifiers[label],
                                "CFBundleExecutable": output.name,
                            }
                        )
                    )
                if label == "cli":
                    products["duktape"].write_bytes(b"changed-after-lipo")
            if name.endswith("_architectures"):
                (owner / (name + ".stdout")).write_bytes(b"arm64 x86_64\n")
            return {"name": name, "status": 0}

        m.sys.platform = "darwin"
        m._RUN_PHASE = modeled_phase
        refused = False
        code = None
        try:
            result, actual_phases = m._compile_product_images(snapshot, owner, tools, deadline)
        except m.BASE.NativeBuildError as error:
            refused = True
            code = error.code
        finally:
            m.sys.platform = native_platform
            m._RUN_PHASE = old_run
        rows.append(
            {
                "case": "earlier-product-changed-by-later-phase",
                "expected": "REFUSE",
                "actual": "REFUSED" if refused else "ACCEPTED",
                "refusal_code": code,
                "receipt_duktape_digest": None if refused else result[0]["sha256"],
                "actual_final_duktape_digest": m.BASE.digest(products["duktape"].read_bytes()),
                "phase_endpoints": "MODELED compiler/lipo; actual source input/product snapshot/currentness and filesystem I/O",
                "native": "UNEXECUTED",
            }
        )
        # Freeze exact actual loop commands independently of the command factory.
        self.assertEqual(
            [label for label, _ in build_commands], ["duktape", "core", "console", "cli"]
        )
        for label, recipe in (
            ("duktape", "vendor/duktape-src"),
            ("core", "src/apps/CoreService"),
            ("console", "src/apps/ConsoleUserServer"),
            ("cli", "src/bin/cli"),
        ):
            with self.subTest(actual_build_target=label):
                expected_command = [
                    tools["xcodebuild"],
                    "-configuration",
                    "Release",
                    "-alltargets",
                    "SYMROOT=" + str(source / recipe / "build"),
                    "ARCHS=arm64 x86_64",
                    "ONLY_ACTIVE_ARCH=NO",
                    "CODE_SIGNING_ALLOWED=NO",
                    "CODE_SIGNING_REQUIRED=NO",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
                    "SWIFT_ENABLE_EXPLICIT_MODULES=NO",
                ]
                if label == "core":
                    expected_command.append("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO")
                self.assertEqual(dict(build_commands)[label], expected_command)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["actual"], "REFUSED")


class OwnedRecordControls(unittest.TestCase):
    """Literal receipt-policy controls; modeled metadata grants no native authority."""

    def record(self, fresh=True):
        phases = ["xcode_version", "xcodegen_acquisition", "xcodegen_version", "sdk_path"]
        if fresh:
            phases += [
                "acquisition",
                "checkout",
                "submodules",
                "identity_upstream",
                "identity_cpm",
                "identity_vhd",
                "source_clean",
            ]
        phases += ["version"]
        phases += [
            label + "_" + stage
            for label in ("duktape", "core", "console", "cli")
            for stage in ("generate", "build", "architectures")
        ]
        rows = []
        for phase in phases:
            row = {"schema": 1, "phase": phase, "status": "passed", "elapsed_seconds": 0.25}
            if phase == "xcodegen_acquisition":
                row.update(
                    operation="verified-HTTPS-download-and-ordinary-extraction",
                    child_process_executed=False,
                )
            else:
                row["exit_status"] = 0
            rows.append(row)
        generated_paths = (
            "appendix/GamePadViewer/Resources/Info.plist",
            "pkginfo/Distribution.xml",
            "src/apps/AppIconSwitcher/Resources/Info.plist",
            "src/apps/ConsoleUserServer/Resources/Info.plist",
            "src/apps/CoreService/Resources/Info.plist",
            "src/apps/EventViewer/Resources/Info.plist",
            "src/apps/MultitouchExtension/Resources/Info.plist",
            "src/apps/ServiceManager-Non-Privileged-Agents/Resources/Info.plist",
            "src/apps/ServiceManager-Privileged-Daemons/Resources/Info.plist",
            "src/apps/SettingsWindow/Resources/Info.plist",
            "src/apps/Updater/Resources/Info.plist",
            "src/share/karabiner_version.h",
        )
        return {
            "schema": 1,
            "status": "passed",
            "qualification": "unsigned_actual_owned_four_target_compilation",
            "budget_seconds": 300,
            "pins": {
                "upstream": "9312593e1a3bf72b94c63c524ebabe2637442e8a",
                "cpm": "6a8b2d64b993746d489432b45455e33b7fb8e09f",
                "vhd": "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb",
            },
            "products": [
                {
                    "target": label,
                    "path": recipe + "/" + path,
                    "sha256": "a" * 64,
                    "bytes": 10,
                    "architectures": ["arm64", "x86_64"],
                }
                for label, recipe, path in PRODUCTS
            ],
            "phases": rows,
            "source_inventory_entries": 4505,
            "owned_replacements": 57,
            "staged_files": 4526,
            "staged_links": 4,
            "generated_inputs": [
                {"path": path, "sha256": "b" * 64, "bytes": 15} for path in generated_paths
            ],
            "native_capture_executed": False,
            "installation_executed": False,
            "signing_executed": False,
            "auth_executed": False,
        }

    def refused(self, record):
        with self.assertRaises(SUBJECT.BASE.NativeBuildError) as caught:
            SUBJECT.validate_owned_record(record)
        self.assertEqual(caught.exception.code, "owned_receipt_refused")

    def test_exact_fresh_and_explicit_phase_records(self):
        for fresh in (True, False):
            with self.subTest(fresh=fresh):
                record = self.record(fresh)
                self.assertIsNone(SUBJECT.validate_owned_record(record))

    def test_exact_record_keyset_and_schema(self):
        for operation in (
            lambda r: r.update(extra=True),
            lambda r: r.pop("pins"),
            lambda r: r.update(schema=True),
            lambda r: r.update(budget_seconds=300.0),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_authority_is_literal_false(self):
        for key in (
            "native_capture_executed",
            "installation_executed",
            "signing_executed",
            "auth_executed",
        ):
            for value in (True, 0, None):
                with self.subTest(key=key, value=value):
                    record = self.record()
                    record[key] = value
                    self.refused(record)

    def test_counts_are_strict_actual_profile(self):
        for key in (
            "source_inventory_entries",
            "owned_replacements",
            "staged_files",
            "staged_links",
        ):
            for value in (True, 0, -1, 4505.0):
                record = self.record()
                record[key] = value
                self.refused(record)

    def test_elapsed_is_bounded_before_float_conversion(self):
        for value in (True, float("nan"), float("inf"), 10**400, -0.1, 300.1, "1"):
            record = self.record()
            record["phases"][0]["elapsed_seconds"] = value
            self.refused(record)

    def test_phases_have_closed_real_exit_fields(self):
        for operation in (
            lambda r: r["phases"][0].update(exit_status=True),
            lambda r: r["phases"][0].update(exit_status=1),
            lambda r: r["phases"][0].update(extra=1),
            lambda r: r["phases"][1].update(exit_status=0),
            lambda r: r["phases"][1].update(child_process_executed=0),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_phases_are_exactly_ordered_and_complete(self):
        for operation in (
            lambda r: r["phases"].reverse(),
            lambda r: r["phases"].pop(),
            lambda r: r["phases"].append(dict(r["phases"][0])),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_generated_rows_are_closed_unique_and_bound(self):
        for operation in (
            lambda r: r["generated_inputs"].pop(),
            lambda r: r["generated_inputs"].append(dict(r["generated_inputs"][0])),
            lambda r: r["generated_inputs"][0].update(path="../foreign"),
            lambda r: r["generated_inputs"][0].update(bytes=True),
            lambda r: r["generated_inputs"][0].update(sha256="g" * 64),
            lambda r: r["generated_inputs"][0].update(extra=True),
            lambda r: r["generated_inputs"][1].update(path=r["generated_inputs"][0]["path"]),
        ):
            record = self.record()
            operation(record)
            self.refused(record)

    def test_pin_and_product_declarations_are_not_authority(self):
        record = self.record()
        record["pins"]["upstream"] = "0" * 40
        self.refused(record)
        record = self.record()
        record["products"][2]["architectures"] = ["arm64"]
        self.refused(record)

    def test_actual_process_output_gate_is_required(self):
        line = "PASS unsigned actual owned four-target compilation; signing and activation unqualified\n"
        self.assertIsNone(SUBJECT.owned_output(0, line, ""))
        for status, stdout, stderr in (
            (1, line, ""),
            (True, line, ""),
            (0, line + line, ""),
            (0, line, "warning"),
            (0, line.rstrip(), ""),
        ):
            with self.assertRaises(SUBJECT.BASE.NativeBuildError) as caught:
                SUBJECT.owned_output(status, stdout, stderr)
            self.assertEqual(caught.exception.code, "owned_receipt_refused")


def concurrent_owned_control_suite():
    """Actual filesystem/coordinator controls with visibly modeled Apple owner ports."""

    class ConcurrentOwnedControls(unittest.TestCase):
        def setUp(self):
            from unittest.mock import patch

            path = Path(__file__).with_name("remap_runtime_artifact_test.py")
            spec = importlib.util.spec_from_file_location(
                "independent_parallel_fixture_" + str(id(self)), path
            )
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            self.case = module.ActualBuilderCustodyControls(methodName="runTest")
            self.case.setUp()
            self.addCleanup(self.case.doCleanups)
            self.builder = self.case.builder
            self.begins, self.finishes, self.owners = [], [], []
            self.begin_fault = None
            self.finish_fault = None
            for name, function in (
                ("_BEGIN_PHASE", self.begin),
                ("_FINISH_PHASE", self.finish),
                ("_PHASE_READY", lambda h: False),
            ):
                item = patch.object(self.builder, name, side_effect=function)
                item.start()
                self.addCleanup(item.stop)

        def begin(self, name, command, cwd, owner, deadline, register):
            h = self.case.namespace(
                name=name, command=command, cwd=cwd, owner=owner, deadline=deadline, drained=False
            )
            register(h)
            self.owners.append(h)
            self.begins.append(name)
            if self.begin_fault is not None:
                self.begin_fault(h)
            return h

        def finish(self, h):
            self.assertFalse(h.drained, "No owner may be waited twice")
            h.drained = True
            self.finishes.append(h.name)
            row = self.case.phase(h.name, h.command, h.cwd, h.owner, h.deadline)
            if self.finish_fault is not None:
                self.finish_fault(h)
            return row

        def test_exact_dag_and_canonical_results(self):
            row = self.case.invoke()
            self.assertEqual(self.begins, ["core_build", "console_build", "cli_build"])
            self.assertEqual(self.finishes, ["core_build", "console_build", "cli_build"])
            self.assertTrue(all(h.drained for h in self.owners))
            self.assertEqual(
                [r["target"] for r in row["products"]], ["duktape", "core", "console", "cli"]
            )
            expected = [
                n + "_" + phase
                for n in ("duktape", "core", "console", "cli")
                for phase in ("generate", "build", "architectures")
            ]
            self.assertEqual([r["phase"] for r in row["phases"][-12:]], expected)
            self.assertTrue(all(h.deadline == self.owners[0].deadline for h in self.owners))

        def test_source_refusal_stops_new_acquisition_and_drains_core(self):
            def mutate(h):
                if h.name == "core_build":
                    path = self.case.stage / "src/apps/CoreService/project.yml"
                    path.rename(path.with_name("old.yml"))
                    path.write_bytes(b"name: Model_core\n")

            self.begin_fault = mutate
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.case.invoke()
            self.assertEqual(caught.exception.code, "source_identity")
            self.assertEqual(self.begins, ["core_build"])
            self.assertEqual(self.finishes, ["core_build"])
            self.assertFalse((self.case.owner / "owned-native-build-result.json").exists())

        def test_begin_refusal_retains_failed_owner_and_drains_sibling(self):
            error = self.builder.BASE.NativeBuildError("phase_failed", "MODELED begin refusal")

            def fail(h):
                if h.name == "console_build":
                    raise error

            self.begin_fault = fail
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.case.invoke()
            self.assertIs(caught.exception, error)
            self.assertEqual(self.begins, ["core_build", "console_build"])
            self.assertEqual(self.finishes, ["core_build", "console_build"])
            self.assertTrue(all(h.drained for h in self.owners))
            self.assertFalse((self.case.owner / "owned-native-build-result.json").exists())

        def test_finish_refusal_drains_pending_cli_without_publication(self):
            error = self.builder.BASE.NativeBuildError(
                "phase_failed", "MODELED native finish refusal"
            )

            def fail(h):
                if h.name == "console_build":
                    raise error

            self.finish_fault = fail
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.case.invoke()
            self.assertIs(caught.exception, error)
            self.assertEqual(self.finishes, ["core_build", "console_build", "cli_build"])
            self.assertTrue(all(h.drained for h in self.owners))
            self.assertFalse((self.case.owner / "owned-native-build-result.json").exists())

        def test_later_completed_child_cannot_replace_earlier_image(self):
            def mutate(h):
                if h.name == "cli_build":
                    path = self.case.stage / self.builder.TARGETS[1][1] / self.builder.TARGETS[1][2]
                    path.write_bytes(b"foreign later compiler image\n")

            self.finish_fault = mutate
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.case.invoke()
            self.assertEqual(caught.exception.code, "source_identity")
            self.assertTrue(all(h.drained for h in self.owners))
            self.assertFalse((self.case.owner / "owned-native-build-result.json").exists())

        def test_actual_build_commands_are_fixed_release_two_architectures(self):
            self.case.invoke()
            for h, label, recipe in zip(
                self.owners,
                ("core", "console", "cli"),
                ("src/apps/CoreService", "src/apps/ConsoleUserServer", "src/bin/cli"),
                strict=True,
            ):
                expected = [
                    "/usr/bin/true",
                    "-configuration",
                    "Release",
                    "-alltargets",
                    "SYMROOT=" + str(self.case.stage / recipe / "build"),
                    "ARCHS=arm64 x86_64",
                    "ONLY_ACTIVE_ARCH=NO",
                    "CODE_SIGNING_ALLOWED=NO",
                    "CODE_SIGNING_REQUIRED=NO",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
                    "SWIFT_ENABLE_EXPLICIT_MODULES=NO",
                ]
                if label == "core":
                    expected.append("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO")
                self.assertEqual(h.command, expected)

        def test_ready_core_finishes_before_console_acquisition(self):
            from unittest.mock import patch

            events = []
            old_begin, old_finish = self.begin, self.finish

            def begin(*arguments):
                events.append(("begin", arguments[0]))
                return old_begin(*arguments)

            def finish(owner):
                events.append(("finish", owner.name))
                return old_finish(owner)

            with (
                patch.object(self.builder, "_BEGIN_PHASE", side_effect=begin),
                patch.object(self.builder, "_FINISH_PHASE", side_effect=finish),
                patch.object(
                    self.builder, "_PHASE_READY", side_effect=lambda h: h.name == "core_build"
                ),
            ):
                self.case.invoke()
            self.assertLess(
                events.index(("finish", "core_build")), events.index(("begin", "console_build"))
            )
            self.assertTrue(all(h.drained for h in self.owners))

        def test_reverse_ready_completion_keeps_canonical_array_order(self):
            from unittest.mock import patch

            with patch.object(
                self.builder, "_PHASE_READY", side_effect=lambda h: h.name == "console_build"
            ):
                row = self.case.invoke()
            self.assertEqual(self.finishes, ["console_build", "core_build", "cli_build"])
            self.assertEqual(
                [r["target"] for r in row["products"]], ["duktape", "core", "console", "cli"]
            )
            expected = [
                n + "_" + phase
                for n in ("duktape", "core", "console", "cli")
                for phase in ("generate", "build", "architectures")
            ]
            self.assertEqual([r["phase"] for r in row["phases"][-12:]], expected)

        def test_unfinished_sibling_image_is_never_observed(self):
            from unittest.mock import patch

            original = self.builder.product_snapshot
            observed = []

            def capture(path, root):
                for label in ("core", "console", "cli"):
                    _, recipe, relative = next(
                        row for row in self.builder.TARGETS if row[0] == label
                    )
                    if Path(path) == self.case.stage / recipe / relative:
                        matching = [h for h in self.owners if h.name == label + "_build"]
                        self.assertEqual(len(matching), 1)
                        self.assertTrue(matching[0].drained)
                        observed.append(label)
                return original(path, root)

            with (
                patch.object(self.builder, "product_snapshot", side_effect=capture),
                patch.object(
                    self.builder, "_PHASE_READY", side_effect=lambda h: h.name == "console_build"
                ),
            ):
                self.case.invoke()
            self.assertEqual(observed[0], "console")
            self.assertTrue(all(h.drained for h in self.owners))

        def test_primary_preserves_both_later_drain_refusals(self):
            primary = self.builder.BASE.NativeBuildError("phase_failed", "MODELED begin refusal")
            core = self.builder.BASE.NativeBuildError("phase_failed", "MODELED core drain refusal")
            console = self.builder.BASE.NativeBuildError(
                "phase_failed", "MODELED console drain refusal"
            )

            def begin_fault(owner):
                if owner.name == "console_build":
                    raise primary

            def finish_fault(owner):
                raise core if owner.name == "core_build" else console

            self.begin_fault, self.finish_fault = begin_fault, finish_fault
            with self.assertRaises(self.builder.BASE.NativeBuildError) as caught:
                self.case.invoke()
            self.assertIs(caught.exception, primary)
            self.assertEqual(caught.exception._owned_phase_failures, (core, console))
            self.assertTrue(all(h.drained for h in self.owners))
            self.assertFalse((self.case.owner / "owned-native-build-result.json").exists())

    return unittest.defaultTestLoader.loadTestsFromTestCase(ConcurrentOwnedControls)


if __name__ == "__main__":
    concurrent_result = unittest.TextTestRunner(verbosity=2).run(concurrent_owned_control_suite())
    print(
        "PARALLEL CONTROLS tests="
        + str(concurrent_result.testsRun)
        + " failures="
        + str(len(concurrent_result.failures))
        + " errors="
        + str(len(concurrent_result.errors))
        + " skipped="
        + str(len(concurrent_result.skipped))
        + " native=unexecuted",
        file=sys.stderr,
    )
    if not (
        concurrent_result.wasSuccessful()
        and concurrent_result.testsRun == 10
        and not concurrent_result.skipped
    ):
        raise SystemExit(1)

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    count = result.testsRun
    print(
        "PASS" if result.wasSuccessful() else "FAIL",
        "portable four-target preparation tests=" + str(count),
        "failures=" + str(len(result.failures)),
        "errors=" + str(len(result.errors)),
        "skipped=" + str(len(result.skipped)),
    )
    raise SystemExit(0 if result.wasSuccessful() and count == 41 and not result.skipped else 1)
