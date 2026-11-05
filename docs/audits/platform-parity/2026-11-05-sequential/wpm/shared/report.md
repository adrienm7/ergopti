# WPM shared contract and cross-driver comparison

Audited commit: `7aecd9a25b35efdcff68898919506dc2f6fd02d0` (2026-11-05). Scope: shared WPM canon, actual Lua drawing-decision model, live calculation, five preference declarations, six metrics-menu commands, locale units/reasons, and source tracing into Windows/macOS/Linux producers and native adapters. No application or registered-test edits. Canonical confirmed findings: **zero**. This does not certify native desktop delivery.

`comparison.json` is the bounded capability/setting/action matrix: 36 capability rows, five settings with exact default/recommended/platform/dependency metadata, six commands with exact disabled/check predicates, and all 21 shipped locale units/reason strings. Every row separates classification from proof basis. Source paths are relative to the pinned worktree. `probes/build-comparison.py` re-derives declarations from their canonical TOML and locales rather than copying generated defaults. The native OS roles independently investigate actual platform owners and refusal/stale controls.

## Actual owner execution

`probes/shared-model.lua` loads the shipped canon with the real shared TOML decoder, executes `wpm_widget.model`, `keystats.live_wpm`, and `keystats.metrics` unchanged, and feeds actual tracker results into model decisions. The only fake is the public group-colour resolver in explicitly named healthy/refused controls; it returns the real exported resolver shape (group -> colour/nil). There is no native surface stub masquerading as desktop receiving.

Run, with `ROOT=/workspace/worktrees/parity-sequential-2026-11-05/shared`:

```sh
PYTHONDONTWRITEBYTECODE=1 /workspace/scratch/parity-toolchain/ci-bin/lua5.4 /workspace/scratch/parity-sequential-2026-11-05/wpm/shared/probes/shared-model.lua "$ROOT"
PYTHONDONTWRITEBYTECODE=1 /workspace/scratch/parity-toolchain/ci-bin/luajit /workspace/scratch/parity-sequential-2026-11-05/wpm/shared/probes/shared-model.lua "$ROOT"
```

Healthy controls cover empty/one-character streams, ten-character output, 2s minimum duration, decay, exact 5s idle and 15s pruning boundaries, held group and its 1s boundary, seconds conversion, five neutral sources, AI/group/user colours, invalid/throwing resolver fallback, strip half-up rounding, source-colours disabled, localized unit/label, panel neutral background, 60-sample history, graph clipping, negative monitor coordinates, graph-anchor round trip, startup hidden, idle hidden, newer-mouse hidden at zero WPM, and preview visibility. Refusal controls cover missing required geometry, malformed colour, missing file, and throwing decoder.

The script deliberately prints an observed policy discrepancy; its successful process exit means the observation assertions matched current source, **not** that the discrepant behavior is approved. Both Lua runtimes must show the same observation. Retained logs explicitly label this as model execution only.

## H-WPMS-001 — mouse and idle behavior differ from declarations and Windows (unknown intent)

Synthetic private fixture: ten output characters at 10.000s, mouse moves at 10.100s, no preview, no subsequent output. The real tracker returns WPM60 at 10.200s. The real `widget_visible` returns `show=true` and resets `last_active` to10.200s, despite the newer mouse event. With continued sampling, residual positive speed refreshes this clock until the5s speed reset; the readout can remain logically shown until nearly8s after input. The observed trace is in `logs/model-lua54.log` and `logs/model-luajit.log`, and replayed in both final sweeps.

Root mechanism: `widget_visible` refreshes `last_active` from positive rolling WPM each draw and its return expression puts positive WPM outside the `mouse_active` exclusion. Rolling speed is an observation of previous input, so it supplies neither the actual last-keystroke clock nor a mouse override. macOS `ui/wpm/wpm_widget.lua` and Linux `ui/wpm/widget.lua` call this actual model. Linux's drag override is separate and appropriate for a user-held window.

Windows `ui/wpm/wpm_display.ahk` instead retains `_last_input_ms`; `Tick` requires keyboard inactivity <=3s and `!mouse_active`, and `MouseWatch` hides on changed mouse position except while a preview is up. These are source-traced counterparts, not a native AHK execution claim. Shared model comments and the Linux module description promise hiding when the user returns to pointing. However, the user-facing menu only says “Floating WPM widget”; no stronger user-facing mouse/idle specification was found in the WPM READMEs, design docs, or locale keys. Therefore this remains **unknown intent**, outside findings, pending product clarification. No forced G2/G5 label.

A future regression direction, if mouse override is intended: execute real tracker -> model with held positive speed, move pointer after last output, assert show=false except preview/active drag; use the actual output timestamp for the3s deadline. If observed speed-based visibility is intended, change the misleading comments and explicitly decide the Windows difference. No performance claim accompanies this observation.

## Explicit intent and native constraints

- Five settings have identical common defaults/recommendations: widget visible=false, widget colours=true, widget graph=true, panel visible=false, panel colours=true. The2026-11-03 comments explicitly justify graph/colours enabled while visibility stays off. Position is Storage state under the shared keys, never a TOML preference.
- Windows panel-readout absence is explicitly declared and already tracked by `TODO.md:28`. The shared reason offers the floating alternative. This is **known product scope**, not a newly discovered platform impossibility: Windows notification icons exist, and the TODO says to evaluate one. Do not duplicate it.
- Linux paints a separate44px PNG number, shrink-to-fit, and uses a localized full label as title. macOS uses a13pt localized string with NBSP padding and optional translucent source background. Linux comments explain that some panels ignore labels and cache icon paths, so alternating PNGs and a neutral fill adapt to the backend. This is an evidenced native adaptation, not proof of delivery on every desktop.
- Windows defaults to monitor work area; macOS uses `mainScreen():fullFrame()`; Linux uses primary monitor or monitor0 full geometry. All use bottom-right inset5 and graph/compact shared anchor. Work area versus full geometry and monitor selection are explicit implementation differences; there is no native monitor-layout run here.
- Actions are the six metrics-menu commands; `actions.toml` has no WPM shortcut action. Dashboard `open_metrics_typing/apps` actions are separate. Windows has four implemented handlers and the two panel rows are unavailable; both Lua drivers have six. Source maps and shared renderer produce declared disabled/check states. Native menu click acknowledgment belongs to each OS role.

## Other discrepancies retained outside findings

- Windows Calc uses the15s window and2s minimum but does not apply the shared5s idle reset. Its usual3s hide masks the number; a visible preview might reveal it. Source-only here, delegated to Windows role.
- Windows independently holds AI/hotstring/autocorrection timestamps and prioritizes AI over hotstring over autocorrection. Lua uses the latest single producer. AI then a hotstring inside1s can show different colours. Windows role reported source-projection evidence, no native AHK execution. Unknown intent.
- Windows uses `<1000ms`, Lua `<=1s` at the colour hold boundary; minor tick-boundary difference, unknown intent.
- Windows synthetic producers correctly loop per replacement character. The initial suspicion of one sample per expansion was **refuted** by reading the enclosing loops in `keystats_hotstring_log.ahk` and `llm_bridge.ahk`; searching the call alone hid the loop. No false finding survives.
- Synthetic string length is UTF16 units on Windows (`StrLen`) versus codepoints in Lua. Non-BMP receiving behavior was not exercised. Manual Backspace treatment and reuse of pre-enable live buffers also differ at source level; see matrix. Do not claim numeric end-to-end equivalence for those inputs.
- Shared `validate` requires only `neutral_sources.none/manual`, although shipped neutral sources also include hotstring/repeat_key/rolls. Deleting `rolls` is accepted and changes its colour fallback. Actual mutation characterized; no ordinary UI writes the bundled canon, so no reachable shipped defect is claimed.
- Feature metadata still names Windows WebView2 for WPM settings although the draw path is native GDI+. No readiness refusal was demonstrated, so this remains metadata/intent uncertainty.
- WPM READMEs are stale: Windows README names a nonexistent `wpm_menubar.ahk`, says compact default despite manifest graph=true, and both platform READMEs say panel readout always visible and per-bar source colouring although current code hides panel at idle and colours the whole curve from current source. These are documentation inaccuracies, not fabricated runtime findings. The shared module README and canon identify the actual current driver consumers.
- Saved-coordinate pair durability was explicitly excluded as a known prior finding. Display hotplug/clamping and native drag admission are left to OS roles; this report does not duplicate their roots.

## Sweeps, tests, and limits

`logs/false-greens.log`: mechanical false-green scan within baseline. This only reports its supported patterns; it does not prove business behavior. The actual probe asserts returned values and refused results, not `pcall` success. Full-scope final sweep A and B re-enumerate the5 settings,6 commands,21 locale mappings and36 capability rows, rerun the entire model/tracker probe on genuine Lua5.4 and LuaJIT, and hash the bounded source inventory. Neither sweep adds a confirmed root. See `coverage.json` and `logs/sweep-{a,b}.log`.

Performance and memory behavior are unmeasured. No G4 claim, native GTK/Cairo/Hammerspoon/Win32 rendering, native pointer dispatch, detached-monitor delivery, live keystats capture, persistence durability, or platform callback scheduling is certified by this shared role. No user configuration, real clipboard, credentials, logs, or live services were read.

Artifact validation: the repository's `tools/audit/workflow.cjs validate-report` rejects this externally assigned scratch path (`report must be inside the repository`), and its schema also limits scope/destination to dated ahk/hammerspoon reports. It was not bypassed or presented as green. `logs/repository-validator.log` retains that rejection. `probes/validate-artifacts.py` validates the task brief's custom manifest, exact bounded inventories, unique capability IDs, hash records, existing report, and LF files; see `logs/artifact-validation.log`.
