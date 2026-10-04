# tools/diagnostics/macos_release_launch_test.py
"""Reject the early-log false green observed in the published macOS application."""

import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
from contextlib import contextmanager
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_launch", Path(__file__).with_name("macos-release-launch.py")
)
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class StartupReadinessTests(unittest.TestCase):
    """Both real startup branches need their own completed operation receipt."""

    def test_published_failure_does_not_count_as_readiness(self):
        with self.assertRaisesRegex(RuntimeError, "never completed"):
            observer.require_startup_ready(
                "Path: log file open (retention purge deferred)\n"
                "Native asynchronous logger transport unavailable: "
                "LuaSocket UDP bootstrap capability is unavailable."
            )

    def test_opening_wizard_does_not_mean_it_opened(self):
        with self.assertRaisesRegex(RuntimeError, "never completed"):
            observer.require_startup_ready("Opening onboarding wizard...")

    def test_first_install_accepts_completed_onboarding(self):
        marker = "Onboarding wizard opened."
        self.assertEqual(observer.require_startup_ready(marker), marker)

    def test_later_javascript_error_invalidates_opened_wizard(self):
        with self.assertRaisesRegex(RuntimeError, "Lua error"):
            observer.require_startup_ready(
                "Onboarding wizard opened.\n"
                "[ERROR] [onboarding] Onboarding JavaScript execution failed."
            )

    def test_existing_configuration_accepts_completed_runtime(self):
        marker = "User interface initialized successfully."
        self.assertEqual(observer.require_startup_ready(marker), marker)


class FailureEvidenceTests(unittest.TestCase):
    """A failed launch must explain itself in the job log, not only the artifact."""

    def test_names_the_failure_and_the_error_lines(self):
        with tempfile.TemporaryDirectory() as folder:
            logs = Path(folder)
            (logs / "ErgoptiPlus_boot.log").write_text(
                "[INFO] booting\n[ERROR] [llm] Profile catalogue failed.\n", encoding="utf-8"
            )
            (logs / "launcher.log").write_text("FATAL: child exited\n", encoding="utf-8")
            lines = observer.failure_evidence({"error": "RuntimeError: boom"}, logs)
        self.assertEqual(lines[0], "release launch failed: RuntimeError: boom")
        self.assertIn("ErgoptiPlus_boot.log: [ERROR] [llm] Profile catalogue failed.", lines)
        self.assertIn("launcher.log: FATAL: child exited", lines)
        self.assertNotIn("ErgoptiPlus_boot.log: [INFO] booting", lines)

    def test_caps_a_noisy_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            logs = Path(folder)
            (logs / "a.log").write_text("[ERROR] x\n" * 500, encoding="utf-8")
            lines = observer.failure_evidence({"error": "RuntimeError: boom"}, logs)
        self.assertEqual(len(lines), observer.MAX_EVIDENCE_LINES)

    def test_missing_log_folder_still_names_the_failure(self):
        lines = observer.failure_evidence(
            {"error": "RuntimeError: boom"}, Path("/nonexistent/ergopti")
        )
        self.assertEqual(lines, ["release launch failed: RuntimeError: boom"])


class PublishedArchiveTests(unittest.TestCase):
    """Use real private bytes and the actual policy owner before native ports."""

    XZ = "ErgoptiPlus.app.tar.xz"
    ZIP = "ErgoptiPlus.app.zip"
    TAG = "v0.0.0-dev.999"

    @contextmanager
    def fixture(self, names=None, fault=None):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            destination = root / "Applications"
            destination.mkdir()
            payloads = {self.XZ: b"independent XZ bytes", self.ZIP: b"historical ZIP bytes"}
            assets = [
                {
                    "name": name,
                    "digest": "sha256:" + hashlib.sha256(payloads[name]).hexdigest(),
                    "size": len(payloads[name]),
                    "future": {"untouched": True},
                }
                for name in (names if names is not None else [self.XZ, self.ZIP])
            ]
            release = {"draft": False, "tag_name": self.TAG, "assets": assets}
            events = []

            def execute(arguments, **keywords):
                if arguments[0] == "node":
                    return subprocess.run(arguments, **keywords)
                if arguments[:2] == ["gh", "api"]:
                    events.append(("view", list(arguments), dict(keywords)))
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(release), "")
                if arguments[:3] == ["gh", "release", "download"]:
                    name = arguments[arguments.index("--pattern") + 1]
                    target = Path(arguments[arguments.index("--dir") + 1]) / name
                    events.append(("download", name))
                    if fault == "download":
                        raise subprocess.CalledProcessError(1, arguments)
                    if fault == "symlink":
                        backing = root / "foreign"
                        backing.write_bytes(payloads[name])
                        target.symlink_to(backing)
                    else:
                        target.write_bytes(b"changed" if fault == "bytes" else payloads[name])
                    return subprocess.CompletedProcess(arguments, 0)
                if arguments[0] in ("/usr/bin/tar", "/usr/bin/ditto"):
                    events.append(("extract", list(arguments)))
                    if fault == "extract":
                        raise subprocess.CalledProcessError(1, arguments)
                    if fault == "extract_status":
                        return subprocess.CompletedProcess(arguments, 3)
                    if fault == "extract_bool":
                        return subprocess.CompletedProcess(arguments, False)
                    if fault == "source_race":
                        (root / "release-download" / self.XZ).write_bytes(
                            b"foreign after extraction"
                        )
                    (destination / "ErgoptiPlus.app").mkdir()
                    return subprocess.CompletedProcess(arguments, 0)
                events.append(("unexpected", list(arguments)))
                raise RuntimeError("Unexpected test transport command")

            yield root, destination, assets, events, execute

    def install(self, root, destination, execute):
        return observer.install_published_release(
            "fixture/project", self.TAG, root, destination, execute
        )

    def test_actual_shared_binding_owner_orders_preferred_before_historical(self):
        self.assertEqual(
            observer.published_archive_bindings(),
            [
                {"name": self.XZ, "format": "tar.xz"},
                {"name": self.ZIP, "format": "zip"},
            ],
        )

    def test_both_archives_install_preferred_and_retain_exact_selected_evidence(self):
        with self.fixture() as (root, destination, assets, events, execute):
            result = self.install(root, destination, execute)
            receipt = json.loads((root / "release-provenance.json").read_text())
            self.assertEqual(result, receipt)
            self.assertEqual(receipt["asset"], assets[0])
            self.assertEqual(receipt["format"], "tar.xz")
            self.assertEqual(events[1], ("download", self.XZ))
            self.assertEqual(
                events[2],
                (
                    "extract",
                    [
                        "/usr/bin/tar",
                        "-xJpf",
                        str(root / "release-download" / self.XZ),
                        "-C",
                        str(destination),
                    ],
                ),
            )
            self.assertTrue((destination / "ErgoptiPlus.app").is_dir())

    def test_preferred_only_is_consumable(self):
        with self.fixture([self.XZ]) as (root, destination, _, events, execute):
            result = self.install(root, destination, execute)
            self.assertEqual(result["asset"]["name"], self.XZ)
            self.assertEqual([e[1] for e in events if e[0] == "download"], [self.XZ])

    def test_absent_preferred_preserves_historical_zip_command(self):
        with self.fixture([self.ZIP]) as (root, destination, assets, events, execute):
            result = self.install(root, destination, execute)
            self.assertEqual(result["asset"], assets[0])
            self.assertEqual(result["format"], "zip")
            self.assertEqual(
                events[-1],
                (
                    "extract",
                    [
                        "/usr/bin/ditto",
                        "-x",
                        "-k",
                        str(root / "release-download" / self.ZIP),
                        str(destination),
                    ],
                ),
            )

    def test_unknown_future_asset_and_metadata_are_not_rewritten(self):
        with self.fixture() as (root, destination, assets, _, execute):
            assets.insert(0, {"name": "future-unrelated.bin", "future": [1, 2, 3]})
            result = self.install(root, destination, execute)
            self.assertEqual(result["asset"], assets[1])
            self.assertEqual(assets[0], {"name": "future-unrelated.bin", "future": [1, 2, 3]})

    def test_present_preferred_missing_or_bad_digest_never_falls_back(self):
        for value in (None, "", "sha256:" + "G" * 64, "sha256:" + "0" * 64, False):
            with (
                self.subTest(value=value),
                self.fixture() as (root, destination, assets, events, execute),
            ):
                assets[0]["digest"] = value
                with self.assertRaises(RuntimeError):
                    self.install(root, destination, execute)
                self.assertFalse(any(e == ("download", self.ZIP) for e in events))
                self.assertFalse(any(e[0] == "extract" for e in events))
                self.assertFalse((root / "release-provenance.json").exists())

    def test_duplicate_preferred_refuses_before_download(self):
        with self.fixture([self.XZ, self.XZ, self.ZIP]) as (root, destination, _, events, execute):
            with self.assertRaisesRegex(RuntimeError, "ambiguous"):
                self.install(root, destination, execute)
            self.assertEqual([e[0] for e in events], ["view"])
            self.assertFalse((root / "release-download").exists())

    def test_duplicate_historical_refuses_when_preferred_absent(self):
        with self.fixture([self.ZIP, self.ZIP]) as (root, destination, _, events, execute):
            with self.assertRaisesRegex(RuntimeError, "ambiguous"):
                self.install(root, destination, execute)
            self.assertEqual([e[0] for e in events], ["view"])

    def test_absent_all_declared_assets_refuses(self):
        with self.fixture([]) as (root, destination, _, events, execute):
            with self.assertRaisesRegex(RuntimeError, "no declared"):
                self.install(root, destination, execute)
            self.assertEqual([e[0] for e in events], ["view"])

    def test_preferred_download_refusal_does_not_try_historical(self):
        with self.fixture(fault="download") as (root, destination, _, events, execute):
            with self.assertRaises(subprocess.CalledProcessError):
                self.install(root, destination, execute)
            self.assertEqual([e[1] for e in events if e[0] == "download"], [self.XZ])
            self.assertFalse(any(e[0] == "extract" for e in events))

    def test_downloaded_wrong_bytes_and_symlink_refuse_before_extraction(self):
        for fault in ("bytes", "symlink"):
            with (
                self.subTest(fault=fault),
                self.fixture(fault=fault) as (root, destination, _, events, execute),
            ):
                with self.assertRaises(RuntimeError):
                    self.install(root, destination, execute)
                self.assertFalse(any(e[0] == "extract" for e in events))
                self.assertFalse((root / "release-provenance.json").exists())

    def test_extractor_throw_nonzero_and_boolean_do_not_admit_provenance(self):
        for fault in ("extract", "extract_status", "extract_bool"):
            with (
                self.subTest(fault=fault),
                self.fixture(fault=fault) as (root, destination, _, events, execute),
            ):
                with self.assertRaises((subprocess.CalledProcessError, RuntimeError)):
                    self.install(root, destination, execute)
                self.assertEqual([e[1] for e in events if e[0] == "download"], [self.XZ])
                self.assertEqual(len([e for e in events if e[0] == "extract"]), 1)
                self.assertFalse((root / "release-provenance.json").exists())

    def test_changed_archive_after_native_completion_is_not_successful_evidence(self):
        with self.fixture(fault="source_race") as (root, destination, _, events, execute):
            with self.assertRaisesRegex(RuntimeError, "changed during"):
                self.install(root, destination, execute)
            self.assertEqual(len([e for e in events if e[0] == "extract"]), 1)
            self.assertFalse((root / "release-provenance.json").exists())
            self.assertEqual(
                (root / "release-download" / self.XZ).read_bytes(), b"foreign after extraction"
            )

    def test_existing_application_is_not_replaced(self):
        with self.fixture() as (root, destination, _, events, execute):
            (destination / "ErgoptiPlus.app").mkdir()
            marker = destination / "ErgoptiPlus.app" / "foreign"
            marker.write_bytes(b"retained application")
            with self.assertRaisesRegex(RuntimeError, "replace"):
                self.install(root, destination, execute)
            self.assertEqual(marker.read_bytes(), b"retained application")
            self.assertFalse(any(e[0] == "extract" for e in events))

    def test_policy_loader_rejects_failed_completion_and_malformed_transport(self):
        packets = [
            (1, "[]"),
            (False, "[]"),
            (0, "not-json"),
            (0, "null"),
            (0, "[]"),
            (0, '[{"name":"x.zip","name":"y.zip","format":"zip"}]'),
            (0, '[{"name":"../x.zip","format":"zip"}]'),
            (0, '[{"name":"x.zip","format":"zip","future":1}]'),
            (0, '[{"name":"x.zip","format":"zip"},{"name":"x.zip","format":"zip"}]'),
        ]
        for code, output in packets:
            calls = []

            def execute(arguments, **keywords):
                calls.append(list(arguments))
                return subprocess.CompletedProcess(arguments, code, output, "private decoder text")

            with self.subTest(code=code, output=output), self.assertRaises(RuntimeError):
                observer.published_archive_bindings(execute)
            self.assertEqual(len(calls), 1)

    def test_policy_loader_throw_is_not_a_guessed_fallback(self):
        calls = []

        def execute(arguments, **keywords):
            calls.append(list(arguments))
            raise OSError("owned loader refused")

        with self.assertRaises(OSError):
            observer.published_archive_bindings(execute)
        self.assertEqual(len(calls), 1)

    @contextmanager
    def policy_fixture(self):
        """Give the actual Node owner an independent classified data fixture."""
        original_root = Path(observer.__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in (
                "tools/build/macos-release-archives.cjs",
                "tools/lib/paths.cjs",
                "static/ergopti_plus/_shared/modules/updater/defaults.json",
            ):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original_root / relative, target)
            config = root / "static/ergopti_plus/_shared/modules/updater/defaults.json"
            with patch.object(
                observer, "__file__", str(root / "tools/diagnostics/macos-release-launch.py")
            ):
                yield config

    def test_real_node_policy_refusal_does_not_return_local_defaults(self):
        with self.policy_fixture() as config:
            config.write_text('{"release_install":{"macos_archives":[]}}')
            with self.assertRaises(subprocess.CalledProcessError):
                observer.published_archive_bindings()

    def test_real_node_policy_order_is_consumed_instead_of_duplicated(self):
        with self.policy_fixture() as config:
            defaults = json.loads(config.read_text())
            defaults["release_install"]["macos_archives"].reverse()
            config.write_text(json.dumps(defaults))
            with self.fixture() as (root, destination, _, events, execute):
                result = self.install(root, destination, execute)
                self.assertEqual(result["format"], "zip")
                self.assertEqual([e[1] for e in events if e[0] == "download"], [self.ZIP])

    def test_real_node_bad_declared_filename_refuses_without_format_guessing(self):
        with self.policy_fixture() as config:
            defaults = json.loads(config.read_text())
            defaults["release_assets"]["macos_bundle_tar_xz"] = "../not-owned.tar.xz"
            config.write_text(json.dumps(defaults))
            with self.assertRaises(subprocess.CalledProcessError):
                observer.published_archive_bindings()

    # REST_DIGEST_NATIVE_TRANSPORT_TESTS_BEGIN
    def test_raw_rest_retains_digest_dropped_by_actual_old_cli_export(self):
        with self.fixture() as (root, destination, assets, events, execute):
            projected = {
                "tagName": self.TAG,
                "assets": [{"name": item["name"], "size": item["size"]} for item in assets],
            }
            observed = []

            def transport(arguments, **keywords):
                observed.append(list(arguments))
                if arguments[:3] == ["gh", "release", "view"]:
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(projected), "")
                return execute(arguments, **keywords)

            result = self.install(root, destination, transport)
            self.assertNotIn("digest", projected["assets"][0])
            self.assertEqual(result["asset"], assets[0])
            self.assertEqual(
                observed[1], ["gh", "api", f"repos/fixture/project/releases/tags/{self.TAG}"]
            )
            self.assertEqual([e[1] for e in events if e[0] == "download"], [self.XZ])

    def test_raw_api_identity_validation_occurs_before_any_owner_command(self):
        cases = [
            (None, self.TAG),
            (False, self.TAG),
            ("fixture", self.TAG),
            ("fixture/project/extra", self.TAG),
            ("fixture/project?query", self.TAG),
            ("fixture/project", None),
            ("fixture/project", False),
            ("fixture/project", ""),
        ]
        for repository, tag in cases:
            observed = []

            def transport(arguments, **keywords):
                observed.append(list(arguments))
                return subprocess.CompletedProcess(arguments, 0, "{}", "")

            with (
                self.subTest(repository=repository, tag=tag),
                self.assertRaisesRegex(RuntimeError, "identity"),
            ):
                observer.install_published_release(repository, tag, "/unused", "/unused", transport)
            self.assertEqual(observed, [])

    def test_raw_api_publication_and_tag_shape_refuses_without_download(self):
        for replacement in (
            {"draft": True},
            {"draft": None},
            {"draft": 0},
            {"draft": "false"},
            {"tag_name": None},
            {"tag_name": "foreign"},
            {"assets": None},
            {"assets": [None]},
        ):
            with (
                self.subTest(replacement=replacement),
                self.fixture() as (root, destination, assets, events, execute),
            ):
                raw = {"draft": False, "tag_name": self.TAG, "assets": assets, **replacement}
                observed = []

                def transport(arguments, **keywords):
                    if arguments[:2] == ["gh", "api"]:
                        observed.append(list(arguments))
                        return subprocess.CompletedProcess(arguments, 0, json.dumps(raw), "")
                    return execute(arguments, **keywords)

                with self.assertRaisesRegex(RuntimeError, "metadata"):
                    self.install(root, destination, transport)
                self.assertEqual(len(observed), 1)
                self.assertEqual(events, [])
                self.assertFalse((root / "release-download").exists())
                self.assertFalse((root / "release-provenance.json").exists())

    def test_raw_api_http_refusal_and_malformed_packets_have_no_fallback(self):
        for code, output in (
            (1, "{}"),
            (False, "{}"),
            (-15, "{}"),
            (0, "not-json"),
            (0, "null"),
            (0, '[{"draft":false}]'),
            (0, '{"draft":false,"draft":false}'),
        ):
            with (
                self.subTest(code=code, output=output),
                self.fixture() as (root, destination, _, events, execute),
            ):
                observed = []

                def transport(arguments, **keywords):
                    if arguments[:2] == ["gh", "api"]:
                        observed.append(list(arguments))
                        return subprocess.CompletedProcess(
                            arguments, code, output, "private packet"
                        )
                    return execute(arguments, **keywords)

                with self.assertRaises((RuntimeError, ValueError)):
                    self.install(root, destination, transport)
                self.assertEqual(len(observed), 1)
                self.assertEqual(events, [])
                self.assertFalse((root / "release-download").exists())
                self.assertFalse((root / "release-provenance.json").exists())

    def test_declared_size_is_strict_before_download_and_matches_private_bytes(self):
        for size in (None, False, 0, -1, 1.5, "19", 2**53, 1):
            with (
                self.subTest(size=size),
                self.fixture() as (root, destination, assets, events, execute),
            ):
                assets[0]["size"] = size
                with self.assertRaisesRegex(RuntimeError, "size"):
                    self.install(root, destination, execute)
                self.assertFalse(any(e[0] == "extract" for e in events))
                self.assertFalse((root / "release-provenance.json").exists())
                if size == 1 and type(size) is int:
                    self.assertEqual([e[1] for e in events if e[0] == "download"], [self.XZ])
                else:
                    self.assertFalse(any(e[0] == "download" for e in events))

    def test_raw_api_encoded_tag_preserves_exact_selected_provenance(self):
        tag = "v0.0.0-dev.999/owned-tag"
        with self.fixture() as (root, destination, assets, events, execute):
            observed = []

            def transport(arguments, **keywords):
                observed.append(list(arguments))
                if arguments[:2] == ["gh", "api"]:
                    raw = {"draft": False, "tag_name": tag, "assets": assets}
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(raw), "")
                return execute(arguments, **keywords)

            result = observer.install_published_release(
                "fixture/project", tag, root, destination, transport
            )
            self.assertEqual(
                observed[1],
                ["gh", "api", "repos/fixture/project/releases/tags/v0.0.0-dev.999%2Fowned-tag"],
            )
            self.assertEqual(result["tag"], tag)
            self.assertEqual(result["asset"], assets[0])
            self.assertEqual([e[1] for e in events if e[0] == "download"], [self.XZ])
            self.assertEqual(json.loads((root / "release-provenance.json").read_text()), result)

    # REST_DIGEST_NATIVE_TRANSPORT_TESTS_END


if __name__ == "__main__":
    unittest.main()
