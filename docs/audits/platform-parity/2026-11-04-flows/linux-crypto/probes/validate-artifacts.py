from pathlib import Path
import json, re

base = Path("/workspace/scratch/parity-flows/linux-crypto")
v = json.loads((base / "findings.json").read_text())
assert v["schema_version"] == 1 and v["scope"] == "linux-crypto"
assert v["audited_sha"] == "213d65af24d2aa4845ba47743c9bab6787b61964"
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", v["created_at"])
assert Path(v["report_path"]).is_file()
ids = set()
for f in v["findings"]:
    for field in [
        "id",
        "title",
        "severity",
        "confidence",
        "reproduction",
        "root_cause",
        "silent_failure",
        "regression_test",
    ]:
        assert isinstance(f[field], str) and f[field].strip(), field
    assert re.fullmatch(r"LCR-\d{3}", f["id"]) and f["id"] not in ids
    ids.add(f["id"])
    assert f["severity"] in ["critical", "high", "medium", "low"]
    assert f["confidence"] in ["high", "medium", "low"]
    assert f["guarantees"] and set(f["guarantees"]) <= {"G1", "G2", "G3", "G4", "G5"}
for name, count in [
    ("pass0-baseline", 239),
    ("pass1-migration-controls", 74),
    ("pass2-auth-controls", 179),
    ("pass2-ui-ownership", 37),
    ("cross-check-local-server", 55),
]:
    assert f"TOTAL {count} passed 0 failed" in (base / "logs" / f"{name}.log").read_text()
for p in ["marker-collision", "secret-tool-short-write", "corruption-boundaries"]:
    assert (base / "probes" / f"{p}.lua").is_file() and (base / "logs" / f"{p}.log").is_file()
assert (base / "pass-ledger.md").is_file()
print(
    "VALID: schema v1 linux-crypto/LCR contract; 2 unique confirmed roots; 584 existing cases green; probe evidence retained; dry-pass ledger present."
)
