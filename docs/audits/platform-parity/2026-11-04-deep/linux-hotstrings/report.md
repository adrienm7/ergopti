# Deep audit: Linux × hotstrings and input expansion

Audited commit: **89b0b774c8c960c7ad458ac3cb98d5c97598e518**. Date: 2026-11-04 UTC. Scope: Linux production configuration, static and dynamic matching, preview, injection, commit metrics, pause/reset/reload, programmable-source ownership. No repository files were changed. This report adds three findings beyond the previous `docs/audits/platform-parity/2026-11-04/hotstrings.md`; the known phone-prefix/date-vocabulary issues are not counted again.

Evidence levels are explicit: actual production Lua functions and an exact extracted daemon fragment were executed with Lua 5.4.8; native output, applications, evdev, accessibility and GTK were not exercised. Configuration/file adapters and the user-code owner are replaced in the compact probe, while the manager, shared matcher, TOML decoder and prefix builder are real. Such adapters are not evidence of native input delivery.

## Confirmed new findings

### LH-001 — Registered single-field dynamic expansions have no production preview row

Severity: **medium**. Confidence: **high**. Guarantees: G2 missing output, G5 truthful preview.

With an enabled personal first-name alias `p`, typing `@p` offers no first-name preview, although `@p★` expands. The same disconnect affects `td`, `dt` and `date`: no date preview before the magic key. Multi-field `@pn` does produce its row. This is a missing preview feature, separate from the previously reported date trigger vocabulary.

Root cause and evidence:

- `linux/modules/dynamic_hotstrings/manager.lua:209` (`M.init`) registers single-letter aliases in the **shared dynamic engine**; `:221` registers dates there.
- `linux/modules/dynamic_hotstrings/manager.lua:936` (`M.prefix_mappings`) exports only `Prefix.build(...)` to the static engine, not these dynamic registrations.
- `linux/ergopti_hotstrings.lua:1499` gets static `engine:candidates`; `:1512` adds only `dyn_hotstrings.preview_candidates`.
- `linux/modules/dynamic_hotstrings/manager.lua:577` (`M.preview_candidates`) deliberately withholds a user-source row when a registered dynamic rule exists; `:594` then returns no row for fewer than two personal fields. Date triggers have no personal tag, so return at `:587`. Its comment at `:592` incorrectly assumes single-letter registrations reach the ordinary preview path.
- `linux/modules/dynamic_hotstrings/manager.lua:621` (`M.preview`) can resolve these values, but no production daemon caller invokes it. Tests call this disconnected API directly, so they do not verify what the user sees.
- `linux/tests/unit/modules/dynamic_hotstrings/test_personal_info_combo_resolver.lua:193` explicitly expects no extra single-letter row on the same incorrect ordinary-path assumption.
- macOS has an actual dynamic preview-provider registration at `macos/modules/dynamic_hotstrings/rules_engine.lua:761`; `preview_provider` at `:363` resolves shared dynamic matches and `macos/modules/keymap/llm_bridge.lua:830` consumes providers. This establishes a concrete OS parity difference by source inspection, without claiming a live macOS run.

Reproduction: execute `probe.lua` with the supplied Lua command below. The exact production candidate sources return `@p: static=0 extra=0 resolves=true`, `td/dt/date: static=0 extra=0 resolves=true`; `@pn: extra=1` is the positive control. Search of shipped hotstring entries found no alternate static registrations for these trigger strings. A user-created mapping could independently add a row and does not repair the missing built-in route.

Silent failure: no exception or warning; the bubble silently disappears for supported expansions.

Regression test: run the daemon's actual candidate-composition path with enabled aliases and each date family; assert one correctly classified/masked row before the magic key, with disabled-family and unknown-boundary negative controls. Do not test only `manager.preview()`.

### LH-002 — Invisible hotstring previews increment the offered-suggestion metric

Severity: **medium**. Confidence: **high**. Guarantee: G1 robust/truthful state; related to G5 visibility truth.

Disabling preview, disabling a category's tooltip, or lacking an available renderer can still increment Linux `hs_suggested` for each distinct candidate. The dashboard's suggestion/acceptance data then measures offers the user never saw. This also poisons deduplication: a failed display sets `_last_offered`, so a subsequently visible identical offer may not be counted.

Root cause and evidence:

- `linux/ui/tooltip/preview.lua:430` (`M.show`) returns `false` without drawing when no style is loaded (`:431`), the kind toggle is disabled (`:432`), the renderer is unavailable (`:433`), or the category forbids the tooltip (`:451`). It also returns the actual renderer result at `:470`.
- `linux/ergopti_hotstrings.lua:1529` (`handle_char` preview block) ignores that return value and unconditionally updates `_last_offered` / calls `keystats.record_suggestion` at `:1538`–`:1540`.
- `linux/modules/keystats/keystats.lua:1083` (`M.record_suggestion`) increments live and dated `hs_suggested`; its contract explicitly calls this an offer to the user.
- By comparison, macOS `macos/modules/keymap/llm_bridge.lua:1141` (`publish_visible_match`) ties suggested telemetry to physically committed preview state. This is a source comparison, not a native macOS test.

Reproduction: `probe.lua` extracts the exact production lines from the show call to the end of its metrics fragment, executes them with `tooltip_preview.show` returning false, and asserts `REFUSED_PREVIEW suggestions=1`. The refusal matches the real renderer/toggle contract above.

Silent failure: accepted metrics writes, no indication the display failed; this is data corruption, not a renderer exception.

Regression test: execute the real daemon preview orchestration with real `preview.show` or its return contract for toggle/category/native-renderer refusals; assert zero offered events and no deduplication commit until a successful display. Then redraw the same successful row and assert a single count.

### LH-003 — Built-in dynamic fire path bypasses the configured expansion-delay gate

Severity: **medium**. Confidence: **high**. Guarantee: G1 configured behavior.

Linux's ordinary and programmable hotstrings enforce the last-letter-to-expander deadline, but built-in date and personal alias/combo expansions bypass it. With a nonzero short expansion delay and a pause shorter than the independent idle reset, pressing the magic key still expands a built-in date. The same category preference can therefore govern a prefix mapping while doing nothing for built-in dynamic output.

Root cause and evidence:

- `linux/ergopti_hotstrings.lua:1340` (`within_delay`) resolves `hotstrings_config.resolve(group, section)` and applies `ExpansionDelay.allows`; it guards only the static result and its cascade at `:1363`–`:1370`.
- The later dynamic fallback at `linux/ergopti_hotstrings.lua:1573`–`:1575` passes only buffer, magic key, boundary and destination to `M.on_trigger`; there is no dynamic timing admission.
- `linux/modules/dynamic_hotstrings/manager.lua:465` (`M.on_trigger`) checks family, trigger, boundary, output validity and retained destination before invoking output at `:515`. It never reads delay configuration or a timing receipt. The combo fallback `:399` has the same absence.
- The programmable path DOES capture `engine:tail_timing_receipt(count)` and apply its interval at `linux/infra/user_hotstring_runtime.lua:35`–`:37`, which refutes the hypothesis that Linux fundamentally cannot time dynamic expansion.
- Default idle reset is independently 3 seconds: `_shared/modules/features/manifest.toml:543`–`:545`. A 1-second pause therefore does not explain away the missing shorter expansion deadline.
- Windows `windows/modules/dynamic_hotstrings/dynamic_hotstrings.ahk:46` resolves the dynamic category delay, and `:135` passes `TimeActivationSeconds` into the built-in date registrations. This establishes specific parity drift. macOS dynamic timing semantics were not fully resolved here and are not asserted equivalent.

Reproduction: the real shared buffer receives `t` at 0 ms, `d` at 10 ms and magic key at 1010 ms; the normal shared gate rejects `{expander_gap_ms=1000}` for 0.01 seconds. Calling the real production manager fallback with this buffer and a current publication still invokes injection once. The probe's 0.01 value demonstrates the ordinary contract; static source tracing above establishes that no configured value reaches the dynamic fallback. For a desktop reproduction, choose an enabled dynamic date family and a nonzero delay shorter than 1 second, type `td`, pause 1 second, then type magic key, keeping idle reset at 3 seconds or higher.

Silent failure: expansion commits successfully despite the user's deadline; no error or expiry diagnostic.

Regression test: drive the real character callback at a fake monotonic clock, with a real resolved dynamic delay and each built-in route. Cover below/exactly/above deadline, zero delay, missing timing, complex keys and an idle threshold longer than the tested interval; verify both no destructive output and consistent preview expiry after refusal.

## Two-pass coverage register

Pass 1 traced the complete production route. Pass 2 actively tried to disprove the suspected gaps through alternate providers/callers, UI reload ownership, existing tests, real manager probes, exact daemon-fragment execution and a limited comparison against the corresponding Windows/macOS owner. No claim is made that all possible inputs or desktop integrations are exhaustive.

| Surface                                          | Concrete coverage / evidence                                                                                                          | Result                                                             |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Shared catalogue and user files                  | `hotstrings_config.load_all` stages loader output, errors, choices and extra mappings (`hotstrings_config.lua:1547`–`:1580`)          | Read; no new confirmed loading gap                                 |
| Flags, case, key-output tokens                   | Loader fields `loader.lua:293`–`:325`; current cross-driver flag/token gates                                                          | Executed gates passed                                              |
| Prefix family admission                          | `manager.prefix_mappings`, enabled-family predicates, private flags                                                                   | Read and real builder executed; known phone issues excluded        |
| Personal TOML and aliases                        | `M.init`, strict Unicode alias registration, shared decoder, source-owned editor receipts                                             | Real decoder/registration exercised                                |
| Date and single-field matching                   | Shared dynamic registration and `match_buffer`, publication requirement                                                               | Real resolution exercised; missing candidate route LH-001          |
| Multi-field combinations                         | `resolve_combo_values`, `_fire_combo`, `inject_fields`; preview positive control                                                      | Preview executed; native focus traversal unavailable               |
| Static delay and cascades                        | Actual `within_delay` call sites, `ExpansionDelay`, shared arrow contract                                                             | Read plus shared gate executed                                     |
| Built-in dynamic delay                           | Actual late fallback and manager signatures                                                                                           | Confirmed LH-003                                                   |
| Preview arbitration                              | Static candidates + dynamic extras; no additional manager.preview caller                                                              | Real sources composed, LH-001                                      |
| Preview toggles/availability/category gating     | `preview.show` boolean contract                                                                                                       | Source-refused routes read; exact caller fragment executed, LH-002 |
| Preview privacy                                  | `parts`/`fields` classification and private mapping metadata                                                                          | Read and privacy sink gate passed; native renderer unavailable     |
| Injection admission                              | `injector.prepare_replacement`, channel/layout/publication seals (`injector.lua:434`–`:555`)                                          | Read; no new confirmed stale-owner gap                             |
| Destructive phases and key ownership             | `run_transaction` neutralizes modifiers, retains cleanup, finishes transaction (`injector.lua:610`–`:672`)                            | Read; no native channel exercised                                  |
| Clipboard fallback                               | Clipboard snapshot/preparation before erasure, captured close on failure (`injector.lua:902`–`:947`)                                  | Read; no clipboard/native execution                                |
| Commit metrics and Undo                          | Daemon `:1421` accepts only delivery.ok, records/arms Undo only after output commit; backspace path `:1938` uses retained destination | Read; no false successful injection metric found                   |
| Private dynamic metrics                          | Daemon `:1588` forwards is_private; events/character sinks judged by gate                                                             | Read and existing JS gate passed                                   |
| AI context                                       | Engine wrapper mirrors edits only after apply_expansion; private dynamic replacement passes secrecy flag                              | Read; no new confirmed leak                                        |
| Reset / focus / Tab / navigation                 | Daemon Tab invalidation `:1254`, WordReset; unknown-boundary resets, physical Backspace semantics                                     | Read; previous audit's reset contracts not re-reported             |
| Pause                                            | Early character return `:1241`, reset/controller wiring and programmable invalidation `:1116`                                         | Read; no new confirmed pause bypass                                |
| Catalogue/magic-key reload                       | Callback `:2697`, `set_magic_key`, dynamic reinit, catalogue reload                                                                   | Read; separate transaction-failure behavior not reproduced         |
| Personal-info save live refresh                  | `save_info :806`, UI bridge `:164` reloads ordinary catalogue                                                                         | Stale-prefix hypothesis refuted for production editor path         |
| Programmable capture and stale-source protection | `user_hotstring_runtime.lua:30`–`:95`, shared `user_code_driver.lua:223`–`:238`                                                       | Read; distinct timing gate confirmed; user callbacks not run       |
| Programmable cancellation/pause                  | Observed-input epochs, pause/capture/focus/source guards, timer cancellation binding                                                  | Read; no native generation race reproduced                         |
| Teardown/error policy                            | Daemon lifetime owners, injector failed transaction cleanup and emergency release                                                     | Read; no native shutdown claim                                     |

## Intentional and constrained OS differences

These differences must stay visible in the eventual feature matrix. They are not all product bugs, and inferred intent is not presented as a decision.

1. **Physical-character ownership — explicit architecture.** `docs/memory/text-input-and-config.md:7` documents that Windows/Linux compensate characters that already reached the application, whereas macOS consumes the completing event. Linux consequently erases suffix plus already-visible magic key (`manager.lua:500`), while macOS's interceptor owns its event. User-visible intended result is the same replacement; native transaction mechanics differ. Copying erasure counts between hosts would be wrong.
2. **Preview dependency — explicit runtime constraint.** Daemon `ergopti_hotstrings.lua:192` and `:2610` intentionally keep expansion available without the optional GUI preview dependency/display. Windows/macOS have their own GUI hosts. The matrix should distinguish expansion from preview availability. That intentional optionality does not justify counting an invisible offer (LH-002).
3. **Secure-field admission — explicit fail-closed policy.** `ergopti_hotstrings.lua:1176` logs that missing native accessibility focus watching closes text automation and metrics. A Linux session can therefore have installed hotstrings but no admitted expansion until focus observation works. Other OSes use their native secure-field ownership; no claim that all Linux desktops provide identical accessibility support.
4. **Programmable-source language and scheduling — explicit implementation, intent bounded.** Linux `modules/dynamic_hotstrings/user_code.lua:5`–`:15` uses shared Lua lifecycle plus zero-delay scheduler callbacks; Windows's existing owner uses AHK callbacks and a native isolated Job process, and macOS also binds shared Lua ownership. This is an implementation distinction with user-visible script portability implications. Source comments establish the scheduling choice; they do not establish a maintainer decision that every isolation consequence is desirable.
5. **Known date vocabulary — explicitly tested Windows contract, already reported.** Windows tests deliberately reject bare dates and accept `@td★`; Linux shared rules accept bare `td★` at a word boundary. It remains documented in the prior audit, without being counted as a newly discovered issue here.
6. **Complex-key timing documentation — stale, not classified intentional.** Memory `text-input-and-config.md:240` says only macOS widens the window. Current Linux `modules/hotstrings/expansion_delay.lua:30`–`:39` also applies the shared multiplier. Current code therefore refutes treating that old sentence as evidence of a present intentional Linux asymmetry.

## Executed checks, failures and limitations

Passed on the audited checkout:

- `/workspace/scratch/parity-toolchain/lua-5.4.8/src/lua -v`: Lua 5.4.8.
- `/workspace/scratch/parity-toolchain/lua-5.4.8/src/lua docs/audits/platform-parity/2026-11-04-deep/linux-hotstrings/probe.lua`: all assertions pass; proves the three defects at the production-logic boundary described above.
- The preview and refused-offer portions also independently passed through installed liblua5.4 using `run-lua.py` before the standalone interpreter became available.
- `node tools/test/test-hotstring-flag-support-per-driver.cjs`: all recorded flags, including 1300 strict-case entries.
- `node tools/test/test-hotstring-output-tokens.cjs`: 284 checks / 57 vectors.
- `node tools/test/test-personal-info-log-sinks-are-judged.cjs`: 27 Windows trigger sinks / 18 Lua value sinks.
- `node tools/test/test-hotstrings-bridge-parity.cjs`: 16 actions / 2 shared windows.

Unavailable / not passed: standalone existing `test_dynamic_multibyte_trigger.lua` could not initialize its real writable preference fixture (`fixture family must persist: date_long_fr`) in this environment. Earlier attempts with relative module paths also hit the canonical-constructor path-admission assertion. Those are harness/environment failures, not evidence that any of that test file's assertions passed or that the product is broken. No full LuaJIT, native driver suite, GTK/AT-SPI desktop, evdev/uinput, clipboard application, terminal editor or real focus traversal was tested.

The confirmed checks are logic reproductions with scoped adapter mocks, not measurements of lag or hardware correctness. Unicode grapheme deletion in host editors, arbitrary user callbacks, late magic-key publication failures and real multi-field Tab settling remain bounded unanswered runtime questions. No unmeasured performance or race claim is promoted into findings.
