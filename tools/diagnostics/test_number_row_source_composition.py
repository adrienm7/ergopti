"""New composition controls require real separately reviewed source inputs.

No synthetic G5/G6 postimage, commit, approval or native transcript is generated.
These controls cannot run until the genuine approved tuple and projection exist.
The original 53-control file and its historical oracle remain unchanged.
"""

import argparse
import copy
import hashlib
from types import ModuleType
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser(description=__doc__)
for name in (
    "repo",
    "recipe",
    "approval",
    "composition",
    "projection",
    "original-producer",
    "receiver",
    "positive-receiver",
    "receiving",
    "controls-projection",
):
    parser.add_argument("--" + name, type=Path, required=True)
for name in ("head", "approval-sha256", "composition-sha256"):
    parser.add_argument("--" + name, required=True)
args, unittest_args = parser.parse_known_args()
if not args.receiving.is_dir() or args.receiving.is_symlink():
    raise ValueError("owned receiving directory required")
admitted_images = {}
for name, path in (
    ("keyboard_geometry_xctest_receipt", args.positive_receiver),
    ("number_row_composition_under_test", args.receiver),
):
    expected = (
        "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094"
        if name == "keyboard_geometry_xctest_receipt"
        else "d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148"
    )
    data = path.read_bytes()
    if path.is_symlink() or not path.is_file() or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("explicit reviewed test dependency required")
    admitted_images[name] = data
positive_name = "keyboard_geometry_xctest_receipt"
missing = object()
previous = sys.modules.get(positive_name, missing)
positive = ModuleType(positive_name)
positive.__file__ = str(args.positive_receiver.resolve())
subject = ModuleType("number_row_composition_under_test")
subject.__file__ = str(args.receiver.resolve())
try:
    sys.modules[positive_name] = positive
    exec(compile(admitted_images[positive_name], positive.__file__, "exec"), positive.__dict__)
    exec(
        compile(admitted_images["number_row_composition_under_test"], subject.__file__, "exec"),
        subject.__dict__,
    )
finally:
    if previous is missing:
        sys.modules.pop(positive_name, None)
    else:
        sys.modules[positive_name] = previous
baseline = subject._closed_json(args.composition, args.composition_sha256)
approval = subject._closed_json(args.approval, args.approval_sha256)
active_auxiliary_path = (
    approval["approvals"][0]["path"] if "approvals" in approval else subject.AUXILIARY_PATH
)
original = args.original_producer.read_bytes()


class CompositionControls(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(dir=args.receiving)
        self.root = Path(self.owned.name)

    def tearDown(self):
        self.owned.cleanup()

    def contract_refuses(self, mutation):
        # Mutated inputs are explicitly negative controlled records. They never
        # replace the real independently reviewed baseline or authorize a run.
        changed = copy.deepcopy(baseline)
        mutation(changed)
        with self.assertRaises(ValueError):
            subject._composition_contract(args.recipe, args.approval, args.approval_sha256, changed)

    def projection_refuses(self, mutation):
        # One method can exercise multiple independent refusal variants.
        parent = Path(tempfile.mkdtemp(dir=self.root))
        projected = parent / "projection"
        shutil.copytree(args.projection, projected)
        mutation(projected)
        with self.assertRaises(ValueError):
            subject.verify_composed_projection(
                args.repo,
                args.head,
                args.recipe,
                args.approval,
                args.approval_sha256,
                args.composition,
                args.composition_sha256,
                projected,
                original,
            )

    def approval_refuses(self, mutation, join_git=False):
        changed = copy.deepcopy(approval)
        mutation(changed["approvals"][0] if "approvals" in changed else changed)
        path = self.root / "negative-approval.json"
        data = json.dumps(changed).encode()
        path.write_bytes(data)
        with self.assertRaises(ValueError):
            legacy, rejected, composition = subject._composition_contract(
                args.recipe, path, hashlib.sha256(data).hexdigest()
            )
            if join_git:
                subject._current_composition_inputs(
                    args.repo, args.head, legacy, rejected, composition
                )

    def test_actual_approved_current_composition(self):
        proof = subject.verify_composed_projection(
            args.repo,
            args.head,
            args.recipe,
            args.approval,
            args.approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            original,
        )
        self.assertEqual(proof["actual_commit"], args.head)
        self.assertEqual(len(proof["paths"]), 99)
        self.assertIs(proof["counterfactual_git_blob"], None)

    def test_historical_branch_still_refuses_new_auxiliary(self):
        with self.assertRaises(ValueError):
            subject.verify_projection(args.recipe, args.projection, original)

    def test_missing_path_refused(self):
        self.contract_refuses(lambda manifest: manifest["paths"].pop())

    def test_duplicate_path_refused(self):
        self.contract_refuses(
            lambda manifest: manifest["paths"].append(copy.deepcopy(manifest["paths"][0]))
        )

    def test_unknown_path_refused(self):
        self.contract_refuses(lambda manifest: manifest["paths"][0].update(path="unadmitted.swift"))

    def test_wrong_auxiliary_digest_refused(self):
        self.contract_refuses(
            lambda manifest: next(
                row for row in manifest["paths"] if row["path"] == active_auxiliary_path
            ).update(sha256="0" * 64)
        )

    def test_wrong_auxiliary_blob_refused(self):
        self.contract_refuses(
            lambda manifest: next(
                row for row in manifest["paths"] if row["path"] == active_auxiliary_path
            ).update(git_blob="0" * 40)
        )

    def test_second_auxiliary_or_package_change_refused(self):
        self.contract_refuses(
            lambda manifest: next(
                row for row in manifest["paths"] if row["path"].endswith("/Package.swift")
            ).update(sha256="0" * 64)
        )

    def test_producer_change_refused(self):
        self.contract_refuses(
            lambda manifest: next(
                row
                for row in manifest["paths"]
                if row["path"].endswith("/NumberRowSourceProbe.swift")
            ).update(sha256="0" * 64)
        )

    def test_test_and_embedded_glyph_oracle_change_refused(self):
        self.contract_refuses(
            lambda manifest: next(
                row
                for row in manifest["paths"]
                if row["path"].endswith("/NumberRowSourceProbeTests.swift")
            ).update(sha256="0" * 64)
        )

    def test_stale_source_commit_refused(self):
        with self.assertRaises(ValueError):
            subject.verify_composed_projection(
                args.repo,
                json.loads(args.recipe.read_bytes())["original_head"],
                args.recipe,
                args.approval,
                args.approval_sha256,
                args.composition,
                args.composition_sha256,
                args.projection,
                original,
            )

    def test_unknown_approval_digest_refused(self):
        with self.assertRaises(ValueError):
            subject._composition_contract(args.recipe, args.approval, "0" * 64, baseline)

    def test_wrong_original_blob_refused(self):
        self.approval_refuses(lambda record: record.update(original_git_blob="0" * 40))

    def test_wrong_original_digest_refused(self):
        self.approval_refuses(lambda record: record.update(original_sha256="0" * 64))

    def test_foreign_auxiliary_approval_refused(self):
        self.approval_refuses(lambda record: record.update(path="unadmitted.swift"))

    def test_wrong_new_committed_blob_refused(self):
        self.approval_refuses(lambda record: record.update(git_blob="0" * 40), join_git=True)

    def test_wrong_new_committed_digest_refused(self):
        self.approval_refuses(lambda record: record.update(sha256="0" * 64), join_git=True)

    def test_wrong_published_source_commit_refused(self):
        self.approval_refuses(
            lambda record: record.update(
                published_source_commit=json.loads(args.recipe.read_bytes())["original_head"]
            ),
            join_git=True,
        )

    def test_unclaimed_approval_fields_refused(self):
        self.approval_refuses(lambda record: record.update(native_ready=True))

    def test_altered_projection_refused(self):
        self.projection_refuses(
            lambda root: (root / active_auxiliary_path).write_bytes(b"unadmitted source\n")
        )

    def test_extra_projection_path_refused(self):
        self.projection_refuses(lambda root: (root / "unadmitted.swift").write_bytes(b"// extra\n"))

    def test_missing_projection_path_refused(self):
        self.projection_refuses(lambda root: (root / active_auxiliary_path).unlink())

    def test_source_symlink_refused(self):
        def replace(root):
            item = root / active_auxiliary_path
            item.unlink()
            item.symlink_to(args.repo / active_auxiliary_path)

        self.projection_refuses(replace)

    def test_second_or_missing_omission_refused(self):
        path = json.loads(args.recipe.read_bytes())["permitted_omission"]["path"]
        self.projection_refuses(lambda root: (root / path).write_bytes(original))
        self.projection_refuses(
            lambda root: (root / path).write_bytes(
                original.replace(subject.NEEDLE, b"true", 1) + b"\n// second alteration\n"
            )
        )

    def approval_list_refuses(self, mutation, join_git=False):
        changed = copy.deepcopy(approval)
        if "approvals" not in changed:
            raise ValueError("new list controls require genuine independently reviewed list")
        mutation(changed)
        path = self.root / "negative-approval-list.json"
        data = json.dumps(changed).encode()
        path.write_bytes(data)
        with self.assertRaises(ValueError):
            legacy, rejected, composition = subject._composition_contract(
                args.recipe, path, hashlib.sha256(data).hexdigest()
            )
            if join_git:
                subject._current_composition_inputs(
                    args.repo, args.head, legacy, rejected, composition
                )

    def test_received_two_row_g5_source_list(self):
        self.assertEqual(approval["role"], "independently-reviewed-committed-source-inputs")
        self.assertEqual(len(approval["approvals"]), 2)
        self.assertEqual(
            {row["path"] for row in approval["approvals"]},
            {
                "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift",
                "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/RemapLeaseWorkerTests.swift",
            },
        )
        proof = subject.verify_composed_projection(
            args.repo,
            args.head,
            args.recipe,
            args.approval,
            args.approval_sha256,
            args.composition,
            args.composition_sha256,
            args.projection,
            original,
        )
        self.assertEqual(
            proof["approved_auxiliary_sources"],
            [
                {
                    "path": row["path"],
                    "published_source_commit": row["published_source_commit"],
                    "git_blob": row["git_blob"],
                    "sha256": row["sha256"],
                    "source_review_sha256": row["source_review_sha256"],
                }
                for row in approval["approvals"]
            ],
        )
        historical = json.loads(args.recipe.read_bytes())["paths"]
        approved_paths = {row["path"] for row in approval["approvals"]}
        self.assertEqual(
            [row for row in baseline["paths"] if row["path"] not in approved_paths],
            [row for row in historical if row["path"] not in approved_paths],
        )
        self.assertEqual(
            len([row for row in baseline["paths"] if row["path"] not in approved_paths]), 97
        )

    def test_empty_source_list_refused(self):
        self.approval_list_refuses(lambda envelope: envelope.update(approvals=[]))

    def test_duplicate_source_list_row_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"].append(copy.deepcopy(envelope["approvals"][0]))
        )

    def test_four_source_list_rows_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope.update(approvals=envelope["approvals"] * 2)
        )

    def test_unknown_envelope_field_refused(self):
        self.approval_list_refuses(lambda envelope: envelope.update(native_ready=True))

    def test_boolean_envelope_schema_refused(self):
        self.approval_list_refuses(lambda envelope: envelope.update(schema=True))

    def test_missing_g5_source_approval_refuses_actual_input(self):
        self.approval_list_refuses(lambda envelope: envelope["approvals"].pop(), join_git=True)

    def test_missing_first_g5_source_approval_refuses_actual_input(self):
        self.approval_list_refuses(lambda envelope: envelope["approvals"].pop(0), join_git=True)

    def test_second_source_original_blob_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"][1].update(original_git_blob="0" * 40)
        )

    def test_second_source_original_digest_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"][1].update(original_sha256="0" * 64)
        )

    def test_second_source_committed_blob_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"][1].update(git_blob="0" * 40), join_git=True
        )

    def test_second_source_committed_digest_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"][1].update(sha256="0" * 64), join_git=True
        )

    def test_second_source_commit_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"][1].update(
                published_source_commit=json.loads(args.recipe.read_bytes())["original_head"]
            ),
            join_git=True,
        )

    def test_missing_source_review_digest_refused(self):
        self.approval_list_refuses(
            lambda envelope: envelope["approvals"][1].pop("source_review_sha256")
        )

    def test_unreceived_third_managed_http_tuple_refused(self):
        def add(envelope):
            row = copy.deepcopy(envelope["approvals"][0])
            row["path"] = subject.AUXILIARY_PATH
            envelope["approvals"].append(row)

        self.approval_list_refuses(add)

    def test_number_row_producer_approval_refused(self):
        path = json.loads(args.recipe.read_bytes())["permitted_omission"]["path"]
        self.approval_list_refuses(lambda envelope: envelope["approvals"][1].update(path=path))

    def test_number_row_test_oracle_approval_refused(self):
        path = json.loads(args.recipe.read_bytes())["original_test_source_unchanged"]
        self.approval_list_refuses(lambda envelope: envelope["approvals"][1].update(path=path))

    def test_package_source_approval_refused(self):
        path = next(
            row["path"] for row in baseline["paths"] if row["path"].endswith("/Package.swift")
        )
        self.approval_list_refuses(lambda envelope: envelope["approvals"][1].update(path=path))

    def test_reordered_or_reduced_approval_bytes_refused_by_received_digest(self):
        changed = copy.deepcopy(approval)
        changed["approvals"].reverse()
        path = self.root / "unreceived-envelope.json"
        path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            subject._composition_contract(args.recipe, path, args.approval_sha256, baseline)
        changed["approvals"].pop()
        path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            subject._composition_contract(args.recipe, path, args.approval_sha256, baseline)

    def test_second_source_projection_alteration_refused(self):
        path = approval["approvals"][1]["path"]
        self.projection_refuses(
            lambda root: (root / path).write_bytes(b"unadmitted second source\n")
        )

    def test_original_legacy_single_record_branch_retained(self):
        old = next(
            row
            for row in json.loads(args.recipe.read_bytes())["paths"]
            if row["path"] == subject.AUXILIARY_PATH
        )
        negative = {
            "schema": 1,
            "role": "independently-reviewed-committed-source-input",
            "path": subject.AUXILIARY_PATH,
            "original_git_blob": old["git_blob"],
            "original_sha256": old["sha256"],
            "published_source_commit": args.head,
            "git_blob": old["git_blob"],
            "sha256": old["sha256"],
            "source_review_sha256": "0" * 64,
        }
        path = self.root / "legacy-unchanged-negative.json"
        data = json.dumps(negative).encode()
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "unchanged input is not a new composition"):
            subject._composition_contract(args.recipe, path, hashlib.sha256(data).hexdigest())

    def test_historical_controls_projection_preserves_original_99(self):
        proof = subject.verify_projection(args.recipe, args.controls_projection, original)
        self.assertIs(proof["counterfactual_git_blob"], None)
        recipe = json.loads(args.recipe.read_bytes())
        producer = recipe["permitted_omission"]["path"]
        actual_paths = {
            item.relative_to(args.controls_projection).as_posix()
            for item in args.controls_projection.rglob("*")
            if item.is_file()
        }
        self.assertEqual(actual_paths, {row["path"] for row in recipe["paths"]})
        self.assertEqual(len(actual_paths), 99)
        for row in recipe["paths"]:
            data = (args.controls_projection / row["path"]).read_bytes()
            expected = (
                hashlib.sha256(original.replace(subject.NEEDLE, b"true", 1)).hexdigest()
                if row["path"] == producer
                else row["sha256"]
            )
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected)
        for row in approval["approvals"]:
            self.assertNotEqual(
                (args.controls_projection / row["path"]).read_bytes(),
                (args.projection / row["path"]).read_bytes(),
            )

    def test_historical_controls_cannot_be_used_as_current_native_projection(self):
        with self.assertRaises(ValueError):
            subject.verify_composed_projection(
                args.repo,
                args.head,
                args.recipe,
                args.approval,
                args.approval_sha256,
                args.composition,
                args.composition_sha256,
                args.controls_projection,
                original,
            )

    def test_current_native_projection_cannot_be_used_as_historical_controls(self):
        with self.assertRaises(ValueError):
            subject.verify_projection(args.recipe, args.projection, original)

    def test_historical_control_destination_overlap_refused(self):
        with self.assertRaises(ValueError):
            subject.materialize_historical_controls(
                args.repo,
                args.head,
                args.recipe,
                args.approval,
                args.approval_sha256,
                args.composition,
                args.composition_sha256,
                self.root,
                self.root,
                args.projection,
            )

    def test_occupied_historical_control_destination_refused(self):
        destination = self.root / "occupied"
        destination.mkdir()
        (destination / "owned.txt").write_text("occupied")
        with self.assertRaises(ValueError):
            subject.materialize_historical_controls(
                args.repo,
                args.head,
                args.recipe,
                args.approval,
                args.approval_sha256,
                args.composition,
                args.composition_sha256,
                destination,
                self.root,
                args.projection,
            )

    def test_historical_control_destination_symlink_refused(self):
        destination = self.root / "linked"
        destination.symlink_to(args.controls_projection, target_is_directory=True)
        with self.assertRaises(ValueError):
            subject.materialize_historical_controls(
                args.repo,
                args.head,
                args.recipe,
                args.approval,
                args.approval_sha256,
                args.composition,
                args.composition_sha256,
                destination,
                self.root,
                args.projection,
            )


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
