#!/usr/bin/env python3
# tools/diagnostics/native_hs_program_providers/run_native.py
"""Qualify actual pinned Hammerspoon provider inventory, never user-program execution."""

import argparse
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import zipfile

VERSION = "1.1.1"
ASSET = "Hammerspoon-1.1.1.zip"
API = "https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1"
CONTRACT = "macos-native-hs-program-providers"
BYTE_LIMIT = 32768
TIMEOUT = 45
PINS = (
    "static/ergopti_plus/macos/adapters/program_providers.lua",
    "static/ergopti_plus/macos/infra/fs_dir.lua",
    "static/ergopti_plus/_shared/lua/program_providers.lua",
    "static/ergopti_plus/_shared/modules/actions/program_providers.json",
    "static/ergopti_plus/_shared/lua/program_parameter.lua",
    "static/ergopti_plus/_shared/lua/json.lua",
    "static/ergopti_plus/_shared/lua/compat/utf8.lua",
    "tools/diagnostics/macos_owned_process.py",
)
DIAGNOSTIC_PINS = (
    "tools/diagnostics/native_hs_program_providers/fixture.lua",
    "tools/diagnostics/native_hs_program_providers/fixture_shim.lua",
    "tools/diagnostics/native_hs_program_providers/run_native.py",
)
DIAGNOSTIC_CONTRACT = "macos-native-hs-program-provider-diagnostic-facts"
FULL = (
    "actual_native_runtime",
    "exact_source_pins_before",
    "inventory_independent_choices",
    "literal_v1_independent_argv",
    "real_interpreter_symlink",
    "interpreter_link_retarget_is_stale",
    "replaced_script_is_stale",
    "proven_missing_root_is_neutral",
    "script_root_symlink_is_refused",
    "native_bounded_directory_loop",
    "native_directory_close_observation",
    "native_listing_failure_is_private",
    "invalid_utf8_native_name_fails_closed",
    "configured_route_change_is_stale",
    "no_private_diagnostics_or_execution",
    "exact_source_pins_after",
)
SHIM = (
    "actual_native_runtime",
    "exact_source_pins_before",
    "real_system_shim_present",
    "fixed_system_python_shim_is_not_installed_provider",
    "exact_source_pins_after",
)
SCOPE = {
    "inventory": True,
    "program_execution": False,
    "effective_acl_verified": False,
    "closedir_errno_observed": False,
    "atomic_execution_lease": False,
}


def require(value, category):
    if value is not True:
        raise ValueError(category)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate_json_key")
        value[key] = item
    return value


def decode_receipt(raw):
    require(type(raw) is bytes and 0 < len(raw) <= BYTE_LIMIT, "receipt_size_refused")
    return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)


def validate_receipt(value, scenario, source_sha, nonce, pid, hashes):
    require(type(hashes) is dict and set(hashes) == set(PINS), "source_pin_census_refused")
    require(
        re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None
        and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None,
        "expected_identity_refused",
    )
    fields = {
        "schema",
        "contract",
        "source_sha",
        "nonce",
        "pid",
        "scenario",
        "source_hashes",
        "cases",
        "counts",
        "scope",
    }
    require(type(value) is dict and set(value) == fields, "receipt_fields_refused")
    require(type(value["schema"]) is int and value["schema"] == 1, "receipt_schema_refused")
    require(
        value["contract"] == CONTRACT and value["scenario"] == scenario, "receipt_contract_refused"
    )
    require(value["source_sha"] == source_sha and value["nonce"] == nonce, "receipt_stale")
    require(type(value["pid"]) is int and value["pid"] == pid and pid > 0, "receipt_owner_refused")
    require(value["source_hashes"] == hashes, "receipt_sources_refused")
    require(
        type(value["scope"]) is dict and set(value["scope"]) == set(SCOPE), "receipt_scope_refused"
    )
    for name, expected in SCOPE.items():
        require(
            type(value["scope"][name]) is bool and value["scope"][name] is expected,
            "receipt_scope_refused",
        )
    expected = FULL if scenario == "full" else SHIM if scenario == "shim" else ()
    require(
        bool(expected) and type(value["cases"]) is list and len(value["cases"]) == len(expected),
        "receipt_census_refused",
    )
    for item, identifier in zip(value["cases"], expected):
        require(type(item) is dict and set(item) == {"id", "status"}, "receipt_case_refused")
        require(item["id"] == identifier and item["status"] == "passed", "native_case_failed")
    counts = value["counts"]
    require(
        type(counts) is dict and set(counts) == {"passed", "failed", "skipped"},
        "receipt_counts_refused",
    )
    require(all(type(n) is int for n in counts.values()), "receipt_counts_refused")
    require(
        counts == {"passed": len(expected), "failed": 0, "skipped": 0}, "receipt_counts_refused"
    )
    return len(expected)


def validate_diagnostic_facts(value, primary, scenario, source_sha, nonce, pid, hashes):
    """Admit closed diagnostic facts only; this never admits a native PASS."""
    fields = {
        "schema",
        "contract",
        "source_sha",
        "nonce",
        "pid",
        "scenario",
        "source_hashes",
        "case_facts",
        "runtime",
        "interpreter",
        "expected_path_equal",
    }
    require(type(value) is dict and set(value) == fields, "diagnostic_fields_refused")
    require(type(value["schema"]) is int and value["schema"] == 1, "diagnostic_schema_refused")
    require(value["contract"] == DIAGNOSTIC_CONTRACT, "diagnostic_contract_refused")
    require(
        re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None
        and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None
        and value["source_sha"] == source_sha
        and value["nonce"] == nonce
        and value["scenario"] == scenario,
        "diagnostic_stale",
    )
    require(
        type(value["pid"]) is int and value["pid"] == pid and pid > 0, "diagnostic_owner_refused"
    )
    require(
        type(hashes) is dict
        and set(hashes) == set(DIAGNOSTIC_PINS)
        and all(
            type(digest) is str and re.fullmatch(r"[0-9a-f]{64}", digest)
            for digest in hashes.values()
        )
        and value["source_hashes"] == hashes,
        "diagnostic_sources_refused",
    )
    expected = FULL if scenario == "full" else SHIM if scenario == "shim" else ()
    require(
        type(primary) is dict and type(primary.get("cases")) is list, "diagnostic_census_refused"
    )
    require(bool(expected) and len(primary["cases"]) == len(expected), "diagnostic_census_refused")
    require(
        type(value["case_facts"]) is list and len(value["case_facts"]) == len(expected),
        "diagnostic_census_refused",
    )
    for primary_item, item, identifier in zip(primary["cases"], value["case_facts"], expected):
        require(
            type(primary_item) is dict
            and set(primary_item) == {"id", "status"}
            and primary_item["id"] == identifier
            and primary_item["status"] in ("passed", "failed"),
            "diagnostic_census_refused",
        )
        require(
            type(item) is dict
            and set(item) == {"case", "kind", "ordinal"}
            and item["case"] == identifier
            and type(item["ordinal"]) is int,
            "diagnostic_failure_refused",
        )
        if primary_item["status"] == "passed":
            require(item["kind"] == "none" and item["ordinal"] == 0, "diagnostic_failure_refused")
        else:
            require(
                (item["kind"] == "check" and 0 < item["ordinal"] < (1 << 53))
                or (item["kind"] == "raised" and item["ordinal"] == 0),
                "diagnostic_failure_refused",
            )
    runtime = value["runtime"]
    function_fields = {"dir", "attributes", "symlink_attributes", "path_to_absolute", "file_open"}
    require(
        type(runtime) is dict and set(runtime) == function_fields | {"lua_version"},
        "diagnostic_runtime_refused",
    )
    require(
        runtime["lua_version"] in ("Lua 5.1", "Lua 5.2", "Lua 5.3", "Lua 5.4", "Lua 5.5", "other"),
        "diagnostic_runtime_refused",
    )
    require(
        all(
            runtime[name] in ("C", "Lua", "main", "missing", "unknown") for name in function_fields
        ),
        "diagnostic_runtime_refused",
    )
    interpreter = value["interpreter"]
    require(
        type(interpreter) is dict
        and set(interpreter)
        == {
            "resolved_scalar_observed",
            "interpreter_equal",
            "argv_count_equal",
            "script_argument_equal",
        }
        and all(type(item) is bool for item in interpreter.values())
        and type(value["expected_path_equal"]) is bool,
        "diagnostic_interpreter_refused",
    )


def report_diagnostic_facts(value, primary, scenario, source_sha, nonce, pid, hashes):
    """Print validated closed facts; no private identity or native verdict escapes."""
    validate_diagnostic_facts(value, primary, scenario, source_sha, nonce, pid, hashes)
    print(
        json.dumps(
            {
                "contract": DIAGNOSTIC_CONTRACT,
                "scenario": scenario,
                "case_facts": value["case_facts"],
                "runtime": value["runtime"],
                "interpreter": value["interpreter"],
                "expected_path_equal": value["expected_path_equal"],
            }
        ),
        flush=True,
    )


def lua_string(value):
    return '"' + "".join("\\%03d" % byte for byte in value.encode("utf-8")) + '"'


def settle_registered(owners):
    """Retire registered capabilities even if acquisition never returned its handle."""
    previous = {}
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous[sig] = signal.signal(sig, signal.SIG_IGN)
        for group in owners:
            require(group.settle(), "native_group_retirement_refused")
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def owned_tool(arguments, native, ownership, accepted=(0,), **options):
    owners = []
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            group = ownership.acquire_owned(
                arguments, native, owners.append, stdout=out, stderr=err, **options
            )
            group.wait_for_exit(20)
        finally:
            settle_registered(owners)
        require(group.process.returncode in accepted, "native_tool_refused")
        out.seek(0)
        err.seek(0)
        return out.read(1048577), err.read(1048577), group.process.returncode


def source_hashes(root, sha, paths=PINS):
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "source_sha_refused")
    result = {}
    for path in paths:
        committed = subprocess.check_output(["git", "show", sha + ":" + path], cwd=root)
        raw = (root / path).read_bytes()
        require(raw == committed, "source_worktree_drift")
        result[path] = hashlib.sha256(raw).hexdigest()
    return result


@contextmanager
def bootstrap_response(phase, request, *, timeout):
    """Report closed network facts, then preserve the original failure and cleanup."""
    require(
        type(phase) is str and phase in ("release_metadata", "archive_download"),
        "bootstrap_phase_refused",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            yield response
    except (HTTPError, URLError, TimeoutError, ssl.SSLError) as error:
        # No URL, request/response headers, body, or arbitrary exception text.
        # A failed diagnostic write cannot replace the original network error;
        # process interruption remains visible rather than being swallowed.
        try:
            status = None
            if isinstance(error, HTTPError):
                family = "http_error"
                code = error.code
                if type(code) is int and 100 <= code <= 599:
                    status = code
            elif isinstance(error, ssl.SSLError) or (
                isinstance(error, URLError) and isinstance(error.reason, ssl.SSLError)
            ):
                family = "tls_error"
            elif isinstance(error, TimeoutError):
                family = "read_timeout"
            else:
                family = "transport_error"
            print(
                json.dumps(
                    {
                        "schema": 1,
                        "contract": "macos-native-bootstrap-failure",
                        "phase": phase,
                        "family": family,
                        "http_status": status,
                        "native_pass": False,
                    }
                ),
                flush=True,
            )
        except Exception:
            pass
        raise


def trusted_asset(output):
    request = Request(
        API,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "ErgoptiPlus-native-qualification",
        },
    )
    with bootstrap_response("release_metadata", request, timeout=20) as reply:
        raw = reply.read(1048577)
    require(len(raw) <= 1048576, "release_metadata_size_refused")
    release = json.loads(raw)
    matches = [a for a in release.get("assets", []) if a.get("name") == ASSET]
    require(release.get("tag_name") == VERSION and len(matches) == 1, "release_asset_refused")
    asset = matches[0]
    require(
        type(asset.get("digest")) is str
        and re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"]) is not None,
        "trusted_digest_missing",
    )
    require(
        type(asset.get("size")) is int and 0 < asset["size"] < 16 * 1024 * 1024,
        "release_size_refused",
    )
    require(
        asset.get("browser_download_url")
        == "https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/" + ASSET,
        "release_url_refused",
    )
    return asset


def verify_archive(archive, asset):
    raw = archive.read_bytes()
    require(
        len(raw) == asset["size"] and hashlib.sha256(raw).hexdigest() == asset["digest"][7:],
        "archive_digest_refused",
    )
    with zipfile.ZipFile(archive) as zipped:
        names = zipped.namelist()
        require(len(names) == len(set(names)), "archive_duplicate_member")
        for name in names:
            path = Path(name)
            require(not path.is_absolute() and ".." not in path.parts, "archive_path_refused")


def verify_bundle(app, archive, native, ownership):
    with zipfile.ZipFile(archive) as zipped:
        expected = set()
        for item in zipped.infolist():
            if not item.filename.startswith("Hammerspoon.app/") or item.is_dir():
                continue
            relative = item.filename[len("Hammerspoon.app/") :]
            expected.add(relative)
            path = app / relative
            data = zipped.read(item)
            if stat.S_ISLNK(item.external_attr >> 16):
                require(
                    path.is_symlink() and os.readlink(path).encode() == data, "bundle_symlink_drift"
                )
            else:
                require(
                    path.is_file() and not path.is_symlink() and path.read_bytes() == data,
                    "bundle_file_drift",
                )
        require(bool(expected), "bundle_inventory_empty")
        actual = set()
        for directory, folders, files in os.walk(app, followlinks=False):
            for name in files + [n for n in folders if (Path(directory) / n).is_symlink()]:
                actual.add(str((Path(directory) / name).relative_to(app)))
        require(actual == expected, "bundle_inventory_drift")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleShortVersionString") == VERSION, "bundle_version_refused")
    require(
        info.get("CFBundleIdentifier") == "org.hammerspoon.Hammerspoon", "bundle_identity_refused"
    )
    owned_tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], native, ownership)
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    require(binary.is_file() and os.access(binary, os.X_OK), "bundle_executable_refused")
    return binary, info["CFBundleIdentifier"]


def prepare(base, source_root, sha, nonce, hashes, scenario):
    config = base / "configuration 日本 e\u0301"
    scripts = config / "scripts"
    scripts.mkdir(parents=True)
    binary = base / "bin"
    binary.mkdir()
    for name, target in (
        ("sh", "/bin/sh"),
        ("bash", "/bin/bash"),
        ("python3", os.path.realpath(sys.executable)),
    ):
        (binary / name).symlink_to(target)
    shell_name = "日本 e\u0301\n%PATH%.sh"
    for name, contents, mode in (
        (shell_name, b"#!/bin/sh\nexit 37\n", 0o600),
        ("literal.bash", b"exit 37\n", 0o600),
        ("literal.py", b"import sys\nsys.exit(37)\n", 0o600),
        ("literal-tool", b"#!/bin/sh\nexit 37\n", 0o700),
        ("no-read.sh", b"PRIVATE\n", 0),
    ):
        (scripts / name).write_bytes(contents)
        (scripts / name).chmod(mode)
    (scripts / "script-link.sh").symlink_to(scripts / shell_name)
    (scripts / "folder").mkdir()
    os.mkfifo(scripts / "pipe.sh", 0o600)
    replacement = base / "replacement.sh"
    replacement.write_bytes(b"#!/bin/sh\nexit 37\n")
    replacement.chmod(0o600)
    other_python = base / "actual-python-copy"
    shutil.copyfile(os.path.realpath(sys.executable), other_python)
    other_python.chmod(0o700)
    retarget = base / "retarget-python"
    retarget.symlink_to(other_python)
    restore = base / "restore-python"
    restore.symlink_to(os.path.realpath(sys.executable))
    hidden = base / "hidden-scripts"
    root_link = base / "root-link"
    root_link.symlink_to(hidden)
    bounded = base / "bounded"
    bounded.mkdir()
    for index in range(257):
        (bounded / ("entry-%03d" % index)).write_bytes(b"")
    invalid = base / "invalid-configuration"
    (invalid / "scripts").mkdir(parents=True)
    invalid_rejected = False
    try:
        fd = os.open(
            os.fsencode(invalid / "scripts") + b"/invalid-\xff.sh",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.close(fd)
    except OSError as error:
        require(error.errno in (errno.EINVAL, errno.EILSEQ), "invalid_name_setup_refused")
        invalid_rejected = True
    return {
        "scenario": scenario,
        "source_root": str(source_root),
        "source_sha": sha,
        "source_hashes": hashes,
        "nonce": nonce,
        "config": str(config),
        "bin": str(binary),
        "shell_name": shell_name,
        "expected_sh": os.path.realpath("/bin/sh"),
        "expected_python": os.path.realpath(sys.executable),
        "retarget_link": str(retarget),
        "restore_link": str(restore),
        "replacement_script": str(replacement),
        "hidden_root": str(hidden),
        "root_link": str(root_link),
        "bounded": str(bounded),
        "invalid_config": str(invalid),
        "invalid_native_name_rejected": invalid_rejected,
        "other_config": str(base / "other-configuration"),
        "absent_root": str(base / "absent-scripts"),
        "nonexistent": str(base / "missing-directory"),
        "receipt": str(base / "receipt.json"),
    }


def read_packet(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        named = path.lstat()
        require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino) == (named.st_dev, named.st_ino),
            "receipt_identity_refused",
        )
        return decode_receipt(os.read(descriptor, BYTE_LIMIT + 1))
    finally:
        os.close(descriptor)


def await_packet(path, group, timeout=TIMEOUT, clock=time.monotonic, pause=time.sleep):
    deadline = clock() + timeout
    while not path.exists():
        require(group.observe_exit() is None, "native_runtime_exited_without_receipt")
        require(clock() < deadline, "native_receipt_timeout")
        pause(0.05)


def runtime_origin(app_binary):
    """Pin exact official packaged wrapper/native library; no runtime API mock."""
    app = Path(app_binary).parent.parent.parent
    selected = {
        "script": (
            app / "Contents/Resources/extensions/hs/fs.lua",
            "7006e6d4917d1cd9d2eefdcdfe8de99ab6ee8242d5da3b2d656b0fdede959b45",
        ),
        "native": (
            app / "Contents/Frameworks/hs/libfs.dylib",
            "a1e0626a5ce6f013033fdc7fe0ff74dfc242d72e98b3620bf328c82af46775f6",
        ),
    }
    pins = {}
    for name, (path, expected) in selected.items():
        before = path.stat()
        require(
            stat.S_ISREG(before.st_mode) and not path.is_symlink(), "runtime_origin_file_refused"
        )
        with path.open("rb") as handle:
            raw = handle.read(1048577)
        after = path.stat()
        require(
            len(raw) <= 1048576
            and before.st_dev == after.st_dev
            and before.st_ino == after.st_ino
            and hashlib.sha256(raw).hexdigest() == expected,
            "runtime_origin_bytes_refused",
        )
        pins[name] = {
            "path": str(path),
            "dev": after.st_dev,
            "ino": after.st_ino,
            "sha256": expected,
        }
    return pins


def run_case(
    scenario, app_binary, root, sha, output, hashes, native, ownership, diagnostic_hashes=None
):
    base = Path(tempfile.mkdtemp(prefix=scenario + "-", dir=output))
    base.chmod(0o700)
    nonce = secrets.token_hex(16)
    value = prepare(base, root, sha, nonce, hashes, scenario)
    value["runtime_origin"] = runtime_origin(app_binary)
    if scenario == "full":
        link = base / "bin/python3"
        target = Path(os.path.realpath(sys.executable))
        link_stat, target_stat = link.lstat(), target.stat()
        require(
            stat.S_ISLNK(link_stat.st_mode) and stat.S_ISREG(target_stat.st_mode),
            "runtime_link_witness_refused",
        )
        value["runtime_link_witness"] = {
            "link": str(link),
            "target": str(target),
            "link_identity": {"dev": link_stat.st_dev, "ino": link_stat.st_ino},
            "target_identity": {"dev": target_stat.st_dev, "ino": target_stat.st_ino},
        }
    template = (
        Path(__file__)
        .with_name("fixture.lua" if scenario == "full" else "fixture_shim.lua")
        .read_text()
    )
    startup = base / "init.lua"
    environment = dict(
        os.environ,
        PATH=str(base / "bin") + ":/bin:/usr/bin" if scenario == "full" else "/usr/bin:/bin",
    )
    environment.pop("__CFBundleIdentifier", None)
    environment.pop("__CFBundlePath", None)
    value["diagnostic_source_hashes"] = diagnostic_hashes
    value["diagnostic_facts"] = str(base / "diagnostic-facts.json")
    value["expected_path"] = environment["PATH"]
    startup.write_text(
        template.replace("__INPUT_JSON__", lua_string(json.dumps(value, ensure_ascii=False)))
    )
    owners = []
    group = None
    packet = None
    try:
        group = ownership.acquire_owned(
            [
                str(app_binary),
                "-MJConfigFile",
                str(startup),
                "-SUEnableAutomaticChecks",
                "NO",
                "-SUHasLaunchedBefore",
                "YES",
            ],
            native,
            owners.append,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        await_packet(Path(value["receipt"]), group)
        packet = read_packet(Path(value["receipt"]))
        expected_cases = FULL if scenario == "full" else SHIM
        for item, expected in zip(packet.get("cases", []), expected_cases):
            if (
                type(item) is dict
                and item.get("id") == expected
                and item.get("status") in ("passed", "failed")
            ):
                print(
                    json.dumps(
                        {
                            "contract": CONTRACT,
                            "scenario": scenario,
                            "case": expected,
                            "status": item["status"],
                        }
                    ),
                    flush=True,
                )
        facts = read_packet(Path(value["diagnostic_facts"]))
        report_diagnostic_facts(
            facts, packet, scenario, sha, nonce, group.process.pid, diagnostic_hashes
        )
        validate_receipt(packet, scenario, sha, nonce, group.process.pid, hashes)
        group.wait_for_exit(5)
    finally:
        settle_registered(owners)
        for retained in owners:
            (base / "physical-group.json").write_text(json.dumps(retained.receipt()) + "\n")
    require(group is not None and group.process.returncode == 0, "native_runtime_status_refused")
    return {
        "scenario": scenario,
        "passed": len(FULL if scenario == "full" else SHIM),
        "physical_group": group.receipt(),
        "receipt": str(Path(value["receipt"]).relative_to(output)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    require(
        sys.platform == "darwin" and sys.version_info >= (3, 13),
        "native_python_prerequisite_refused",
    )
    root = args.source_root.resolve()
    spec = importlib.util.spec_from_file_location(
        "native_group_owner", root / "tools/diagnostics/macos_owned_process.py"
    )
    ownership = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ownership)

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("native_probe_interrupted")

    # Acquisition replays pending signals after registration; a raising handler
    # reaches each caller's retained-capability finally instead of killing it.
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    native = ownership.NativeProcessGroups()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    hashes = source_hashes(root, args.source_sha)
    diagnostic_hashes = source_hashes(root, args.source_sha, DIAGNOSTIC_PINS)
    asset = trusted_asset(args.output)
    archive, app = args.archive, args.app
    if args.download:
        require(archive is None and app is None, "bootstrap_arguments_refused")
        archive = args.output / ASSET
        with (
            bootstrap_response(
                "archive_download", asset["browser_download_url"], timeout=30
            ) as incoming,
            archive.open("xb") as target,
        ):
            raw = incoming.read(asset["size"] + 1)
            target.write(raw)
        verify_archive(archive, asset)
        extracted = args.output / "official"
        extracted.mkdir()
        owned_tool(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], native, ownership)
        app = extracted / "Hammerspoon.app"
    else:
        require(archive is not None and app is not None, "bootstrap_arguments_refused")
        verify_archive(archive, asset)
    app_binary, domain = verify_bundle(app, archive, native, ownership)
    graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayPixelsWide.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayPixelsWide.restype = ctypes.c_size_t
    require(
        graphics.CGDisplayPixelsWide(graphics.CGMainDisplayID()) > 0, "window_server_unavailable"
    )
    # NSArgumentDomain supplies MJConfigFile; never defaults write/import/delete.
    # Fingerprint the persistent value through its export to detect interference.
    pref_command = ["/usr/bin/defaults", "read", domain, "MJConfigFile"]
    before, _, before_status = owned_tool(pref_command, native, ownership, accepted=(0, 1))
    try:
        runs = [
            run_case(
                scenario,
                app_binary,
                root,
                args.source_sha,
                args.output,
                hashes,
                native,
                ownership,
                diagnostic_hashes,
            )
            for scenario in ("full", "shim")
        ]
    finally:
        after, _, after_status = owned_tool(pref_command, native, ownership, accepted=(0, 1))
        require(
            before_status == after_status and before == after,
            "persistent_config_preference_changed",
        )
    require(source_hashes(root, args.source_sha) == hashes, "source_postrun_drift")
    require(
        source_hashes(root, args.source_sha, DIAGNOSTIC_PINS) == diagnostic_hashes,
        "diagnostic_source_postrun_drift",
    )
    summary = {
        "schema": 1,
        "contract": CONTRACT,
        "source_sha": args.source_sha,
        "native_pass": True,
        "passed": len(FULL) + len(SHIM),
        "failed": 0,
        "skipped": 0,
        "hammerspoon_version": VERSION,
        "asset_digest": asset["digest"],
        "source_hashes": hashes,
        "scope": SCOPE,
        "scenarios": runs,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, sort_keys=True) + "\n")
    print(
        json.dumps(
            {
                "contract": CONTRACT,
                "native_pass": True,
                "passed": summary["passed"],
                "source_sha": args.source_sha,
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            json.dumps(
                {
                    "contract": CONTRACT,
                    "native_pass": False,
                    "reason": str(error)
                    if type(error) is ValueError and re.fullmatch(r"[a-z_]+", str(error))
                    else type(error).__name__,
                }
            )
        )
        raise SystemExit(1)
