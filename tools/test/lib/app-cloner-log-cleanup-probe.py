"""Execute shipped CLI prefixes with actual finite kernel file limits, without launching apps."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import resource
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

OPERATION_SECONDS = 5
RETIREMENT_SECONDS = 5
PR_SET_CHILD_SUBREAPER = 36
OWNERSHIP_CLOSED = True


def executable(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def retire_group(group, deadline):
    # Linux's private observer becomes the parent of orphaned fixture children.
    # This is a process-parenting boundary, not application business logic.
    while time.monotonic() < deadline:
        if sys.platform == "linux":
            while True:
                try:
                    child, _ = os.waitpid(-group, os.WNOHANG)
                except ChildProcessError:
                    break
                if not child:
                    break
        try:
            os.killpg(group, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.01)
    return False


def execute(shell, script, arguments, environment, limit):
    global OWNERSHIP_CLOSED

    def policy():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        if limit is not None:
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))

    OWNERSHIP_CLOSED = False
    child = subprocess.Popen(
        [str(shell), str(script), *arguments],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        preexec_fn=policy,
    )
    try:
        output, errors = child.communicate(timeout=OPERATION_SECONDS)
    except (subprocess.TimeoutExpired, InterruptedError) as error:
        deadline = time.monotonic() + RETIREMENT_SECONDS
        # Only an unreaped leader proves this newly created group still belongs to us.
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
        try:
            child.communicate(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise RuntimeError("Owned CLI retirement unknown; retain exact fixture") from error
        OWNERSHIP_CLOSED = retire_group(child.pid, deadline)
        raise RuntimeError(
            "Owned CLI timed out; retain exact fixture: " + environment["OWNED_CASE"]
        ) from error
    OWNERSHIP_CLOSED = retire_group(child.pid, time.monotonic() + RETIREMENT_SECONDS)
    if not OWNERSHIP_CLOSED:
        raise RuntimeError("Owned CLI descendants remain; retain exact fixture")
    return child.returncode, output.decode("utf-8"), errors.decode("utf-8")


def prefix(source, boundary):
    if source.count(boundary) != 1:
        raise ValueError("Actual CLI source boundary must be unique: " + boundary)
    return source[: source.index(boundary) + len(boundary)]


def observation(resources, shell, root, caller, mode, color):
    case = root / (caller + "-" + mode)
    case.mkdir(mode=0o700)
    provided = resources
    resources = case / "resources"
    resources.mkdir()
    for name in [
        "clone_app.sh",
        "make_shortcut.sh",
        "reserve_bundle.sh",
        "quote_launcher_values.py",
    ]:
        shutil.copyfile(provided / name, resources / name)
    home_name = {"result-backslash-c": "home\\c", "result-backslash-t": "home\\t"}.get(mode, "home")
    home, binary = case / home_name, case / "bin"
    home.mkdir()
    binary.mkdir()
    app_name = {"backslash-c": "Source\\c.app", "backslash-t": "Source\\t.app"}.get(
        mode, "Source.app"
    )
    app = case / app_name
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/Source").write_text("inert", encoding="utf-8")
    log, created = case / "owned.log", case / "created-workspace"
    log.write_bytes(b"")
    destination = home / ("Desktop" if caller == "shortcut" else "Applications") / "Log Limit.app"
    environment = dict(os.environ)
    environment.update(
        HOME=str(home),
        PATH=str(binary) + os.pathsep + environment["PATH"],
        LC_ALL="C",
        OWNED_LOG=str(log),
        OWNED_SOURCE=str(app),
        OWNED_DEST=str(destination),
        OWNED_CASE=str(case),
        OWNED_HEALTHY_SIZE=str(case / "healthy-prefix-size"),
        OWNED_MODE=mode,
        OWNED_WORKSPACE=str(created),
        OWNED_STAT_FAULT="",
        OWNED_TEMPLATE=str(case / "workspace.XXXXXX"),
        OWNED_EXPECTED_TEMPLATE="/tmp/"
        + ("shortcut" if caller == "shortcut" else "appcloner")
        + ".XXXXXX",
        OWNED_TEE_PID=str(case / "tee.pid"),
        OWNED_TEE_CONTROL=str(case / "tee-control"),
        OWNED_TEE_CLOSED=str(case / "tee-closed"),
    )
    executable(
        binary / "mktemp",
        """#!/bin/sh
[ "$#" = 2 ] && [ "$1" = -d ] && [ "$2" = "$OWNED_EXPECTED_TEMPLATE" ] || exit 91
workspace=$(/usr/bin/mktemp -d "$OWNED_TEMPLATE") || exit $?
printf '%s' "$workspace" > "$OWNED_WORKSPACE" || exit $?
printf '%s\\n' "$workspace"
""",
    )
    executable(
        binary / "PlistBuddy",
        """#!/bin/sh
[ "$#" = 3 ] && [ "$1" = -c ] && [ "$2" = 'Print :CFBundleExecutable' ] && [ "$3" = "$OWNED_SOURCE/Contents/Info.plist" ] || exit 92
case "$OWNED_MODE" in
 *foreign) mv "$OWNED_DEST" "$OWNED_DEST.held"; mkdir "$OWNED_DEST"; printf foreign > "$OWNED_DEST/marker" ;;
 *refusal) chmod 500 "$HOME/Applications" ;;
esac
case "$OWNED_MODE" in
 deadpipe*) printf '%s\\n' stop > "$OWNED_TEE_CONTROL"; [ "$(cat "$OWNED_TEE_CLOSED")" = closed ] || exit 93 ;;
esac
printf '%s\\n' Source
""",
    )
    executable(
        binary / "python3",
        """#!/bin/sh
[ "$#" = 2 ] && [ "$1" = -c ] && [ "$2" = 'import sys' ] || exit 97
exec "$OWNED_PYTHON" "$@"
""",
    )
    environment["OWNED_PYTHON"] = sys.executable
    # FIFO admission proves the controlled reader has closed fd0 before metadata returns.
    # The second FIFO acknowledges closure without polling an unbounded marker loop.
    if mode.startswith("deadpipe"):
        os.mkfifo(case / "tee-control", 0o600)
        os.mkfifo(case / "tee-closed", 0o600)
        tee_body = """case \"$OWNED_MODE\" in
deadpipe*)
read control < "$OWNED_TEE_CONTROL" || exit 94
[ "$control" = stop ] || exit 95
exec 0<&-
printf closed > "$OWNED_TEE_CLOSED"
;;
*) exec /usr/bin/tee "$@" ;;
esac
"""
    else:
        tee_body = 'exec /usr/bin/tee "$@"\n'
    executable(
        binary / "tee",
        """#!/bin/sh
[ "$#" = 2 ] && [ "$1" = -a ] && [ "$2" = "$OWNED_LOG" ] || exit 96
printf '%s' "$$" > "$OWNED_TEE_PID.tmp" || exit $?
/bin/mv "$OWNED_TEE_PID.tmp" "$OWNED_TEE_PID" || exit $?
"""
        + tee_body,
    )
    executable(
        binary / "qlmanage",
        """#!/bin/sh
[ "$#" = 6 ] && [ "$1" = -t ] && [ "$2" = -s ] && [ "$3" = 1024 ] && [ "$4" = -o ] && [ -f "$6" ] || exit 98
printf png > "$5/preview.png"
""",
    )
    executable(
        binary / "sips",
        """#!/bin/sh
[ "$#" = 6 ] && [ "$1" = -z ] && [ "$2" = "$3" ] && [ -f "$4" ] && [ "$5" = --out ] || exit 99
printf png > "$6"
""",
    )
    executable(
        binary / "iconutil",
        """#!/bin/sh
[ "$#" = 5 ] && [ "$1" = -c ] && [ "$2" = icns ] && [ -d "$3" ] && [ "$4" = -o ] || exit 100
printf icon > "$5"
""",
    )
    limited = mode not in [
        "healthy",
        "child-default",
        "backslash-c",
        "backslash-t",
        "result-backslash-c",
        "result-backslash-t",
    ]
    if caller == "clone":
        source = (resources / "clone_app.sh").read_text(encoding="utf-8")
        script_text = prefix(source, 'log "SRC_EXE=$SRC_EXE"') + "\nexit 0\n"
        if script_text.count("/usr/libexec/PlistBuddy") != 1:
            raise ValueError("Actual native metadata command must be unique")
        script_text = script_text.replace(
            "/usr/libexec/PlistBuddy", shlex.quote(str(binary / "PlistBuddy"))
        )
        limit = None
        arguments = [str(app), "Log Limit", "", "", "tint", "", "0", str(log)]
        if mode.startswith("result-backslash-"):
            tail_marker = "CLONE_COMPLETE=1\n"
            if source.count(tail_marker) != 1:
                raise ValueError("Actual CLI success tail must be unique")
            actual_tail = source[source.index(tail_marker) :]
            script_text = script_text[: -len("exit 0\n")] + actual_tail

        if mode == "child-default":
            signal_child = case / "signal-child"
            executable(
                signal_child,
                '#!/bin/sh\nkill -XFSZ $$\nprintf survived > "$OWNED_SURVIVED"\n',
            )
            environment["OWNED_SURVIVED"] = str(case / "child-survived")
            script_text = (
                script_text[: -len("exit 0\n")]
                + "set +e\n"
                + shlex.quote(str(signal_child))
                + '\nchild_status=$?\nexit "$child_status"\n'
            )
    elif caller == "shortcut":
        source = (resources / "make_shortcut.sh").read_text(encoding="utf-8")
        boundary = "# render SVG to PNG using QuickLook"
        if source.count(boundary) != 1:
            raise ValueError("Actual shortcut source boundary must be unique")
        script_text = source[: source.index(boundary)] + "\nexit 0\n"
        script_text = (
            source[: source.index(boundary)] + '\nwc -c < "$SVG" > "$OWNED_HEALTHY_SIZE"\nexit 0\n'
        )
        limit = None
        arguments = ["Log Limit", "target", "app", color, "label"]
        if mode.startswith("result-backslash-"):
            script_text = source

    else:
        script_text = """set -euo pipefail
source "$1"
initialize_bundle_creation
trap cleanup_bundle_creation EXIT
reserve_owned_bundle_directory "$HOME/Applications/Log Limit.app"
TMPDIR_WORK="$(mktemp -d /tmp/appcloner.XXXXXX)"
CLONE_COMPLETE=1
chmod 500 "$OWNED_CASE"
exit "$2"
"""
        (home / "Applications").mkdir()
        limit, limited = None, False
        arguments = [
            str(resources / "reserve_bundle.sh"),
            "74" if mode == "refusal-primary" else "0",
        ]
    # Keep the shipped resource directory as SCRIPT_DIR while controlling the actual native boundary.
    script = resources / ("probe-" + case.name + ".sh")
    executable(script, script_text)
    healthy_bytes = None
    if limited:
        control = dict(environment, OWNED_MODE="healthy")
        control_status, _, _ = execute(shell, script, arguments, control, None)
        control_workspace = Path(created.read_text(encoding="utf-8"))
        if control_status != 0 or destination.exists() or control_workspace.exists():
            raise ValueError(
                "The same-fixture healthy control must actually allocate and retire both resources"
            )
        if caller == "clone":
            suffix = ("SRC_EXE=" + str(app / "Contents/MacOS/Source") + "\n").encode("utf-8")
            data = log.read_bytes()
            if not data.endswith(suffix):
                raise ValueError(
                    "The actual healthy log must end at the post-reservation source boundary"
                )
            healthy_bytes = len(data) - len(suffix)
            limit = healthy_bytes + 1
        else:
            healthy_bytes = int((case / "healthy-prefix-size").read_text(encoding="ascii"))
            limit = healthy_bytes - 1
        if limit <= 0:
            raise ValueError("The actual healthy prefix must establish a finite positive quota")
        log.write_bytes(b"")
        created.unlink()
        if (case / "tee.pid").exists():
            (case / "tee.pid").unlink()
    status, output, errors = execute(
        shell, script, arguments, environment, limit if limited else None
    )
    workspace = Path(created.read_text(encoding="utf-8"))
    if workspace.parent != case or not workspace.name.startswith("workspace."):
        raise ValueError("The actual allocator must report its exact private workspace")
    tee_closed = True
    if caller == "clone":
        tee_pid = int((case / "tee.pid").read_text(encoding="ascii"))
        try:
            os.kill(tee_pid, 0)
            tee_closed = False
        except ProcessLookupError:
            pass
    marker = destination / "marker"
    actual_source_line = next(
        (line for line in log.read_bytes().split(b"\n") if line.startswith(b"=== SOURCE=")),
        b"",
    )
    row = dict(
        normalized_status=(128 - status if status < 0 else status),
        termination_kind="signal" if status < 0 else "exit",
        execution_scope=(
            "actual-clone-prefix-and-success-tail"
            if caller == "clone" and mode.startswith("result-backslash-")
            else "actual-clone-prefix"
            if caller == "clone"
            else "actual-full-shortcut-generator"
            if caller == "shortcut" and mode.startswith("result-backslash-")
            else "actual-shortcut-svg-prefix"
            if caller == "shortcut"
            else "actual-owned-cleanup-api"
        ),
        source_app=str(app),
        result_path=str(destination),
        result_path_exact=output == str(destination) + "\n",
        source_line_hex=actual_source_line.hex(),
        caller=caller,
        mode=mode,
        status=status,
        limit=limit if limited else None,
        healthy_prefix_bytes=healthy_bytes,
        actual_log_bytes=log.stat().st_size,
        workspace_created=True,
        log_source_exact=("=== SOURCE=" + str(app) + "\n").encode("utf-8") in log.read_bytes(),
        workspace_exists=workspace.exists(),
        destination_exists=destination.exists(),
        foreign_marker=marker.read_text(encoding="utf-8") if marker.exists() else None,
        ownership_closed=OWNERSHIP_CLOSED and tee_closed,
        child_survived=(case / "child-survived").exists(),
        output=output,
        stderr=errors,
    )
    case.chmod(0o700)
    home.chmod(0o700)
    if (home / "Applications").exists():
        (home / "Applications").chmod(0o700)
    return row


def interrupted(_signal, _frame):
    raise InterruptedError("The exact CLI probe was interrupted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--shell", type=Path, required=True)
    parser.add_argument("--palette", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    if sys.implementation.name != "cpython" or sys.version_info < (3, 8):
        raise RuntimeError("The actual CLI probe requires CPython 3.8 or newer")
    palette = re.findall(
        r'^hex = "(#[0-9a-fA-F]{6})"$',
        args.palette.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not palette:
        raise ValueError("The canonical native palette must supply the fixture color")
    color = palette[0]
    if sys.platform == "linux":
        if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Private Linux child observer admission failed")
    elif sys.platform != "darwin":
        raise RuntimeError("Physical finite file limits require a supported POSIX host")
    if os.geteuid() == 0:
        raise RuntimeError("Physical permission vectors require an actual non-root host")
    args.fixture.mkdir(mode=0o700)
    cases = []
    for caller, modes in [
        (
            "clone",
            [
                "healthy",
                "finite",
                "foreign",
                "refusal",
                "deadpipe",
                "deadpipe-foreign",
                "deadpipe-refusal",
                "child-default",
                "backslash-c",
                "backslash-t",
                "result-backslash-c",
                "result-backslash-t",
            ],
        ),
        ("shortcut", ["healthy", "finite", "result-backslash-c", "result-backslash-t"]),
        ("owner", ["refusal-zero", "refusal-primary"]),
    ]:
        for mode in modes:
            cases.append(observation(args.resources, args.shell, args.fixture, caller, mode, color))
    failures = []
    for row in cases:
        expected = (
            0
            if row["mode"]
            in [
                "healthy",
                "backslash-c",
                "backslash-t",
                "result-backslash-c",
                "result-backslash-t",
            ]
            else (
                74
                if row["mode"] == "refusal-primary"
                else (1 if row["caller"] == "owner" else 128 + signal.SIGXFSZ)
            )
        )
        foreign = row["mode"].endswith("foreign")
        refusal = (
            row["mode"].endswith("refusal")
            or row["caller"] == "owner"
            or row["mode"].startswith("result-backslash-")
        )
        if (
            row["normalized_status"] != expected
            or not row["ownership_closed"]
            or (row["workspace_exists"] != (row["caller"] == "owner"))
            or row["destination_exists"] != (foreign or refusal)
            or (foreign and row["foreign_marker"] != "foreign")
            or row["child_survived"]
            or (row["mode"].startswith("result-backslash-") and not row["result_path_exact"])
            or (
                row["caller"] == "clone"
                and row["limit"] is not None
                and row["actual_log_bytes"] != row["limit"]
            )
            or (
                row["mode"] in ["healthy", "backslash-c", "backslash-t"]
                and row["caller"] == "clone"
                and not row["log_source_exact"]
            )
        ):
            failures.append(row["caller"] + ":" + row["mode"])
    print(
        json.dumps(
            dict(
                state="PASSED" if not failures else "FAILED",
                ownership_closed=OWNERSHIP_CLOSED and all(row["ownership_closed"] for row in cases),
                cases=cases,
                failures=failures,
                shell=str(args.shell),
                source_kind="actual-cli-source-with-explicit-prefix-scopes",
            )
        )
    )
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps(dict(state="ERROR", ownership_closed=OWNERSHIP_CLOSED, error=str(error))))
        sys.exit(1)
