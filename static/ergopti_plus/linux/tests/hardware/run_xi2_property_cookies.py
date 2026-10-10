#!/usr/bin/env python3
"""Qualify three non-input property cookies under the unchanged exact-family owner."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import uuid


HARDWARE = Path(__file__).resolve().parent
ROOT = HARDWARE.parents[4]
CASES = ["property-created", "property-modified", "property-deleted"]
FAMILY_SHA = "7545c2d6aa8d48e5d48557b2b218e6d8a864eeb42ae761e055d4f917cdf06334"
FAMILY = HARDWARE / "native_fixture_family.py"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path, value):
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(value, indent=2) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def system_file(name):
    path = Path(name).resolve(strict=True)
    observed = path.stat()
    assert stat.S_ISREG(observed.st_mode) and observed.st_uid == 0
    assert not observed.st_mode & 0o022, "system input must not be group/world writable"
    return path


def family_run(directory, role, command, timeout, environment):
    """Never launch an experiment/compiler without original full-family admission."""
    reader, writer = os.pipe()
    token = uuid.uuid4().hex
    raw = b""
    with (
        (directory / (role + ".family.stdout")).open("xb") as stdout,
        (directory / (role + ".family.stderr")).open("xb") as stderr,
    ):
        try:
            supervisor = subprocess.Popen(
                [
                    sys.executable,
                    str(FAMILY),
                    "--timeout",
                    str(timeout),
                    "--receipt-fd",
                    str(writer),
                    "--token",
                    token,
                    "--",
                    *command,
                ],
                pass_fds=(writer,),
                cwd=directory,
                env=environment,
                stdout=stdout,
                stderr=stderr,
            )
            os.close(writer)
            writer = None
            # The original owner holds its deadline and debt; no parent-side kill.
            code = supervisor.wait()
            while True:
                block = os.read(reader, 4096)
                if not block:
                    break
                raw += block
                assert len(raw) <= 4096, "family receipt bound"
        finally:
            os.close(reader)
            if writer is not None:
                os.close(writer)
    (directory / (role + ".family.jsonl")).write_bytes(raw)
    frames = [json.loads(line) for line in raw.splitlines()]
    record(
        directory / (role + ".family.json"),
        dict(
            command=command,
            timeout=timeout,
            exit=code,
            token=token,
            supervisor=supervisor.pid,
            frames=frames,
        ),
    )
    assert len(frames) == 2 and [row["stage"] for row in frames] == ["ready", "settled"], (
        "original family admission refused; zero scenarios never qualify"
    )
    assert all(
        row["version"] == 1 and row["token"] == token and row["supervisor"] == supervisor.pid
        for row in frames
    )
    terminal = frames[-1]
    assert terminal["namespace_absent"] is True
    assert terminal["acquired"] == terminal["reaped"] == terminal["closed"] >= 1
    assert terminal["status"] == code == 0
    return terminal


def main():
    assert len(sys.argv) == 2, "fresh absolute evidence directory required"
    directory = Path(sys.argv[1])
    assert directory.is_absolute() and not directory.exists()
    directory.mkdir(mode=0o700)
    directory = directory.resolve(strict=True)
    observed = directory.stat()
    assert observed.st_uid == os.getuid() == os.geteuid()
    assert stat.S_IMODE(observed.st_mode) == 0o700
    nonce = uuid.uuid4().hex
    result = dict(
        qualified=False,
        cases=[],
        native_epoch_claim=False,
        input_output_grant=False,
        source_sha=os.environ.get("GITHUB_SHA"),
        nonce=nonce,
    )
    try:
        assert sys.platform == "linux" and platform.machine() == "x86_64"
        source_sha = os.environ["GITHUB_SHA"]
        assert re.fullmatch(r"[0-9a-f]{40}", source_sha)
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, timeout=5, text=True
        ).strip()
        assert head == source_sha, "exact checkout required"
        run_id, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
        assert run_id.isdecimal() and attempt.isdecimal()
        assert digest(FAMILY) == FAMILY_SHA, "original supervisor changed"
        files = [
            HARDWARE / name
            for name in [
                "xi2_property_cookie.c",
                "xi2_property_types.h",
                "xi2_property_display.py",
                "run_xi2_property_cookies.py",
                "native_fixture_family.py",
            ]
        ]
        source_pins = {str(path.relative_to(ROOT)): digest(path) for path in files}
        for relative, sha in source_pins.items():
            original = subprocess.check_output(
                ["git", "show", source_sha + ":" + relative], cwd=ROOT, timeout=5
            )
            assert hashlib.sha256(original).hexdigest() == sha, "source must equal exact Git image"
        compiler = system_file("/usr/bin/gcc")
        xvfb = system_file("/usr/bin/Xvfb")
        xi = system_file("/usr/lib/x86_64-linux-gnu/libXi.so")
        x11 = system_file("/usr/lib/x86_64-linux-gnu/libX11.so")
        headers = [
            system_file(name)
            for name in [
                "/usr/include/X11/Xlib.h",
                "/usr/include/X11/extensions/XInput2.h",
                "/usr/include/X11/extensions/XI2.h",
            ]
        ]
        system_pins = {str(path): digest(path) for path in [compiler, xvfb, xi, x11, *headers]}
        environment = dict(os.environ)
        for name in [
            "LD_PRELOAD",
            "LD_AUDIT",
            "LD_LIBRARY_PATH",
            "LD_DEBUG",
            "LD_DEBUG_OUTPUT",
            "LIBRARY_PATH",
            "CPATH",
            "C_INCLUDE_PATH",
            "CPLUS_INCLUDE_PATH",
            "GCC_EXEC_PREFIX",
            "COMPILER_PATH",
        ]:
            environment.pop(name, None)
        executable = directory / "cookie_experiment"
        command = [
            str(compiler),
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            str(HARDWARE / "xi2_property_cookie.c"),
            str(xi),
            str(x11),
            "-o",
            str(executable),
        ]
        record(
            directory / "plan.json",
            dict(
                source_sha=source_sha,
                run_id=run_id,
                attempt=attempt,
                nonce=nonce,
                cases=CASES,
                source_pins=source_pins,
                system_pins=system_pins,
                compiler_command=command,
                compile_family_deadline=60,
                native_family_deadline=25,
                scope="non-input Xvfb C property-cookie qualification",
            ),
        )
        compiler_terminal = family_run(directory, "compile", command, 60, environment)
        executable_sha = digest(executable)
        native_terminal = family_run(
            directory,
            "native",
            [
                sys.executable,
                str(HARDWARE / "xi2_property_display.py"),
                str(directory),
                str(executable),
                str(xvfb),
            ],
            25,
            environment,
        )
        display = json.loads((directory / "display-receipt.json").read_text())
        assert display["controlled_exit"] == 0
        assert display["controlled"] == dict(controlled_passed=16, native_fetch=0, native_free=0)
        assert display["native_exit"] == 0 and display["rescue"] == 0
        assert display["owned_display"] == "REAPED"
        assert display["termination_requested"] is True and display["server_pidfd_closed"] is True
        assert display["xvfb_exit"] in (0, -15)
        assert "premature_xvfb_exit" not in display and "failure_type" not in display
        facts = display["native"]
        assert facts["stage"] == 7 and facts["opened"] == facts["closed_calls"] == 1
        assert facts["close_status"] == 0 and facts["xi_major"] >= 2
        assert facts["fetched"] == facts["freed"] == facts["published"] == len(CASES) == 3
        assert facts["xerrors"] == facts["input_injections"] == 0
        assert facts["native_epoch_claim"] is False
        assert facts["server_peer_pid"] > 0 and facts["server_peer_uid"] == os.getuid()
        assert json.loads((directory / "native.stdout").read_bytes()) == facts
        assert not (directory / "native.stderr").read_bytes()
        assert not (directory / "controlled.stderr").read_bytes()
        assert digest(executable) == executable_sha
        assert all(digest(ROOT / name) == sha for name, sha in source_pins.items())
        assert all(digest(Path(name)) == sha for name, sha in system_pins.items())
        result.update(
            qualified=True,
            cases=CASES,
            run_id=run_id,
            attempt=attempt,
            source_pins=source_pins,
            system_pins=system_pins,
            executable_sha256=executable_sha,
            compile=compiler_terminal,
            native=native_terminal,
            observation=facts,
            raw={path.name: digest(path) for path in directory.iterdir() if path.is_file()},
        )
        print(
            "PASS native XI2 property cookies: property-created, property-modified, property-deleted"
        )
        return 0
    except BaseException as error:
        result["failure_type"] = type(error).__name__
        print("FAIL native XI2 property-cookie qualification", file=sys.stderr)
        return 1
    finally:
        record(directory / "receiving.json", result)


if __name__ == "__main__":
    sys.exit(main())
