"""Execute shipped identity writers without registering or launching an application."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid

OPERATION_SECONDS = 5
RETIREMENT_SECONDS = 5
PR_SET_CHILD_SUBREAPER = 36
IDENTIFIER_PATTERN = re.compile(
    r"fr\.b519hs\.(clone|shortcut)\.([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
)
FAULTS = [
    "nonzero",
    "valid-nonzero",
    "empty",
    "malformed",
    "missing-newline",
    "extra-newline",
    "multiple-records",
    "nul",
]
OWNERSHIP_CLOSED = True
ACTIVE_CHILDREN = {}


def native_port():
    """Port only the fixed native argv boundary; success uses the host's actual UUID source."""
    operation, *arguments = sys.argv[1:]
    if operation == "stat":
        if len(arguments) != 3 or arguments[:2] != ["-f", "%d:%i"]:
            raise ValueError("Invalid native stat boundary arguments")
        entry = os.lstat(arguments[2])
        print(str(entry.st_dev) + ":" + str(entry.st_ino))
        return 0
    if operation != "uuidgen" or arguments:
        raise ValueError("Invalid native UUID generator boundary arguments")
    with open(os.environ["OWNED_UUID_CALLS"], "ab") as receipt:
        receipt.write(b"called\n")
    mode = os.environ.get("OWNED_UUID_FAULT", "")
    value = b"01234567-89AB-CDEF-0123-456789ABCDEF"
    if mode:
        data = {
            "nonzero": b"",
            "valid-nonzero": value + b"\n",
            "empty": b"",
            "malformed": b"invalid\n",
            "missing-newline": value,
            "extra-newline": value + b"\n\n",
            "multiple-records": value + b"\n" + value + b"\n",
            "nul": value + b"\0\n",
        }[mode]
        sys.stdout.buffer.write(data)
        return 73 if mode in ["nonzero", "valid-nonzero"] else 0
    if sys.platform == "darwin":
        child = subprocess.run(["/usr/bin/uuidgen"], capture_output=True, check=False)
        sys.stdout.buffer.write(child.stdout)
        sys.stderr.buffer.write(child.stderr)
        if child.returncode < 0:
            status = 128 - child.returncode
            print(
                "Native UUID fixture child terminated by signal "
                + str(-child.returncode)
                + " (raw="
                + str(child.returncode)
                + ", status="
                + str(status)
                + ")",
                file=sys.stderr,
            )
            return status
        return child.returncode
    if sys.platform not in ["linux", "win32"]:
        raise RuntimeError("No supported native UUID test boundary")
    print(uuid.uuid4())
    return 0


def executable(path, source):
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def retire_group(group, deadline):
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
        except PermissionError:
            # Darwin can refuse this read while an exiting group is retiring.
            # Only its later ESRCH proves closure; a lasting refusal stays unknown.
            pass
        time.sleep(0.01)
    return False


def finish(child):
    global OWNERSHIP_CLOSED
    try:
        output, errors = child.communicate(timeout=OPERATION_SECONDS)
    except (subprocess.TimeoutExpired, InterruptedError) as error:
        deadline = time.monotonic() + RETIREMENT_SECONDS
        # No poll or wait has released the freshly created leader's PID custody.
        if child.returncode is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            child.communicate(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise RuntimeError("Owned identity child retirement unknown; retain fixture") from error
        if retire_group(child.pid, deadline):
            ACTIVE_CHILDREN.pop(child.pid)
        OWNERSHIP_CLOSED = not ACTIVE_CHILDREN
        raise RuntimeError("Owned identity child interrupted; retain fixture") from error
    if not retire_group(child.pid, time.monotonic() + RETIREMENT_SECONDS):
        raise RuntimeError("Owned identity descendants remain; retain fixture")
    ACTIVE_CHILDREN.pop(child.pid)
    OWNERSHIP_CLOSED = not ACTIVE_CHILDREN
    return child.returncode, output, errors


def run(shell, script, arguments, environment):
    global OWNERSHIP_CLOSED
    OWNERSHIP_CLOSED = False
    child = subprocess.Popen(
        [str(shell), str(script), *arguments],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    ACTIVE_CHILDREN[child.pid] = child
    return finish(child)


def boundary(source, marker):
    if source.count(marker) != 1:
        raise ValueError("Actual identity source boundary must be unique: " + marker)
    return source[: source.index(marker) + len(marker)]


def fixture(resources, root):
    root.mkdir(mode=0o700)
    copies, binary, home = root / "resources", root / "bin", root / "home"
    for directory in [copies, binary, home]:
        directory.mkdir(mode=0o700)
    for name in [
        "clone_app.sh",
        "make_shortcut.sh",
        "reserve_bundle.sh",
        "quote_launcher_values.py",
    ]:
        (copies / name).write_bytes((resources / name).read_bytes())
    command = shlex.quote(sys.executable) + " -B " + shlex.quote(str(Path(__file__).resolve()))
    generator = binary / "uuidgen"
    executable(generator, "#!/bin/sh\nexec " + command + ' uuidgen "$@"\n')
    helper = (copies / "reserve_bundle.sh").read_text(encoding="utf-8")
    if helper.count("/usr/bin/uuidgen") not in [0, 1]:
        raise ValueError("The shared UUID command has more than one owner")
    helper = helper.replace("/usr/bin/uuidgen", shlex.quote(str(generator)))
    if sys.platform != "darwin":
        native_stat = binary / "stat"
        executable(native_stat, "#!/bin/sh\nexec " + command + ' stat "$@"\n')
        helper = helper.replace("/usr/bin/stat", shlex.quote(str(native_stat)))
    (copies / "reserve_bundle.sh").write_text(helper, encoding="utf-8")
    executable(
        binary / "date",
        """#!/bin/sh
if [ "$#" = 0 ]; then printf '%s\\n' "$OWNED_DATE_TEXT"; exit 0; fi
[ "$#" = 1 ] && [ "$1" = '+%s' ] || exit 91
printf '%s\\n' "$OWNED_EPOCH"
""",
    )
    executable(
        binary / "mktemp",
        """#!/bin/sh
[ "$#" = 2 ] && [ "$1" = -d ] && [ "$2" = "$OWNED_EXPECTED_TEMPLATE" ] || exit 92
created=$(/usr/bin/mktemp -d "$OWNED_TMP_TEMPLATE") || exit $?
printf '%s' "$created" > "$OWNED_WORKSPACE_RECEIPT" || exit $?
printf '%s\\n' "$created"
""",
    )
    executable(
        binary / "qlmanage",
        """#!/bin/sh
[ "$#" = 6 ] && [ "$1" = -t ] && [ "$2" = -s ] && [ "$3" = 1024 ] && [ "$4" = -o ] && [ -f "$6" ] || exit 93
printf '%s\\n' qlmanage >> "$OWNED_ICON_RECEIPT"
printf png > "$5/preview.png"
""",
    )
    executable(
        binary / "sips",
        """#!/bin/sh
[ "$#" = 6 ] && [ "$1" = -z ] && [ "$2" = "$3" ] && [ -f "$4" ] && [ "$5" = --out ] || exit 94
printf '%s\\n' sips >> "$OWNED_ICON_RECEIPT"
printf png > "$6"
""",
    )
    executable(
        binary / "iconutil",
        """#!/bin/sh
[ "$#" = 5 ] && [ "$1" = -c ] && [ "$2" = icns ] && [ -d "$3" ] && [ "$4" = -o ] || exit 95
printf '%s\\n' iconutil >> "$OWNED_ICON_RECEIPT"
printf icon > "$5"
""",
    )
    app = root / "Source.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/Source").write_text("inert", encoding="utf-8")
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "Source",
                "CFBundleIdentifier": "org.fixture.source",
            }
        )
    )
    buddy = binary / "PlistBuddy"
    executable(
        buddy,
        """#!/bin/sh
[ "$#" = 3 ] && [ "$1" = -c ] && [ "$2" = 'Print :CFBundleExecutable' ] && [ "$3" = "$OWNED_SOURCE/Contents/Info.plist" ] && [ -f "$3" ] || exit 96
printf '%s\\n' Source
""",
    )
    env = dict(
        os.environ,
        HOME=str(home),
        PATH=str(binary) + os.pathsep + os.environ["PATH"],
        LC_ALL="C",
        OWNED_SOURCE=str(app),
        OWNED_EPOCH=str(int(time.time())),
        OWNED_DATE_TEXT="owned frozen clock",
        OWNED_UUID_FAULT="",
    )
    return copies, env, buddy


def clone_program(source, buddy, full_prefix):
    # Common Bash executes only the pre-allocation failure path. Native zsh also
    # executes its actual family/profile prefix and the actual metadata writers.
    marker = 'log "USER_DATA_DIR=$USER_DATA_DIR"' if full_prefix else 'log "SRC_EXE=$SRC_EXE"'
    program = boundary(source, marker)
    if program.count("/usr/libexec/PlistBuddy") != 1:
        raise ValueError("Actual metadata command must have one owner")
    program = program.replace("/usr/libexec/PlistBuddy", shlex.quote(str(buddy)))
    if not full_prefix:
        return program + "\nexit 0\n"
    info_start = 'safe_name_xml="$(/usr/bin/python3 "$QUOTE_HELPER" xml "$safe_name")"'
    if source.count(info_start) != 1:
        raise ValueError("Actual Info.plist writer must have one owner")
    info = source[source.index(info_start) :].split("\nPLIST\n", 1)[0] + "\nPLIST\n"
    launcher_start = "cat > \"$LAUNCHER\" <<'LAUNCHER_HEAD'"
    if source.count(launcher_start) != 1 or source.count('LAUNCHER="$MACOS/launcher"') != 1:
        raise ValueError("Actual launcher writer must have one owner")
    launcher = (
        source[source.index(launcher_start) :].split("\nLAUNCHER_BODY\n", 1)[0]
        + "\nLAUNCHER_BODY\n"
    )
    return (
        program
        + "\n"
        + info
        + '\nLAUNCHER="$MACOS/launcher"\n'
        + launcher
        + "\nCLONE_COMPLETE=1\nprintf '%s\\n' \"$DEST\"\n"
    )


def invocation(copies, env, root, caller, label, color, full_clone=False):
    current = dict(
        env,
        OWNED_UUID_CALLS=str(root / (label + ".uuid-calls")),
        OWNED_WORKSPACE_RECEIPT=str(root / (label + ".workspace")),
        OWNED_TMP_TEMPLATE=str(root / (label + ".XXXXXX")),
        OWNED_EXPECTED_TEMPLATE="/tmp/"
        + ("shortcut" if caller == "shortcut" else "appcloner")
        + ".XXXXXX",
        OWNED_ICON_RECEIPT=str(root / (label + ".icons")),
    )
    if caller == "shortcut":
        return (
            copies / "make_shortcut.sh",
            ["Identity Collision", "target", "/Applications/Fixture.app", color, "label"],
            current,
        )
    diagnostic = root / (label + ".log")
    diagnostic.write_bytes(b"")
    return (
        copies / ("full-clone-prefix.sh" if full_clone else "clone-failure-prefix.sh"),
        [env["OWNED_SOURCE"], "Identity Collision", "", "", "tint", "", "0", str(diagnostic)],
        current,
    )


def calls(environment):
    path = Path(environment["OWNED_UUID_CALLS"])
    if not path.exists():
        return 0
    data = path.read_bytes()
    if data != b"called\n" * data.count(b"called\n"):
        raise ValueError("Native UUID invocation receipt is invalid")
    return data.count(b"called\n")


def positive_pair(resources, shell, root, caller, color):
    global OWNERSHIP_CLOSED
    copies, env, buddy = fixture(resources, root)
    source = (copies / "clone_app.sh").read_text(encoding="utf-8")
    executable(copies / "full-clone-prefix.sh", clone_program(source, buddy, True))
    children = []
    try:
        for index in range(2):
            script, arguments, child_env = invocation(
                copies, env, root, caller, str(index), color, True
            )
            OWNERSHIP_CLOSED = False
            child = subprocess.Popen(
                [str(shell), str(script), *arguments],
                env=child_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            ACTIVE_CHILDREN[child.pid] = child
            children.append((child, child_env))
        result = []
        for child, environment in children:
            status, output, errors = finish(child)
            if status != 0 or errors:
                raise RuntimeError(
                    "Actual identity writer failed: " + str((status, output, errors))
                )
            if not output.endswith(b"\n"):
                raise ValueError("Actual identity writer did not publish its path terminator")
            destination = Path(output[:-1].decode("utf-8"))
            metadata = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
            workspace = Path(
                Path(environment["OWNED_WORKSPACE_RECEIPT"]).read_text(encoding="utf-8")
            )
            if workspace.parent != root or workspace.exists():
                raise RuntimeError("Actual identity workspace has not retired")
            row = dict(
                destination=str(destination),
                identifier=metadata["CFBundleIdentifier"],
                inode=destination.stat().st_ino,
                uuid_calls=calls(environment),
                workspace_retired=True,
            )
            if caller == "clone":
                launcher = (destination / "Contents/MacOS/launcher").read_text(encoding="utf-8")
                values = re.findall(r"^UNIQUE_ID=.*$", launcher, re.MULTILINE)
                profiles = re.findall(r"^USER_DATA_DIR=.*$", launcher, re.MULTILINE)
                exports = re.findall(r"^export __CFBundleIdentifier=.*$", launcher, re.MULTILINE)
                if len(values) != 1 or len(profiles) != 1 or len(exports) != 1:
                    raise ValueError("Actual clone consumer assignments must be unique")
                command = root / (str(child.pid) + ".consumer.sh")
                executable(
                    command,
                    values[0]
                    + "\n"
                    + profiles[0]
                    + "\n"
                    + exports[0]
                    + '\nprintf \'%s\\0%s\\0\' "$__CFBundleIdentifier" "$USER_DATA_DIR"\n',
                )
                consumer_status, consumer_output, consumer_errors = run(
                    shell, command, [], environment
                )
                fields = consumer_output.split(b"\0")
                if consumer_status != 0 or consumer_errors or len(fields) != 3 or fields[-1] != b"":
                    raise RuntimeError("Actual clone assignment consumer did not complete")
                row.update(
                    launcher_identifier=fields[0].decode("utf-8"), profile=fields[1].decode("utf-8")
                )
                if (
                    row["launcher_identifier"] != row["identifier"]
                    or not Path(row["profile"]).is_dir()
                ):
                    raise AssertionError("Actual clone identifier and profile consumers diverged")
            result.append(row)
        return dict(
            caller=caller,
            creations=result,
            distinct_destinations=len({r["destination"] for r in result}) == 2,
            distinct_identifiers=len({r["identifier"] for r in result}) == 2,
            distinct_profiles=caller != "clone" or len({r["profile"] for r in result}) == 2,
            execution_scope="actual-full-shortcut-generator"
            if caller == "shortcut"
            else "actual-zsh-clone-family/profile-prefix-and-actual-Info.plist/launcher-writers",
        )
    finally:
        for child, _ in children:
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.communicate(timeout=RETIREMENT_SECONDS)
                if not retire_group(child.pid, time.monotonic() + RETIREMENT_SECONDS):
                    raise RuntimeError("A concurrent identity child did not retire; retain fixture")
                ACTIVE_CHILDREN.pop(child.pid)
                OWNERSHIP_CLOSED = not ACTIVE_CHILDREN


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--shell", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--palette", type=Path, required=True)
    args = parser.parse_args()
    if (
        sys.platform == "linux"
        and ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0
    ):
        raise OSError(ctypes.get_errno(), "Private child observer admission failed")
    if sys.platform not in ["linux", "darwin"]:
        raise RuntimeError("Physical identity fixtures require POSIX process custody")
    if os.geteuid() == 0:
        raise RuntimeError("Physical identity fixtures require an actual non-root host")
    colors = re.findall(
        r'^hex = "(#[0-9a-fA-F]{6})"$', args.palette.read_text(encoding="utf-8"), re.MULTILINE
    )
    if not colors:
        raise ValueError("The native palette must provide the fixture color")
    args.fixture.mkdir(mode=0o700)
    positive = [
        positive_pair(args.resources, args.shell, args.fixture / "shortcut", "shortcut", colors[0])
    ]
    if args.shell.name == "zsh":
        positive.append(
            positive_pair(args.resources, args.shell, args.fixture / "clone", "clone", colors[0])
        )
    failures = [
        row["caller"]
        for row in positive
        if not row["distinct_destinations"]
        or not row["distinct_identifiers"]
        or not row["distinct_profiles"]
        or any(
            not IDENTIFIER_PATTERN.fullmatch(c["identifier"])
            or not c["identifier"].startswith("fr.b519hs." + row["caller"] + ".")
            or c["uuid_calls"] != 1
            for c in row["creations"]
        )
    ]
    report = dict(
        positive=positive,
        faults=[],
        admission=[],
        helper_generations={},
        failures=failures,
        ownership_closed=OWNERSHIP_CLOSED,
        native_uuidgen="/usr/bin/uuidgen"
        if sys.platform == "darwin"
        else "test-only actual CPython uuid4",
        native_clone_scope="actual-zsh-profile-and-writers"
        if args.shell.name == "zsh"
        else "deferred to native zsh; Common does not rewrite family discovery",
    )
    if failures:
        report["state"] = "FAILED"
        print(json.dumps(report))
        return 1
    copies, env, buddy = fixture(args.resources, args.fixture / "contracts")
    executable(
        copies / "clone-failure-prefix.sh",
        clone_program((copies / "clone_app.sh").read_text(encoding="utf-8"), buddy, False),
    )
    contract = args.fixture / "contracts"
    for kind in ["clone", "shortcut"]:
        command = contract / (kind + ".sh")
        executable(
            command,
            'set -euo pipefail\nsource "$1"\nnew_bundle_identifier "$2"\nnew_bundle_identifier "$2"\n',
        )
        current = dict(env, OWNED_UUID_CALLS=str(contract / (kind + ".uuid-calls")))
        status, output, errors = run(
            args.shell, command, [str(copies / "reserve_bundle.sh"), kind], current
        )
        values = output.decode("utf-8").splitlines()
        if (
            status != 0
            or errors
            or len(values) != 2
            or len(set(values)) != 2
            or any(
                not IDENTIFIER_PATTERN.fullmatch(value)
                or not value.startswith("fr.b519hs." + kind + ".")
                for value in values
            )
            or calls(current) != 2
        ):
            raise AssertionError(
                "Both shared identity kinds must execute the native generator exactly once per result"
            )
        report["helper_generations"][kind] = values
    for index, arguments in enumerate([[], ["unknown"], ["clone", "extra"]]):
        command = contract / ("admission-" + str(index) + ".sh")
        executable(command, 'set -euo pipefail\nsource "$1"\nshift\nnew_bundle_identifier "$@"\n')
        current = dict(env, OWNED_UUID_CALLS=str(contract / ("admission-" + str(index) + ".calls")))
        status, output, errors = run(
            args.shell, command, [str(copies / "reserve_bundle.sh"), *arguments], current
        )
        if status != 1 or output or not errors or calls(current) != 0:
            raise AssertionError(
                "Invalid shared identity arguments must fail before the native generator"
            )
        report["admission"].append(dict(arguments=arguments, status=status, uuid_calls=0))
    for caller in ["clone", "shortcut"]:
        for mode in FAULTS:
            case = args.fixture / (caller + "-" + mode)
            copies, env, buddy = fixture(args.resources, case)
            executable(
                copies / "clone-failure-prefix.sh",
                clone_program((copies / "clone_app.sh").read_text(encoding="utf-8"), buddy, False),
            )
            script, arguments, current = invocation(
                copies, dict(env, OWNED_UUID_FAULT=mode), case, caller, mode, colors[0]
            )
            status, output, errors = run(args.shell, script, arguments, current)
            expected = 73 if mode in ["nonzero", "valid-nonzero"] else 1
            workspace_created = Path(current["OWNED_WORKSPACE_RECEIPT"]).exists()
            destination_parent = Path(current["HOME"]) / (
                "Applications" if caller == "clone" else "Desktop"
            )
            if (
                status != expected
                or not (output or errors)
                or calls(current) != 1
                or workspace_created
                or destination_parent.exists()
            ):
                raise AssertionError(
                    "A failed UUID generator must refuse before allocating any bundle/workspace: "
                    + repr((caller, mode, status, output, errors, workspace_created))
                )
            report["faults"].append(
                dict(
                    caller=caller,
                    mode=mode,
                    status=status,
                    uuid_calls=1,
                    bundle_parent_created=False,
                    workspace_created=False,
                    owned_group_retired=True,
                )
            )
    report.update(state="PASSED", ownership_closed=OWNERSHIP_CLOSED)
    print(json.dumps(report))
    return 0


def interrupted(_signal, _frame):
    raise InterruptedError("Owned identity probe interrupted")


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] in ["uuidgen", "stat"]:
            sys.exit(native_port())
        signal.signal(signal.SIGTERM, interrupted)
        sys.exit(main())
    except Exception as error:
        print(json.dumps(dict(state="ERROR", ownership_closed=OWNERSHIP_CLOSED, error=str(error))))
        sys.exit(1)
