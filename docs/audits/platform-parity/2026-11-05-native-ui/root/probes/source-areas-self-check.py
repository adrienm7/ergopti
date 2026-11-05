"""Private Git fixtures qualify source-area membership and stale-output detection."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", type=Path, required=True)
helper = parser.parse_args().source_root.resolve() / "tools/audit/source-areas.py"
env = dict(
    os.environ,
    GIT_AUTHOR_NAME="Audit Fixture",
    GIT_AUTHOR_EMAIL="audit@example.invalid",
    GIT_COMMITTER_NAME="Audit Fixture",
    GIT_COMMITTER_EMAIL="audit@example.invalid",
    GIT_CONFIG_NOSYSTEM="1",
)
with tempfile.TemporaryDirectory(prefix="ergopti-source-area-check-") as temporary:
    root = Path(temporary)

    def git(*args):
        return (
            subprocess.check_output(
                ["git", "-C", str(root), "-c", "core.hooksPath=/dev/null", *args],
                env=env,
                stderr=subprocess.PIPE,
            )
            .decode()
            .strip()
        )

    def run(*args, expected=0):
        result = subprocess.run(
            ["python3", str(helper), "--source-root", str(root), "--output", str(output), *args],
            capture_output=True,
            text=True,
        )
        assert result.returncode == expected, (args, result.returncode, result.stderr)
        return result

    def write(name, data="local runtime = true\n"):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    git("init", "-q")
    for name in [
        "static/ergopti_plus/linux/modules/llm/runtime.lua",
        "static/ergopti_plus/windows/vendor/_generated/runtime.ahk",
        "static/ergopti_plus/_shared/go/http/client.go",
        "static/ergopti_plus/macos/launcher/Tests/Fixture.swift",
        "static/ergopti_plus/_shared/go/http/client_test.go",
        "static/ergopti_plus/linux/tests/excluded.lua",
    ]:
        write(name)
    git("add", "static")
    git("commit", "-qm", "fixture baseline")
    before = git("rev-parse", "HEAD")
    output = root / "census.json"
    run()
    run("--check")
    original = output.read_bytes()
    manifest = json.loads(original)
    members = [m for area in manifest["areas"] for m in area["members"]]
    assert len(members) == 3
    assert manifest["audited_sha"] == before
    assert any(m["vendor_path"] and m["generated_path"] for m in members)
    assert any(m["path"].endswith("client.go") for m in members)
    assert all(len(m["git_blob"]) == len(before) for m in members)
    print("PASS healthy exact Git members, SHA/blob identity, test exclusions and lexical labels")
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    run("--check")
    print("PASS formatted JSON and reordered object keys accepted semantically")
    output.write_bytes(original.replace(b"\n", b"\r\n"))
    run("--check", expected=1)
    print("PASS CRLF output rejected")
    manifest["areas"][0]["members"].pop()
    output.write_text(json.dumps(manifest) + "\n")
    run("--check", expected=1)
    print("PASS missing member rejected")
    output.write_bytes(original)
    write("static/ergopti_plus/linux/modules/new/runtime.lua")
    git("add", "static/ergopti_plus/linux/modules/new/runtime.lua")
    git("commit", "-qm", "fixture new runtime")
    run("--check", expected=1)
    print("PASS later tracked source addition rejected as stale output")
    run("--ref", before, "--check")
    write("static/ergopti_plus/linux/modules/llm/runtime.lua", "dirty working bytes\n")
    run("--ref", before, "--check")
    print("PASS historical ref reproducible despite new HEAD and dirty working file")
    run()
    run("--check")
    regenerated = json.loads(output.read_bytes())
    regenerated_members = [m for area in regenerated["areas"] for m in area["members"]]
    assert len(regenerated_members) == 4
    assert any(m["path"].endswith("linux/modules/new/runtime.lua") for m in regenerated_members)
    assert output.read_bytes().endswith(b"\n") and b"\r" not in output.read_bytes()
    print("PASS regenerated current census and UTF-8/LF deterministic bytes")
