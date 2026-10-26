"""Execute the real embedded Dock writer against owned files and kernel locks.

Foundation bookmark and native Dock/LaunchServices subprocess boundaries are
controlled. No host Dock preferences, processes, or native UI are touched.
"""

import contextlib
import errno
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

DEADLINE = 5


def wait_for(path):
    deadline = time.monotonic() + DEADLINE
    while not path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("Owned Dock fixture marker did not arrive: " + path.name)
        time.sleep(0.005)


def lock_held(path):
    if not path.exists():
        return False
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return False
    finally:
        os.close(descriptor)


def campaign(source_path, root_parent=None):
    source = Path(source_path).read_text(encoding="utf-8")
    if source.count("<<'DOCKEOF'\n") != 1:
        raise ValueError("Exactly one actual Dock worker is required")
    code = source.split("<<'DOCKEOF'\n")[1].split("\nDOCKEOF")[0]
    commands = re.findall(r"""^python3 - "\$DEST"[^\n]*<<'DOCKEOF'$""", source, re.M)
    if len(commands) != 1:
        raise ValueError("Exactly one actual shell Dock admission is required")
    command = commands[0]
    compile(code, "actual Dock writer", "exec")
    root = Path(tempfile.mkdtemp(prefix="ErgoptiDockUpdate-", dir=root_parent))
    root.chmod(0o700)
    owned = []
    debt = False
    checks = {}
    receipts = []
    argument_receipts = {}
    try:
        (root / "dock.py").write_text(code, encoding="utf-8")
        (root / "Foundation.py").write_text(
            """from pathlib import Path
import os,time
class NSURL:
 @classmethod
 def fileURLWithPath_(cls,path):
  value=cls();value.path=path;return value
 def bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error_(self,*arguments):
  if os.environ.get('PROBE_BARRIER')=='yes':
   root=Path(os.environ['PROBE_ROOT']);name=os.environ['PROBE_NAME']
   (root/(name+'.read')).touch()
   marker=root/('release-A' if name=='A' else 'A.written')
   deadline=time.monotonic()+float(os.environ['PROBE_DEADLINE'])
   while not marker.exists():
    if time.monotonic()>=deadline:raise RuntimeError('Owned bookmark barrier deadline')
    time.sleep(.005)
  return None,None
""",
            encoding="utf-8",
        )
        (root / "run.py").write_text(
            """from pathlib import Path
import fcntl,os,runpy,subprocess,sys,time
from types import SimpleNamespace
root=Path(os.environ['PROBE_ROOT']);name=os.environ['PROBE_NAME']
real_flock=fcntl.flock
# This observer calls the real kernel operation; parent independently checks
# that A owns the same inode before letting B reach this operation.
def flock(descriptor,operation):
 if operation & fcntl.LOCK_EX:
  (root/(name+'.lock-attempt')).touch()
 return real_flock(descriptor,operation)
fcntl.flock=flock
def run(arguments,**options):
 if len(arguments)>1 and arguments[1]=='-u' and name=='A':
  (root/'A.written').touch()
 return SimpleNamespace(returncode=1 if arguments[0]=='plutil' else 0,stdout='',stderr='')
subprocess.run=run
real_sleep=time.sleep
time.sleep=lambda duration: None if duration==2 else real_sleep(duration)
(root/(name+'.started')).touch()
sys.argv=sys.argv[1:]
import json
Path(os.environ['PROBE_ARGS_PATH']).write_text(json.dumps(sys.argv[1:]))
exec(compile(sys.stdin.read(),'actual embedded Dock worker','exec'))
""",
            encoding="utf-8",
        )
        binaries = root / "bin"
        binaries.mkdir()
        selected_python = binaries / "python3"
        selected_python.write_text(
            "#!/bin/sh\nexec "
            + shlex.quote(sys.executable)
            + " -B "
            + shlex.quote(str(root / "run.py"))
            + ' "$@"\n',
            encoding="utf-8",
        )
        selected_python.chmod(0o700)
        source_app = root / "Source.app"
        (source_app / "Contents").mkdir(parents=True)
        (source_app / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "probe.source"})
        )

        def fixture(name):
            home = root / name
            preferences = home / "Library/Preferences"
            preferences.mkdir(parents=True)
            dock = preferences / "com.apple.dock.plist"
            dock.write_bytes(plistlib.dumps({"persistent-apps": []}))
            parent = home / "Library/Application Support/AppCloner"
            parent.mkdir(parents=True, mode=0o700)
            applications = home / "Applications"
            applications.mkdir()
            return home, dock, parent, applications

        def launch(name, fixture_data, barrier=False):
            home, dock, parent, applications = fixture_data
            app = applications / (name + ".app")
            app.mkdir(exist_ok=True)
            profile = parent / (name + "_native")
            profile.mkdir(exist_ok=True)
            argument_receipt = home / (name + ".arguments.json")
            environment = dict(
                os.environ,
                DEST=str(app),
                UNIQUE_ID="probe." + name,
                SOURCE_APP=str(source_app),
                PWA_BROWSER="",
                USER_DATA_DIR=str(profile),
                PATH=str(binaries) + os.pathsep + os.environ.get("PATH", ""),
                PROBE_ARGS_PATH=str(argument_receipt),
                HOME=str(home),
                PROBE_ROOT=str(root),
                PROBE_NAME=name,
                PROBE_BARRIER="yes" if barrier else "no",
                PYTHONDONTWRITEBYTECODE="1",
                PROBE_DEADLINE=str(DEADLINE),
            )
            process = subprocess.Popen(
                ["/bin/sh", "-c", "exec " + command + "\n" + code + "\nDOCKEOF\n"],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            argument_receipts[process.pid] = (argument_receipt, profile)
            owned.append(process)
            return process

        def retire(process):
            output, errors = process.communicate(timeout=DEADLINE)
            receipts.append({"exit": process.returncode, "stderr": errors})
            receipt_path, profile = argument_receipts[process.pid]
            actual_arguments = json.loads(receipt_path.read_text(encoding="utf-8"))
            admitted = len(actual_arguments) == 5 and actual_arguments[4] == str(profile)
            checks["required_user_data_argument_reaches_actual_worker"] = (
                checks.get("required_user_data_argument_reaches_actual_worker", True) and admitted
            )
            if process.returncode != 0 or "deadline" in output or "deadline" in errors:
                raise AssertionError(
                    "Actual Dock writer did not complete normally: " + output + errors
                )

        def labels(data):
            return [
                entry["tile-data"]["file-label"]
                for entry in plistlib.loads(data[1].read_bytes())["persistent-apps"]
            ]

        serial = fixture("serial")
        retire(launch("A", serial))
        retire(launch("B", serial))
        checks["serial_distinct_entries"] = labels(serial) == ["A", "B"]
        retire(launch("A", serial))
        checks["same_app_deduplicates"] = labels(serial) == ["B", "A"]

        for marker in [
            "A.read",
            "B.read",
            "A.written",
            "A.lock-attempt",
            "B.lock-attempt",
            "release-A",
            "A.started",
            "B.started",
        ]:
            (root / marker).unlink(missing_ok=True)
        concurrent = fixture("concurrent")
        lock_path = concurrent[2] / ".dock-update.lock"
        first = launch("A", concurrent, True)
        wait_for(root / "A.read")
        kernel_owned = lock_held(lock_path)
        inode = lock_path.stat().st_ino if lock_path.exists() else None
        second = launch("B", concurrent, True)
        # Baseline/no-op locking is forced into the known lost-update ordering.
        # Correct locking lets B reach real flock, then releases A's held lock.
        wait_for(root / ("B.lock-attempt" if kernel_owned else "B.read"))
        (root / "release-A").touch()
        retire(first)
        retire(second)
        checks["kernel_lock_owned_during_read_modify_write"] = kernel_owned
        checks["concurrent_entries_preserved"] = labels(concurrent) == ["A", "B"]
        checks["stable_private_lock_inode"] = (
            lock_path.exists()
            and lock_path.stat().st_ino == inode
            and stat.S_IMODE(lock_path.stat().st_mode) == 0o600
            and lock_path.stat().st_uid == os.geteuid()
            and not lock_held(lock_path)
        )

        for kind in ["public-file", "symlink", "directory", "fifo", "writable-parent"]:
            data = fixture("invalid-" + kind)
            path = data[2] / ".dock-update.lock"
            target = data[2] / "unrelated-owned-file"
            if kind == "public-file":
                path.write_text("retained", encoding="utf-8")
                path.chmod(0o644)
            elif kind == "symlink":
                target.write_text("retained", encoding="utf-8")
                path.symlink_to(target)
            elif kind == "directory":
                path.mkdir()
            elif kind == "fifo":
                os.mkfifo(path, 0o600)
            else:
                data[2].chmod(0o777)
            before = data[1].read_bytes()
            process = launch("A", data)
            output, errors = process.communicate(timeout=DEADLINE)
            checks["refuses_" + kind] = (
                process.returncode != 0
                and data[1].read_bytes() == before
                and (kind != "symlink" or target.read_text(encoding="utf-8") == "retained")
            )
            if kind == "writable-parent":
                data[2].chmod(0o700)

        # Same-process exception proves descriptor retirement rather than relying
        # on automatic descriptor closure when a worker process terminates.
        exceptional = fixture("exception")
        profile = exceptional[2] / "A_native"
        profile.mkdir()
        arguments = [
            str(root / "dock.py"),
            str(exceptional[3] / "A.app"),
            "probe.A",
            str(source_app),
            "",
            str(profile),
        ]
        previous_arguments, previous_home, original_load = (
            sys.argv,
            os.environ.get("HOME"),
            plistlib.load,
        )
        original_open = os.open
        descriptors = []

        def observe_open(path, *arguments, **options):
            descriptor = original_open(path, *arguments, **options)
            if os.path.basename(path) == ".dock-update.lock":
                descriptors.append(descriptor)
            return descriptor

        sentinel = RuntimeError("Owned load refusal")
        try:
            sys.argv = arguments
            os.environ["HOME"] = str(exceptional[0])

            def refuse_load(stream):
                raise sentinel

            plistlib.load = refuse_load
            os.open = observe_open
            with contextlib.redirect_stdout(io.StringIO()):
                try:
                    runpy.run_path(str(root / "dock.py"), run_name="__main__")
                except RuntimeError as error:
                    checks["load_refusal_propagates"] = error is sentinel
                else:
                    checks["load_refusal_propagates"] = False
        finally:
            sys.argv, plistlib.load, os.open = previous_arguments, original_load, original_open
            if previous_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = previous_home
        closed = []
        for descriptor in descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                closed.append(error.errno == errno.EBADF)
            else:
                closed.append(False)
                os.close(descriptor)
        checks["exception_closes_exact_descriptor"] = len(closed) == 1 and all(closed)
        path = exceptional[2] / ".dock-update.lock"
        checks["exception_releases_kernel_lock_in_same_process"] = path.exists() and not lock_held(
            path
        )
        return {
            "state": "PASS" if all(checks.values()) else "FAIL",
            "checks": checks,
            "concurrent_labels": labels(concurrent),
            "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "dock_block_sha256": hashlib.sha256(code.encode()).hexdigest(),
            "scope": "Actual production Python Dock block, real plist files and kernel flock; Foundation/native registration/restart ports controlled. Cooperating App Cloner writers only; no host Dock/UI claim.",
        }
    finally:
        for process in owned:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=DEADLINE)
                except subprocess.TimeoutExpired:
                    debt = True
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        if not debt:
            shutil.rmtree(root)
        else:
            raise RuntimeError(
                "Owned Dock fixture child retirement is unknown; retained " + str(root)
            )


if __name__ == "__main__":

    def interrupt(signum, frame):
        raise InterruptedError("Owned Dock campaign was interrupted")

    signal.signal(signal.SIGTERM, interrupt)
    report = campaign(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else None)
    print(json.dumps(report, sort_keys=True))
    sys.exit(0 if report["state"] == "PASS" else 1)
