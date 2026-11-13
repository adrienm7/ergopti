#!/usr/bin/env python3
# tools/dev/macos_dev_go.py
"""Give the macOS developer builds the repository's Go without installing anything.

The proxy sign-in relay and the managed Ollama both compile with Go, and a
maintainer's Mac has none: nothing asks for one, PATH stays as it is. The
official archive of the repository's pin (go_version in
_shared/ai/data/managed_ollama_runtime.json) is downloaded once, admitted
only when its SHA-256 and size equal the ones tools/dev/macos-dev-go.json pins
for this architecture, and unpacked under build/macos-dev-go in the clone.

Run directly, this prints the go executable of that pin: the one on PATH when it
is exactly that version, otherwise the private copy. It exits 1 with the reason
on stderr when neither can be had, and the developer build goes without the
relay. The Python of the Xcode command-line tools runs this, so nothing here may
need a newer one.
"""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = "static/ergopti_plus/_shared/ai/data/managed_ollama_runtime.json"
GO_ARCHIVES = "tools/dev/macos-dev-go.json"
GO_STATE = "build/macos-dev-go"
DOWNLOAD_TIMEOUT_SECONDS = 1800


class GoRefusal(Exception):
    """A pinned Go archive that cannot be had or fails its admission."""


def regular_file(path):
    return path.is_file() and not path.is_symlink()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def download(url, destination):
    """Fetch one HTTPS URL with the system curl, which honours the user's proxy."""
    subprocess.run(
        [
            "/usr/bin/curl",
            "--fail",
            "--show-error",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--retry",
            "3",
            "--max-time",
            str(DOWNLOAD_TIMEOUT_SECONDS),
            "--output",
            str(destination),
            url,
        ],
        check=True,
    )


def unpack(archive, destination):
    """Unpack an archive whose digest was already admitted against its pin."""
    with tarfile.open(archive) as bundle:
        # Python 3.9 of the Xcode tools has no extraction filter; the digest is
        # what admits these bytes, the filter only hardens the newer interpreters.
        options = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        bundle.extractall(destination, **options)


def bootstrap(root, version, machine, fetch=download):
    """Unpack the pinned official Go archive under build/ and return its go."""
    pins = read_json(root / GO_ARCHIVES)
    if pins["version"] != version:
        raise GoRefusal(
            "%s pins %s but the contract builds with %s: copy the %s darwin archive"
            " digests and sizes into it" % (GO_ARCHIVES, pins["version"], version, version)
        )
    archive = pins["archives"].get(machine)
    if archive is None:
        raise GoRefusal("%s pins no Go archive for %s" % (GO_ARCHIVES, machine))
    home = root / GO_STATE / version
    go = home / "go" / "bin" / "go"
    if regular_file(go):
        return str(go)
    home.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="go-", dir=home.parent))
    try:
        fetched = work / archive["filename"]
        print("[macos-dev-go] Downloading %s for this clone..." % version, file=sys.stderr)
        fetch(pins["url"].format(filename=archive["filename"]), fetched)
        if fetched.stat().st_size != archive["size"] or sha256_file(fetched) != archive["sha256"]:
            raise GoRefusal(
                "the downloaded %s differs from its pin in %s" % (archive["filename"], GO_ARCHIVES)
            )
        unpacked = work / "unpacked"
        unpack(fetched, unpacked)
        if not regular_file(unpacked / "go" / "bin" / "go"):
            raise GoRefusal("%s holds no go/bin/go" % archive["filename"])
        shutil.rmtree(home, ignore_errors=True)
        os.replace(unpacked, home)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return str(go)


def reports(go, version):
    """Return whether this go executable is exactly the pinned toolchain."""
    environment = dict(os.environ, GOTOOLCHAIN="local")
    try:
        answer = subprocess.run(
            [go, "env", "GOVERSION"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            env=environment,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return answer.stdout.strip() == version


def resolve(root, machine, fetch=download):
    """Return the go of the repository's pin, from PATH or the private copy."""
    version = read_json(root / CONTRACT)["go_version"]
    on_path = shutil.which("go")
    if on_path and reports(on_path, version):
        return on_path
    go = bootstrap(root, version, machine, fetch)
    if not reports(go, version):
        raise GoRefusal("the unpacked Go does not report %s" % version)
    return go


def main():
    try:
        print(resolve(ROOT, platform.machine()))
    except (GoRefusal, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("[macos-dev-go] ERROR: no Go toolchain: %s." % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
