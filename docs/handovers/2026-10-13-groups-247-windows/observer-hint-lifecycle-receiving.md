# Private Windows observer hint lifecycle correction

Base: `ae684ed723c82bb158dd873a9e928be2e105a9c1`.
Patch: `observer-hint-lifecycle.patch`, SHA256
`e0bed5075add9e73dd59dfeb99f1b1db5f5477ec50c27e77eaa2d0a7553cfa49`.
Exact two pre/post hashes: `freeze-observer-hint-lifecycle-manifest.json`.
No canonical source/index, native bridge, vendor, roster or CI change occurred.
Keylogger/Group6 overlap is signaled; receiving must coordinate ownership and
compare freshly fetched dev before any live integration.

The old `_KL_Hook_CaptureInput` updates cached key hints before checking logger
initialization, shutdown or stopping. Actual KL_BeginShutdown/CancelShutdown can
change lifecycle without stopping InputHook, so a refused Down may replace hints
and a successor Char may inherit another lifecycle's key identity. The old
capture invalidation/start also leaves those hints alive.

The correction moves the complete admission guard before hint updates, clears
cached hints on capture invalidation/start, and retains the logger lifecycle that
owns the cached pair. An admitted callback entering another lifecycle clears the
old pair first. Same-generation behavior, FIFO receipts, privacy handling,
activity accounting and the Char three-argument/KeyDown four-argument ergonomic
signatures remain intact. Unknown hints stay zero and metadata kc/sk is omitted.
This does not authenticate a physical edge, correlate native callbacks, solve
hook order, assign future modifiers or open any production capture cohort.

Windows InputHook supplies vk/sc to OnKeyDown but none to OnChar, creating this
specific persistent cache. macOS keylogger/init.lua derives keycode directly from
its current event object (and applies its physical-accounting owner separately).
Linux keylogger/keylogger.lua accepts an explicit scancode argument with the
character callback. Neither path uses this Windows cross-callback pair cache;
no invented parity change is made to those drivers or qualified by inspection.

Executed Linux evidence: actual old-source control RED, corrected-source GREEN
and seven source inverse failures; two-file AHK syntax antipattern scan PASS,
loop-capture zero with fourteen detector self-tests PASS; strict UTF8 BOM/LF PASS.
These are source observations, not AHK behavior. All227 original assertion
occurrences and test bytes survive except two faithful fixture additions that
save/seed the new lifecycle stamp.26 assertions append seven registered native
cases: capture/lifecycle/shutdown-rollback barriers, three refused Down modes,
and renewed same-generation hints. These **seven AHK cases are UNRUN**.

After reviewed source composition, portable source evidence can be replayed on
Linux with the exact Git preimage and the corrected production file:

```sh
git show ae684ed723c82bb158dd873a9e928be2e105a9c1:static/ergopti_plus/windows/modules/keylogger/keylogger_hook.ahk > /tmp/ergopti-observer-hints-before.ahk
node docs/handovers/2026-10-12-dev-consolidation/observer-source-controls.cjs /tmp/ergopti-observer-hints-before.ahk static/ergopti_plus/windows/modules/keylogger/keylogger_hook.ahk
```

Expected original source RED, corrected source GREEN and7 inverse rejections.
This supplemental source probe adds no repository runner enrollment and replaces
no native test. Its default inputs also replay the retained private projection.

After reviewed source composition, use pinned AutoHotkey2.0.26 x64 on a Windows
VM with the ordinary unit fixture graph, from the repository root:

```powershell
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only todo49-observer-hints
if ($LASTEXITCODE -ne 0) { throw 'Observer hint lifecycle regressions failed.' }
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static/ergopti_plus/windows/tests/run_all.ahk --only 'keylogger arrival FIFO'
if ($LASTEXITCODE -ne 0) { throw 'Existing keylogger arrival custody regressions failed.' }
node tools/test/test-ahk-v2-syntax-antipatterns.cjs
node tools/test/test-ahk-loop-capture.cjs
node tools/test/test-ahk-encoding.cjs
```

Expect7 new cases, all existing FIFO/privacy/shutdown/ergonomic assertions and
unchanged callbacks. Record actual selected counts/exits rather than treating
source scans as native receipts. A Windows VM suffices for these controlled
port/clock/lifecycle cases. Actual InputHook callback delivery, IME/composition,
real keyboard holdings and hook-order behavior remain separate native/physical
receiving. TODO49 and complete nonhook cohort conversion stay open.
