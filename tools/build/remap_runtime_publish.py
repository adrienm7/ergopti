# tools/build/remap_runtime_publish.py
"""Package the signed owned runtime reproducibly and pin it in the manifest.

The hosted build (`remap_runtime_build.py --sign-owned`) leaves the signed
products under `<owner>/.signed-runtime-preparation/Runtime/`. This tool turns
that tree into the one downloadable artifact of ADR 011 (WP5) and writes the
`runtime.*` pin of `static/ergopti_plus/macos/vendor/remap-runtime/manifest.json`.

Reproducible means: the same signed tree always gives the same bytes. Entries
are sorted, owners are 0, times are 0, the gzip header carries no name and no
time, and only directories and regular files with the modes the signer wrote
are accepted. Anything else (a link, a device, a stray product) is refused by
name rather than skipped, so the digest always describes the whole tree.
"""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile

# The version of the owned runtime artifact. It names the upstream release the
# fork re-anchors on (16.3.0) and the Ergopti revision of that fork; bump the
# last number whenever the signed products change.
RUNTIME_VERSION = "16.3.0-ergopti.1"
FILE_PREFIX = "ErgoptiPlus-Remap-Runtime-"
FILE_SUFFIX = ".tar.gz"
RELEASE_TAG_PREFIX = "remap-runtime-v"
# The GitHub owner and repository have one declaration, the updater defaults.
SHARED = Path(__file__).resolve().parents[2] / "static/ergopti_plus/_shared"
UPDATER_DEFAULTS = SHARED / "modules/updater/defaults.json"
# The GitHub host has one declaration too, the shared identifiers.
GITHUB_HOST = json.loads((SHARED / "data/identifiers.json").read_text(encoding="utf-8"))["hosts"][
    "github"
]


def _default_repository():
    github = json.loads(UPDATER_DEFAULTS.read_text(encoding="utf-8"))["github"]
    return github["owner"] + "/" + github["repo"]


DEFAULT_REPOSITORY = _default_repository()
TOP = "Runtime"
# The three signed products, as remap_runtime_build.py's _SIGNED_PRODUCTS names
# them; an artifact without one of them is not the runtime.
REQUIRED_MEMBERS = (
    "Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
    "Runtime/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
    "Runtime/bin/ergoptiplus_remap_cli",
)
ALLOWED_MODES = (0o755, 0o644)
MAX_MEMBERS = 2048
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MANIFEST_RELATIVE = "static/ergopti_plus/macos/vendor/remap-runtime/manifest.json"
PIN_KEYS = ("version", "file_name", "source_url", "sha256", "size")


class PublishRefusal(Exception):
    """The signed tree or the manifest cannot be published as asked."""


def _require(condition, message):
    if not condition:
        raise PublishRefusal(message)


def file_name(version=RUNTIME_VERSION):
    """The artifact file name of a runtime version."""
    return FILE_PREFIX + version + FILE_SUFFIX


def source_url(repository=DEFAULT_REPOSITORY, version=RUNTIME_VERSION):
    """The release address the driver downloads the artifact from."""
    _require(
        repository.count("/") == 1 and all(part for part in repository.split("/")),
        "repository must be owner/name",
    )
    return (
        "https://"
        + GITHUB_HOST
        + "/"
        + repository
        + "/releases/download/"
        + RELEASE_TAG_PREFIX
        + version
        + "/"
        + file_name(version)
    )


def inventory(root):
    """Lists the tree under root/Runtime as sorted (relative, path, info) rows."""
    root = Path(root)
    top = root / TOP
    _require(top.is_dir() and not top.is_symlink(), "the signed tree has no Runtime directory")
    rows = []
    pending = [top]
    total = 0
    while pending:
        directory = pending.pop()
        info = directory.lstat()
        _require(stat.S_ISDIR(info.st_mode), "not a directory: " + str(directory))
        rows.append((directory.relative_to(root).as_posix(), directory, info))
        for child in sorted(directory.iterdir()):
            child_info = child.lstat()
            relative = child.relative_to(root).as_posix()
            if stat.S_ISDIR(child_info.st_mode):
                pending.append(child)
            elif stat.S_ISREG(child_info.st_mode):
                _require(child_info.st_nlink == 1, "hard-linked file: " + relative)
                total += child_info.st_size
                rows.append((relative, child, child_info))
            else:
                raise PublishRefusal("neither a directory nor a regular file: " + relative)
            _require(len(rows) <= MAX_MEMBERS, "too many members in the signed tree")
            _require(total <= MAX_TOTAL_BYTES, "the signed tree is too large")
    for relative, _, info in rows:
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISDIR(info.st_mode):
            _require(mode == 0o755, "directory mode is not 0755: " + relative)
        else:
            _require(mode in ALLOWED_MODES, "file mode is not 0755 or 0644: " + relative)
    names = {relative for relative, _, _ in rows}
    for required in REQUIRED_MEMBERS:
        _require(required in names, "missing signed product: " + required)
    return sorted(rows, key=lambda row: row[0])


def archive_bytes(root):
    """Builds the reproducible artifact of the signed tree."""
    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buffer, mtime=0, compresslevel=9) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for relative, path, info in inventory(root):
                member = tarfile.TarInfo(relative)
                member.mode = stat.S_IMODE(info.st_mode)
                member.uid = member.gid = 0
                member.uname = member.gname = ""
                member.mtime = 0
                if stat.S_ISDIR(info.st_mode):
                    member.type = tarfile.DIRTYPE
                    archive.addfile(member)
                    continue
                data = path.read_bytes()
                _require(len(data) == info.st_size, "file changed while packaging: " + relative)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
    return buffer.getvalue()


def verify_archive(data, pin):
    """Checks artifact bytes against a pin and returns the member names.

    The same checks the driver makes before it extracts a download: the size
    and digest first, then a closed member list without links, absolute paths
    or `..`, with every signed product present.
    """
    _require(len(data) == pin["size"], "size differs from the pin")
    _require(hashlib.sha256(data).hexdigest() == pin["sha256"], "digest differs from the pin")
    names = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            _require(
                not path.is_absolute() and ".." not in path.parts and path.parts[:1] == (TOP,),
                "member outside Runtime: " + member.name,
            )
            _require(
                member.isdir() or member.isreg(),
                "member is neither a directory nor a file: " + member.name,
            )
            names.append(member.name)
    for required in REQUIRED_MEMBERS:
        _require(required in names, "missing signed product: " + required)
    return names


def package(root, output, repository=DEFAULT_REPOSITORY, version=RUNTIME_VERSION):
    """Writes the artifact and its pin next to it; returns the pin."""
    data = archive_bytes(root)
    pin = {
        "version": version,
        "file_name": file_name(version),
        "source_url": source_url(repository, version),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    }
    verify_archive(data, pin)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / pin["file_name"]).write_bytes(data)
    (output / "runtime-pin.json").write_text(json.dumps(pin, indent=2) + "\n", encoding="utf-8")
    return pin


def apply_pin(manifest_path, pin):
    """Writes the runtime pin into the manifest, keeping every other field."""
    _require(sorted(pin) == sorted(PIN_KEYS), "the pin must carry exactly " + ", ".join(PIN_KEYS))
    manifest_path = Path(manifest_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    _require(manifest.get("schema") == 1, "unknown manifest schema")
    runtime = manifest["runtime"]
    for key in PIN_KEYS:
        runtime[key] = pin[key]
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return manifest


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package", help="build the artifact and runtime-pin.json")
    pack.add_argument("signed_root", type=Path, help="directory that holds the signed Runtime/")
    pack.add_argument("output", type=Path)
    pack.add_argument("--repository", default=DEFAULT_REPOSITORY)
    apply = commands.add_parser("apply", help="write runtime-pin.json into the manifest")
    apply.add_argument("pin", type=Path)
    apply.add_argument("--manifest", type=Path, default=Path(MANIFEST_RELATIVE))
    options = parser.parse_args(arguments)
    try:
        if options.command == "package":
            pin = package(options.signed_root, options.output, options.repository)
            print(json.dumps(pin, sort_keys=True))
            return 0
        apply_pin(options.manifest, json.loads(options.pin.read_text(encoding="utf-8")))
        print("Pinned the owned runtime in " + str(options.manifest))
        return 0
    except (PublishRefusal, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print("Owned runtime publication refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
