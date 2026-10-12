<!-- docs/handovers/2026-10-12-dev-consolidation/pending-native-output-receiving.md -->

# Pending captured-clock and output serialization corrections

These two source corrections were implemented and tested in compact Linux
projections of `60001d60f99aaf30ed5e8a345972d671f47ea2f1`. They remain pending;
this delivery applies neither correction to the live native source or DLL.
Preserve the existing paired modifier patches and receive the complete source
union with a real official MSVC rebuild. Production admission remains false.

| Pending source patch                                                             | SHA256                                                             | Exact frozen source manifest                                              |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| [Captured-clock boundary](pending-capture-clock-half-range.patch)                | `8ee073d062ac1cbee2b29b228d45ebc44d802603e5eec3ac69ccb393b2baea1c` | [Clock manifest](capture-clock-half-range.manifest.json)                  |
| [Retained-output serialization](pending-owned-win32-payload-serialization.patch) | `c34435adcce905b74019fad3792f8b4a8ef6cdbda94ec8c1a78d640d808ee7ff` | [Serialization manifest](owned-win32-payload-serialization.manifest.json) |

The manifests retain the exact frozen source hashes and observations, including
historical scratch log locations as provenance. Those paths are not receiving prerequisites. Logs,
binaries, temporary reports and proof archives are not part of this delivery.
Commands below run from the repository root after coordinated source composition.

## Captured-clock boundary

The producer requires adjacent admitted DWORD times to differ by strictly less
than half a cycle. Its backward branch already rejects the exact half-range;
its forward branch incorrectly accepts it. The correction changes one `>` to
`>=`, preserving refusal, the previous clock anchor, effective source holds,
authentic raw capture, partial FIFO acceptance and shutdown debt.

Only `nav_event_owner.c` and its existing test change. Seven literal boundary
vectors generate 35 producer-seam edges. A subsequent valid UP proves rejected
metadata cannot advance the anchor or erase the hold. The five raw edges survive;
accepting two retains the exact three-edge suffix, which then retires in order.
All 1,352 original assertion calls remain; 31 are added within the existing
registered case. The complete original test bytes are recovered by removing its
single additive block. The census remains 44 native cases, 43 portable.

Actual Linux execution: original producer RED exit 1 at the new status assertion;
corrected selected case and all 43/43 portable cases PASS. Full
Address/Undefined/Leak sanitizers pass for the selected case. Two independent
compiled mutations, advancing the refused anchor and dropping the ambiguous raw
edge, are RED exit 1. These are production C and portable boundary results,
not real Windows hook ordering, SDK or physical qualification.

## Retained-output serialization

The pure serializer validates the existing owner, token, sequence, plan and
attempt, then copies the immutable attempted suffix into strict INPUT40 data.
Each logical unit becomes exactly one packet; the exact-prefix ACK API remains
unchanged. Unicode preserves literal DOWN/UP and stranded surrogate suffixes.
Native VK and scan axes stay separate; the scan extended bit is encoded in the
native flag. No repeat expansion, surrogate aggregation, discarded edge or
invented acceptance occurs.

Callers cannot supply a marker. Its existing authoritative definition moves to
the included output header without changing its name or value. Reserved/padding
bytes and time are zero. Unsupported architecture, pointer/endian layout,
malformed units, stale/foreign custody, capacity failure and writable aliases
refuse without changing state or caller outputs. Only x64/ARM64 little-endian
wire construction is supported; native deployment architecture policy is
unchanged. Receiving-source static assertions pin size, offsets and flags to the
actual Windows SDK. Those real SDK assertions remain Windows UNRUN.

Only `terminal_output_plan.c`, its header/test and `nav_event_owner.c/.h` change.
No native export or external ABI is added. The 124 original test assertions and
ordered bodies survive exactly; 66 are added. Six independently specified texts
exercise 26 accepted-prefix cohorts; eight LR families on both axes exercise
32 DOWN/UP edges from actual replay snapshots. Atomic refusal, maximum 2,048
packets, mutable external copies and cancellation debt are covered.

Actual Linux execution: 10/10 matrices PASS normally and with full sanitizers;
existing production C 43/43 PASS. Six cleanly compiled mutations fail assertions:
restart an accepted prefix, use a foreign marker, lose extended scan, omit
Unicode UP, accept stale attempt identity, and write before full validation.
The original producer lacks the API and gives link RED exit 1; this is missing
implementation evidence, not a claim of an executed original runtime defect.
The actual unsupported-architecture branch also refuses transactionally under
an explicitly forced compile predicate; no foreign CPU execution is claimed.
Independent review reproduces the hashes, assertion retention, normal/sanitizer
results, 43 cases and six mutation failures. No Windows sending was executed.

## Source composition and Windows receiving

Prerequisites: freshly synchronized coordinated source checkout, pinned Node
22.22.2, official MSVC x64/Windows SDK, stock PowerShell 5.1/.NET, and an
interactive Windows desktop for the existing native receiver matrix. Pinned
AutoHotkey 2.0.26 x64 is additionally required for the existing adapter selections;
`ERGOPTI_AHK_RUNTIME` must point to that executable. A Windows VM suffices for
these controlled compiler/API cases; no real keyboard is needed to establish
pure planner or SDK layout facts.

Verify each artifact against its frozen SHA256 before composition:

```powershell
$handover = 'docs/handovers/2026-10-12-dev-consolidation'
$patches = @{
    'pending-capture-clock-half-range.patch' = '8ee073d062ac1cbee2b29b228d45ebc44d802603e5eec3ac69ccb393b2baea1c'
    'pending-owned-win32-payload-serialization.patch' = 'c34435adcce905b74019fad3792f8b4a8ef6cdbda94ec8c1a78d640d808ee7ff'
    'pending-modifier-custody.patch' = '7e5990669183cf953f31660e881f6bf62baf4026d2b5f68f2378954559d0bfcf'
    'pending-modifier-consumer.patch' = 'eedef72cfd2e1fee4d605f195b1a4a6e890a7807e15c2ca34733865a9a17085d'
}
foreach ($name in $patches.Keys) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $handover $name)).Hash
    if ($actual -ine $patches[$name]) { throw "Pending source patch hash mismatch: $name" }
}
```

Compare the exact source preimages in the manifests with current source before
applying changes; drift requires source review. Compose the clock correction,
the two paired modifier patches and the serializer as separate reviewed causes.
Do not blindly apply all independent patches sequentially: the modifier and
serializer test diffs share the matrix-count footer. Preserve both additive
helper/call unions and all original assertions; report **11 matrices** after the
union, rather than choosing either 8 or 10. Eleven is the expected composed
census, not an execution already performed in the cloud. This delivery does not
provide a newly qualified combined binary or source seal.

After that reviewed source union is complete, receive it using the official
owner. These commands stop on a failed external child:

```powershell
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
if ($LASTEXITCODE -ne 0) { throw 'Official native rebuild failed.' }
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
if ($LASTEXITCODE -ne 0) { throw 'Native artifact provenance verification failed.' }
& .\static\ergopti_plus\windows\build\native\nav_event_owner\ergopti_terminal_output_plan_test.exe
if ($LASTEXITCODE -ne 0) { throw 'Native output-plan receiving failed.' }
& .\static\ergopti_plus\windows\build\native\nav_event_owner\ergopti_nav_event_owner_test.exe
if ($LASTEXITCODE -ne 0) { throw 'Native FIFO/core receiving failed.' }
node tools/test/test-windows-terminal-output-custody-adapter.cjs
if ($LASTEXITCODE -ne 0) { throw 'Output custody source controls failed.' }
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only todo49-output
if ($LASTEXITCODE -ne 0) { throw 'Original AHK output cohort failed.' }
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only todo49-natural-custody
if ($LASTEXITCODE -ne 0) { throw 'Natural zero-unit custody cohort failed.' }
node tools/test/test-ahk-full-startup-smoke.cjs
if ($LASTEXITCODE -ne 0) { throw 'Source-bound native startup failed.' }
```

Expected: 11 output matrices, unchanged 44-case native census including the
Windows-only editor receiver, all existing route/trace cases, eighteen source
controls and 98 newly authored natural-custody AHK cases. Keep the original
output cohort intact and report its measured count. Native output/AHK cases,
actual Windows SDK pins, rebuilt DLL/manifest and full source fingerprints all
remain **UNRUN** for these new source patches. A preceding DLL receipt qualifies
only its preceding recipe; never restamp it from Linux or activate only the
changed zero-unit AHK consumer against that DLL.

The portable receiving commands, after coordinated source composition, remain:

```sh
node tools/test/run-nav-event-owner-portable.cjs 'terminal route snapshots retain exact suffix (todo49-route-fifo)'
node tools/test/run-nav-event-owner-portable.cjs
node tools/test/test-windows-nav-portable-registration.cjs
node tools/test/run-windows-terminal-output-plan.cjs
node tools/test/run-windows-terminal-output-plan.cjs --sanitize
```

Expected: selected C 1/1, full portable C 43/43, unchanged 44-case source census,
and 11 composed planner matrices; genuine Windows qualification remains absent.

## Software and physical work still open

The lock-held public DLL/consumer bridge does not invoke the serializer yet.
It must authenticate the current FIFO head using the existing native receipt,
copy the retained attempt under its serialized owner and expose that matching
receipt. Emitter orchestration must retain unknown/reentrant outcomes and report
only the exact accepted input prefix before existing ACK/consumption can retire
any original edge. The bridge, emitter and complete nonhook handler/observer
conversion remain **software work**, including dead keys, prefixes, tap-holds,
Caps/AltGr/direct-digit and pre-registration holding owners. No claim of complete
production migration or container-work exhaustion is made.

Real native observations must establish actual callback/delivery contracts,
receiving text, hook reinstallation effects and backend measurements before
choosing SendEvent versus SendInput. Known synthetic trace lanes observe injected
callbacks and cannot qualify physical capture. Bounded keyboard holds, overlapping
external/physical modifier custody and actual suppression need a real keyboard
or an honestly described VM keyboard channel. Screen/DPI, UIA and installed-app
acceptance remain separate. Preserve closed production admission and keep TODO49
open through software integration and the required native/physical receiving.
