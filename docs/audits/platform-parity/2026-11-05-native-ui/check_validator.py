"""Exercise metadata guards by mutating parsed values only; never edit evidence."""

import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

path = Path(__file__).resolve().with_name("validate.py")
spec = importlib.util.spec_from_file_location("audit_validation", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_load, original_text = module.load, module.read_text
baseline_output = io.StringIO()
with contextlib.redirect_stdout(baseline_output):
    module.main()
baseline_index = original_load(module.DIRECTORY / "index.json")
target_scope = next(scope["scope"] for scope in baseline_index["scopes"] if scope["ids"])
cases = []


def first_finding(path, data, mutate):
    if path.name == "findings.json" and path.parent.name == target_scope:
        mutate(data["findings"][0])
    return data


def check(name, corrupt=None, corrupt_text=None, refused=True):
    def load(candidate):
        data = copy.deepcopy(original_load(candidate))
        return corrupt(candidate, data) if corrupt else data

    def read_text(candidate):
        text = original_text(candidate)
        return corrupt_text(candidate, text) if corrupt_text else text

    module.load, module.read_text = load, read_text
    try:
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                module.main()
        except AssertionError:
            assert refused, "positive control rejected " + name
        else:
            assert not refused, "negative control accepted " + name
        cases.append({"case": name, "refused": refused})
    finally:
        module.load, module.read_text = original_load, original_text


def index_field(field, value):
    def corrupt(path, data):
        if path.name == "index.json":
            data[field] = value
        return data

    return corrupt


check("invalid-source-identity", index_field("audited_sha", "not-a-commit"))
check("wrong-revision-even-if-well-formed", index_field("audited_sha", "0" * 40))
check("wrong-campaign-date", index_field("created_at", "2026-11-04"))


def duplicate_scope(path, data):
    if path.name == "index.json":
        data["scopes"][1] = copy.deepcopy(data["scopes"][0])
    return data


check("duplicate-os-module-scope", duplicate_scope)


def missing_ids(path, data):
    if path.name == "index.json":
        next(scope for scope in data["scopes"] if scope["scope"] == target_scope)["ids"] = []
    return data


check("manifest-id-missing-from-authoritative-index", missing_ids)


def duplicate_id(path, data):
    if path.name == "findings.json" and path.parent.name == target_scope:
        data["findings"].append(copy.deepcopy(data["findings"][0]))
    return data


check("duplicate-finding-id", duplicate_id)


def mutate_finding(name, mutate):
    check(name, lambda path, data: first_finding(path, data, mutate))


mutate_finding("invalid-severity", lambda row: row.update(severity="important"))
mutate_finding("invalid-confidence", lambda row: row.update(confidence="certain"))
mutate_finding("empty-root-cause", lambda row: row.update(root_cause="  "))
mutate_finding("unknown-guarantee", lambda row: row.update(guarantees=["G6"]))
mutate_finding("duplicate-guarantee", lambda row: row.update(guarantees=["G2", "G2"]))
mutate_finding(
    "malformed-additional-properties",
    lambda row: row.update(additional_properties={"wrong": "container"}),
)


def unclassified(row):
    row["guarantees"] = []
    row.pop("additional_property", None)
    row.pop("additional_properties", None)


mutate_finding("unclassified-additional-property", unclassified)
mutate_finding("missing-native-limits", lambda row: row.update(basis={"kind": "modeled"}))
mutate_finding("wrong-source-report", lambda row: row.update(source_report="missing/report.md"))
mutate_finding("missing-evidence-list", lambda row: row.update(evidence=[]))
mutate_finding(
    "missing-evidence-file", lambda row: row.update(evidence=["logs/absent-negative-control.log"])
)
mutate_finding("evidence-parent-escape", lambda row: row.update(evidence=["../report.md"]))
mutate_finding(
    "evidence-absolute-escape", lambda row: row.update(evidence=[str(module.ROOT / "TODO.md")])
)
mutate_finding(
    "evidence-unportable-backslash", lambda row: row.update(evidence=["logs\\receipt.log"])
)
mutate_finding("evidence-path-duplicate", lambda row: row.update(evidence=[row["evidence"][0]] * 2))


for excluded in sorted(module.EXCLUDED_IDS):
    scope_name = "linux-webview" if excluded.startswith("LVB") else "macos-runtime"

    def resurrect(path, data, excluded=excluded, scope_name=scope_name):
        if path.name == "findings.json" and path.parent.name == scope_name:
            data["findings"][0]["id"] = excluded
        return data

    check("excluded-disposition-" + excluded, resurrect)


def missing_capability_evidence(path, data):
    if path.name == "capabilities.json":
        data["capabilities"][0]["evidence_reports"] = ["missing/report.md"]
    return data


check("missing-capability-evidence-report", missing_capability_evidence)


def wrong_capability_revision(path, data):
    if path.name == "capabilities.json":
        data["audited_sha"] = "0" * 40
    return data


check("capability-revision-mismatch", wrong_capability_revision)


def foreign_shared_id(path, data):
    if path.name == "index.json":
        data["shared_mechanisms"] = {"negative-control": ["FOREIGN-999"]}
    return data


check("shared-group-foreign-id", foreign_shared_id)
check(
    "canonical-id-missing-from-todo",
    corrupt_text=lambda path, text: (
        "No canonical findings recorded.\n" if path.name == "TODO.md" else text
    ),
)
check(
    "missing-report-source-sha",
    corrupt_text=lambda path, text: (
        text.replace(module.AUDITED_SHA, "removed-source-sha") if path.name == "report.md" else text
    ),
)
check(
    "markdown-local-path-escape",
    corrupt_text=lambda path, text: (
        text + "\n[Escape](../../../../../../outside-negative-control.md)\n"
        if path.name == "report.md"
        else text
    ),
)
check(
    "rendered-capabilities-stale",
    corrupt_text=lambda path, text: (
        text + "\nstale table\n" if path.name == "capabilities.md" else text
    ),
)


def canonical_empty(path, data):
    if path.name == "index.json":
        for scope in data["scopes"]:
            scope["ids"] = []
        data["shared_mechanisms"] = {}
    elif path.name == "findings.json":
        data["findings"] = []
    return data


check("canonical-ids-authoritative-zero-findings-allowed", canonical_empty, refused=False)
print(
    json.dumps(
        {
            "baseline": baseline_output.getvalue().strip(),
            "mutation_scope": "Parser/text return values only; no real files changed",
            "controls": cases,
        },
        indent=2,
    )
)
