# LCP-004 caller completeness countercheck

Audited SHA: `213d65af24d2aa4845ba47743c9bab6787b61964`. **Extend existing LCP-004**, rather than add a new root finding: `make_executable_selection` reaches the same unsafe URI-selection probe without even an initial file-manager admission. An unchanged focused terminal is sufficient; focus-switch timing is unnecessary for this caller. Severity remains medium; source-path confidence high, native desktop effect unexecuted.

The real production route is a configured action binding → `modules.gestures.manager.execute_action` (`manager.lua:1934–1939`) → `_execute_action` system-handler branch (`:816–828`) → `SystemActions.HANDLERS.make_executable_selection` (`system_actions.lua:284–307`) → `adapters.clipboard.read_selection_uri_list` (`clipboard.lua:595–624`). Paths above are relative to `static/ergopti_plus/linux/`. The catalogue declares this Linux action without a file-manager requirement (`_shared/modules/actions/actions.toml:1079–1081`, relative to `static/ergopti_plus/`). Keyboard `fire` invokes that executor (`modules/shortcuts/keyboard_shortcuts.lua:794–799`); an admitted gesture also invokes `_execute_action` (`manager.lua:1952–1985`). Their ownership/pause/source checks do not establish that the destination is a file manager.

The manager passes the ordinary `combo_emitter.press` directly, no publication guard or focused-app predicate. The handler invokes the URI helper before it can know whether files were selected. That helper snapshots text, writes its sentinel, then calls `emit_combo("ctrl+c")` at `clipboard.lua:609`; the no-file result is determined only afterwards. `combo_emitter.press` (`:292–302`) checks a publication only when non-nil; `press_codes` (`:323–353`) treats nil publication as admitted and checks device availability, not application eligibility. Thus no outer or inner file-manager guard refutes the path. The root helper owns the dangerous probe and must receive/enforce destination admission; callers must establish the intended file-manager target.

Reproduction: bind “make selection executable” to a supported key/gesture, leave a terminal focused with a foreground command, activate the binding. With an available clipboard provider and input channel, the driver sends Ctrl+C to that terminal before finding no URI selection. A typical terminal interprets this as interrupt; that native consequence is derived from normal terminal semantics, **not measured here**. It is possible to disrupt work even though the handler ultimately reports no file selected and never runs chmod.

## Safe execution and controls

Probe: `probes/make-executable-caller.lua`. Real manager, system handler, URI helper and parser execute with recording shell, clipboard, emitter, timer and notification boundaries. No real clipboard, terminal, device, chmod or notification is used. The production source files inspected had no diff from the pinned SHA. Both `/workspace/scratch/parity-toolchain/ci-bin/lua` and `ci-bin/luajit` completed successfully; see `logs/make-executable-caller-{lua,luajit}.txt`.

- Unchanged terminal, provider available: exactly one Ctrl+C attempt at terminal, nil publication, two text writes (sentinel/restore), no background command, saved text restored, no-file notice recorded.
- Healthy file-manager control: exactly one Ctrl+C, URI parsed, exactly one **recorded** `chmod +x` command, saved text restored. The fake path is a fixture string only; no file is created or modified.
- No clipboard provider: no chord attempt, no writes, no background command.
- Input emitter refuses (model of unavailable writer): one recorded attempted Ctrl+C call returning false, no actual injection, two text writes for probe/restore, no chmod. This validates safe refusal propagation at the recording boundary; it does not claim to execute a real unopened uinput device.

The fixture's `world.app` labels the unchanged focus boundary; production code is never given that label and does not inspect it. It establishes the absence of application admission, not native terminal delivery. Positive control and no-command controls distinguish the URI-probe defect from chmod parsing/execution.

## Intentional boundaries and closure

The Linux action intentionally uses Unix executable permission; Windows is explicitly excluded because its executable-permission model differs (`actions.toml:1079–1081`). The Linux helper intentionally obtains file-manager URIs through copy; neither that mechanism nor the macOS equivalent establishes an intentional policy to send interrupts to arbitrary focused applications. No macOS/Windows race immunity is asserted.

This is the previously retained LCP-004 unsafe URI-copy class with another reachable caller, not a separate newly counted defect. Regression coverage should include direct binding from a non-file-manager, file-manager success, unavailable provider/emitter, and the existing focus-change case. No new G4 measurement. This bounded caller review found no guard that refutes the extension and makes no claim of a fresh whole-module dry audit.
