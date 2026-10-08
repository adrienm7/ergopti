"""TEST-ONLY fixed native properties query; no installation or source authority.

The invoking unchanged SDK Guardian owns all native subprocess retirement.
Compile, signing and observation share one absolute 25-second deadline.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time


class FixtureRefusal(Exception):
    pass


def require(value, reason):
    if not value:
        raise FixtureRefusal(reason)


SIGNER_SHA256 = "f2a492cd326b0808922e4abe0d8e864f5069b6aff772b9399a95e56855fe9bf8"
MACHO_SHA256 = "238fc52ca61326fe05b708954a0d9e84ebecc0f45b5088c06278a3b3ba1eb14b"
IDENTIFIER = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
SIGNING_IDENTIFIER = "com.ergoptiplus.test.vhd-properties"
_signer = None
_signer_source = None
_signer_origin = None
_signer_stamp = None
_signer_operations = None


def source_stamp(info):
    # Reading a genuine source may change atime. Every source-relevant field
    # remains fenced, including nanosecond mtime/ctime and physical link count.
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_gid,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
        info.st_nlink,
    )


def signer():
    global _signer, _signer_source, _signer_origin, _signer_stamp, _signer_operations
    if _signer is None:
        source = Path(__file__).absolute().parent / "hs274_native_signing_fixture.py"
        before = source.lstat()
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "signer_source")
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            require(source_stamp(os.fstat(fd)) == source_stamp(before), "signer_source")
            data = bytearray()
            while chunk := os.read(fd, 65536):
                data.extend(chunk)
                require(len(data) <= 1024 * 1024, "signer_source")
            require(
                source_stamp(os.fstat(fd)) == source_stamp(before)
                and source_stamp(source.lstat()) == source_stamp(before),
                "signer_source",
            )
        finally:
            os.close(fd)
        require(hashlib.sha256(data).hexdigest() == SIGNER_SHA256, "signer_source")
        spec = importlib.util.spec_from_file_location("active_vhd_fixed_signer", source)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        exec(compile(bytes(data), str(source), "exec"), module.__dict__)
        held = module.ordinary(source)
        require(
            held.data == bytes(data) and source_stamp(source.lstat()) == source_stamp(before),
            "signer_source",
        )
        _signer_source, _signer_origin, _signer_stamp = (
            held,
            source,
            source_stamp(before),
        )
        _signer_operations = tuple(
            (name, getattr(module, name))
            for name in (
                "ordinary",
                "current",
                "_ancestors",
                "_current_ancestors",
                "_write",
                "FixtureRefusal",
            )
        )
        _signer = module
    # A newly captured changed provider must never replace the already executed
    # fixed image. Bind its physical source, origin and original operation refs
    # before every cached use, including every existing native-port guard.
    require(
        _signer.__file__ == str(_signer_origin) and _signer.__spec__.origin == str(_signer_origin),
        "signer_origin_changed",
    )
    require(
        all(getattr(_signer, name) is operation for name, operation in _signer_operations),
        "signer_operations_changed",
    )
    require(source_stamp(_signer_origin.lstat()) == _signer_stamp, "signer_source_changed")
    try:
        _signer.current(_signer_source)
    except (_signer.FixtureRefusal, OSError) as error:
        raise FixtureRefusal("signer_source_changed") from error
    return _signer


def capture(path, *, owned=True, mode=None):
    module = signer()
    try:
        return module.ordinary(Path(path), mode, owned=owned)
    except (module.FixtureRefusal, OSError) as error:
        raise FixtureRefusal("input_refused") from error


def check_current(held):
    module = signer()
    try:
        module.current(held)
    except (module.FixtureRefusal, OSError) as error:
        raise FixtureRefusal("input_changed") from error


def time_left(deadline, *, now=None):
    value = deadline - (time.monotonic() if now is None else now)
    require(value > 0, "absolute_deadline")
    return value


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_json_member")
        result[key] = value
    return result


def text(value, limit):
    return (
        type(value) is str
        and 0 < len(value.encode("utf-8")) <= limit
        and not any(ord(c) < 32 for c in value)
    )


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def observation(data, leaf_sha256):
    require(type(data) is bytes and 0 < len(data) <= 65536, "observation_size")
    require(re.fullmatch(r"[0-9a-f]{64}", leaf_sha256) is not None, "public_leaf")
    try:
        packet = json.loads(data.decode("utf-8", "strict"), object_pairs_hook=unique)
    except (UnicodeError, ValueError) as error:
        raise FixtureRefusal("observation_json") from error
    keys = {
        "schema",
        "query_identifier",
        "status",
        "reason",
        "properties",
        "callback_count",
        "elapsed_ms",
        "error_domain",
        "error_code",
        "reference_qualified",
        "approval_qualified",
        "installed_positive_qualified",
        "test_only",
        "signing_identifier",
        "public_leaf_sha256",
    }
    require(type(packet) is dict and set(packet) == keys, "observation_schema")
    require(type(packet["schema"]) is int and packet["schema"] == 1, "observation_schema")
    require(packet["query_identifier"] == IDENTIFIER, "query_identifier")
    require(packet["signing_identifier"] == SIGNING_IDENTIFIER, "signing_identifier")
    require(packet["public_leaf_sha256"] == leaf_sha256, "public_leaf")
    require(packet["test_only"] is True, "test_only")
    for name in (
        "reference_qualified",
        "approval_qualified",
        "installed_positive_qualified",
    ):
        require(packet[name] is False, "authority_promotion")
    pairs = {
        "observed_empty": {"native_properties_empty"},
        "observed_properties": {"native_properties_observed"},
        "query_denied": {"native_query_failed"},
        "query_timeout": {"native_query_timeout"},
        "unsupported": {"native_properties_api_unavailable"},
        "query_refused": {
            "main_thread_required",
            "foreign_request_callback",
            "duplicate_native_callback",
            "observation_stopped",
            "ambiguous_native_properties",
            "native_property_fields_refused",
            "unexpected_native_callback",
        },
    }
    require(
        type(packet["status"]) is str and packet["status"] in pairs,
        "observation_status",
    )
    status = packet["status"]
    require(
        type(packet["reason"]) is str and packet["reason"] in pairs[status],
        "observation_reason",
    )
    require(integer(packet["callback_count"], 0, 2), "observation_callback")
    require(integer(packet["elapsed_ms"], 0, 25000), "observation_elapsed")
    require(
        type(packet["properties"]) is list and len(packet["properties"]) <= 1,
        "observation_properties",
    )
    if status in ("observed_empty", "observed_properties", "query_denied"):
        require(packet["callback_count"] == 1, "observation_callback")
    if status in ("query_timeout", "unsupported"):
        require(packet["callback_count"] == 0, "observation_callback")
    if status == "observed_properties":
        require(len(packet["properties"]) == 1, "observation_properties")
    else:
        require(not packet["properties"], "observation_properties")
    if status == "query_denied":
        require(text(packet["error_domain"], 128), "observation_error")
        require(integer(packet["error_code"], -(2**53 - 1), 2**53 - 1), "observation_error")
    else:
        require(
            packet["error_domain"] is None and packet["error_code"] is None,
            "observation_error",
        )
    for item in packet["properties"]:
        require(
            type(item) is dict
            and set(item)
            == {
                "identifier",
                "version",
                "short_version",
                "url",
                "enabled",
                "awaiting_approval",
                "uninstalling",
            },
            "property_schema",
        )
        require(item["identifier"] == IDENTIFIER, "property_identifier")
        for field in ("version", "short_version"):
            require(text(item[field], 64), "property_version")
        url = item["url"]
        require(
            text(url, 4096) and url.startswith("/") and ".." not in Path(url).parts,
            "property_url",
        )
        for field in ("enabled", "awaiting_approval", "uninstalling"):
            require(type(item[field]) is bool, "property_state")
    return packet


def query_delivery_qualified(packet):
    return packet["status"] in ("observed_empty", "observed_properties")


def run(arguments, deadline, guard):
    guard()
    try:
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=time_left(deadline),
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise FixtureRefusal("native_process") from error
    guard()
    require(result.returncode == 0, "native_process")
    require(len(result.stdout) + len(result.stderr) <= 2 * 1024 * 1024, "native_output")
    return result.stdout, result.stderr


def execute(owner, credentials, public, deadline):
    require(sys.platform == "darwin" and os.geteuid() != 0, "ordinary_darwin_required")
    owner, credentials, public = Path(owner), Path(credentials), Path(public)
    for path in (owner, credentials, public):
        require(path.is_absolute() and path.resolve(strict=True) == path, "fixed_owner_path")
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "owner")
        require(stat.S_IMODE(info.st_mode) == 0o700, "owner_mode")
    require(len({owner, credentials, public}) == 3, "owner_overlap")
    require(
        all(
            a not in b.parents
            for a in (owner, credentials, public)
            for b in (owner, credentials, public)
            if a != b
        ),
        "owner_overlap",
    )
    require(not list(owner.iterdir()), "owner_not_empty")
    owner_before = signer()._ancestors(owner)
    diagnostics = Path(__file__).resolve().parent
    repository = diagnostics.parent.parent
    source_paths = (
        repository
        / "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/InstalledVirtualHIDActiveExtensionProbe.swift",
        diagnostics / "installed_vhd_active_extension_main.swift",
    )
    inputs = [capture(path) for path in source_paths]
    inputs.append(capture(Path(__file__).resolve()))
    inputs.append(capture(diagnostics / "hs274_native_signing_fixture.py"))
    macho_source = capture(repository / "tools/build/remap_runtime_macho.py")
    require(hashlib.sha256(macho_source.data).hexdigest() == MACHO_SHA256, "macho_source")
    spec = importlib.util.spec_from_file_location("active_vhd_fixed_macho", macho_source.path)
    macho = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = macho
    exec(compile(macho_source.data, str(macho_source.path), "exec"), macho.__dict__)
    inputs.append(macho_source)
    leaf = capture(credentials / "public-leaf.der", mode=0o644)
    public_leaf = capture(public / "public-leaf.der", mode=0o644)
    require(leaf.data == public_leaf.data, "public_leaf")
    inputs.extend((leaf, public_leaf))
    identity = hashlib.sha1(leaf.data).hexdigest().upper()
    digest = hashlib.sha256(leaf.data).hexdigest()
    keychain = capture(credentials / "fixture.keychain-db", mode=0o600)
    state = capture(credentials / ".state.json", mode=0o600)
    inputs.append(state)
    root_before = signer()._ancestors(credentials)
    native_tools = [
        capture(Path(path), owned=False) for path in ("/usr/bin/xcrun", "/usr/bin/codesign")
    ]
    inputs.extend(native_tools)
    # Copy the captured exact source bytes exclusively; compilation never reads
    # a later repository replacement. Every staged input is checked at ports.
    staged = []
    for index, held in enumerate(inputs[:2]):
        copy = owner / ("fixed-" + str(index) + ".swift")
        signer()._write(copy, held.data, 0o600)
        staged.append(capture(copy, mode=0o600))
    inputs.extend(staged)

    def guard():
        time_left(deadline)
        signer()._current_ancestors(owner_before)
        signer()._current_ancestors(root_before)
        for held in inputs:
            check_current(held)
        # The actual keychain database may change bytes during native signing;
        # custody remains the original ordinary owner/inode/mode, not a digest.
        fresh = capture(keychain.path, mode=0o600)
        require(fresh.identity[:4] == keychain.identity[:4], "keychain_custody")

    binary = owner / "TEST-ONLY-properties-query"
    sdk_output, _ = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], deadline, guard)
    try:
        sdk_text = sdk_output.decode("utf-8", "strict").strip()
    except UnicodeError as error:
        raise FixtureRefusal("native_sdk") from error
    require(text(sdk_text, 4096) and sdk_text.startswith("/"), "native_sdk")
    sdk = Path(sdk_text).resolve(strict=True)
    header = capture(
        sdk
        / "System/Library/Frameworks/SystemExtensions.framework/Versions/A/Headers/SystemExtensions.h",
        owned=False,
    )
    inputs.append(header)
    require(
        all(
            selector in header.data
            for selector in (
                b"propertiesRequestForExtension:",
                b"foundProperties:",
                b"isEnabled",
                b"isAwaitingUserApproval",
                b"isUninstalling",
            )
        ),
        "native_sdk_properties_api",
    )
    signer()._write(
        owner / "actual-sdk.json",
        (
            json.dumps(
                {
                    "schema": 1,
                    "sdk": str(sdk),
                    "header_sha256": hashlib.sha256(header.data).hexdigest(),
                    "test_only": True,
                    "native_execution_qualified": False,
                },
                sort_keys=True,
            )
            + "\n"
        ).encode(),
        0o600,
    )
    inputs.append(capture(owner / "actual-sdk.json", mode=0o600))
    run(
        [
            "/usr/bin/xcrun",
            "swiftc",
            "-swift-version",
            "5",
            "-warnings-as-errors",
            "-parse-as-library",
            "-sdk",
            str(sdk),
            "-framework",
            "Foundation",
            "-framework",
            "SystemExtensions",
            "-framework",
            "Security",
            str(staged[0].path),
            str(staged[1].path),
            "-o",
            str(binary),
        ],
        deadline,
        guard,
    )
    compiled = capture(binary)
    requirement = (
        'identifier "' + SIGNING_IDENTIFIER + '" and certificate leaf = H"' + identity + '"'
    )
    run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            identity,
            "--keychain",
            str(keychain.path),
            "--identifier",
            SIGNING_IDENTIFIER,
            "--timestamp=none",
            "--requirements",
            "=designated => " + requirement,
            str(binary),
        ],
        deadline,
        guard,
    )
    signed = capture(binary)
    require(signed.identity[2:4] == compiled.identity[2:4], "signed_binary_custody")
    # Native codesign may legitimately replace its exact target. Reuse the
    # existing fixed comparator to prove that only the signing transform changed.
    try:
        architectures = macho.compare_macho(compiled.data, signed.data, deadline)
    except macho.MachORefusal as error:
        raise FixtureRefusal("signing_transform") from error
    require(architectures in (("x86_64",), ("arm64",)), "signing_architecture")
    inputs.append(signed)
    run(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "-R",
            "=" + requirement,
            str(binary),
        ],
        deadline,
        guard,
    )
    require(time_left(deadline) >= 9, "query_observation_budget")
    data, _ = run([str(binary)], deadline, guard)
    packet = observation(data, digest)
    guard()
    return packet


def main(args):
    deadline = time.monotonic() + 25
    try:
        require(len(args) == 3, "arguments")
        module = signer()
        try:
            packet = execute(*args, deadline)
        except module.FixtureRefusal as error:
            raise FixtureRefusal("fixed_signer_refused") from error
        print(json.dumps(packet, sort_keys=True))
        return 0
    except (FixtureRefusal, OSError, ValueError, TypeError):
        # No credential values, raw tool output, private-key paths or arbitrary errors.
        print("TEST-ONLY active extension query fixture refused", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
