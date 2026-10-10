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
local function shared(path)
 local file = assert(io.open("../_shared/"..path, "rb"))
 local value = Json.decode(file:read("*a")); assert(file:close()); return value
end
local config = require("healthcheck.snapshot").load_config(function(path) return "../_shared/"..path end)
local schema = config.schema
local rules = config.redaction
local catalogue = shared("data/locales/en.json")
local notice = assert(catalogue[schema.share_policy.notice_key])
package.loaded["infra.i18n"] = {get=function(key)
 local value = catalogue[key]
 assert(type(value)=="string", "fixture catalogue lacks declared key: "..key)
 return value
end}
local baseline = os.getenv("ERGOPTI_REPORT_TEST_MODULE")
local Report = baseline and assert(loadfile(baseline))() or require("ui.healthcheck.report")
local directory = assert(os.getenv("ERGOPTI_REPORT_DIRECTORY"))
local raw = assert(os.getenv("ERGOPTI_REPORT_TEXT"))
local snapshot = {driver="linux",schema_version=2,detailed=false,generated_at="2026-10-04T00:00:00Z",
 sections={versions={ergopti_version="2.4.0"},issues={warn_count=0,err_count=0,recent={raw}}}}
-- The immediate-write case must still exceed the native stream buffer. Only
-- admitted synthetic technical cohorts enlarge it; private text stays excluded.
if #raw>=8192 then
 snapshot.retired_probes=Json.array({})
 for i=1,128 do
  snapshot.retired_probes[i]={probes={github_api={state="cancelled",cleanup="unknown",ms=i}}}
 end
end
local document = require("healthcheck.share").document(snapshot,schema,notice)
assert(not document.text:find("/private-owner",1,true) and not document.text:find("privateowner",1,true))
if #raw>=8192 then assert(#document.text>=8192,"immediate-write corpus lost its large native write") end
local name=document.name
local revealed = 0
local result = Report.perform({action="save", name=name, text=document.text},
 {diagnostics_dir=directory}, {redaction=rules,schema=schema}, {home="/private-owner",user="privateowner"},
 {reveal=function(path)
  assert(path==directory.."/"..name);revealed=revealed+1;return true
 end},snapshot)
print(Json.encode({ok=result.ok, revealed=revealed, path=result.path, expected=document.text,name=name}))
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
    schema = json.loads(
        Path("../_shared/modules/diagnostics/schema.json").read_text(encoding="utf-8")
    )
    name = (
        schema["report"]["name_prefix"]
        + "linux-2026-10-04T00_00_00Z"
        + schema["report"]["name_suffix"]
    )
    failures = 0
    with tempfile.TemporaryDirectory(prefix="ergopti-diagnostics-native-save-") as owned:
        for kind, leaf, text, limit, refusal in cases:
            directory = Path(owned) / leaf
            directory.mkdir()
            target = directory / name
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
                expected = receipt.pop("expected")
                assert receipt.pop("name") == name
                assert "/private-owner" not in expected and "privateowner" not in expected
                if limit is not None:
                    assert target.read_bytes() == expected.encode()[:limit], (
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
                    assert target.read_bytes() == expected.encode(), (
                        "saved bytes differ from the approved host projection"
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
