<!-- tools/diagnostics/apple_shortcuts_installed_target/README.md -->

# Installed Shortcuts Events metadata diagnostic

Resolve only `com.apple.shortcuts.events` with the public LaunchServices
`LSCopyApplicationURLsForBundleIdentifier` lookup. The resolver starts no target
and sends no AppleEvent. A single local installed bundle is required; absent,
ambiguous or nonlocal results refuse. Read only its exact retained Info.plist and
resource explicitly declared by OSAScriptingDefinition/NSScriptingDefinition.
No directory scan, resource guessing, dictionary parsing or CLI catalogue fallback
is used. The declared-key policy obtains raw requested metadata; it does not
certify official dictionary/event semantics or whether the target is running.

The collector loads validated retained bytes of the original native process
owner and Root probe, never cached pyc or a later source reopen. Fixed hashes
refuse dependency drift. No-follow descriptors retain ancestors, source files and
the private output directory; replacement and secondary-receipt failures refuse
without replacing a pending original cancellation/retirement error. Original
20-second capture and 65,536-byte bounds remain unchanged. An original native_exit
refusal does not identify an absent target or TCC cause: nonzero resolver stdout
is not admitted by the unchanged original capture.

Portable enrollment is `node tools/test/test-apple-shortcuts-installed-target.cjs`.
Its exact nineteen reader plus fifteen loader/output tests pass in the current
portable controls, with unchanged source before/after. They exercise
real controlled filesystem operations, not LaunchServices or native process
custody. Windows performs explicit structural-only checks: POSIX descriptor
controls are UNRUN_UNSUPPORTED, never 34 green. The strict ordinary Python children
have separate 60-second/output bounds; they provide no native family qualification.

Native receiving requires macOS, Python3.13 with Darwin nonreaping wait APIs,
installed Xcode/Command Line Tools and the actual SDK/compiler selected by xcrun.
The proposed workflow observes both existing arm64/amd64 native matrix rows only
on manual nonrelease runs, under !cancelled, at the END of managed-ollama-native.
All original qualification steps run first and their failures remain failures.
Cancellation or the unchanged job deadline can still prevent late observation.
The raw-retention step keeps source/build hashes, raw compiler/collector statuses
and private observation evidence. Compiler hashes attest build integrity only,
not signing identity, osascript's principal, consent or SDK authorization.

After adoption and owner-authorized native execution, the receiving commands are:

```sh
diagnostic=tools/diagnostics/apple_shortcuts_installed_target
sdk="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --find swiftc)"
"$compiler" -O -sdk "$sdk" -framework Foundation -framework CoreServices \
  "$diagnostic/resolve_installed_target.swift" -o "$RUNNER_TEMP/installed-target-resolver"
resolver_sha="$(shasum -a 256 "$RUNNER_TEMP/installed-target-resolver" | cut -d ' ' -f 1)"
python3 -B "$diagnostic/collect_installed_target.py" \
  --source-root "$GITHUB_WORKSPACE" --resolver "$RUNNER_TEMP/installed-target-resolver" \
  --resolver-sha256 "$resolver_sha" --output "$RUNNER_TEMP/installed-target-observation"
```

Use a fresh absolute nonsymlink output destination and the reviewed source/build
checks; these example commands do not replace the strict workflow status receipts.
Retained Info/dictionary bytes may contain private metadata: keep only in bounded
private artifacts, never public logs or a product catalogue. Every catalogue,
permission, invocation and running-target qualification flag remains false.

Current status: formatted collector/guard and end-only placement have independent
source reviews; actual portable 19+15 passed. Native build, installed-target LS
resolution and metadata execution are UNRUN. No result explains the existing
app.shortcuts() stall, grants consent or qualifies native catalogue/invocation.
Item 106 and its original requirements remain partial. This diagnostic complements
the original JXA/SDK observer; it does not replace its principal or checkpoints.
