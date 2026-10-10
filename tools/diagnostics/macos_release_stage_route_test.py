# tools/diagnostics/macos_release_stage_route_test.py
#!/usr/bin/env python3
"""Authored portable shell receipt controls; no genuine macOS/native-wire credit.
Root supplies one original or candidate release_stage.sh path and output receipt.
All packets, statuses, archive bytes and refusal floors are authored below.
"""

import argparse
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

URL = "https://github.com/adrienm7/ergopti/releases/download/v0.0.0-dev.139/ErgoptiPlus.app.zip"
DIGEST = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
COMPLETE = b'{"version":1,"success":true,"reason":"complete"}\n'
VERIFY = b'{"version":1,"success":false,"reason":"verify"}\n'
# Independent literal inventory; these are not generated from candidate source.
PERMUTATIONS = (
    COMPLETE,
    b'{"version":1,"reason":"complete","success":true}\n',
    b'{"success":true,"version":1,"reason":"complete"}\n',
    b'{"success":true,"reason":"complete","version":1}\n',
    b'{"reason":"complete","version":1,"success":true}\n',
    b'{"reason":"complete","success":true,"version":1}\n',
)
BASE_CALLS = ["native", "shasum", "ditto", "plist", "codesign-display", "codesign-verify"]
CASES = [
    dict(name="compact-order-" + str(i + 1), packet=p, want=0, calls=BASE_CALLS)
    for i, p in enumerate(PERMUTATIONS)
]
CASES += [
    dict(
        name="native-tar",
        packet=COMPLETE,
        format="tar.xz",
        want=0,
        calls=["native", "shasum", "tar", "plist", "codesign-display", "codesign-verify"],
    ),
    dict(
        name="native-verify",
        packet=VERIFY,
        native_status=74,
        deliver=False,
        want=21,
        calls=["native"],
    ),
    dict(
        name="native-file-write",
        packet=b'{"version":1,"success":false,"reason":"file_write"}\n',
        native_status=74,
        deliver=False,
        want=10,
        calls=["native"],
    ),
    dict(
        name="false-complete",
        packet=b'{"version":1,"success":false,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="true-verify",
        packet=b'{"version":1,"success":true,"reason":"verify"}\n',
        native_status=74,
        want=10,
        calls=["native"],
    ),
    dict(
        name="native-connect",
        packet=b'{"version":1,"success":false,"reason":"connect"}\n',
        native_status=74,
        deliver=False,
        want=10,
        calls=["native"],
    ),
    dict(
        name="native-deadline",
        packet=b'{"version":1,"success":false,"reason":"deadline"}\n',
        native_status=75,
        deliver=False,
        want=10,
        calls=["native"],
    ),
    dict(name="complete-nonzero", packet=COMPLETE, native_status=74, want=10, calls=["native"]),
    dict(name="verify-zero", packet=VERIFY, want=10, calls=["native"]),
    dict(
        name="deadline-wrong-exit",
        packet=b'{"version":1,"success":false,"reason":"deadline"}\n',
        native_status=74,
        want=10,
        calls=["native"],
    ),
    dict(name="no-lf", packet=COMPLETE[:-1], want=10, calls=["native"]),
    dict(name="two-lf", packet=COMPLETE + b"\n", want=10, calls=["native"]),
    dict(name="nul-instead-lf", packet=COMPLETE[:-1] + b"\0", want=10, calls=["native"]),
    dict(name="nul-after-lf", packet=COMPLETE + b"\0", want=10, calls=["native"]),
    dict(
        name="embedded-nul",
        packet=b'{"version":1,\0"success":true,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="foreign-key",
        packet=b'{"version":1,"success":true,"reason":"complete","other":0}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="duplicate-key",
        packet=b'{"version":1,"version":1,"success":true,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="boolean-version",
        packet=b'{"version":true,"success":true,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="string-version",
        packet=b'{"version":"1","success":true,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="wrong-version",
        packet=b'{"version":2,"success":true,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="numeric-success",
        packet=b'{"version":1,"success":1,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="unknown-reason",
        packet=b'{"version":1,"success":false,"reason":"foreign"}\n',
        native_status=74,
        want=10,
        calls=["native"],
    ),
    dict(
        name="truncated-json", packet=b'{"version":1,"success":true,\n', want=10, calls=["native"]
    ),
    dict(name="empty-receipt", packet=b"", want=10, calls=["native"]),
    dict(
        name="whitespace-receipt",
        packet=b'{ "version":1,"success":true,"reason":"complete"}\n',
        want=10,
        calls=["native"],
    ),
    dict(
        name="digest-suffix-refusal",
        packet=COMPLETE,
        digest="0" * 64,
        want=21,
        calls=["native", "shasum"],
    ),
    dict(
        name="extract-refusal",
        packet=COMPLETE,
        extract_status=1,
        want=22,
        calls=["native", "shasum", "ditto"],
    ),
    dict(
        name="version-refusal",
        packet=COMPLETE,
        found_version="0.0.0-dev.138",
        want=25,
        calls=["native", "shasum", "ditto", "plist"],
    ),
    dict(name="signature-refusal", packet=COMPLETE, signature_status=1, want=27, calls=BASE_CALLS),
    dict(
        name="designation-refusal",
        packet=COMPLETE,
        display_status=1,
        want=26,
        calls=["native", "shasum", "ditto", "plist", "codesign-display"],
    ),
    dict(name="fresh-stage-collision", packet=COMPLETE, collision=True, want=10, calls=[]),
    dict(name="launcher-identity-refusal", packet=COMPLETE, wrong_identity=True, want=10, calls=[]),
    dict(name="launcher-bundle-refusal", packet=COMPLETE, wrong_bundle=True, want=10, calls=[]),
    dict(
        name="launcher-missing-refusal", packet=COMPLETE, missing_launcher=True, want=10, calls=[]
    ),
    dict(
        name="launcher-observed-replacement",
        packet=COMPLETE,
        replace_launcher=True,
        want=10,
        calls=["native"],
    ),
    dict(
        name="stage-observed-replacement",
        packet=COMPLETE,
        replace_stage=True,
        want=10,
        calls=["native"],
    ),
    dict(name="request-output-refusal", packet=COMPLETE, wrong_output=True, want=10, calls=[]),
    dict(name="request-budget-refusal", packet=COMPLETE, wrong_budget=True, want=10, calls=[]),
    dict(
        name="explicit-lowercase",
        packet=COMPLETE,
        proxies={
            "https_proxy": "http://lower.invalid:80",
            "HTTPS_PROXY": "http://upper.invalid:80",
        },
        explicit=True,
        want=0,
        calls=["curl", "shasum", "ditto", "plist", "codesign-display", "codesign-verify"],
    ),
    dict(
        name="explicit-uppercase",
        packet=COMPLETE,
        proxies={"https_proxy": "", "HTTPS_PROXY": "http://upper.invalid:80"},
        explicit=True,
        want=0,
        calls=["curl", "shasum", "ditto", "plist", "codesign-display", "codesign-verify"],
    ),
    dict(
        name="explicit-all-lowercase",
        packet=COMPLETE,
        proxies={
            "all_proxy": "http://all-lower.invalid:80",
            "ALL_PROXY": "http://all-upper.invalid:80",
        },
        explicit=True,
        want=0,
        calls=["curl", "shasum", "ditto", "plist", "codesign-display", "codesign-verify"],
    ),
    dict(
        name="explicit-all-uppercase",
        packet=COMPLETE,
        proxies={"ALL_PROXY": "http://all-upper.invalid:80"},
        explicit=True,
        want=0,
        calls=["curl", "shasum", "ditto", "plist", "codesign-display", "codesign-verify"],
    ),
    dict(
        name="explicit-no-fallback",
        packet=COMPLETE,
        proxies={"https_proxy": "bad://declared"},
        explicit=True,
        curl_status=22,
        want=10,
        calls=["curl"],
    ),
    dict(
        name="manual-original-curl",
        packet=COMPLETE,
        manual=True,
        want=0,
        calls=["curl", "shasum", "ditto", "plist", "codesign-display", "codesign-verify"],
    ),
]

# Portable adapters implement tool interfaces using actual local files. Neither
# native routing nor plutil/stat compatibility with real macOS is credited here.
TOOL = r"""import json, os, sys, hashlib
from pathlib import Path
c=json.loads(Path(os.environ['FIXTURE_CONFIG']).read_text())
a=sys.argv[1:]; name=Path(sys.argv[0]).name
log=Path(c['log'])
def record(kind, **data):
    with log.open('a') as f: f.write(json.dumps(dict(kind=kind, **data))+'\n')
if name=='stat':
    st=os.stat(a[2], follow_symlinks=True)
    print(str(st.st_dev)+':'+str(st.st_ino) if a[1]=='%d:%i' else st.st_size)
elif name=='plutil':
    d=json.loads(Path(a[-1]).read_bytes()); v=d[a[1]]
    print('true' if v is True else 'false' if v is False else v)
elif name=='ErgoptiPlus':
    raw=sys.stdin.buffer.read()
    expected={'version':1,'url':c['url'],'sha256':c['digest'],'output':c['archive'],'timeout_ms':900000}
    record('native', argv=a, stdin_hex=raw.hex(), stdin_eof=True, pid=os.getpid())
    if a!=['--managed-bootstrap-download','900000'] or json.loads(raw)!=expected: sys.exit(91)
    if c.get('deliver',True): Path(c['archive']).write_bytes(b'abc')
    if c.get('replace_launcher'):
        p=Path(sys.argv[0]); replacement=p.with_name('replacement')
        replacement.write_bytes(p.read_bytes()); replacement.chmod(0o700); os.replace(replacement,p)
    if c.get('replace_stage'):
        stage=Path(c['stage']); stage.rename(str(stage)+'.observed-old'); stage.mkdir(mode=0o700)
    sys.stdout.buffer.write(bytes.fromhex(c['packet_hex'])); sys.stdout.buffer.flush()
    record('native-exit', status=c.get('native_status',0), pid=os.getpid())
    sys.exit(c.get('native_status',0))
elif name=='curl':
    record('curl', argv=a, proxies={k:os.environ.get(k) for k in ['https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY','no_proxy','NO_PROXY']})
    if c.get('curl_status'): sys.exit(c['curl_status'])
    Path(a[a.index('--output')+1]).write_bytes(b'abc')
elif name=='shasum':
    record('shasum'); print(hashlib.sha256(Path(a[2]).read_bytes()).hexdigest()+'  '+a[2])
elif name in ['ditto','tar']:
    record(name)
    if c.get('extract_status'): sys.exit(c['extract_status'])
    (Path(a[3])/'ErgoptiPlus.app'/'Contents').mkdir(parents=True)
elif name=='PlistBuddy':
    record('plist'); print(c.get('found_version','0.0.0-dev.139'))
elif name=='codesign':
    if a[0]=='-d':
        record('codesign-display'); print('designated => identifier "com.ergoptiplus.app"')
        sys.exit(c.get('display_status',0))
    record('codesign-verify'); sys.exit(c.get('signature_status',0))
else: sys.exit(92)
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("receipt")
    args = ap.parse_args()
    if sys.platform not in ("linux", "darwin"):
        raise SystemExit("Unsupported POSIX cohort capability; no receiving cases executed")
    case_root = Path(args.receipt).resolve().parent / "cases"
    if (
        not case_root.is_dir()
        or case_root.is_symlink()
        or case_root.stat().st_mode & 0o777 != 0o700
    ):
        raise SystemExit("An existing private owner-held case directory is required")
    original = Path(args.script).read_text()
    observations = []
    failures = []
    for case in CASES:
        # The enclosing native owner, not this worker, retires and removes
        # all inputs. Ambiguous cancellation leaves these paths intact.
        with nullcontext(tempfile.mkdtemp(prefix="release-route-receiving-", dir=case_root)) as tmp:
            root = Path(tmp)
            tools = root / "tools"
            tools.mkdir()
            running = root / "Running.app"
            launcher = running / "Contents" / "MacOS" / "ErgoptiPlus"
            launcher.parent.mkdir(parents=True)
            toolbody = "#!" + sys.executable + "\n" + TOOL
            launcher.write_text(toolbody)
            launcher.chmod(0o700)
            script = original
            for name, absolute in [
                ("stat", "/usr/bin/stat"),
                ("plutil", "/usr/bin/plutil"),
                ("curl", "/usr/bin/curl"),
                ("shasum", "/usr/bin/shasum"),
                ("ditto", "/usr/bin/ditto"),
                ("tar", "/usr/bin/tar"),
                ("PlistBuddy", "/usr/libexec/PlistBuddy"),
                ("codesign", "/usr/bin/codesign"),
            ]:
                tool = tools / name
                tool.write_text(toolbody)
                tool.chmod(0o700)
                script = script.replace(absolute, str(tool))
            stage = root / "stage"
            fmt = case.get("format", "zip")
            archive = stage / ("release." + fmt)
            c = {k: v for k, v in case.items() if k not in ["packet", "calls", "proxies"]}
            c.update(
                packet_hex=case["packet"].hex(),
                log=str(root / "calls.jsonl"),
                url=URL,
                digest=case.get("digest", DIGEST),
                archive=str(archive),
                stage=str(stage),
            )
            config = root / "config.json"
            config.write_text(json.dumps(c))
            env = dict(os.environ)
            for k in [
                "https_proxy",
                "HTTPS_PROXY",
                "all_proxy",
                "ALL_PROXY",
                "http_proxy",
                "HTTP_PROXY",
                "no_proxy",
                "NO_PROXY",
                "ERGOPTI_RELEASE_STAGE_REQUEST",
                "ERGOPTI_LAUNCHER_EXECUTABLE",
                "ERGOPTI_LAUNCHER_DEVICE",
                "ERGOPTI_LAUNCHER_INODE",
            ]:
                env.pop(k, None)
            st = launcher.stat()
            env.update(
                FIXTURE_CONFIG=str(config),
                ERGOPTI_LAUNCHER_EXECUTABLE=str(launcher),
                ERGOPTI_LAUNCHER_DEVICE=str(st.st_dev),
                ERGOPTI_LAUNCHER_INODE=str(st.st_ino),
                no_proxy="literal.bypass.invalid",
                NO_PROXY="upper.bypass.invalid",
            )
            env.update(case.get("proxies", {}))
            req = {
                "version": 1,
                "url": URL,
                "sha256": c["digest"],
                "output": str(archive),
                "timeout_ms": 900000,
            }
            if case.get("wrong_output"):
                req["output"] = str(root / "foreign")
            if case.get("wrong_budget"):
                req["timeout_ms"] = 900001
            if not case.get("manual"):
                env["ERGOPTI_RELEASE_STAGE_REQUEST"] = json.dumps(req, separators=(",", ":"))
            if case.get("wrong_identity"):
                env["ERGOPTI_LAUNCHER_INODE"] = str(st.st_ino + 1)
            if case.get("missing_launcher"):
                env["ERGOPTI_LAUNCHER_EXECUTABLE"] = ""
            if case.get("collision"):
                stage.mkdir(mode=0o700)
                (stage / "owned-before").write_text("untouched")
            argv = [
                "/bin/sh",
                "-c",
                script,
                "stage",
                URL,
                c["digest"],
                str(stage),
                "0.0.0-dev.139",
                str(root / "Foreign.app") if case.get("wrong_bundle") else str(running),
                fmt,
                "ErgoptiPlus.app",
            ]
            execution_error = None
            stdout_path, stderr_path = root / "child.stdout", root / "child.stderr"
            with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
                result = subprocess.run(argv, env=env, stdout=stdout, stderr=stderr)
            if stdout_path.stat().st_size > 1048576 or stderr_path.stat().st_size > 1048576:
                raise RuntimeError("Owned case capture exceeds its bound")
            result = subprocess.CompletedProcess(
                argv, result.returncode, stdout_path.read_bytes(), stderr_path.read_bytes()
            )
            rows = (
                [json.loads(line) for line in Path(c["log"]).read_text().splitlines()]
                if Path(c["log"]).exists()
                else []
            )
            calls = [r["kind"] for r in rows if r["kind"] != "native-exit"]
            errors = [execution_error] if execution_error else []
            if result.returncode != case["want"]:
                errors.append("literal-exit")
            if calls != case["calls"]:
                errors.append("literal-call-sequence")
            expected_ready = ("READY " + str(stage / "app" / "ErgoptiPlus.app") + "\n").encode()
            if result.stdout != (expected_ready if case["want"] == 0 else b""):
                errors.append("literal-READY-or-empty")
            if case.get("collision") and (stage / "owned-before").read_text() != "untouched":
                errors.append("collision-preimage")
            if case.get("explicit") or case.get("manual"):
                curl = next((r for r in rows if r["kind"] == "curl"), None)
                expected = [
                    "--fail",
                    "--location",
                    "--silent",
                    "--show-error",
                    "--proto",
                    "=https",
                    "--proto-redir",
                    "=https",
                    "--max-time",
                    "900",
                    "--output",
                    str(archive),
                    URL,
                ]
                if not curl or curl["argv"] != expected:
                    errors.append("original-curl-argv")
                if curl and any(curl["proxies"].get(k) != env.get(k) for k in curl["proxies"]):
                    errors.append("original-explicit-environment")
            native = [r for r in rows if r["kind"] == "native"]
            if native:
                if (
                    len(native) != 1
                    or native[0]["argv"] != ["--managed-bootstrap-download", "900000"]
                    or native[0]["stdin_eof"] is not True
                ):
                    errors.append("owned-native-invocation")
                if len([r for r in rows if r["kind"] == "native-exit"]) != 1:
                    errors.append("foreground-fixture-exit")
            observation = dict(
                name=case["name"],
                expected_status=case["want"],
                actual_status=result.returncode,
                expected_calls=case["calls"],
                actual_calls=calls,
                stdout_hex=result.stdout.hex(),
                stderr_hex=result.stderr.hex(),
                actual_rows=rows,
                errors=errors,
            )
            observations.append(observation)
            if errors:
                failures.append(case["name"])
    packet = {
        "version": 1,
        "kind": "portable-authored-shell-only",
        "script": str(Path(args.script).resolve()),
        "script_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "observations": observations,
        "failures": failures,
        "no_genuine_native_qualification": True,
    }
    Path(args.receipt).write_text(json.dumps(packet, indent=2) + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
