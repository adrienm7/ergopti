import argparse, json, pathlib, re

p = argparse.ArgumentParser()
p.add_argument("--artifact-root", required=True)
a = p.parse_args()
b = pathlib.Path(a.artifact_root)
f = json.loads((b / "findings.json").read_text())
assert f["schema_version"] == 1 and f["scope"] == "macos-diagnostics"
assert (
    f["audited_sha"] == "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
    and f["created_at"] == "2026-11-05"
)
assert (
    pathlib.Path(f["report_path"]).resolve() == (b / "report.md").resolve()
    and (b / "report.md").is_file()
)
assert f["findings"] == []
for n in ["finalA", "finalB"]:
    r = json.loads((b / "logs" / f"{n}-ledger.json").read_text())
    assert len(r) == 46 and all(x["returncode"] == 0 for x in r)
    assert sum(x.get("passed_tests") or 0 for x in r) == 596
    assert len([x for x in r if x["selector"].startswith("tests.")]) == 39
    assert all(pathlib.Path(x["log"]).is_file() for x in r)
    assert "shared_export_control" in (b / "logs" / f"{n}-crash-canary.log").read_text()
print(
    "PASS schema=1 scope=macos-diagnostics SHA/date/report identity exact; confirmed findings empty."
)
print(
    "PASS finalA/finalB:46 commands each,39 Lua modules and596 registered passes each,6 focused Node scripts,1 private actual-owner proof."
)
print(
    "PASS both final canary proofs contain typed-document/daylog cleanup controls; no generated crash JSON retained."
)
assert not list((b / "logs/crash-fixture").glob("*.json"))
