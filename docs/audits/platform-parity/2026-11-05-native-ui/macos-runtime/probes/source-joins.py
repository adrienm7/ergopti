#!/usr/bin/env python3
"""Read-only source assertions and navigation. These do not qualify native runtime behavior."""

import argparse, hashlib, json, pathlib, subprocess

p = argparse.ArgumentParser()
p.add_argument("source_root")
args = p.parse_args()
root = pathlib.Path(args.source_root).resolve()
expected = "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
assert (
    subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() == expected
)
checks = {
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedRuntimeDownloadedHelper.swift": [
        'guard receipt == Data((pin.sha256 + "\\n").utf8) else { return .failure(.receiptMismatch) }',
        "let selection = LuaSourceSelection.resolve(",
        "guard let home = accountHome()",
        "let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)",
    ],
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedRuntimeFirstInstallOwner.swift": [
        'guard fstatat(parentDescriptor, "Runtime", &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { throw OwnedRuntimeInstallFailure.destination }',
        "try scratch.publishRuntime()",
        "state = .filesPublished",
    ],
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedRuntimeIdleServiceEntry.swift": [
        "try publication.publishFirstInstallation()",
        "result = .filesPublishedServiceCleanupPending",
        "let core = try provision.provisionAndStartCore()",
        "try OwnedRuntimeVirtualHIDProvisionOwner.provision(within: provision)",
    ],
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedRuntimeInstallMainOperation.swift": [
        "switch OwnedRuntimeDownloadedHelper.current()",
        "driverStep = Self.driverProgram(package)",
        'driverStep + "task_status=0;',
        " --owned-install-first)",
        "let source = try OwnedRuntimeInstallTree(root: helper, protected: false)",
        "SecCertificateCopyData(certificate) as Data == publisher.leaf",
    ],
    "static/ergopti_plus/macos/platform/remap/init.lua": [
        "runtime_job_not_loaded = true,",
        "function M.install_owned_runtime(on_done)",
    ],
    "static/ergopti_plus/macos/platform/remap/runtime_artifact_fetch.lua": [
        'receipt:match("^(%x+)") ~= pin.sha256',
        "if kept(home, pin) then",
    ],
    "static/ergopti_plus/macos/ui/menu/menu_tap_holds.lua": [
        "runtime_job_not_loaded = NOT_INSTALLED,",
        'require("ui.owned_runtime_install").open(karabiner)',
    ],
}
result = {"audited_sha": expected, "kind": "source joins only, not native execution", "sources": []}
for relative, needles in checks.items():
    raw = (root / relative).read_bytes()
    text = raw.decode()
    found = []
    for needle in needles:
        assert needle in text, (relative, needle)
        found.append({"line": text[: text.index(needle)].count("\n") + 1, "text": needle})
    result["sources"].append(
        {"path": relative, "sha256": hashlib.sha256(raw).hexdigest(), "joins": found}
    )
print(json.dumps(result, indent=2))
