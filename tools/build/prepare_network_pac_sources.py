"""Generate bounded PAC build inputs from canonical sources and a verified archive."""

import argparse
import hashlib
import json
from pathlib import Path
import tarfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def integer(value, name):
    if type(value) is not int or value <= 0 or value > 2147483647:
        raise ValueError(f"Invalid canonical positive integer: {name}")
    return value


def generate(repo, archive, output, msvc_function):
    catalog_path = "static/ergopti_plus/_shared/data/linux_native_runtime.json"
    policy_path = "static/ergopti_plus/_shared/modules/network/proxy_policy.json"
    defaults_path = "static/ergopti_plus/_shared/modules/updater/defaults.json"
    helper_path = "static/ergopti_plus/_shared/modules/network/pac_helpers.js"
    catalog = json.loads((repo / catalog_path).read_text(encoding="utf-8"))
    # The canonical Linux source authority already pins the shared JS VM.
    authorities = catalog["network_runtime"]["portable"]["flatpak_sources"]
    pin = authorities["duktape"]
    archive_bytes = archive.read_bytes()
    if sha256(archive_bytes) != pin["sha256"]:
        raise ValueError("Duktape archive identity refused")
    policy = json.loads((repo / policy_path).read_text(encoding="utf-8"))
    defaults = json.loads((repo / defaults_path).read_text(encoding="utf-8"))
    native = policy["native_pac"]
    limits = {
        "HEAP_BYTES": integer(native["max_heap_bytes"], "max_heap_bytes"),
        "SCRIPT_BYTES": integer(native["max_script_bytes"], "max_script_bytes"),
        "INPUT_BYTES": integer(policy["max_proxy_bytes"], "max_proxy_bytes"),
        "OUTPUT_BYTES": integer(policy["max_proxy_bytes"], "max_proxy_bytes"),
        "NATIVE_QUERIES": integer(native["max_native_queries"], "max_native_queries"),
        "LOOKUP_MS": integer(
            defaults["release_sources"]["proxy_resolve_timeout_sec"] * 1000,
            "proxy_resolve_timeout_ms",
        ),
    }
    helpers = (repo / helper_path).read_bytes()
    helpers.decode("utf-8", errors="strict")
    if (
        not helpers
        or len(helpers) > limits["SCRIPT_BYTES"]
        or b"\r" in helpers
        or b"\x00" in helpers
    ):
        raise ValueError("Canonical helper source refused")
    output.mkdir(parents=True, exist_ok=True)
    extracted = {}
    with tarfile.open(archive, "r:xz") as source:
        members = source.getmembers()
        for name in ["duktape.c", "duktape.h", "duk_config.h", "LICENSE.txt"]:
            expected = "duktape-2.7.0/" + ("src/" if name != "LICENSE.txt" else "") + name
            candidates = [member for member in members if member.name == expected]
            if len(candidates) != 1 or not candidates[0].isfile():
                raise ValueError("Pinned Duktape member inventory refused")
            with source.extractfile(candidates[0]) as member:
                extracted[name] = member.read()
            if not extracted[name] or len(extracted[name]) != candidates[0].size:
                raise ValueError("Pinned Duktape member receipt refused")
    config = extracted["duk_config.h"].decode("utf-8", errors="strict")
    replacements = {
        "#undef DUK_USE_EXEC_TIMEOUT_CHECK\n": '#include "pac_runtime.h"\n#define DUK_USE_EXEC_TIMEOUT_CHECK(udata) ergopti_pac_should_interrupt((void *)(udata))\n',
        "#undef DUK_USE_INTERRUPT_COUNTER\n": "#define DUK_USE_INTERRUPT_COUNTER\n",
    }
    for before, after in replacements.items():
        if config.count(before) != 1:
            raise ValueError("Pinned Duktape configuration preimage refused")
        config = config.replace(before, after)
    extracted["duk_config.h"] = config.encode("utf-8")
    for name, contents in extracted.items():
        (output / name).write_bytes(contents)
    fingerprint_files = [
        catalog_path,
        policy_path,
        defaults_path,
        helper_path,
        "static/ergopti_plus/_shared/native/network/pac_runtime.c",
        "static/ergopti_plus/_shared/native/network/pac_runtime.h",
        "static/ergopti_plus/windows/native/ergopti_network_pac_platform.c",
        "static/ergopti_plus/windows/native/ergopti_network_pac_platform.h",
        "static/ergopti_plus/windows/native/ergopti_network_pac.c",
        "tools/build/build_windows_nav_owner.ps1",
        "tools/build/build_windows_network_pac.ps1",
        "tools/build/prepare_network_pac_sources.py",
    ]
    identity = ["ergopti-network-pac-source-recipe-v1"]
    for index, name in enumerate(sorted(fingerprint_files)):
        contents = (repo / name).read_bytes()
        contents.decode("utf-8", errors="strict")
        if b"\r" in contents:
            raise ValueError("Canonical source line endings refused")
        identity.extend(
            [f"input[{index}].path={name}", f"input[{index}].sha256={sha256(contents)}"]
        )
    identity.extend(
        [
            "duktape.archive.sha256=" + pin["sha256"],
            "msvc.function.sha256=" + sha256(msvc_function.read_bytes()),
        ]
    )
    fingerprint = sha256(("\n".join(identity) + "\n").encode("utf-8"))
    header = [
        "/* Generated by prepare_network_pac_sources.py; never edit. */",
        "#ifndef ERGOPTI_PAC_GENERATED_H",
        "#define ERGOPTI_PAC_GENERATED_H",
    ]
    header.extend(f"#define ERGOPTI_PAC_{name} {value}u" for name, value in limits.items())
    header.append(f'#define ERGOPTI_PAC_SOURCE_FINGERPRINT "{fingerprint}"')
    header.append("static const unsigned char ergopti_pac_helpers[] = {")
    header.extend(
        "\t" + ",".join(str(byte) for byte in helpers[index : index + 32]) + ","
        for index in range(0, len(helpers), 32)
    )
    header.extend(["};", "#endif", ""])
    (output / "pac_generated.h").write_text("\n".join(header), encoding="utf-8", newline="\n")
    receipt = {
        "schema_version": 1,
        "source_fingerprint": fingerprint,
        "duktape_archive_sha256": pin["sha256"],
        "inputs": fingerprint_files,
        "generated_files": {name: sha256(contents) for name, contents in extracted.items()},
        "helper_bytes": len(helpers),
        "limits": limits,
    }
    (output / "source_receipt.json").write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    print("Prepared verified pinned PAC sources and generated absolute-clock configuration.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--msvc-function", required=True, type=Path)
    args = parser.parse_args()
    generate(args.repo, args.archive, args.output, args.msvc_function)
