import pathlib, subprocess, json, datetime

root = pathlib.Path("/workspace/scratch/parity-flows/macos-clipboard/probes")
ledger = []
for name, script, results in [
    ("D1", "run-tests.py", "test-results.json"),
    ("D2", "run-more-tests.py", "second-test-results.json"),
]:
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    p = subprocess.run(
        ["python", str(root / script)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    (root / "logs" / (name + "-execution.log")).write_text(p.stdout)
    rows = json.loads((root / results).read_text())
    assert p.returncode == 0 and all(row["exit_code"] == 0 for row in rows)
    ledger.append(
        dict(
            pass_id=name,
            started_at=started,
            finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            fresh_modules=len(rows),
            results_path=str(root / results),
            new_confirmed_findings=0,
            source_review="See report pass ledger: source/entry/custody review completed; this execution is validation of the reviewed controls, not proof of no bugs.",
        )
    )
    print(name, "complete", len(rows), "fresh modules,0 failures", flush=True)
(root / "dry-pass-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
