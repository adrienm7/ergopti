# tools/build/remap_runtime_preparation_observation.py
"""Read-only retired-output observations; never recreate original custody authority."""

import argparse
import ast
from dataclasses import dataclass
import hashlib
import importlib.util
import math
import os
from pathlib import Path
import plistlib
import stat
import sys
import time

BUILD_SHA256 = "fa6a6915e9152adf3704dde17848d5a2f03866e38c9335b9bcbb09c1c9ae1bef"
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_MEMBERS = 2048
_MAX_ANCESTORS = 64
_CODE_BYTES = 2 * 1024 * 1024
_MACHO_MAGIC = frozenset(
    bytes.fromhex(value)
    for value in (
        "feedface",
        "cefaedfe",
        "feedfacf",
        "cffaedfe",
        "cafebabe",
        "bebafeca",
        "cafebabf",
        "bfbafeca",
    )
)
_NESTED_CODE = (".app", ".framework", ".xpc", ".appex", ".bundle", ".dylib", ".so")
FULL_PASS = "PASS observed unsigned prepared runtime products=3; custody, signing and installation unqualified\n"
COMPILATION_PASS = "PASS observed completed compilation metadata; unsigned snapshot unqualified\n"


class ObservationRefusal(Exception):
    """A fixed refusal describes observation only, never a new native verdict."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require(condition, code):
    if not condition:
        raise ObservationRefusal(code)


def _deadline(deadline):
    _require(math.isfinite(deadline) and time.monotonic() < deadline, "deadline")


def _identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _stable_directory(info):
    return info.st_dev, info.st_ino, info.st_uid, info.st_mode


def _ancestor_cuts(path, deadline, cuts):
    # Directory contents may change independently; retain their incarnation,
    # including every non-enumerated code/product parent, without following links.
    parents = path.parents
    _require(len(parents) <= _MAX_ANCESTORS, "bounds")
    for parent in parents:
        _deadline(deadline)
        info = parent.lstat()
        _require(stat.S_ISDIR(info.st_mode), "unsafe_path")
        cuts.append((parent, _stable_directory(info)))


def _inspect(path, deadline, cuts, *, directory=False, mode=None):
    _deadline(deadline)
    info = path.lstat()
    _require(path.is_absolute() and path.resolve(strict=True) == path, "unsafe_path")
    _require(info.st_uid == os.getuid() and not stat.S_IMODE(info.st_mode) & 0o7022, "unsafe_path")
    _require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), "unsafe_path")
    if not directory:
        _require(info.st_nlink == 1, "unsafe_path")
    if mode is not None:
        _require(stat.S_IMODE(info.st_mode) == mode, "unsafe_path")
    _ancestor_cuts(path, deadline, cuts)
    cuts.append((path, _identity(info)))
    _deadline(deadline)
    return info


def _read(path, deadline, cuts, *, mode=None, maximum=MAX_FILE_BYTES):
    info = _inspect(path, deadline, cuts, mode=mode)
    _require(0 <= info.st_size <= maximum, "bounds")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        _require(_identity(os.fstat(descriptor)) == _identity(info), "identity")
        chunks, remaining = [], info.st_size
        while remaining:
            _deadline(deadline)
            data = os.read(descriptor, min(remaining, 1024 * 1024))
            _require(data and len(data) <= remaining, "identity")
            chunks.append(data)
            remaining -= len(data)
        _require(_identity(os.fstat(descriptor)) == _identity(info), "identity")
        _require(_identity(path.lstat()) == _identity(info), "identity")
        _deadline(deadline)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _recut(cuts, deadline):
    for path, original in cuts:
        _deadline(deadline)
        try:
            current = path.lstat()
        except OSError as error:
            raise ObservationRefusal("identity") from error
        observed = _stable_directory(current) if len(original) == 4 else _identity(current)
        _require(observed == original and path.resolve(strict=True) == path, "identity")


def _builder(repository, deadline, cuts):
    path = repository / "tools/build/remap_runtime_build.py"
    data = _read(path, deadline, cuts, maximum=_CODE_BYTES)
    _require(hashlib.sha256(data).hexdigest() == BUILD_SHA256, "source_identity")
    # Preserve the dependency cuts before the original builder performs imports.
    # Pin values come from its already verified original bytes, not caller metadata.
    syntax = ast.parse(data)
    pins = {}
    for node in syntax.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in {"BASE_SHA256", "PROVIDER_SHA256"}:
                    pins[target.id] = ast.literal_eval(node.value)
    base_path = repository / "tools/diagnostics/hs274_native_build.py"
    provider_path = repository / "tools/build/remap_runtime_patch.py"
    base_data = _read(base_path, deadline, cuts, maximum=_CODE_BYTES)
    provider_data = _read(provider_path, deadline, cuts, maximum=_CODE_BYTES)
    _require(hashlib.sha256(base_data).hexdigest() == pins["BASE_SHA256"], "source_identity")
    _require(
        hashlib.sha256(provider_data).hexdigest() == pins["PROVIDER_SHA256"], "source_identity"
    )

    def retained_load(name, target, supplied):
        # Exactly the two original validator dependency calls are permitted.
        # No file loader, bytecode cache, global hook or caller callback executes.
        _recut(cuts, deadline)
        if name == "four_target_native_phase_owner" and Path(target) == base_path:
            original = base_data
        elif name == "four_target_single_identity_provider" and Path(target) == provider_path:
            original = provider_data
        else:
            raise ObservationRefusal("source_identity")
        _require(type(supplied) is bytes and supplied == original, "source_identity")
        spec = importlib.util.spec_from_loader(name, loader=None)
        dependency = importlib.util.module_from_spec(spec)
        dependency.__file__ = str(target)
        sys.modules[name] = dependency
        exec(compile(original, str(target), "exec"), dependency.__dict__)
        _recut(cuts, deadline)
        return dependency

    loaders = [
        index
        for index, node in enumerate(syntax.body)
        if isinstance(node, ast.FunctionDef) and node.name == "_load"
    ]
    _require(len(loaders) == 1, "source_identity")
    split = loaders[0] + 1
    _recut(cuts, deadline)
    spec = importlib.util.spec_from_loader("retired_preparation_observer_builder", loader=None)
    module = importlib.util.module_from_spec(spec)
    module.__file__ = str(path)
    sys.modules[spec.name] = module
    # All original nodes, including the original loader definition, execute
    # unchanged. Only this private observer namespace routes the two later
    # dependency calls to their already pinned/held bytes before the suffix.
    prefix = ast.Module(body=syntax.body[:split], type_ignores=[])
    suffix = ast.Module(body=syntax.body[split:], type_ignores=[])
    exec(compile(prefix, str(path), "exec"), module.__dict__)
    module.__dict__["_load"] = retained_load
    _recut(cuts, deadline)
    exec(compile(suffix, str(path), "exec"), module.__dict__)
    _recut(cuts, deadline)
    return module


@dataclass(frozen=True)
class _Member:
    directory: bool
    mode: int
    data: bytes | None


def _scan(root, deadline, cuts, *, primary, members, byte_limit, expected=None, private=False):
    """One finite scan; reject an unknown output before enumerating further entries."""
    mode = 0o700 if private else 0o755
    _inspect(root, deadline, cuts, directory=True, mode=mode)
    rows = {".": _Member(True, mode, None)}
    count, total = (0 if private else 1), 0
    pending = [root]
    while pending:
        _deadline(deadline)
        directory = pending.pop()
        with os.scandir(directory) as entries:
            while True:
                _deadline(deadline)
                try:
                    entry = next(entries)
                except StopIteration:
                    break
                _deadline(deadline)
                relative = str((directory / entry.name).relative_to(root))
                if expected is not None:
                    _require(relative in expected, "inventory")
                _require(count < members, "bounds")
                count += 1
                path = directory / entry.name
                info = path.lstat()
                _require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), "unsafe_path")
                if expected is None:
                    _require(
                        not any(
                            part.lower().endswith(_NESTED_CODE) for part in Path(relative).parts
                        ),
                        "inventory",
                    )
                if stat.S_ISDIR(info.st_mode):
                    _inspect(path, deadline, cuts, directory=True, mode=0o755)
                    rows[relative] = _Member(True, 0o755, None)
                    pending.append(path)
                else:
                    wanted_mode = 0o755 if relative in primary else 0o644
                    _require(
                        info.st_size <= MAX_FILE_BYTES and total + info.st_size <= byte_limit,
                        "bounds",
                    )
                    data = _read(
                        path,
                        deadline,
                        cuts,
                        mode=wanted_mode,
                        maximum=min(MAX_FILE_BYTES, byte_limit - total),
                    )
                    _require(relative in primary or data[:4] not in _MACHO_MAGIC, "inventory")
                    total += len(data)
                    rows[relative] = _Member(False, wanted_mode, data)
    _require(count <= members and total <= byte_limit, "bounds")
    _recut(cuts, deadline)
    return rows, count, total


def _observe(repository, owner, *, compilation_only):
    deadline = time.monotonic() + 30
    cuts = []
    _inspect(owner, deadline, cuts, directory=True, mode=0o700)
    build = _builder(repository, deadline, cuts)
    try:
        raw = _read(owner / "owned-native-build-result.json", deadline, cuts, maximum=_CODE_BYTES)
        record = build.parse_json(raw)
        build.validate_current_owned_record(record)
    except build.BASE.NativeBuildError as error:
        raise ObservationRefusal("metadata") from error
    _recut(cuts, deadline)
    if compilation_only:
        return
    stage = owner / "upstream"
    _inspect(stage, deadline, cuts, directory=True, mode=0o700)
    expected = {
        ".": _Member(True, 0o700, None),
        "Runtime": _Member(True, 0o755, None),
        "Runtime/bin": _Member(True, 0o755, None),
    }
    source_files, output_primaries = {}, set()
    members, total = 0, 0
    for label, recipe, product in build.TARGETS:
        if label == "duktape":
            continue
        primary_path = recipe + "/" + product
        if label in {"core", "console"}:
            bundle = (stage / primary_path).parent.parent.parent
            local_primary = str((stage / primary_path).relative_to(bundle))
            rows, count, size = _scan(
                bundle,
                deadline,
                cuts,
                primary={local_primary},
                members=MAX_MEMBERS - members,
                byte_limit=MAX_TOTAL_BYTES - total,
            )
            destination = "Runtime/" + bundle.name
            for relative, row in rows.items():
                key = destination if relative == "." else destination + "/" + relative
                expected[key] = row
                if not row.directory:
                    source_files[str((bundle / relative).relative_to(stage))] = row.data
            for required in ("Contents/Info.plist", local_primary, "Contents/Resources/app.icns"):
                _require(required in rows and rows[required].data, "product_identity")
            try:
                build.validate_plist(rows["Contents/Info.plist"].data, label)
                plist = plistlib.loads(rows["Contents/Info.plist"].data)
                _require(plist.get("CFBundlePackageType") == "APPL", "product_identity")
            except (build.BASE.NativeBuildError, ValueError, TypeError) as error:
                raise ObservationRefusal("product_identity") from error
            output_primaries.add(destination + "/" + local_primary)
        else:
            _require(label == "cli" and members < MAX_MEMBERS, "inventory")
            data = _read(
                stage / primary_path,
                deadline,
                cuts,
                mode=0o755,
                maximum=min(MAX_FILE_BYTES, MAX_TOTAL_BYTES - total),
            )
            count, size = 1, len(data)
            destination = "Runtime/bin/" + Path(primary_path).name
            expected[destination] = _Member(False, 0o755, data)
            source_files[primary_path] = data
            output_primaries.add(destination)
        members += count
        total += size
        _require(members <= MAX_MEMBERS and total <= MAX_TOTAL_BYTES, "bounds")
    _require(len(output_primaries) == 3, "inventory")
    output = owner / ".unsigned-runtime-preparation"
    actual, _, _ = _scan(
        output,
        deadline,
        cuts,
        primary=output_primaries,
        members=MAX_MEMBERS + 2,
        byte_limit=MAX_TOTAL_BYTES,
        expected=expected,
        private=True,
    )
    _require(set(actual) == set(expected), "inventory")
    for relative, wanted in expected.items():
        _require(actual[relative] == wanted, "content")
    for row in record["products"]:
        data = source_files.get(row["path"])
        if data is None:
            _require(row["target"] == "duktape", "inventory")
            data = _read(stage / row["path"], deadline, cuts)
        _require(
            len(data) == row["bytes"] and hashlib.sha256(data).hexdigest() == row["sha256"],
            "product_identity",
        )
    _recut(cuts, deadline)


def observe(repository, owner, *, compilation_only=False):
    """Observe current files only; completion of the original handoff stays separate."""
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        try:
            _observe(Path(repository), Path(owner), compilation_only=compilation_only)
        except OSError as error:
            raise ObservationRefusal("unsafe_path") from error
    finally:
        sys.dont_write_bytecode = previous


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("owner", type=Path)
    parser.add_argument("--compilation-only", action="store_true")
    options = parser.parse_args(arguments)
    try:
        observe(options.repository, options.owner, compilation_only=options.compilation_only)
    except ObservationRefusal as error:
        print("Unsigned preparation observation refused: " + error.code, file=sys.stderr)
        return 2
    print(COMPILATION_PASS if options.compilation_only else FULL_PASS, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
