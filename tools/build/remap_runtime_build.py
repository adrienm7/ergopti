# tools/build/remap_runtime_build.py
"""Compile a fixed unsigned four-target tree with retained pristine source ownership."""

import argparse
import hashlib
from dataclasses import dataclass
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import sys
import time
import uuid

BASE_PATH = Path(__file__).resolve().parents[1] / "diagnostics/hs274_native_build.py"
BASE_SHA256 = "aa54be49feca564a455bc0f1804939a8bf3658ddeb5f56a691a914114c69aee2"
PROVIDER_SHA256 = "6655ddeae27826d7dd9e7e54e907eba82f5477cb0212fb443eb0bafa367f8352"


def _load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


# The reviewed process, TLS, evidence and phase owners remain the sole backend.
if hashlib.sha256(BASE_PATH.read_bytes()).hexdigest() != BASE_SHA256:
    raise RuntimeError("Reviewed native phase controller changed")
BASE = _load("four_target_native_phase_owner", BASE_PATH)
_REQUIRE = BASE.require
_RUN_PHASE = BASE.run_phase
_READ_REGULAR = BASE.read_regular
_WRITE_EXCLUSIVE = BASE.write_exclusive
_OWNER = BASE.validate_owner_root

TARGETS = (
    ("duktape", "vendor/duktape-src", "build/Release/libduktape.a"),
    (
        "core",
        "src/apps/CoreService",
        "build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
    ),
    (
        "console",
        "src/apps/ConsoleUserServer",
        "build/Release/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
    ),
    ("cli", "src/bin/cli", "build/Release/ergoptiplus_remap_cli"),
)
BASELINE_PHASES = (
    "xcode_version",
    "xcodegen_acquisition",
    "xcodegen_version",
    "sdk_path",
    "acquisition",
    "checkout",
    "submodules",
    "identity_upstream",
    "identity_cpm",
    "identity_vhd",
    "source_clean",
    "version",
    "instrumentation",
    "duktape_generate",
    "duktape_build",
    "core_generate",
    "core_build",
    "cli_generate",
    "cli_build",
)
PRODUCT_MAX_BYTES = 128 * 1024 * 1024
# The complete canonical factory already bounds its actual tracked leaves at 8 MiB.
SOURCE_TREE_MAX_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True, slots=True)
class InputFile:
    """Retain exact source bytes and filesystem incarnation, never caller metadata."""

    path: str
    identity: tuple
    data: bytes


@dataclass(frozen=True, slots=True)
class InputSnapshot:
    """Private immutable current input projection; it grants no source-build authority."""

    root: Path
    root_identity: tuple
    files: tuple[InputFile, ...]


def check_deadline(deadline):
    """Check one caller-owned absolute deadline without resetting its budget."""
    _REQUIRE(
        type(deadline) in (int, float)
        and 0 < deadline < 10**20
        and math.isfinite(deadline)
        and time.monotonic() < deadline,
        "phase_deadline",
        "The single calibration deadline expired or is invalid",
    )


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


def _directory_identity(info):
    # Adding an owned staging child legitimately changes directory size/time/nlink.
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode)


def _relative(value):
    _REQUIRE(
        type(value) is str and value and "\0" not in value,
        "unsafe_path",
        "Invalid relative input path",
    )
    path = PurePosixPath(value)
    _REQUIRE(
        not path.is_absolute() and str(path) == value and ".." not in path.parts,
        "unsafe_path",
        "Input path escapes or aliases its owner",
    )
    return value


def _ordinary(path, root, maximum):
    """Read only the retained physical descriptor matching the selected path."""
    path, root = Path(path), Path(root)
    try:
        canonical = path.resolve(strict=True)
        before = path.lstat()
    except OSError as error:
        raise BASE.NativeBuildError("unsafe_path", "Input is unavailable") from error
    _REQUIRE(
        path.is_absolute() and root in path.parents and canonical == path,
        "unsafe_path",
        "Input redirects or escapes the exact source owner",
    )
    _REQUIRE(
        stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.getuid(),
        "unsafe_path",
        "Input is not an ordinary singly linked owned file",
    )
    _REQUIRE(
        type(maximum) is int and 0 < maximum <= PRODUCT_MAX_BYTES,
        "unsafe_path",
        "Input read bound is not a fixed positive integer",
    )
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            _REQUIRE(
                _identity(opened) == _identity(before),
                "source_identity",
                "Actually opened input differs from selected filesystem incarnation",
            )
            _REQUIRE(opened.st_size <= maximum, "unsafe_path", "Input exceeds its fixed read bound")
            data = stream.read(maximum + 1)
            completed = os.fstat(stream.fileno())
            after = path.lstat()
            _REQUIRE(
                len(data) == opened.st_size
                and _identity(opened) == _identity(completed) == _identity(after)
                and path.resolve(strict=True) == path,
                "source_identity",
                "Retained descriptor or selected input changed during read",
            )
    except OSError as error:
        raise BASE.NativeBuildError(
            "unsafe_path", "Retained input descriptor read refused"
        ) from error
    return InputFile(str(path.relative_to(root)), _identity(opened), data)


def snapshot_inputs(root, expected, deadline):
    """Preflight all fixed expected hashes before any detached output is published."""
    check_deadline(deadline)
    root = Path(root)
    _REQUIRE(
        root.is_absolute() and root.resolve(strict=True) == root and root.is_dir(),
        "unsafe_path",
        "Source input root is not canonical",
    )
    root_identity = _directory_identity(root.lstat())
    _REQUIRE(
        type(expected) is dict and 1 <= len(expected) <= 512,
        "source_identity",
        "Input inventory is empty or unbounded",
    )
    rows = tuple(expected.items())
    files = []
    for relative, wanted in rows:
        _relative(relative)
        _REQUIRE(
            type(wanted) is str and re.fullmatch(r"[0-9a-f]{64}", wanted),
            "source_identity",
            "Expected source hash is not closed",
        )
        check_deadline(deadline)
        row = _ordinary(root / relative, root, BASE.MAX_INPUT_BYTES)
        _REQUIRE(
            BASE.digest(row.data) == wanted,
            "source_identity",
            "Fixed source preimage changed",
        )
        check_deadline(deadline)
        files.append(row)
    snapshot = InputSnapshot(root, root_identity, tuple(files))
    current_inputs(snapshot, deadline)
    return snapshot


def current_inputs(snapshot, deadline, *, maximum=BASE.MAX_INPUT_BYTES):
    """Reject replacement or mutation of every retained source incarnation."""
    check_deadline(deadline)
    _REQUIRE(
        type(snapshot) is InputSnapshot,
        "source_identity",
        "Source snapshot is not private typed input",
    )
    _REQUIRE(
        snapshot.root.resolve(strict=True) == snapshot.root
        and _directory_identity(snapshot.root.lstat()) == snapshot.root_identity,
        "source_identity",
        "Source owner changed",
    )
    for previous in snapshot.files:
        check_deadline(deadline)
        current = _ordinary(snapshot.root / previous.path, snapshot.root, maximum)
        _REQUIRE(current == previous, "source_identity", "Retained source changed")
        check_deadline(deadline)


def stage_inputs(snapshot, owner, deadline):
    """Publish a complete detached input tree; it is not a qualified upstream tree."""
    owner = _OWNER(owner)
    owner_identity = _directory_identity(owner.lstat())
    current_inputs(snapshot, deadline)
    destination = owner / "source-inputs"
    _REQUIRE(
        not destination.exists() and not destination.is_symlink(),
        "unsafe_path",
        "Staging destination exists",
    )
    staging = owner / (".input-staging-" + uuid.uuid4().hex)
    staging.mkdir(mode=0o700)
    for row in snapshot.files:
        check_deadline(deadline)
        target = staging / row.path
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _WRITE_EXCLUSIVE(target, row.data)
        check_deadline(deadline)
    current_inputs(snapshot, deadline)
    for row in snapshot.files:
        _REQUIRE(
            _ordinary(staging / row.path, staging, BASE.MAX_INPUT_BYTES).data == row.data,
            "source_identity",
            "Detached staging bytes changed",
        )
        check_deadline(deadline)
    _REQUIRE(
        _directory_identity(_OWNER(owner).lstat()) == owner_identity,
        "owner_identity",
        "Staging owner changed",
    )
    # Reserve the final directory exclusively. Only our exact empty placeholder
    # can be replaced by the completed private staging directory.
    try:
        destination.mkdir(mode=0o700)
    except OSError as error:
        raise BASE.NativeBuildError(
            "unsafe_path", "Exclusive staging publication refused"
        ) from error
    reserved = _directory_identity(destination.lstat())
    current_inputs(snapshot, deadline)
    _REQUIRE(
        _directory_identity(destination.lstat()) == reserved and not any(destination.iterdir()),
        "owner_identity",
        "Reserved publication directory changed",
    )
    os.rename(staging, destination)
    check_deadline(deadline)
    current_inputs(snapshot, deadline)
    return destination


def build_command(executable, project):
    """Return the fixed unsigned Release invocation used by all four real targets."""
    return [
        executable,
        "-configuration",
        "Release",
        "-alltargets",
        "SYMROOT=" + str(Path(project) / "build"),
        "ARCHS=arm64 x86_64",
        "ONLY_ACTIVE_ARCH=NO",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
    ]


def architectures(output):
    """Require exactly the two actual lipo slices, independently for every image."""
    _REQUIRE(
        type(output) is bytes and len(output) <= 1024,
        "product_architecture",
        "Architecture output is not bounded bytes",
    )
    try:
        values = output.decode("ascii").split()
    except UnicodeError as error:
        raise BASE.NativeBuildError(
            "product_architecture", "Architecture output is not ASCII"
        ) from error
    _REQUIRE(
        len(values) == 2 and set(values) == {"arm64", "x86_64"},
        "product_architecture",
        "Actual native product lacks exactly two unique architectures",
    )
    return ("arm64", "x86_64")


def product_snapshot(path, root):
    """Capture an actual ordinary retained image; dummy fixture bytes prove no native build."""
    snapshot = _ordinary(path, root, PRODUCT_MAX_BYTES)
    _REQUIRE(snapshot.data, "product_identity", "Native product is empty")
    return snapshot


def current_product(snapshot, root):
    _REQUIRE(
        product_snapshot(Path(root) / snapshot.path, root) == snapshot,
        "source_identity",
        "Native product changed across a foreign phase",
    )


def validate_products(products):
    """Check closed receipt metadata without using it as a substitute for real images."""
    _REQUIRE(
        type(products) is list and len(products) == len(TARGETS),
        "product_identity",
        "Four actual products are required",
    )
    result = []
    for row, (target, recipe, relative) in zip(products, TARGETS):
        _REQUIRE(
            type(row) is dict
            and set(row) == {"target", "path", "sha256", "bytes", "architectures"}
            and row["target"] == target
            and row["path"] == recipe + "/" + relative
            and type(row["sha256"]) is str
            and re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
            and type(row["bytes"]) is int
            and 0 < row["bytes"] <= PRODUCT_MAX_BYTES
            and type(row["architectures"]) is list
            and row["architectures"] == ["arm64", "x86_64"],
            "product_identity",
            "Product metadata inventory is not closed or current",
        )
        result.append({**row, "architectures": list(row["architectures"])})
    return result


def _identifiers(repository=None, deadline=None):
    if repository is not None:
        factory = _source_factory()
        dependencies = _factory_operation(
            factory, factory.capture_dependencies, Path(repository), deadline
        )
        rows = [row for row in dependencies if row.path == "tools/build/remap_runtime_patch.py"]
        _REQUIRE(len(rows) == 1, "source_identity", "Actual fixed identity provider is absent")
        provider = factory.load_fixed("four_target_actual_owned_identity", rows[0])
        result = dict(provider.OWNED_PRODUCT_IDENTIFIERS)
        _REQUIRE(
            _factory_operation(factory, factory.capture_dependencies, Path(repository), deadline)
            == dependencies,
            "source_identity",
            "Actual fixed identity provider changed across loading",
        )
        check_deadline(deadline)
        return result

    path = Path(__file__).with_name("remap_runtime_patch.py")
    source = _READ_REGULAR(path)
    _REQUIRE(
        BASE.digest(source) == PROVIDER_SHA256,
        "source_identity",
        "Reviewed single identity provider changed",
    )
    provider = _load("four_target_single_identity_provider", path)
    _REQUIRE(
        _READ_REGULAR(path) == source,
        "source_identity",
        "Identity provider changed during load",
    )
    return dict(provider.OWNED_PRODUCT_IDENTIFIERS)


def validate_plist(data, target, *, repository=None, deadline=None):
    """Validate emitted app identities against the reviewed single identity provider."""
    _REQUIRE(
        target in {"core", "console"},
        "product_identity",
        "CLI has source-only identity, not an app plist",
    )
    try:
        value = plistlib.loads(data)
    except (ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise BASE.NativeBuildError(
            "product_identity", "Actual emitted app plist is malformed"
        ) from error
    product = next(row[2] for row in TARGETS if row[0] == target).split("/")[-1]
    _REQUIRE(
        type(value) is dict
        and value.get("CFBundleIdentifier") == _identifiers(repository, deadline)[target]
        and value.get("CFBundleExecutable") == product,
        "product_identity",
        "Actual emitted app identity differs from reviewed source",
    )


def _current_build_inputs(source_snapshot, deadline, staged_image):
    current_inputs(
        source_snapshot,
        deadline,
        maximum=SOURCE_TREE_MAX_BYTES if staged_image is not None else BASE.MAX_INPUT_BYTES,
    )
    if staged_image is not None:
        factory = _source_factory()
        _factory_operation(factory, factory.current_staged_source, staged_image, deadline)


def _compile_product_images(source_snapshot, owner, tools, deadline, *, staged_image=None):
    """Compile the fixed four native images from a retained complete owned stage.

    The fixed entrypoint first obtains the released parent/auth projection.
    Source composition and native phase ownership remain separate.
    Only actual native phases may produce its four product observations.
    """
    _REQUIRE(sys.platform == "darwin", "tool_unavailable", "Actual Darwin SDK is mandatory")
    owner = _OWNER(owner)
    _current_build_inputs(source_snapshot, deadline, staged_image)
    _REQUIRE(
        type(tools) is dict and set(tools) == {"xcodegen", "xcodebuild", "xcrun"},
        "tool_unavailable",
        "Exact actual native tool inventory is required",
    )
    tool_inputs = []
    for value in tools.values():
        path = Path(value)
        _REQUIRE(
            path.is_absolute() and path.resolve(strict=True) == path,
            "tool_unavailable",
            "Native tool redirects or is relative",
        )
        # Tool images are foreign system resources. They are observed, never
        # installed/replaced or treated as a signed producer authority here.
        tool_inputs.append((path, _identity(path.stat())))
    products, phases, retained = [], [], []
    for label, recipe, relative in TARGETS:
        _current_build_inputs(source_snapshot, deadline, staged_image)
        project = source_snapshot.root / recipe
        output = project / relative
        _REQUIRE(
            not output.exists() and not output.is_symlink(),
            "product_identity",
            "A native product predates this actual build",
        )
        for suffix, command in (
            ("generate", [tools["xcodegen"], "generate"]),
            ("build", build_command(tools["xcodebuild"], project)),
        ):
            _current_build_inputs(source_snapshot, deadline, staged_image)
            phases.append(_RUN_PHASE(label + "_" + suffix, command, project, owner, deadline))
            check_deadline(deadline)
            _current_build_inputs(source_snapshot, deadline, staged_image)
            if staged_image is not None and suffix == "generate":
                # Retain actual project inputs before the native compiler reads
                # them. Names come from the already verified canonical recipe.
                recipe_input = _ordinary(
                    project / "project.yml", source_snapshot.root, BASE.MAX_INPUT_BYTES
                )
                name_rows = [
                    line[6:].strip()
                    for line in recipe_input.data.decode("utf-8").splitlines()
                    if line.startswith("name: ")
                ]
                _REQUIRE(
                    len(name_rows) == 1 and re.fullmatch(r"[A-Za-z0-9_-]+", name_rows[0]),
                    "source_identity",
                    "The actual verified project name is not closed",
                )
                project_file = project / (name_rows[0] + ".xcodeproj") / "project.pbxproj"
                native_recipe = product_snapshot(project_file, source_snapshot.root)
                retained.append((native_recipe, source_snapshot.root))
            for previous, root in retained:
                current_product(previous, root)
        image = product_snapshot(output, source_snapshot.root)
        retained.append((image, source_snapshot.root))
        _current_build_inputs(source_snapshot, deadline, staged_image)
        phases.append(
            _RUN_PHASE(
                label + "_architectures",
                [tools["xcrun"], "lipo", "-archs", str(output)],
                project,
                owner,
                deadline,
            )
        )
        check_deadline(deadline)
        current_product(image, source_snapshot.root)
        lipo_output = _ordinary(owner / (label + "_architectures.stdout"), owner, 1024)
        retained.append((lipo_output, owner))
        slices = architectures(lipo_output.data)
        current_product(image, source_snapshot.root)
        _current_build_inputs(source_snapshot, deadline, staged_image)
        if label in {"core", "console"}:
            plist = product_snapshot(output.parents[1] / "Info.plist", source_snapshot.root)
            retained.append((plist, source_snapshot.root))
            validate_plist(
                plist.data,
                label,
                repository=staged_image.projection.repository if staged_image is not None else None,
                deadline=deadline,
            )
            current_product(plist, source_snapshot.root)
            current_product(image, source_snapshot.root)
            _current_build_inputs(source_snapshot, deadline, staged_image)
        products.append(
            {
                "target": label,
                "path": image.path,
                "sha256": BASE.digest(image.data),
                "bytes": len(image.data),
                "architectures": list(slices),
            }
        )
        for path, identity in tool_inputs:
            _REQUIRE(
                path.resolve(strict=True) == path and _identity(path.stat()) == identity,
                "source_identity",
                "Native tool image changed across actual compilation",
            )
        check_deadline(deadline)
    # Later compiler phases may change an earlier library, app or lipo capture.
    # Every retained observation must still describe the actual final inputs.
    for previous, root in retained:
        check_deadline(deadline)
        current_product(previous, root)
        check_deadline(deadline)
    _current_build_inputs(source_snapshot, deadline, staged_image)
    observed = validate_products(products)
    if staged_image is not None:
        return observed, tuple(phases), tuple(retained)
    return observed, tuple(phases)


def parse_json(data):
    """Reject duplicate and escaped duplicate keys before metadata validation."""

    def unique(pairs):
        result = {}
        for key, value in pairs:
            _REQUIRE(key not in result, "duplicate_key", "Receipt repeats a JSON key")
            result[key] = value
        return result

    try:
        return json.loads(
            data,
            object_pairs_hook=unique,
            parse_constant=lambda _: _REQUIRE(
                False, "source_identity", "Receipt contains a nonfinite constant"
            ),
        )
    except (ValueError, UnicodeError) as error:
        raise BASE.NativeBuildError("source_identity", "Receipt is not strict JSON") from error


def owned_output(status, stdout, stderr):
    """Check a real retired invocation before any persisted receipt is inspected."""
    _REQUIRE(
        type(status) is int
        and status == 0
        and type(stdout) is str
        and type(stderr) is str
        and stderr == ""
        and stdout
        == "PASS unsigned actual owned four-target compilation; signing and activation unqualified\n",
        "owned_receipt_refused",
        "The actual owned invocation did not finish cleanly",
    )


def validate_owned_record(record):
    """Check closed metadata only; actual phase/source/product ownership is separate."""
    fields = {
        "schema",
        "status",
        "qualification",
        "budget_seconds",
        "pins",
        "products",
        "phases",
        "source_inventory_entries",
        "owned_replacements",
        "staged_files",
        "staged_links",
        "generated_inputs",
        "native_capture_executed",
        "installation_executed",
        "signing_executed",
        "auth_executed",
    }

    def require(value):
        _REQUIRE(
            value,
            "owned_receipt_refused",
            "Owned compilation metadata is not the closed actual contract",
        )

    require(type(record) is dict and set(record) == fields)
    require(
        type(record["schema"]) is int
        and record["schema"] == 1
        and record["status"] == "passed"
        and record["qualification"] == "unsigned_actual_owned_four_target_compilation"
        and type(record["budget_seconds"]) is int
        and record["budget_seconds"] == 300
    )
    require(record["pins"] == {"upstream": BASE.UPSTREAM, "cpm": BASE.CPM, "vhd": BASE.VIRTUAL_HID})
    for key in (
        "native_capture_executed",
        "installation_executed",
        "signing_executed",
        "auth_executed",
    ):
        require(record[key] is False)
    for key, count in (
        ("source_inventory_entries", 4505),
        ("owned_replacements", 57),
        ("staged_files", 4526),
        ("staged_links", 4),
    ):
        require(type(record[key]) is int and record[key] == count)
    try:
        validate_products(record["products"])
    except BASE.NativeBuildError as error:
        raise BASE.NativeBuildError(
            "owned_receipt_refused", "Owned product metadata differs"
        ) from error
    phases = record["phases"]
    prefix = ("xcode_version", "xcodegen_acquisition", "xcodegen_version", "sdk_path")
    acquisition = (
        "acquisition",
        "checkout",
        "submodules",
        "identity_upstream",
        "identity_cpm",
        "identity_vhd",
        "source_clean",
    )
    suffix = ("version",) + tuple(
        label + "_" + stage
        for label, _, _ in TARGETS
        for stage in ("generate", "build", "architectures")
    )
    require(
        type(phases) is list
        and len(phases) in (17, 24)
        and all(type(row) is dict for row in phases)
    )
    require(
        tuple(row.get("phase") for row in phases)
        in (prefix + acquisition + suffix, prefix + suffix)
    )
    for row in phases:
        special = row["phase"] == "xcodegen_acquisition"
        require(
            set(row)
            == (
                {
                    "schema",
                    "phase",
                    "status",
                    "elapsed_seconds",
                    "operation",
                    "child_process_executed",
                }
                if special
                else {"schema", "phase", "status", "elapsed_seconds", "exit_status"}
            )
        )
        elapsed = row["elapsed_seconds"]
        require(
            type(row["schema"]) is int
            and row["schema"] == 1
            and row["status"] == "passed"
            and type(elapsed) in (int, float)
            and 0 <= elapsed <= 300
            and math.isfinite(elapsed)
        )
        if special:
            require(
                row["operation"] == "verified-HTTPS-download-and-ordinary-extraction"
                and row["child_process_executed"] is False
            )
        else:
            require(type(row["exit_status"]) is int and row["exit_status"] == 0)
    generated = record["generated_inputs"]
    require(type(generated) is list and len(generated) == 12)
    names = []
    for row in generated:
        require(type(row) is dict and set(row) == {"path", "sha256", "bytes"})
        name = row["path"]
        require(
            type(name) is str
            and name
            and len(name) <= 512
            and "\0" not in name
            and not PurePosixPath(name).is_absolute()
            and str(PurePosixPath(name)) == name
            and ".." not in PurePosixPath(name).parts
            and type(row["bytes"]) is int
            and 0 < row["bytes"] <= BASE.MAX_INPUT_BYTES
            and type(row["sha256"]) is str
            and re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
        )
        names.append(name)
    require(len(set(names)) == 12 and names == sorted(names))


def baseline_output(status, stdout, stderr):
    """Check evidence only after Swift's real Guardian has completed and retired."""
    _REQUIRE(
        type(status) is int
        and status == 0
        and type(stdout) is str
        and type(stderr) is str
        and stderr == "",
        "baseline_refused",
        "Baseline did not finish cleanly",
    )
    lines = stdout.split("\n")
    _REQUIRE(
        len(lines) == 22
        and lines[0]
        == "PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted"
        and lines[20] == "CANDIDATE none; actual diagnostic inputs compiled"
        and lines[21] == "",
        "baseline_refused",
        "Baseline output differs from the actual unchanged calibration",
    )
    for name, line in zip(BASELINE_PHASES, lines[1:20]):
        prefix = "PHASE " + name + " seconds="
        _REQUIRE(
            line.startswith(prefix),
            "baseline_refused",
            "Baseline phases are not exactly ordered",
        )
        try:
            seconds = float(line[len(prefix) :])
        except ValueError as error:
            raise BASE.NativeBuildError(
                "baseline_refused", "Baseline elapsed value is malformed"
            ) from error
        _REQUIRE(
            math.isfinite(seconds) and 0 <= seconds <= 300,
            "baseline_refused",
            "Baseline elapsed value is outside its actual fixed deadline",
        )


def observe_products(source, owner, *, repository=None):
    """Observe four current actual images using the existing finite phase owner.

    This is static compilation evidence only, never final source/auth admission.
    Swift calls it under the original SDK guardian after genuine compilation.
    """
    _REQUIRE(sys.platform == "darwin", "tool_unavailable", "Actual Darwin lipo is mandatory")
    source, owner = Path(source), _OWNER(owner)
    _REQUIRE(
        source.is_absolute() and source.resolve(strict=True) == source and source.is_dir(),
        "source_identity",
        "Product source root is not current and canonical",
    )
    source_identity = _directory_identity(source.lstat())
    xcrun = shutil.which("xcrun")
    _REQUIRE(xcrun is not None, "tool_unavailable", "Actual xcrun is unavailable")
    xcrun = Path(xcrun)
    _REQUIRE(
        xcrun.is_absolute() and xcrun.resolve(strict=True) == xcrun,
        "tool_unavailable",
        "Actual xcrun is redirected",
    )
    tool_identity = _identity(xcrun.stat())
    deadline = time.monotonic() + 30
    images, result = [], []
    for label, recipe, relative in TARGETS:
        check_deadline(deadline)
        image = product_snapshot(source / recipe / relative, source)
        images.append(image)
        _RUN_PHASE(
            label + "_observed_architectures",
            [str(xcrun), "lipo", "-archs", str(source / image.path)],
            source,
            owner,
            deadline,
        )
        check_deadline(deadline)
        current_product(image, source)
        slices = architectures(
            _READ_REGULAR(owner / (label + "_observed_architectures.stdout"), 1024)
        )
        current_product(image, source)
        if label in {"core", "console"}:
            plist = product_snapshot((source / image.path).parents[1] / "Info.plist", source)
            images.append(plist)
            validate_plist(plist.data, label, repository=repository, deadline=deadline)
            current_product(plist, source)
        result.append(
            {
                "target": label,
                "path": image.path,
                "sha256": BASE.digest(image.data),
                "bytes": len(image.data),
                "architectures": list(slices),
            }
        )
        for previous in images:
            current_product(previous, source)
        _REQUIRE(
            source.resolve(strict=True) == source
            and _directory_identity(source.lstat()) == source_identity
            and xcrun.resolve(strict=True) == xcrun
            and _identity(xcrun.stat()) == tool_identity,
            "source_identity",
            "Actual source or tool changed across product observation",
        )
        check_deadline(deadline)
    return validate_products(result)


SOURCE_FACTORY_SHA256 = "227cd2a9ace8007b5d46bef1d9617a30d23700320c67f914cc028d51adc124f8"
_SOURCE_FACTORY = None


def _source_factory():
    """Load only the fixed released compositor, never a caller-selected recipe."""
    global _SOURCE_FACTORY
    path = Path(__file__).with_name("remap_runtime_source.py")
    _REQUIRE(
        type(SOURCE_FACTORY_SHA256) is str and re.fullmatch(r"[0-9a-f]{64}", SOURCE_FACTORY_SHA256),
        "dependency_unreleased",
        "The actual complete source factory release is unavailable",
    )
    retained = _ordinary(path, path.parent, BASE.MAX_INPUT_BYTES)
    _REQUIRE(
        BASE.digest(retained.data) == SOURCE_FACTORY_SHA256,
        "source_identity",
        "The fixed current source factory changed",
    )
    if _SOURCE_FACTORY is None:
        # Execute the captured verified bytes; avoid a second loader path read.
        specification = importlib.util.spec_from_loader(
            "four_target_owned_source_factory", loader=None
        )
        module = importlib.util.module_from_spec(specification)
        module.__file__ = str(path)
        sys.modules[specification.name] = module
        exec(compile(retained.data, str(path), "exec"), module.__dict__)
        _SOURCE_FACTORY = module
    _REQUIRE(
        _ordinary(path, path.parent, BASE.MAX_INPUT_BYTES) == retained,
        "source_identity",
        "The actual source factory changed during loading",
    )
    return _SOURCE_FACTORY


def _factory_operation(factory, operation, *arguments):
    """Preserve the fixed factory's typed refusal without an unbounded traceback."""
    try:
        return operation(*arguments)
    except factory.SourceRefusal as error:
        raise BASE.NativeBuildError(
            error.code, "The fixed actual source operation refused"
        ) from error


def materialize_owned_source(projection, owner, deadline):
    """Publish the genuine full tracked tree and exact canonical owned overlays.

    The pristine input remains separate and current. The returned factory image
    describes the full physical staging, before the actual version generator.
    Failed private staging is retained for diagnosis and grants no authority.
    """
    factory = _source_factory()
    _REQUIRE(
        type(projection) is factory.PreparedSource,
        "source_identity",
        "The source projection is not the actual fixed factory result",
    )
    check_deadline(deadline)
    owner = _OWNER(owner)
    owner_identity = _directory_identity(owner.lstat())
    _REQUIRE(
        owner != projection.upstream and projection.upstream not in owner.parents,
        "unsafe_path",
        "Detached owned staging overlaps the retained pristine source",
    )
    destination = owner / "upstream"
    _REQUIRE(
        not destination.exists() and not destination.is_symlink(),
        "unsafe_path",
        "The owned source destination already exists",
    )
    _factory_operation(factory, factory.revalidate_owned_source, projection, deadline)
    staging = owner / (".owned-source-staging-" + uuid.uuid4().hex)
    staging.mkdir(mode=0o700)
    for relative, mode, _, wanted in projection.inventory:
        check_deadline(deadline)
        _relative(relative)
        if mode == "160000":
            continue  # Genuine recursive submodule leaves follow in the inventory.
        target = staging / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        source = projection.upstream / relative
        if mode == "120000":
            before = source.lstat()
            _REQUIRE(
                stat.S_ISLNK(before.st_mode) and before.st_uid == os.getuid(),
                "source_identity",
                "A tracked symbolic link changed its physical type or owner",
            )
            link = os.readlink(source)
            _REQUIRE(
                BASE.digest(os.fsencode(link)) == wanted
                and _identity(source.lstat()) == _identity(before),
                "source_identity",
                "The genuine tracked link changed during materialization",
            )
            # Retain genuine relative links, including the upstream broken-link
            # test fixture. The factory's closed inventory owns their targets.
            os.symlink(link, target)
        else:
            _REQUIRE(mode in {"100644", "100755"}, "source_identity", "Unknown tracked mode")
            retained = _ordinary(source, projection.upstream, SOURCE_TREE_MAX_BYTES)
            _REQUIRE(
                BASE.digest(retained.data) == wanted,
                "source_identity",
                "An actual tracked input differs from the factory inventory",
            )
            _WRITE_EXCLUSIVE(target, retained.data)
            target.chmod(0o755 if mode == "100755" else 0o644)
        check_deadline(deadline)
    for relative, data in projection.replacements:
        check_deadline(deadline)
        _relative(relative)
        target = staging / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            retained = _ordinary(target, staging, SOURCE_TREE_MAX_BYTES)
            target.unlink()
            _WRITE_EXCLUSIVE(target, data)
            target.chmod(stat.S_IMODE(retained.identity[3]))
        else:
            _WRITE_EXCLUSIVE(target, data)
            target.chmod(0o644)
        check_deadline(deadline)
    _factory_operation(factory, factory.validate_staged_source, projection, staging, deadline)
    _factory_operation(factory, factory.revalidate_owned_source, projection, deadline)
    _REQUIRE(
        _directory_identity(_OWNER(owner).lstat()) == owner_identity,
        "owner_identity",
        "The owned staging root changed before publication",
    )
    try:
        destination.mkdir(mode=0o700)
    except OSError as error:
        raise BASE.NativeBuildError("unsafe_path", "Exclusive owned publication refused") from error
    reserved = _directory_identity(destination.lstat())
    _REQUIRE(
        _directory_identity(destination.lstat()) == reserved and not any(destination.iterdir()),
        "owner_identity",
        "The reserved owned source destination changed",
    )
    os.rename(staging, destination)
    check_deadline(deadline)
    image = _factory_operation(
        factory, factory.validate_staged_source, projection, destination, deadline
    )
    _factory_operation(factory, factory.current_staged_source, image, deadline)
    return image


def dependency_ready(repository, owner, seconds):
    """Validate fixed code dependencies without source or compilation authority."""
    _REQUIRE(
        type(seconds) is int and seconds == 300,
        "invalid_budget",
        "Owned calibration requires 300 seconds",
    )
    _OWNER(owner)
    deadline = time.monotonic() + seconds
    factory = _source_factory()
    _factory_operation(factory, factory.capture_dependencies, Path(repository), deadline)
    check_deadline(deadline)
    return factory


def _acquire_pristine(owner, tools, deadline, phases):
    """Use the existing phase owner for a genuinely fresh fixed pinned checkout."""
    checkout = owner / "pristine"
    _REQUIRE(
        not checkout.exists() and not checkout.is_symlink(),
        "unsafe_path",
        "Pristine acquisition already exists",
    )
    commands = (
        (
            "acquisition",
            [
                tools["git"],
                "-c",
                "http.sslVerify=true",
                "-c",
                "transfer.fsckObjects=true",
                "clone",
                "--no-checkout",
                "https://github.com/pqrs-org/Karabiner-Elements.git",
                str(checkout),
            ],
        ),
        ("checkout", [tools["git"], "-C", str(checkout), "checkout", "--detach", BASE.UPSTREAM]),
        (
            "submodules",
            [tools["git"], "-C", str(checkout), "submodule", "update", "--init", "--recursive"],
        ),
    )
    for name, command in commands:
        phases.append(_RUN_PHASE(name, command, owner, owner, deadline))
        check_deadline(deadline)
    observed = {}
    for name, relative in (
        ("upstream", ""),
        ("cpm", "vendor/cpm-cmake-package-lock"),
        ("vhd", "vendor/Karabiner-DriverKit-VirtualHIDDevice"),
    ):
        phase = "identity_" + name
        phases.append(
            _RUN_PHASE(
                phase,
                [tools["git"], "-C", str(checkout / relative), "rev-parse", "HEAD"],
                owner,
                owner,
                deadline,
            )
        )
        observed[name] = (
            _ordinary(owner / (phase + ".stdout"), owner, 1024).data.decode("ascii").strip()
        )
        check_deadline(deadline)
    BASE.verify_pins(observed)
    phases.append(
        _RUN_PHASE(
            "source_clean",
            [tools["git"], "-C", str(checkout), "diff", "--exit-code"],
            owner,
            owner,
            deadline,
        )
    )
    return checkout


def capture_generated_inputs(image, deadline):
    """Retain genuine version outputs at their actual physical descriptor cuts."""
    factory = _source_factory()
    _factory_operation(factory, factory.current_staged_source, image, deadline)
    generated = []
    for relative, wanted in _factory_operation(factory, factory.expected_generated_outputs, image):
        check_deadline(deadline)
        row = _ordinary(image.root / relative, image.root, BASE.MAX_INPUT_BYTES)
        _REQUIRE(
            row.data == wanted,
            "source_identity",
            "An actual version output differs from its retained template",
        )
        generated.append(row)
    _REQUIRE(len(generated) == 12, "source_identity", "Actual version outputs are incomplete")
    _factory_operation(factory, factory.current_staged_source, image, deadline)
    original = tuple(InputFile(row.path, row.identity, row.data) for row in image.files)
    snapshot = InputSnapshot(image.root, image.root_identity, original + tuple(generated))
    _current_build_inputs(snapshot, deadline, image)
    return snapshot


def compile_owned(repository, owner, seconds, upstream=None):
    """Compile the complete canonical owned tree using the genuine Darwin SDK.

    A separate pristine acquisition is retained through all phase boundaries.
    The factory's complete tracked image is published before actual version
    generation. No signing, installation, authentication or capture executes.
    """
    _REQUIRE(
        type(seconds) is int and seconds == 300,
        "invalid_budget",
        "Owned calibration requires 300 seconds",
    )
    owner = _OWNER(owner)
    _REQUIRE(
        not any(owner.iterdir()), "unsafe_path", "Actual owned build requires a fresh empty owner"
    )
    deadline = time.monotonic() + seconds
    factory = _source_factory()
    _factory_operation(factory, factory.capture_dependencies, Path(repository), deadline)
    _REQUIRE(
        sys.platform == "darwin",
        "tool_unavailable",
        "Actual owned compilation requires the Darwin SDK",
    )
    tools = {}
    for name in ("git", "xcodebuild", "xcrun"):
        path = shutil.which(name)
        _REQUIRE(path is not None, "tool_unavailable", "An actual fixed native tool is unavailable")
        tools[name] = str(Path(path).resolve(strict=True))
    phases = [
        _RUN_PHASE("xcode_version", [tools["xcodebuild"], "-version"], owner, owner, deadline)
    ]
    binary, acquisition = BASE.acquire_xcodegen(owner, deadline)
    phases.append(acquisition)
    tools["xcodegen"] = str(binary.resolve(strict=True))
    phases.append(
        _RUN_PHASE("xcodegen_version", [tools["xcodegen"], "--version"], owner, owner, deadline)
    )
    phases.append(
        _RUN_PHASE("sdk_path", [tools["xcrun"], "--show-sdk-path"], owner, owner, deadline)
    )
    pristine = (
        Path(upstream)
        if upstream is not None
        else _acquire_pristine(owner, tools, deadline, phases)
    )
    projection = _factory_operation(
        factory, factory.prepare_owned_source, Path(repository), pristine, deadline
    )
    image = materialize_owned_source(projection, owner, deadline)
    _factory_operation(factory, factory.current_staged_source, image, deadline)
    phases.append(
        _RUN_PHASE(
            "version",
            [sys.executable, str(image.root / "scripts/update_version.py")],
            image.root,
            owner,
            deadline,
        )
    )
    inputs = capture_generated_inputs(image, deadline)
    products, native_phases, retained_products = _compile_product_images(
        inputs,
        owner,
        {name: tools[name] for name in ("xcodegen", "xcodebuild", "xcrun")},
        deadline,
        staged_image=image,
    )
    phases.extend(native_phases)
    _current_build_inputs(inputs, deadline, image)
    check_deadline(deadline)
    record = {
        "schema": 1,
        "status": "passed",
        "qualification": "unsigned_actual_owned_four_target_compilation",
        "budget_seconds": seconds,
        "pins": dict(projection.pins),
        "products": products,
        "phases": phases,
        "source_inventory_entries": len(projection.inventory),
        "owned_replacements": len(projection.replacements),
        "staged_files": len(image.files),
        "staged_links": len(image.links),
        "generated_inputs": [
            {"path": row.path, "sha256": BASE.digest(row.data), "bytes": len(row.data)}
            for row in inputs.files[len(image.files) :]
        ],
        "native_capture_executed": False,
        "installation_executed": False,
        "signing_executed": False,
        "auth_executed": False,
    }
    validate_owned_record(record)
    pending_receipt = owner / ".owned-native-build-result.pending.json"
    BASE.write_json(pending_receipt, record)
    _current_build_inputs(inputs, deadline, image)
    for previous, root in retained_products:
        current_product(previous, root)
        check_deadline(deadline)
    receipt = owner / "owned-native-build-result.json"
    _WRITE_EXCLUSIVE(receipt, _ordinary(pending_receipt, owner, BASE.MAX_INPUT_BYTES).data)
    for previous, root in retained_products:
        current_product(previous, root)
    _current_build_inputs(inputs, deadline, image)
    check_deadline(deadline)
    return record


def preflight(repository, owner, seconds):
    """Retain the original dependency-only preparation without complete source inputs."""
    _REQUIRE(
        type(seconds) is int and seconds == BASE.CALIBRATION_SECONDS,
        "invalid_budget",
        "Owned calibration must retain exactly 300 seconds",
    )
    owner = _OWNER(owner)
    deadline = time.monotonic() + seconds
    repository = Path(repository)
    # These are current executable dependencies, never a loader for an arbitrary
    # script supplied by a caller. Complete source acquisition and staging belong to the explicit compile entry.
    expected = {
        "tools/diagnostics/hs274_native_build.py": BASE_SHA256,
        "tools/build/remap_runtime_patch.py": PROVIDER_SHA256,
    }
    try:
        snapshot_inputs(repository, expected, deadline)
    except BASE.NativeBuildError as error:
        raise BASE.NativeBuildError(
            "source_identity", "Fixed current build dependency is missing or changed"
        ) from error
    _REQUIRE(
        False,
        "dependency_unreleased",
        "Complete pristine source inputs are absent from dependency-only preparation",
    )


# These companions are independent source controls, not factory generators.
# Pin the currently published bytes, including the frozen formatted corpora.
SOURCE_CONTROL_INPUTS = (
    (
        "tools/build/remap_runtime_auth_transport_test.py",
        "958eec8bc543db610956601a39f9074cd9926d18da1339e3c1de069f605d6481",
    ),
    (
        "tools/build/remap_runtime_auth_test.py",
        "0093ec937550298fed3aaee2f4faf5b11c5fbb898926bb60f8b2ded0407fa42a",
    ),
    (
        "tools/build/remap_runtime_auth_hs274_test.py",
        "02ecfacf75406969eba420f20f8344c228ebf1e79c017d63c71b4260e068a082",
    ),
    (
        "tools/build/fixtures/remap_runtime_auth_policy26.json",
        "ef999db672cf22e5dff512c418826bfc3a13ea2ac0581b0a070803a2de1a003a",
    ),
    (
        "tools/build/fixtures/remap_runtime_auth_hs27422.json",
        "3581dbbe0af267a44d6544a06e0ec25279c0ae9d68660537517cfb91b994b2dc",
    ),
)
SOURCE_CONTROL_GROUPS = (("auth_transport21", 21), ("auth_policy26", 26), ("auth_hs27422", 22))
SOURCE_CONTROL_PHASES = (
    "acquisition",
    "checkout",
    "submodules",
    "identity_upstream",
    "identity_cpm",
    "identity_vhd",
    "source_clean",
) + tuple(name for name, _ in SOURCE_CONTROL_GROUPS)
SOURCE_CONTROL_PASS = (
    "PASS owned AUTH source controls=21 policy=26 hs274=22; native authentication unqualified\n"
)


def _source_controls_require(condition):
    _REQUIRE(
        condition,
        "source_controls_refused",
        "Source controls did not finish with their exact closed evidence",
    )


def auth_source_output(status, stdout, stderr):
    """A real retired child precedes its exact no-skip unittest summary."""
    _source_controls_require(
        type(status) is int and status == 0 and stdout == "" and type(stderr) is str
    )
    summary = re.fullmatch(r"\.{21}\n-{70}\nRan 21 tests in ([0-9]+(?:\.[0-9]+)?)s\n\nOK\n", stderr)
    _source_controls_require(summary is not None)
    # Bound the decimal text before converting it; huge integers cannot overflow.
    elapsed = summary.group(1)
    _source_controls_require(len(elapsed) <= 32)
    value = float(elapsed)
    _source_controls_require(0 <= value <= 300 and math.isfinite(value))


def policy_source_output(status, stdout, stderr, record, count, oracle_hash, policy_hash):
    """Keep the independent O0/O2 literal corpora separate from native identity."""
    _source_controls_require(
        type(status) is int
        and status == 0
        and type(stdout) is str
        and type(stderr) is str
        and stderr == ""
    )
    _source_controls_require(type(count) is int and count in (26, 22))
    _source_controls_require(
        type(record) is dict
        and set(record)
        == {
            "qualification",
            "native_executed",
            "oracle_sha256",
            "policy_sha256",
            "adapter",
            "receipts",
        }
    )
    _source_controls_require(parse_json(stdout) == record)
    _source_controls_require(
        record["qualification"] == "PORTABLE_LITERAL_POLICY_ONLY"
        and type(record["native_executed"]) is int
        and record["native_executed"] == 0
        and record["oracle_sha256"] == oracle_hash
        and record["policy_sha256"] == policy_hash
        and record["adapter"] == {"ordinary_supported_request": "frontmost_application_changed"}
    )
    rows = record["receipts"]
    _source_controls_require(type(rows) is list and len(rows) == 2)
    for row, mode in zip(rows, ("unoptimized", "optimized"), strict=True):
        _source_controls_require(
            type(row) is dict
            and set(row)
            == {
                "mode",
                "compile_exit",
                "run_exit",
                "literal_policy_cases",
                "native_executed",
            }
        )
        _source_controls_require(row["mode"] == mode)
        for key, wanted in (
            ("compile_exit", 0),
            ("run_exit", 0),
            ("literal_policy_cases", count),
            ("native_executed", 0),
        ):
            _source_controls_require(type(row[key]) is int and row[key] == wanted)


def source_controls_output(status, stdout, stderr):
    """Persisted evidence cannot substitute for the actual guardian return."""
    _source_controls_require(
        type(status) is int and status == 0 and stdout == SOURCE_CONTROL_PASS and stderr == ""
    )


def validate_source_controls_record(record):
    """Portable metadata only; the caller must first admit real process closure."""
    _source_controls_require(
        type(record) is dict
        and set(record)
        == {
            "schema",
            "status",
            "qualification",
            "budget_seconds",
            "pins",
            "source_inventory_entries",
            "companions",
            "phases",
            "controls",
            "native_compilation_executed",
            "native_capture_executed",
            "installation_executed",
            "signing_executed",
            "auth_executed",
        }
    )
    for key, expected in (
        ("schema", 1),
        ("budget_seconds", 300),
        ("source_inventory_entries", 4505),
    ):
        _source_controls_require(type(record[key]) is int and record[key] == expected)
    _source_controls_require(
        record["status"] == "passed"
        and record["qualification"] == "portable_owned_auth_source_controls_on_genuine_pristine"
    )
    BASE.verify_pins(record["pins"])
    _source_controls_require(
        record["companions"]
        == [{"path": path, "sha256": digest} for path, digest in SOURCE_CONTROL_INPUTS]
    )
    phases = record["phases"]
    _source_controls_require(type(phases) is list and len(phases) == len(SOURCE_CONTROL_PHASES))
    for row, phase in zip(phases, SOURCE_CONTROL_PHASES, strict=True):
        _source_controls_require(
            type(row) is dict
            and set(row) == {"schema", "phase", "status", "exit_status", "elapsed_seconds"}
        )
        _source_controls_require(
            type(row["schema"]) is int
            and row["schema"] == 1
            and row["phase"] == phase
            and row["status"] == "passed"
            and type(row["exit_status"]) is int
            and row["exit_status"] == 0
        )
        elapsed = row["elapsed_seconds"]
        _source_controls_require(
            type(elapsed) in (int, float) and 0 <= elapsed <= 300 and math.isfinite(elapsed)
        )
    controls = record["controls"]
    _source_controls_require(type(controls) is list and len(controls) == 3)
    for row, (name, count) in zip(controls, SOURCE_CONTROL_GROUPS, strict=True):
        _source_controls_require(
            type(row) is dict
            and set(row) == {"name", "tests", "failures", "errors", "skipped", "native_executed"}
            and row["name"] == name
        )
        for key, expected in (
            ("tests", count),
            ("failures", 0),
            ("errors", 0),
            ("skipped", 0),
            ("native_executed", 0),
        ):
            _source_controls_require(type(row[key]) is int and row[key] == expected)
    for key in (
        "native_compilation_executed",
        "native_capture_executed",
        "installation_executed",
        "signing_executed",
        "auth_executed",
    ):
        _source_controls_require(record[key] is False)


def source_controls(repository, owner, seconds):
    """Run actual source controls on one freshly acquired retained pristine tree.

    The existing native phase owner and outer Guardian retain all process debt.
    AUTH C++ uses modeled identity/UID/watch/MAIN leaves, never native authority.
    This mode is separate from either native compilation and never stages outputs.
    """
    _REQUIRE(
        type(seconds) is int and seconds == 300,
        "invalid_budget",
        "Source controls require exactly 300 seconds",
    )
    owner = _OWNER(owner)
    _REQUIRE(not any(owner.iterdir()), "unsafe_path", "Source controls require a fresh empty owner")
    owner_identity = _directory_identity(owner.lstat())
    deadline = time.monotonic() + seconds
    repository = Path(repository)
    factory = _source_factory()
    _factory_operation(factory, factory.capture_dependencies, repository, deadline)
    companions = snapshot_inputs(repository, dict(SOURCE_CONTROL_INPUTS), deadline)
    _REQUIRE(
        sys.platform == "darwin",
        "tool_unavailable",
        "The actual source-control phase owner requires Darwin",
    )
    executable = shutil.which("git")
    _REQUIRE(
        executable is not None, "tool_unavailable", "The genuine Git source tool is unavailable"
    )
    phases = []
    pristine = _acquire_pristine(
        owner, {"git": str(Path(executable).resolve(strict=True))}, deadline, phases
    )
    projection = _factory_operation(
        factory, factory.prepare_owned_source, repository, pristine, deadline
    )

    def current():
        check_deadline(deadline)
        _REQUIRE(
            _OWNER(owner) == owner and _directory_identity(owner.lstat()) == owner_identity,
            "source_identity",
            "The source-control owner changed",
        )
        _factory_operation(factory, factory.revalidate_owned_source, projection, deadline)
        current_inputs(companions, deadline)
        check_deadline(deadline)

    current()
    policy = repository / "tools/build/remap_runtime_auth_policy.hpp"
    policy_hash = dict(factory.DEPENDENCIES)["tools/build/remap_runtime_auth_policy.hpp"]
    commands = (
        [
            sys.executable,
            str(repository / SOURCE_CONTROL_INPUTS[0][0]),
            "--source-root",
            str(pristine),
        ],
        [
            sys.executable,
            str(repository / SOURCE_CONTROL_INPUTS[1][0]),
            str(policy),
            str(repository / SOURCE_CONTROL_INPUTS[3][0]),
            str(owner / "policy26"),
        ],
        [
            sys.executable,
            str(repository / SOURCE_CONTROL_INPUTS[2][0]),
            str(policy),
            str(repository / SOURCE_CONTROL_INPUTS[4][0]),
            str(owner / "hs27422"),
        ],
    )
    for index, ((name, count), command) in enumerate(
        zip(SOURCE_CONTROL_GROUPS, commands, strict=True)
    ):
        current()
        # run_phase returns only after the genuine foreground child has exited.
        phases.append(_RUN_PHASE(name, command, owner, owner, deadline))
        current()
        stdout = _ordinary(owner / (name + ".stdout"), owner, BASE.MAX_INPUT_BYTES).data.decode(
            "utf-8"
        )
        stderr = _ordinary(owner / (name + ".stderr"), owner, BASE.MAX_INPUT_BYTES).data.decode(
            "utf-8"
        )
        if index == 0:
            auth_source_output(phases[-1]["exit_status"], stdout, stderr)
        else:
            result_dir = owner / ("policy26" if index == 1 else "hs27422")
            row = _ordinary(result_dir / "RESULT.json", owner, BASE.MAX_INPUT_BYTES)
            policy_source_output(
                phases[-1]["exit_status"],
                stdout,
                stderr,
                parse_json(row.data),
                count,
                SOURCE_CONTROL_INPUTS[index + 2][1],
                policy_hash,
            )
        current()
    record = {
        "schema": 1,
        "status": "passed",
        "qualification": "portable_owned_auth_source_controls_on_genuine_pristine",
        "budget_seconds": seconds,
        "pins": dict(projection.pins),
        "source_inventory_entries": len(projection.inventory),
        "companions": [
            {"path": row.path, "sha256": BASE.digest(row.data)} for row in companions.files
        ],
        "phases": phases,
        "controls": [
            {
                "name": name,
                "tests": count,
                "failures": 0,
                "errors": 0,
                "skipped": 0,
                "native_executed": 0,
            }
            for name, count in SOURCE_CONTROL_GROUPS
        ],
        "native_compilation_executed": False,
        "native_capture_executed": False,
        "installation_executed": False,
        "signing_executed": False,
        "auth_executed": False,
    }
    validate_source_controls_record(record)
    current()
    pending = owner / ".owned-source-controls.pending.json"
    BASE.write_json(pending, record)
    current()
    _WRITE_EXCLUSIVE(
        owner / "owned-source-controls-result.json",
        _ordinary(pending, owner, BASE.MAX_INPUT_BYTES).data,
    )
    current()
    return record


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("owner", type=Path)
    parser.add_argument("--budget", type=int, default=300)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--ready", action="store_true")
    parser.add_argument("--compile-owned", action="store_true")
    parser.add_argument("--source-controls", action="store_true")
    parser.add_argument("--upstream", type=Path)
    parser.add_argument("--observe-products", type=Path)
    options = parser.parse_args(arguments)
    try:
        selected = (
            int(options.preflight)
            + int(options.ready)
            + int(options.compile_owned)
            + int(options.source_controls)
            + int(options.observe_products is not None)
        )
        _REQUIRE(
            selected <= 1 and (options.upstream is None or options.compile_owned),
            "invalid_budget",
            "Conflicting owned preparation modes",
        )
        if options.source_controls:
            source_controls(options.repository, options.owner, options.budget)
            print(SOURCE_CONTROL_PASS, end="")
            return 0
        if options.ready:
            dependency_ready(options.repository, options.owner, options.budget)
            print("PASS fixed owned build dependencies; source and compilation unexecuted")
            return 0
        if options.compile_owned:
            compile_owned(options.repository, options.owner, options.budget, options.upstream)
            print(
                "PASS unsigned actual owned four-target compilation; signing and activation unqualified"
            )
            return 0
        if options.observe_products is not None:
            _REQUIRE(not options.preflight, "invalid_budget", "Conflicting preparation modes")
            observe_products(options.observe_products, options.owner, repository=options.repository)
            print(
                "PASS observed native products=4 architectures=2; signing and activation unqualified"
            )
            return 0
        preflight(options.repository, options.owner, options.budget)
        # The dependency-only preparation grants no native child/source authority.
        return 0
    except BASE.NativeBuildError as error:
        try:
            BASE.write_json(
                _OWNER(options.owner) / "owned-build-refusal.json",
                {
                    "schema": 1,
                    "status": "refused",
                    "code": error.code,
                    "native_capture_executed": False,
                    "installation_executed": False,
                    "signing_executed": False,
                    "auth_executed": False,
                },
            )
        except (BASE.NativeBuildError, OSError):
            pass  # Refusal never replaces an earlier receipt or clears retained debt.
        print("Owned runtime compilation refused: " + error.code, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
