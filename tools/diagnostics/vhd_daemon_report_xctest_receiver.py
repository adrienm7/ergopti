"""Receive the closed daemon-report XCTest roster on one actual macOS architecture.

No installer/product build, consent operation or workflow is invoked. The original
32 cases remain frozen; additional cases require an explicitly reviewed catalogue
edit. Portable judge controls do not establish native execution.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import posixpath
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from types import ModuleType


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "static/ergopti_plus/macos/launcher"
CATALOGUE = "tools/diagnostics/fixtures/vhd-daemon-report-xctest-cases.json"
SELF = "tools/diagnostics/vhd_daemon_report_xctest_receiver.py"
SUPERVISOR = "tools/diagnostics/macos_owned_process.py"
EXTERNAL_COMPILER_HEADERS = (
    "tools/build/InstalledUserConfiguration.hpp",
    "tools/build/InstalledRuntimePublisher.hpp",
)
ORIGINAL_CASES_SHA256 = "8af2825efae3d744eb2c967979af8f2a5d64b89a9ac4c62f8cca80598a23c3cc"
CLASSES = (
    "OwnedVirtualHIDDaemonReportTests",
    "OwnedVirtualHIDDaemonReportWorkerTests",
    "OwnedVirtualHIDDaemonReportMainOperationTests",
    "OwnedVirtualHIDDaemonReportPurposeQueryTests",
)
FILTER = r"(^|[.])(" + "|".join(CLASSES) + r")([/.]|$)"
MAX_LOG_BYTES = 32 * 1024 * 1024
EXECUTION_SECONDS = 600


def require(condition):
    """Refuse invalid evidence without exporting arbitrary exception text."""
    if not condition:
        raise ValueError("daemon-report receiving refused")


def catalogue(data):
    """Keep the original oracle whole, with only explicit additive enrollment."""
    value = json.loads(data)
    require(set(value) == {"schema", "original_cases", "additional_cases"})
    require(type(value["schema"]) is int and value["schema"] == 1)
    original, added = value["original_cases"], value["additional_cases"]
    require(type(original) is list and type(added) is list)
    encoded = json.dumps(original, separators=(",", ":")).encode()
    require(hashlib.sha256(encoded).hexdigest() == ORIGINAL_CASES_SHA256)
    result = original + added
    require(all(type(name) is str for name in result))
    require(len(original) == 32 and len(result) == len(set(result)))
    for name in result:
        require(type(name) is str)
        require(re.fullmatch(r"(" + "|".join(CLASSES) + r")\.test[A-Za-z0-9_]+", name))
    return tuple(result)


def case_identity(value):
    """Accept the two genuine XCTest spellings, with the exact test module."""
    match = re.fullmatch(r"(?:ErgoptiPlusTests\.)?(\w+)\.(test\w+)", value)
    if match is None:
        match = re.fullmatch(r"-\[(?:ErgoptiPlusTests\.)?(\w+) (test\w+)\]", value)
    require(match is not None)
    return match.group(1) + "." + match.group(2)


def valid_source_frame(frame, sha):
    """A nonempty source list is not a substitute for the fixed input closure."""
    require(type(frame) is dict and set(frame) == {"head", "files"} and frame["head"] == sha)
    require(type(frame["files"]) is list)
    names = []
    for row in frame["files"]:
        require(type(row) is dict and set(row) == {"path", "blob", "sha256"})
        require(all(type(value) is str for value in row.values()))
        require(re.fullmatch(r"[0-9a-f]{40}", row["blob"]) is not None)
        require(re.fullmatch(r"[0-9a-f]{64}", row["sha256"]) is not None)
        names.append(row["path"])
    require(len(names) == len(set(names)))
    required = {SELF, SUPERVISOR, CATALOGUE, PACKAGE + "/Package.swift"}
    required.update(EXTERNAL_COMPILER_HEADERS)
    required.update(
        PACKAGE + "/Tests/ErgoptiPlusTests/" + name
        for name in (
            "OwnedVirtualHIDDaemonReportTests.swift",
            "OwnedVirtualHIDDaemonReportWorkerTests.swift",
            "OwnedVirtualHIDDaemonReportMainOperationTests.swift",
        )
    )
    require(required <= set(names))


def judge(
    log,
    expected,
    *,
    swift_status,
    capture_status,
    retired,
    requested_sha,
    before,
    after,
    architecture,
    observed_architecture,
):
    """Require exact paired cases plus independent command/source/owner evidence."""
    result = {
        "schema": 1,
        "scope": "vhd-daemon-report-xctest",
        "passed": False,
        "expected_count": len(expected),
        "received_count": 0,
        "swift_status": swift_status,
        "capture_status": capture_status,
        "retired": retired,
        "architecture": architecture,
        "source_sha": requested_sha,
        "wrapper_used": False,
        "helper_product_qualified": False,
        "sdk_qualified": False,
        "installation_qualified": False,
        "physical_qualified": False,
    }
    try:
        require(type(swift_status) is int and swift_status == 0)
        require(type(capture_status) is int and capture_status == 0)
        require(retired is True)
        require(architecture in ("arm64", "x86_64") and architecture == observed_architecture)
        require(re.fullmatch(r"[0-9a-f]{40}", requested_sha) is not None)
        require(type(before) is dict and before == after)
        valid_source_frame(before, requested_sha)
        require(len(expected) >= 32 and len(set(expected)) == len(expected))
        require(type(log) is bytes and 0 < len(log) <= MAX_LOG_BYTES and log.endswith(b"\n"))
        text = log.decode("utf-8", errors="strict").replace("\r\n", "\n")
        require("\r" not in text and "\x1b" not in text)
        starts, passes = [], []
        active = None
        root_started = root_passed = summaries = 0
        awaiting_summary = False
        for line in text.splitlines():
            if awaiting_summary and line.strip():
                summary = re.fullmatch(
                    r"\s*Executed (\d+) tests?, with 0 failures? \(0 unexpected\) in "
                    r"[0-9.]+ \([0-9.]+\) seconds",
                    line,
                )
                require(summary is not None and int(summary.group(1)) == len(expected))
                summaries += 1
                awaiting_summary = False
            if line.startswith("Test Suite 'Selected tests' started at "):
                root_started += 1
            if line.startswith("Test Suite 'Selected tests' passed at "):
                root_passed += 1
                awaiting_summary = True
            if not line.startswith("Test Case "):
                continue
            row = re.fullmatch(
                r"Test Case '([^']+)' (started\.|passed \([0-9.]+ seconds\)\.)", line
            )
            require(row is not None and root_started == 1 and root_passed == 0)
            identity = case_identity(row.group(1))
            require(identity in expected)
            if row.group(2) == "started.":
                require(active is None and identity not in starts)
                starts.append(identity)
                active = identity
            else:
                require(active == identity and identity not in passes)
                passes.append(identity)
                active = None
        result["received_count"] = len(passes)
        require(active is None and root_started == root_passed == summaries == 1)
        require(not awaiting_summary and set(starts) == set(passes) == set(expected))
        result["passed"] = True
        result["reason"] = "exact-source-bound-cases-passed"
    except (ValueError, TypeError, UnicodeError, KeyError):
        result["reason"] = "evidence-refused"
    return result


def git(arguments):
    """Only fixed read-only Git operations are issued by this receiver."""
    environment = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
    return subprocess.run(
        ["/usr/bin/git", "-C", str(ROOT), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        env=environment,
    ).stdout


def quoted_include_closure(sources, read):
    """Follow actual local/public-header quoted includes, including external headers."""
    result = dict(sources)
    pending = list(sources)
    public_headers = PACKAGE + "/Sources/CPOSIXCompatibility/include"
    while pending:
        name = pending.pop()
        if Path(name).suffix.lower() not in (
            ".c",
            ".h",
            ".cpp",
            ".hpp",
            ".m",
            ".mm",
            ".cc",
            ".hxx",
        ):
            continue
        text = result[name].decode("utf-8", errors="strict").replace("\\\n", "")
        text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.DOTALL)
        for include in re.findall(r'^\s*#\s*(?:include|import)\s*"([^"\n]+)"', text, re.MULTILINE):
            require(not include.startswith("/") and "\\" not in include)
            resolved = None
            for base in (posixpath.dirname(name), public_headers):
                candidate = posixpath.normpath(posixpath.join(base, include))
                require(candidate != ".." and not candidate.startswith("../"))
                try:
                    data = result[candidate] if candidate in result else read(candidate)
                except FileNotFoundError:
                    continue
                resolved = candidate
                if candidate not in result:
                    result[candidate] = data
                    pending.append(candidate)
                break
            require(resolved is not None)
    return result


def source_frame(sha):
    """Bind launcher, genuine transitive quoted headers and receiver dependencies."""
    require(git(["rev-parse", "--verify", "HEAD"]).decode().strip() == sha)
    records = git(
        [
            "ls-tree",
            "-rz",
            sha,
            "--",
            PACKAGE,
            SELF,
            SUPERVISOR,
            CATALOGUE,
            *EXTERNAL_COMPILER_HEADERS,
        ]
    )
    entries = {}
    for record in records.split(b"\0"):
        if not record:
            continue
        header, raw_path = record.split(b"\t", 1)
        mode, kind, blob = header.decode().split()
        name = raw_path.decode("utf-8", errors="strict")
        require(kind == "blob" and mode in ("100644", "100755"))
        entries[name] = (mode, blob)
    files = {}

    def read(name):
        path = ROOT / name
        if name not in entries:
            record = git(["ls-tree", "-z", sha, "--", name])
            if not record:
                # A real untracked local header must not be bypassed by a fallback search.
                require(not path.exists() and not path.is_symlink())
                raise FileNotFoundError("quoted compiler header absent")
            header, raw_path = record.rstrip(b"\0").split(b"\t", 1)
            mode, kind, blob = header.decode().split()
            require(raw_path.decode() == name and kind == "blob" and mode in ("100644", "100755"))
            entries[name] = (mode, blob)
        mode, blob = entries[name]
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
        require(path.resolve(strict=True) == path and info.st_size <= MAX_LOG_BYTES)
        data = path.read_bytes()
        actual_blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        require(actual_blob == blob)
        require(bool(info.st_mode & 0o111) == (mode == "100755"))
        files[name] = {"path": name, "blob": blob, "sha256": hashlib.sha256(data).hexdigest()}
        return data

    sources = {name: read(name) for name in list(entries)}
    quoted_include_closure(sources, read)
    names = set(files)
    require(
        {SELF, SUPERVISOR, CATALOGUE, PACKAGE + "/Package.swift", *EXTERNAL_COMPILER_HEADERS}
        <= names
    )
    for filename in (
        "OwnedVirtualHIDDaemonReportTests.swift",
        "OwnedVirtualHIDDaemonReportWorkerTests.swift",
        "OwnedVirtualHIDDaemonReportMainOperationTests.swift",
    ):
        require(PACKAGE + "/Tests/ErgoptiPlusTests/" + filename in names)
    # SwiftPM discovers untracked source too: an unchanged tracked subset is insufficient.
    untracked = git(["ls-files", "--others", "--exclude-standard", "-z", "--", PACKAGE])
    require(not untracked)
    require(
        not git(
            [
                "ls-files",
                "--others",
                "--ignored",
                "--exclude-standard",
                "-z",
                "--",
                PACKAGE + "/Sources",
                PACKAGE + "/Tests",
            ]
        )
    )
    return {"head": sha, "files": [files[name] for name in sorted(files)]}


def retire_registered(owners, output, *, previous_refusal=False):
    """Retain original owners until actual reap, as the existing native receiver does.

    This is retirement debt, not another command deadline. Only the original
    NativeProcessGroup.settle may act; no source/Git subprocess or successful
    verdict may follow while any acquired reservation remains unresolved.
    """
    refused = previous_refusal
    while not all(owner.reaped is True for owner in owners):
        for owner in owners:
            if owner.reaped is True:
                continue
            try:
                if owner.settle(timeout=1) is not True:
                    refused = True
            except BaseException:
                refused = True
        if not all(owner.reaped is True for owner in owners):
            try:
                with (output / "pending-retirement.json").open("x", encoding="utf-8") as stream:
                    json.dump(
                        {
                            "schema": 1,
                            "passed": False,
                            "reason": "native-retirement-debt",
                            "controller_retains_capabilities": True,
                        },
                        stream,
                        sort_keys=True,
                    )
                    stream.write("\n")
            except BaseException:
                refused = True
            try:
                time.sleep(0.05)
            except BaseException:
                refused = True
    return not refused


def ownership_module(frame):
    """Execute the exact authenticated supervisor bytes, never import caches."""
    rows = [row for row in frame["files"] if row["path"] == SUPERVISOR]
    require(len(rows) == 1)
    path = ROOT / SUPERVISOR
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1)
    require(path.resolve(strict=True) == path and before.st_size <= MAX_LOG_BYTES)
    data = path.read_bytes()
    after = path.lstat()
    require(
        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    )
    require(hashlib.sha256(data).hexdigest() == rows[0]["sha256"])
    require(
        hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        == rows[0]["blob"]
    )
    module = ModuleType("_daemon_report_authenticated_ownership")
    module.__file__ = str(path)
    exec(compile(data, str(path), "exec", dont_inherit=True), module.__dict__)
    return module


def receive(sha, architecture, output):
    """Execute fixed SwiftPM selection; reap only after genuine group retirement."""
    require(sys.platform == "darwin" and platform.machine() == architecture)
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None)
    require(not os.environ.get("GITHUB_SHA") or os.environ["GITHUB_SHA"] == sha)
    for name in (
        "ERGOPTI_DEV_QUALIFICATION_PROFILE",
        "SWIFT_EXEC",
        "SWIFT_EXEC_MANIFEST",
        "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
        "SWIFTPM_BUILD_DIR",
    ):
        require(not os.environ.get(name))
    require(output.is_absolute() and output.parent.resolve(strict=True) == output.parent)
    output.mkdir(mode=0o700, exist_ok=False)
    require(output.stat().st_uid == os.getuid())
    before = source_frame(sha)
    expected = catalogue((ROOT / CATALOGUE).read_bytes())
    (output / "source-before.json").write_text(json.dumps(before, sort_keys=True) + "\n")
    ownership = ownership_module(before)
    native = ownership.NativeProcessGroups()
    groups = []
    group = None
    captured = 0
    eof = False
    capture_status = None
    retired = False
    retirement_refused = False
    after = None
    handlers = {}

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("Daemon-report receiver interrupted")

    command = [
        "/usr/bin/swift",
        "test",
        "--package-path",
        str(ROOT / PACKAGE),
        "--scratch-path",
        str(output / "swift-build"),
        "--configuration",
        "debug",
        "--arch",
        architecture,
        "--filter",
        FILTER,
    ]
    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            handlers[signum] = signal.signal(signum, interrupted)
        with (output / "xctest.log").open("xb") as stream, selectors.DefaultSelector() as selector:
            group = ownership.acquire_owned(
                command,
                native,
                groups.append,
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            os.set_blocking(group.process.stdout.fileno(), False)
            selector.register(group.process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + EXECUTION_SECONDS

            def drain():
                nonlocal captured, eof
                for key, _ in selector.select(0.02):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        eof = True
                        selector.unregister(key.fileobj)
                    else:
                        captured += len(chunk)
                        require(captured <= MAX_LOG_BYTES)
                        stream.write(chunk)

            while group.observe_exit() is None:
                require(time.monotonic() < deadline)
                drain()
            try:
                retired = group.settle(timeout=1)
            except BaseException:
                retirement_refused = True
                raise
            retirement_refused = retired is not True
            require(retired)
            drain_deadline = time.monotonic() + 1
            while not eof and time.monotonic() < drain_deadline:
                drain()
            require(eof)
            stream.flush()
            os.fsync(stream.fileno())
            capture_status = 0
    except (Exception, KeyboardInterrupt):
        # A refusal never borrows a completed transcript or cleanup invocation as success.
        capture_status = None
    finally:
        try:
            # Match the original guardian: cancellation cannot interrupt owned retirement.
            for signum in handlers:
                signal.signal(signum, signal.SIG_IGN)
            retirement_clean = retire_registered(
                groups, output, previous_refusal=retirement_refused
            )
            retired = bool(groups) and all(held.reaped is True for held in groups)
            if not retirement_clean:
                capture_status = None
            if group is not None and group.process.stdout is not None:
                group.process.stdout.close()
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
    try:
        after = source_frame(sha)
        (output / "source-after.json").write_text(json.dumps(after, sort_keys=True) + "\n")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        after = None
    log_path = output / "xctest.log"
    log = (
        log_path.read_bytes()
        if log_path.exists() and log_path.stat().st_size <= MAX_LOG_BYTES
        else b""
    )
    status = group.process.returncode if group is not None and retired else None
    verdict = judge(
        log,
        expected,
        swift_status=status,
        capture_status=capture_status,
        retired=retired,
        requested_sha=sha,
        before=before,
        after=after,
        architecture=architecture,
        observed_architecture=platform.machine(),
    )
    verdict["log_sha256"] = hashlib.sha256(log).hexdigest()
    verdict["log_bytes"] = len(log)
    verdict["retirement_refused"] = not retirement_clean
    with (output / "verdict.json").open("x", encoding="utf-8") as stream:
        json.dump(verdict, stream, sort_keys=True)
        stream.write("\n")
    return verdict


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = receive(args.source_sha, args.architecture, args.output)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print("Daemon-report XCTest prerequisites refused", file=sys.stderr)
        return 1
    print(
        "PASS exact daemon-report XCTest roster"
        if result["passed"]
        else "FAIL daemon-report XCTest receiving"
    )
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
