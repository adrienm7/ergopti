# Windows original managed origin custody

Apply this source-only incremental patch after `75356660b04198ec5279587cfa9a03bb92b2b3d099d13a1e55434d2bb0ddb82c` (the frozen model-offer consent patch). It changes six existing feature-owned source/test paths. No native DLL, manifest, source flag, readiness grant, release policy or runner enrollment changes.

Ordinary model-list and chat requests previously retained auxiliary generation plus URL. The managed bootstrap's private probe prefix was correct, but its direct retirement only retired that prefix; an ordinary retained request could therefore compare the old URL with a successor's equal URL. The new lexical currency closure captures the original flow, runtime, runtime record, target, task, generation, detached ticket fields and auxiliary generation before the origin reader. It distinguishes explicit external selection from app ownership. Result closures retain the same receipt across native reads, filesystem/process cleanup and user delivery. Prebuilt chat dispatch uses its captured URL. Shared auxiliary ping/delete paths also retain their captured endpoint and recheck currency before dispatch. The bootstrap's original `OwnsProbe` body is byte-identical.

External server replacement at the same configured URL remains unobservable: there is no invented app-owned ticket for a personal server. Creating unrelated inventory owners does not change auxiliary generation and does not invalidate a valid same-source response. No new code starts or stops a server; the existing admitted-origin validator remains responsible for its existing source checks.

## Portable source receiving

From the repository root with pinned Node 22.22.2:

```sh
node tools/test/test-windows-managed-bootstrap.cjs
node tools/test/test-ahk-v2-syntax-antipatterns.cjs
node tools/test/test-ahk-loop-capture.cjs
node tools/test/test-ahk-encoding.cjs
```

The feature guard retains the prior 11 offer inverses and adds 13 original-origin source inverses. Original source under the new guard is RED because the new capture API is absent; this is source-contract evidence only. Syntax, loop-capture and strict BOM/LF checks passed on the private source projection. Native AHK execution and actual managed server replacement remain UNRUN. Original test assertions remain intact: the original managed test bytes recover exactly after removing the new tests and faithful custody/generation fixture metadata; the original API test prefix is byte-identical.

## Native Windows receiving (UNRUN)

Preconditions: the composed source tree, pinned AutoHotkey v2.0.26 on Windows, and the existing test fixtures. The pinned executable must be present on PATH or invoked by its absolute path.

```powershell
AutoHotkey64.exe /ErrorStdOut=UTF-8 /CP65001 static/ergopti_plus/windows/tests/run_all.ahk --only managed-origin-custody
```

Expect 17 new authored cases, zero failures. These execute actual AHK functions over explicit fixture capabilities; they do not qualify native daemon process identity, installation or network delivery. Also rerun the existing managed bootstrap/API cohorts through the ordinary Windows runner.

For native managed integration, after the existing official managed-runtime receiving prerequisites are satisfied, hold an actual `/api/tags` result and prebuilt chat/stream result across app-owned READY -> RETIRED -> READY at the same URL. The old result must create no missing-model offer, text or readiness claim; the successor's own request must still succeed. Repeat with ordinary inventory creation while the original service stays unchanged: its original result must remain valid. Verify external server/configuration remains untouched. This receiving requires a Windows VM/native session and actual owned service observations, not a physical keyboard or screen qualification.
