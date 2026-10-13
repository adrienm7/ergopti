<!-- docs/handovers/2026-10-12-dev-consolidation/terminal-complete-receiving.md -->

# Coherent Windows terminal source receiving

This is implemented source awaiting Windows artifact integration, not an active
production backend. The complete union contains 19 source/test paths (including two new files):
the modifier-custody planner, replay output protection, half-range event clock,
owned INPUT40 serializer, authenticated locked bridge, modifier consumer, packet
receiver, immutable original custody identity, explicit sender, captured KLE reset
observer recipe and both existing
feature guards. The standalone receiver requires an explicit CLI opt-in. It retains all original assertions
and registrations. Use the accompanying manifest's exact preimages and apply
the union once; do not also apply its constituent patches.

The active tracked DLL still has 40 exports. This union adds the authenticated
serializer as the 41st export and requires the matching mandatory AHK binding.
Do not apply that adapter against the old DLL, fabricate a source seal, or
disable qualification to enable it. Only the official Windows SDK/MSVC builder
may regenerate the tracked DLL and its manifest. Production cohort admission
remains false, and the receiver has only an explicit injected emission port.

## Container receipts

The actual composed C source passes eight replay matrices, eleven output
matrices and all 43 portable native-owner cases, with exit 0 for each runner.
Full address/undefined/leak sanitizers retain assertions and pass the output
matrices, real bridge fault harness and all 43 owner cases. This executes Linux
C and a POSIX thread boundary; it does not qualify Windows critical sections,
INPUT delivery, hook order or an SDK DLL. The native census still has 44 cases.

The combined receiving guard passes all 119 source inverse controls: the 59
original/modifier/packet controls, eight original-authority controls and 26
explicit sender/receiving controls, 21 KLE publication/recipe controls and five
actual copy-hook controls. The copy fixture now uses the real
`observe_terminal_output_packet_copy` key; its 48 affected vectors actually
reach the injected callback instead of an unrelated Map entry. The bridge guard retains 13 originals and adds 14
inverses (27 total). Exact native/CDECL widths, locked authentication, output
alias refusal, detached packet bytes and reentrant record identity are covered.
The old AHK test file has 23 enrolled cases; 98 modifier and 212 packet cases
bring the earlier authored file to 333. A further 123 immutable-authority and
211 explicit-sender cases bring the file to 667. All 667 cases and both standalone
native receiving vectors are UNRUN under native AHK in this container. Source controls do not count as executed AHK tests. The separate KLE unit adds
91 authored, UNRUN cases. Its captured factory is published only after complete
registration and final criterion cleanup. The recipe is read-only metadata; it
does not authenticate a captured event, mutate live KLE state, emit input or
acknowledge a FIFO.

## Windows VM commands

Use an isolated current dev checkout, official MSVC x64 and Windows SDK through
the existing builder, PowerShell 5.1, pinned Node 22.22.2 and AutoHotkey 2.0.26.
Preserve unrelated changes. From the repository root, verify the source images
before and after applying the one union:

```powershell
$Evidence = 'docs/handovers/2026-10-12-dev-consolidation'
$Manifest = Get-Content "$Evidence/terminal-complete-union.manifest.json" -Raw | ConvertFrom-Json
$Patch = "$Evidence/pending-terminal-complete-union.patch"
if ((Get-FileHash $Patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Manifest.patch_sha256) { throw 'Union patch hash mismatch' }
foreach ($Image in $Manifest.paths.PSObject.Properties) {
    if ($null -eq $Image.Value.before_sha256) {
        if (Test-Path $Image.Name) { throw "Expected absent new path: $($Image.Name)" }
    } elseif ((Get-FileHash $Image.Name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Image.Value.before_sha256) {
        throw "Preimage mismatch: $($Image.Name)"
    }
}
git apply --check $Patch
if ($LASTEXITCODE -ne 0) { throw 'Union preflight refused' }
git apply $Patch
if ($LASTEXITCODE -ne 0) { throw 'Union application failed' }
foreach ($Image in $Manifest.paths.PSObject.Properties) {
    if ((Get-FileHash $Image.Name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Image.Value.after_sha256) { throw "Postimage mismatch: $($Image.Name)" }
}
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
if ($LASTEXITCODE -ne 0) { throw 'Official native rebuild failed' }
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
if ($LASTEXITCODE -ne 0) { throw 'Native provenance verification failed' }
```

Require the builder's eight replay/eleven output matrices, all 44 native-owner
cases, unchanged hook-trace matrices and an exact 41-export hardened x64 DLL.
Inspect its actual source fingerprint and publish source/DLL/manifest coherently
only after these native checks. Then run each following command and require its
own exit 0; a final successful command cannot hide an earlier failure:

```powershell
node tools/test/test-windows-terminal-output-custody-adapter.cjs
node tools/test/test-windows-hook-trace-source.cjs
node tools/test/test-ahk-encoding.cjs
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo49-packet-receiving
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo49-natural-custody
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo49-output-custody-adapter
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo49-output-consumer
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo49-frozen-authority
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=todo49-explicit-sendinput
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=kle-reset-observer
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=layout-registry-emulation
node tools/test/test-ahk-full-startup-smoke.cjs
```

Require exactly 212 new packet cases, 98 modifier cases, 12 original custody
cases, 11 original consumer cases, 123 authority cases and 211 sender cases,
without skips or unexecuted selections. Also require 91 new KLE observer cases
and all existing layout-registry-emulation cases. A source guard success cannot
substitute for any of these AHK receipts.
Set ERGOPTI_AHK_RUNTIME to the actual pinned executable. These callback cases
use injected ports even on Windows; separately receive actual CDECL/SDK INPUT
bytes and native output behaviour. In particular, receive right Control/Alt/Win
VK interpretation and extended scan semantics before backend activation.

A Windows VM suffices for compiler, ABI, DLL, callback and startup receiving.
A separate standalone fixture is available after explicit operator authorization:

```powershell
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/fixtures/terminal_output_sendinput_receiving_fixture.ahk --allow-explicit-user32-sendinput
if ($LASTEXITCODE -ne 0) { throw 'Inspect retained native receiving evidence' }
```

Use an idle interactive Windows desktop with production Ergopti and other input
automation stopped, modifiers released, and attention on the fixture-owned Edit.
Require literal `a`, one emoji and the natural exit receipt `code=0 vectors=2
native_calls=2`. It uses real user32/GUI receiving with injected source planning,
serializer and FIFO. Missing opt-in exits 2 before GUI/input. Partial or unknown
output retains the owned process/window; no forced kill or guessed cleanup. This
is not production backend or physical qualification.

Production emission selection, preregistration and non-hook observer migration
still contain software work; this union does not declare them complete. Real
keyboard mixtures, both actual hook orders, UIPI/installed applications, IME,
UTF-16 rendering, display/DPI/UIA and physical input require separate native or
device acceptance. Choose SendEvent versus SendInput only after actual Windows
measurements. TODO 49 remains partial.
