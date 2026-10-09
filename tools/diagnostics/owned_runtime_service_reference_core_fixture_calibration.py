# tools/diagnostics/owned_runtime_service_reference_core_fixture_calibration.py
"""Invoke the fixed genuine Core-only producer inside its own native Guardian.

The terminal JSON is an observation, never a transferable Core/source owner.
The SDK Guardian independently proves actual child-group retirement.
"""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import stat
import sys
import threading
import time

PRODUCER_PATH = "tools/diagnostics/owned_runtime_service_reference_core_fixture_build.py"
PRODUCER_SHA256 = "7b52011dcd9c86b18ea445dc8fc152665627ae1e5d278861be3367af782344ee"
MAX_SOURCE_BYTES = 8 * 1024 * 1024


class CalibrationRefusal(RuntimeError):
    """A prerequisite or retirement refusal preserves its real custody owner."""

    def __init__(self, code, owner=None):
        self.code, self.owner = code, owner
        super().__init__(code)


def require(value, code, owner=None):
    if not value:
        raise CalibrationRefusal(code, owner)


def budget(value):
    require(type(value) is int and value == 300, "invalid_budget")
    return value


def tick(deadline):
    require(
        type(deadline) in (int, float) and math.isfinite(deadline) and time.monotonic() < deadline,
        "deadline",
    )


def identity(info):
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


class FixedProducerImage:
    """Own the fixed executed source FD and its genuine typed per-phase guard."""

    def __init__(self, path):
        self.path, self.descriptor, self.program_source = path, None, None
        self.data, self.stamp, self.module = None, None, None
        self.closed = self.failed = False
        self._lock = threading.Lock()

    @classmethod
    def capture(cls, repository):
        path = Path(repository) / PRODUCER_PATH
        result = cls(path)
        try:
            require(
                path.is_absolute() and path.resolve(strict=True) == path,
                "program_source_identity",
                result,
            )
            result.descriptor = os.open(
                path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
            )
            info = os.fstat(result.descriptor)
            require(
                stat.S_ISREG(info.st_mode)
                and info.st_uid == os.getuid()
                and info.st_nlink == 1
                and 0 < info.st_size <= MAX_SOURCE_BYTES,
                "program_source_identity",
                result,
            )
            result.stamp = identity(info)
            result.data = result._read(info.st_size)
            require(
                hashlib.sha256(result.data).hexdigest() == PRODUCER_SHA256,
                "program_source_identity",
                result,
            )
            result._current()
            spec = importlib.util.spec_from_loader(
                "fixed_actual_core_fixture_producer", loader=None
            )
            module = importlib.util.module_from_spec(spec)
            module.__file__ = str(path)
            exec(compile(result.data, str(path), "exec"), module.__dict__)
            result.module = module
            result._current()
            guard = module._HeldFile.capture(path, MAX_SOURCE_BYTES)
            result.program_source = guard
            require(
                guard.stamp == result.stamp and guard.data == result.data,
                "program_source_changed",
                result,
            )
            result._current()
            return result
        except BaseException as error:
            if isinstance(error, CalibrationRefusal):
                raise
            # Core capture may itself have an unknown physical close return.
            if result.module is not None and isinstance(error, result.module.Refusal):
                if isinstance(error.owner, result.module._HeldFile):
                    result.program_source = error.owner
            raise CalibrationRefusal("program_source_identity", result) from error

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
        require(not self.closed and not self.failed, "program_source_retired", self)
        try:
            require(
                self.path.resolve(strict=True) == self.path
                and identity(self.path.lstat()) == self.stamp
                and identity(os.fstat(self.descriptor)) == self.stamp,
                "program_source_changed",
                self,
            )
            require(
                self._read(len(self.data)) == self.data
                and identity(os.fstat(self.descriptor)) == self.stamp
                and identity(self.path.lstat()) == self.stamp,
                "program_source_changed",
                self,
            )
            if self.program_source is not None:
                self.program_source.current()
        except (OSError, self.module.Refusal if self.module is not None else OSError) as error:
            raise CalibrationRefusal("program_source_changed", self) from error

    def current(self, deadline):
        tick(deadline)
        require(self._lock.acquire(blocking=False), "program_source_busy", self)
        try:
            self._current()
        finally:
            self._lock.release()
        tick(deadline)

    def close_retained(self):
        require(self._lock.acquire(blocking=False), "program_source_busy", self)
        try:
            complete = not self.failed
            if self.program_source is not None and not self.program_source.closed:
                try:
                    self.program_source.close()
                except self.module.Refusal:
                    complete = False
            if self.descriptor is not None:
                descriptor, self.descriptor = self.descriptor, None
                try:
                    os.close(descriptor)
                except OSError:
                    self.failed = True
                    complete = False
            if complete:
                self.closed = True
            return complete
        finally:
            self._lock.release()


class CalibrationOwner:
    """Keep the real producer continuation on failure; never rebuild it from JSON."""

    def __init__(self):
        self.image = self.core = None

    def close_retained(self):
        complete = True
        if self.core is not None and not self.core.close_retained():
            complete = False
        if self.image is not None and not self.image.close_retained():
            complete = False
        return complete


def calibrate(repository, pristine, owner, seconds=300):
    """Use one absolute envelope and report only a partial actual Core compilation."""
    budget(seconds)
    deadline = time.monotonic() + seconds
    retained = CalibrationOwner()
    try:
        tick(deadline)
        retained.image = FixedProducerImage.capture(repository)
        retained.image.current(deadline)
        producer = retained.image.module
        retained.core = producer.produce(
            repository,
            pristine,
            owner,
            seconds,
            current_program_source=retained.image.program_source,
        )
        retained.image.current(deadline)
        retained.core.current(deadline)
        core, info = retained.core.core_image, retained.core.core_info
        packet = {
            "schema": 1,
            "qualification": "unsigned_actual_core_constructor_compilation_only",
            "producer_sha256": PRODUCER_SHA256,
            "source_factory_sha256": dict(producer.SOURCE_PINS)[
                "tools/build/remap_runtime_source.py"
            ],
            "core_relative_path": str(retained.core.core_bundle.relative_to(Path(owner))),
            "core_sha256": hashlib.sha256(core.data).hexdigest(),
            "core_bytes": len(core.data),
            "info_sha256": hashlib.sha256(info.data).hexdigest(),
            "architectures": list(producer._macho_slices(core.data)),
            "full_four_target_qualified": False,
            "signing_executed": False,
            "main_principal_qualified": False,
            "root_placement_qualified": False,
            "child_group_retirement_qualified": False,
            "installation_executed": False,
            "capture_executed": False,
        }
        retained.core.current(deadline)
        retained.image.current(deadline)
        require(retained.close_retained(), "descriptor_retirement_unknown", retained)
        tick(deadline)
        packet["descriptor_retirement_ack"] = True
        return packet
    except BaseException as error:
        if isinstance(error, CalibrationRefusal):
            if isinstance(error.owner, FixedProducerImage):
                retained.image = error.owner
            error.owner = retained
            raise
        if retained.image is not None and isinstance(error, retained.image.module.Refusal):
            if isinstance(error.owner, retained.image.module.CoreFixtureBuild):
                retained.core = error.owner
            raise CalibrationRefusal(error.code, retained) from error
        raise CalibrationRefusal("core_calibration_refused", retained) from error


def main(arguments=None):
    """Expose only the fixed compiler entry; ordinary input errors acquire no child."""
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--pristine", required=True)
    parser.add_argument("--budget", type=int, required=True)
    try:
        options = parser.parse_args(arguments)
        budget(options.budget)
    except (SystemExit, CalibrationRefusal):
        return 64
    repository = Path(__file__).resolve(strict=True).parents[2]
    try:
        packet = calibrate(repository, Path(options.pristine), Path(options.owner), options.budget)
    except CalibrationRefusal as error:
        acknowledged = error.owner is not None and error.owner.close_retained()
        print("Core constructor calibration refused: " + error.code, file=sys.stderr)
        if not acknowledged:
            print("Core constructor descriptor retirement unqualified", file=sys.stderr)
            return 70
        return 69
    print(json.dumps(packet, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
