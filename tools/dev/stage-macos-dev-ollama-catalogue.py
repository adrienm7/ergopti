#!/usr/bin/env python3
# tools/dev/stage-macos-dev-ollama-catalogue.py
"""Give the macOS developer app the published, verified managed Ollama catalogue.

A built app carries ``managed_ollama_release.json`` inside its sealed bundle:
the release pipeline generates it from the native producer and never commits
it. The developer app runs the Python and the shared data of this clone, so its
owned Ollama install found no catalogue and refused with
OLLAMA_MANAGED_CATALOGUE_MISSING. This tool copies the catalogue of the newest
immutable GitHub release that binds this clone's runtime contract into the
clone, where the developer app reads it (the path is ignored by Git).

The catalogue is admitted only when every link of the chain holds: the release
is published and immutable; the catalogue bytes match the SHA-256 GitHub
recorded for that asset; the runtime policy accepts it for both macOS hosts
against this clone's contract; its publication names that tag and the canonical
repository; and each native asset it pins is an asset of the same release with
the same digest, size and download URL. When no release binds the contract (a
contract edited since the last release), the stale catalogue is removed and the
tool exits 3, so the app keeps refusing with its closed missing-catalogue
result instead of running a binary built for another contract.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SHARED = "static/ergopti_plus/_shared"
CONTRACT = SHARED + "/modules/llm/managed_ollama_runtime.json"
OUTPUT = SHARED + "/modules/llm/managed_ollama_release.json"
DEFAULTS = SHARED + "/modules/updater/defaults.json"
IDENTIFIERS = SHARED + "/data/identifiers.json"
POLICY_SOURCE = SHARED + "/python/managed_ollama_runtime.py"
CATALOGUE = "managed_ollama_release.json"
HOSTS = ("macos-arm64", "macos-amd64")
# Releases read per listing; the binding release is one of the newest ones.
RELEASES_PER_PAGE = 30
FETCH_TIMEOUT_SECONDS = 60
NO_BINDING_RELEASE = 3


class CatalogueRefusal(Exception):
    """A published catalogue or release that fails one admission link."""


def load_policy(root):
    specification = importlib.util.spec_from_file_location(
        "ergopti_dev_managed_ollama_policy", root / POLICY_SOURCE
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def curl_fetch(url, accept):
    """Read one HTTPS resource through curl, which honours the system proxy settings."""
    result = subprocess.run(
        [
            "/usr/bin/curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--max-time",
            str(FETCH_TIMEOUT_SECONDS),
            "--header",
            "Accept: " + accept,
            url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise OSError(
            "curl exited %d for %s: %s"
            % (result.returncode, url, result.stderr.decode("utf-8", "replace").strip())
        )
    return result.stdout


def asset_digest(asset):
    digest = asset.get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:"):
        raise CatalogueRefusal("asset %s has no SHA-256 digest" % asset.get("name"))
    return digest[len("sha256:") :]


def admit(policy, contract_bytes, repository, github_host, release, catalogue_bytes):
    """Return the catalogue bytes when every admission link holds, else raise."""
    tag = release.get("tag_name")
    if release.get("draft") is not False or release.get("immutable") is not True:
        raise CatalogueRefusal("release %s is not published and immutable" % tag)
    assets = {asset.get("name"): asset for asset in release.get("assets", [])}
    if hashlib.sha256(catalogue_bytes).hexdigest() != asset_digest(assets[CATALOGUE]):
        raise CatalogueRefusal("catalogue of %s differs from its recorded digest" % tag)
    publication = policy.metadata_bytes(catalogue_bytes)["publication"]
    if (
        publication.get("mode") != "planned-release"
        or publication.get("tag") != tag
        or publication.get("repository") != repository
    ):
        raise CatalogueRefusal("catalogue of %s names another publication" % tag)
    for host in HOSTS:
        try:
            _, pinned = policy.select_asset(contract_bytes, catalogue_bytes, host)
        except policy.RuntimeRefusal as error:
            raise CatalogueRefusal(
                "catalogue of %s refused for %s: %s" % (tag, host, error)
            ) from error
        native = assets.get(pinned["filename"])
        expected_url = "https://%s/%s/releases/download/%s/%s" % (
            github_host,
            repository,
            tag,
            pinned["filename"],
        )
        if (
            native is None
            or asset_digest(native) != pinned["sha256"]
            or native.get("size") != pinned["bytes"]
            or pinned["url"] != expected_url
            or native.get("browser_download_url") != expected_url
        ):
            raise CatalogueRefusal("native %s asset of %s differs from its catalogue" % (host, tag))
    return catalogue_bytes


def binding_catalogue(root, fetch, policy):
    """Return (tag, bytes) of the newest release binding this clone's contract, or None."""
    contract_bytes = (root / CONTRACT).read_bytes()
    contract_sha256 = hashlib.sha256(contract_bytes).hexdigest()
    github = json.loads((root / DEFAULTS).read_text(encoding="utf-8"))["github"]
    repository = github["owner"] + "/" + github["repo"]
    hosts = json.loads((root / IDENTIFIERS).read_text(encoding="utf-8"))["hosts"]
    listing = json.loads(
        fetch(
            "https://%s/repos/%s/releases?per_page=%d"
            % (hosts["github_api"], repository, RELEASES_PER_PAGE),
            "application/vnd.github+json",
        )
    )
    for release in listing:
        assets = {asset.get("name"): asset for asset in release.get("assets", [])}
        if CATALOGUE not in assets or release.get("draft") is not False:
            continue
        catalogue_bytes = fetch(
            assets[CATALOGUE]["browser_download_url"], "application/octet-stream"
        )
        try:
            bound = policy.metadata_bytes(catalogue_bytes).get("runtime_contract_sha256")
        except policy.RuntimeRefusal as error:
            raise CatalogueRefusal(
                "catalogue of %s is not metadata" % release.get("tag_name")
            ) from error
        if bound != contract_sha256:
            continue
        # The newest binding release decides; a refusal there is an error, never
        # a reason to fall back to an older catalogue.
        return release["tag_name"], admit(
            policy, contract_bytes, repository, hosts["github"], release, catalogue_bytes
        )
    return None


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


def stage(root, fetch):
    """Stage the binding catalogue; return the process exit code."""
    output = root / OUTPUT
    found = binding_catalogue(root, fetch, load_policy(root))
    if found is None:
        if output.exists():
            output.unlink()
        print(
            "[dev-ollama-catalogue] WARNING: no published release binds this clone's managed"
            " Ollama contract (%s changed since the last release); the developer app's owned"
            " Ollama install will refuse with OLLAMA_MANAGED_CATALOGUE_MISSING until a release"
            " publishes it." % CONTRACT,
            file=sys.stderr,
        )
        return NO_BINDING_RELEASE
    tag, data = found
    if output.exists() and output.read_bytes() == data:
        print("[dev-ollama-catalogue] Catalogue of %s already staged." % tag)
        return 0
    write_atomically(output, data)
    print("[dev-ollama-catalogue] Staged the verified catalogue of %s." % tag)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.parse_args()
    try:
        sys.exit(stage(ROOT, curl_fetch))
    except (CatalogueRefusal, OSError, ValueError, KeyError) as error:
        print("[dev-ollama-catalogue] ERROR: %s" % error, file=sys.stderr)
        sys.exit(1)
