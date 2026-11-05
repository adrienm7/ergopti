# macOS personal-information audit

Audited SHA: `7aecd9a25b35efdcff68898919506dc2f6fd02d0`, 2026-11-05. Scope: all 15 personal fields and 13 default aliases, added ASCII aliases, @-combo and prefix routes, masking versus literal output, editor/controller, file publication and reload, consent, privacy and callback lifecycle. Two confirmed medium-severity roots. No production or registered tests changed. No real secrets, user files or native Darwin desktop were used.

## Confirmed findings

### PIM-001 — Added valid ASCII aliases are ignored and erased by an unrelated edit

Medium severity, high confidence; G2; additional property: configured alias/source integrity.

Put `x = "city"` in `[letters]`, with a valid string `city` in `[info]`. Startup reports success, but the actual keymap event route for `@x★` produces no preview, no consume and no emission. In the same source, changing the existing `p` alias to `"city"` works: its preview and output are exactly `Audit City`. An unrelated editor save changing only `last_name` succeeds and removes `letters.x` from the actual TOML. Exact before/after files are retained.

The configured mapping is valid under the shared example's declared contract: `core/config_schema/examples/personal_info.example.toml:22–24` says `[letters]` maps a one-letter shortcut to a known `[info]` field and restricts the **values** to known field names. It does not enumerate a fixed alphabet. `SCHEMA.md:9` calls this file universal. The macOS collector itself accepts any lowercase ASCII `a–z`, so `x` is already in its input alphabet. Linux reads arbitrary valid single-codepoint aliases, and Windows preview comments explicitly discuss aliases a user may add. No explicit macOS restriction to the 13 default keys was located. This finding requires only lowercase ASCII `x` and a known field; it makes no promise about arbitrary Unicode aliases or custom `[info]` fields.

Root: `personal_info.lua:220–235` iterates only `DEFAULT_CONFIG.letters` when loading the alias section; every non-default alias is discarded rather than loaded or refused. `LETTER_KEYS` derives from the same default map, and `serialize_config` writes only that list. Thus reload cannot repair the configured alias, and a successful normal save makes its loss durable. No alias diagnostic is emitted. Reassigning an existing alias is a working backstop. Parser and serializer are one fixed-whitelist mechanism; source deletion is a retained consequence, not a second finding. ADR-009 is specifically about `config.toml`; no generic unknown-key preservation obligation for this separate file is inferred from it.

Regression direction: load an added lowercase ASCII alias to a known field through real startup, exercise actual preview/dispatch, save an unrelated field and restart, requiring the same mapping throughout. Keep existing-alias remap, invalid-reference, static-trigger collision and all-or-nothing combo controls. If a restricted alphabet is intended, declare it, reject unsupported source explicitly, and preserve its source rather than silently dropping it.

Evidence: `probes/engine.lua`, `probes/engine.log`, `probes/aliases.before.toml`, `probes/aliases.after.toml`, `probes/contract-excerpts.txt`.

### PIM-002 — A personal prefix interprets field data as output commands

Medium severity, high confidence; G2; additional property: data-versus-command integrity.

Open the actual personal-information editor, submit ordinary save bridge data with `phone_number = "0123{Tab}45"`, and enable phone-prefix expansion. The actual editor/controller/UIBuilder and PersonalInfo save accept the string and close the native-shaped view. Type `0123` at a word boundary. The actual keymap consumes it and constructs a native Tab key pair, while the logical emitted value becomes `0123` + tab + `45`, instead of the accepted literal field text. The same stored value through `@t★` is a positive control: it emits the exact literal `0123{Tab}45` and constructs no native Tab.

This is intentionally adversarial string data. The shared frontend creates ordinary text inputs and forwards `input.value`; backend `validate_info_update` accepts any string for a known field. No numeric-phone validation/refusal or declaration that personal values contain Send commands was found. The shared personal-info policy explicitly says it changes no typed output: expansion is always the complete value. The result is demonstrated as constructed callback-return native command events; no actual focus move or multi-field native application is claimed.

Root chain: actual editor `handle_message(save)` → `PersonalInfo.save_info` → real `RulesEngine.refresh_personal_data`/Registry transaction → `register_prefix_entries` passes raw private personal values to ordinary `Registry.add` → `registry.lua:833` precomputes tokenized `plain_repl` → `expander.emit_dispatch:410–416` selects `emit_tokens` when the raw and plain replacement differ. Personal `field` and `is_private` metadata control masking/logging, not literal output semantics. In contrast, the @-combo owner deliberately calls `SyntheticInput.emit_key_strokes(value)` per field and emits inter-field Tab separately.

No failure is reported: save, registration and replacement complete normally. Prefix callbacks are enabled and the field is present, so missing-file/startup/cleanup guards are irrelevant. Privacy marking does not prevent a command from being emitted. The @ alias is a working backstop. This changes emitted output and is distinct from prior **MH-001**, where the same-looking tokens in literal provider descriptions are stripped only in previews. That earlier preview root is not recounted.

Regression direction: pass accepted brace/key/Unicode-looking strings through actual editor → save → personal prefix registration → Registry/Expander/SyntheticInput. Require byte-exact literal content and zero command-token events, while preserving separate intentional inter-field Tab events for combos. Keep ordinary hotstring Send syntax operational. Windows and Linux literal-data counterparts were source-counterchecked by root: Windows uses its text-only `{Text}` output and Linux's provider mapping bypasses the generic output-token resolver. Their native receiving is not claimed by this role.

Evidence: `probes/prefix.lua`, `probes/prefix.log`, shared bootstrap `probes/engine.lua`, `probes/contract-excerpts.txt`.

## Actual owner and field coverage

`engine.lua` and the other three owner probes execute the actual macOS Keymap, PersonalInfo, RulesEngine, Registry, Expander, preview bridge, SyntheticInput and FileSystem. The editor reproduction also executes the actual personal editor, UIBuilder and native-close controller. Native immediate app/window/AX/event/timer/pasteboard/WebView ports use the repository's source-backed fixtures. Tooltip and external LLM/keystats collaborators record data; they do not implement personal resolution, matching, masking, saving or output policy. Actual Utils/secure-field classification is exercised over native-shaped app/window/AX objects; no fake “normal window” business classifier is used.

The initial collaborator factory is reused from the existing `test_personal_preview_static_ownership.lua` prefix; the probes do not execute or borrow its test assertions as proof. The production subject remains pinned source. Secondary probes reuse the owned `engine.lua` setup prefix, so replay includes both retained files.

`matrix.lua` executes every default alias:

| Alias | Field                  |
| ----- | ---------------------- |
| a     | street_address         |
| b     | bic                    |
| c     | credit_card            |
| d     | date_of_birth          |
| e, m  | email_address          |
| f     | phone_number_clean     |
| i     | iban                   |
| n     | last_name              |
| p     | first_name             |
| s     | social_security_number |
| t     | phone_number           |
| w     | work_email_address     |

It additionally remaps known alias `p` to each of the 15 declared fields and verifies exact full-value emission plus the private telemetry flag. City, country and postal code therefore have a tested route through a configured existing alias; absence of a default alias is not another finding. Four fields are masked in actual displayed rows—IBAN, BIC, card, SSN—while their emitted values remain complete. Phone values, names, dates, address, city, country, postal code and emails follow the declared unmasked policy. Unicode and multiline data remain literal on emission. The literal `{Tab}` preview delta and newline flattening belong to the existing provider projection mechanism described under deduplication below.

A failed declaration open is tested through the real field-classification binding by refusing only its native file open: previews fail closed, and unknown fields classify masked. No editing of the shipped canon was performed. Invalid scalar field-entry corruption of that immutable canon remains a source-only limit, not an actionable user-data finding.

## Entry, consent, lifecycle and failure sweeps

- **Public routes:** typed @-tags enter PersonalInfo's registered interceptor; private phone/SSN/IBAN prefix mappings enter normal Registry/Expander dispatch. `open_personal_info` action opens the source file through its configured path, while the hotstrings menu's personal editor frame opens the structured form. There is no separate personal-value action catalogue assumed by this audit. Editor fields and field policy enumerate the same 15 names.
- **Default consent:** feature default is off. Although PersonalInfo.start initializes tracking before module reconciliation, `init.lua:2075–2079` applies and verifies the canonical personal-info choice **before eventtap startup**. Menu/runtime synchronization and scope transactions provide later reconciliation. No boot-consent bypass was confirmed. Prefix section controls are independently configured dynamic sections; they are not assumed to inherit the @-combo row's switch.
- **Pause/security/ignore:** `gates.lua` executes actual keymap pause, actual AX secure classification, native unknown focused-window state and actual ignored Hammerspoon-app classification. Each passes the physical key through and emits no personal preview/output. Retired personal callbacks and the stopped keymap remain inert. No native TCC, real protected field or hardware keyboard was exercised.
- **Combos:** actual `pn` output has exactly one intentional Tab key pair, literal brace text stays data, and logical concatenation excludes inter-field separators. Unknown or blank fields decline the entire combo. The keymap buffer authorizes the pending suffix before deletion; mouse/focus invalidation and Alt+Backspace cases are covered by registered regressions. Trigger changes reset pending collection; old magic events cannot expand. Static full-trigger ownership is shared between prospective preview and interceptor, avoiding a preview for a declined combo.
- **Startup/reload ownership:** append-only keymap registrations are token-gated; rejected partial starts and stop invalidate old closures. Duplicate start with a different owner refuses. Real file watchers include personal_info through the hotstrings root or an exact required watcher for uncovered bundle topology (`infra/file_watchers.lua:650–675`), with lifecycle-active fencing and reload debounce. Watcher behavior was source-reviewed; actual FSEvents/reload were not exercised.
- **Save transactions:** actual save validates field names/types, revokes preview, builds a detached candidate, runs real Registry transaction, conditionally publishes through FileSystem, and updates the shared live table only on commitment. Changed external winners are reread and adopted; unchanged I/O refusal retains old state. Registered save/config/registry tests cover stale source, invalid content, writer/fence refusal and live-table identity. PIM-001 concerns what that candidate intentionally omits, not absence of atomic publication. The generic preferences wrapper restores both state and runtime on failed menu persistence; a standalone fake save callback would miss that backstop, so no toggle rollback defect is asserted.
- **Editor:** real construction/session/revision owners fence stale ready/save/navigation/close callbacks. Save refusal keeps the form; successful save closes through the exact native lifecycle. Native delete and close callbacks use the source-backed fixture; they are not actual WebKit/Cocoa events. The shared frontend uses textContent/value rather than interpreting field data as HTML. Full values in the editing form are intentional: preview masking is explicitly not a privacy setting or a constraint on editing/emission.
- **Privacy:** every tested @ alias/field passes `is_private=true` to the telemetry sink. Prefix mappings carry private trigger/output metadata; the source gate checks known log sinks. Private AI context marks are covered by the isolated existing private-expansion tests. This is not an end-to-end real SQL/network/privacy measurement.

## Prior findings, differences and rejected hypotheses

- **MH-001 already owns literal provider preview projection.** The actual personal first-name value `Synthetic {Tab} 雪` emits intact but previews as `Synthetic  雪`. Multiline address previews flatten line breaks. The existing `provider_plain` token projection is the same underlying mechanism as the prior programmable-descriptor report, so no new preview finding is counted. PIM-002 additionally constructs command events through a different Registry/Expander route.
- **MVB-001/MVB-002** concern action-picker initial delivery and an unsaved hotstring draft destroyed after refused save. Neither is re-raised as a personal-editor defect. Personal editor failure/ownership tests are executed rather than assuming another editor's bug applies here.
- Prior **MCF-001** locale publication and crypto/metrics migration roots are outside this file's transactions. The aliases issue was checked against previous flow/config and macOS hotstrings reports; no duplicate was located. Generic “unknown source must be preserved” claims were deliberately not borrowed from the config.toml-only ADR.
- Windows's current native preview path now reads the shared masking policy; the shared fields README's “Windows not wired” paragraph is stale documentation, not proof of a missing capability. Shared/Linux/Windows roles own their counterpart evidence.
- No arbitrary Unicode alias requirement is inferred. The tested added alias is ASCII `x`; remapping existing aliases is a healthy supported control. No claim that the 15-field info schema must accept arbitrary new fields is made.
- Exact event tags, actor generations, clipboard/focus continuation policy and native refusal diagnostics are retained. Previously found cross-family clipboard or multi-item snapshot issues are not counted again merely because long personal values can use those emitters. Performance and memory are unmeasured.

## Verification

The isolated registered selection contains **19 files, 126 passing cases, 0 failures**. The `test_personal_info_editor_port_leak` file registers zero cases; it is not credited as behavioral case coverage. The exact module list and compact per-case receipts are retained in `probes/registered-isolated.json` and `.log`. The initial substring command `tests/run.lua --only=personal_info` matched only six case names across discovery; it is not described as whole-module coverage. Mechanical false-green scan is within baseline. The personal-info log-sink gate passes its declared 27 Windows trigger/18 Lua value sink census; that source gate is not native log/SQL observation.

Reproduce the four actual-owner probes:

```sh
/workspace/scratch/parity-toolchain/ci-bin/lua5.4 /workspace/scratch/parity-sequential-2026-11-05/personal-info/macos/probes/engine.lua /workspace/worktrees/parity-sequential-2026-11-05/macos
/workspace/scratch/parity-toolchain/ci-bin/lua5.4 /workspace/scratch/parity-sequential-2026-11-05/personal-info/macos/probes/prefix.lua /workspace/worktrees/parity-sequential-2026-11-05/macos
/workspace/scratch/parity-toolchain/ci-bin/lua5.4 /workspace/scratch/parity-sequential-2026-11-05/personal-info/macos/probes/matrix.lua /workspace/worktrees/parity-sequential-2026-11-05/macos
/workspace/scratch/parity-toolchain/ci-bin/lua5.4 /workspace/scratch/parity-sequential-2026-11-05/personal-info/macos/probes/gates.lua /workspace/worktrees/parity-sequential-2026-11-05/macos
```

Two final complete bounded dry sweeps after PIM-002 replay the owner proofs and compile/recheck the source owner inventory, with no new roots; timestamps and hashes are in `probes/dry-A.json` and `probes/dry-B.json`. Manifest required fields, guarantee names, unique IDs and evidence paths are independently validated; repository validation rejects external scratch report paths, so no repository copy is created. No native desktop receiving, field focus movement, file durability across power loss, real secrets or user artifacts were accessed or claimed.
