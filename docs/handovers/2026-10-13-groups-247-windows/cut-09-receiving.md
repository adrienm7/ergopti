# Windows app-picker live callback compatibility

Incremental patch after frozen Windows offer753 + managed-origin7bf + requester57bfc. The exact three paths/preimages/afterimages/checksum are in `manifest.json`.

Requester57bfc changed the shared `_LLM_Agent_ApplyCommitted` callback to mandatory `(Key, Previous, Candidate)`. Its normal setting caller retained Previous correctly, but the actual app-picker save still bound only Key. The real transaction calls `ApplyFn.Call(CandidateMenu)` only after the borrowed durable writer and live publication; the picker therefore omitted the required Candidate argument. This is an actual source-interface defect, not a claimed executed AHK failure.

The picker now captures the previous app selection and binds both retained arguments, leaving the transaction to supply its actual candidate. Its save tail requires an exact integer true acknowledgement, like the normal agent-setting caller. Stale receipt claiming, refused commits, foreign configuration, normalized app list and the unrelated manual requester remain under the original owners; no alternate writer, native readiness or source qualification is introduced.

Executed Node22.22.2: actual existing rewrite feature guard with the new picker contract fails on the genuine old binder (exit1), then passes corrected source (exit0), preserving all163 prior guard checks and19 requester source inverses. Three new source inverses withdraw previous-value binding, exact acknowledgement and retained previous lookup and are refused. These are explicitly source controls, not simulated AHK behavior. The read-only overlay selects changed exact private files and otherwise the current canonical bytes; every selected read is recorded in `proof.json`. No canonical mutation occurs.

Six existing-feature AHK cases are authored, native UNRUN: accepted save, same selection, refused commit, stale receipt, float acknowledgement and string acknowledgement. They invoke actual `LLM_Agent_OnAppPickerSave` through the existing real candidate/live-tail fixture, retain generation, verify normalized state and rebuild admission, and require exact receipt one-shot use. Receipt cleanup runs in finally even after assertion failure. The previous complete test bytes, including615 Assert-prefixed named calls and every earlier requester case, are preserved as a prefix; seven new named assertion calls are appended. No new test file/roster is needed.

Four private AHK files pass the unchanged syntax-antipattern scanner, loop scanner0/0 and all14 self-test fixtures. The two changed AHK files have exactly one UTF8 BOM, strict valid UTF8 and LF-only bytes. Repository Prettier passes the changed feature guard. Exact private-preimage apply-check exits0. This does not claim a complete canonical gate or native AutoHotkey parsing.

Native Windows VM receiving (UNRUN), with composed source and pinned AutoHotkey2.0.26:

```powershell
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only=agent-app-picker-tail
```

Require exactly six selected cases, exit0, zero failures, and no skipped/unexecuted selections. Then run existing full agent/app-picker cohorts. In the real installed menu, save normalized excluded apps, confirm durable/live state and one tray refresh; stale/cancelled/refused saves must not fabricate acceptance or revoke an unrelated manual requester. This menu software receiving needs a native Windows VM/desktop; physical keyboard/trackpad/display qualification is separate and not established here.
