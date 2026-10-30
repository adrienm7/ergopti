#!/usr/bin/env python3
# tools/dev/stage-macos-dev-ollama-catalogue.py
"""Build the macOS developer app's managed Ollama from this clone's pinned sources.

A built app carries ``managed_ollama_release.json`` inside its sealed bundle:
the release pipeline builds the native Ollama asset with
tools/build/build-macos-managed-ollama.py, generates the catalogue with
tools/build/stage-macos-managed-ollama-catalogue.py and never commits either.
The developer app runs the Python and the shared data of this clone, so its
owned Ollama install found no catalogue and refused with
OLLAMA_MANAGED_CATALOGUE_MISSING. Copying the catalogue of a published release
only worked once the clone's version was published, so an upcoming version
(its contract edited since the last release) had no owned Ollama at all.

This tool runs the same two release tools on this Mac instead, from the
repository's own pins, and depends on no published Ergopti release:

- the official Ollama archive is downloaded and admitted only when its SHA-256
  and size equal the ones ollama_release.json pins (the build tools check them
  again);
- the upstream source is fetched at the exact source_commit of
  managed_ollama_runtime.json, and the producer checks every reviewed
  upstream preimage and go.sum before it patches anything;
- the Go toolchain must report the contract's go_version: the local `go` when
  it is that version, otherwise the exact toolchain Go downloads itself, which
  it verifies against the Go checksum database (refused when that database is
  disabled or bypassed). A Mac without any `go` gets the official archive of
  that version, admitted only when its SHA-256 and size equal the ones
  tools/dev/macos-dev-go.json pins, unpacked under build/macos-dev-go; nothing
  is installed system-wide.

The catalogue is generated in unpublished mode: CI alone attaches a release
URL, so it names none, and the archive stays in the clone under
build/macos-dev-ollama, where the runtime installer admits it against the
catalogue's SHA-256 and size. A staged build is reused while it binds the
clone's contract and every fingerprinted source; anything else is removed
before rebuilding, so the app refuses with its closed missing-catalogue result
instead of running a binary built for other sources.
"""

import argparse
import hashlib
import importlib.util
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
SHARED = "static/ergopti_plus/_shared"
CONTRACT = SHARED + "/modules/llm/managed_ollama_runtime.json"
OFFICIAL_RELEASE = SHARED + "/modules/llm/ollama_release.json"
CHANNELS = SHARED + "/modules/updater/channels.json"
IDENTIFIERS = SHARED + "/data/identifiers.json"
POLICY_SOURCE = SHARED + "/python/managed_ollama_runtime.py"
OUTPUT = SHARED + "/modules/llm/managed_ollama_release.json"
PRODUCER = "tools/build/build-macos-managed-ollama.py"
GENERATOR = "tools/build/stage-macos-managed-ollama-catalogue.py"
CATALOGUE = "managed_ollama_release.json"
HOSTS = {"arm64": "macos-arm64", "x86_64": "macos-amd64"}
# The Go settings that would let a toolchain or module download skip the Go
# checksum database; any of them refuses the toolchain instead of trusting HTTPS.
CHECKSUM_BYPASS = ("GONOSUMDB", "GOINSECURE", "GOPRIVATE")
CHECKSUM_DATABASE = "sum.golang.org"
DOWNLOAD_TIMEOUT_SECONDS = 1800
GO_ARCHIVES = "tools/dev/macos-dev-go.json"
GO_STATE = "build/macos-dev-go"


class StageRefusal(Exception):
    """One pinned input or produced output that fails its admission."""


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_policy(root):
    specification = importlib.util.spec_from_file_location(
        "ergopti_dev_managed_ollama_policy", root / POLICY_SOURCE
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def fingerprint(root, contract):
    return {name: sha256_file(root / name) for name in contract["source_fingerprint_paths"]}


def regular_file(path):
    return path.is_file() and not path.is_symlink()


def write_atomically(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=".catalogue-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


class Pins:
    """The clone's pinned identities, read once from their single sources."""

    def __init__(self, root, policy, machine):
        if machine not in HOSTS:
            raise StageRefusal("this Mac's architecture %s has no managed Ollama" % machine)
        self.root = root
        self.policy = policy
        self.host = HOSTS[machine]
        self.contract_bytes = (root / CONTRACT).read_bytes()
        self.contract = json.loads(self.contract_bytes)
        official = read_json(root / OFFICIAL_RELEASE)
        if official["version"] != self.contract["version"]:
            raise StageRefusal("ollama_release.json and the managed contract pin other versions")
        self.official = official["assets"][self.contract["official_asset_key"]]
        github = read_json(root / IDENTIFIERS)["hosts"]["github"]
        self.official_url = "https://%s/ollama/ollama/releases/download/v%s/%s" % (
            github,
            official["version"],
            self.official["filename"],
        )
        self.source_url = "https://%s/ollama/ollama.git" % github
        self.channel = read_json(root / CHANNELS)["unreleased_build_channel"]
        self.filename = self.contract["assets"][self.host]["filename"]
        self.state = root / policy.DEVELOPER_ASSET_DIRECTORY
        self.archive = self.state / self.filename
        self.output = root / OUTPUT

    def admit(self, catalogue_bytes, archive):
        """Raise unless the catalogue pins this clone and the archive is its asset."""
        try:
            _, asset = self.policy.select_asset(self.contract_bytes, catalogue_bytes, self.host)
        except self.policy.RuntimeRefusal as error:
            raise StageRefusal("the runtime policy refuses the catalogue: %s" % error) from error
        catalogue = self.policy.metadata_bytes(catalogue_bytes)
        if catalogue["publication"].get("mode") != "unpublished-ci" or asset["url"]:
            raise StageRefusal("the catalogue is not an unpublished build of this clone")
        if catalogue["repository_source_sha256"] != fingerprint(self.root, self.contract):
            raise StageRefusal("the catalogue was built from other fingerprinted sources")
        if (
            not regular_file(archive)
            or archive.stat().st_size != asset["bytes"]
            or sha256_file(archive) != asset["sha256"]
        ):
            raise StageRefusal("the native archive differs from the catalogue's pin")

    def staged_build_holds(self):
        if not regular_file(self.output):
            return False
        try:
            self.admit(self.output.read_bytes(), self.archive)
        except StageRefusal:
            return False
        return True


def run(arguments, **options):
    subprocess.run(arguments, check=True, **options)


def output_of(arguments, environment=None):
    return subprocess.run(
        arguments, check=True, text=True, stdout=subprocess.PIPE, env=environment
    ).stdout.strip()


class HostPorts:
    """The real downloads, toolchain and release tools; tests inject their own."""

    def __init__(self, go=None, root=ROOT):
        self.go = go
        self.root = root

    def machine(self):
        return platform.machine()

    def download(self, url, destination):
        run(
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
            ]
        )

    def source_head(self, source):
        """Return the checkout's HEAD when it is clean, else None."""
        try:
            head = output_of(["git", "-C", str(source), "rev-parse", "HEAD"])
            dirty = output_of(
                ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"]
            )
        except (OSError, subprocess.CalledProcessError):
            return None
        return None if dirty else head

    def fetch_source(self, source, url, commit):
        run(["git", "init", "--quiet", str(source)])
        run(["git", "-C", str(source), "remote", "add", "origin", url])
        run(["git", "-C", str(source), "fetch", "--depth=1", "--no-tags", "origin", commit])
        run(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"])

    def pinned_go(self, version):
        """Return a go executable that reports `version`, checksum-verified when downloaded."""
        go = self.go or shutil.which("go") or self.bootstrap_go(version)
        local = dict(os.environ, GOTOOLCHAIN="local")
        if output_of([go, "env", "GOVERSION"], local) == version:
            return Path(go).resolve()
        settings = json.loads(output_of([go, "env", "-json", "GOSUMDB", *CHECKSUM_BYPASS], local))
        bypass = [name for name in CHECKSUM_BYPASS if settings.get(name)]
        if settings.get("GOSUMDB") != CHECKSUM_DATABASE or bypass:
            raise StageRefusal(
                "Go would download %s without the %s checksum database (GOSUMDB=%s%s);"
                " restore the default or install %s yourself"
                % (
                    version,
                    CHECKSUM_DATABASE,
                    settings.get("GOSUMDB"),
                    "".join(", %s is set" % name for name in bypass),
                    version,
                )
            )
        pinned = dict(os.environ, GOTOOLCHAIN=version)
        for name in CHECKSUM_BYPASS:
            pinned.pop(name, None)
        goroot = Path(output_of([go, "env", "GOROOT"], pinned))
        executable = goroot / "bin/go"
        if output_of([str(executable), "env", "GOVERSION"], local) != version:
            raise StageRefusal("the downloaded Go toolchain does not report %s" % version)
        return executable

    def bootstrap_go(self, version):
        """Unpack the pinned official Go archive under build/ and return its go."""
        pins = read_json(self.root / GO_ARCHIVES)
        if pins["version"] != version:
            raise StageRefusal(
                "%s pins %s but the contract builds with %s: copy the %s darwin archive"
                " digests and sizes into it" % (GO_ARCHIVES, pins["version"], version, version)
            )
        archive = pins["archives"].get(self.machine())
        if archive is None:
            raise StageRefusal("%s pins no Go archive for %s" % (GO_ARCHIVES, self.machine()))
        home = self.root / GO_STATE / version
        go = home / "go" / "bin" / "go"
        if regular_file(go):
            return str(go)
        home.parent.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="go-", dir=home.parent))
        try:
            download = work / archive["filename"]
            print("[dev-ollama-catalogue] No go on PATH: installing %s for this clone..." % version)
            self.download(pins["url"].format(filename=archive["filename"]), download)
            if (
                download.stat().st_size != archive["size"]
                or sha256_file(download) != archive["sha256"]
            ):
                raise StageRefusal(
                    "the downloaded %s differs from its pin in %s"
                    % (archive["filename"], GO_ARCHIVES)
                )
            unpacked = work / "unpacked"
            with tarfile.open(download) as bundle:
                bundle.extractall(unpacked, filter="data")
            if not regular_file(unpacked / "go" / "bin" / "go"):
                raise StageRefusal("%s holds no go/bin/go" % archive["filename"])
            shutil.rmtree(home, ignore_errors=True)
            os.replace(unpacked, home)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        return str(go)

    def produce(self, root, source, official, go, output):
        run(
            [
                sys.executable,
                str(root / PRODUCER),
                "--repository",
                str(root),
                "--source",
                str(source),
                "--official-archive",
                str(official),
                "--go",
                str(go),
                "--output",
                str(output),
            ]
        )

    def generate(self, root, source, official, go, receipt, archive, channel, output):
        run(
            [
                sys.executable,
                str(root / GENERATOR),
                "--repository",
                str(root),
                "--source",
                str(source),
                "--official-archive",
                str(official),
                "--producer-receipt",
                str(receipt),
                "--archive",
                str(archive),
                "--go",
                str(go),
                "--release",
                "false",
                "--release-channel",
                channel,
                "--output",
                str(output),
            ]
        )


def official_archive(pins, ports):
    """Return the official archive, downloaded once and admitted by its pinned identity."""
    path = pins.state / "official" / pins.official["filename"]

    def pinned(candidate):
        return (
            regular_file(candidate)
            and candidate.stat().st_size == pins.official["bytes"]
            and sha256_file(candidate) == pins.official["sha256"]
        )

    if pinned(path):
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name("." + path.name + ".partial")
    for stale in (path, partial):
        if stale.exists() or stale.is_symlink():
            stale.unlink()
    print(
        "[dev-ollama-catalogue] Downloading the official Ollama %s archive..."
        % (pins.contract["version"])
    )
    ports.download(pins.official_url, partial)
    if not pinned(partial):
        if partial.exists():
            partial.unlink()
        raise StageRefusal(
            "the downloaded %s differs from the SHA-256 and size %s pins"
            % (pins.official["filename"], OFFICIAL_RELEASE)
        )
    os.replace(partial, path)
    return path


def upstream_source(pins, ports):
    """Return a clean checkout of the contract's exact upstream commit."""
    source = pins.state / "source"
    commit = pins.contract["source_commit"]
    if source.exists() or source.is_symlink():
        if ports.source_head(source) == commit:
            return source
        shutil.rmtree(source)
    print("[dev-ollama-catalogue] Fetching the upstream Ollama source at %s..." % commit)
    ports.fetch_source(source, pins.source_url, commit)
    if ports.source_head(source) != commit:
        raise StageRefusal("the fetched upstream source is not the clean commit %s" % commit)
    return source


def build(pins, ports):
    """Produce the asset and its catalogue with the release tools."""
    # The release tools extract with tarfile's data filter and zip strictly:
    # the Xcode /usr/bin/python3 (3.9) has neither, and would fail mid-build.
    if sys.version_info < (3, 10) or not hasattr(tarfile, "data_filter"):
        raise StageRefusal(
            "the release tools need Python 3.11.4 or newer, not %s at %s; run this with one"
            " (for example `brew install python`)" % (platform.python_version(), sys.executable)
        )
    official = official_archive(pins, ports)
    source = upstream_source(pins, ports)
    go = ports.pinned_go(pins.contract["go_version"])
    work = Path(tempfile.mkdtemp(prefix="build-", dir=pins.state))
    try:
        assets = work / "assets"
        assets.mkdir()
        print(
            "[dev-ollama-catalogue] Building the managed Ollama %s for %s (several minutes)..."
            % (pins.contract["version"], pins.host)
        )
        ports.produce(pins.root, source, official, go, assets)
        archive = assets / pins.filename
        receipt = assets / (pins.filename + ".provenance.json")
        generated = work / "catalogue" / CATALOGUE
        ports.generate(pins.root, source, official, go, receipt, archive, pins.channel, generated)
        data = generated.read_bytes()
        pins.admit(data, archive)
        os.replace(archive, pins.archive)
        pins.admit(data, pins.archive)
        write_atomically(pins.output, data)
    finally:
        shutil.rmtree(work)


def stage(root, ports):
    """Stage a catalogue and archive built from this clone's pins; return the exit code."""
    pins = Pins(root, load_policy(root), ports.machine())
    pins.state.mkdir(parents=True, exist_ok=True)
    if pins.staged_build_holds():
        print("[dev-ollama-catalogue] The managed Ollama built from this clone is staged.")
        return 0
    if pins.output.exists() or pins.output.is_symlink():
        # A catalogue of other sources must not outlive a failed rebuild.
        pins.output.unlink()
    build(pins, ports)
    print(
        "[dev-ollama-catalogue] Staged the managed Ollama %s built from this clone's pinned"
        " sources." % pins.contract["version"]
    )
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--go", help="Go executable to start from (default: go on PATH)")
    arguments = parser.parse_args()
    try:
        sys.exit(stage(ROOT, HostPorts(arguments.go)))
    except (StageRefusal, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(
            "[dev-ollama-catalogue] ERROR: %s; the developer app's owned Ollama install"
            " refuses with OLLAMA_MANAGED_CATALOGUE_MISSING until this succeeds." % error,
            file=sys.stderr,
        )
        sys.exit(1)
