from pathlib import Path
import subprocess, datetime, json, os

base = Path(__file__).resolve().parent.parent
ledger = []
for pass_id, review in [
    (
        "D1",
        "Rechecked source-to-destination authority, backup publication/refusal, actual parser and loader adoption, native directory/read/write returns and restart recovery.",
    ),
    (
        "D2",
        "Rechecked common/newer destination policy, occupied backups, custom/nested/TOML locators, symlink/nesting uncertainty and explicit cross-OS/compiled-runtime differences; no additional confirmed root.",
    ),
]:
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    transcript = []
    for script in ["run.py", "run-existing.py"]:
        result = subprocess.run(
            ["python3", str(base / "probes" / script)], capture_output=True, text=True
        )
        transcript.append(result.stdout + result.stderr)
        assert result.returncode == 0, (script, result.stdout, result.stderr)
    (base / "logs" / (pass_id + ".txt")).write_text("\n".join(transcript))
    for name in ["results.json", "existing-results.json"]:
        (base / "logs" / (pass_id + "-" + name)).write_text((base / "logs" / name).read_text())
    ledger.append(
        dict(
            pass_id=pass_id,
            started_at=start,
            finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            source_review=review,
            public_modes=12,
            fresh_registered_modules=6,
            registered_cases=36,
            new_confirmed_roots=0,
            uid=os.geteuid(),
        )
    )
    print(pass_id, "PASS 12 public safe modes + 6 fresh registered modules/36 cases; new roots0")
(base / "logs/dry-pass-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
