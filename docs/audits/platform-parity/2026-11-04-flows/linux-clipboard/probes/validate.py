import datetime, json, pathlib, re

directory = pathlib.Path("/workspace/scratch/parity-flows/linux-clipboard")
manifest = json.loads((directory / "findings.json").read_text())
assert manifest["schema_version"] == 1 and manifest["scope"] == "linux-clipboard"
assert re.fullmatch("[0-9a-f]{40}", manifest["audited_sha"])
datetime.date.fromisoformat(manifest["created_at"])
assert pathlib.Path(manifest["report_path"]).is_file()
seen = set()
for finding in manifest["findings"]:
    assert re.fullmatch(r"LCP-\d{3}", finding["id"]) and finding["id"] not in seen
    seen.add(finding["id"])
    assert finding["severity"] in {"critical", "high", "medium", "low"}
    assert finding["confidence"] in {"high", "medium", "low"}
    assert finding["guarantees"] and set(finding["guarantees"]) <= {"G1", "G2", "G3", "G4", "G5"}
    for field in ["title", "reproduction", "root_cause", "silent_failure", "regression_test"]:
        assert isinstance(finding[field], str) and finding[field].strip()
print("SCRATCH_MANIFEST_VALID", len(seen))
