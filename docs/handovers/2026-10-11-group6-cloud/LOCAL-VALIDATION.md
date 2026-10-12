# Group6 existing local native qualification procedure

Source-bound to 1f764e33fa9711787b54fb4718a8e1575ac12df4. This is an inventory/design, not an executed qualification. source-binding.json records24 actual committed entry-point/recipe cuts; canonical-steps.json records22 exact workflow step bodies including their env/conditions/step and job budgets. The source copies contain the original code and assertions. They introduce no alternative test tree or expectation corpus.

## Common receiving order

1. Use the existing reviewed checkout and preserve its index/worktree. Record actual Git HEAD/tree, status and relevant native source hashes before setup/build. Install the repository's pinned Node and frozen dependencies. Do any required generator work under its original ownership before sealing source; JS/native source-drift writers never run concurrently. Create a new owned private evidence directory with restricted permissions. Keep capability observations, actual command/exit, raw outputs and before/final source receipts distinct.
2. Admit the actual OS/toolchain/session, package/runtime pins and required fixture privileges. A process or installed executable alone is insufficient: observe the original runner's real completion and native closure. Windows certificate store and macOS private keychain/owned Automation operations must use the actual original fixture cleanup. Missing native APIs, authority or GUI are failed admission or UNEXECUTED blockers, never a stubbed pass.
3. Execute only existing entry points with their original selectors/assertions and inner clocks. Retain outputs after original owners acknowledge exit/capture/descendant retirement. A timeout/refused settle retains ownership debt and artifacts; a digest or source snapshot cannot authorize deletion. Existing suite/manifest receivers consume their original expected labels and reject incomplete or skipped qualification. Never generate expectations from new implementation output.
4. Record PASSED, FAILED, SKIPPED and UNEXECUTED individually. PASSED requires every expected case and original cleanup/exit checks. Record actual suite skips/deferred disposition explicitly as unqualified scope. An unstarted case remains UNEXECUTED; a started nonterminal case is separately pending/failed and cannot be counted as a pass. Whole-unit, native E2E, compiled packaging/install and source qualification are separate results. Local execution does not automatically reproduce a GitHub outer step timer.

## Windows enterprise network and updater

Prerequisites: actual Windows x64, the pinned AutoHotkey runtime/compiler contracts, MSVC x64 environment resolved by the original builder, Node, Python and a real interactive desktop where the fixture requires native controls. Use the original current-user SSPI/owned proxy/native event fixtures through their AHK owners; standalone background fixture commands are not a qualification procedure. The workflow's real LocalMachine fixture-root scope needs its corresponding privilege. Do not automatically change Defender or substitute CI machine settings on a local host.

Existing compiler commands are `./tools/build/build_windows_nav_owner.ps1` and `./tools/build/build_windows_network_pac.ps1 -Publish`. The first does not alter tracked DLLs unless its explicit UpdateTracked switch is used. The second legitimately replaces exactly the PAC vendor exe/json; LICENSE must remain unchanged. Before Publish qualification, independently enroll the actual original complete committed source profile and genuine prebuild/publisher/postbuild receipts. Preserve original Git blobs separately from the two authenticated runtime outputs; all other tracked sources and current21 updater pins remain exact. The saved historical Root f1db map matches19/21 current pins and cannot authorize them. A compile without Publish can exercise the existing core build checks, but cannot qualify the actual published worker bytes used by the full AHK receiving.

Canonical unit commands, with `$ahk` obtained and verified from the actual runtime contract:

```powershell
node tools/test/test-ahk-suite-manifest.cjs --ahk $ahk
& $ahk /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk
node tools/test/validate-ahk-suite-manifest.cjs --input $env:ERGOPTI_AHK_RESULTS_FILE --json "$g6Evidence/windows-unit-manifest.json"
```

Set ERGOPTI_AHK_RESULTS_FILE to a fresh owned capture path before invocation. The actual workflow uses Start-Process/retained native handle/WaitForExit; reuse that exact receiving body from canonical-steps.json when collecting exit and file receipts. The runner preserves its1320000ms maximum watchdog and count-derived budget. The existing25minute step boundary is a separate supervisor obligation; a new wrapper must not renew it or claim it exists in a bare local command. verify-change already runs the existing unit/E2E entry points and rejects incomplete manifests, but its temporary TAP cleanup is not durable release evidence.

The supplemental original23 runner and both shared native PAC receiver modules are absent from canonical source at this commit. Their held preparation remains UNADOPTED. Activation requires exact current-source/loader ownership, strict held-reader composition, genuine source_receipt/MSVC/prepared/header/command evidence, original18/4/1 oracle and exact2307-byte child, unchanged300000ms shared budget/30000ms disposal and late-consumer receiving. Do not create a new cohort or narrow full-unit coverage to avoid its earlier Root configuration-restoration failure.

Existing E2E commands use the same shipped interpreter:

```powershell
& $ahk /ErrorStdOut static/ergopti_plus/windows/tests/e2e/run_e2e.ahk
node tools/test/validate-ahk-e2e-manifest.cjs --input static/ergopti_plus/windows/tests/e2e/test_results.txt
```

The actual E2E step owns its5minute outer boundary. Windows packaging uses the existing fresh-workspace Generate features/static bundle/version stamping/authenticated compiler/Compile/Sign steps. A prior unit workspace carries test caches and must not become package input. After compiling and obtaining the original startup receipt, installed-upgrade acceptance is already callable:

```powershell
./tools/test/run-compiled-save-upgrade.ps1 -Executable $compiledExe -Checkout $reviewedCheckout -StartupEvidence $originalStartupEvidence -EvidenceDirectory $freshUpgradeEvidence
```

This owner receives the pinned published prior release, actual compiled auto-execute path, real installed user state/full save and native process-tree cleanup. It requires actual checkout SHA/startup evidence. Its original120second boot/5second idle clocks and10minute outer step stay intact. Interpreted AHK success does not qualify compilation or installation. Do not invoke release publication/signing APIs as part of this procedure.

## macOS archive, Sparkle and Brew

Run on actual macOS with Xcode/Swift, codesign/Security, Homebrew, SIGN*UPDATE pinned to Sparkle2.9.2 and CPython>=3.13 with waitid/P_PID/WEXITED/WNOHANG/WNOWAIT/CLD*\* support. Observe `launchctl print "gui/$(id -u)"`, `sw_vers`, `xcodebuild -version`, `swift --version`, actual Python identity and brew/tool paths. Real desktop/Accessibility/owned Automation consent must exist when required; keep the exact normal-consent flags and original prompt clocks. Do not reset TCC or edit trust/clock assertions.

The scoped item36 workflow is already a complete callable source-bound entry. Set RUNNER_TEMP to a fresh owned root; create swift-launcher-evidence and an owned archive-session. Set ERGOPTI_ARCHIVE_EVIDENCE_DIR and the original consent opt-ins to1, without changing HOME. Keep SIGN_UPDATE's actual verified executable. Use bash with pipefail and preserve both pipeline exit statuses:

```bash
node tools/diagnostics/item36_xctest_evidence.cjs begin "$actualGitHead" "$sourceReceipt"
script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher   --scratch-path "$RUNNER_TEMP/swift-launcher-ci"   --filter 'ReleaseArchiveStagingTests|SparkleArchiveUpdateAcceptanceTests|HomebrewArchiveAcceptanceTests|HomebrewAutomationConsentTests' 2>&1 | tee "$transcript"
# Capture both PIPESTATUS values immediately; then call existing judge with them.
node tools/diagnostics/item36_xctest_evidence.cjs judge "$transcript" "$swiftExit" "$teeExit" "$actualGitHead" "$sourceReceipt" "$verdict"
```

The full exact workflow body is included in canonical-steps.json. Its outer20minute boundary and owned prompt/child clocks remain unchanged. The separate original no-prompt SDK permission API uses its own exact single-case filter and sdk_permission_xctest_evidence begin/judge; it does not grant Automation or replace archive acceptance. The Brew CLI is also existing (`python3 tools/diagnostics/macos_brew_archive_acceptance.py <repo> <receipt> --fixture-parent <private-parent> --evidence-directory <owned-evidence> --allow-automation-consent --allow-owned-consent-ui`), but the XCTest owner is preferred for the full established suite and its fixed case identity.

## macOS managed native HTTP/PAC and cancellation

The existing native release-stage guardian is directly callable with no test fork:

```bash
node tools/diagnostics/macos_release_stage_native_receiving.cjs --output "$ownedReleaseStageEvidence"
```

It retains its original native guardian, frozen corpus and120second deadline. For HTTP clients, create the same locked Python venv as CI: export-macos-managed-http-test-deps.py consumes the committed uv.lock, then pip uses --require-hashes --only-binary=:all:. Do not replace locked HTTPX/HF versions. Existing entry points:

```bash
"$nativePython" tools/diagnostics/macos_owned_process_native_test.py
"$nativePython" static/ergopti_plus/macos/tests/support/native_http_receiving_test.py --client-only
ERGOPTI_NATIVE_CLOCK_EVIDENCE="$ownedClockPayload" "$nativePython" -I -B   -X "pycache_prefix=$ownedPrivateCache" static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py
```

A real local run is explicitly supported when ALL GITHUB_SHA/GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT are absent: native_clock_epoch returns None/context_bound=false. No invented run IDs or borrowed official environment. The actual builder retains source/staged/image/sign/clock bytes through the existing owners; the fixed --fixture-clock-proof retains its15second command deadline. A local numerical sample remains UNQUALIFIED_GIT_HEAD_CLEANLINESS_NOT_RECEIVED until full independent source/image/context receiving; it cannot activate the held Swift45second factory path.

SourcePAC XCTest uses the exact existing ManagedPACSourceTests cohort and native_pac_source_evidence begin/judge. PAC/WPAD uses ManagedHTTPWireTests|ManagedHTTPWPADWireTests and its existing transcript receiver. SourcePAC's old source roster does not magically cover new PAC14/client inputs. The official clock receiver additionally joins real run/attempt/architecture/API job/artifact context; local None epoch has no such proof. Fresh source/callee/factory enrollment and original current-source before/final receipts remain required before any stronger claim. Run actual arm64 and x86_64 hosts for both advertised lanes; a translated or portable result is not native second-architecture acceptance.

## macOS packaging and installation

The existing build_macos_app.sh already builds the signed .app and ZIP/TAR.XZ archives. Use its actual workflow prerequisites: pinned Hammerspoon/managed catalogue inputs, original source build and code signing; ERGOPTI_RELEASE=false for local nonpublication. Ad hoc identity and an empty/throwaway Sparkle key have narrower scope and cannot prove stable production permission/update identity. No secret values are placed in this plan.

Existing commands after a genuine built/signature-verified package:

```bash
bash tools/build/build_macos_app.sh
node tools/build/macos-release-archives.cjs --ci-receipt "$builtApp" "$packageDirectory"
node tools/build/macos-release-archives.cjs --ci-install "$packageDirectory" /Applications "$ownedQuarantineStamp"
python3 tools/diagnostics/macos-release-launch.py /Applications/ErgoptiPlus.app "$freshLaunchEvidence"
```

Respect the original `test ! -e /Applications/ErgoptiPlus.app` precondition and preserve existing user applications. The actual installed-state launch matrix uses macos_launch_gate.py with original scenario/seed-tag/qualification receipt. Use those existing scenarios and full package receipt rather than a new smoke stub; do not invoke appcast/release publication scripts. Packaging/installation/upgrade are distinct results with their original outer and internal bounds.

## Smallest remaining implementation decision

Existing native entry points and package/install owners already cover execution. The missing reusable layer is fresh source/receipt enrollment and explicit local-vs-official receiving, not another executor. No new CLI is authored here: it would currently duplicate existing owners or manufacture local official identity. After Root/Windows/G3 admission, the smallest useful own documentation slice is this source-bound local command/prerequisite/evidence map; any later local summary tool should only consume existing original receipts and distinguish scope/status, never launch duplicate native owners or generate expectations. All commands above remain UNEXECUTED in this Linux container. Only source inventory was performed.
