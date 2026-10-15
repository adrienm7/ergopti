"""Use the genuine fixed SDK source factory and its original StagedSource owner.

This module authenticates the existing builder only. It neither transforms a
second source image nor grants signing, installation, activation or readiness.
"""

import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys

BUILD_SHA = "24065c518469ac9d60ba3d0888e053ee0158642e5720c4caff64121dd280ceee"
FACTORY_SHA = "9caa7c6b7a89fd1420452b59c4c5697a7a2aaaa9293498652f6b8a6628094c9d"
_BUILD = None
_BUILD_INPUT = None


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def input_identity(info):
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


def _load_build(repository, absolute_deadline):
    """Cache one authenticated issuer while rechecking its original physical input."""
    global _BUILD, _BUILD_INPUT
    path = Path(repository) / "tools/build/remap_runtime_build.py"
    require(path.resolve(strict=True) == path and path.is_file(), "Build owner redirects")
    before = path.lstat()
    require(
        stat.S_ISREG(before.st_mode)
        and before.st_nlink == 1
        and before.st_uid == os.getuid()
        and 0 < before.st_size <= 8 * 1024 * 1024,
        "Build owner is not one ordinary owned input",
    )
    data = path.read_bytes()
    require(
        len(data) == before.st_size
        and digest(data) == BUILD_SHA
        and input_identity(path.lstat()) == input_identity(before),
        "Fixed SDK build owner changed",
    )
    observed = (path, input_identity(before), data)
    if _BUILD is None:
        name = "fixed_sdk_source_original_build_owner"
        spec = importlib.util.spec_from_loader(name, loader=None)
        module = importlib.util.module_from_spec(spec)
        module.__file__ = str(path)
        sys.modules[name] = module
        exec(compile(data, str(path), "exec"), module.__dict__)
        _BUILD, _BUILD_INPUT = module, observed
    require(_BUILD_INPUT == observed, "Original SDK build owner incarnation changed")
    require(
        input_identity(path.lstat()) == input_identity(before) and path.read_bytes() == data,
        "SDK build owner changed while loading",
    )
    _BUILD.check_deadline(absolute_deadline)
    require(_BUILD.SOURCE_FACTORY_SHA256 == FACTORY_SHA, "Different fixed SDK source factory")
    factory = _BUILD._source_factory()
    return _BUILD, factory, path, before, data


def rows(repository, absolute_deadline):
    """Read the one sealed SDK supplier's roster, with no second literal copy."""
    build, factory, _, _, _ = _load_build(repository, absolute_deadline)
    inputs = factory.capture_sdk_dependencies(Path(repository), absolute_deadline)
    provider = factory.load_fixed("fixed_sdk_receiving_source_roster", inputs[0])
    result = provider.ROWS
    require(
        factory.capture_sdk_dependencies(Path(repository), absolute_deadline) == inputs,
        "Fixed SDK source supplier changed while loading",
    )
    build.check_deadline(absolute_deadline)
    return result


def prepare(repository, pristine, owner, absolute_deadline):
    """Issue the real factory image through the original full materializer."""
    repository, pristine, owner = map(Path, (repository, pristine, owner))
    build, factory, _, _, _ = _load_build(repository, absolute_deadline)
    projection = factory.prepare_sdk_owned_source(repository, pristine, absolute_deadline)
    image = build.materialize_owned_source(projection, owner, absolute_deadline)
    factory.current_staged_source(image, absolute_deadline)
    return image


def build_owner(image, absolute_deadline):
    require(_BUILD is not None, "Original SDK source issuer is absent")
    factory = _BUILD._source_factory()
    require(type(image) is factory.StagedSource, "No original factory-issued SDK image")
    build, factory, _, _, _ = _load_build(image.projection.repository, absolute_deadline)
    factory.current_staged_source(image, absolute_deadline)
    return build


def current(image, absolute_deadline):
    """Recheck the issuer's actual image, never an adapter or detached receipt."""
    build_owner(image, absolute_deadline)


def inventory(image, absolute_deadline):
    """Copy technical bindings after currentness; no image/terminal authority."""
    build = build_owner(image, absolute_deadline)
    factory = build._source_factory()
    expected = factory._staged_expectations(image.projection, absolute_deadline)
    return tuple((path, mode, sha) for path, (mode, sha) in sorted(expected.items()))
