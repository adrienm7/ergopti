<!-- docs/audits/2026-08-03-mise-en-commun-et-simplification.md -->

# Audit — mise en commun maximale et simplification

Run of `docs/prompts/audit_mise_en_commun_et_simplification.md`, 2026-08-03.
The prompt had never been executed. It asks for a report, not code, and every
finding below is backed by a measurement that is reproducible from this repo.

One correction the prompt itself calls for: it says to confront conclusions
against `docs/REFACTOR_PLAN.md`, which no longer exists.
[`docs/PROJECT_MEMORY.md`](../PROJECT_MEMORY.md) is the canonical memory, and
`TODO.md` is the live backlog; both were read before concluding.

**The headline is not what the prompt expects.** It is written as if the codebase
were early in its consolidation and full of low-hanging duplication. It is not.
The mechanisms it proposes building mostly exist and are gated: 38 single-source
or parity gates, 21 hexagonal ports, a manifest-driven menu on all three drivers,
14 shared webview pages, 21 locale catalogues held to key parity. The honest
finding is that **the cheap consolidation is done, and what remains is expensive
and mostly already recorded in `TODO.md`.** Padding this report with
"opportunities" that are really re-statements of finished work would be the
failure mode the prompt warns about in its own "pistes écartées" section.

---

## 1. Résumé exécutif

Ordered by value/risk. Only the first three are new findings; the rest confirm or
correct entries that already exist.

| # | Opportunity | Value | Risk | New? |
| --- | --- | --- | --- | --- |
| 1 | **Three gates ran nowhere** — port compliance, priority parity, manifest parity: alias present, suite entry absent | high | none | ✅ new |
| 2 | 11 literal French UI strings in two `ui/` files bypass i18n; they are invisible in 20 of 21 locales | small, user-visible | low | ✅ new |
| 3 | `_generated/` is **not** reducible — every one of the 21 artefacts has a runtime reader and a generator wired into the drift guard | closes a question | none | ✅ new |
| 4 | 33 production files over 900 lines (35 873 lines) — the split candidates are known and mostly listed in `TODO.md` | large | medium | partly |
| 5 | The remaining cross-driver duplication is the four items already in `TODO.md` Lot 8 | large | high | no |

---

## 2. Axe 1 — mise en commun

### 1.1 UI / webviews

**Constat.** The migration to shared webviews is substantially complete and
further conversion is not obviously positive.

**Preuve.** `_shared/ui/` holds **14 shared pages**: `action_picker`,
`changelog`, `download_window`, `healthcheck`, `hotstrings_config_window`,
`hotstring_editor`, `metrics_apps`, `metrics_typing`, `model_browser`,
`onboarding`, `paths_editor`, `personal_info_editor`, `prompt_editor`,
`token_prompt`. Per driver: Windows 58 `ui/` files of which 21 touch a webview,
macOS 65 of which 23, Linux 18 of which 5.

**Proposition.** None as a blanket rule. The prompt names
`windows/ui/editors.ahk` as a conversion target; those are single-field modals
(magic key, repeat key, GPT link, personal info) and the personal-info one
**already has** a shared page — `personal_info_editor`. The rest satisfy the
prompt's own "peut rester natif" criterion: one input, one OK, one Cancel.

**Gain.** Converting them would add a webview host, a bridge contract and a
native fallback per modal to replace an `InputBox`. Net negative.

**Vérif.** `ls static/ergopti_plus/_shared/ui/*/` and the per-driver counts above.

### 1.2 Menu

**Constat.** Both interactive drivers now render from the shared manifest, and
this is the axis that moved most during this session.

**Preuve.** `test-menu-rows-outside-renderer.cjs` measures rows built outside the
renderer: windows 220, macOS 301, linux 3. Both numbers moved down this session
(windows 222 → 220) and neither may rise. The keyboard-shortcut groups became one
manifest `list` entry read by both drivers, replacing a `Menu.Insert` splice on
Windows that had already caused one unbounded-row-growth bug.

**Proposition.** Continue lowering the two ratchets. macOS's 301 is the larger
target and the gate names its biggest offenders (`menu_remap.lua` 36,
`menu_llm/models_selector.lua` 32, `menu_keyboard_layout.lua` 26).

**Risque.** Low per row, and the ratchet makes regression impossible.

### 1.3 Valeurs par défaut

**Constat.** §5.2 is enforced at scale already; this is not an open axis.

**Preuve.** 38 gate files in `tools/test/` are named `*single-source*`,
`*parity*` or `*no-drift*`. They cover the WPM colours, keylogger timings, logger
scalars, gesture slot space, tap-hold thresholds, hotstring flags, prompt-builder
constants, keycode data, chord native mappings and more.

**Proposition.** The remaining duplication is **not** a missing gate, it is the
two tap-hold namespaces — and that is now measured rather than guessed:
`test-tap-hold-namespace-correspondence.cjs` pairs the keys by physical position,
names 3 synonym pairs and 5 divergences, and finds **exactly one genuine drift**
(`tab.tap`: `alt_tab_monitor` vs `alt_tab_windows`, with no recorded reason).

**Vérif.** `npm run test:tap-hold-namespaces`.

### 1.4 Données & catalogues

**Constat.** One catalogue was still being shadowed; it now is not.

**Preuve.** `_shared/modules/actions/modifier_chords.json` already held the
per-OS key spellings (`ahk_prefix`, `hammerspoon`, `windows_key`, `macos_key`)
and three drivers read it — while the new chord adapters had re-typed the same
facts. `test-chord-native-mapping-single-source.cjs` now holds both drivers to it.

**Reste ouvert.** `macos/platform/remap/data/actions.json` — 73 Karabiner actions
with hardcoded French labels and no i18n keys, of which 18 already have
`sg_actions.*` keys in all 21 languages and 55 do not. This is `TODO.md` Lot 6(4)
and the merge must precede the translations, or ~1 155 strings get keyed to ids
that are about to change.

### 1.5 i18n — **finding**

**Constat.** Key parity across the 21 catalogues is enforced, but a small number
of UI strings never reach the catalogue at all.

**Preuve.** Scanning production `.ahk`/`.lua` for a double-quoted literal
containing an accented character, on a line that does not route through
`i18n`/`t()`/a logger: **156 hits in 32 files**, of which all but 11 are
legitimately French *data* — hotstring corpora
(`windows/modules/hotstrings/hotstrings_distances.ahk`, 31) and layout character
tables (`windows/modules/keymap/layout.ahk`, 25). The genuine findings are the
two under `ui/`:

- `macos/ui/menu/menu_llm/models_manager_mlx_download.lua` — 7 strings
- `windows/ui/onboarding/steps_keyboard.ahk` — 4 strings

**Proposition.** Add 11 keys to the shared catalogue and read them through
`i18n.get()`/`t()`. The onboarding one matters most: it is the first screen a new
user sees, and it is French for a Japanese or Arabic user today.

**Gain.** 11 strings × 21 locales become translatable; two files stop being
exceptions to the rule.

**Risque.** Low. **Effort.** One commit. **Vérif.** Re-run the scan (the script
is in this report's commit message) and `npm run test:i18n-*`.

---

## 3. Axe 2 — simplification

### 2.1 `_generated/` — **the prompt's central question, answered: no**

**Constat.** Nothing in `_generated/` can be deleted, and nothing large can
usefully be replaced by a runtime read of the shared source.

**Preuve.** All 21 committed artefacts across the three drivers total **200.3 KB**.
Every single one has at least one runtime reader outside `_generated/` and at
least one generator under `tools/`, and all are covered by the drift guard
(`build-domain.cjs` compares the working tree against the index). The three
largest are the feature manifests — `macos/_generated/features_manifest.lua`
54.9 KB, `windows/_generated/features_manifest.ahk` 54.8 KB,
`linux/_generated/features_manifest.lua` 24 KB — which is 67 % of the total and
is exactly the mass ADR-002 moved off the boot path deliberately.

**Proposition.** Close the question. Record in `PROJECT_MEMORY.md` that the
`_generated/` trees were audited on 2026-08-03 and found to have zero orphans, so
the next person does not re-open it.

**Piste écartée.** Replacing the feature manifests with a runtime TOML read would
put a ~130 KB parse back on the boot path of every driver to save 134 KB of
committed text. Net negative, and it is the change ADR-002 exists to prevent.

**Vérif.** The scan is reproducible: for each file under `_generated/`, search
the driver and `tools/` trees for its basename.

### 2.2 Simplifier `_shared/`

**Constat.** The structure is coherent and the port contract is proportionate.

**Preuve.** `_shared/` splits into `core/` (ports + domain specs + config schema),
`data/` (locales), `lua/` (shared implementation), `modules/` (shared data),
`tap_hold/`, `tests/corpus/`, `ui/`. 21 ports, each with an adapter on the
drivers that need it — ADR-008 established that a port is a contract for drivers
that need the capability, not a checklist, and `test-port-compliance.cjs` reports
21/21 covered.

**Proposition.** None. The one asymmetry worth naming is that `_shared/lua/` is
consumed by macOS and Linux but never by Windows, which gets a ported twin pinned
by a corpus — that is I5 working as designed, not a defect.

### 2.3 God-files — **33 files, 35 873 lines**

**Constat.** A third of the driver mass sits in files over 900 lines.

**Preuve.** Top of the list:

| Lines | File |
| --- | --- |
| 1 675 | `macos/modules/keylogger/init.lua` |
| 1 495 | `windows/modules/keylogger/keylogger.ahk` |
| 1 447 | `windows/infra/hotstrings/hotstring_inputhook.ahk` |
| 1 385 | `macos/modules/keymap/init.lua` |
| 1 324 | `windows/modules/keymap/layout.ahk` |
| 1 293 | `macos/modules/keylogger/log_manager.lua` |

**Proposition.** Do not split on size. Three of the top six are the two keylogger
walkers plus their log manager, and `TODO.md` Lot 8(3) already names the right
move for them — a shared aggregation core, because the two ~1 330-line walkers
have function names that map 1:1 and one says in a comment that it "MIRRORS" the
other. Splitting them per driver first would make that harder, not easier.

**Risque.** High for the keymap/hotstring files: they are the keystroke path.

### 2.4 Tooling — **the sharpest finding of the audit**

**Constat.** Three gates existed, passed, had an npm alias, and were run by
**nothing** — not the JS suite, not CI, not the build.

**Preuve.** `test:port-compliance` → `tools/test/test-port-compliance.cjs`,
`test:priority-parity`, `test:manifest-parity`. Each appears exactly once outside
its own file: on its `package.json` line. Port compliance is the gate that
re-projects `contracts.json` from the 21 `*.spec.js` files and checks every
AutoHotkey `ADAPTER_*` dispatch map against it — the freshness gate for the whole
port layer. It had been dark. All three pass, so nothing had rotted; they were
simply never going to catch anything.

**Proposition.** Wired into `run-js-suite.cjs` (140 → 144 checks), and
`test-npm-aliases-match-the-suite.cjs` now makes the direction an **assertion**:
no alias may name a gate the suite does not run.

**The reverse direction was measured and deliberately not made a rule.** 78 of
the 136 suite gates have no npm alias. Requiring one would mean 78 lines of
`package.json` mirroring the suite — churn, not safety. It is a **ratchet** at 78
instead: adding a gate with an alias is free, adding one without makes the number
worse on purpose.

**Falsifié avant d'atterrir.** Four one-fact probes, four reds: a gate dropped
from the suite with its alias left behind, an alias pointing at a file that does
not exist, an alias removed from a suite gate (count 78 → 79), and the suite
parser breaking (0 paths parsed, floor fires).

**Gain.** One dark gate over the entire port layer, now live. **Effort.** One
commit. **Risque.** None — all three already passed.

---

## 4. Plan d'exécution incrémental

Least to most risky. Each is one conventional commit.

1. **`test(tooling)`** — the npm-alias ↔ suite-entry gate (§2.4). No behaviour
   change; verified by the gate itself plus a falsifiability probe.
2. **`fix(i18n)`** — key the 11 UI strings (§1.5). Verified by the scan going to
   zero under `ui/` and by the locale key-parity gate. Onboarding is
   **reload-only** to confirm visually on Windows.
3. **`docs`** — record the `_generated/` verdict in `PROJECT_MEMORY.md` (§2.1)
   so the question is not re-opened.
4. **Lot 8(3)** — the shared keylogger aggregation core, which is also the right
   answer to three of the six largest god-files (§2.3). Corpus first, as with the
   logger: the constants half is cheap, the walker half is not.
5. **Lot 6(4)** — the Karabiner catalogue merge, structure before translations.

Everything past step 3 is already in `TODO.md` with a measurement attached; this
audit does not add to that backlog, it confirms it.

---

## 5. Pistes écartées

- **Converting the remaining native modals to webviews** — they are single-field
  dialogs and one of the four named in the prompt already has a shared page. A
  webview host plus a bridge contract plus a native fallback to replace an
  `InputBox` is net negative (§1.1).
- **Shrinking `_generated/` by reading the shared source at runtime** — would put
  a ~130 KB parse back on every driver's boot path to save 134 KB of committed
  text. This is precisely what ADR-002 decided against (§2.1).
- **Splitting god-files by size** — three of the six largest are the keylogger
  walkers, whose real answer is the shared core in Lot 8(3). Splitting first
  makes the merge harder (§2.3).
- **Requiring an npm alias for every suite gate** — 78 of 136 have none, so the
  rule was never true. Enforcing it means 78 lines of `package.json` mirroring
  the suite. Ratcheted instead (§2.4).
- **A `mod` token unifying `ctrl`/`cmd`** — already measured and rejected: it
  resolves 2 cases out of 24. See `TODO.md` §0, "Two logical modifiers, not one".
