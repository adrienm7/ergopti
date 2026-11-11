<!-- docs/platform-parity-audit.md -->

# Ergopti+ platform parity audit

This audit describes the source tree at the time of the change. The generated
[entry-by-entry review queue](feature-inventory.md) is updated from the actual
catalogues, and includes every missing configuration path, bindable action and
platform-restricted interactive menu entry, with action alternatives and menu reasons. An
entry is not the same thing as a user-facing capability: an OS can provide the
same capability through a different path. A declaration is not a runtime or
hardware test.

## Review status at pause — November 5, 2026

The maintainer requested a pause after the dead-key campaign delivered in
`04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9`. This register describes the work
already recorded in the repository; it starts no additional audit. Each dated
report owns its audited revision, exact coverage, rejected hypotheses and proof
limits. **Deeply reviewed does not mean fixed, bug-free or native-certified.**
Later corrections and adjudicated findings take precedence over raw submissions.

### Focused cross-platform investigations already recorded

These campaigns follow named flows through their owners, callers and settlement
boundaries. Their scope includes Windows, macOS and Linux, with shared review
where the linked campaign records it. The links retain the per-OS detail;
a row is not a claim that every function or every physical scenario was tested.

| Area                           | Reviewed in depth                                                                                                                                                                                                         | Evidence                                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Dead keys and composition      | Pending-state ownership, disabled rows, grouped character payloads, consumed continuations, chains and converter/locale collisions; six shipped layouts, 140 states and 4,391 explicit converter expectations             | [Dead-key campaign](audits/platform-parity/2026-11-05-dead-keys/report.md)                                               |
| Tap-holds, chords and layer    | No-hold tap rules, lone tap window per rule, pair first-key choice, pair tap/layer interplay, chord defaults, macOS generator per-key rules; source and model replays, no native receiving                                | [Tap-hold campaign](audits/platform-parity/2026-11-10-tap-holds/report.md)                                               |
| Hotstring cascade and undo     | Cascade link choice, private/key/no-op winners, final-entry outranking, delay masking, bare `:` end characters, Backspace undo eligibility/casing/failure, dynamic and personal tags; engine replays, no native receiving | [Hotstring cascade campaign](audits/platform-parity/2026-11-11-hotstring-cascade/report.md)                              |
| Gestures and touchpad          | Incremental diagonal travel and reversal, axis lock in the diagonal band, click hold release, contact join, sensitivity; engine replays on the Lua drivers, no touchpad or AHK receiving                                  | [Gestures campaign](audits/platform-parity/2026-11-11-gestures/report.md)                                                |
| One-shot Shift                 | Public activation, next-key consumption, modifier context, repeated presses, timeout and retirement                                                                                                                       | [One-shot campaign](audits/platform-parity/2026-11-05-one-shot-shift/report.md)                                          |
| CapsWord                       | Activation, accepted output, delimiter exits, timers, pointer identity, configuration publication and synthetic-key counterchecks                                                                                         | [CapsWord campaign](audits/platform-parity/2026-11-05-caps-word/report.md)                                               |
| Word reset and AI context      | Independent word/context lifetimes, following keys, edited controls, synthetic origins and lifecycle retirement                                                                                                           | [Word-reset campaign](audits/platform-parity/2026-11-05-word-reset/report.md)                                            |
| Repeat and immediate recovery  | Magic-key repetition, corrections after repeat, word boundaries, private ancestry and eligible immediate Backspace restoration                                                                                            | [Repeat/recovery campaign](audits/platform-parity/2026-11-05-undo-repeat/report.md)                                      |
| WPM                            | Widget publication, native draw/resize refusal, placement, pointer handling, idle behavior and configuration precedence                                                                                                   | [Sequential campaign: WPM](audits/platform-parity/2026-11-05-sequential/report.md#wpm)                                   |
| Wrap symbols                   | Pair catalogue, custom pairs, spaced delimiters, selection completeness, clipboard restoration and endpoint aliases                                                                                                       | [Sequential campaign: wrap](audits/platform-parity/2026-11-05-sequential/report.md#wrap-symbols)                         |
| Personal information           | Field/alias generation, literal values, command-token boundaries, source location, first creation, destination authority and preview/privacy rules                                                                        | [Sequential campaign: personal information](audits/platform-parity/2026-11-05-sequential/report.md#personal-information) |
| Managed local runtime          | Provisioning, deadlines, refusal, repair authority, source identity, native settings and completion/retirement boundaries                                                                                                 | [Runtime/editor/diagnostics campaign](audits/platform-parity/2026-11-05-native-ui/report.md)                             |
| WebView editors                | Shared frontend and host joins, zero-valued delays, save/reload/close refusals, draft preservation and configuration serializers                                                                                          | [Runtime/editor/diagnostics campaign](audits/platform-parity/2026-11-05-native-ui/report.md)                             |
| Diagnostics                    | Collection/export/page joins, backend and disabled-state reporting, partial output, timer refusal and local versus shared privacy                                                                                         | [Runtime/editor/diagnostics campaign](audits/platform-parity/2026-11-05-native-ui/report.md)                             |
| Folder/configuration migration | Destination collisions, physical aliases, locators, alternate roots, refusal, retry and next-start adoption                                                                                                               | [Migration/update campaign](audits/platform-parity/2026-11-04-recovery/report.md)                                        |
| Update/reload handoff          | Chosen-release transactions, leases, armed installation, restart receipts, native alternatives and package-manager ownership                                                                                              | [Migration/update campaign](audits/platform-parity/2026-11-04-recovery/report.md)                                        |
| Clipboard and selection        | Borrow/restore ownership, concurrent clipboard changes, target focus/range and cross-owner transformations                                                                                                                | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |
| Credentials and cipher storage | Typed ingress, persistence markers, SQL/storage joins, credential publication and cryptographic native-component controls                                                                                                 | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |
| Configuration persistence      | Save/publication refusal, authoritative next-start values, durable ownership and truthful saved/applied/restarted reporting                                                                                               | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |
| Fixed desktop actions          | Actual dispatch, acknowledgment/refusal and overlapping native setting changes through bounded worker controls                                                                                                            | [Action/persistence flows](audits/platform-parity/2026-11-04-flows/report.md)                                            |

### Broader module reviews already recorded

The [18 OS × module review](audits/platform-parity/2026-11-04-deep/report.md)
already inspected hotstrings, input/remapping, AI, metrics, lifecycle and
gestures separately on all three OSes. The [earlier module review](#independent-module-review-2026-11-04)
also records their declarations, implementations and corrected false gaps.
These areas are **not untouched**. Their broad reviews do not replace a focused
end-to-end campaign for every submodule listed below. The later focused
campaigns above extend particular parts of that coverage.

### Remaining investigation, implementation and qualification

The root [TODO](../TODO.md) remains the only implementation checklist and the
owner of individual finding IDs, policy questions and physical acceptance.
This section records investigation boundaries, not a duplicate checklist.
No new investigation is being launched at this pause.

| Remaining work                                    | Starting point and boundary                                                                                                                                                                                                                                                    |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Reconcile coverage with current source            | Generate a fresh source-area census and match its areas to the dated coverage registers. Classify unmatched or changed areas as requiring review; file presence alone never establishes review or feature parity.                                                              |
| Next focused module: tap-holds, chords and layers | Deepen the existing input review: activation/rollover arbitration, held modifiers, repeats, remapped versus native ownership, simultaneous devices, pause/reload/source change and actual action settlement. Keep all OS/shared reviewers on this one module before advancing. |
| Hotstring cascade and trigger arbitration         | Deepen the broad hotstrings review beyond the separately covered repeat, CapsWord and personal-data routes: automatic/terminator cascades, precedence, delay admission, Unicode/word boundaries, preview/output agreement and interrupted output.                              |
| Gestures and touchpad event ownership             | Deepen the existing gestures review with complete slot-to-action flows, axis/threshold/repeat handling, device/session capability, disconnection and retirement. Real hardware acceptance remains separate.                                                                    |
| Metrics beyond the WPM widget                     | Follow each producer through collection/privacy, persistence/ledger, aggregation, export and dashboard display. The broad metrics findings already exist; verify units, missing producers and cross-device behavior without recounting them.                                   |
| AI request-to-output flows                        | Deepen the broad AI review for prediction/streaming, cancellation/successors, retry/refill, model/profile changes and deferred agent/connectors. Managed-runtime provisioning is already a separate focused campaign; live-provider interoperability is still distinct.        |
| Remaining input/layout engine joins               | Extend the existing input and dead-key work to full shortcut/layout/number-row/replay ordering, modifier/source currency and multidevice state. Do not count an emulation path as equivalent to native layout receiving without proof.                                         |
| Fix and regress existing findings                 | Reconfirm each issue against current code before implementing its TODO entry. Audit probes preserve observations; they are not fixes or wired regression tests. Deduplicate overlapping reports and retain intentional differences.                                            |
| Resolve product policy                            | Keep existing behavior until a common contract is decided for unresolved fallback, expiry, pause, modifier attribution, privacy or preview questions. Source-visible differences are not automatically intended differences.                                                   |
| Windows receiving                                 | Qualify the relevant original callbacks, installed HKLs, AHK/InputHook/SendEvent, UIA/WebView2 and target applications on Windows. Portable source projections and Linux PowerShell are not these native receipts.                                                             |
| macOS receiving                                   | Qualify NSEvent/dead-key/IME payload grouping, event consumption/output, Hammerspoon/WebKit and lifecycle/service boundaries on a Mac. Controlled Lua ports and dependency-source contracts do not certify a receiver.                                                         |
| Linux receiving                                   | Qualify the active X11/Wayland session, compositor, evdev/uinput/device lifecycle and receiving application. Genuine libxkbcommon/Compose, filesystem and libuv controls cover components, not the entire desktop.                                                             |
| Timing, memory and failure durability             | Measure real typing latency, long-session retention, native races, power-loss recovery, signing/provisioning and relevant provider/network failures. No global G4/RSS guarantee follows from the source audits.                                                                |
| Maintain automatic inventories                    | Keep the normal catalogue generators, reason/localization checks and drift guards current. Add reviewed behavior declarations for newly identified semantics; automatic catalogue discovery does not discover every behavior or prove native equivalence.                      |

The source-area navigation tool can create a fresh **external** snapshot without
rewriting historical audit evidence:

```sh
python3 -B tools/audit/source-areas.py --ref HEAD --output /tmp/ergopti-source-areas-current.json
```

When work resumes, read the relevant report's coverage and source receipts,
verify source drift, then choose one bounded module from the table. Reuse the
original-owner probes through their documented safe replay mechanism. Some
historical helpers write sibling receipts or embed retired checkout paths;
never run them in place in immutable evidence. Do not infer completeness from
two dry sweeps, a source-file count, declaration coverage or a green generic CI.

### Verification status retained at the pause

The dead-key delivery records 572 passing JS checks, successful final formatting,
source/custody checks and independent replays in its
[qualified local receipt](audits/platform-parity/2026-11-05-dead-keys/validation/verification.json).
Its initial archive-format failure and correction are preserved there.

[Preflight 42121216727](https://github.com/adrienm7/ergopti/actions/runs/42121216727)
on `04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9` finished with failure.
The originating failed job was **Common / Install and launch (Stable site)**,
at **Install production site browsers**; Common's verdict and the final lane
verification consequently failed. That step is not a successful browser/render
receipt. The root TODO retains the final-source CI checkpoint and the separate
native/physical qualification work. No CI workflow is cancelled or relaunched
as part of this documentation checkpoint.

## Dead-key composition continuation

The [November 5 dead-key audit](audits/platform-parity/2026-11-05-dead-keys/report.md) follows four OS/shared owners at `f2c3ea43542c985fb20e5f0887976f1c02525341`. Five roots cover disabled-row continuation routing, grouped macOS payload lookup/output, consumed Linux Compose history and inherited Bépo Compose prefixes. The [generated 13-contract comparison](audits/platform-parity/2026-11-05-dead-keys/capabilities.md) preserves intentional architecture, native policy, known limits and unresolved lifecycle questions. Six registry layouts, 140 states and 4,391 explicit converter expectations are checked; 97 distinct named source paths are authenticated. Genuine native component tests and original owners over controlled ports do not establish actual application receiving. Reproduction/check commands and immutable worker custody are retained in the campaign README; implementation and policy work remains in the root TODO.

## One-shot Shift continuation

The [November 5 one-shot Shift audit](audits/platform-parity/2026-11-05-one-shot-shift/report.md) keeps four OS/shared reviewers on activation, consumption, modifier context, repeated presses and retirement at `9c565c88c9a1366a2e9b18c1b9d2868509510975`. Its90 qualified coverage summaries are not90 native scenarios. Five OS-scoped findings cover Windows named-control modifier attribution, macOS/Linux Caps+Shift title selection, the macOS programmatic timeout domain and Linux repeat ownership. The [generated comparison](audits/platform-parity/2026-11-05-one-shot-shift/capabilities.md) documents the deliberate tap-only Linux route, action aliases, trigger defaults and configuration differences. Replays authenticate original-owner behavior over declared ports; a separate genuine XKB component check does not establish desktop receiving. The dated source checker rejects changed reviewed bytes, and projection controls reject stale or unqualified metadata.

## CapsWord activation and termination continuation

The [November 5 CapsWord audit](audits/platform-parity/2026-11-05-caps-word/report.md) follows public activation, accepted output, configurable termination, timers, pointer identity and retirement at `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`. Four pinned OS/shared reviewers retain159 initial qualified rows and nine new findings. A further synthetic-key countercheck extends existing WRSL-001 with a CapsWord consumer instead of counting a second connector root. The [generated capability comparison](audits/platform-parity/2026-11-05-caps-word/capabilities.md) distinguishes deliberate Windows next-activation settings, macOS fixed exits, gesture constraints, ambiguous common policy and the observed menu/timer/publication mismatches. Native receiving and corrected fixture limits are explicit.

## Word-reset and AI-context continuation

The [November 5 word-reset audit](audits/platform-parity/2026-11-05-word-reset/report.md) follows the repeat/recovery closure at the same `b17e47e` source. Four reviewers compare independent word/AI lifetimes through the following key, synthetic action origins, edited controls, terminal receipts and lifecycle retirement: 98 coverage rows and five qualified findings. The [generated comparison](audits/platform-parity/2026-11-05-word-reset/capabilities.md) retains explicit macOS tap-hold-origin limits, idle architectures, conditional keypad-Enter receiving and unresolved modifier policy. Root replays include a matched-default physical/action Linux arrow control; no native desktop or AHK receiving is claimed.

## Repeat and recovery continuation

The [November 5 repeat/recovery audit](audits/platform-parity/2026-11-05-undo-repeat/report.md) keeps four OS/shared reviewers on one bounded module at source `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`. Its 85 aspect rows follow repeat through actual caller publication, following corrections, word boundaries, private ancestry and immediate Backspace recovery. The [generated comparison](audits/platform-parity/2026-11-05-undo-repeat/capabilities.md) separates explicit preview policy, application Undo, unestablished intent and native receiving gaps. A [supplementary live behavior catalogue](behavior-inventory.md) now reaches the site and documentation, with reviewed-owner drift checks; it does not infer semantic exhaustiveness.

## Sequential WPM, wrap and personal-information continuation

The [sequential November 5 audit](audits/platform-parity/2026-11-05-sequential/report.md) keeps four OS/shared reviewers on the same module before advancing: WPM, wrap symbols, then personal information, at `7aecd9a25b35efdcff68898919506dc2f6fd02d0`. It adds independently replayed owner evidence, qualified Windows source projections and a [generated capability/intent comparison](audits/platform-parity/2026-11-05-sequential/capabilities.md). Canonical findings, shared mechanisms, known duplicates, policy questions and native receiving gaps remain distinct. The root TODO tracks the open findings; dated validators check evidence and projection drift without claiming automated semantic parity.

## Native runtime, editor and diagnostics continuation

The [nine-scope November 5 audit](audits/platform-parity/2026-11-05-native-ui/report.md) follows managed runtime/provisioning, WebView editors and diagnostics separately on each OS at `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. It retains 15 qualified findings, documents intentional differences and refuted hypotheses, and adds an automatic source-area register alongside the existing generated feature inventory. Source presence and declared availability remain distinct from verified native behavior. The [capability comparison](audits/platform-parity/2026-11-05-native-ui/capabilities.md) and root TODO record the concrete follow-ups.

The [Nix delivery follow-up](audits/platform-parity/2026-11-05-native-ui/delivery-nix.md) preserves the native process owner while transporting the enlarged Git inventory outside its bounded result capture; its local controls do not claim an installed-Nix build.

## Migration and update continuation

The [six-scope recovery audit](audits/platform-parity/2026-11-04-recovery/report.md) covers the previously excluded folder migration and updater/reload handoff at `3a680d9f530a9af686fccc16d3f7611ec7fb034c`. It adds 17 qualified OS follow-ups and a [machine-readable, rendered capability/intent comparison](audits/platform-parity/2026-11-04-recovery/capabilities.md). Actual native boundaries, shared causes, receiving gaps and two final dry passes are explicit; the Windows updater scope adds controls without a new confirmed root.

## End-to-end continuation

The [12-scope flow audit](audits/platform-parity/2026-11-04-flows/report.md) follows clipboard/selection, crypto/credential storage, configuration publication and fixed native system actions through their actual acknowledgment and cleanup boundaries at `213d65af24d2aa4845ba47743c9bab6787b61964`. Its 26 OS/flow follow-ups include shared causes, explicitly qualified source-only Windows cases and an approved-overwrite data-loss risk. [Intentional behavior and constraints](audits/platform-parity/2026-11-04-flows/intentional-differences.md) remain separate from defects. Canonical declarations still do not certify native behavior.

## Deep review by OS and module

The [18-scope deep audit](audits/platform-parity/2026-11-04-deep/report.md)
examines each combination of Windows/macOS/Linux and hotstrings, remapping,
AI, metrics, lifecycle and gestures at commit
`89b0b774c8c960c7ad458ac3cb98d5c97598e518`. It supersedes earlier availability
conclusions wherever explicitly corrected. Its [intentional-difference register](audits/platform-parity/2026-11-04-deep/intentional-differences.md)
documents rationale, user-visible effects and OS equivalents, distinguishing
explicit policy from native constraints, guarded unfinished work and unknown
product intent. The JSON companion preserves the same audit-snapshot data.

The deep pass produced 30 OS-scoped actionable entries, including a guarded
unfinished capability and a conditional account-context scenario. These are not
30 native-reproduced bugs. Per-entry severity, confidence and reproduction
basis are in the [Windows](audits/platform-parity/2026-11-04-deep/windows-envelope/report.md),
[macOS](audits/hammerspoon/2026_11_04/report.md) and
[Linux](audits/linux/2026_11_04/report.md) envelopes. The same restart-reporting
root cause affects two OSes. Policy candidates and refuted hypotheses are kept
out of the confirmed queue.

**Corrections:** physical shortcut delivery/editor qualification is disabled on
both Lua drivers as well as missing on Windows. Bridge/capture code and test
fixtures did not establish real feature readiness. Windows inline auto-type
inserts a completed continuation, not tokens as they arrive. Complex-key
expansion-delay widening exists on all three drivers; older Mac-only wording
is stale. Current declaration matrices do not establish these runtime facts.

## Independent module review, 2026-11-04

Five parallel, read-only reviewers examined production code and callers at
`c2fa619`, rather than treating catalogue membership as behavioral proof. The
integration review reopened their evidence and independently reproduced the
phone/date matcher output using the real Lua modules with synthetic data. No
native three-OS certification was performed.

| Module                                                        | Coverage                                                                                | Result and evidence                                                                                                                                                                                                       |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Hotstrings](audits/platform-parity/2026-11-04/hotstrings.md) | Static/dynamic/personal/programmed expansion, input gates, previews, private sources    | Three behavior differences: Linux shortest phone prefix fires without magic key; Lua international output retains the national zero; Windows date triggers and boundary semantics differ. Pure Lua reproduction included. |
| [AI](audits/platform-parity/2026-11-04/llm.md)                | Predictions, profiles, local/remote models, tone, translation, vision, agent/connectors | Linux lacks the bounded retry/refill policy implemented on Windows/macOS. Windows retry TODO refuted. Core AI families have real implementations; native connectors differ.                                               |
| [Input](audits/platform-parity/2026-11-04/input.md)           | Tap-holds, holds/chords, layers, layouts, physical editor, gesture vocabulary           | macOS typing-priority rollover differs from release-order classification; working live number-row control is missing from its onboarding. Hold-picker test only establishes Windows/Linux agreement.                      |
| [Metrics](audits/platform-parity/2026-11-04/metrics.md)       | Producers, persistence, ledger sync, aggregation, dashboards, WPM, privacy              | Linux lacks ledger synchronization and some producers; pointer distance units differ. Windows owns extra raw telemetry. Space-change KPI is only actually produced on macOS; night-wake is inert on every OS.             |
| [Lifecycle](audits/platform-parity/2026-11-04/lifecycle.md)   | Installation/startup/uninstall, updater, backups, onboarding, diagnostics, bundled apps | macOS-only diagnostics availability explanation and signed newest-channel feed-install fallback. Linux packaged updates intentionally belong to the package manager. Backup scope qualifications documented.              |

The detailed reports record tests actually executed, source-only conclusions,
rejected hypotheses and remaining environmental limits. The metrics SQL tests
were not green under this environment's Node 24 NUL-string handling; this was
not promoted into a production parity defect. Each confirmed gap is tracked in
TODO. Finding a behavior difference does not authorize silently changing an
explicitly tested product contract, such as Windows's date trigger vocabulary.

### Generation coverage and limits

The normal generator registry and website prebuild now own the inventories.
Website builds refresh the menu projection first, then regenerate availability;
`npm run gen` and the standard generated-output drift guard share its declared
output paths. Every one of the 197 restricted configuration entries has a
translated explicit or matching-section reason. This checks declaration
coverage, not runtime equivalence.

The generated tap-hold key table reads the live `tap_hold.catalog.keys`: native
Command/Option versus Win/AltGr identities are shown without counting them as
missing product functions. The hold picker is not universal: the actual macOS
picker filters its native catalogue, while Windows/Linux enumerate the shared
PC modifier combinations. Gesture slot actuation, onboarding conditions,
installation ownership, real provider availability and telemetry producers
require the module-specific qualifications above. New unregistered runtime
behaviors cannot be discovered reliably from a manifest alone.

## Sources and checks

- Configuration and settings: `_shared/modules/features/manifest.toml`, resolved
  with the same platform inheritance as the driver generator. The existing
  Linux evidence gate checks registration, calls, application and proof tiers.
- Bindable actions and gesture axes: `_shared/modules/actions/actions.toml`.
  Its generator requires a reason for each missing platform and validates named
  equivalents; driver suites compare generated catalogues to executable actions.
- User-visible unavailable controls: `_shared/modules/menu/menu.toml` and its
  generated `menu_manifest.json`. Restricted interactive rows and rows with `unavailable = "grey"` supply the
  platform-specific reason where declared. The menu's own drift and dispatch gates remain the
  authority for its projection and handlers.
- Additional capabilities: compared the three driver module and UI trees,
  runtime entry points, platform-specific action reasons, and the bundled macOS
  app descriptions. Files with matching names are leads, not proof of parity.

The layer editor has an additional canonical vocabulary:
`_shared/keymap/layer_actions.toml`. Its actions, modifier restrictions, input
source kinds and parameters are included in the generated action inventory as
`layers.*`. Mouse-button sources exclude Linux, repeat counts are Windows-only,
and Fn and Spotlight belong to macOS. The source explains each restriction.

## Findings beyond individual configuration paths

| Capability                                                  | Windows                                    | macOS                                                          | Linux                                                                                      | Evidence and qualification                                                                                                                                                                           |
| ----------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Physical shortcut editor                                    | Unavailable: no host                       | Unavailable: native delivery unqualified                       | Unavailable: native delivery unqualified                                                   | Actual macOS/Linux `keyboard_shortcuts.physical_delivery_available()` both return false; deep input reports supersede declaration-only readiness claims. Preserve fail-closed admission.             |
| Token-by-token prediction display                           | Unvalidated and disabled                   | Declared                                                       | Declared                                                                                   | `llm_token_streaming` menu row; distinct from typing predictions directly into a document                                                                                                            |
| Automatic insertion of a completed continuation             | Declared, completed response only          | Bubble then accept                                             | Bubble then accept                                                                         | Windows `inline_autotype` is not token-by-token document streaming; deep Windows AI report records the native output constraint.                                                                     |
| Prompt profile automatically follows model                  | Declared                                   | Applied on request                                             | Declared                                                                                   | `platform_reason.llm_profile_follows_model_is_not_on_macos`                                                                                                                                          |
| Tap-hold word-reset option                                  | Declared                                   | No equivalent option                                           | Declared                                                                                   | `platform_reason.tap_hold_word_reset_not_on_macos`; macOS Karabiner input follows the shortcut option                                                                                                |
| Bulk copy tap assignments to chord slots                    | Not exposed                                | Declared                                                       | Declared                                                                                   | `key_combinations_group.copy_tap_to_combo`; no Windows implementation found in the driver tree                                                                                                       |
| Layout-only restore/clear                                   | Declared                                   | Declared                                                       | Hidden; global restore/clear includes the scope                                            | `layout_menu` and Linux `infra/keyboard_layout_scope.lua`. The menu comment says Linux has no layout settings, but its live number-row and pause-layout controls warrant rechecking that assumption. |
| Shortcut-only restore/clear                                 | Declared                                   | Configuration restore combines shortcut and Karabiner settings | Declared                                                                                   | `scope_restore` and `scope_clear` in `shortcuts_menu`                                                                                                                                                |
| Continuous gesture axes and step sizes                      | Discrete system gestures                   | Continuous                                                     | Discrete                                                                                   | `ax_actions` and `platform_reason.gesture_modes_and_steps_are_macos`; catalogue records discrete equivalents                                                                                         |
| Extra touchpad slots                                        | Three/four finger system slots             | Two to five fingers, including diagonals                       | Shared gesture slot set, subject to device/session                                         | `actions.toml` slots and Windows touchpad reason; actual device support requires testing                                                                                                             |
| Floating WPM widget                                         | Implemented                                | Implemented                                                    | Implemented                                                                                | Windows `ui/wpm/wpm_widget.ahk`, macOS `ui/wpm/wpm_widget.lua`, Linux `ui/wpm/widget.lua` and runtime registration. Linux availability is not hardware proof.                                        |
| WPM in system bar                                           | Notification area                          | Menu bar                                                       | Notification area                                                                          | Same contract on all three (decision 2026-11-06)                                                                                                                                                     |
| Wrap-symbol pair management                                 | Custom add/delete and bulk controls        | Custom add/delete and bulk controls                            | Fixed-pair invocation; no custom/bulk menu controls                                        | Linux `ui/menu/menu_shortcuts.lua`; shared `wrap_symbols_*` control rows filter Linux                                                                                                                |
| Focused-application identity                                | Native API                                 | Native API                                                     | X11 and selected Wayland compositors; unavailable on GNOME, KDE, COSMIC and Weston Wayland | `linux/adapters/window_info.lua`; unknown identity constrains per-application rules and is not equivalent to an empty application                                                                    |
| Tap-hold copy confirmation                                  | Check supported by platform implementation | Check supported by platform implementation                     | Unchecked on Wayland or X11 without xclip                                                  | `linux/platform/remap/tap_copy.lua`: copy is sent, but the counter-dependent retry and warning cannot run                                                                                            |
| Pointer center, teleport, spotlight                         | Declared                                   | Declared                                                       | No implementation                                                                          | `sg_actions` reasons: Wayland restricts pointer moves/overlays; X11-only implementations remain potential work                                                                                       |
| Open terminal or create file in current file-manager folder | Declared                                   | Declared                                                       | No implementation                                                                          | Action catalogue records lack of a common Linux file-manager interface; per-file-manager support remains potential work                                                                              |
| Accented-key shortcut remapping                             | Declared                                   | Native layout control/command layer                            | No equivalent                                                                              | `platform_reason.accented_shortcuts_are_windows`                                                                                                                                                     |
| MLX local inference                                         | Not applicable                             | Apple Silicon                                                  | Not applicable                                                                             | `platform_reason.llm_mlx_is_apple_silicon`; Ollama is separate                                                                                                                                       |
| Keyboard layout emulation                                   | Declared                                   | Installed system input source                                  | Installed XKB layout                                                                       | `platform_reason.layout_emulation_is_windows_only`; these are different installation models                                                                                                          |
| App Cloner bundled application                              | No bundled counterpart found               | Bundled                                                        | No bundled counterpart found                                                               | `macos/apps/App Cloner.app/Contents/Info.plist`; separate app clones and profiles                                                                                                                    |
| Encryptor bundled application                               | No bundled counterpart found               | Bundled                                                        | No bundled counterpart found                                                               | `macos/apps/Encryptor.app/Contents/Info.plist`; file encryption/decryption is distinct from text and metrics encryption                                                                              |

Some missing menu rows have equivalent providers rather than missing features: Linux's
`llm_generation` provider exposes min/max words, temperature, prediction count
and context length even though the native Windows/macOS presentation rows are
absent. See `linux/ui/menu/menu_llm.lua` and `modules/llm/settings.lua`.

Windows programmable hotstrings are an equivalent presentation rather than an
absence: `ui/menu/menu_submenus.ahk` calls `_HS_ProgrammableHotstringRows`, whose
commands open, reload or repair the user's source. Likewise Linux prompt actions
reach `prediction_engine.trigger_prompt` through `llm_prompt_prediction`; the
absence of macOS's per-profile shortcut dialog does not remove prompt actions.

The English catalogue also contains stale Linux claims. The reason
`platform_reason.llm_configuration_surface_is_not_on_linux` says Linux has no
backend, profile, trigger or display surfaces, while `linux/ui/menu/menu_llm.lua`
provides them and `menu.toml` explicitly selects Linux's inline generation
provider. `platform_reason.metrics_extras_are_not_on_linux` says there is no
per-application exclusion, while `linux/ui/menu/menu_metrics.lua` and
`modules/keystats/keystats.lua` implement it. These strings are not reliable
proof of absence; correcting and propagating their translations is tracked in
TODO. The Linux action `open_personal_shortcuts` additionally resolves
`personal_shortcuts.toml`, but the declared editable shortcut owner uses
`config.toml`; no production reader of that file was found in this tree. Its
actual behavior requires verification and is tracked separately.

The complete action-level list also includes OS-specific system commands,
keyboard shortcuts, sticky modifiers and equivalents. For example, a missing
macOS `copy` action is provided as a modifier/key combination, and a missing
Windows executable-permission action reflects the OS permission model. The
queue deliberately retains these entries with reasons instead of counting all of
them as missing product features.

The comparison does not establish that every unregistered feature has been
identified, nor that all declared features behave identically. New capabilities
must be registered in the appropriate shared catalogue; code review and runtime
or hardware tests remain necessary to establish behavior. Linux evidence tracks
hardware proof independently of software registration.
