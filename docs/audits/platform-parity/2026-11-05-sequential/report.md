# Sequential feature parity audit

Audited source: `7aecd9a25b35efdcff68898919506dc2f6fd02d0`. Date: 2026-11-05.

This continuation reviews WPM, wrap symbols and personal information in that order. Four isolated, source-identical worktrees were reused: Windows, macOS, Linux and shared contracts. All reviewers stayed on the same module until root adjudication and independent decisive replays closed it. The [phase journal](phases.json) records the order; [worktree provenance](worktrees.json) records source identity and recovery.

The [generated capability comparison](capabilities.md), owned by [JSON](capabilities.json), includes explicit product decisions, native alternatives, constraints, unresolved intent, observed defects and documentation drift. `raw_parity` means matching bounded contract/source evidence, not equivalent native execution. Every row names its evidence and qualifications. Raw reviewer matrices remain available beside the adjudicated comparison; the adjudicated table overrides raw source-presence conclusions where execution exposed a defect.

## Findings and independent evidence

The canonical queue contains **20 entries across twelve bounded OS/shared scopes**, representing eighteen grouped mechanisms. The comparison contains 120 contract/behavior aspects, not 120 independently native-certified features. No production defect is fixed by this audit-only delivery.

Canonical findings are indexed in [index.json](index.json) and tracked in [TODO.md](../../../../TODO.md). OS manifestations sharing a mechanism are grouped in that index, rather than represented as independent shared findings. Empty shared manifests are deliberate. These are findings about code paths, executed owners and modeled native boundaries; Windows findings are source projections. They are not three-desktop reproductions.

### WPM

Five OS-scoped findings: Windows delayed boot-show overrides a newer disable (WPMW-001), and graph drawing reports success after a refused native upload (WPMW-002); macOS canvas never opts into native mouse tracking (WPMM-001), and cached default placement survives display shrink without recomputing its anchor (WPMM-002); Linux clears its shown bookkeeping after a failed resize, preventing a later idle hide of the still-visible native window (WPML-001).

Root replayed the actual Lua owners and Windows source assertions. The canvas contract was independently checked against the exact bundled Hammerspoon 1.1.1 source; AppKit constraints were checked against Apple documentation. Linux's decisive native seam throws before mutation, rather than pretending GTK's void resize function returns a refusal boolean. Root receipts and native contract excerpts are in [root-replays/wpm](root-replays/wpm/receipt.json).

The 36-row shared comparison also records differences in pointer hiding, colour-source priority, idle reset, preview and pause semantics. Pointer hiding and source precedence remain unknown-intent parity decisions. Linux rollback debt is an explicit guarded recovery limitation, not evidence that retry should bypass the guard. Whether `--no-tray` owes a GUI pump remains unresolved because documented headless use conflicts with interpreting it as a tray-icon-only switch. Windows coordinate persistence and its absent menubar readout were already tracked; no duplicate findings were added.

### Wrap symbols

Seven OS manifestations, grouped into five mechanisms: Windows ignores a committed custom pair on its remapped-symbol route (WSW-001), and treats bounded UIA text as a complete selection (WSW-002); macOS/Linux cannot recognize the spaced French guillemet pair during ordinary typing (WSM-001 / WSL-001); macOS loses later pasteboard items during restoration (WSM-002); flattened endpoint aliases remove a still-enabled macOS opener or a Linux menu row (WSM-003 / WSL-002).

The UIA case is conditional on the editor exposing a longer native selection: successful `GetText(8192)` can return a truncated prefix, which the parent marks usable and pastes over the complete selection. Preserve the bounded worker and deadline; detect incompleteness and refuse safely. Do not replace the bound with an unlimited UIA call. Root independently read Microsoft's maxLength/truncation contract. macOS pasteboard evidence executes the exact shipped Hammerspoon 1.1.1 Lua helpers over item-aware native primitives: all formats of the first item are not all items. Healthy single-item controls pass. This is distinct from previously recorded concurrent clipboard ownership and focus defects.

Root replayed ten decisive programs, including both genuine Lua runtimes for the shared parser, real Linux catalogue/menu/configuration owners and four real macOS owner paths. [Root receipts](root-replays/wrap-symbols/receipt.json) distinguish source-only Windows checks, native-shaped boundaries and actual business logic. The shared catalogue has 43 pairs in seven groups. Linux's binding-specific custom delimiters remain available even though pair management is absent; that existing gap is not counted again. Windows's direct remapped guillemet route can work, so a universal Windows guillemet absence would be false.

The macOS combined registered wrap selection reported 255 passes and four order-sensitive fixture failures. The affected delivery fixture passes alone (12/0); the combined fixture omits a production i18n dependency after cached module reuse. These receipts are preserved as test-harness debt, not renamed as native product findings or described as a fully green suite. Linux final registered sweeps execute 290 relevant cases; the shared parser/preference corpus executes 283 assertions on each Lua runtime.

### Personal information

Eight qualified entries: Windows eager compounds escape their intended Tab separators and admit partial empty-field identities (PIW-001), while valid TOML literal values or quoted known keys silently remain placeholders (PIW-002). macOS drops additional admitted alias names and removes them during an unrelated normal save (PIM-001); its automatic personal prefix route interprets accepted data as output commands, although the direct alias emits it literally (PIM-002). Linux drops retained destination admission for multi-field output (PIL-001), ignores the effective configuration directory for this source (PIL-002), and cannot initialize/create the first missing personal source through its editor (PIL-003). The shared prefix-count helper advertises duplicate spaced variants that are not actually generated (PIS-001).

The macOS token case goes through the actual editor/controller/UIBuilder bridge and save owner with synthetic `phone_number='0123{Tab}45'`. Direct `@t` emits the complete literal value with no native Tab; the prefix route emits a Tab command instead. The native WebView and input ports record effects; no real application changed fields. Windows's normal personal prefix defaults to text-only sending, and Linux's provider mappings bypass command-token parsing. This differs from the already tracked macOS preview token stripping, which remains a duplicate rather than a new ID.

Linux's stale-destination proof changes its controlled resident focus during actual layout planning without explicitly invalidating the guard. The actual guard refuses the single-field route with zero output; the combo records fourteen events, including deletion and Tab, into the successor. The regression must retain initial destination authority while allowing intentional later Tab navigation. First-create work must introduce a legitimate absent-source authority, rather than weakening source/session guards. The directory proof uses real configuration paths, bootstrap storage and private TOML writes; the explicit-path control reads the intended file.

All fifteen classified fields, thirteen example aliases, four secret-preview fields and all-field private log treatment are inventoried. Phone and birth date are deliberately unmasked in the preview; the policy requires every personal value to remain private for persistent logging, and expansion should emit the full value. High Windows pre-generation settings have exponential source-level cardinality; no hang, latency or memory experiment was run. Supplementary-character masking, invalid policies, empty parts, static collision precedence, source admission, editor payloads and pause/secure-field gates have separate bounded controls. Existing phone-prefix magic-key and international-zero defects remain linked to their previous TODOs.

Root replayed genuine Lua54/LuaJIT mask/TOML/shared contracts, actual Linux manager/injector/focus and editor/source owners, the actual shared frontend over minimal DOM ports, and source assertions for Windows. Generated native AHK fixtures are retained **unexecuted**; they are not passing Windows tests. Linux's final registered selection passes 191 cases in sixteen modules; macOS isolated files execute 126 cases with no failures (the broad substring selection executes only six). The shared corpus passes 108 assertions on each Lua runtime and its actual frontend runs 39 assertions. The [personal root receipts](root-replays/personal-info/receipt.json) distinguish these bases.

## Automation and evidence boundaries

The existing canonical configuration/action/menu inventory still owns automatic publication: `npm run codegen:feature-inventory`, the normal generator registry and website build regenerate the site data and [configuration inventory](../../../feature-inventory.md); its CI drift guard rejects stale projections. This audit adds a separate, dated behavior comparison. Its renderer rejects stale Markdown; its validator checks twelve manifests, source identity, finding provenance, evidence paths, TODO IDs, module ordering and LF. Negative controls prove that malformed evidence, unsupported guarantee tags, invalid chronology and drift are rejected. Zero findings is accepted; there is no finding quota.

Run from the repository root:

```sh
python3 -B docs/audits/platform-parity/2026-11-05-sequential/render.py --check
python3 -B docs/audits/platform-parity/2026-11-05-sequential/validate.py
python3 -B docs/audits/platform-parity/2026-11-05-sequential/check_validator.py
```

These helpers validate evidence structure and deterministic projection. They do not infer semantic parity from source names, auto-close TODOs, or prove that a native application received an edit. This custom twelve-scope schema is intentionally distinct from the older OS audit CLI envelopes; no passing legacy-CLI receipt is claimed. Each reviewer records two bounded dry sweeps after its last new root. Native Windows execution, Darwin event/AX/pasteboard delivery and Linux desktop acceptance remain explicitly unmeasured where stated. This continuation does not certify global repository exhaustiveness.

## Integration verification

All 33 decisive root programs were replayed after repository formatting; [the receipt](validation/post-format-replays.json) records archived byte hashes, private fixture rebindings, exact commands, output and exit status. This verifies the retained executable evidence, including source-only Windows assertions; it does not turn those assertions into native AHK executions. Formatting/import/identifier cleanup affects audit programs only. Original role matrices, source inventories and submitted findings remain semantically preserved; canonical metadata and named-property normalization are separate. Role artifact-freeze hashes identify the original scratch submissions before repository formatting; they are distinct from production-source hashes and the archived executable hashes in the post-format receipt.

The [source hash receipt](validation/source-hashes.json) covers 496 explicit claims across 167 repository paths. Every claim matches the audited commit, and current production bytes match; the documented TODO drift is expected integration work. Replay its owner with `python3 -B docs/audits/platform-parity/2026-11-05-sequential/validation/source-hash-check.py --check`. It verifies declared hashes, without inventing hash claims for scopes that supplied none.

The audited baseline's later dev CI was not fully green: [run 41960243417](https://github.com/adrienm7/ergopti/actions/runs/41960243417) failed the macOS Intel French input-source fixture deadline and temporary-source cleanup. Its [receipt](validation/baseline-ci.json) distinguishes that run from the preceding green preflight. This campaign's [local validation receipt](validation/local.json) and [complete local gate transcript](validation/local-verify.log) record successful selected gates, including 572 JS checks and the explicitly unexecuted host case. Source-bound hosted results belong to the delivery commit's GitHub CI run; neither native receiving nor a clean baseline is inferred from passing metadata checks.

The [delivery qualification note](delivery.md) records upstream integration, current-checkout replays, source-bound CI attempts and the explicitly documented native/prerequisite gaps.
