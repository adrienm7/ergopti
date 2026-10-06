# tools/diagnostics/hs274_promoted_source_witness.py
"""Generate the closed reviewed promoted-source witness, never a test outcome corpus."""

import argparse
import difflib
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "promoted_witness_native_contract", Path(__file__).with_name("hs274_native_build.py")
)
CONTROLLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROLLER)
NativeBuildError = CONTROLLER.NativeBuildError
ARCHIVE = "tools/diagnostics/fixtures/hs274-native-build-candidate"
OUTPUT = "tools/diagnostics/fixtures/hs274-promoted-source-witness"
ARCHIVE_SHA256 = "0bf8c164dac52886f2088559c42a0fd2cc8e8742a597f88ce30bfaaf37d1b191"
REVIEWED_FORMAT_HASHES = {
    "hs274_raw_patch.py": "52202e991ad12e0aae5806ecb093c4018318517c8f07d774ef3d4e730f218423",
    "hs274_stream_patch.py": "7df485fc0cbcb6bb16b3e8d3d67ebacebc0da9b0840abe7b308bb45fb809011b",
}


def generate(repository):
    """Return a coherent fresh-directory pair only for the declared reviewed25 source bytes."""
    repository = Path(repository).absolute()
    CONTROLLER.require(
        repository.resolve() == repository, "unsafe_path", "Witness repository is redirected"
    )
    archive = repository / ARCHIVE / "manifest.json"
    archive_bytes = CONTROLLER.read_regular(archive, 65_536)
    CONTROLLER.require(
        CONTROLLER.digest(archive_bytes) == ARCHIVE_SHA256,
        "source_identity",
        "Original archived source contract changed",
    )
    seal = CONTROLLER.load_candidate_seal(archive)
    archive_patch = archive.parent / seal["patch_file"]
    archive_patch_bytes = CONTROLLER.read_regular(archive_patch)
    CONTROLLER.require(
        CONTROLLER.digest(archive_patch_bytes) == seal["patch_sha256"],
        "source_identity",
        "Original archived patch changed",
    )
    CONTROLLER.require(
        len(seal["files"]) == 25
        and set(REVIEWED_FORMAT_HASHES).issubset({row["path"] for row in seal["files"]}),
        "source_identity",
        "Reviewed promoted source inventory changed",
    )
    inputs = []
    rows = []
    patch = []
    for row in seal["files"]:
        path = repository / "tools/diagnostics" / row["path"]
        expected = REVIEWED_FORMAT_HASHES.get(row["path"], row["candidate_sha256"])
        source = CONTROLLER.read_regular(path)
        CONTROLLER.require(
            CONTROLLER.digest(source) == expected,
            "source_identity",
            "Source differs from its declared reviewed promoted bytes",
        )
        inputs.append((path, source))
        rows.append({"path": row["path"], "preimage_sha256": None, "candidate_sha256": expected})
        patch.append("diff --git a/" + row["path"] + " b/" + row["path"] + "\n")
        patch.append("new file mode 100644\n")
        patch.extend(
            difflib.unified_diff(
                [],
                source.decode("utf-8").splitlines(keepends=True),
                fromfile="/dev/null",
                tofile="b/" + row["path"],
                n=3,
            )
        )
    patch_bytes = "".join(patch).encode("utf-8")
    witness = {
        "schema": 1,
        "purpose": "inactive-native-compilation-only",
        "patch_file": "candidate.patch",
        "patch_sha256": CONTROLLER.digest(patch_bytes),
        "files": rows,
    }
    # Recheck retained source bytes after all reading and composition, before publishing.
    for path, source in inputs:
        CONTROLLER.require(
            CONTROLLER.read_regular(path) == source,
            "source_identity",
            "Promoted source changed during witness generation",
        )
    CONTROLLER.require(
        CONTROLLER.read_regular(archive, 65_536) == archive_bytes,
        "source_identity",
        "Archived contract changed during witness generation",
    )
    CONTROLLER.require(
        CONTROLLER.read_regular(archive_patch) == archive_patch_bytes,
        "source_identity",
        "Archived patch changed during witness generation",
    )
    return {
        "manifest.json": (json.dumps(witness, indent="\t") + "\n").encode("utf-8"),
        "candidate.patch": patch_bytes,
    }


def main(repository, write=False):
    """Write or check only the two owned generated source artifacts."""
    outputs = generate(repository)
    directory = Path(repository).absolute() / OUTPUT
    if write:
        CONTROLLER.require(
            directory.resolve() == directory, "unsafe_path", "Witness output is redirected"
        )
        directory.mkdir(parents=True, exist_ok=True)
        for name in outputs:
            path = directory / name
            if path.exists() or path.is_symlink():
                CONTROLLER.read_regular(path)
        for name, source in outputs.items():
            (directory / name).write_bytes(source)
    else:
        for name, source in outputs.items():
            CONTROLLER.require(
                CONTROLLER.read_regular(directory / name) == source,
                "source_identity",
                "Generated promoted witness is stale",
            )
    print(
        "PASS generated promoted source witness files=25; compilation and installation unexecuted"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--write", action="store_true")
    options = parser.parse_args()
    main(options.repository, options.write)
