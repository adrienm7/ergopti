#!/usr/bin/env python3
# tests/hardware/run_diagnostics_save_receipts.py
# Production diagnostics saves must not reveal an incomplete regular file.
# RLIMIT_FSIZE failures are real kernel receipts, not injected adapter results.
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile

WORKER = r"""
local Json = require("json")
local source = assert(io.open("../_shared/modules/diagnostics/redaction.json", "rb"))
local rules = Json.decode(source:read("*a")); assert(source:close())
local baseline = os.getenv("ERGOPTI_REPORT_TEST_MODULE")
local Report = baseline and assert(loadfile(baseline))() or require("ui.healthcheck.report")
local directory = assert(os.getenv("ERGOPTI_REPORT_DIRECTORY"))
local name = "ergopti-diagnostics-linux-2.4.0-20261004T000000Z.md"
local revealed = 0
local result = Report.perform({action="save", name=name, text=assert(os.getenv("ERGOPTI_REPORT_TEXT"))},
 {diagnostics_dir=directory}, {redaction=rules}, {home="/private-owner",user="privateowner"},
 {reveal=function(path)
  assert(path==directory.."/"..name);revealed=revealed+1;return true
 end})
print(Json.encode({ok=result.ok, revealed=revealed, path=result.path}))
"""


def restrict_file_size(limit):
    def apply():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))

    return apply


def main():
    assert os.geteuid() != 0, "native permission receipts require an unprivileged user"
    cases = (
        ("normal-literal-directory", "quoted-'é\n\\directory", "é\nexact bytes\r\n", None, None),
        (
            "redaction-before-save",
            "redaction",
            "/private-owner/config (privateowner)\n",
            None,
            None,
        ),
        ("buffered-close-failure", "close", "x" * 128, 32, None),
        ("zero-byte-close-failure", "zero", "x" * 128, 0, None),
        ("immediate-write-failure", "write", "x" * 8192, 32, None),
        ("readonly-existing-file", "readonly", "x" * 128, None, "file"),
        ("unwritable-directory", "unwritable", "x" * 128, None, "directory"),
    )
    failures = 0
    with tempfile.TemporaryDirectory(prefix="ergopti-diagnostics-native-save-") as owned:
        for kind, leaf, text, limit, refusal in cases:
            directory = Path(owned) / leaf
            directory.mkdir()
            target = directory / "ergopti-diagnostics-linux-2.4.0-20261004T000000Z.md"
            if refusal == "file":
                target.write_bytes(b"existing report preserved\n")
                target.chmod(0o444)
            if refusal == "directory":
                directory.chmod(0o500)
            try:
                env = dict(
                    os.environ, ERGOPTI_REPORT_DIRECTORY=str(directory), ERGOPTI_REPORT_TEXT=text
                )
                result = subprocess.run(
                    [env.get("ERGOPTI_REPORT_TEST_LUA", "luajit"), "-e", WORKER],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    preexec_fn=restrict_file_size(limit) if limit is not None else None,
                )
                assert result.returncode == 0, (result.stdout + result.stderr)[-1200:]
                receipt = json.loads(result.stdout.strip().splitlines()[-1])
                if limit is not None:
                    assert target.read_bytes() == text.encode()[:limit], (
                        "unexpected native short-file bytes"
                    )
                if limit is not None or refusal:
                    assert receipt["ok"] is False, f"incomplete save reported success: {receipt}"
                    assert receipt["revealed"] == 0, f"incomplete save revealed: {receipt}"
                    assert receipt.get("path") is None
                    if refusal == "file":
                        assert target.read_bytes() == b"existing report preserved\n"
                    elif refusal == "directory":
                        assert not target.exists()
                else:
                    expected = "~/config (<user>)\n" if kind == "redaction-before-save" else text
                    assert target.read_bytes() == expected.encode(), (
                        "saved bytes differ from the redacted report"
                    )
                    assert receipt == {"ok": True, "revealed": 1, "path": str(target)}
                print(f"PASS {kind}")
            except (AssertionError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
                failures += 1
                print(f"FAIL {kind}: {error}")
            finally:
                directory.chmod(0o700)
                if target.exists():
                    target.chmod(0o600)
    print(f"Native diagnostics save receipts: {len(cases)} checks, {failures} failures")
    return int(failures > 0)


if __name__ == "__main__":
    raise SystemExit(main())
