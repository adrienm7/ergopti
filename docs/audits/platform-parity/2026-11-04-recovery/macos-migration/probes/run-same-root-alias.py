from pathlib import Path
import json, os, subprocess, tempfile, datetime, hashlib

base = Path(__file__).resolve().parent.parent
bundle = base / "probes/immutable-bundle"
provenance = json.loads((base / "logs/immutable-bundle-provenance.json").read_text())
for row in provenance["files"]:
    assert hashlib.sha256(Path(row["bundle_path"]).read_bytes()).hexdigest() == row["sha256"]
rows = []
for mode in ["alias", "distinct", "absent"]:
    with tempfile.TemporaryDirectory(prefix="tmp-alias-", dir=base / "probes") as home:
        result = subprocess.run(
            [
                "/workspace/scratch/parity-toolchain/ci-bin/lua",
                str(base / "probes/same-root-alias.lua"),
                mode,
            ],
            capture_output=True,
            text=True,
            env=dict(os.environ, HOME=home),
        )
        (base / "logs" / ("same-root-" + mode + ".txt")).write_text(result.stdout + result.stderr)
        rows.append(
            dict(mode=mode, exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
        )
        print(
            mode,
            result.returncode,
            result.stdout.splitlines()[0] if result.stdout else result.stderr,
        )
assert all(row["exit"] == 0 for row in rows)
(base / "logs/same-root-results.json").write_text(
    json.dumps(
        dict(
            audited_sha=provenance["audited_sha"],
            created_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            source="4 immutable Git-blob modules only; hash verified",
            results=rows,
        ),
        indent=2,
    )
    + "\n"
)
