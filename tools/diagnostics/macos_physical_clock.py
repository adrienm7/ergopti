# tools/diagnostics/macos_physical_clock.py
"""Qualify actual borrowed Hammerspoon samples against an independent Mach interval.

One private official runtime and the existing reserved native-process creator are
used. This proves that hosted samples are in Mach nanoseconds; an API-binding token
never establishes boot, physical capture, privacy, wall epoch or awake authority.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid

import macos_owned_process as owner
import macos_tooltip_canvas as facade

MAX_RECEIPT_BYTES = 16_384
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
CONTROLLER_SECONDS = 25
ACQUISITION_SECONDS = 10
PROBE_SECONDS = 10
SAMPLE_PHASES = (
    "legacy_before",
    "bound_read",
    "bound_now",
    "legacy_after_detach",
    "successor_read",
)
FACTS = {
    "current_before",
    "wrong_owner_denied",
    "wrong_token_denied",
    "duplicate_bind_refused",
    "detached",
    "retired_after_detach",
    "read_after_detach_denied",
    "getter_unchanged",
    "successor_distinct",
    "successor_current",
    "successor_detached",
    "successor_retired",
}
SOURCE_FILES = (
    "static/ergopti_plus/macos/adapters/physical_observation_clock.lua",
    "static/ergopti_plus/_shared/lua/keylogger/physical_subscription_lifetime.lua",
)


def require(condition, message):
    """Keep refusal checks active even when Python optimization is enabled."""
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    """Refuse duplicate decoded fields, including escaped spellings of a key."""
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate native receipt field")
        result[key] = value
    return result


def validate_budget(value):
    """Preserve the existing SDK worker's thirty-second envelope."""
    require(type(value) is int and 0 < value <= CONTROLLER_SECONDS, "Invalid hosted clock budget")
    return value


def command(arguments, deadline, maximum):
    """Bound every prerequisite command by the same absolute parent deadline."""
    remaining = deadline - time.monotonic()
    require(remaining > 0, "Hosted clock prerequisite deadline exhausted")
    result = subprocess.run(
        arguments, capture_output=True, timeout=min(maximum, remaining), check=False
    )
    require(
        result.returncode == 0, "Hosted clock prerequisite command refused: " + str(arguments[0])
    )
    require(time.monotonic() < deadline, "Hosted clock prerequisite exceeded its deadline")
    return result


def digest(path):
    """Read exact source bytes without human-output filtering."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def qualified_pin(repo):
    """Reuse the official runtime selection and checksum already qualified by CI."""
    version = facade.selected_version(repo)
    require(version == "1.1.1", "Hosted clock source qualification requires Hammerspoon 1.1.1")
    workflow = (repo / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
    pins = re.findall(
        r"printf '%s  %s\\n' ([0-9a-f]{64}) \"\$archive\" \| shasum -a 256 --check",
        workflow,
    )
    require(len(pins) == 1, "Qualified official runtime checksum absent or ambiguous")
    return version, pins[0]


def verify_archive(archive, expected):
    """A bounded ordinary archive must match selected official bytes before extraction."""
    info = archive.lstat()
    require(
        stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_ARCHIVE_BYTES,
        "Runtime archive unavailable",
    )
    require(digest(archive) == expected, "Official runtime archive checksum differs")


def admit_runtime(app, version, deadline):
    """Retain existing strict signature and Gatekeeper policies within the SDK budget."""
    require(app.resolve(strict=True) == app and app.is_dir(), "Redirected native runtime refused")
    with (app / "Contents/Info.plist").open("rb") as stream:
        information = plistlib.load(stream)
    require(
        information.get("CFBundleShortVersionString") == version, "Native runtime version differs"
    )
    executable = app / "Contents/MacOS/Hammerspoon"
    require(
        executable.is_file() and not executable.is_symlink() and os.access(executable, os.X_OK),
        "Native runtime executable unavailable",
    )
    evidence = {}
    for label, args in (
        ("codesign", ["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)]),
        ("signer", ["/usr/bin/codesign", "--display", "--verbose=4", str(app)]),
        (
            "gatekeeper",
            ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
        ),
    ):
        result = command(args, deadline, 3)
        evidence[label] = {
            "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
            "stderr_sha256": hashlib.sha256(result.stderr).hexdigest(),
        }
    return executable, evidence


class AcquisitionRefused(ValueError):
    """Preserve typed acquisition facts without changing TLS trust or error policy."""

    def __init__(self, evidence):
        self.evidence = dict(evidence)
        super().__init__(
            "Official runtime acquisition refused: " + str(evidence.get("refusal", "stage_refused"))
        )


def download_archive(url, archive, deadline):
    """Retain actual curl HTTP/TLS/deadline facts, never fall back to another trust path."""
    evidence = {
        "curl_returncode": None,
        "http_status": None,
        "ssl_verify_result": None,
        "http_response_known": False,
        "tls_policy": "default trust; peer and host verification enabled",
        "curl_error_summary": None,
        "stdout_sha256": None,
        "stderr_sha256": None,
    }
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise AcquisitionRefused(dict(evidence, refusal="deadline"))
    try:
        result = subprocess.run(
            [
                "/usr/bin/curl",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--write-out",
                "%{http_code} %{ssl_verify_result}",
                "--max-time",
                str(min(ACQUISITION_SECONDS, remaining)),
                "--output",
                str(archive),
                url,
            ],
            capture_output=True,
            timeout=min(ACQUISITION_SECONDS, remaining),
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise AcquisitionRefused(dict(evidence, refusal="deadline")) from None
    evidence["curl_returncode"] = result.returncode
    evidence["stdout_sha256"] = hashlib.sha256(result.stdout).hexdigest()
    evidence["stderr_sha256"] = hashlib.sha256(result.stderr).hexdigest()
    metadata = re.fullmatch(rb"([0-9]{3}) ([0-9]{1,10})", result.stdout.strip())
    if metadata is not None:
        evidence["http_status"] = int(metadata.group(1))
        evidence["ssl_verify_result"] = int(metadata.group(2))
        evidence["http_response_known"] = 100 <= evidence["http_status"] <= 599
    if result.returncode == 60 or (evidence["ssl_verify_result"] not in (None, 0)):
        refusal, summary = "certificate_verification", "curl certificate verification failed"
    elif result.returncode == 35:
        refusal, summary = "tls_handshake", "curl TLS handshake failed"
    elif result.returncode == 28 or time.monotonic() >= deadline:
        refusal, summary = "deadline", "curl acquisition deadline exhausted"
    elif result.returncode == 22 or (
        evidence["http_response_known"] and evidence["http_status"] != 200
    ):
        refusal, summary = "http_status", "curl HTTP response refused"
    elif result.returncode != 0:
        refusal, summary = "transport_exit", "curl transport refused"
    elif metadata is None:
        refusal, summary = "transport_metadata", "curl transport metadata unavailable"
    elif evidence["http_status"] != 200:
        refusal, summary = "transport_metadata", "curl successful HTTP response unavailable"
    else:
        return evidence
    raise AcquisitionRefused(dict(evidence, refusal=refusal, curl_error_summary=summary))


def acquire_runtime(repo, root, deadline):
    """Acquire independently of other jobs, retaining every typed failure stage privately."""
    started = time.monotonic()
    deadline = min(deadline, started + ACQUISITION_SECONDS)
    evidence = {
        "schema": 1,
        "status": "error",
        "stage": "version_pin",
        "phase_budget_seconds": ACQUISITION_SECONDS,
        "version": None,
        "origin": None,
        "archive_sha256_expected": None,
        "archive_sha256_actual": None,
        "transport": None,
        "error_summary": None,
    }
    try:
        version, pin = qualified_pin(repo)
        url = f"https://github.com/Hammerspoon/hammerspoon/releases/download/{version}/Hammerspoon-{version}.zip"
        evidence.update(version=version, origin=url, archive_sha256_expected=pin)
        archive = root / "Hammerspoon.zip"
        evidence["stage"] = "download"
        evidence["transport"] = download_archive(url, archive, deadline)
        evidence["stage"] = "archive_checksum"
        info = archive.lstat()
        if stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_ARCHIVE_BYTES:
            evidence["archive_sha256_actual"] = digest(archive)
        verify_archive(archive, pin)
        evidence["stage"] = "extract"
        extracted = root / "runtime"
        extracted.mkdir(mode=0o700)
        command(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], deadline, 3)
        evidence["stage"] = "signature"
        app = extracted / "Hammerspoon.app"
        executable, signatures = admit_runtime(app, version, deadline)
        runtime_digest = digest(executable)
        if time.monotonic() >= deadline:
            raise AcquisitionRefused({"refusal": "deadline"})
        evidence.update(status="ok", stage="ready")
        return executable, {
            "version": version,
            "origin": url,
            "archive_sha256": pin,
            "executable_sha256": runtime_digest,
            "signature_replies": signatures,
            "publisher_evidence": "selected official HTTPS archive bytes; strict signature and Gatekeeper accepted",
        }
    except Exception as error:
        if isinstance(error, AcquisitionRefused):
            if evidence["stage"] == "download":
                evidence["transport"] = error.evidence
            evidence["refusal"] = error.evidence.get("refusal", "stage_refused")
        else:
            evidence["refusal"] = "stage_refused"
        # Closed stage summaries retain the observed boundary without exposing
        # exception strings, headers, URLs supplied by errors, CA or environment.
        summaries = {
            "version_pin": "actual qualified runtime selection refusal",
            "download": "actual HTTPS acquisition refusal",
            "archive_checksum": "actual archive checksum refusal",
            "extract": "actual archive extraction refusal",
            "signature": "actual signature refusal",
        }
        evidence["error_summary"] = summaries.get(
            evidence["stage"], "actual acquisition stage refusal"
        )
        raise AcquisitionRefused(evidence) from None
    finally:
        finished = time.monotonic()
        evidence["elapsed_seconds"] = finished - started
        late_completion = evidence["status"] == "ok" and finished >= deadline
        if late_completion:
            evidence.update(
                status="error",
                refusal="deadline",
                error_summary="actual acquisition completion deadline exhausted",
            )
        owner.exclusive_receipt(root / "acquisition.json", evidence)
        if late_completion:
            raise AcquisitionRefused(evidence)


def ordinary_owner_root(root):
    """Require the existing canonical private fixture directory without changing it."""
    root = Path(root)
    info = root.lstat()
    require(
        root.is_absolute() and root.resolve(strict=True) == root, "Redirected fixture root refused"
    )
    require(
        stat.S_ISDIR(info.st_mode)
        and stat.S_IMODE(info.st_mode) == 0o700
        and info.st_uid == os.geteuid(),
        "Native fixture root not privately owned",
    )
    return root


def read_receipt(path):
    """Read only bounded ordinary owner bytes; FIFO and symlink reads cannot block."""
    path = Path(path)
    require(path.parent.resolve(strict=True) == path.parent, "Redirected result parent refused")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        require(
            stat.S_ISREG(info.st_mode)
            and info.st_uid == os.geteuid()
            and 0 < info.st_size <= MAX_RECEIPT_BYTES,
            "Native result is not a bounded owner file",
        )
        body = os.read(descriptor, MAX_RECEIPT_BYTES + 1)
        require(len(body) == info.st_size, "Native result changed or was not read completely")
    finally:
        os.close(descriptor)
    packet = json.loads(body, object_pairs_hook=unique_object)
    require(type(packet) is dict, "Native result must be an object")
    return packet


def checked_sample(sample):
    """Check the exact native rational conversion before an unsigned multiply can wrap."""
    require(
        type(sample) is dict and set(sample) == {"ticks", "numer", "denom"},
        "Invalid parent Mach sample",
    )
    require(
        type(sample["ticks"]) is int and 0 <= sample["ticks"] <= (1 << 64) - 1,
        "Invalid parent Mach ticks",
    )
    for key in ("numer", "denom"):
        require(
            type(sample[key]) is int and 0 < sample[key] < (1 << 32), "Invalid actual Mach timebase"
        )
    product = sample["ticks"] * sample["numer"]
    require(product <= (1 << 64) - 1, "Native Mach timebase product would overflow")
    nanoseconds = product // sample["denom"]
    require(nanoseconds <= (1 << 63) - 1, "Native Mach sample exceeds signed Lua representation")
    return nanoseconds


def validate_receipt(packet, expected, bracket):
    """Bind actual C samples to an independent live parent interval, never a token."""
    keys = {
        "schema",
        "status",
        "runtime",
        "version",
        "pid",
        "nonce",
        "getter_what",
        "binding_scope",
        "samples",
        "facts",
    }
    require(type(packet) is dict and set(packet) == keys, "Incomplete native clock result")
    require(
        type(packet["schema"]) is int and packet["schema"] == 1 and packet["status"] == "ok",
        "Native clock diagnostic refused",
    )
    require(
        type(packet["pid"]) is int and packet["pid"] == expected["pid"],
        "Foreign native runtime receipt",
    )
    require(
        packet["version"] == expected["version"] and packet["runtime"] == "native Hammerspoon",
        "Native runtime identity differs",
    )
    require(packet["nonce"] == expected["nonce"], "Stale native result refused")
    require(packet["getter_what"] == "C", "Actual clock getter is not a native C function")
    require(
        packet["binding_scope"] == "borrowed hs.timer.absoluteTime API only",
        "Source token cannot claim native domain authority",
    )
    facts = packet["facts"]
    require(
        type(facts) is dict
        and set(facts) == FACTS
        and all(value is True for value in facts.values()),
        "Incomplete actual source binding lifecycle",
    )
    require(
        type(bracket) is dict and set(bracket) == {"before", "after"},
        "Missing independent parent bracket",
    )
    before, after = bracket["before"], bracket["after"]
    first, last = checked_sample(before), checked_sample(after)
    require(
        before["numer"] == after["numer"]
        and before["denom"] == after["denom"]
        and before["ticks"] <= after["ticks"],
        "Parent native timebase changed or ran backwards",
    )
    samples = packet["samples"]
    require(
        type(samples) is list and len(samples) == len(SAMPLE_PHASES), "Missing native clock samples"
    )
    previous = None
    for phase, sample in zip(SAMPLE_PHASES, samples):
        require(
            type(sample) is dict and set(sample) == {"phase", "ns"} and sample["phase"] == phase,
            "Native sample sequence differs",
        )
        value = sample["ns"]
        require(
            type(value) is str
            and re.fullmatch(r"0|[1-9][0-9]*", value) is not None
            and len(value) <= 19,
            "Native sample lost integral representation",
        )
        value = int(value)
        require(
            value <= (1 << 63) - 1 and first <= value <= last,
            "Native Hammerspoon sample differs from actual parent Mach interval",
        )
        require(previous is None or previous < value, "Actual hosted clock samples are not ordered")
        previous = value
    return packet


class MachTimebase(ctypes.Structure):
    """Use Darwin's two exact uint32 fields rather than architecture assumptions."""

    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class NativeMachClock:
    """Read actual libSystem Mach ticks and checked kernel timebase independently."""

    def __init__(self):
        require(sys.platform == "darwin", "Actual Mach clock requires native macOS")
        require(ctypes.sizeof(MachTimebase) == 8, "Unsupported Mach timebase ABI")
        self.library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.library.mach_absolute_time.argtypes = []
        self.library.mach_absolute_time.restype = ctypes.c_uint64
        self.library.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
        self.library.mach_timebase_info.restype = ctypes.c_int32

    def sample(self):
        """Return kernel scale and actual ticks; unsupported values are never repaired."""
        scale = MachTimebase()
        require(
            self.library.mach_timebase_info(ctypes.byref(scale)) == 0,
            "Native Mach timebase query refused",
        )
        sample = {
            "ticks": self.library.mach_absolute_time(),
            "numer": scale.numer,
            "denom": scale.denom,
        }
        checked_sample(sample)
        return sample


def observe(
    group,
    path,
    expected,
    before,
    mach,
    unchanged,
    deadline,
    *,
    now=time.monotonic,
    pause=time.sleep,
):
    """Admit a complete receipt only while its exact native direct child remains live."""
    while True:
        require(now() < deadline, "Actual hosted clock observation exceeded its deadline")
        require(
            group.observe_exit() is None, "Exact Hammerspoon child exited before clock observation"
        )
        if path.exists() or path.is_symlink():
            packet = read_receipt(path)
            bracket = {"before": before, "after": mach.sample()}
            validate_receipt(packet, expected, bracket)
            unchanged()
            require(
                group.observe_exit() is None,
                "Exact Hammerspoon child exited during clock observation",
            )
            require(now() < deadline, "Actual hosted clock receipt arrived after deadline")
            return {
                "native_result": packet,
                "parent_mach_bracket": bracket,
                "native_execution": "executed",
            }
        pause(0.02)


def validate_owner(report, expected_pid):
    """Subscription detach cannot replace actual reserved inherited-PGID retirement."""
    require(report.get("status") == "ok", "Native observation or retirement refused")
    native = report.get("native_owner")
    require(type(native) is dict, "Missing actual native child retirement")
    require(
        type(native.get("worker_pid")) is int
        and native["worker_pid"] == expected_pid
        and type(native.get("group_id")) is int
        and native["group_id"] == expected_pid,
        "Native process owner differs",
    )
    require(
        native.get("closed") is True
        and native.get("reservation_lost") is False
        and native.get("live_group_members") == []
        and native.get("escaped_sessions_managed") is False,
        "Native group retains retirement debt",
    )


def validate_imports(repo):
    """Use the actual immutable creator and facade loaded from these repo bytes."""
    for module, name in ((owner, "macos_owned_process.py"), (facade, "macos_tooltip_canvas.py")):
        actual = Path(module.__file__).absolute()
        expected = repo / "tools/diagnostics" / name
        require(
            actual == expected and actual.resolve(strict=True) == expected and actual.is_file(),
            "Diagnostic imported another creator or facade",
        )


def run(repo, root, budget=CONTROLLER_SECONDS):
    """Acquire and measure the real prerequisite under the unchanged SDK budget."""
    require(
        sys.platform == "darwin" and sys.version_info >= (3, 13),
        "Requires actual macOS CPython3.13+ native ownership",
    )
    budget = validate_budget(budget)
    root = ordinary_owner_root(root)
    repo = Path(repo).resolve(strict=True)
    validate_imports(repo)
    start = time.monotonic()
    deadline = start + budget
    output = root / "hosted-clock"
    output.mkdir(mode=0o700)
    here = Path(__file__).resolve().parent
    require(here == repo / "tools/diagnostics", "Diagnostic loaded from another source")
    inputs = SOURCE_FILES + (
        "tools/diagnostics/macos_physical_clock.py",
        "tools/diagnostics/macos_physical_clock.lua",
        "tools/diagnostics/macos_owned_process.py",
        "tools/diagnostics/macos_tooltip_canvas.py",
        "tools/build/build_macos_app.sh",
        ".github/workflows/ci-macos.yml",
    )
    before = {}
    for relative in inputs:
        path = repo / relative
        require(
            path.resolve(strict=True) == path and path.is_file(), "Redirected source input refused"
        )
        before[relative] = digest(path)
    source = output / "source"
    for relative in SOURCE_FILES:
        path = source / relative
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(repo / relative, path)
    acquisition_start = time.monotonic()
    executable, provisioning = acquire_runtime(
        repo, output, min(deadline, time.monotonic() + ACQUISITION_SECONDS)
    )
    acquisition_end = time.monotonic()
    if acquisition_end - acquisition_start > ACQUISITION_SECONDS:
        late = {
            "schema": 1,
            "status": "error",
            "stage": "acquisition_completion",
            "refusal": "deadline",
            "phase_budget_seconds": ACQUISITION_SECONDS,
            "elapsed_seconds": acquisition_end - acquisition_start,
        }
        owner.exclusive_receipt(output / "acquisition-completion.json", late)
        raise AcquisitionRefused(late)
    config = output / "init.lua"
    shutil.copyfile(here / "macos_physical_clock.lua", config)
    nonce = uuid.uuid4().hex
    owner.exclusive_receipt(
        output / "probe-config.json",
        {
            "source_root": str(source),
            "output_dir": str(output),
            "nonce": nonce,
            "version": provisioning["version"],
        },
    )
    owner.exclusive_receipt(output / "source-identities.json", before)
    native = owner.NativeProcessGroups()
    mach = NativeMachClock()
    bracket_start = mach.sample()
    actual_pid = None

    def unchanged():
        for relative, expected in before.items():
            require(
                digest(repo / relative) == expected, "Live source input changed during observation"
            )
        for relative in SOURCE_FILES:
            require(
                digest(source / relative) == before[relative],
                "Copied source input changed during observation",
            )
        require(
            digest(config) == before["tools/diagnostics/macos_physical_clock.lua"],
            "Copied native probe changed",
        )
        require(
            digest(executable) == provisioning["executable_sha256"],
            "Owned runtime executable changed",
        )

    def operation(group):
        nonlocal actual_pid
        actual_pid = group.process.pid
        expected = {"pid": actual_pid, "version": provisioning["version"], "nonce": nonce}
        return observe(
            group,
            output / "result.json",
            expected,
            bracket_start,
            mach,
            unchanged,
            min(deadline, time.monotonic() + PROBE_SECONDS),
        )

    report = facade.owned_observation(executable, config, output, operation, native)
    owner.exclusive_receipt(output / "supervisor.json", report)
    validate_owner(report, actual_pid)
    elapsed = time.monotonic() - start
    require(
        elapsed <= budget, "Hosted prerequisite and retirement exceeded fixed SDK controller budget"
    )
    result = {
        "status": "ok",
        "qualification": "actual hosted samples match independently checked parent Mach nanoseconds",
        "binding_token_scope": "borrowed API subscription identity only",
        "provisioning": provisioning,
        "acquisition_seconds": acquisition_end - acquisition_start,
        "setup_seconds": acquisition_start - start,
        "total_seconds": elapsed,
        "controller_budget_seconds": budget,
        "parent_mach_bracket": report["parent_mach_bracket"],
        "native_result": report["native_result"],
        "native_owner": report["native_owner"],
        "source_identities": before,
        "physical_input": "unexecuted",
        "wall_epoch_and_awake_generation": "unqualified",
        "installation": "unexecuted",
        "permission_history": "unadmitted",
    }
    owner.exclusive_receipt(output / "qualification.json", result)
    return result


def main():
    """Expose one native observation without a fake-platform success or skip mode."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--budget", type=int, default=CONTROLLER_SECONDS)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.repo, args.root, args.budget), sort_keys=True))
        return 0
    except Exception as error:
        print("Hosted native clock qualification refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
