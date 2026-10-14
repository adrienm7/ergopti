"""Controlled software-only four-role source contracts, never source approval.

The local envelope uses plainly controlled review digests. No Git source,
external independent review, native execution, or TIS receipt is synthesized.
The original 53/51 files are separate, unchanged historical lanes.
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import ModuleType
import unittest
from unittest.mock import patch
from contextlib import ExitStack
import os
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
for name in (
    "receiver",
    "core-receiver",
    "positive-receiver",
    "recipe",
    "base-approval",
    "network-approval",
    "historical-network-approval",
    "receiving",
):
    parser.add_argument("--" + name, type=Path, required=True)
args, remaining = parser.parse_known_args()
if args.receiving.is_symlink() or not args.receiving.is_dir():
    raise ValueError("explicit owned receiving directory required")
images = {}
for name, path, expected in (
    ("subject", args.receiver, "b7ffb22ae11d1414cf465f55eb6a97e58f9badde6e96a804d64bc8ef7b683754"),
    (
        "core",
        args.core_receiver,
        "d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148",
    ),
    (
        "positive",
        args.positive_receiver,
        "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094",
    ),
    ("recipe", args.recipe, "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba"),
    (
        "base",
        args.base_approval,
        "47b2dc03e558db6418234ab6c69a279cc91fd9c29bc587505e13ea0989764549",
    ),
    (
        "authentic_network",
        args.network_approval,
        "6f313f6afb2f6bee59a9c8e5a728c0d12b8f765dd8af9bff029595faea4aef6c",
    ),
    (
        "historical_network",
        args.historical_network_approval,
        "3c499a617641770276cecbbbc454c0227970d60e66b31fd641f14b527f0201e2",
    ),
):
    data = path.read_bytes()
    if path.is_symlink() or not path.is_file() or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("exact independently pinned control dependency required")
    images[name] = data
positive_name = "keyboard_geometry_xctest_receipt"
missing = object()
previous = sys.modules.get(positive_name, missing)
positive = ModuleType(positive_name)
positive.__file__ = str(args.positive_receiver)
subject = ModuleType("current_network_controls")
subject.__file__ = str(args.receiver)
core = ModuleType("unchanged_core_for_controlled_tests")
core.__file__ = str(args.core_receiver)
try:
    sys.modules[positive_name] = positive
    exec(compile(images["positive"], positive.__file__, "exec"), positive.__dict__)
    exec(compile(images["core"], core.__file__, "exec"), core.__dict__)
    exec(compile(images["subject"], subject.__file__, "exec"), subject.__dict__)
finally:
    if previous is missing:
        sys.modules.pop(positive_name, None)
    else:
        sys.modules[positive_name] = previous

BASE_SHA = "47b2dc03e558db6418234ab6c69a279cc91fd9c29bc587505e13ea0989764549"
# These tuples are literal independent e941 committed source receiving facts. The
# controlled review field below is not an authentic Root/G6 approval.
ROLES = (
    (
        "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapDownload.swift",
        "980c261c18fd417f896efda44590e3fe4881b419",
        "b0c188bfd62d65336c041183c312c94a7d042d8c38d65f2d9a61469a7aa5b0ad",
        "4485baa5f97fc6232417742976f0e30426e43311",
        "de611cc1f0ae94beb20930ccb7e76e8a21ea1bc488c6dae94802298b47a90b94",
    ),
    (
        "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift",
        "e17ff5af9c971d32d2a3536693f93a4e02e634cd",
        "0650c5f3c6ab64b79f324dcf07331286a2c7710fec2734fec93c8d800cddd624",
        "2887593d22dfd7c5d5280a31f1210f4a7152b6f7",
        "ab575a32abf59d0258c393509ca8f1067885338e655f5e53f523efc0e4f55a77",
    ),
    (
        "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedBootstrapDownloadTests.swift",
        "a36a7cb184fad53e0dd44844f912e0b4ad96c2ad",
        "50c0ccd4135112ac43c65efe3db33664b624326966e3488f793ed4468075cebb",
        "dc6314036b8d9916c67d74b42c2c30653b89c653",
        "64966864219c3ac4d360f4e6e9641e15b5ab88515874dcab1806ccc83bff230f",
    ),
    (
        "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedHTTPWorkerTests.swift",
        "1b2f96dc1e9c29b5a79d8eba05d03fa0eca0b9e6",
        "ef4882cc6ac6a7c578e756405cb4ae77f0f80243e96e6417f4fff69be2b54243",
        "6b5960985c4ff5f28297ec0eeb4d2318fb6659be",
        "774549205624192feaebad02234887e1b0a418504dca95e9253cf222d79af03c",
    ),
)


class CurrentNetworkControls(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(dir=args.receiving)
        self.root = Path(self.owned.name)
        self.network = {
            "schema": 1,
            "role": "independently-reviewed-committed-source-inputs",
            "approvals": [
                {
                    "schema": 1,
                    "role": "independently-reviewed-committed-source-input",
                    "path": path,
                    "original_git_blob": old_blob,
                    "original_sha256": old_sha,
                    "published_source_commit": "e94153e87b698b24de86133239319bde4be12a90",
                    "git_blob": blob,
                    "sha256": digest,
                    "source_review_sha256": "c" * 64,
                }
                for path, old_blob, old_sha, blob, digest in ROLES
            ],
        }

    def tearDown(self):
        self.owned.cleanup()

    def envelope(self, value=None):
        path = self.root / "controlled-network-approval.json"
        data = (json.dumps(self.network if value is None else value) + "\n").encode()
        path.write_bytes(data)
        return path, hashlib.sha256(data).hexdigest()

    def contract(self, value=None, composition=None):
        path, digest = self.envelope(value)
        return subject._current_network_contract(
            core, args.recipe, args.base_approval, BASE_SHA, path, digest, composition
        )

    def refuse(self, mutate):
        changed = copy.deepcopy(self.network)
        mutate(changed)
        with self.assertRaises(ValueError):
            self.contract(changed)

    def test_exact_four_roles_and_ninety_five_original_rows(self):
        legacy, combined, actual = self.contract()
        original = json.loads(images["recipe"])
        base = json.loads(images["base"])
        replacements = {r["path"]: r for r in base["approvals"]}
        replacements.update({p: {"git_blob": b, "sha256": s} for p, _, _, b, s in ROLES})
        independent_rows = [dict(row) for row in original["paths"]]
        unchanged = 0
        for row in independent_rows:
            if row["path"] in replacements:
                row.update(
                    git_blob=replacements[row["path"]]["git_blob"],
                    sha256=replacements[row["path"]]["sha256"],
                )
            else:
                unchanged += 1
        self.assertEqual(unchanged, 93)
        self.assertEqual(len(actual["paths"]), 99)
        self.assertEqual(actual["paths"], independent_rows)
        self.assertEqual(len(combined["approvals"]), 6)
        self.assertEqual(legacy, original)
        self.assertEqual(actual["schema"], 2)
        self.assertEqual(
            actual["role"],
            "reviewed-current-network-build-input-composition-not-native-qualification",
        )

    def test_missing_network_role_refused(self):
        self.refuse(lambda x: x["approvals"].pop())

    def test_duplicate_network_role_refused(self):
        self.refuse(lambda x: x["approvals"].__setitem__(1, copy.deepcopy(x["approvals"][0])))

    def test_swapped_network_role_order_refused(self):
        self.refuse(lambda x: x["approvals"].reverse())

    def test_foreign_role_with_valid_source_tuple_refused(self):
        self.refuse(
            lambda x: x["approvals"][0].__setitem__(
                "path", "static/ergopti_plus/macos/launcher/Package.swift"
            )
        )

    def test_changed_network_postimage_refused(self):
        self.refuse(lambda x: x["approvals"][0].__setitem__("sha256", "d" * 64))

    def test_changed_network_predecessor_refused(self):
        self.refuse(lambda x: x["approvals"][0].__setitem__("original_git_blob", "d" * 40))

    def test_missing_external_review_identity_refused(self):
        self.refuse(lambda x: x["approvals"][0].pop("source_review_sha256"))

    def test_malformed_external_review_identity_refused(self):
        self.refuse(
            lambda x: x["approvals"][0].__setitem__(
                "source_review_sha256", "controlled-not-a-digest"
            )
        )

    def test_malformed_published_source_identity_refused(self):
        self.refuse(
            lambda x: x["approvals"][0].__setitem__("published_source_commit", "not-a-Git-commit")
        )

    def test_float_envelope_schema_refused(self):
        self.refuse(lambda x: x.__setitem__("schema", 1.0))

    def test_float_row_schema_refused(self):
        self.refuse(lambda x: x["approvals"][0].__setitem__("schema", 1.0))

    def test_extra_approval_field_refused(self):
        self.refuse(lambda x: x["approvals"][0].__setitem__("native_qualified", True))

    def test_wrong_external_envelope_digest_refused_before_git(self):
        path, _ = self.envelope()
        with patch.object(core, "_current_composition_inputs") as current:
            with self.assertRaises(ValueError):
                subject.create_current_network_composition(
                    core,
                    self.root,
                    "a" * 40,
                    args.recipe,
                    args.base_approval,
                    BASE_SHA,
                    path,
                    "0" * 64,
                )
            current.assert_not_called()

    def test_wrong_base_digest_refused_before_git(self):
        path, digest = self.envelope()
        with patch.object(core, "_current_composition_inputs") as current:
            with self.assertRaises(ValueError):
                subject.create_current_network_composition(
                    core,
                    self.root,
                    "a" * 40,
                    args.recipe,
                    args.base_approval,
                    "0" * 64,
                    path,
                    digest,
                )
            current.assert_not_called()

    def test_different_valid_base_envelope_refused(self):
        changed = json.loads(images["base"])
        changed["approvals"][0]["source_review_sha256"] = "d" * 64
        path = self.root / "controlled-different-base.json"
        data = json.dumps(changed).encode()
        path.write_bytes(data)
        network, digest = self.envelope()
        with self.assertRaises(ValueError):
            subject._current_network_contract(
                core, args.recipe, path, hashlib.sha256(data).hexdigest(), network, digest
            )

    def test_float_composition_schema_refused(self):
        _, _, composition = self.contract()
        composition["schema"] = 2.0
        with self.assertRaises(ValueError):
            self.contract(composition=composition)

    def test_changed_fifth_input_refused(self):
        _, _, composition = self.contract()
        path = "static/ergopti_plus/macos/launcher/Package.swift"
        row = next(r for r in composition["paths"] if r["path"] == path)
        row["sha256"] = "d" * 64
        with self.assertRaises(ValueError):
            self.contract(composition=composition)

    def test_all_four_roles_reach_unchanged_git_admission_once(self):
        path, digest = self.envelope()
        with patch.object(
            core,
            "_current_composition_inputs",
            side_effect=ValueError("controlled-stop-before-Git"),
        ) as current:
            with self.assertRaisesRegex(ValueError, "controlled-stop-before-Git"):
                subject.create_current_network_composition(
                    core,
                    self.root,
                    "a" * 40,
                    args.recipe,
                    args.base_approval,
                    BASE_SHA,
                    path,
                    digest,
                )
            self.assertEqual(current.call_count, 1)
            self.assertEqual(len(current.call_args.args[3]["approvals"]), 6)

    def test_legacy_contract_still_refuses_network_envelope(self):
        path, digest = self.envelope()
        with self.assertRaises(ValueError):
            core._composition_contract(args.recipe, path, digest)

    def test_legacy_two_role_contract_retains_original_schema(self):
        _, approval, composition = core._composition_contract(
            args.recipe, args.base_approval, BASE_SHA
        )
        self.assertEqual(len(approval["approvals"]), 2)
        self.assertEqual(composition["schema"], 1)
        self.assertNotIn("network_source_approval_sha256", composition)

    def command(self, mode):
        # This directory shape is expressly controlled, not a Git checkout.
        # load_core is stopped/modeled below; no ancestry is manufactured.
        repo = self.root / "controlled-directory"
        repo.mkdir()
        helper = repo / "tools/diagnostics/number_row_current_network_causal.py"
        helper.parent.mkdir(parents=True)
        helper.write_bytes(images["subject"])
        self.repo = repo
        self.receipt = self.root / "native-receipt.json"
        self.output = self.root / "generated.json"
        self.projection = self.root / "projection"
        self.evidence = self.root / "evidence"
        path, digest = self.envelope()
        argv = [
            "controlled-companion",
            "--head",
            "a" * 40,
            "--companion-sha256",
            "b7ffb22ae11d1414cf465f55eb6a97e58f9badde6e96a804d64bc8ef7b683754",
            mode,
            "--recipe",
            str(args.recipe),
            "--base-approval",
            str(args.base_approval),
            "--base-approval-sha256",
            BASE_SHA,
            "--network-approval",
            str(path),
            "--network-approval-sha256",
            digest,
        ]
        if mode == "generate":
            argv += ["--output", str(self.output)]
        else:
            argv += [
                "--composition",
                str(self.root / "composition"),
                "--composition-sha256",
                "d" * 64,
                "--projection",
                str(self.projection),
            ]
        if mode == "materialize":
            argv += ["--evidence", str(self.evidence)]
        if mode == "receive":
            self.projection.mkdir()
            original = self.root / "original"
            original.write_bytes(b"controlled-source")
            test = self.root / "controlled-test"
            test.write_bytes(b"controlled-test-source")
            test_path = json.loads(images["recipe"])["original_test_source_unchanged"]
            projected = self.projection / test_path
            projected.parent.mkdir(parents=True)
            projected.write_bytes(test.read_bytes())
            transport = self.root / "transport"
            # Actual unchanged transport bytes are required separately by the
            # command. This control stops before that native port by default.
            self.transport = transport
            for name, value in (
                ("original-producer", original),
                ("test-source", test),
                ("log", self.root / "log"),
                ("transport", transport),
                ("tis-root", self.root / "tis"),
                ("receipt", self.receipt),
                ("tis-stdout", self.root / "tis.stdout"),
                ("tis-stderr", self.root / "tis.stderr"),
                ("node", self.root / "not-a-native-node"),
            ):
                argv += ["--" + name, str(value)]
            argv += ["--session", "controlled", "--swift-exit", "1", "--capture-exit", "1"]
        return argv, helper

    def invoke(self, argv, helper, stack):
        old_cwd = Path.cwd()
        try:
            os.chdir(self.repo)
            stack.enter_context(patch.object(sys, "argv", argv))
            stack.enter_context(patch.object(subject, "__file__", str(helper)))
            return subject.main()
        finally:
            os.chdir(old_cwd)

    def test_generate_cli_reaches_only_closed_generator(self):
        argv, helper = self.command("generate")
        with ExitStack() as stack:
            loader = stack.enter_context(
                patch.object(subject, "load_core", return_value=(core, {}))
            )
            generator = stack.enter_context(
                patch.object(
                    subject,
                    "create_current_network_composition",
                    side_effect=ValueError("controlled-generator-entry"),
                )
            )
            native = stack.enter_context(
                patch.object(
                    subject.subprocess,
                    "run",
                    side_effect=AssertionError("no native port permitted"),
                )
            )
            with self.assertRaisesRegex(ValueError, "controlled-generator-entry"):
                self.invoke(argv, helper, stack)
            self.assertEqual(loader.call_count, 1)
            self.assertEqual(generator.call_count, 1)
            native.assert_not_called()
            self.assertFalse(self.output.exists())

    def test_materialize_cli_reaches_only_closed_materializer(self):
        argv, helper = self.command("materialize")
        with ExitStack() as stack:
            stack.enter_context(patch.object(subject, "load_core", return_value=(core, {})))
            materializer = stack.enter_context(
                patch.object(
                    subject,
                    "materialize_current_network_projection",
                    side_effect=ValueError("controlled-materializer-entry"),
                )
            )
            native = stack.enter_context(
                patch.object(
                    subject.subprocess,
                    "run",
                    side_effect=AssertionError("no native port permitted"),
                )
            )
            with self.assertRaisesRegex(ValueError, "controlled-materializer-entry"):
                self.invoke(argv, helper, stack)
            self.assertEqual(materializer.call_count, 1)
            native.assert_not_called()
            self.assertFalse(self.evidence.exists())

    def test_receive_cli_proves_source_before_native_port(self):
        argv, helper = self.command("receive")
        with ExitStack() as stack:
            stack.enter_context(patch.object(subject, "load_core", return_value=(core, {})))
            verifier = stack.enter_context(
                patch.object(
                    subject,
                    "verify_current_network_projection",
                    side_effect=ValueError("controlled-source-entry"),
                )
            )
            native = stack.enter_context(
                patch.object(
                    subject.subprocess,
                    "run",
                    side_effect=AssertionError("no native port permitted"),
                )
            )
            status = self.invoke(argv, helper, stack)
            self.assertEqual(status, 1)
            self.assertEqual(verifier.call_count, 1)
            self.assertEqual(
                json.loads(self.receipt.read_bytes())["reason"], "controlled-source-entry"
            )
            native.assert_not_called()

    def test_missing_network_cli_port_refuses_before_loader(self):
        argv, helper = self.command("generate")
        index = argv.index("--network-approval-sha256")
        del argv[index : index + 2]
        with ExitStack() as stack:
            loader = stack.enter_context(patch.object(subject, "load_core"))
            with self.assertRaises(SystemExit) as refused:
                self.invoke(argv, helper, stack)
            self.assertEqual(refused.exception.code, 2)
            loader.assert_not_called()
            self.assertFalse(self.output.exists())

    def test_authentic_g6_envelope_contract_before_git(self):
        # These are the received owner bytes, not a generated control envelope.
        network = json.loads(images["authentic_network"])
        self.assertEqual(network["role"], "independently-reviewed-committed-source-inputs")
        self.assertEqual(
            [row["source_review_sha256"] for row in network["approvals"]],
            ["8ef6ba2dcea1a5fd83aa42081cc6b4a785423c5b82298bdee4e50fd61f20a9aa"] * 4,
        )
        self.assertEqual(
            [row["published_source_commit"] for row in network["approvals"]],
            ["e94153e87b698b24de86133239319bde4be12a90"] * 4,
        )
        self.assertEqual(
            [
                (
                    row["path"],
                    row["original_git_blob"],
                    row["original_sha256"],
                    row["git_blob"],
                    row["sha256"],
                )
                for row in network["approvals"]
            ],
            list(ROLES),
        )
        with (
            patch.object(
                core,
                "_current_composition_inputs",
                side_effect=AssertionError("unexpected Git admission"),
            ) as current,
            patch.object(
                core, "_git_input", side_effect=AssertionError("unexpected Git read")
            ) as git,
        ):
            legacy, combined, composition = subject._current_network_contract(
                core,
                args.recipe,
                args.base_approval,
                BASE_SHA,
                args.network_approval,
                "6f313f6afb2f6bee59a9c8e5a728c0d12b8f765dd8af9bff029595faea4aef6c",
            )
            self.assertEqual(combined["approvals"][2:], network["approvals"])
            self.assertEqual(len(combined["approvals"]), 6)
            self.assertEqual(
                composition["network_source_approval_sha256"],
                "6f313f6afb2f6bee59a9c8e5a728c0d12b8f765dd8af9bff029595faea4aef6c",
            )
            replacements = {row["path"] for row in combined["approvals"]}
            unchanged = [row for row in legacy["paths"] if row["path"] not in replacements]
            self.assertEqual(len(unchanged), 93)
            self.assertEqual(len(composition["paths"]), 99)
            self.assertEqual(
                [row for row in composition["paths"] if row["path"] not in replacements], unchanged
            )
            current.assert_not_called()
            git.assert_not_called()

    def refused_current_input_before_git(self, network):
        path, digest = self.envelope(network)
        with patch.object(core, "_current_composition_inputs") as current:
            with self.assertRaises(ValueError):
                subject.create_current_network_composition(
                    core,
                    self.root,
                    "a" * 40,
                    args.recipe,
                    args.base_approval,
                    BASE_SHA,
                    path,
                    digest,
                )
            current.assert_not_called()

    def test_authentic_historical_http2_envelope_refused_before_git(self):
        with patch.object(core, "_current_composition_inputs") as current:
            with self.assertRaises(ValueError):
                subject.create_current_network_composition(
                    core,
                    self.root,
                    "a" * 40,
                    args.recipe,
                    args.base_approval,
                    BASE_SHA,
                    args.historical_network_approval,
                    "3c499a617641770276cecbbbc454c0227970d60e66b31fd641f14b527f0201e2",
                )
            current.assert_not_called()

    def test_http4_worker_cannot_borrow_historical_postimage(self):
        changed = copy.deepcopy(self.network)
        old = json.loads(images["historical_network"])["approvals"][0]
        changed["approvals"][1]["git_blob"] = old["git_blob"]
        changed["approvals"][1]["sha256"] = old["sha256"]
        self.refused_current_input_before_git(changed)

    def test_http4_worker_tests_cannot_borrow_historical_postimage(self):
        changed = copy.deepcopy(self.network)
        old = json.loads(images["historical_network"])["approvals"][1]
        changed["approvals"][3]["git_blob"] = old["git_blob"]
        changed["approvals"][3]["sha256"] = old["sha256"]
        self.refused_current_input_before_git(changed)

    def test_http4_bootstrap_current_postimage_refused_before_git(self):
        changed = copy.deepcopy(self.network)
        changed["approvals"][0]["sha256"] = "d" * 64
        self.refused_current_input_before_git(changed)

    def test_http4_bootstrap_tests_current_postimage_refused_before_git(self):
        changed = copy.deepcopy(self.network)
        changed["approvals"][2]["sha256"] = "d" * 64
        self.refused_current_input_before_git(changed)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *remaining])
