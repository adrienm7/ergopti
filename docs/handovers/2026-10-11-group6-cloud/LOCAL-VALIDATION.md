# Group6 existing local native qualification procedure

The unchanged recipe inventory is source-bound to 1f764e33fa9711787b54fb4718a8e1575ac12df4; the original updater local command below is added after feature2abea05f32f9bb2fabb05b6a7d92476be52e5fd7. This procedure is not an executed native qualification. source-binding.json records24 actual committed entry-point/recipe cuts; canonical-steps.json records22 exact workflow step bodies including their env/conditions/step and job budgets. The source copies contain the original code and assertions. They introduce no alternative test tree or expectation corpus.

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

The original23 updater collector is now available at `tools/ci/run-windows-updater-original-diagnostic-cohort.cjs`, with its frozen independent18/4/1 oracle and exact2307-byte child. Run its explicit local mode on a clean reviewed checkout **before** PAC -Publish or another tracked build-output replacement. Static review finds no PAC worker/build invocation in those selected case bodies; genuine Windows include/load/execution remains required. The collector receives current21 and all declared tracked inputs before/final, preserves300000ms selection/execution and30000ms disposal, and retains raw TAP/stdout/stderr plus manifests. Its local context uses actual HEAD, null run IDs and context_bound=false. It never grants full-suite, fresh PAC build, feature or official CI qualification.

The collector requires an existing absolute archive path in `ERGOPTI_WINDOWS_AHK_ARCHIVE` on cache hits as well as fresh acquisitions. It authenticates the archive against the canonical `windows_release_toolchain.json` SHA before decoding, binds the exact unique `AutoHotkey64.exe` member bytes to the acquired interpreter and checks AMD64/PE32+ executable header flags. Archive, image and contract identities/digests are repeated before/final. The supplied FileVersion stays explicitly unqualified caller metadata. Header checks do not establish Windows loader admission, actual launched-image identity or process-tree retirement. No cache guess, arbitrary SDK receipt or missing-archive fallback is admitted.

With `$runtimeArchive` the existing canonical pinned ZIP and `$ahk` its independently received interpreter, use a fresh evidence root outside the checkout:

```powershell
$env:ERGOPTI_WINDOWS_AHK_ARCHIVE = (Resolve-Path -LiteralPath $runtimeArchive -ErrorAction Stop).Path
$fileVersion = (Get-Item -LiteralPath $ahk).VersionInfo.FileVersion
$g6Evidence = Join-Path ([System.IO.Path]::GetTempPath()) ('ergopti-group6-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $g6Evidence -ErrorAction Stop
node tools/ci/run-windows-updater-original-diagnostic-cohort.cjs --local $ahk $fileVersion $g6Evidence
if ($LASTEXITCODE -ne 0) { throw 'Original updater diagnostics refused; retain their evidence.' }
```

Local mode refuses hosted GitHub context, relative SDK/evidence paths and mixed/unknown arguments. An authentication binding alone grants no run identity. Retain the actual newly created local child directory and its RESULT/source/manifest/raw files; do not invent GITHUB_SHA/RUN_ID/RUN_ATTEMPT or RUNNER_TEMP to bypass admission. Source-only SDK controls use independent synthetic ZIP/PE fixtures and a finite private committed test contract; they do not qualify native Windows. Genuine pinned2.0.26 archive/image format compatibility was checked as inert data only. All23 native cases remain UNEXECUTED here. The registered `npm run test:windows-updater-original-source` instead covers22 portable private-Git/filesystem/context/model controls; native=false and official=false.

The two shared PAC receiver modules and authenticated two-runtime-output branch remain unadopted. Activation after -Publish still requires current complete producer/profile/source_receipt/MSVC/prepared/header/command and late-consumer receiving. Strict tracked-Git refusal remains; no historical producer map, arbitrary binary or successful subset can authorize fresh published PAC bytes. Preserve the full original unit suite and1320000ms watchdog. The supplemental23 cannot replace it.

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

## Remaining native receiving

The explicit local updater command reuses the original diagnostic child and independent oracle; it creates no alternative native test tree. Its22 portable controls and four causal predecessor refusals do not execute Windows. All Windows/macOS commands in this document remain UNEXECUTED on this Linux host. Original full-unit/E2E/build/install, Brew6, trust/restoration, both native Mac architectures, fresh producer enrollment and enterprise/device acceptance remain separate required results. Keep items36/62 and transversal16/38 open until their actual scope is qualified.
