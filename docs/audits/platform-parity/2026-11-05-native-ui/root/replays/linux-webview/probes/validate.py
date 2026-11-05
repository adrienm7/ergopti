import json
import pathlib
import re

folder = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((folder / "findings.json").read_text())
assert manifest["schema_version"] == 1 and manifest["scope"] == "linux-webview"
assert re.fullmatch("[0-9a-f]{40}", manifest["audited_sha"])
assert manifest["created_at"] == "2026-11-05"
assert pathlib.Path(manifest["report_path"]).is_file()
ids = set()
for item in manifest["findings"]:
    assert item["id"] not in ids
    ids.add(item["id"])
    assert re.fullmatch("LVB-[0-9]{3}", item["id"])
    assert item["severity"] in ("critical", "high", "medium", "low")
    assert item["confidence"] in ("high", "medium", "low")
    assert item["guarantees"] and set(item["guarantees"]) <= {"G1", "G2", "G3", "G4", "G5"}
    for key in (
        "title",
        "reproduction",
        "root_cause",
        "silent_failure",
        "regression_test",
        "command",
        "other_os",
    ):
        assert isinstance(item[key], str) and item[key].strip()
    for evidence in item["evidence"]:
        assert (folder / evidence).is_file()
print("MANIFEST_RECEIPT schema=1 scope=linux-webview findings=" + str(len(ids)) + " valid=true")
