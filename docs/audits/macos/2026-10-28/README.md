<!-- docs/audits/macos/2026-10-28/README.md -->

# macOS audit handoff and recovery

This handoff preserves the work after the execution container is deleted. The user asked to finish the work and bugs already found, stop further research, and record unfinished items as TODOs. It does not claim that finite tests prove the absence of every bug.

**Published code checkpoint:** `b56677ea345e115828e2bf5b5dbfcf5cf5e46c7e` is published on `fix/macos`, with all 35 delivery atoms and 12 normal development merges. The final oracle and Common 529/529 qualification are complete. CI [40765470617](https://github.com/adrienm7/ergopti/actions/runs/40765470617) names that exact source and finished **FAILURE**. The complete terminal census and current-source receipts are recorded in the report and archive. The documentation commit preserves those source-bound results; it does not relabel them as a test of later documentation bytes.

- [Report](report.md): commit subjects, bugs, root causes, regression evidence, historical CI results and scope limits. Historical source hashes and dates remain attached to their original snapshots.
- [Remaining work](TODO.md): the one confirmed protected bug and separately identified, unconfirmed native or physical questions.
- [Manifest](manifest.json): archive checksum, individual recorded-file checksums, deliberate omissions and final source bindings.
- `evidence.tar.gz`: compact recorded receipts, negative reproductions and source patches; no complete worktrees or dependency caches.

## Verify and extract evidence

Run this from the repository root. It checks the archive and every recorded file before writing only ordinary files into a newly allocated temporary directory. It rejects absolute paths, traversal, links and other archive member types.

```sh
python3 - <<'PY'
from pathlib import Path
import hashlib, json, tarfile, tempfile
handoff = Path('docs/audits/macos/2026-10-28')
manifest = json.loads((handoff / 'manifest.json').read_text())
archive = handoff / 'evidence.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['archive']['sha256']
destination = Path(tempfile.mkdtemp(prefix='ergopti-audit-evidence-'))
with tarfile.open(archive, 'r:gz') as packed:
    members = packed.getmembers()
    for member in members:
        path = Path(member.name)
        assert member.isfile() and not path.is_absolute() and '..' not in path.parts
        assert not member.issym() and not member.islnk()
    inventory = json.loads(packed.extractfile('MANIFEST.json').read())
    expected = {row['path']: row for row in inventory['entries']}
    assert {member.name for member in members} == set(expected) | {'MANIFEST.json'}
    for member in members:
        data = packed.extractfile(member).read()
        if member.name != 'MANIFEST.json':
            row = expected[member.name]
            assert len(data) == row['bytes']
            assert hashlib.sha256(data).hexdigest() == row['sha256']
        target = destination / member.name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
print(destination)
PY
```

Historical `/workspace/scratch/NAME/file` references in the report correspond to `recorded/NAME/file` in the extracted archive when selected. The manifest lists every retained file and deliberately omitted input. Original proof bytes remain unchanged. Selected completed raw CI logs are retained. Running/future outputs, personal field logs, credentials and large build payloads are not included. Native CI run and job identifiers provide the external log/artifact references; artifact retention is controlled by GitHub.

## Recover Git work

The archive contains `recovery/owned-work.bundle` and its metadata. The prerequisite is the repository history through `18d69a24c06586186a221c1afb5ce703732ac4a1`, as recorded in the verified final-code bundle metadata. Verify the bundle from a clone containing that prerequisite:

```sh
git bundle verify /path/to/extracted/recovery/owned-work.bundle
git bundle list-heads /path/to/extracted/recovery/owned-work.bundle
```

Fetch it into separate local recovery refs; do not overwrite an active worktree. Only `fix/macos` was authorized for remote publication. The bundle's code checkpoint precedes the documentation commit that stores the bundle itself.

The local `macos/oct28-carrier-staleness-owner` ref at `f699073f0d9fe66a23cfb2f2e45a71a28c4ec785` is archived recovery data only. **DO NOT CHERRY-PICK:** `dev` superseded that private implementation. It was not integrated, pushed as a branch, or counted as a delivered fix. The final test-only oracle correction is a different change.

## Replay the protected bootstrap finding

The recorded script `recorded/oct28-protected-bootstrap-report/probe-uv-python.py` is a Linux-host reproduction using actual Bash, filesystem and process-group signals. Only the managed download boundary is replaced by a strict local fixture. It does not perform real network downloads, use personal runtime caches, or claim native Darwin/PTY execution. Its normal failure control must clean up; the two recorded SIGTERM cases retain a workspace and partial download.

The original script embeds the now-deleted workspace paths. Keep it unchanged and derive a transparent path-only copy in a temporary directory. With `evidence_root` set to the extracted evidence directory, run from a checkout of the audited source:

```sh
python3 - "$PWD" "$evidence_root/recorded/oct28-protected-bootstrap-report/probe-uv-python.py" <<'PY'
from pathlib import Path
import ast, hashlib, subprocess, sys, tempfile
repo = Path(sys.argv[1]).resolve()
original = Path(sys.argv[2]).read_text()
needle = "ROOT=Path('/workspace/ergopti-macos-integration');OUT=Path('/workspace/scratch/oct28-protected-bootstrap-report');"
assert original.count(needle) == 1
with tempfile.TemporaryDirectory(prefix='ergopti-bootstrap-replay-') as temporary:
    output = Path(temporary)
    replacement = f'ROOT=Path({str(repo)!r});OUT=Path({str(output)!r});'
    derived = original.replace(needle, replacement, 1)
    ast.parse(derived)
    script = output / 'derived-probe.py'
    script.write_text(derived)
    print('recorded-script-sha256', hashlib.sha256(original.encode()).hexdigest())
    print('derived-path-only-sha256', hashlib.sha256(derived.encode()).hexdigest())
    subprocess.run([sys.executable, str(script)], check=True)
PY
```

Check the source hashes in the recorded `ready.json` before comparing a replay with the original finding. A later fix should make the bug-expecting assertions fail; it then needs its own cleanup regression assertions. The recorded `/proc` process-group check is Linux-specific. No other unconfirmed hypothesis should be treated as a reproduced bug merely because its source looks suspicious.

Other archived probe scripts may also embed historical worktree paths or require a particular pre-fix source snapshot. Replay a derived copy with explicit path changes, record both hashes, and retain the original. The committed regression tests and recorded exact commands remain the primary replay path. Never rewind, stash, reset or rewrite an active worktree to manufacture old-source evidence.

## Documentation publication and verification

The code, full local Common qualification, independent 22-control oracle review, final hosted CI, cleanup receipts and recoverable Git bundle are preserved. Every original receipt retains its actual source and outcome. The archive never includes itself or the later validation that checks its final bytes.

The final documentation commit adds exactly these five files. Normal selected gates and Git hooks must pass before normal publication to `fix/macos`; no dev/main push, force-push or new workflow dispatch is part of the documentation-only handoff. Its exact SHA is available from ordinary branch history and the final response. The source-equivalence check compares all paths outside this handoff directory against the explicit CI code checkpoint.

The backup builder and bundle refresher remain preparation tools outside the repository. They do not replace generation, formatting, convention checks, selected test gates or actual GitHub CI evidence. The user requested that work stop after this bounded handoff; confirmed protected work and unconfirmed questions remain separately recorded in TODO.
