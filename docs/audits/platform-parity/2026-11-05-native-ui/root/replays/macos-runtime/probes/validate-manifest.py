#!/usr/bin/env python3
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
m = json.loads(path.read_text())
assert m["schema_version"] == 1 and m["scope"] == "macos-runtime"
assert (
    m["audited_sha"] == "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
    and m["created_at"] == "2026-11-05"
)
allowed = {
    "G1",
    "G2",
    "G3",
    "G4",
    "G5",
    "P_BOUNDED_COMMAND_SETTLEMENT",
    "P_ARTIFACT_ADMISSION_CONSISTENCY",
    "P_RECOVERABLE_PROVISIONING",
}
seen = set()
for f in m["findings"]:
    assert f["id"].startswith("MRT-") and f["id"] not in seen
    seen.add(f["id"])
    assert f["severity"] in {"critical", "high", "medium", "low"} and f["confidence"] in {
        "high",
        "medium",
        "low",
    }
    assert f["guarantees"] and set(f["guarantees"]) <= allowed
    for key in ("title", "reproduction", "root_cause", "silent_failure", "regression_test"):
        assert isinstance(f[key], str) and f[key].strip()
assert seen == {"MRT-001", "MRT-002", "MRT-003", "MRT-004", "MRT-006"}
assert (path.parent / "report.md").is_file()
print(
    "PASS requested schema1 macos-runtime manifest: 5 confirmed findings; MRT-005 intentionally excluded"
)
