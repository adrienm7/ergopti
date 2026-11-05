import json, pathlib, re

p = pathlib.Path(__file__).resolve().parent.parent / "findings.json"
d = json.loads(p.read_text())
assert (
    d["schema_version"] == 1 and d["scope"] == "linux-runtime" and d["created_at"] == "2026-11-05"
)
assert re.fullmatch("[0-9a-f]{40}", d["audited_sha"])
assert pathlib.Path(d["report_path"]).is_file()
ids = set()
for f in d["findings"]:
    assert f["id"] not in ids
    ids.add(f["id"])
    assert re.fullmatch("LRT-[0-9]{3}", f["id"])
    assert f["severity"] in ["critical", "high", "medium", "low"] and f["confidence"] in [
        "high",
        "medium",
        "low",
    ]
    assert f["guarantees"] and all(x in ["G1", "G2", "G3", "G4", "G5"] for x in f["guarantees"])
    for k in ["title", "reproduction", "root_cause", "silent_failure", "regression_test"]:
        assert isinstance(f[k], str) and f[k].strip()
    for k in ["artifact", "log"]:
        assert pathlib.Path(f["evidence"][k]).is_file()
print("PASS schema1 linux-runtime manifest:", len(d["findings"]), "confirmed finding(s)")
