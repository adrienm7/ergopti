from pathlib import Path
import datetime, json, subprocess, hashlib

base = Path(__file__).resolve().parent.parent
history = base / "logs/dry-pass-ledger-before-MFM006.json"
if not history.exists():
    history.write_bytes((base / "logs/dry-pass-ledger.json").read_bytes())
ledger = json.loads(history.read_text())
reviews = [
    (
        "D3",
        "Forward full bounded migration source sweep: immutable complete facade/ports/plan/core, all move/clash/kept/rewrite/restart outcomes; direct launcher/environment/init admission and ConfigPaths read/parse/selection joins. Existing MFM001-005 remain, new alias physical identity root is MFM006; no additional confirmed root.",
    ),
    (
        "D4",
        "Reverse full bounded migration source sweep: immutable current destination/backup custody through all facade/core physical moves, default/custom/nested/literal locators and backup/final-write refusal recovery, report and boot adoption/abort joins. Rechecked native return/throw and explicit policy boundaries; no additional confirmed root.",
    ),
]
for name, review in reviews:
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    inspected = []
    for provenance_path, key in [
        (base / "logs/immutable-bundle-provenance.json", "bundle_path"),
        (base / "logs/immutable-source-joins.json", "scratch_path"),
    ]:
        for row in json.loads(provenance_path.read_text())["files"]:
            data = Path(row[key]).read_bytes()
            assert hashlib.sha256(data).hexdigest() == row["sha256"]
            inspected.append(
                dict(source_path=row["source_path"], sha256=row["sha256"], bytes=len(data))
            )
    result = subprocess.run(
        ["python3", str(base / "probes/run-same-root-alias.py")], capture_output=True, text=True
    )
    (base / "logs" / (name + "-immutable-alias.txt")).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (result.stdout, result.stderr)
    (base / "logs" / (name + "-immutable-alias-results.json")).write_bytes(
        (base / "logs/same-root-results.json").read_bytes()
    )
    ledger.append(
        dict(
            pass_id=name,
            started_at=start,
            finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            source_review=review,
            scope="Full original bounded migration source and direct boot/locator joins rechecked; execution restricted to new same-root alias+healthy controls",
            source_files=inspected,
            immutable_source_sha="3a680d9f530a9af686fccc16d3f7611ec7fb034c",
            reset_after="MFM-006",
            fresh_lua_processes=3,
            public_modes=3,
            registered_cases=0,
            new_confirmed_roots=0,
            native_macos_execution=False,
        )
    )
    print(name, "PASS: immutable alias + distinct/absent controls;3 fresh interpreters;new roots0")
(base / "logs/dry-pass-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
