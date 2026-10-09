# tools/diagnostics/hs_owned_configuration_fixture.py
"""Qualify actual isolated Hammerspoon publication under its existing native owner."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import time
import uuid

import hs_karabiner_config_probe as probe
import hs_delayed_timer_probe as timer
import macos_owned_process as owner
import macos_physical_clock as clock
import macos_tooltip_canvas as facade

MAX_BYTES = 16 * 1024 * 1024
CONTROLLER_SECONDS = 25
SOURCE_EXTRAS = (
    "tools/diagnostics/hs_karabiner_config_native.lua",
    "tools/diagnostics/hs_karabiner_config_probe.py",
    "tools/diagnostics/hs_karabiner_config_contract.json",
    "tools/diagnostics/hs_delayed_timer_probe.py",
    "tools/diagnostics/hs_delayed_timer_contract.json",
    "tools/diagnostics/hs_owned_configuration_fixture.py",
    "tools/diagnostics/macos_owned_process.py",
    "tools/diagnostics/macos_physical_clock.py",
    "tools/diagnostics/macos_tooltip_canvas.py",
)


def require(condition, message):
    """Keep mandatory guards active under optimized Python."""
    if not condition:
        raise ValueError(message)


def read_owned(path, maximum=MAX_BYTES, private=True):
    """Read bounded ordinary owner bytes with held and named identity checks."""
    path = Path(path)
    require(
        path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
        "Redirected owner file parent",
    )
    parent_before = path.parent.stat()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and (0 < before.st_size <= maximum if private else 0 <= before.st_size <= maximum)
            and (not private or stat.S_IMODE(before.st_mode) == 0o600),
            "Not a bounded ordinary owner file",
        )
        chunks, remaining = [], maximum + 1
        while remaining:
            part = os.read(descriptor, min(remaining, 65536))
            if not part:
                break
            chunks.append(part)
            remaining -= len(part)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        named = path.lstat()
        parent_after = path.parent.stat()

        def signature(value):
            return (
                value.st_dev,
                value.st_ino,
                value.st_mode,
                value.st_uid,
                value.st_size,
                value.st_mtime_ns,
            )

        require(
            signature(before) == signature(after) == signature(named)
            and len(data) == before.st_size
            and len(data) <= maximum,
            "Owner file changed during read",
        )
        require(
            (
                parent_before.st_dev,
                parent_before.st_ino,
                parent_before.st_mode,
                parent_before.st_uid,
            )
            == (parent_after.st_dev, parent_after.st_ino, parent_after.st_mode, parent_after.st_uid)
            and path.parent.resolve(strict=True) == path.parent,
            "Owner file parent changed during read",
        )
        return data
    finally:
        os.close(descriptor)


def file_identity(path):
    """Bind actual source bytes and physical inode without following aliases."""
    path = Path(path)
    before = path.lstat()
    raw = read_owned(path, private=False)
    info = path.lstat()
    require(
        (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_uid,
            before.st_size,
            before.st_mtime_ns,
        )
        == (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_size, info.st_mtime_ns),
        "Source identity changed during read",
    )
    return {
        "dev": info.st_dev,
        "ino": info.st_ino,
        "mode": info.st_mode,
        "uid": info.st_uid,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def verify_identity(path, expected):
    """Reject equal-length replacements and new inodes even when bytes look familiar."""
    require(file_identity(path) == expected, "Source identity changed")


def admit(packet, report, nonce, pid, executable, domain):
    """Require actual group retirement and the independent complete native graph validator."""
    require(
        report.get("operation_error") is None
        and report.get("cleanup_errors") == []
        and report.get("application_cleanup") == "confirmed inherited PGID retired",
        "Native operation or retirement refused",
    )
    clock.validate_owner(report, pid)
    return probe.validate_owned_receipt(packet, nonce, pid, executable, domain)


def admit_with_failure_observation(packet, report, nonce, pid, executable, domain):
    """Retain the original refusal while projecting only closed controller facts."""
    try:
        return admit(packet, report, nonce, pid, executable, domain)
    except Exception:
        # A diagnostic sink cannot replace the primary failure or grant authority.
        try:
            operation, cleanup, retirement = "unavailable", "unavailable", "unavailable"
            if type(report) is dict:
                error = dict.get(report, "operation_error")
                if error is None:
                    operation = "none"
                elif type(error) is str:
                    operation = {
                        "Native private publication observation deadline": "observation_deadline",
                        "Native private publication receipt deadline": "receipt_deadline",
                        "Exact native publication child exited before receipt": "child_exited_before_receipt",
                        "Exact native publication child exited during receipt": "child_exited_during_receipt",
                        "Source identity changed": "source_identity_changed",
                        "Native private publication controller deadline": "controller_deadline",
                    }.get(error, "unclassified_refusal")
                errors = dict.get(report, "cleanup_errors")
                if type(errors) is list:
                    cleanup = "refused" if errors else "none"
                acknowledged = dict.get(report, "application_cleanup")
                if type(acknowledged) is str:
                    if acknowledged == "confirmed inherited PGID retired":
                        retirement = "acknowledged"
                    elif acknowledged == "unconfirmed; inputs retained":
                        retirement = "unconfirmed"
            observation = {
                "schema": 1,
                "kind": "owned_configuration_controller_failure_observation",
                "authority": False,
                "native_verdict": "unchanged",
                "operation": operation,
                "cleanup": cleanup,
                "retirement": retirement,
            }
            text = (
                "ERGOPTI_OWNED_CONFIGURATION_FAILURE "
                + json.dumps(observation, sort_keys=True, separators=(",", ":"), allow_nan=False)
                + "\n"
            )
            if len(text) <= 512:
                sys.stderr.write(text)
        except Exception:
            pass
        raise


def admit_files(root, packet, original):
    """Read the actual final full document and the distinct personal sentinel independently."""
    root = Path(root)
    final = read_owned(root / "karabiner/karabiner.json")
    stock = read_owned(root / "stock-personal.json")
    parsed = json.loads(final, object_pairs_hook=probe.unique_object)
    require(
        probe.typed_equal(parsed, packet["variants"][-1]["config"]),
        "Actual final private configuration differs",
    )
    require(stock == original, "Stock private sentinel changed")
    return {
        "final_sha256": hashlib.sha256(final).hexdigest(),
        "stock_sha256": hashlib.sha256(stock).hexdigest(),
    }


def source_inventory(repo):
    """Capture the complete Lua/data closure, including the exact native writer inputs."""
    rows = {}
    for relative in ("static/ergopti_plus/macos", "static/ergopti_plus/_shared", "static/layouts"):
        tree = repo / relative
        require(tree.is_dir() and tree.resolve(strict=True) == tree, "Unsafe source root")
        for file in sorted(tree.rglob("*")):
            if any(part in {".build", "node_modules", "__pycache__"} for part in file.parts):
                continue
            if file.suffix in {".lua", ".json", ".toml", ".keylayout"}:
                rows[str(file.relative_to(repo))] = file_identity(file)
    for relative in SOURCE_EXTRAS:
        rows[relative] = file_identity(repo / relative)
    require(len(rows) >= 100, "Vacuous source inventory")
    return rows


def validate_providers(repo):
    """Bind the actual executing creator and validator closure to the selected source."""
    repo = Path(repo)
    require(
        repo.is_absolute() and repo.resolve(strict=True) == repo, "Redirected provider repository"
    )
    providers = (
        (sys.modules[__name__], "hs_owned_configuration_fixture.py"),
        (probe, "hs_karabiner_config_probe.py"),
        (timer, "hs_delayed_timer_probe.py"),
        (clock, "macos_physical_clock.py"),
        (owner, "macos_owned_process.py"),
        (facade, "macos_tooltip_canvas.py"),
    )
    bindings = {}
    for module, name in providers:
        actual = Path(module.__file__).absolute()
        expected = repo / "tools/diagnostics" / name
        require(
            actual == expected and actual.resolve(strict=True) == expected,
            "Executing provider belongs to another source repository",
        )
        functions = {}
        for name_in_module, value in vars(module).items():
            if getattr(value, "__module__", None) != module.__name__:
                continue
            candidates = ((name_in_module, value),)
            if isinstance(value, type):
                candidates = tuple(
                    (name_in_module + "." + key, member) for key, member in vars(value).items()
                )
            for slot, operation in candidates:
                if isinstance(operation, (staticmethod, classmethod)):
                    operation = operation.__func__
                code = getattr(operation, "__code__", None)
                if code is None:
                    continue
                require(
                    Path(code.co_filename).absolute() == expected,
                    "Executing provider code belongs to another source repository",
                )
                functions[slot] = operation
        require(functions, "Executing provider has no bound Python definitions")
        identity = file_identity(actual)
        identity["module"] = module
        identity["definitions"] = functions
        bindings[str(expected.relative_to(repo))] = identity
    require(
        clock.owner is owner and clock.facade is facade and facade.owner is owner,
        "Executing native creator or facade alias changed",
    )
    require(
        probe.unique_object is timer.unique_object and probe.TIMER_CONTRACT is timer.CONTRACT,
        "Executing native validator provider alias changed",
    )
    for name, loaded in (
        ("hs_karabiner_config_contract.json", probe.CONTRACT),
        ("hs_delayed_timer_contract.json", timer.CONTRACT),
    ):
        path = repo / "tools/diagnostics" / name
        current = json.loads(read_owned(path, private=False), object_pairs_hook=timer.unique_object)
        require(
            probe.typed_equal(current, loaded), "Executing validator contract differs from source"
        )
        bindings[str(path.relative_to(repo))] = file_identity(path)
    return bindings


def native(repo, root):
    """Run an isolated actual signed runtime without any lease or installed activation."""
    require(
        sys.platform == "darwin" and sys.version_info >= (3, 13),
        "Native macOS CPython3.13 required",
    )
    started = time.monotonic()
    deadline = started + CONTROLLER_SECONDS
    root = clock.ordinary_owner_root(root)
    repo = Path(repo)
    provider_bindings = validate_providers(repo)
    inventory = source_inventory(repo)
    output = root / "owned-configuration"
    output.mkdir(mode=0o700)
    copied = output / "source"
    copied_identities = {}
    for relative, identity in inventory.items():
        verify_identity(repo / relative, identity)
        target = copied / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(repo / relative, target)
        copied_identities[relative] = file_identity(target)
        require(copied_identities[relative]["sha256"] == identity["sha256"], "Source copy changed")
    require(validate_providers(repo) == provider_bindings, "Executing provider source changed")
    for relative, identity in inventory.items():
        verify_identity(repo / relative, identity)
        verify_identity(copied / relative, copied_identities[relative])
    executable, provisioning = clock.acquire_runtime(
        repo, output, min(deadline, time.monotonic() + 10)
    )
    runtime_identity = file_identity(executable)
    nonce = uuid.uuid4().hex
    private_root = output / "private-root"
    private_root.mkdir(mode=0o700)
    (private_root / "karabiner").mkdir(mode=0o700)
    original = (json.dumps(probe.INITIAL_CONFIG, indent=2) + "\n").encode()
    descriptor = os.open(
        private_root / "stock-personal.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
    )
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(original)
        stream.flush()
        os.fsync(stream.fileno())
    configuration = {
        "source": str(copied),
        "private_root": str(private_root),
        "nonce": nonce,
        "result": str(output / "native-result.json"),
        "challenge": str(output / "challenge.json"),
    }
    owner.exclusive_receipt(output / "configuration.json", configuration)
    configuration_identity = file_identity(output / "configuration.json")
    config = output / "init.lua"
    config.write_text(
        """local json = require("hs.json")
local location = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local config = assert(json.read(location .. "/configuration.json"))
package.path = config.source .. "/static/ergopti_plus/macos/?.lua;" .. config.source .. "/static/ergopti_plus/macos/?/init.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local noop = function() end
package.loaded["infra.logger"] = { info=noop, warn=noop, error=noop, debug=noop, start=noop, done=noop, success=noop, trace=noop }
package.loaded["infra.config_paths"] = { get_config_dir=function() return config.private_root .. "/" end }
local fixture = assert(dofile(config.source .. "/tools/diagnostics/hs_karabiner_config_native.lua"))
local diagnostic = {}
_G.ergopti_owned_configuration_diagnostic = diagnostic
diagnostic.timer = hs.timer.doEvery(0.01, function()
 local handle = io.open(config.challenge, "rb")
 if not handle then return end
 local raw = assert(handle:read("*a")); assert(handle:close())
 local challenge = assert(json.decode(raw))
 diagnostic.timer:stop(); diagnostic.timer = nil
 assert(challenge.nonce == config.nonce and challenge.pid == hs.processInfo.processID)
 assert(fixture.run_owned(config.result, config.private_root, config.nonce, challenge.uid, challenge.pid) == config.nonce)
end)
""",
        encoding="utf-8",
        newline="\n",
    )
    config_identity = file_identity(config)
    actual_pid = None
    challenge_identity = None

    def unchanged():
        require(time.monotonic() < deadline, "Native private publication controller deadline")
        require(validate_providers(repo) == provider_bindings, "Executing provider source changed")
        verify_identity(output / "configuration.json", configuration_identity)
        verify_identity(config, config_identity)
        verify_identity(executable, runtime_identity)
        for relative, identity in inventory.items():
            verify_identity(repo / relative, identity)
            verify_identity(copied / relative, copied_identities[relative])
        if challenge_identity is not None:
            verify_identity(output / "challenge.json", challenge_identity)

    def operation(group):
        nonlocal actual_pid, challenge_identity
        actual_pid = group.process.pid
        require(type(actual_pid) is int and actual_pid > 0, "Native child PID missing")
        owner.exclusive_receipt(
            output / "challenge.json", {"nonce": nonce, "uid": os.geteuid(), "pid": actual_pid}
        )
        challenge_identity = file_identity(output / "challenge.json")
        probe_deadline = min(deadline, time.monotonic() + 10)
        while time.monotonic() < probe_deadline:
            require(
                group.observe_exit() is None, "Exact native publication child exited before receipt"
            )
            unchanged()
            if (output / "native-result.json").exists():
                raw = read_owned(output / "native-result.json")
                packet = json.loads(raw, object_pairs_hook=probe.unique_object)
                require(
                    group.observe_exit() is None,
                    "Exact native publication child exited during receipt",
                )
                unchanged()
                require(
                    time.monotonic() < probe_deadline, "Native private publication receipt deadline"
                )
                return {"native_result": packet}
            time.sleep(0.01)
        raise ValueError("Native private publication observation deadline")

    unchanged()
    previous_umask = os.umask(0o077)
    try:
        report = facade.owned_observation(
            executable, config, output, operation, owner.NativeProcessGroups()
        )
    finally:
        os.umask(previous_umask)
    unchanged()
    summary = admit_with_failure_observation(
        report.get("native_result"),
        report,
        nonce,
        actual_pid,
        executable,
        "org.hammerspoon.Hammerspoon",
    )
    file_hashes = admit_files(private_root, report["native_result"], original)
    raw = read_owned(output / "native-result.json")
    inventory_bytes = json.dumps(inventory, sort_keys=True).encode()
    result = {
        "status": "ok",
        "qualification": "actual native private whole document publication",
        "summary": summary,
        "native_owner": report["native_owner"],
        "files": file_hashes,
        "record_sha256": hashlib.sha256(raw).hexdigest(),
        "record_bytes": len(raw),
        "record_relative": "owned-configuration/native-result.json",
        "source_count": len(inventory),
        "source_inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "controller_budget_seconds": CONTROLLER_SECONDS,
        "observation_retirement_seconds": time.monotonic() - started,
        "authority": {
            "installation": False,
            "remapping": False,
            "physical_input": "unexecuted",
            "native_metadata": "actual",
            "native_json_files": "actual",
            "logging": "modeled no-op",
        },
    }
    owner.exclusive_receipt(output / "source-identities.json", inventory)
    owner.exclusive_receipt(output / "qualification.json", result)
    unchanged()
    return result


def main():
    """Keep the native mode explicit; unsupported hosts cannot silently pass."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(native(args.repo, args.root), sort_keys=True, allow_nan=False))
    except Exception as error:
        print("Native private publication refused: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
