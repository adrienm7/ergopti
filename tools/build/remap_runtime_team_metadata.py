# tools/build/remap_runtime_team_metadata.py
"""One existing SDK worker qualifies actual CF metadata only after owned compilation."""

import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import stat
import sys
import time

BUILDER_SHA256 = "e8891edda6f25de3ab4361143c51ce55b4289368e6dfb69102f671681081d1d6"
HEADER_SHA256 = "f6b921d8ce74938463b6d28dc50bda457755da1602f62c9e52e8bba760604a75"
CONTROL_SHA256 = "8ead4c6e4b9100d58d91d3464a6349a4b69891c6017b4e9ffecabb0c233fc947"
CORPUS_SHA256 = "fe38a9f21227093543541d9f19cfdaf0bd7c052f15f7dc18dff6a0a4558ec335"
PASS = "PASS native CF Team metadata cases=12; signing and authentication unqualified\n"


class MetadataRefusal(Exception):
    """A finite native observation failed to complete its exact closed boundary."""


def require(condition):
    if not condition:
        raise MetadataRefusal()


def admit_output(stdout, stderr, corpus):
    require(type(stdout) is bytes and type(stderr) is bytes and type(corpus) is bytes)
    require(not stderr and hashlib.sha256(corpus).hexdigest() == CORPUS_SHA256)
    cases = json.loads(corpus)["cases"]
    require(len(cases) == 12)
    ids = [row.split(":", 1)[0] for row in cases]
    require(len(set(ids)) == 12)
    expected = "".join("CASE " + case + " PASS\n" for case in ids + ["inventory"]).encode()
    require(stdout == expected)


def file_identity(info):
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


def fixed_file(path, root, digest):
    require(path.is_absolute() and path.resolve(strict=True) == path and root in path.parents)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.getuid())
    require(0 < before.st_size <= 2 * 1024 * 1024)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        data = stream.read(2 * 1024 * 1024 + 1)
        require(
            file_identity(opened)
            == file_identity(before)
            == file_identity(os.fstat(stream.fileno()))
            == file_identity(path.lstat())
        )
        require(len(data) == before.st_size and hashlib.sha256(data).hexdigest() == digest)
    return data, file_identity(before)


def run(repository, owned, owner):
    deadline = time.monotonic() + 30
    require(sys.platform == "darwin")
    repository, owned, owner = Path(repository), Path(owned), Path(owner)
    canonical = Path(__file__).resolve().parents[2]
    require(repository == canonical and repository.is_absolute())
    for path in (repository, owned, owner):
        require(
            path.resolve(strict=True) == path
            and path.is_dir()
            and path.stat().st_uid == os.getuid()
        )
    require(owned != owner and owned not in owner.parents and owner not in owned.parents)
    require(not any(owner.iterdir()))
    builder_path = repository / "tools/build/remap_runtime_build.py"
    builder_data, builder_identity = fixed_file(builder_path, repository, BUILDER_SHA256)
    specification = importlib.util.spec_from_file_location(
        "team_metadata_fixed_builder", builder_path
    )
    builder = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = builder
    exec(compile(builder_data, str(builder_path), "exec"), builder.__dict__)
    builder.BASE.validate_owner_root(owner)
    factory = builder._source_factory()
    projection = factory.prepare_owned_source(repository, owned / "pristine", deadline)
    stage = owned / "upstream"
    expected = factory._staged_expectations(projection)
    files, links = [], []
    for relative, (mode, digest) in sorted(expected.items()):
        if mode == "120000":
            row = factory._staged_link(stage, relative, deadline)
            links.append(row)
        else:
            row = factory.read_input(stage, relative, 8 * 1024 * 1024, deadline)
            require(bool(row.identity[3] & 0o111) == (mode == "100755"))
            files.append(row)
        require(hashlib.sha256(row.data).hexdigest() == digest)
    image = factory.StagedSource(
        projection, stage, factory.root_identity(stage), tuple(files), tuple(links)
    )
    factory.current_staged_source(image, deadline)
    inputs = builder.capture_generated_inputs(image, deadline)
    record_image = builder._ordinary(
        owned / "owned-native-build-result.json", owned, builder.BASE.MAX_INPUT_BYTES
    )
    record = builder.parse_json(record_image.data)
    builder.validate_current_owned_record(record)
    actual_generated = [
        {
            "path": row.path,
            "sha256": builder.BASE.digest(row.data),
            "bytes": len(row.data),
        }
        for row in inputs.files[len(image.files) :]
    ]
    require(actual_generated == record["generated_inputs"])
    products = []
    for row in record["products"]:
        product = builder.product_snapshot(stage / row["path"], stage)
        require(
            builder.BASE.digest(product.data) == row["sha256"] and len(product.data) == row["bytes"]
        )
        products.append(product)
    control = repository / "tools/build/remap_runtime_team_metadata_control.cpp"
    corpus_path = repository / "tools/build/fixtures/remap_runtime_team_metadata12.json"
    corpus, _ = fixed_file(corpus_path, repository, CORPUS_SHA256)
    header_path = repository / "tools/build/remap_runtime_auth.hpp"
    xcrun = Path("/usr/bin/xcrun")
    require(xcrun.resolve(strict=True) == xcrun and os.access(xcrun, os.X_OK))
    tool_identity = builder._identity(xcrun.stat())

    def current():
        require(math.isfinite(deadline) and time.monotonic() < deadline)
        fixed_file(builder_path, repository, BUILDER_SHA256)
        require(file_identity(builder_path.lstat()) == builder_identity)
        fixed_file(header_path, repository, HEADER_SHA256)
        fixed_file(control, repository, CONTROL_SHA256)
        fixed_file(corpus_path, repository, CORPUS_SHA256)
        require(
            xcrun.resolve(strict=True) == xcrun and builder._identity(xcrun.stat()) == tool_identity
        )
        builder.current_product(record_image, owned)
        builder._current_build_inputs(inputs, deadline, image)
        for product in products:
            builder.current_product(product, stage)

    current()
    executable = owner / "native-team-metadata-control"
    require(not executable.exists() and not executable.is_symlink())
    command = [
        str(xcrun),
        "clang++",
        "-std=c++23",
        "-O0",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-pedantic",
        "-I" + str(repository / "tools/build"),
        "-I" + str(stage / "vendor/vendor/include"),
        str(control),
        "-framework",
        "CoreFoundation",
        "-framework",
        "Security",
        "-lbsm",
        "-o",
        str(executable),
    ]
    builder.BASE.run_phase("team_metadata_compile", command, owner, owner, deadline)
    current()
    require(builder._ordinary(owner / "team_metadata_compile.stdout", owner, 4096).data == b"")
    require(builder._ordinary(owner / "team_metadata_compile.stderr", owner, 4096).data == b"")
    require(os.access(executable, os.X_OK))
    binary = builder.product_snapshot(executable, owner)
    require(len(binary.data) > 0)
    builder.BASE.run_phase("team_metadata_run", [str(executable)], owner, owner, deadline)
    builder.current_product(binary, owner)
    current()
    admit_output(
        builder._ordinary(owner / "team_metadata_run.stdout", owner, 4096).data,
        builder._ordinary(owner / "team_metadata_run.stderr", owner, 4096).data,
        corpus,
    )
    builder.current_product(binary, owner)
    current()
    print(PASS, end="")


def main(arguments):
    try:
        require(len(arguments) == 3)
        run(*arguments)
        return 0
    except Exception:
        print(
            "Native CF Team metadata qualification refused; retained evidence remains private",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
