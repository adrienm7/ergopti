"""Native-only regression candidate for the actual App Cloner worker boundary.

This is not a GUI test. Only the launcher's native UI port is replaced: it runs
the actual source worker and completion predicate through real osascript.
"""

import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tempfile
import types


CONTENTS = Path("static/ergopti_plus/macos/apps/App Cloner.app/Contents")
CHILD_DEADLINE = 5
RETIREMENT_DEADLINE = 5


def one(pattern, source, description, flags=0):
    """Refuse a missing or ambiguous production source boundary."""
    matches = list(re.finditer(pattern, source, flags))
    if len(matches) != 1:
        raise ValueError("Expected one actual source " + description)
    return matches[0]


def program_from_source(source):
    """Retain the actual admission, argument construction, worker and predicate."""
    admission = one(
        r"^\t(do shell script [^\n]+quoted form of cloneScript)$", source, "helper admission", re.M
    ).group(1)
    clone_assignment = one(
        r'^\tset cloneScript to appDir & "([^"]+)"$', source, "helper path", re.M
    )
    command_start = one(
        r"^\tset cmd to quoted form of cloneScript", source, "command construction", re.M
    )
    command_end = one(r'^\tlogmsg\("cmd: ', source, "command observation", re.M)
    allocation_start = one(
        r"^\tset runDir to do shell script ", source, "private run allocation", re.M
    )
    allocation_end = one(r"^\tdo shell script bgCmd$", source, "worker launch", re.M)
    if (
        not clone_assignment.start()
        < source.index(admission)
        < command_start.start()
        < command_end.start()
        < allocation_start.start()
        < allocation_end.start()
    ):
        raise ValueError("Actual worker phase boundaries are not ordered")
    command = source[command_start.start() : command_end.start()]
    allocation = source[allocation_start.start() : allocation_end.start()]
    loop = one(
        r"^\trepeat until isDone\n(.*?)^\tend repeat$", source, "completion loop", re.M | re.S
    ).group(1)
    predicate = one(
        r"^\s*(do shell script [^\n]+quoted form of donePath)$", loop, "completion predicate", re.M
    ).group(1)
    observer = 'if wait "$!"; then printf "0"; else observed=$?; printf "%s" "$observed"; fi'
    quoted_observer = '"' + observer.replace("\\", "\\\\").replace('"', '\\"') + '"'
    program = """use AppleScript version "2.4"
use framework "Foundation"
use scripting additions

on observe_completion(donePath)
    try
        PREDICATE
        return true
    on error
        return false
    end try
end observe_completion

on run argv
    set appDir to item 1 of argv
    CLONE_ASSIGNMENT
    set sourcePath to item 2 of argv
    set cloneName to "Worker regression fixture"
    set colorHex to ""
    set openArg to ""
    set iconMode to ""
    set iconPath to ""
    set pwaArg to "0"
    set appLogPath to item 3 of argv
    ADMISSION
COMMAND
ALLOCATION
    -- This test-only wait owns/reaps the exact original background job. The
    -- production background expression and its child body stay unchanged.
    set observed_wait to do shell script (bgCmd & linefeed & OBSERVER)
    set actual_ready to my observe_completion(donePath)
    set absent_path to runDir & "/observer-absent-completion"
    if (((current application's NSFileManager's defaultManager())'s fileExistsAtPath:absent_path) as boolean) then error "Negative completion fixture is not absent."
    set negative_ready to my observe_completion(absent_path)
    set actual_number to current application's NSNumber's numberWithBool:actual_ready
    set negative_number to current application's NSNumber's numberWithBool:negative_ready
    set receipt to current application's NSDictionary's dictionaryWithObjects:{runDir, observed_wait, actual_number, negative_number} forKeys:{"run_directory", "worker_wait_status", "predicate_accepted", "absent_control_accepted"}
    set {receipt_data, receipt_error} to current application's NSJSONSerialization's dataWithJSONObject:receipt options:0 |error|:(reference)
    if receipt_data is missing value then error "The native worker observer could not encode its receipt."
    return (current application's NSString's alloc()'s initWithData:receipt_data encoding:(current application's NSUTF8StringEncoding)) as text
end run
"""
    replacements = {
        "PREDICATE": predicate,
        "CLONE_ASSIGNMENT": clone_assignment.group(0).strip(),
        "ADMISSION": admission,
        "COMMAND": command,
        "ALLOCATION": allocation,
        "OBSERVER": quoted_observer,
    }
    for placeholder, replacement in replacements.items():
        if program.count(placeholder) != 1:
            raise ValueError("Native source observer placeholder is ambiguous: " + placeholder)
        program = program.replace(placeholder, replacement)
    return program, clone_assignment.group(1)


def native_child(arguments, environment):
    """Bound only the owned observer process; preserve uncertainty on interruption."""
    restore_signals = environment.pop("PROBE_RESTORE_SIGNALS") == "yes"
    process = subprocess.Popen(
        arguments,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        restore_signals=restore_signals,
    )
    try:
        output, errors = process.communicate(timeout=CHILD_DEADLINE)
    except subprocess.TimeoutExpired:
        # Never signal a reaped/reused leader. No unowned service or system
        # process is selected; an interrupted native operation remains debt.
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            output, errors = process.communicate(timeout=RETIREMENT_DEADLINE)
        except subprocess.TimeoutExpired:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
            raise RuntimeError("Owned native observer retirement is unproven")
        raise RuntimeError("Native observer timed out; fixture retained despite child retirement")
    if process.returncode is None or process.returncode < 0:
        raise RuntimeError("Native observer ended without a normal retirement receipt")
    if process.returncode != 0:
        raise RuntimeError(
            "Native source program failed before completion qualification: " + errors
        )
    return json.loads(output), errors


def run_case(snapshot, case_root, name, refused, restore_signals):
    """Execute the actual Python entry and replace only its native UI boundary."""
    launcher = snapshot / CONTENTS / "MacOS/AppCloner"
    script = snapshot / CONTENTS / "Resources/ShortcutBuilder.applescript"
    source = script.read_text(encoding="utf-8")
    program, clone_suffix = program_from_source(source)
    observer = case_root / "worker-observer.applescript"
    observer.write_text(program, encoding="utf-8")
    helper = snapshot / CONTENTS.parent / clone_suffix.lstrip("/")
    helper.parent.mkdir(parents=True, exist_ok=True)
    helper.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    helper.chmod(0o755)
    source_app = case_root / "Source.app"
    source_app.mkdir()
    loader = importlib.machinery.SourceFileLoader("appcloner_native_worker_probe", str(launcher))
    specification = importlib.util.spec_from_loader(loader.name, loader)
    subject = importlib.util.module_from_spec(specification)
    loader.exec_module(subject)
    original_run = subprocess.run
    original_environment = dict(os.environ)
    original_temp = tempfile.tempdir
    original_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    original_signal = signal.getsignal(signal.SIGXFSZ)
    original_umask = os.umask(0o077)
    warning = io.StringIO()
    events = []
    result = {
        "name": name,
        "requested_native_restore_signals": restore_signals,
        "resource_limit_file_bytes": 0 if refused else None,
        "ownership_closed": True,
    }

    def observe(arguments, **options):
        if len(arguments) != 3 or arguments[:2] != ["osascript", str(script)]:
            raise RuntimeError(
                "A non-worker or user-facing native dispatch cannot run in this fixture"
            )
        environment = options["env"].copy()
        log_path = environment.get("ERGOPTI_APPCLONER_LOG", "")
        events.append(
            {"actual_native_entry_arguments": arguments, "exported_usable_log_path": log_path}
        )
        environment["PROBE_RESTORE_SIGNALS"] = "yes" if restore_signals else "no"
        try:
            receipt, native_errors = native_child(
                ["/usr/bin/osascript", str(observer), arguments[2], str(source_app), log_path],
                environment,
            )
        except Exception:
            result["ownership_closed"] = False
            raise
        run_directory = Path(receipt["run_directory"])
        if (
            run_directory.resolve().parent != case_root.resolve()
            or not run_directory.name.startswith("ergopti-appcloner.")
        ):
            result["ownership_closed"] = False
            raise ValueError("The native source run directory is not owned by this case")
        if not isinstance(receipt["predicate_accepted"], bool) or not isinstance(
            receipt["absent_control_accepted"], bool
        ):
            raise ValueError("Native completion results must be actual JSON booleans")
        wait_status = receipt["worker_wait_status"]
        if not isinstance(wait_status, str) or re.fullmatch(r"[0-9]{1,3}", wait_status) is None:
            raise ValueError("Native wait must report an exact retired child status")
        absent = run_directory / "observer-absent-completion"
        if absent.exists() or receipt["absent_control_accepted"]:
            raise AssertionError("The source predicate oracle accepted an absent completion file")
        files = {path.name: path.read_text(encoding="utf-8") for path in run_directory.iterdir()}
        result["native"] = {
            **receipt,
            "worker_wait_status": int(wait_status),
            "files": files,
            "native_stderr": native_errors,
            "worker_retired_by_actual_wait": True,
        }
        # Return only to retire the actual Python entry after the bounded phase
        # observation. This does not claim that the full UI polling loop ran.
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

    try:
        os.environ["ERGOPTI_LOCALE"] = "en"
        os.environ.pop("ERGOPTI_LOCALES_DIR", None)
        os.environ["TMPDIR"] = str(case_root)
        tempfile.tempdir = str(case_root)
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        if refused:
            resource.setrlimit(resource.RLIMIT_FSIZE, (0, original_limit[1]))
        subprocess.run = observe
        with contextlib.redirect_stderr(warning):
            subject.main()
    except Exception as error:
        result["precondition_failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, original_limit)
        signal.signal(signal.SIGXFSZ, original_signal)
        subprocess.run = original_run
        tempfile.tempdir = original_temp
        os.environ.clear()
        os.environ.update(original_environment)
        os.umask(original_umask)
    result["actual_main_dispatches"] = events
    result["actual_main_warnings"] = warning.getvalue()
    return result


def main():
    if sys.platform != "darwin":
        raise RuntimeError(
            "This regression candidate requires actual Darwin osascript; it cannot pass by skipping"
        )
    repository, root = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    snapshot = root / "snapshot"
    sources = [
        CONTENTS / "MacOS/AppCloner",
        CONTENTS / "Resources/ShortcutBuilder.applescript",
        Path("static/ergopti_plus/_shared/data/locales/en.json"),
    ]
    hashes = {}
    for relative in sources:
        content = (repository / relative).read_bytes()
        destination = snapshot / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        hashes[str(relative)] = hashlib.sha256(content).hexdigest()
    if "def append_log(" not in (snapshot / sources[0]).read_text(encoding="utf-8"):
        raise ValueError(
            "The native worker regression requires the published optional-log admission fix"
        )
    cases = []
    for name, refused, restore in [
        ("healthy", False, True),
        ("refused-default", True, True),
        ("refused-inherited-ignore", True, False),
    ]:
        directory = root / name
        directory.mkdir(mode=0o700)
        cases.append(run_case(snapshot, directory, name, refused, restore))
    violations = []
    for case in cases:
        native = case.get("native")
        if len(case["actual_main_dispatches"]) != 1:
            violations.append(
                case["name"]
                + ": the actual launcher did not admit exactly one native worker boundary"
            )
        if "precondition_failure" in case or native is None:
            violations.append(case["name"] + ": actual native boundary was not qualified")
        elif not native["predicate_accepted"]:
            violations.append(
                case["name"] + ": actual completion predicate remains false after worker retirement"
            )
        elif case["name"] == "healthy" and (
            native["files"].get("status") != "1\n" or native["worker_wait_status"] != 0
        ):
            violations.append(
                case["name"]
                + ": ordinary clone refusal did not persist its exact failure and retire normally"
            )
        elif native["files"].get("status", "").strip() == "0":
            violations.append(
                case["name"] + ": ordinary clone refusal acquired a false successful status"
            )
    report = {
        "state": "NATIVE_COMPLETION_REGRESSION_PASSED"
        if not violations
        else "NATIVE_COMPLETION_REGRESSION_FAILED",
        "ownership_closed": all(case["ownership_closed"] for case in cases),
        "source_sha256": hashes,
        "cases": cases,
        "violations": violations,
        "limits": [
            "Actual Python entry plus real Darwin source-worker execution and actual predicate, not a whole GUI or completed clone.",
            "The optional icon assets are absent in the fixture to avoid icon generation or desktop process effects.",
            "A test-only parent wait reaps the exact original background job; the production worker body is unchanged.",
            "Requested launch signal dispositions can be normalized by the native runtime; no particular shell disposition is assumed.",
            "Any absent production completion after retired-worker observation fails the regression; it is never treated as a successful diagnostic case.",
        ],
    }
    print(json.dumps(report))
    return 0 if not violations and report["ownership_closed"] else 1


if __name__ == "__main__":
    sys.exit(main())
