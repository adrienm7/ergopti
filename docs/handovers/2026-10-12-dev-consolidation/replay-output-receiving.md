<!-- docs/handovers/2026-10-12-dev-consolidation/replay-output-receiving.md -->

# Pending replay-core writable output protection

The [source patch](pending-replay-output-protection.patch) fixes an actual
memory-custody defect in `ErgoptiReplay_Step` and `ErgoptiReplay_PrepareNativeEdge`.
It is preserved on dev, with its tests, but is not applied to live DLL recipe
inputs. [The source inventory](replay-output-protection.manifest.json) records
all three exact preimages/postimages and the patch digest. No ABI, export,
activation, runner, vendor artifact or emission policy changes.

`Step` cleared an output overlapping its live state before checking ownership.
`PrepareNativeEdge` cleared an output overlapping state or its immutable input
snapshot before reading those values. Both now reject intersecting half-open
spans and address overflow before writing. A refused protected output receives
no status write. Ordinary nonalias refusal/clearing remains unchanged; legitimate
incoming-event/output reuse remains supported.

An independently compiled behavioral caller proves the original wrong-owner
call erased an initialized registered Shift hold: status -2, preserved=false,
initialized=0, owner=0, exit 1. The corrected caller preserves every state byte:
status -1, preserved=true, initialized=1, owner=85, exit 0. This is actual pure C
execution on Linux/x64, not a source assertion. The additive production tests
preserve all 108 original assertion calls/order and add 32. Eight core matrices,
43 production-C/POSIX-shim cases, seven neighboring output-plan matrices, and
the core/43-case full sanitizers pass with assertions and leak checks active.
The genuine original with the new tests fails; five compiled guard mutations
also fail. The first sanitizer attempt encountered LeakSanitizer's ptrace
restriction; the identical executable passed outside that sandbox.

## Reproduce and receive

Before applying, synchronize dev and verify the frozen source preimages. This
patch is independent of the pending modifier, clock and serializer cuts; review
any shared test composition rather than discarding additive assertions.

```powershell
$replayFolder = 'docs/handovers/2026-10-12-dev-consolidation'
$replayInventory = Get-Content "$replayFolder/replay-output-protection.manifest.json" -Raw | ConvertFrom-Json
$replayPatch = "$replayFolder/pending-replay-output-protection.patch"
if ((Get-FileHash $replayPatch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $replayInventory.patch_sha256) { throw 'Replay patch identity changed.' }
foreach ($replayFile in $replayInventory.changed_files.PSObject.Properties) {
    if ((Get-FileHash $replayFile.Name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $replayFile.Value.before_sha256) { throw "Replay preimage changed: $($replayFile.Name)" }
}
git apply --check $replayPatch
if ($LASTEXITCODE -ne 0) { throw 'Replay patch composition failed.' }
git apply $replayPatch
if ($LASTEXITCODE -ne 0) { throw 'Replay patch application failed.' }
foreach ($replayFile in $replayInventory.changed_files.PSObject.Properties) {
    if ((Get-FileHash $replayFile.Name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $replayFile.Value.after_sha256) { throw "Replay postimage changed: $($replayFile.Name)" }
}
```

With the pinned Node/compiler available, these existing owners reproduce the
portable regressions from the applied checkout:

```text
node tools/test/run-windows-replay-route-core.cjs
node tools/test/run-windows-replay-route-core.cjs --sanitize
node tools/test/run-nav-event-owner-portable.cjs
node tools/test/run-windows-terminal-output-plan.cjs
```

Expected portable results: 8/8 core, 43/43 owner cases (the native-only editor is
excluded), 7/7 output-plan matrices, each actual exit 0. Combined pending output
patches can increase the output-plan census; retain every original matrix.

Native Windows MSVC/SDK/DLL receiving is UNRUN. On a Windows x64 build VM with
the repository's required MSVC/Windows SDK installed, compose the reviewed cuts
and regenerate through the official owner before committing active sources:

```powershell
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
if ($LASTEXITCODE -ne 0) { throw 'Native rebuild failed.' }
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
if ($LASTEXITCODE -ne 0) { throw 'Native provenance verification failed.' }
```

Expect all 44 native registered cases, strict compilation and matching generated
DLL/manifest. Preserve the existing source/DLL recipe relationship until this
actual rebuild completes; do not restamp the E4133 artifact from Linux.
A native desktop session is needed for the editor case. Physical keyboard,
real hook ordering, effective modifiers, app behavior and backend measurements
remain separate receiving. No macOS native qualification is claimed.

Item 49 remains open. Full pre-registration/nonhook observer conversion and
production emission are still software work, independently of this correction.

## Delivery gate limit

The canonical selected gate on `ae684ed72` finishes with formatting exit 0
(393 files) and JS 423/426, actual exit 1. The three failures are retained:
`test-lua-gsub-single-return.cjs` classifies an already-parenthesized concatenation;
`test-layouts-defaults-single-source.cjs` classifies a pure macOS ISO metadata
lookup as a download client; `test-linux-uninstall-sandbox.cjs` refuses its
`--check` fixture preflight (line 114, status 1). The unchanged isolated uninstall
owner then exits 0. Its original failure is not erased or called a green suite.
No production, test, runner or workflow source changes in this documentation-only
checkpoint. Root owns the outstanding source-guard/infrastructure work.
