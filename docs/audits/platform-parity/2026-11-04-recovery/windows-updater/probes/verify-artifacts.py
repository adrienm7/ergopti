import pathlib, json, hashlib, subprocess

b = pathlib.Path("/workspace/scratch/parity-recovery/windows-updater")
r = pathlib.Path("/workspace/ergopti")
receipt = json.load(open(b / "logs/source-identity.json"))
assert receipt["audited_sha"] == "3a680d9f530a9af686fccc16d3f7611ec7fb034c"
assert all(v["matches_pin"] for v in receipt["sources"])
swap = json.load(open(b / "logs/swap-cases.json"))
assert len(swap) == 4 and all(x["verified"] for x in swap)
p = json.load(open(b / "logs/posix-owned-output-receipt.json"))
assert [x["exit"] for x in p] == [0, 1, 1]
rows = []
for f in (b / "probes").glob("*.ps1"):
    rows.append(
        {"file": str(f.relative_to(b)), "sha256": hashlib.sha256(f.read_bytes()).hexdigest()}
    )
(b / "logs/probe-identity.json").write_text(json.dumps(rows, indent=2) + "\n")
print(
    "PASS exact-source receipts, four actual swap branches, baseline-positive/two-negative mutation sensitivity, retained probe identities"
)
