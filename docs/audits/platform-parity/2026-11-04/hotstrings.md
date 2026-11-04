# Hotstrings / dynamic / personal source parity audit

Audit-only; no repository changes. Reviewed on 2026-11-04 against the shared working tree. Read AGENTS, cross-driver-parity skill, memory index/text-input-and-config and relevant maintainer-decision searches, existing parity audit and TODO. Findings below are new behavior differences, not missing entire date/phone capabilities.

## New findings

### 1. Linux two-digit phone prefix expands before the magic key (high confidence)

For personal `phone_number = "0612345678"`, Linux builds an auto-expanding `06` mapping. Windows and macOS require `06★` for this shortest prefix. A user typing a date/year/other number beginning with their phone's first two digits can expand the phone before reaching a longer prefix. This is also a behavioral obstacle to the declared four-digit prefix: the shortest one already fired.

Evidence:

- `static/ergopti_plus/linux/modules/dynamic_hotstrings/prefix_rules.lua:154`: short trigger is `phone:sub(1, PHONE_MIN_FOR_SHORT)` without magic key.
- Same file `:65`: all prefix mappings have `auto_expand = true`; `:51` says two digits plus magic key, but code does not do that.
- `static/ergopti_plus/linux/modules/dynamic_hotstrings/manager.lua:943`: production `prefix_mappings()` returns `Prefix.build(_info, M.is_rule_enabled)`, with no trigger argument or rewrite.
- `static/ergopti_plus/linux/ergopti_hotstrings.lua:937`: extra catalogue provider invokes that production function before `load_all` at :941.
- `static/ergopti_plus/windows/modules/dynamic_hotstrings/dynamic_hotstrings.ahk:179`: shortest trigger explicitly appends `MK`.
- `static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua:513`: shortest trigger appends `_trigger`, with `is_magic_trigger=true` options at :510.

Real-Lua probe (below) confirms `PREFIX 06 ... auto=true` and actual shared engine yields replacement on the second character (`ENGINE 6 06 0612345678`). The probe's later four-digit result does not model app output because it deliberately does not apply any returned expansion; the first result is the relevant reproduction.

Proposed TODO: make Linux's two-digit phone expansion require the current configured magic key, include magic-trigger semantics, and replay exact triggers/output through all three drivers from one shared corpus. Include a non-default magic-key case.

### 2. International phone output differs; Lua drivers retain the national leading zero (high confidence)

With `0612345678`, typing `+33612` returns `+33612345678` on Windows and `+330612345678` on macOS/Linux. The Windows branch drops the initial national `0`; the Lua branches prepend `+33` to the whole value. This is behavior drift in an available feature, not OS impossibility.

Evidence:

- Windows `modules/dynamic_hotstrings/dynamic_hotstrings.ahk:180` and :184: output `"+33" . SubStr(Phone, 2)`.
- macOS `modules/dynamic_hotstrings/rules_engine.lua:514` and :518: output `"+33" .. phone`.
- Linux `modules/dynamic_hotstrings/prefix_rules.lua:157` and :163: output `FRANCE_DIAL_PREFIX .. phone`.
- Linux real-Lua probe confirms the built `+33612` row outputs `+330612345678`.

Proposed TODO: decide canonical French international formatting, share an output corpus (not just counts), and align all drivers. Include both short international triggers and already international/non-French user inputs so a normalization fix does not invent its own assumptions.

### 3. Date trigger vocabulary and continuation contract differ (high confidence; intentional Windows behavior pinned by tests)

All OSes provide the three formats, but Windows registers only explicit `@dt★`, `@td★`, `@date★`; shared Lua registers `dt`, `td`, `date` and receives magic key separately. Windows tests explicitly reject bare `td★/dt★/date★` and accept explicit @ dates after preceding text. Shared Lua's boundary guard rejects `@td` (the preceding `@` is treated as a hotstring word character), and accepts bare `td` at a known boundary. This means a shared published feature list must not imply identical commands.

Evidence:

- Windows `modules/dynamic_hotstrings/dynamic_hotstrings.ahk:138`, :141, :144 registers the @ forms.
- Windows `tests/unit/modules/dynamic_hotstrings/test_dynamic_hotstrings_module.ahk:292` explicitly lists bare `date`, `td`, `dt` as rejected with/without star; :321 accepts the @ forms after empty text, `2026`, or `expandedword`.
- `_shared/lua/dynamic_hotstrings/init.lua:302`–304 registers bare suffixes, with `require_word_boundary=true`; :213–222 implements boundary guard (only suffixes themselves beginning @ bypass).
- macOS `modules/dynamic_hotstrings/rules_engine.lua:773` calls that shared registration.
- Linux `modules/dynamic_hotstrings/manager.lua:221` calls that shared registration; :485 calls `Engine.match_buffer` against preceding text.
- Linux `tests/unit/modules/dynamic_hotstrings/test_dynamic_multibyte_trigger.lua:48`–60 asserts the production manager preview/fire for `td★`.
- The real-Lua probe shows `td -> td`, `@td -> NO MATCH`, `xtd -> NO MATCH`, `word@td -> NO MATCH`.

Proposed TODO: document or align canonical date triggers and continuation semantics across drivers; register these behavior differences in future feature evidence. Do not silently change Windows's explicitly tested @ contract without product decision.

## Coverage and refutations

- Dynamic date formats, phone/SSN/IBAN families, personal @ tags/combinations, programmable sources, menu surfaces, source initialization, preview privacy, and Linux focus/privacy gate wiring inspected.
- Programmable sources exist on all OSes. Windows uses AHK user source plus isolated native Job owner (`windows/modules/dynamic_hotstrings/user_code.ahk`); Lua drivers use shared lifecycle owner (`_shared/lua/dynamic_hotstrings/user_code_driver.lua`) with platform bindings. No new programmable-feature absence established. Windows menu equivalence already documented by parent; not a new gap.
- Linux personal editor has actual payload/save ownership (`linux/ui/personal_info_editor/bridge.lua:67`, :126, :150`); no absence inferred from UI module shape.
- Linux secure-field support is implemented, not absent: `linux/ergopti_hotstrings.lua:1175` keeps text automation closed without a ready native accessibility watcher, then primes the secure focus guard. `:1199` supplies detector/focus guard/capture gate to programmable runtime. Availability on a particular session remains a runtime/native question. The password-app suppression at :1308 alone is not the complete privacy mechanism.
- Private prefix mappings carry `is_private=true` on Linux (`prefix_rules.lua:67`); dynamic personal output log sinks have existing regression checks. No new privacy leak established.
- Existing parity tests cover flags/tokens/menu/bridges and prefix COUNTS, but do not establish exact dynamic trigger/output equivalence. The corpus `_shared/tests/corpus/dynamic_hotstrings/prefix_vectors.json` expects counts only. Linux `test_prefix_expansions.lua:110` compares built count <= promised count, not trigger/output dictionaries. This explains why concrete phone drift is not rejected.

## Reproduction and verification

`lua docs/audits/platform-parity/2026-11-04/hotstrings-probe.lua .` configures repo package paths, replaces only logging with no-op functions, and executes the real Linux prefix builder, shared matcher, and shared date engine. In the audit environment the same Lua body was executed through the installed liblua5.4 C API because no Lua executable was available; the parent independently repeated that observation. No app/native injection is invoked. Exact output:

```
PREFIX  06      0612345678       auto=true
PREFIX  +3306   +330612345678    auto=true
PREFIX  0612    0612345678       auto=true
PREFIX  +33612  +330612345678    auto=true
PREFIX  6123    0612345678       auto=true
ENGINE  6       06              0612345678
ENGINE  2       0612            0612345678
DATE    td      td
DATE    @td     NO MATCH
DATE    xtd     NO MATCH
DATE    word@td NO MATCH
```

Passed, run independently:

- `node tools/test/test-hotstring-flag-support-per-driver.cjs`: all recorded flags supported, including strict case (1300 entries).
- `node tools/test/test-hotstring-output-tokens.cjs`: 284 checks, 57 vectors.
- `node tools/test/test-personal-info-log-sinks-are-judged.cjs`: 27 Windows trigger sinks / 18 Lua value sinks checked.
- `node tools/test/test-dynamic-hotstrings-menu-labels.cjs`: 4 checks.
- `node tools/test/test-hotstrings-bridge-parity.cjs`: 16 actions across 2 shared windows, every host handles them.

No full native suites or real Windows/macOS apps were executed here. Windows/macOS output statements are directly evidenced by production registrations and Windows runtime tests read from source, rather than claimed hardware reproduction. This is a module-specific source/runtime-logic audit, not proof of complete product parity or exhaustive discovery of every possible behavioral divergence.
