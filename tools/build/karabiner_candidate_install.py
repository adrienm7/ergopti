# tools/build/karabiner_candidate_install.py
"""Check a retained fork package before and after installation on a hosted Mac."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from karabiner_candidate import PRODUCTS, REVISION, inspect_product, native
from hs274_runtime import runtime_paths
from hs274_hammerspoon import read_clock


FIXTURE = Path(__file__).resolve().parents[1] / "diagnostics/fixtures/hs274-native-package-identity.json"
MARKER = "ergopti-candidate.json"


def digest(path):
    """Hash the bytes rather than trusting a version or installation marker."""
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def reference():
    """Load the exact successful native producer selected for installation tests."""
    receipt = json.loads(FIXTURE.read_text(encoding="utf-8"))
    identity = receipt["identity"]
    if (identity["kind"] != "ergopti-karabiner-candidate" or identity["coverage"] != "fixture_only"
            or identity["upstream_revision"] != REVISION
            or not re.fullmatch(r"[0-9a-f]{40}", receipt["producer_revision"])
            or any(type(receipt[key]) is not int or receipt[key] <= 0
                   for key in ("run_id", "artifact_id", "package_bytes"))):
        raise ValueError("Invalid native candidate provenance")
    expected = ["src/" + component + "/build/Release/" + name for component, name in PRODUCTS]
    if [row["product"] for row in identity["products"]] != expected:
        raise ValueError("Native candidate does not cover every current product")
    filename = identity["package"]["file_name"]
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.dmg", filename)
            or not re.fullmatch(r"[0-9a-f]{64}", identity["package"]["sha256"])):
        raise ValueError("Invalid native candidate package identity")
    return receipt


def verify_download(directory, receipt):
    """Reject different metadata or image bytes before any privileged command."""
    directory = Path(directory).resolve()
    identity_file = directory / "identity.json"
    if not identity_file.is_file() or identity_file.resolve() != identity_file:
        raise ValueError("Missing or redirected candidate identity")
    identity = json.loads(identity_file.read_text(encoding="utf-8"))
    if identity != receipt["identity"]:
        raise ValueError("Downloaded identity differs from the accepted native producer")
    image = directory / identity["package"]["file_name"]
    if not image.is_file() or image.resolve() != image:
        raise ValueError("Missing or redirected candidate image")
    if image.stat().st_size != receipt["package_bytes"] or digest(image) != identity["package"]["sha256"]:
        raise ValueError("Downloaded candidate image does not match the native receipt")
    return image


def configuration_snapshot(directory):
    """Retain every existing configuration entry; later additions are permitted."""
    directory = Path(directory)
    snapshot = {}
    def reject_unreadable(error):
        raise error

    entries = (Path(parent) / name
               for parent, directories, files in os.walk(directory, onerror=reject_unreadable, followlinks=False)
               for name in directories + files)
    for path in sorted(entries):
        name = path.relative_to(directory).as_posix()
        if path.is_symlink():
            snapshot[name] = {"kind": "link", "target": os.readlink(path)}
            if path.is_file():
                snapshot[name]["sha256"] = digest(path)
            elif path.is_dir():
                raise ValueError("Directory aliases are outside this configuration fixture")
        elif path.is_file():
            snapshot[name] = {"kind": "file", "sha256": digest(path)}
        elif not path.is_dir():
            raise ValueError("Unexpected special configuration entry")
    if "karabiner.json" not in snapshot:
        raise ValueError("Configuration preservation requires an existing profile")
    return snapshot


def verify_configuration(before, after):
    """A successful installer may not reset or remove preexisting user data."""
    if not before or "karabiner.json" not in before:
        raise ValueError("Configuration baseline is empty")
    changed = [name for name, value in before.items() if after.get(name) != value]
    if changed:
        raise ValueError("Installer changed existing configuration: " + ", ".join(changed))


def verify_installed(base, applications, identity, verify=native):
    """Verify the actual installation, independently of a copied marker file."""
    base, applications = Path(base).resolve(), Path(applications).resolve()
    marker = base / MARKER
    if not marker.is_file() or marker.resolve() != marker:
        raise ValueError("Missing or redirected installed candidate identity")
    # The image checksum is assigned after assembly and cannot be inside itself.
    installed_identity = {key: value for key, value in identity.items() if key != "package"}
    if json.loads(marker.read_text(encoding="utf-8")) != installed_identity:
        raise ValueError("Installed candidate marker differs from the native producer")
    observed = []
    for (component, name), expected in zip(PRODUCTS, identity["products"], strict=True):
        parent = applications if component in ("apps/SettingsWindow", "apps/EventViewer") else base
        if component == "bin/cli":
            parent = base / "bin"
        product = parent / name
        actual = inspect_product(product, verify)
        relative_executable = Path(expected["executable"]).relative_to(expected["product"])
        if actual["executable"] != product / relative_executable:
            raise ValueError("Installed executable identity changed")
        for key in ("sha256", "architectures", "team_identifier"):
            if actual[key] != expected[key]:
                raise ValueError("Installed candidate differs at " + component + ": " + key
                                 + "; expected " + repr(expected[key]) + ", observed " + repr(actual[key]))
        actual["product"] = str(product)
        actual["executable"] = str(actual["executable"])
        observed.append(actual)
    return observed


def hosted_runtime():
    """The installation fixture is never a local-user bootstrap command."""
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or os.environ.get("HS274_DEVELOPMENT_ROOT")):
        raise RuntimeError("Installed-candidate acceptance requires a hosted macOS runner")
    paths = runtime_paths()
    return paths, paths["core_app"].parent


def before_install(output, receipt):
    """Establish an official installed baseline with real configuration data."""
    paths, base = hosted_runtime()
    if (base / MARKER).exists():
        raise ValueError("Expected the official remapper before candidate installation")
    expected_cli = next(row for row in receipt["identity"]["products"] if row["product"].endswith("/karabiner_cli"))
    if digest(paths["cli"]) == expected_cli["sha256"]:
        raise ValueError("Candidate CLI is already installed")
    native(["/usr/bin/codesign", "--verify", "--strict", str(paths["cli"])])
    configuration = Path.home() / ".config/karabiner"
    profile = configuration / "karabiner.json"
    seeded = not profile.exists()
    if seeded:
        configuration.mkdir(parents=True, exist_ok=True)
        data = {"global": {"check_for_updates_on_startup": False},
                "profiles": [{"name": "HS274 preserved installation profile", "selected": True,
                              "simple_modifications": [], "complex_modifications": {"rules": []}}]}
        with profile.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream)
            stream.write("\n")
    baseline = {"official_cli_sha256": digest(paths["cli"]), "configuration_path": str(configuration),
                "configuration": configuration_snapshot(configuration), "profile_seeded": seeded}
    Path(output).write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8", newline="\n")


def after_install(baseline, output, receipt):
    """Record installation integrity without claiming live physical-stream proof."""
    paths, base = hosted_runtime()
    before = json.loads(Path(baseline).read_text(encoding="utf-8"))
    products = verify_installed(base, Path("/Applications"), receipt["identity"])
    after = configuration_snapshot(before["configuration_path"])
    verify_configuration(before["configuration"], after)
    clock = json.loads(native([str(paths["cli"]), "--hs274-clock"]))
    read_clock(clock)
    result = {"kind": "installed-candidate-integrity", "producer_run": receipt["run_id"],
              "products": products, "configuration_preserved": True, "clock": clock,
              "physical_stream_verified": False}
    Path(output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("selection", "download", "before", "after"))
    parser.add_argument("paths", nargs="*")
    arguments = parser.parse_args()
    receipt = reference()
    if arguments.mode == "selection" and not arguments.paths:
        print("run_id=" + str(receipt["run_id"]))
        print("artifact_name=hs274-producer-build-" + receipt["producer_revision"])
    elif arguments.mode == "download" and len(arguments.paths) == 1:
        print("image=" + str(verify_download(arguments.paths[0], receipt)))
    elif arguments.mode == "before" and len(arguments.paths) == 1:
        before_install(arguments.paths[0], receipt)
    elif arguments.mode == "after" and len(arguments.paths) == 2:
        after_install(*arguments.paths, receipt)
    else:
        parser.error("invalid mode arguments")
