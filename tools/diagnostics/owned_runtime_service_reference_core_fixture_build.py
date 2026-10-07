# tools/diagnostics/owned_runtime_service_reference_core_fixture_build.py
"""Build only the genuine Core constructor fixture and its Duktape prerequisite.

This separate producer never emits a complete four-product build record. Its
in-process continuation and real descriptors do not travel through JSON. The
invoking Guardian must own the separate 300-second calibration and acknowledge
physical child-group retirement before deleting its namespace or credentials.
"""

import hashlib
import importlib.util
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import threading
import time
import uuid

SOURCE_PINS = (
    (
        "tools/build/remap_runtime_build.py",
        "f1cd9c3be1c3793a4fb829955406807dcb16df84542aa377af5ce167eb5faf7d",
    ),
    (
        "tools/build/remap_runtime_source.py",
        "854dc3ef556e2540d4a64e0d935610a2a2fe8c947e3f7fe315c1641ceaaedd7d",
    ),
    (
        "tools/build/remap_runtime_patch.py",
        "c29ceb96e73655cadea7763805b9468c32744033c2f177bae492e4ce9fe4100a",
    ),
    (
        "tools/diagnostics/hs274_native_build.py",
        "aa54be49feca564a455bc0f1804939a8bf3658ddeb5f56a691a914114c69aee2",
    ),
)
MAX_BYTES = 128 * 1024 * 1024
CORE_RECIPE = "src/apps/CoreService"
CORE_PRODUCT = "build/Release/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core"
CORE_IDENTIFIER = "com.ergoptiplus.remap.core"


class Refusal(RuntimeError):
    """A refusal retains the real custody owner, including unknown close debt."""

    def __init__(self, code, owner=None):
        self.code, self.owner = code, owner
        super().__init__(code)


def _require(value, code, owner=None):
    if not value:
        raise Refusal(code, owner)


def _budget(value):
    _require(type(value) is int and value == 300, "invalid_budget")
    return value


def _tick(deadline):
    _require(
        type(deadline) in (int, float) and math.isfinite(deadline) and time.monotonic() < deadline,
        "deadline",
    )


def _darwin():
    _require(sys.platform == "darwin", "native_unavailable")


def _identity(info, *, directory=False):
    base = (info.st_dev, info.st_ino, info.st_uid, info.st_mode)
    # Directory additions are legitimate compilation output; reading file bytes
    # can change atime. Neither is a source incarnation mutation by itself.
    return (
        base
        if directory
        else base + (info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    )


class _HeldFile:
    """Retain one actual descriptor; unknown close return is never retried."""

    @classmethod
    def _opened(cls, path, descriptor, info):
        result = cls()
        result.path, result.descriptor = path, descriptor
        result.stamp, result.data = _identity(info), None
        result.closed = result.failed = False
        result._lock = threading.Lock()
        return result

    @classmethod
    def capture(cls, path, maximum):
        path = Path(path)
        _require(type(maximum) is int and 0 < maximum <= MAX_BYTES, "file_identity")
        _require(path.is_absolute() and path.resolve(strict=True) == path, "file_identity")
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        except OSError as error:
            raise Refusal("file_identity") from error
        result = cls._opened(path, descriptor, os.fstat(descriptor))
        try:
            info = os.fstat(descriptor)
            _require(
                stat.S_ISREG(info.st_mode)
                and info.st_uid == os.getuid()
                and info.st_nlink == 1
                and 0 < info.st_size <= maximum,
                "file_identity",
                result,
            )
            _require(_identity(path.lstat()) == result.stamp, "file_identity", result)
            result.data = result._read(info.st_size)
            result.current()
            return result
        except BaseException as error:
            try:
                result.close()
            except Refusal as debt:
                raise debt from error
            if isinstance(error, Refusal):
                raise
            raise Refusal("file_identity", result) from error

    def _read(self, size):
        chunks, offset = [], 0
        while offset <= size:
            part = os.pread(self.descriptor, min(65536, size + 1 - offset), offset)
            if not part:
                break
            chunks.append(part)
            offset += len(part)
        return b"".join(chunks)

    def _current(self):
        _require(not self.closed and not self.failed, "retired", self)
        try:
            _require(
                self.path.resolve(strict=True) == self.path
                and _identity(self.path.lstat()) == self.stamp
                and _identity(os.fstat(self.descriptor)) == self.stamp,
                "file_changed",
                self,
            )
            _require(self._read(len(self.data)) == self.data, "file_changed", self)
            _require(
                _identity(os.fstat(self.descriptor)) == self.stamp
                and _identity(self.path.lstat()) == self.stamp
                and self.path.resolve(strict=True) == self.path,
                "file_changed",
                self,
            )
        except OSError as error:
            raise Refusal("file_changed", self) from error

    def current(self):
        _require(self._lock.acquire(blocking=False), "owner_busy", self)
        try:
            self._current()
        finally:
            self._lock.release()

    def close(self):
        _require(self._lock.acquire(blocking=False), "owner_busy", self)
        try:
            _require(not self.failed, "close_unknown", self)
            _require(not self.closed, "retired", self)
            descriptor, self.descriptor = self.descriptor, None
            try:
                os.close(descriptor)
            except OSError as error:
                self.failed = True
                raise Refusal("close_unknown", self) from error
            self.closed = True
        finally:
            self._lock.release()


class _HeldOwner(_HeldFile):
    """Retain the private build root without deleting any owned or foreign name."""

    @classmethod
    def capture(cls, path):
        path = Path(path)
        _require(path.is_absolute() and path.resolve(strict=True) == path, "owner_identity")
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY | os.O_CLOEXEC)
        except OSError as error:
            raise Refusal("owner_identity") from error
        result = cls._opened(path, descriptor, os.fstat(descriptor))
        result.stamp = _identity(os.fstat(descriptor), directory=True)
        try:
            result.current()
            return result
        except BaseException as error:
            try:
                result.close()
            except Refusal as debt:
                raise debt from error
            raise

    def _current(self):
        _require(not self.closed and not self.failed, "retired", self)
        try:
            info = os.fstat(self.descriptor)
            _require(
                stat.S_ISDIR(info.st_mode)
                and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o700,
                "owner_identity" if self.data is None else "owner_changed",
                self,
            )
            _require(
                self.path.resolve(strict=True) == self.path
                and _identity(self.path.lstat(), directory=True) == self.stamp
                and _identity(info, directory=True) == self.stamp,
                "owner_changed",
                self,
            )
            self.data = b"private directory observation"
        except OSError as error:
            raise Refusal("owner_changed", self) from error


def _release_command(executable, project):
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


def _macho_slices(data):
    """Require real bounded fat tables and both actual thin64 executable headers."""
    _require(type(data) is bytes and 48 <= len(data) <= MAX_BYTES, "macho_identity")
    magic, count = struct.unpack_from(">II", data)
    _require(magic == 0xCAFEBABE and count == 2, "macho_identity")
    rows, spans = {}, []
    for position in (8, 28):
        cpu, subtype, offset, size, alignment = struct.unpack_from(">IIIII", data, position)
        _require(
            cpu in (16777228, 16777223)
            and cpu not in rows
            and size >= 32
            and offset >= 48
            and offset + size <= len(data)
            and alignment <= 31
            and offset % (1 << alignment) == 0,
            "macho_identity",
        )
        thin = struct.unpack_from("<IIIIIIII", data, offset)
        _require(
            thin[0] == 0xFEEDFACF and thin[1] == cpu and thin[2] == subtype and thin[3] == 2,
            "macho_identity",
        )
        spans.append((offset, offset + size))
        rows[cpu] = True
    spans.sort()
    _require(spans[0][1] <= spans[1][0], "macho_identity")
    return ("arm64", "x86_64")


class _FixedInputs:
    def __init__(self, repository):
        self.repository = Path(repository)
        self.holds, self.module = [], None
        self.refusal_debt = []
        try:
            for path, digest in SOURCE_PINS:
                held = _HeldFile.capture(self.repository / path, 8 * 1024 * 1024)
                self.holds.append(held)
                _require(hashlib.sha256(held.data).hexdigest() == digest, "source_identity", self)
            self.current()
            name = "owned_core_fixture_builder_" + uuid.uuid4().hex
            spec = importlib.util.spec_from_loader(name, loader=None)
            module = importlib.util.module_from_spec(spec)
            module.__file__ = str(self.holds[0].path)
            sys.modules[name] = module
            exec(compile(self.holds[0].data, module.__file__, "exec"), module.__dict__)
            self.module = module
            self.current()
            _require(
                module.SOURCE_FACTORY_SHA256 == SOURCE_PINS[1][1]
                and module.PROVIDER_SHA256 == SOURCE_PINS[2][1]
                and module.BASE_SHA256 == SOURCE_PINS[3][1],
                "source_identity",
                self,
            )
        except BaseException as error:
            if isinstance(error, Refusal):
                if error.owner is not None and error.owner is not self:
                    self.refusal_debt.append(error.owner)
                error.owner = self
                raise
            raise Refusal("source_identity", self) from error

    def current(self):
        for held in self.holds:
            held.current()

    def close_retained(self):
        acknowledged = True
        for held in reversed(self.holds + self.refusal_debt):
            if not held.closed:
                try:
                    held.close()
                except Refusal:
                    acknowledged = False
        return acknowledged


class CoreFixtureBuild:
    """An actual same-process build continuation; no install or signing authority."""

    def __init__(self, owner):
        self.owner = _HeldOwner.capture(owner)
        self.fixed = self.image = self.inputs = None
        self.core_image = self.core_info = None
        self.current_program_source = None
        self.products, self.tools = [], []
        self.refusal_debt = []
        self.phases, self.ready, self.failed = [], False, False
        self._lock = threading.Lock()

    def _current(self, deadline):
        _tick(deadline)
        if self.current_program_source is not None:
            self.current_program_source.current()
        self.owner.current()
        if self.fixed is not None:
            self.fixed.current()
            builder = self.fixed.module
            if self.image is not None:
                factory = builder._source_factory()
                builder._factory_operation(
                    factory, factory.current_staged_source, self.image, deadline
                )
            if self.inputs is not None:
                builder._current_build_inputs(self.inputs, deadline, self.image)
        for path, stamp in self.tools:
            _require(
                path.resolve(strict=True) == path and _identity(path.stat()) == stamp,
                "tool_changed",
                self,
            )
        for held in self.products:
            held.current()
        _tick(deadline)

    def _completed(self):
        return (
            self.ready
            and not self.failed
            and self.fixed is not None
            and self.image is not None
            and self.inputs is not None
            and type(self.core_image) is _HeldFile
            and type(self.core_info) is _HeldFile
            and self.core_image in self.products
            and self.core_info in self.products
            and not self.core_image.closed
            and not self.core_info.closed
            and self.core_image.path == self.image.root / CORE_RECIPE / CORE_PRODUCT
            and self.core_info.path == self.core_image.path.parents[1] / "Info.plist"
        )

    def current(self, deadline):
        _require(self._lock.acquire(blocking=False), "owner_busy", self)
        try:
            _require(self._completed(), "fixture_lifecycle", self)
            self._current(deadline)
        finally:
            self._lock.release()

    def close_retained(self):
        """Acknowledge descriptor releases only; namespace/group retirement is separate."""
        _require(self._lock.acquire(blocking=False), "owner_busy", self)
        try:
            complete = True
            for held in reversed(self.products):
                if not held.closed:
                    try:
                        held.close()
                    except Refusal:
                        complete = False
            if self.fixed is not None and not self.fixed.close_retained():
                complete = False
            for debt in reversed(self.refusal_debt):
                if type(debt) is _FixedInputs:
                    if not debt.close_retained():
                        complete = False
                elif isinstance(debt, _HeldFile) and not debt.closed:
                    try:
                        debt.close()
                    except Refusal:
                        complete = False
            if not self.owner.closed:
                try:
                    self.owner.close()
                except Refusal:
                    complete = False
            self.ready = False
            self.failed = not complete
            return complete
        finally:
            self._lock.release()

    def _run(self, name, arguments, cwd, deadline):
        self._current(deadline)
        builder = self.fixed.module
        self.phases.append(
            builder._observed_run_phase(name, arguments, cwd, self.owner.path, deadline)
        )
        self._current(deadline)

    def observation(self):
        """Report limitations; this dictionary cannot reconstruct custody or provenance."""
        return {
            "qualification": "unsigned_core_constructor_fixture_only",
            "ready": self._completed(),
            "full_four_target_qualified": False,
            "signing_qualified": False,
            "executing_main_qualified": False,
            "root_placement_qualified": False,
            "child_group_retirement_qualified": False,
            "installation_executed": False,
            "capture_executed": False,
        }


def produce(repository, pristine, owner, seconds=300, *, current_program_source=None):
    """Build from genuinely prepared pinned source under a separate owned calibration.

    No checkout is acquired. Refusal retains the actual build owner for the
    Guardian's retirement path; neither exception nor observation grants access.
    """
    _budget(seconds)
    deadline = time.monotonic() + seconds
    result = CoreFixtureBuild(owner)
    result._lock.acquire()
    try:
        _require(not any(result.owner.path.iterdir()), "owner_not_empty", result)
        if current_program_source is not None:
            _require(
                type(current_program_source) is _HeldFile
                and current_program_source.path == Path(__file__)
                and not current_program_source.closed
                and not current_program_source.failed,
                "program_source_identity",
                result,
            )
            current_program_source.current()
            result.current_program_source = current_program_source
            result.products.append(current_program_source)
        result.fixed = _FixedInputs(repository)
        builder = result.fixed.module
        factory = builder._source_factory()
        projection = builder._factory_operation(
            factory, factory.prepare_owned_source, Path(repository), Path(pristine), deadline
        )
        result._current(deadline)
        _darwin()
        tools = {}
        for name in ("xcodebuild", "xcrun"):
            # Fixed Apple tool shims, never a PATH-selected executable.
            path = Path("/usr/bin") / name
            _require(path.resolve(strict=True) == path, "native_tool_missing", result)
            _require(path.is_file(), "native_tool_missing", result)
            tools[name] = str(path)
            result.tools.append((path, _identity(path.stat())))
        result._run(
            "core_fixture_xcode_version",
            [tools["xcodebuild"], "-version"],
            result.owner.path,
            deadline,
        )
        result._current(deadline)
        binary, acquisition = builder.BASE.acquire_xcodegen(result.owner.path, deadline)
        result.phases.append(acquisition)
        result._current(deadline)
        path = binary.resolve(strict=True)
        tools["xcodegen"] = str(path)
        generator = _HeldFile.capture(path, 16 * 1024 * 1024)
        result.products.append(generator)
        _require(
            hashlib.sha256(generator.data).hexdigest() == builder.BASE.XCODEGEN_BINARY_SHA256,
            "native_tool_missing",
            result,
        )
        result.tools.append((path, _identity(path.stat())))
        result._run(
            "core_fixture_xcodegen_version",
            [tools["xcodegen"], "--version"],
            result.owner.path,
            deadline,
        )
        result._run(
            "core_fixture_sdk_path",
            [tools["xcrun"], "--show-sdk-path"],
            result.owner.path,
            deadline,
        )
        builder._factory_operation(factory, factory.revalidate_owned_source, projection, deadline)
        result.image = builder.materialize_owned_source(projection, result.owner.path, deadline)
        result._run(
            "core_fixture_version",
            [sys.executable, str(result.image.root / "scripts/update_version.py")],
            result.image.root,
            deadline,
        )
        result.inputs = builder.capture_generated_inputs(result.image, deadline)
        for label, recipe, relative in (
            ("duktape", "vendor/duktape-src", "build/Release/libduktape.a"),
            ("core", CORE_RECIPE, CORE_PRODUCT),
        ):
            project = result.image.root / recipe
            output = project / relative
            _require(not output.exists() and not output.is_symlink(), "predating_product", result)
            result._run(
                "core_fixture_" + label + "_generate",
                [tools["xcodegen"], "generate"],
                project,
                deadline,
            )
            recipe_input = builder._ordinary(
                project / "project.yml", result.image.root, builder.BASE.MAX_INPUT_BYTES
            )
            names = [
                line[6:].strip()
                for line in recipe_input.data.decode("utf-8").splitlines()
                if line.startswith("name: ")
            ]
            _require(
                len(names) == 1 and re.fullmatch(r"[A-Za-z0-9_-]+", names[0]),
                "generated_recipe",
                result,
            )
            result.products.append(
                _HeldFile.capture(
                    project / (names[0] + ".xcodeproj") / "project.pbxproj", MAX_BYTES
                )
            )
            result._run(
                "core_fixture_" + label + "_build",
                _release_command(tools["xcodebuild"], project),
                project,
                deadline,
            )
            held = _HeldFile.capture(output, MAX_BYTES)
            result.products.append(held)
            result._run(
                "core_fixture_" + label + "_architectures",
                [tools["xcrun"], "lipo", "-archs", str(output)],
                project,
                deadline,
            )
            lipo = _HeldFile.capture(
                result.owner.path / ("core_fixture_" + label + "_architectures.stdout"), 1024
            )
            result.products.append(lipo)
            _require(
                builder.architectures(lipo.data) == ("arm64", "x86_64"), "macho_identity", result
            )
            if label == "core":
                _macho_slices(held.data)
                info = _HeldFile.capture(output.parents[1] / "Info.plist", MAX_BYTES)
                result.products.append(info)
                builder.validate_plist(
                    info.data, "core", repository=Path(repository), deadline=deadline
                )
                result.core_bundle = output.parents[2]
                result.core_image, result.core_info = held, info
            result._current(deadline)
        result._current(deadline)
        result.ready = True
        return result
    except BaseException as error:
        result.failed = True
        if isinstance(error, Refusal):
            if error.owner is not None and error.owner is not result:
                result.refusal_debt.append(error.owner)
            error.owner = result
            raise
        if result.fixed is not None and result.fixed.module is not None:
            native_error = result.fixed.module.BASE.NativeBuildError
            if isinstance(error, native_error):
                raise Refusal(error.code, result) from error
        raise Refusal("core_fixture_build", result) from error
    finally:
        result._lock.release()
