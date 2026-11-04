# Linux clipboard, selection and text transformations

Audited SHA: **213d65af24d2aa4845ba47743c9bab6787b61964**. Date: 2026-11-04. Scope: Linux clipboard borrowers, selection capture/replacement, text case/wrapping, plain paste and file-selection/open/search actions. Read-only audit; production and registered test files unchanged. Artifacts are confined to `docs/audits/platform-parity/2026-11-04-flows/linux-clipboard/`.

Applied `.agents/skills/adversarial-audit/SKILL.md` and its report contract, Linux/cross-driver principles and routed text/clipboard memory. The user/parent-authorized scratch destination overrides the skill's default repository report destination.

Four new issues were reproduced with actual production Lua modules and recording native boundaries. This is **not** real clipboard, native application, display-server or input-injection validation. Prior 18 deep reports and TODO were searched for duplicates: these findings do not recount the known Wayland/X11-without-xclip copy-confirmation limitation, metrics clipboard collectors, or old hotstring/LLM/gesture findings.

## Confirmed findings

### LCP-001 — Clipboard borrowing silently discards the user's non-text formats

Severity: **medium**. Confidence: **high**. Guarantees: G1, G2.

A clipboard containing both plain text and HTML/RTF/file-related representations is not restored intact after a Linux text transformation or clipboard-based output. The action can report success and restore the same visible text while silently losing the other representations. A later paste into a rich editor/file manager behaves differently.

Production chain, paths relative to `static/ergopti_plus/`:

- Explicit case/wrap actions enter `linux/modules/shortcuts/manager.lua:590` (`transform_selection`) or `:373` (`M.wrap_selection`), then `Clipboard.transform_selection`.
- `linux/adapters/clipboard.lua:99` (`backend`) selects a **single text read/write** command: wl-paste/wl-copy, xclip, or xsel. It does not enumerate or snapshot MIME targets.
- `clipboard.lua:186` (`read_restorable_snapshot`) captures only that string; it rejects NUL but never asks whether other targets must be preserved.
- `clipboard.lua:175` (`write_backend_checked`) passes only that text to the selected writer, acquiring new clipboard ownership without the old HTML/RTF/file representations.
- `clipboard.lua:629` (`M.transform_selection`) restores only the saved string at `:646`/`:676`; `M.read_selection :574`, `M.read_selection_uri_list :595`, `M.paste_text :462` and `M.new_paste_stage :374` share the same text-only snapshot mechanism.

Reproduction: `probes/clipboard-flows.lua` executes the real adapter for X11 and Wayland against a modeled clipboard offering `text/plain="saved"` plus `text/html="<b>saved</b>"`. The recording tool boundary models the actual text-only publication: no HTML is supplied by the adapter. A real Unicode uppercase transform succeeds, pastes `SELECTED`, and ends with plain `saved`, **HTML nil**. All shell calls/writes are recorded; no real tool is launched.

Silent failure: successful return and matching visible plain text hide the loss. Existing snapshot-restorability tests correctly reject NUL and unreadable content, but do not establish preservation of multiple targets.

OS comparison: macOS `macos/adapters/clipboard.lua:120` saves `hs.pasteboard.readAllData()` and `:152` restores `writeAllData`; `macos/modules/shortcuts/actions/text.lua:487` captures all types for text actions. Windows `windows/adapters/clipboard.ahk:1035` (`CB_SaveAll`) uses `ClipboardAll()`, with ownership-aware restore APIs. These are inspected production mechanisms, not native runs. Linux's limitation is explicit in its **implementation shape**, but no maintainer decision authorizing destruction of the user's other formats was found.

Regression: start with plain+HTML/RTF/URI data, perform each borrower route, and verify all original targets/bytes survive or mutation refuses before borrowing. Do not fix only the generated feature matrix or merely compare restored plain strings.

### LCP-002 — Text transforms overwrite a newer external clipboard copy

Severity: **medium**. Confidence: **high**. Guarantees: G1, G3.

If another application copies new content while a Linux case/wrap transformation waits for paste settlement, the old clipboard snapshot is unconditionally written over it. The transform still returns success. This differs from Linux's existing ordinary paste path, which already preserves a changed clipboard.

- `linux/adapters/clipboard.lua:643` (`M.transform_selection` local restore) always calls `write_backend_checked(b, saved)`.
- After copy/set/paste waits, the unconditional restore at `:676` does not prove the current clipboard still belongs to this transaction.
- `M.read_selection :579` and `M.read_selection_uri_list :617` also restore unconditionally; their exact timing cases were source inspected, while the transformation route is the independently reproduced case.
- By comparison, the same adapter's `holds_pasted_text :203` and `M.paste_text :505` avoid restoring over a different value. `new_paste_stage` has a corresponding check at `:389`. Thus preserving an intervening copy is an actual existing requirement, not a newly invented policy.

Reproduction: on both X11 and Wayland recording backends, inject `external-copy` at the final transform wait. The real transform returns true and final clipboard is `saved`. A control using the real `paste_text` with the same kind of intervening copy ends with `external-copy`, confirming the modeled boundary and existing preservation behavior.

Silent failure: no refusal or foreign-ownership log is emitted by the transform restore; the newer content disappears after the user action otherwise succeeded.

OS comparison: macOS `modules/shortcuts/actions/text.lua:315` (`restore_text_clipboard`) checks native change count and revokes its snapshot on a new generation, including identical text (`:335`). Windows `adapters/clipboard.ahk` retains explicit clipboard transaction generations/owners and conditional restore debt. Those mechanisms establish stronger ownership contracts by source; no claim is made that all native clipboard managers/platforms are immune to every race.

Regression: change clipboard generation/content after copy, replacement staging and paste on success/refusal paths; assert a newer owner survives. Preserve a genuine owed restore after a partial/failed own write. A simple unconditional “skip every changed value” rule must not erase existing restoration-debt guarantees.

### LCP-003 — Case/wrap transforms can replace a different selection inside the same text field

Severity: **high**. Confidence: **high** for the real-module/model result; native editor reproduction unavailable. Guarantees: G1, G3.

The transformation copies one selected range, computes its replacement, then pastes into whichever range is selected later. Its guard retains the accessible **field**, not the selected offsets/text. If the application programmatically changes its selection while the same field remains focused during clipboard/tool settlement, the old transformed text replaces the new range. Different unrelated document text can be removed while the original selection remains untransformed.

- `linux/modules/shortcuts/manager.lua:590` captures a text destination and calls `Clipboard.transform_selection` at `:597`.
- `linux/modules/keystats/focus_guard.lua:425` (`guard.capture_text_owner`) retains bus/path/role/context/epoch. `owner.current` at `:465` proves the same field and privacy state, but contains no selected-range observation.
- `linux/adapters/clipboard.lua:656` transforms the earlier copied string; after its settle wait it emits `ctrl+v` at `:670`. No original selected-range receipt is captured or rechecked.
- The resident worker listens to focused/window/name events (`linux/adapters/atspi_focus_watch_worker.lua:79`), not selection/caret changes. The synchronous sleeps do not turn a stable field identity into a stable application range.

Reproduction: `probes/range-owner.lua` invokes the real `manager.transform_to_uppercase`, real clipboard adapter and **real focus guard/detector/policy** through the existing `text_owner_fixture`. Native shell/combo/wait boundaries are recorded. Start with selection `source`; during the pre-paste wait the application changes its selected range to `other-range`, preserving field identity and privacy. Output:

```text
SAME_FIELD_RANGE ok=true writes=1 range=other-range text=SOURCE
```

A real internal comparator is available: `adapters/selection_transaction.lua:114` (`replace_staged`) retains the AT-SPI range receipt and compares bus/path/role/**first/last/text** immediately before payload. `probes/atspi-range-control.lua` drives that owner through the existing native-boundary fixture with a changed range, yielding `committed=false emits=0 payload_written=false settled=true`.

Silent failure: the legacy transform returns success because Ctrl+V/clipboard restore acknowledged; none of those ACKs proves the intended range was replaced.

OS comparison: Windows' matching actions use `windows/modules/gestures/actions.ahk:736` (`GestureTransformSelection`) → `GetSelectionAsync` → `SendInstant`. macOS text actions are implemented in `macos/modules/shortcuts/actions/text.lua`, with AX selected-text support at `:1888` and clipboard ownership owners. **This audit does not establish that those OSes exclude the same residual application-selection race.** The confirmed mismatch is between Linux's exact-range LLM owner and its legacy case/wrap owner; blanket Windows/macOS immunity would be unsupported.

Regression: through the actual case/wrap entry, change only selected offsets/text in the same accessible field between copy and paste. Assert no payload until the original range is independently revalidated. Include unchanged-range success, inaccessible range refusal, pause/cancel/scope transitions, and original-range changed-back cases. A field-only identity check is insufficient.

### LCP-004 — A file-selection clipboard probe can send Ctrl+C to a newly focused terminal

Severity: **high**. Confidence: **high** for the real-module/model result; native terminal execution unavailable. Guarantees: G1, G3.

`copy_selected_path` identifies a known file manager, then performs blocking clipboard I/O before its Ctrl+C probe. It never retains/rechecks the original window/application at the copy boundary. A window change during that I/O can deliver Ctrl+C to a terminal or another application. In a terminal that chord normally interrupts the foreground job; the audit records the chord/target without running a real job.

- `linux/modules/shortcuts/open_selection.lua:215` (`M.copy_selected_path`) reads the app identity once and selects the file-manager branch at `:225`.
- `copy_file_selection :143` calls the default `read_uri_list` dependency; `:71` supplies `Clipboard.read_selection_uri_list(ComboEmitter.press, EventLoop.sleep_ms)` with no publication/source owner.
- `linux/adapters/clipboard.lua:600` snapshots the clipboard and `:604` stages its sentinel before `:608` emits `ctrl+c`. The emitter is given no retained publication and the original file-manager identity is never checked again.
- `open_selection.lua:22` explicitly says Ctrl+C is sent only to a known file manager because it interrupts terminals. That intended invariant is true only at branch selection, not at the actual effect.
- `linux/modules/gestures/system_actions.lua:284` (`make_executable_selection`) also uses this unowned URI-list probe. Its full action flow is not counted as a second finding; the unsafe shared probe deserves review across callers.

Reproduction: `probes/file-copy-focus.lua` uses the **real open-selection module and real clipboard adapter**. A recording focused-app dependency starts at `nautilus`; the snapshot-read boundary changes the active application to `terminal`. The recorded native emitter receives `ctrl+c`, target `terminal`, publication nil. Output:

```text
FILE_COPY_FOCUS result=false chords=1 target=terminal combo=ctrl+c publication=nil
```

No real terminal, copied files or user clipboard was touched. The eventual false/no-selection result cannot undo the already delivered control chord.

Silent failure: the action may only log “no primary selection”/return false after the unexpected Ctrl+C. It has no stale-source admission refusal identifying why the chord was unsafe.

OS comparison: macOS corresponding path/open action is `macos/modules/shortcuts/actions/apps.lua:856` (`copy_or_open_path`), with copy-capture/application-scope authorization before its boundaries. Windows corresponding action is `modules/shortcuts/win.ahk` Search path, registered as `copy_selected_path` in `modules/gestures/actions.ahk:247`. They are concrete counterparts, not proof that every native focus transition is safe on those OSes. The Linux header's terminal-safety guarantee and missing publication are directly evidenced here.

Regression: switch the active native app/window during clipboard snapshot/write and immediately before Ctrl+C; assert no chord is sent to a successor target, including a terminal. Use a window/application owner suitable for non-text file-manager surfaces, not an assumption that every selection must expose a text field.

## Pass ledger: continued until two consecutive dry sweeps

| Pass | Sweep and evidence                                                                                                                                                                                                            | New confirmed issues / dry count                                                                                                    |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| P1   | Trace case/wrap/plain-paste borrowers; compare snapshots and foreign-copy cleanup; execute field/range race with real guard                                                                                                   | LCP-001/002/003; dry count 0                                                                                                        |
| P2   | Trace other clipboard entries, file-manager URI copy, open/search and system file actions; execute changed-focus copy probe                                                                                                   | LCP-004; dry count reset to 0                                                                                                       |
| P3   | Revisit failure/partial-write/debt/cancel paths, staged selected-output owner, helper physical settlement, source-generation changes, binary/empty clipboard and per-backend restoration                                      | No new confirmed issue; dry count 1. LCP-001/002 cover repeated manifestations; held native cleanup/refusals remain deliberate.     |
| P4   | Revisit every action-entry family against Unicode/wrap vectors, PRIMARY session alternatives, pause/reload/configuration owners and Windows/macOS comparators; run both real Lua runtimes and the exact-range refusal control | No new confirmed issue; dry count 2. Locale test-order failure and native boundaries retained as gaps, not converted into findings. |

The stopping condition is relative to the enumerated scope and evidence. Two dry passes do not certify every possible application, clipboard manager or native timing interleaving.

## Entry-to-receipt coverage register

| User entry / flow                                | Actual owner → effect → receipt / refusal                                                                                                                     | Coverage                                                                                                                                     |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Upper/lower/title toggles and explicit case      | `shortcuts.manager.action_handlers` → real shared Unicode function → clipboard copy/transform/paste/restore → boolean, with retained field guard              | Production path read; case/vectors/destination tests executed; LCP-001/002/003                                                               |
| Explicit wrap action/custom pair                 | Shared wrap parser/catalogue → `transform_selection` or `wrap_selection` → clipboard or empty-selection pair output                                           | Paths read; wrap vectors and owner tests executed; same borrowing/range issues                                                               |
| Wrap while typing a symbol                       | Keyboard consume callback → `wrap_on_type` → changed PRIMARY baseline + local context epoch → retained injection; otherwise physical symbol passes once       | 77 existing cases/runtime; no real keyboard/pointer or PRIMARY read                                                                          |
| Plain-text paste                                 | `M.paste_plain` → checked clipboard read → admitted injector output                                                                                           | Source read, destination tests; literal paste deliberately strips formatting in output, but borrowed original formats must survive (LCP-001) |
| Unmappable-character fallback                    | `injector.prepare_replacement`/`selected_output` → prepared clipboard stage → short owned Ctrl+V transaction → restore ACK/debt                               | Source read; prepared-stage/snapshot/partial-write tests executed; LCP-001 applies                                                           |
| Native LLM tone/translation/agent selection read | Daemon `:1703` → `privacy_owners.selection.read` → cold AT-SPI helper → opaque bus/path/role/range/text receipt after physical settlement                     | Actual owner/fixture tests and refusal control executed; no native accessibility server                                                      |
| Native selected replacement                      | Retained receipt → stage preparation → exact range observation → payload/key cleanup → inserted-span/caret observation → reselect → physical/business receipt | 48 selected-write cases/runtime; confirmed refusal control. Application integration remains unverified.                                      |
| Selected URI/path copy                           | Action registry → `open_selection.copy_selected_path` → app classification → URI-list clipboard probe → shared URI parser → permanent path publication        | 104 open-selection + 28 file-vector cases/runtime; LCP-001/004                                                                               |
| Make selected files executable                   | System action → same URI-list clipboard probe → shared path parser → bounded native file operation                                                            | Caller source read; shared probe LCP-004; actual chmod not executed                                                                          |
| Open/search selected text                        | Registry builtin → raw `primary_selection` → shared target classifier/percent encoding → desktop opener                                                       | Source read; classifier/action tests with recording ports; raw X11 route limitation documented below                                         |
| Direct clipboard read/write/clear                | Session backend → bounded text shell command → checked status                                                                                                 | Source read; snapshot/restore/deadline tests; permanent writes/clear intentionally replace clipboard contents                                |
| X11 primary/clipboard providers                  | xclip, xsel fallback; xclip TIMESTAMP counter when available                                                                                                  | Adapter source + recording tests; no X server or actual clipboard target negotiation                                                         |
| Wayland providers                                | wl-copy/wl-paste; optional PRIMARY and data-control support                                                                                                   | Adapter source + recording tests; no compositor/real protocol capability probe                                                               |
| Pause/reload/scope/cancel                        | Shortcut collision/configuration generations, field publication, stage revocation, selection-owner cancel/stop, helper settlement                             | Destination/wrap/selected-write cases exercised; late native desktop work outside recorded ports remains bounded gap                         |
| Unicode/binary/framing                           | Shared Unicode corpus, exact-stdin heredoc writer, NUL snapshot refusal, UTF-8 range lengths                                                                  | Both runtime suites and private native-executable deadline test executed                                                                     |

## Intentional differences and constraints

| Difference                                | Evidence and classification                                                                                                                                  | User-visible effect / OS equivalent                                                                                                                                                                                                                                                                                                                            |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Session-specific clipboard tools          | Explicit Linux design in `clipboard.lua:25`: Wayland uses wl-clipboard; X11 uses xclip/xsel                                                                  | A missing tool/display refuses rather than claiming clipboard output. macOS uses native pasteboard; Windows uses native clipboard. Tool presence is not compositor support.                                                                                                                                                                                    |
| PRIMARY-based wrap-on-type                | Explicit rationale `wrap_on_type.lua:18`: no Ctrl+C, to avoid interrupting terminals; changed-baseline guard at `:21`                                        | Clipboard remains untouched. Re-selecting identical text can deliberately miss a wrap and type the symbol normally. macOS uses AX selection/fallback machinery; Windows uses its hotkey/native selection owner.                                                                                                                                                |
| Selected text open/search remains raw X11 | Explicit current restriction: shared action catalogue `actions.toml:1296`/`:1311` requires xclip; manager `primary_selection :386` uses raw xclip `io.popen` | These builtins do not use the available `Clipboard.read_primary` wl-paste/xsel route. Pure Wayland/xsel-only users can lack these actions even while other clipboard features work. This is documented implementation restriction; no maintainer rationale proving it should remain was found. Its unbounded helper is a source risk, not a measured G4 claim. |
| URI-list unavailable via xsel             | Explicit `clipboard.lua:598` refusal: xsel cannot request a MIME target                                                                                      | File-manager selected-path copy can refuse on xsel-only X11; xclip/wl-clipboard provide the target path. Windows/macOS native/file-manager routes differ.                                                                                                                                                                                                      |
| Clipboard counter                         | Explicit `change_counter :255`: only xclip/X11 TIMESTAMP supported                                                                                           | Wayland and X11-without-xclip copy confirmation remain weaker, already tracked in TODO. Not counted as a new finding.                                                                                                                                                                                                                                          |
| Binary snapshot containing NUL            | Explicit fail-closed implementation `read_restorable_snapshot :190`                                                                                          | Borrowing refuses before a text-only shell writer could corrupt bytes. This does not justify dropping other formats that coexist with valid text (LCP-001). Windows/macOS all-type snapshots use other native mechanisms.                                                                                                                                      |
| Exact selection requires accessibility    | Explicit `selection_transaction`/AT-SPI helper contract                                                                                                      | Native LLM selection actions can refuse unsupported/multiple/unknown ranges rather than use stale clipboard text. Legacy case/wrap lacks the same protection (LCP-003); no assertion that every Linux app exposes AT-SPI text.                                                                                                                                 |
| Unicode casing                            | Explicit routed memory `shared-architecture.md:270` and per-driver corpus filtering                                                                          | Linux/macOS share generated Unicode tables; Windows native casing differs for selected ß/final-sigma/title-digraph vectors. This is a documented algorithm/native difference, not “ASCII only” Linux behavior.                                                                                                                                                 |
| Native coordinates                        | AT-SPI uses Unicode character offsets and Lua UTF-8 lengths; Windows APIs may use UTF-16/native edit coordinates                                             | Offset vocabularies must be normalized before declaring parity; no byte-count comparison across OSes was used here.                                                                                                                                                                                                                                            |
| Permanent clipboard actions vs borrowing  | Explicit write/clear/copy-path APIs                                                                                                                          | Copy path/clear intentionally change the clipboard. Transform/fallback borrowers promise restoration; their non-text or foreign-copy loss is not the intended permanent mutation.                                                                                                                                                                              |

## Refuted hypotheses, memory and performance provenance

- Failed clipboard reads are **not** silently treated as valid empty snapshots on borrowing paths; existing failure-atomic tests passed. A valid empty clipboard is restored to empty, not left as the replacement.
- NUL snapshots refuse before mutation; the supplied text writer is not advertised as an arbitrary-binary serializer.
- Prepared clipboard restoration can retain debt after partial/failed writes and does not abandon owned key-up cleanup when publication retires. Selected-write fixture and private-executable tests exercise these paths.
- The native LLM selection route does **not** simply paste into whatever is selected when a model responds: it captures and revalidates exact range receipts. LCP-003 is the distinct legacy case/wrap route.
- Context/privacy checks cover accessible field identity and source epochs. They do not establish selected-range equality; the latter distinction was exercised rather than assumed.
- The old manifest comment saying Linux cannot read file-manager MIME selections is stale: `read_selection_uri_list` exists with xclip/wl-clipboard. The real current limitations are tool/session support and source ownership, not absent file-path code.
- Existing test result discrepancy: one all-21-locales caption case fails after earlier cases in `test_case_transforms.lua` on both runtimes; exactly that case passes when run alone. This proves an order-dependent test result, **not** a diagnosed production bug or complete suite pass. The root cause remains a coverage gap; no test was weakened or edited.

Memory watch-list: shared Unicode rule honored and replayed; immutable all-format clipboard ownership is implemented by OS counterparts but missing on Linux (LCP-001); foreign-owner restore fencing differs by Linux route (LCP-002); text destination vs selected-range ownership separated (LCP-003); file-manager classification is not admission at the eventual Ctrl+C effect (LCP-004). Shell return semantics were exercised on Lua 5.4 and LuaJIT. AT-SPI helper output buffers clear on settlement and range receipts are weak-keyed; this is source/lifecycle inspection, not a heap-retention or cryptographic-memory audit.

**G4 provenance:** no user driver performance logs or live desktop timings were collected. Native tool reads/writes are bounded in the clipboard adapter, while the old builtin PRIMARY helper is not; those are source observations. Mock timing, focused-test elapsed time and private fake-executable deadlines do not measure user-perceived input lag. No G4 finding or assertion that production lag is absent is made.

## Executed evidence and explicit limits

- `python probes/replay.py`: four proof/control scripts × Lua 5.4.8 and LuaJIT 2.1.1793383622, **8 successful executions**. Raw outputs/version provenance in `logs/probe-results.json` and adjacent logs. Native boundaries are modeled/recorded, not live desktop calls.
- `python probes/run-tests.py`: 15 registered test modules on each runtime; **656 pass, 1 fails per runtime** (1,312 pass / 2 fail total). Exact module counts in `logs/test-results.json`.
- The failing locale case isolated on each runtime: **1 pass / 0 fail**, logs `lua-isolated-locale.log` and `luajit-isolated-locale.log`. It remains reported as an unresolved suite-order gap.
- Additional real-shell/private-executable clipboard-deadline module: **12 pass / 0 fail on each runtime**. Executables and clipboard storage are private test fixtures; no real clipboard is invoked. Logs retain this separate evidence boundary.
- No production source or registered test changes, no real user clipboard/configuration, X11/Wayland server, native input, real application selection, external API or permission state changed. Tests use isolated runner homes. No live Windows/macOS execution, native cross-process clipboard MIME oracle, native AT-SPI editor, teardown under real window switching, hardware latency or full-suite CI result is claimed.

Manifest validation: the prescribed `node tools/audit/workflow.cjs validate-report --report <scratch findings.json>` was attempted and refused with `report must be inside the repository`. Its loader also restricts scopes/paths to ahk/hammerspoon. Moving evidence or changing source to satisfy that legacy destination restriction was outside this delegation. `python probes/validate.py` independently validates the same required manifest/finding field types, enum values, SHA/date, unique LCP IDs and report existence for the authorized scratch scope. This is explicitly not reported as a successful canonical-tool run.

## LCP-004 additional public caller countercheck

The [caller review](LCP004-caller-countercheck.md) extends the existing unsafe URI-probe root: `make_executable_selection` reaches it directly from an unchanged focused terminal, without initial file-manager eligibility. Root independently replayed the real manager/handler/helper fixture on Lua and LuaJIT: terminal/no-chmod, healthy file-manager/recorded-chmod, unavailable provider and refusing emitter controls passed. No actual clipboard, terminal interrupt or chmod was executed. This strengthens LCP-004; it is not a second finding or a fresh whole-module closure claim.
