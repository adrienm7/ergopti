# Hammerspoon audit — 2026-09-07

Audited commit: `f6d387ff85cdbac5cf8ded0c88994bf1948fbd67`.
Scope: `static/ergopti_plus/macos/`.

## Findings and reproduction evidence

This bounded pass confirmed thirteen defects. Completion is recorded in atomic
commits with `Audit-Finding` trailers; this report describes the audited state.

- **HS-254, low severity/high confidence:** the system diagnostic multiplies
  free pages by 4096. With 65536 pages of 16384 bytes, it displays `0.2 GB`
  instead of `1.0 GB`. The focused `test_healthcheck_memory_page_size.lua`
  reproduced this mismatch before production changed. The previous suite did
  not assert memory values. The host snapshot provides `pageSize`, `pagesFree`
  and `memSize`: [native contract](https://www.hammerspoon.org/docs/hs.host.html#vmStat).
- **HS-255, low severity/high confidence:** the diagnostic divides full desktop
  width by usable desktop width to infer Retina scaling. With native scale 2
  and equal widths it reports `1.0×`; a side Dock can make scale 1 report
  `1.2×`. Three of four focused `test_healthcheck_retina_scale.lua` cases failed
  before the correction. Both rectangles use points; the mode's `scale` is the
  native factor: [native contract](https://www.hammerspoon.org/docs/hs.screen.html#currentMode).
- **HS-256, medium severity/high confidence:** start a system-load sample,
  then pause, disable, stop or restart keylogging before delivering its task
  completion. The old callback still queues `system_load`. Five focused
  `test_system_load_lifecycle.lua` cases failed before the correction, including
  old and new samples completing into the same restarted runtime. The task pin
  is released correctly, but the completion bypasses the existing hardware
  generation and authorization guard. The real log-manager sink accepts the
  queued event without a second lifecycle check.
- **HS-257, medium severity/high confidence:** PTY failure output can be CRLF.
  The MLX and Ollama `tail_for_error` helpers split only LF and pass the retained
  CR to the download window's `set_error`. Its string encoder escapes quotes
  and backslashes but leaves CR/LF raw, invalidating the JavaScript call and
  hiding the failure message. The control-byte case in
  `test_download_window_setmodel_js_escaping.lua` failed before the correction.
  The same encoder serves step, detail and log presentation. Existing escaping
  tests covered quotes and backslashes only.
- **HS-258, high severity/high confidence:** show download window A, save its
  native close callback, hide A, show B, then deliver A's close callback. The
  callback clears B's owner and calls B's cancellation controller. An isolated
  Lua reproduction using the real download-window module observed one successor
  cancellation and `is_active() == false`. The UI builder forwards native
  `closing` and `closed` notifications without an identity check. Related
  controller reentrancy also crosses operation boundaries: A's abort callback
  can show B before the bridge fetches `_on_cancel`, causing B's callback to run.
  Regressions must cover native replacement and paired-controller reentrancy,
  including reuse of the same native window. Delayed frontend messages across
  same-window operation replacement require a separate protocol review.
- **HS-259, medium severity/high confidence:** the input-source probe emits
  JSON with Python's default Unicode escaping, but the Lua parser extracts
  quoted substrings. `Fran\u00e7ais` becomes a literal escaped identifier rather
  than `Français`, so the selected marker and subsequent layout selection are
  wrong. Embedded quotes also split one name into multiple records. Three
  focused `test_active_layout_json_escapes.lua` cases failed before production
  changed. Existing parser tests used ASCII names without escapes.
- **HS-260, high severity/high confidence:** the terminator settle fence starts
  during preparation using a nominal dispatch budget. If paced replacement
  dispatch completes after that deadline, completion releases the terminator
  immediately, leaving no post-paste settling interval. Independent isolated
  Lua replay used a 0.2 s budget, 0.1 s settle delay, fence delivery at 0.3 s and
  replacement completion at 1 s; replay activated at 1 s. Source review confirms
  that `utils.perform_paste` starts clipboard restoration at completion but does
  not keep that replacement transaction pending through the settling interval.
  The replay admission contract must retain its pre-acquired owner while the
  settle interval is anchored to actual completion. Native visible impact
  remains unmeasured.
- **HS-261, medium severity/high confidence:** a failed `top` completion with
  empty stdout persisted one empty system-load event and emitted no error.
  Eight invalid-sample cases failed before the correction; the valid-sample
  control passed. Exit status and parsed metrics require validation before the
  event is handed to persistence, with bounded diagnostics excluding output.
- **HS-262, medium severity/high confidence:** synchronous JavaScript failures
  are swallowed by three execution paths, and no native completion observer is
  supplied for asynchronous errors. An isolated real-window replay rejected
  two evaluations while recording zero diagnostic errors. WebKit reports
  runtime errors through the optional callback's second argument:
  [native contract](https://www.hammerspoon.org/docs/hs.webview.html#evaluateJavaScript).
- **HS-263, medium severity/high confidence:** `show`, 201 pre-ready log lines,
  then navigation completion deliver 200 commands but never `setKind`.
  The bounded FIFO discards essential initialization together with log history.
  Required state must survive overflow; disposable log history may be truncated
  only with a diagnostic count and bounded storage.
- **HS-264, medium severity/high confidence:** replacing an operation before
  the first navigation queues `resetUI` on a never-initialized document. The
  shared script runs before the builder's delayed locale injection and hides
  and disables Cancel when its label is unavailable. A real-script DOM replay
  observed both effects. Existing reuse coverage navigates before replacement.
- **HS-265, medium severity/high confidence:** bootstrap Terminal commands
  concatenate the configurable unified-log path directly after `tail -f`.
  A path containing spaces is split by the shell; AppleScript string escaping
  protects a different syntax layer. MLX download and reattach use the same
  construction pattern but currently restrict generated paths to safe names;
  quoting these sibling path arguments is preventive consistency, not evidence
  of independently vulnerable current filenames.
- **HS-266, high severity/high confidence:** the actual shared frontend emitted
  the plain body `cancel` for A. After real Lua `show(B)` reused the same native
  window, delivering that retained body produced zero A cancellations and one
  B cancellation. Native ownership cannot fence two occupants of one window.
  The protocol needs an operation identity end-to-end, with explicit legacy
  compatibility for the unchanged Windows and Linux consumers.

## Coverage and rejected hypotheses

Read-only parallel review covered timer, process and task lifecycle adapters
and selected callers, followed by singleton window ownership. Local review
covered network/crypto reachability, diagnostic collectors, keylogger task
completion and its downstream sink, download-window payload construction,
input-source JSON parsing and terminator settling order.

No new adapter-internal lifecycle defect was confirmed in that bounded review.
Action picker, prompt editor and model browser already guard context ownership.
Normal bootstrap streaming splits both CR and LF before `set_detail`; the
confirmed escaping path is the terminal error tail, not that streaming path.
Raw task construction remains centralized; presence of a GC pin alone was not
treated as proof of callback authorization.

The mechanical false-green scanner reported zero in all six detectable
categories. It cannot establish native-double fidelity or detect every invalid
test oracle. Behavioral reproductions above were required independently.

The additional test-quality review inventoried the largest Lua test modules.
The 4284-line pause-owner inventory contains independent input, backend and
startup compositions. A test-only split preserves all 296 executed case names;
all ten resulting test modules pass alone, and reverse/interleaved composition
passes 592 cases with explicit module/native-world isolation checks. No
duplicate or useless assertion was demonstrated by this bounded review, so
none was removed.

## Verification and remaining coverage

The first change-scoped verification passed Hammerspoon E2E and 8448 Lua tests
across 940 modules. Subsequent fixes require their own selected verification;
the initial pass is not evidence for changes made later.

The first integration batch subsequently passed 8498 Hammerspoon tests across
957 modules, Hammerspoon E2E, all 208 JS checks, strict conventions and the
mechanical false-green ratchet. This covers HS-254 through HS-263 and the
pause-owner split; HS-264 through HS-266 remain queued for the next batch.

Two independent tooling defects were reproduced and corrected in separate
commits. The RTK launcher test discarded its discovered shell when restricting
the child's PATH; retaining the absolute shell executable preserves the real
isolated-PATH exit-contract test. The Linux bundle copy loop exhausted its
60-second aggregate build budget on Windows. A 123-file tracked fixture took
14619.8 ms before the copy change (one baseline sample) and 379.1, 458.2 and
502.0 ms afterward, while exact file sets, live bytes, exclusions and timestamps
were checked. Per-file shell process counts fell from 369 to zero. A complete
bundle assembly then passed in 8.452 seconds (one run, smoke skipped because
this is the cross-platform packaging gate). These are local Windows tooling
measurements during the campaign, not native driver latency measurements.

This host runs Windows and headless Lua doubles. No macOS runtime latency,
CoreGraphics behavior, native WebKit rendering, Swift build or permission flow
was measured. Native APIs were checked against documentation where relevant.
Removing memory-probe subprocesses is an operation-count reduction, not a
measured latency result. No claim that all bugs or all latency are eliminated
is justified. Full input/configuration flow sweeps and two consecutive dry
passes remain necessary, followed by native macOS verification.
