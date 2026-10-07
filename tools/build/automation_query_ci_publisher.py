#!/usr/bin/env python3
# tools/build/automation_query_ci_publisher.py
"""Compile the fixed native query product and seal its final signed CI provenance."""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

LAUNCHER = "static/ergopti_plus/macos/launcher/"
STATE = "automation-query-publisher.json"
# Unresolved reservations must outlive business failure and retain native owners.
_RETAINED_COMPILERS = {}


class Refused(RuntimeError):
    """No receipt is published without compiler and signing custody."""


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def digest(path):
    require(path.is_file() and not path.is_symlink(), "nonregular_input")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root, *arguments):
    return subprocess.check_output(["git", *arguments], cwd=root, timeout=10)


def context(root):
    sha = os.environ.get("GITHUB_SHA", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    require(os.environ.get("GITHUB_ACTIONS") == "true", "not_hosted_ci")
    require(re.fullmatch("[0-9a-f]{40}", sha), "invalid_ci_source")
    require(git(root, "rev-parse", "HEAD").decode().strip() == sha, "head_mismatch")
    require(
        re.fullmatch("[1-9][0-9]*", run_id) and re.fullmatch("[1-9][0-9]*", attempt),
        "invalid_ci_run",
    )
    return sha, run_id, attempt


def public_sparkle_lock(raw):
    """Permit diagnostic bytes only for the fixed public dependency schema."""

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result

    try:
        packet = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
        if not isinstance(packet, dict) or type(packet.get("version")) is not int:
            return None
        version = packet["version"]
        if version == 2:
            if set(packet) != {"pins", "version"}:
                return None
        elif version == 3:
            if set(packet) != {"originHash", "pins", "version"}:
                return None
            if not isinstance(packet["originHash"], str) or not re.fullmatch(
                "[0-9a-f]{64}", packet["originHash"]
            ):
                return None
        else:
            return None
        pins = packet["pins"]
        if not isinstance(pins, list) or len(pins) != 1:
            return None
        pin = pins[0]
        if not isinstance(pin, dict) or set(pin) != {"identity", "kind", "location", "state"}:
            return None
        if (pin["identity"], pin["kind"], pin["location"]) != (
            "sparkle",
            "remoteSourceControl",
            "https://github.com/sparkle-project/Sparkle",
        ):
            return None
        state = pin["state"]
        if not isinstance(state, dict) or set(state) != {"revision", "version"}:
            return None
        if state["version"] != "2.9.2" or not isinstance(state["revision"], str):
            return None
        if not re.fullmatch("[0-9a-f]{40}", state["revision"]):
            return None
        return version
    except (ValueError, UnicodeError, TypeError):
        return None


def current_lockfile_facts(root):
    """Read only the fixed lockfile, with bounded no-follow stable-file custody."""
    path = root / LAUNCHER / "Package.resolved"
    facts = {"path": LAUNCHER + "Package.resolved", "status": "read_refused"}
    descriptor = None
    try:
        before_path = path.lstat()
        if not stat.S_ISREG(before_path.st_mode):
            facts["status"] = "nonregular"
            return facts
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            facts["status"] = "nonregular"
            return facts
        if before.st_size > 16384:
            facts.update(status="oversized", byte_count=before.st_size)
            return facts
        raw = bytearray()
        while len(raw) <= 16384:
            part = os.read(descriptor, min(4096, 16385 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(descriptor)
        after_path = path.lstat()

        def identity(info):
            return (
                info.st_dev,
                info.st_ino,
                info.st_mode,
                info.st_size,
                info.st_mtime_ns,
                info.st_ctime_ns,
            )

        if not (
            identity(before_path) == identity(before) == identity(after) == identity(after_path)
        ):
            facts["status"] = "changed"
            return facts
        if len(raw) > 16384 or len(raw) != after.st_size:
            facts["status"] = "changed"
            return facts
        raw = bytes(raw)
        schema = public_sparkle_lock(raw)
        facts.update(
            status="stable",
            byte_count=len(raw),
            sha256=hashlib.sha256(raw).hexdigest(),
            public_sparkle_schema=schema,
        )
        if schema is not None:
            facts["validated_public_bytes_base64"] = base64.b64encode(raw).decode("ascii")
        return facts
    except FileNotFoundError:
        facts["status"] = "absent"
        return facts
    except (OSError, ValueError, OverflowError):
        return facts
    finally:
        if descriptor is not None:
            os.close(descriptor)


def census_refusal_facts(root, sha, expected, actual):
    """Failure-only facts confer no compiler, source, or receipt admission."""
    try:
        missing = sorted(expected - actual)
        # Missing names come only from the committed observer input cohort.
        names = [
            name
            for name in missing
            if len(name) <= 240
            and re.fullmatch(r"static/ergopti_plus/macos/launcher/[A-Za-z0-9_./+-]+", name)
        ]
        packet = {
            "schema": 1,
            "source_sha": sha,
            "expected_count": len(expected),
            "actual_count": len(actual),
            "missing_count": len(missing),
            "missing_paths": names[:128],
            "missing_paths_complete": len(names) == len(missing) and len(names) <= 128,
            "extra_count": len(actual - expected),
            "only_root_lockfile_extra": actual - expected == {LAUNCHER + "Package.resolved"},
            "root_lockfile_expected": LAUNCHER + "Package.resolved" in expected,
            "root_lockfile_observed": LAUNCHER + "Package.resolved" in actual,
            "lockfile": current_lockfile_facts(root),
        }
        print(
            "Automation query publisher census refusal facts: "
            + json.dumps(packet, sort_keys=True, separators=(",", ":")),
            file=sys.stderr,
        )
    except Exception:
        # Reporting must never replace the original strict census refusal.
        pass


def snapshot(root, sha):
    # Use the observer's exact input set, not a caller-supplied census.
    observer_path = "tools/diagnostics/program_actions/run_signed_query_probe.py"
    require(
        git(root, "show", sha + ":" + observer_path) == (root / observer_path).read_bytes(),
        "observer_source_mismatch",
    )
    probe = load_module(root / observer_path, "query_probe")
    paths = probe.source_paths(root, sha)
    expected = {path for path in paths if path.startswith(LAUNCHER)}
    actual = set()
    for directory, dirs, files in os.walk(root / LAUNCHER, followlinks=False):
        dirs[:] = [name for name in dirs if name != ".build"]
        for name in dirs:
            require(not (Path(directory) / name).is_symlink(), "linked_input_directory")
        for name in files:
            path = Path(directory) / name
            if path.suffix in {".swift", ".c", ".h"} or name in {
                "Package.swift",
                "Package.resolved",
            }:
                actual.add(path.relative_to(root).as_posix())
    if actual != expected or not expected:
        census_refusal_facts(root, sha, expected, actual)
    require(actual == expected and bool(expected), "native_input_census_mismatch")
    hashes = {}
    for relative in paths:
        path = root / relative
        raw = path.read_bytes()
        require(
            not path.is_symlink() and git(root, "show", sha + ":" + relative) == raw,
            "tracked_input_mismatch",
        )
        hashes[relative] = digest(path)
    # Pin this publisher and the build owner as additional compiler proof.
    for relative in (
        "tools/build/automation_query_ci_publisher.py",
        "tools/build/build_macos_app.sh",
    ):
        require(
            git(root, "show", sha + ":" + relative) == (root / relative).read_bytes(),
            "publisher_source_mismatch",
        )
    return hashes


def verify_staged(package, hashes):
    observed = set()
    for directory, dirs, files in os.walk(package, followlinks=False):
        dirs[:] = [name for name in dirs if name != ".build"]
        for name in dirs:
            require(not (Path(directory) / name).is_symlink(), "linked_compiler_directory")
        for name in files:
            path = Path(directory) / name
            if path.suffix in {".swift", ".c", ".h"} or name in {
                "Package.swift",
                "Package.resolved",
            }:
                observed.add(path.relative_to(package).as_posix())
    require(observed == set(hashes), "staged_census_changed")
    for relative, expected in hashes.items():
        require(digest(package / relative) == expected, "compiler_input_changed")


def write_once(path, packet):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(packet, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def state(root, directory):
    require(
        not directory.is_symlink() and (directory.stat().st_mode & 0o777) == 0o700, "state_custody"
    )
    packet = json.loads((directory / STATE).read_bytes())
    sha, run_id, attempt = context(root)
    require(
        (packet["source_sha"], packet["ci_run_id"], packet["ci_run_attempt"])
        == (sha, run_id, attempt),
        "stale_ci_state",
    )
    require(snapshot(root, sha) == packet["source_hashes"], "source_changed")
    expected_native = {
        relative[len(LAUNCHER) :]: expected
        for relative, expected in packet["source_hashes"].items()
        if relative.startswith(LAUNCHER)
    }
    require(packet["native_hashes"] == expected_native, "compiler_input_census_omitted")
    verify_staged(directory / "package", packet["native_hashes"])
    require(
        digest(Path(packet["product"])) == packet["unsigned_sha256"], "compiler_product_changed"
    )
    return packet


def native_run(root, arguments, output, timeout=600):
    """Use the qualified native inherited-PGID owner, including interruption cleanup."""
    ownership = load_module(
        root / "tools/diagnostics/macos_owned_process.py", "query_compiler_custody"
    )
    native = ownership.NativeProcessGroups()
    group = None
    previous = {}

    def interrupted(_signum, _frame):
        raise Refused("compiler_interrupted")

    def register(acquired):
        nonlocal group
        group = acquired
        _RETAINED_COMPILERS[id(group)] = group

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, interrupted)
        ownership.acquire_owned(arguments, native, register, stdout=output, stderr=sys.stderr)
        group.wait_for_exit(timeout)
    finally:
        try:
            for signum in previous:
                signal.signal(signum, signal.SIG_IGN)
            require(group is not None, "compiler_acquisition_refused")
            # Business deadlines never authorize dropping a native reservation.
            # A failed/lost observation cannot authorize another group signal.
            warned = False
            while True:
                closed = False
                if not group.reservation_lost and not group.reap_started:
                    try:
                        closed = group.settle()
                    except Exception:
                        pass
                elif group.reaped:
                    closed = True
                if closed:
                    del _RETAINED_COMPILERS[id(group)]
                    break
                if not warned:
                    print(
                        "Automation query publisher retains unknown compiler custody; no product admitted",
                        file=sys.stderr,
                    )
                    warned = True
                # Terminal debt deliberately has no fabricated successful timeout.
                # Once reservation_lost is set this only holds custody, no signals.
                time.sleep(0.1)
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
    require(group.process.returncode == 0, "compiler_failed")


def compile_product(root, directory, runner=native_run):
    require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_ci_required")
    sha, run_id, attempt = context(root)
    hashes = snapshot(root, sha)
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    package = directory / "package"
    package.mkdir()
    native_hashes = {}
    for relative, expected in hashes.items():
        if relative.startswith(LAUNCHER):
            local = relative[len(LAUNCHER) :]
            target = package / local
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / relative, target)
            require(digest(target) == expected, "staged_input_mismatch")
            native_hashes[local] = expected
    swift = Path(
        subprocess.check_output(["/usr/bin/xcrun", "--find", "swift"], timeout=10).decode().strip()
    )
    compiler_target = swift.resolve(strict=True)
    compiler_hash = digest(compiler_target)
    common = [
        str(swift),
        "build",
        "-c",
        "release",
        "--arch",
        "arm64",
        "--arch",
        "x86_64",
        "--package-path",
        str(package),
        "--disable-automatic-resolution",
    ]
    runner(root, common + ["--product", "ErgoptiPlus"], sys.stderr)
    with (directory / "bin-path.txt").open("xb") as output:
        runner(root, common + ["--show-bin-path"], output, 30)
    raw = (directory / "bin-path.txt").read_bytes()
    require(len(raw) < 4096 and raw.count(b"\n") == 1, "compiler_path_refused")
    product = Path(raw.decode().strip()) / "ErgoptiPlus"
    require(
        product.resolve().is_relative_to((package / ".build").resolve()), "foreign_compiler_product"
    )
    require(
        swift.resolve(strict=True) == compiler_target
        and digest(compiler_target) == compiler_hash
        and snapshot(root, sha) == hashes,
        "compiler_source_changed",
    )
    verify_staged(package, native_hashes)
    architectures = (
        subprocess.check_output(["/usr/bin/lipo", "-archs", str(product)], timeout=10)
        .decode()
        .split()
    )
    require(set(architectures) == {"arm64", "x86_64"}, "nonuniversal_product")
    proof = {
        "schema": 1,
        "source_sha": sha,
        "ci_run_id": run_id,
        "ci_run_attempt": attempt,
        "source_hashes": hashes,
        "native_hashes": native_hashes,
        "product": str(product),
        "unsigned_sha256": digest(product),
        "compiler_path": str(swift),
        "compiler_target": str(compiler_target),
        "compiler_sha256": compiler_hash,
        "compiler_arguments": common + ["--product", "ErgoptiPlus"],
        "publisher_sha256": digest(root / "tools/build/automation_query_ci_publisher.py"),
        "builder_sha256": digest(root / "tools/build/build_macos_app.sh"),
    }
    write_once(directory / STATE, proof)
    print(product)


def copied(root, directory, app):
    packet = state(root, directory)
    require(
        digest(app / "Contents/MacOS/ErgoptiAutomationQuery") == packet["unsigned_sha256"],
        "copied_product_mismatch",
    )
    write_once(directory / "copied.json", {"unsigned_sha256": packet["unsigned_sha256"]})


def seal(root, directory, app):
    packet = state(root, directory)
    require(
        json.loads((directory / "copied.json").read_bytes())
        == {"unsigned_sha256": packet["unsigned_sha256"]},
        "copy_proof_missing",
    )
    helper = app / "Contents/MacOS/ErgoptiAutomationQuery"
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(helper)],
        check=True,
        timeout=10,
    )
    signed_hash = digest(helper)
    receipt = {
        "schema": 1,
        "contract": "signed-native-query-build",
        "source_sha": packet["source_sha"],
        "source_hashes": packet["source_hashes"],
        "helper_sha256": signed_hash,
        "ci_run_id": packet["ci_run_id"],
        "ci_run_attempt": packet["ci_run_attempt"],
    }
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    write_once(resources / "automation-query-build.json", receipt)
    write_once(
        directory / "sealed.json",
        {
            "helper_sha256": signed_hash,
            "receipt_sha256": digest(resources / "automation-query-build.json"),
        },
    )


def verify_outer(root, directory, app):
    state(root, directory)
    sealed = json.loads((directory / "sealed.json").read_bytes())
    require(
        digest(app / "Contents/MacOS/ErgoptiAutomationQuery") == sealed["helper_sha256"],
        "outer_sign_changed_helper",
    )
    require(
        digest(app / "Contents/Resources/automation-query-build.json") == sealed["receipt_sha256"],
        "outer_sign_changed_receipt",
    )
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--deep", str(app)],
        check=True,
        timeout=10,
    )
    # Verify again after native verifier execution, then publish a private terminal proof.
    require(
        digest(app / "Contents/MacOS/ErgoptiAutomationQuery") == sealed["helper_sha256"],
        "verification_changed_helper",
    )
    write_once(directory / "outer-verified.json", sealed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["compile", "copied", "seal", "verify"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_ci_required")
    root = args.root.resolve()
    directory = args.directory.absolute()
    if args.operation == "compile":
        compile_product(root, directory)
    else:
        require(args.app is not None, "app_missing")
        {"copied": copied, "seal": seal, "verify": verify_outer}[args.operation](
            root, directory, args.app.absolute()
        )


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError, subprocess.SubprocessError, KeyError) as error:
        print("Automation query publisher REFUSED: " + str(error), file=sys.stderr)
        raise SystemExit(1)
