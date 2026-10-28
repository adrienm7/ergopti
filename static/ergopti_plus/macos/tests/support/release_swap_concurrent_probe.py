# static/ergopti_plus/macos/tests/support/release_swap_concurrent_probe.py

"""Drive actual Lua-emitted swap commands at deterministic native rename barriers."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

CONTROL_TIMEOUT = 10
RETIREMENT_POLL_INTERVAL = 0.01
PR_SET_CHILD_SUBREAPER = 36


def own_detached_descendants():
    """Linux fixture custody adopts only this probe's detached worker descendants."""
    if sys.platform == "linux":
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
            raise OSError(
                ctypes.get_errno(), "The concurrent fixture could not retain descendant custody"
            )


def reap_owned_group(group):
    """Retire adopted exact-group children after its unreaped anchor was signalled."""
    if sys.platform != "linux":
        return
    deadline = time.monotonic() + CONTROL_TIMEOUT
    while True:
        try:
            child, _ = os.waitpid(-group, os.WNOHANG)
        except ChildProcessError:
            return
        if child != 0:
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("The exact adopted concurrent installer group did not retire")
        # Yield against the remaining named operation budget, without an unbounded wait.
        time.sleep(min(remaining, RETIREMENT_POLL_INTERVAL))


def load(name, path):
    """Import exact checked-out fixture owners without resolving another checkout."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def emitted(driver, root):
    """Compare the strict literal parser with real production Lua evaluation."""
    arming = load(
        "concurrent_arming", driver / "tests/support/modules/updater/release_arming_fixture.py"
    )
    physical = load("concurrent_physical", driver / "tests/support/release_swap_physical_probe.py")
    capture = (
        arming.CAPTURE.split("installer._getenv=", 1)[0] + "\nio.write(installer.SWAP_SCRIPT)\n"
    )
    result = subprocess.run(
        [arming.resolve_lua(), "-", str(driver), str(driver.parent / "_shared"), "", "", "", ""],
        input=capture,
        text=True,
        capture_output=True,
        timeout=CONTROL_TIMEOUT,
        check=True,
    )
    source = driver / "modules/updater/release_installer.lua"
    if result.stdout != physical.extract_program(source.read_text(encoding="utf-8")):
        raise RuntimeError("The physical concurrent probe does not match actual Lua bytes")
    return result.stdout, physical, arming


MOVER = r"""
import json,os,select,subprocess,sys
from pathlib import Path
source,target=map(Path,sys.argv[1:]);root=Path(os.environ['RENAME_CASE'])
app=root/'ErgoptiPlus.app';previous=Path(str(app)+'.previous');staged=root/'stage/app/ErgoptiPlus.app'
pairs={(str(app),str(previous)):'backup',(str(staged),str(app)):'publish',(str(previous),str(app)):'rollback'}
phase=pairs[(str(source),str(target))]
if phase==os.environ['RENAME_PHASE']:
 if target.exists() or target.is_symlink():raise RuntimeError('The exact rename target must be absent at admission')
 os.write(int(os.environ['RENAME_READY']), (json.dumps({'phase':phase,'pid':os.getpid(),'target':str(target)})+'\n').encode())
 ready,_,_=select.select([int(os.environ['RENAME_RELEASE'])],[],[],10)
 if not ready or os.read(ready[0],1)!=b'1':raise RuntimeError('The exact rename barrier was not released')
command=json.loads(os.environ['RENAME_COMMAND'])
if os.environ['RENAME_MUTANT']=='mv':command=['/bin/mv','--']
else:command += ['--release-rename','move']
status=subprocess.run(command+[str(source),str(target)],check=False).returncode
sys.exit(status)
"""


def rename_case(program, physical, root, phase, native, mutant):
    """Hold one real move after its shell guard, then publish a foreign directory."""
    base = root / phase
    base.mkdir()
    app, staged = base / "ErgoptiPlus.app", base / "stage/app/ErgoptiPlus.app"
    previous = Path(str(app) + ".previous")
    app.mkdir()
    staged.mkdir(parents=True)
    (app / "marker").write_text("original")
    (staged / "marker").write_text("chosen")
    physical.install_launcher(app, native)
    old = staged / "Contents/MacOS/ErgoptiPlus"
    old.parent.mkdir(parents=True)
    old.write_text("#!/bin/sh\nexit 99\n")
    old.chmod(0o700)
    mover, opener, observer = (base / name for name in ["mover", "opener", "stat"])
    mover.write_text("#!" + sys.executable + "\n" + MOVER)
    opener.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$2\" >> " + shlex.quote(str(base / "opened")) + "\n"
    )
    observer.write_text(
        "#!/bin/sh\nexec "
        + shlex.quote(sys.executable)
        + " -B "
        + shlex.quote(str(Path(physical.__file__).resolve()))
        + ' stat "$@"\n'
    )
    for path in [mover, opener, observer]:
        path.chmod(0o700)
    expected = '"$launcher" "$rename_flag" move'
    if program.count(expected) != 3:
        raise RuntimeError("All three canonical exclusive move boundaries must remain present")
    actual = program.replace(expected, shlex.quote(str(mover)))
    actual = actual.replace("/usr/bin/open", shlex.quote(str(opener)))
    if sys.platform != "darwin":
        actual = actual.replace("/usr/bin/stat", shlex.quote(str(observer)))
    if phase == "rollback":
        staged.parent.chmod(0o500)
    ready_read, ready_write = os.pipe()
    release_read, release_write = os.pipe()
    environment = dict(
        os.environ,
        RENAME_CASE=str(base),
        RENAME_PHASE=phase,
        RENAME_READY=str(ready_write),
        RENAME_RELEASE=str(release_read),
        RENAME_COMMAND=json.dumps(physical.launcher_command(native)),
        RENAME_MUTANT=mutant,
    )
    process = subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            'exec 3>&1\nexec "$@"',
            "start",
            *physical.launcher_command(native),
            "--release-rename",
            "lock",
            str(app),
            actual,
            "999999999",
            str(staged),
            str(previous),
        ],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        pass_fds=(ready_write, release_read),
        start_new_session=True,
    )
    os.close(ready_write)
    os.close(release_read)
    settled = False
    try:
        ready, _, _ = select.select([ready_read], [], [], CONTROL_TIMEOUT)
        if not ready:
            raise RuntimeError("The actual exclusive rename admission was not reached")
        admission = json.loads(os.read(ready_read, 4096))
        foreign = Path(admission["target"])
        foreign.mkdir()
        (foreign / "marker").write_text("foreign")
        identity = (foreign.stat().st_dev, foreign.stat().st_ino)
        os.write(release_write, b"1")
        output, error = process.communicate(timeout=CONTROL_TIMEOUT)
        settled = True
        observed = (foreign.stat().st_dev, foreign.stat().st_ino)
        nested = foreign / (
            source_name := (
                "ErgoptiPlus.app.previous" if phase == "rollback" else "ErgoptiPlus.app"
            )
        )
        record = {
            "name": phase,
            "exit": process.returncode,
            "stdout": output.decode(),
            "stderr": error.decode(),
            "foreign_identity_preserved": identity == observed,
            "foreign_marker": (foreign / "marker").read_text(),
            "nested_source": nested.exists(),
            "opened": (base / "opened").read_text() if (base / "opened").exists() else "",
            "previous_marker": (previous / "marker").read_text()
            if (previous / "marker").is_file()
            else None,
            "staged_exists": staged.exists(),
            "source_name": source_name,
        }
        if (
            record["exit"] != (5 if phase == "backup" else 8)
            or not record["foreign_identity_preserved"]
            or record["foreign_marker"] != "foreign"
            or record["nested_source"]
        ):
            raise AssertionError(
                "A concurrent directory must never be replaced or receive the source as a nested child: "
                + json.dumps(record)
            )
        if phase != "backup" and record["opened"]:
            raise AssertionError(
                "A refused concurrent publication must not open the foreign app: "
                + json.dumps(record)
            )
        return record
    finally:
        os.close(ready_read)
        os.close(release_write)
        staged.parent.chmod(0o700)
        if not settled:
            # Keep the unreaped group leader as the exact process-group capability.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=CONTROL_TIMEOUT)
            reap_owned_group(process.pid)


def lease_case(driver, physical, arming, root, native, mutant):
    """A second real detached installer must refuse before acknowledging ARMED."""
    base = root / "two-installers"
    base.mkdir()
    app = base / "ErgoptiPlus.app"
    app.mkdir()
    physical.install_launcher(app, native)
    (app / "marker").write_text("original")
    staged_apps = [base / ("stage" + str(index)) / "app/ErgoptiPlus.app" for index in [1, 2]]
    for index, staged in enumerate(staged_apps):
        staged.mkdir(parents=True)
        (staged / "marker").write_text("chosen" + str(index))
    opener = base / "open"
    opener.write_text("#!/bin/sh\nexit 0\n")
    opener.chmod(0o700)
    observer = base / "stat"
    observer.write_text(
        "#!/bin/sh\nexec "
        + shlex.quote(sys.executable)
        + " -B "
        + shlex.quote(str(Path(physical.__file__).resolve()))
        + ' stat "$@"\n'
    )
    observer.chmod(0o700)
    parent = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    owned = []
    try:
        receipts = []
        for staged in staged_apps:
            capture = subprocess.run(
                [
                    arming.resolve_lua(),
                    "-",
                    str(driver),
                    str(driver.parent / "_shared"),
                    str(app),
                    str(staged),
                    str(parent.pid),
                    "",
                ],
                input=arming.CAPTURE,
                text=True,
                capture_output=True,
                timeout=CONTROL_TIMEOUT,
                check=True,
            )
            command = json.loads(capture.stdout)
            command["args"][3] = command["args"][3].replace(
                "/usr/bin/open", shlex.quote(str(opener))
            )
            if sys.platform != "darwin":
                command["args"][3] = command["args"][3].replace(
                    "/usr/bin/stat", shlex.quote(str(observer))
                )
            if mutant == "no-lease":
                expected = '/usr/bin/nohup "$3/Contents/MacOS/ErgoptiPlus" --release-rename lock "$3" "$1" "$2" "$4" "$5"'
                replacement = '/usr/bin/nohup /bin/sh -c "$1" swap "$2" "$3" "$4" "$5"'
                if command["args"][1].count(expected) != 1:
                    raise RuntimeError(
                        "The lease mutant requires the exact detached production owner"
                    )
                command["args"][1] = command["args"][1].replace(expected, replacement)
            read_fd, write_fd = os.pipe()
            supervisor = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    arming.SUPERVISOR,
                    json.dumps([command["executable"], *command["args"]]),
                    str(write_fd),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pass_fds=(write_fd,),
                start_new_session=True,
            )
            os.close(write_fd)
            owned.append((supervisor, read_fd))
            receipts.append(arming.read_line(supervisor))
        if receipts[0]["status"] != 0 or receipts[0]["stdout"] != "ARMED\n":
            raise AssertionError(
                "The first actual detached installer must own its lease before ARMED: "
                + json.dumps(receipts)
            )
        if receipts[1]["status"] == 0 or receipts[1]["stdout"]:
            raise AssertionError(
                "A second detached installer must refuse before ARMED: " + json.dumps(receipts)
            )
        if not arming.await_eof(owned[1][1]):
            raise RuntimeError("The refused second installer retained a child capability")
        if (app / "marker").read_text() != "original":
            raise AssertionError("No replacement may begin before the launcher's actual exit")
        # A real publication failure must still restore the sole original backup.
        staged_apps[0].parent.chmod(0o500)
        parent.stdin.close()
        parent.wait(timeout=CONTROL_TIMEOUT)
        if not arming.await_eof(owned[0][1]):
            raise RuntimeError("The first exact detached installer did not retire")
        original_restored = (app / "marker").read_text() == "original"
        if (
            not original_restored
            or Path(str(app) + ".previous").exists()
            or not staged_apps[1].exists()
        ):
            raise AssertionError(
                "The refused second installer must not delete the first installer's rollback app"
            )
        log = (staged_apps[0].parents[1] / "swap.log").read_text()
        if "the previous one is back" not in log:
            raise AssertionError(
                "The actual first installer must acknowledge its completed rollback"
            )
        return {
            "name": "two-installers-before-arming",
            "receipts": receipts,
            "original_restored": original_restored,
            "second_candidate_preserved": staged_apps[1].exists(),
        }
    finally:
        for supervisor, read_fd in owned:
            # The retained supervisor remains the unreaped owned group anchor.
            try:
                os.killpg(supervisor.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if not arming.await_eof(read_fd):
                raise RuntimeError("The exact concurrent installer's descendants did not retire")
            supervisor.communicate(timeout=CONTROL_TIMEOUT)
            reap_owned_group(supervisor.pid)
            os.close(read_fd)
        if not parent.stdin.closed:
            parent.stdin.close()
        parent.wait(timeout=CONTROL_TIMEOUT)
        staged_apps[0].parent.chmod(0o700)


def main():
    """Keep one exact fixture tree until all controlled descendants have retired."""
    parser = argparse.ArgumentParser()
    parser.add_argument("driver", type=Path)
    parser.add_argument("root", type=Path)
    parser.add_argument("--native-launcher", type=Path)
    parser.add_argument("--mutant", choices=["none", "mv", "no-lease"], default="none")
    parser.add_argument("--phase", choices=["backup", "publish", "rollback", "lease"])
    args = parser.parse_args()
    if os.name != "posix" or os.geteuid() == 0:
        raise RuntimeError("Concurrent release controls require an unprivileged POSIX host")
    own_detached_descendants()
    args.root.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="concurrent-release-", dir=args.root))
    complete = False
    try:
        program, physical, arming = emitted(args.driver.resolve(strict=True), root)
        phases = [args.phase] if args.phase else ["backup", "publish", "rollback", "lease"]
        records = [
            lease_case(
                args.driver.resolve(strict=True),
                physical,
                arming,
                root,
                args.native_launcher,
                args.mutant,
            )
            if phase == "lease"
            else rename_case(program, physical, root, phase, args.native_launcher, args.mutant)
            for phase in phases
        ]
        if len(records) != len(phases) or len({record["name"] for record in records}) != len(
            phases
        ):
            raise RuntimeError("The full concurrent release case census must execute exactly once")
        complete = True
        print(
            json.dumps(
                {
                    "program_sha256": hashlib.sha256(program.encode()).hexdigest(),
                    "source_sha256": hashlib.sha256(
                        (args.driver / "modules/updater/release_installer.lua").read_bytes()
                    ).hexdigest(),
                    "native_launcher": str(args.native_launcher) if args.native_launcher else None,
                    "cases": records,
                }
            )
        )
    finally:
        if complete:
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
