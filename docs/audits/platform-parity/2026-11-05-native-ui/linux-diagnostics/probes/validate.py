import json, pathlib, re

out = pathlib.Path(__file__).resolve().parent.parent
d = json.loads((out / "findings.json").read_text())
assert (
    d["schema_version"] == 1
    and d["scope"] == "linux-diagnostics"
    and d["created_at"] == "2026-11-05"
)
assert (
    d["audited_sha"] == "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
    and pathlib.Path(d["report_path"]).is_file()
)
ids = set()
for f in d["findings"]:
    assert re.fullmatch(r"LDG-\d{3}", f["id"]) and f["id"] not in ids
    ids.add(f["id"])
    assert f["severity"] in ["critical", "high", "medium", "low"] and f["confidence"] in [
        "high",
        "medium",
        "low",
    ]
    assert f["guarantees"] and set(f["guarantees"]) <= set(["G1", "G2", "G3", "G4", "G5"])
    for k in ["title", "reproduction", "root_cause", "silent_failure", "regression_test"]:
        assert isinstance(f[k], str) and f[k].strip()
    for k in ["artifact", "log"]:
        assert pathlib.Path(f["evidence"][k]).is_file()
    for p in f["evidence"].get("additional_logs", []):
        assert pathlib.Path(p).is_file()
for label in ["final-dry1", "final-dry2"]:
    rows = json.loads((out / "logs" / f"{label}-results.json").read_text())
    assert len(rows) == 32 and not [x for x in rows if x["exit_code"]]
print("PASS schema1 linux-diagnostics:", len(ids), "confirmed findings; 2 full dry sweeps verified")
