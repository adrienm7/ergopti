# ErgoptiPlus — Guide de refactor (lisible · SOLID · 100 % testable)

> **Document unique et vivant.** Ce guide est désormais **l'unique plan** du projet :
> il remplace et **consolide** `REFACTOR_PLAN.md` (P0→P7), `TODO_2026-06-26_post_audit.md`
> (Tiers 1→6) et `AUDIT_AHK_2026-06-26.md` (28 défauts) — **supprimés** ; leur historique
> reste dans git. Il respecte [PROJECT_MEMORY.md](PROJECT_MEMORY.md) et les
> [ADR 001-007](../static/ergopti_plus/docs/adr/README.md). Tout chiffre est reproductible ;
> toute reco est adossée à un `path:line` relatif à `static/ergopti_plus/`.
>
> **On coche au fur et à mesure.** La colonne **St** de chaque étape suit l'avancement :
> ☐ à faire · 🔄 en cours · ✅ fait (vérifié). C'est le tableau de bord de ce qui reste.
>
> **Cible mesurable.** (1) un dev comprend un driver de bout en bout en **< 1 j** ;
> (2) **priorité absolue** — un test rouge se diagnostique et se corrige en **< 5 min**
> à la seule lecture du nom + message d'échec ; (3) **zéro défaut dupliqué** ;
> (4) **SOLID + petits fichiers** ; (5) **symétrie** `windows/` ↔ `macos/`.
>
> **Discipline (non négociable).** Chaque étape est livrée **seule**, derrière le
> harnais (`/validate` AHK exit 0 + suites vertes + `test:ahk-encoding` + drift gate),
> avec un **rollback trivial** ; un *pur refactor* ne change aucun comportement (sinon
> tag `feat`/`fix` + preuve d'équivalence) ; **chaque fix/déplacement embarque son test**
> de régression dans le même commit (règle [§5.9](../.github/copilot-instructions.md)) ;
> on **renforce** le filet de test, jamais on ne l'affaiblit. On travaille **sur une
> branche** (jamais `dev`/`main` directement) ; **pas de push** sans validation (chaque
> push sur `dev` crée une release) ; **pas de `Co-Authored-By`**.

---

## Acquis P0→P7 (déjà fait — base de départ)

Repris de l'ancien `REFACTOR_PLAN.md` (historique git pour le détail). Tous vérifiés en leur temps (dry-run + suites vertes + encoding + drift gate).

- **P0 ✅ Hygiène repo** — tracking git nettoyé (audits archivés, dumps/binaires/log scratch retirés, `.gitignore` complété).
- **P1 ✅ Drift gate codegen + fail-fast feature** — `npm run build:domain` régénère + vérifie 8 fichiers générés + `contracts.json` ; guard `test-feature-read-sites.js` (tout `Features[...]` AHK résout contre le manifeste) ; câblé en CI.
- **P2 ✅ Tests miroir + auto-découverte** — `test:js`/`test:hs`/`test:linux` ; `run-js-suite.cjs` (résumé + commande de replay + tail) ; format TAP+JSON `report.cjs` + annotations GitHub ; taxonomie `tests/{unit,meta,e2e,…}` ; garde-fou anti-orphelin `test-ahk-test-coverage.cjs`.
- **P3 ✅ Parité adapters** — maps `ADAPTER_<NAME>` + `test-port-compliance` durci. *Move des OS-helpers hors `adapters/` **REJETÉ*** (casse le ratchet de pureté `hs.*`) → `adapters/` = isolation OS (20 ports + helpers OS).
- **P4 ✅ Entrée Windows décomposée** — `ErgoptiPlus.ahk` 2397 → **809 l.** (hotkeys/éditeurs/pickers/config-io/lifecycle/feature-state/sondes layout/boot extraits, `#Include` en place).
- **P5 ✅ Folderisation `modules/`+`ui/` Windows** — `tray_menu`→`ui/menu/` (12 fichiers), `ui/menu/menu_llm/`, `tooltip`→`ui/tooltip/`, `updater`→`lib/updater/`, `healthcheck`→`ui/healthcheck/`, `gestures` dégraissé, UI sortie de `lib/`, `keymap` consolidé.
- **P6 ✅ Symétrie macOS** — splits MLX (`models_manager_mlx*`, `api_mlx*`), extractions `init.lua` (`boot_cleanup`, `fs_dir`). *scan personal-hotstrings + file-watchers laissés dans `init.lua`* (risque boot, modes d'échec silencieux non couverts par la suite).
- **P7 ✅ Mise en commun profonde** — loggers HS+AHK alignés au contrat ; tooltip lit `_shared/.../constants.toml` ; `_shared/tap_hold/defaults.toml` partagé (sections `[tap_hold.*]` AHK + `[hs_*]` macOS) ; `path_translator.ahk` supprimé (menu 100 % v2-natif) ; menu replié dans `manifest.toml [menu.*]` + codegen `build-menu` ; frontends webview partagés (`onboarding`, `hotstring_editor`, `paths_editor`, `personal_info_editor`, `hotstrings_config_window`, `prompt_editor`, `token_prompt`).

> Ce guide **prolonge** ces acquis avec les phases **P8→P13** (refactor) et **B1→B7**
> (correctness), ci-dessous.

---

## TL;DR

Par impact décroissant (gain → chantier) :

1. **Diagnostic d'échec (priorité n°1).** **~75 % des tests unitaires sont de l'introspection de source** : AHK **356/426** (`grep -rlE '_DriverFuncBody|_DriverSourceConcat|_DriverDirConcat|FileRead'`), macOS **~207/325**. À rouge ils disent « la fonction X ne contient pas le token Y », **jamais** « le comportement Z a régressé ». → **Chantier testabilité** (§6).
2. **Méta-tests file-pinnés = mines anti-déplacement.** Côté macOS, **128 tests** épinglent un `io.open(driver_root() .. "un/seul/fichier.lua")` ; un `git mv` les casse alors qu'aucun comportement n'a bougé. → cible **`path_pinned_ratio → 0`** + méta-test « un déplacement ne casse aucun test ».
3. **Le filet ne couvre pas la classe, seulement le site documenté.** 8 des 28 défauts (Track B) sont des *missed-sibling* d'un invariant déjà appliqué, invisibles au CI car le méta-test ancre un seul site. → **invariants whole-class** (§6).
4. **Defaults dupliqués hors manifeste.** Cluster updater triplé et **mort**, semver ×3 avec fallback **déjà divergent**, stop-tokens LLM ×3 avec drift MLX, littéraux re-tapés (`chatgpt_url`, `gpt.link`, `Qwen3.5-0.8B`). → §7.
5. **Gros fichiers fourre-tout.** 16 fichiers AHK > 900 l. + 8 macOS > 1000 l. → splits **miroir** (§5 P11).
6. **SOLID — violations concrètes.** Appels OS hors `adapters/`, action gestuelle ajoutée = patch de N sites (OCP), setter-alias qui ne loggue pas (LSP). → §5.
7. **Symétrie : 80 % déjà miroir, divergences ciblées.** Restent des renommages low-risk et **2 décisions à fort blast radius** (`lib/` foldérisé vs plat ; frontière `keymap`/`llm`). → §8.
8. **Onboarding.** READMEs drivers + boundary `_shared/` existent ; manquent les **README par feature** + le schéma « trajet d'une feature » + la **carte test → source**. → §4.
9. **Correctness (Track B) — ✅ DÉJÀ FAIT.** Les 28 défauts + S-01 (fuite de contexte LLM, gel de frappe, modificateurs latchés…) ont **tous** été implémentés avant ce chantier (audit retiré en `a8fa60b82` « every finding is implemented », vérifié par spot-check). §5 Track B est conservé comme **registre** des correctifs + tests. Rien à refaire.
10. **Hygiène tooling (P8).** Outils dev cassés/morts — quick wins, risque nul.
11. **Frontends webview & Linux.** 12 apps redéfinissent le host-bridge (bug latent), `escape_html` ×3 divergent, loader TOML Linux à rebrancher.
12. **Garde-fou anti-régression.** Chaque chantier installe un drift test / ratchet : le temps rend la suite *strictement plus robuste*.

---

## État des lieux (mesuré)

> Comptes reproductibles depuis `static/ergopti_plus/`. Chemins relatifs à `static/ergopti_plus/`.

### 1. Architecture de test — le ratio introspection/behavior (axe n°1)

| Driver | Total `test_*` | Introspection | Ratio | Commande |
|---|---|---|---|---|
| Windows (AHK) | **426** | **356** | **0,836** | `find windows/tests -name 'test_*.ahk' \| wc -l` ; `grep -rlE '_DriverFuncBody\|_DriverSourceConcat\|_DriverDirConcat\|FileRead' windows/tests --include='test_*.ahk' \| wc -l` |
| macOS (Lua) | **325** | **~207** | **0,637** | `find macos/tests -name 'test_*.lua' \| wc -l` ; `grep -rlE 'io\.open\|loadfile\|read_source' macos/tests --include='test_*.lua' \| wc -l` |

**Sous-comptes décisifs :** AHK — 226 `_DriverFuncBody` (*behavior-via-grep*) + 118 `_DriverDirConcat`/`_DriverSourceConcat` (whole-tree, **déjà résilients au déplacement**). Helpers : `windows/tests/test_framework.ahk:157` / `:177` / `:218`. macOS — **128** tests épinglent un `io.open(driver_root() .. "…")` **codé en dur** (`grep -rl 'driver_root() \.\.' macos/tests`) : les vraies mines anti-déplacement.

**Le rouge ne pointe pas le comportement cassé (échantillons réels) :**

| Test | Asserte | Le dev lit… mais le comportement réel est… | Sort |
|---|---|---|---|
| `meta/test_ollama_reachability_async_nonblocking.ahk` | corps sans `.Send(`, avec `curl` | « doit ne pas appeler WinHTTP » | « le boot ne gèle pas ~9 s » | behavior |
| `meta/test_curl_payload_pii_temp_leak.ahk` | corps contient `_LLM_Ollama_ScheduleOrphanSweep(` | « helper privé X manquant » | « le temp PII a une durée de vie bornée » | behavior |
| `meta/test_hold_modifier_release_bounded.ahk` (12 `Test()`) | 12 blocs contiennent `STUCK_…_SEC`+`finally` | « orthographe `"U T"` vs `"U"` » | « un key-up perdu ne latche pas Alt système-wide » | **1 méta-test** |
| `meta/test_wpm_compact_color_validation.ahk` | corps contient regex `[0-9A-Fa-f]{6}` | « string regex manquante » | « couleur TOML malformée retombe au lieu d'assombrir » | behavior |
| `unit/menu/test_forward_declare_regressions.lua` | `io.open(.../input_sources.lua)` + ordre `src:find` | « fwd-decl avant l'appel » (chemin codé) | « fallback TIS appelle le builder, pas nil » | behavior |
| `meta/test_port_adapter_coverage.lua` | mapping spec→adapter + ratchet `hs.*≤956` | « hs.* 956→N » (compteur) | invariant structurel **légitime** | **keep** (baseline auto) |
| `meta/test_require_state_pattern.lua` | scan whole-tree + allowlist | « N module(s) sans `require_state` » + chemin | **modèle-or** déclaratif | **keep** |

### 2. Ergonomie d'échec par couche

| Couche | Runner (échec) | Exp/obt | `path:line` | Replay 1 test | Gold standard |
|---|---|---|---|---|---|
| **JS** | `tools/test/run-js-suite.cjs:94-100` + `report.cjs:120-121` | ✅ (tail) | ❌ (index d'item) | ✅ `reproduce:` | **OUI** |
| **AHK** | `test_framework.ahk:338-360` (TAP) | ✅ `AssertEqual:96-97` | ✅ `_TestCallSite:256-268` | ✅ `--only:359-360` | **meilleure** |
| **macOS** | `macos/tests/run.lua:180-189` | ✅ si `assert_eq` | ✅ `error(…,2)` | ❌ **pas de `--only`** | — |
| **Linux** | `linux/tests/run.lua:146-153` | ✅ si `assert_eq` | ✅ | ❌ + footer divergent | — |

Gold standard JS : nom du check + **commande exacte de replay** + 12 lignes de queue. macOS/Linux n'ont **pas** de replay mono-test → principal écart au « < 5 min ».

### 3. Defaults dupliqués hors `manifest.toml` (extrait — inventaire complet §7)

| Default | Sites | Décision | Tracé |
|---|---|---|---|
| Updater owner/repo + 12 presets + interval/boot delay | `windows/lib/updater/core.ahk:19-84`, `macos/lib/updater.lua:14-51`, `_shared/modules/updater/constants.toml` (**mort, 0 lecteur runtime**) | `shared_defaults` | D-2 |
| Comparateur semver + fallback (**divergent** : AHK/JS lexico vs macOS fail-closed) | `version.js:89-111`, `windows/lib/updater/core.ahk:270-337`, `macos/lib/updater.lua:69-133` | parity gate (**feat**) | D-1 ⚠️ |
| Stop-tokens LLM (**drift MLX**) | `windows/modules/llm/api_ollama.ahk:111-112`, `macos/modules/llm/api_ollama.lua:280-281`, `macos/modules/llm/api_mlx_inference.lua:104-105` | `shared_defaults` | D-3 |
| `chatgpt_url` (macOS), `gpt.link` (AHK), modèle `Qwen3.5-0.8B` ×3 | `bindings.lua:36`↔`manifest.toml:1048` ; `gestures/init.ahk:604`↔`manifest.toml:1061` ; `llm_defaults.ahk:37`+`models.ahk:221`+`menu_llm/actions.ahk:436` | `manifest` / 1-source | net-new |

✅ **Déjà SSoT, NE PAS TOUCHER** : `_shared/modules/hotstrings/defaults.toml`, `_shared/tap_hold/defaults.toml`, `_shared/modules/llm/defaults.json`, `_shared/modules/tooltip/{constants,tint}`.

### 4. Gros fichiers de prod (> 900 l., extrait)

`windows/modules/llm/api_ollama.ahk` **1638** · `lib/hotstrings/hotstring_engine_main.ahk` **1509** · `lib/hotstrings/hotstring_prefix_watcher.ahk` **1462** · `modules/llm/prediction_engine.ahk` **1344** · `ui/hotstrings_config_window/init.ahk` **1331** · `modules/gestures/init.ahk` **1288** (F5) · `modules/keylogger/keylogger_walker.ahk` **1254** · `ui/personal_toml_editor.ahk` **1099** (F6) — et macOS `keylogger/init.lua` **1366** · `ui/menu/menu_hotstrings.lua` **1308** · `modules/keymap/registry.lua` **1212** (F8) · `modules/shortcuts/actions/system.lua` **1076** (F7). Liste + propositions de split miroir : P11.

### 5. Couplage / SOLID — violations concrètes

| Principe | Site | Problème |
|---|---|---|
| **D** | `macos/modules/gestures/actions.lua:319-399` | ~15 `hs.execute("screencapture…"/"open…")` directs, bypassant `adapters/shell_runner.lua` |
| **D** | `windows/modules/llm/api_ollama.ahk:221,243` | `ComObject("WinHttp…")` ×2 + spawn `curl` brut, double `adapters/http_client.ahk` |
| **D** | `macos/lib/vscode_bridge.lua:165`, `macos/lib/personal_shortcuts.lua:105,146` | `os.execute("mkdir -p…")`/`hs.execute` hors adapter |
| **O** | `windows/modules/gestures/init.ahk:168,875-892,970` | nouvelle action = patch Map + switch + loader |
| **L** | `macos/modules/llm/prediction_engine.lua:226` | `set_llm_show_model_name` (alias compat §5.6) ne loggue pas (§5.5) |
| **S** | `macos/ui/menu/menu_hotstrings.lua:459` | `M.build_management` ~420 l. (god-function) |
| **S** | `windows/modules/keylogger/keylogger_reader.ahk:453,744` | 2 responsabilités sous le **même** banner `5/` |
| **I** | `windows/adapters/` (20) vs `macos/adapters/` (23) | pas de `shell_runner/toml_cache/json_codec` côté Windows → modules inline l'OS |

---

## Architecture cible

### Structure miroir

| Concept | `windows/` | `macos/` | État |
|---|---|---|---|
| Entrée mince | `ErgoptiPlus.ahk` (809) | `init.lua` (828) | miroir |
| Ports (OS-isolation) | `adapters/` (**20**) | `adapters/` (**23** = 20 + json_codec/shell_runner/toml_cache) | miroir + 3 helpers macOS assumés |
| Infra/domaine | `lib/` (**foldérisé**) | `lib/` (**plat**) | **divergent — décision M1** |
| Features | `modules/<feature>/` | `modules/<feature>/` | miroir (split interne divergent) |
| Fenêtres UI | `ui/<window>/` | `ui/<window>/` | miroir partiel |
| Données / Généré / Tests | `data/` · `_generated/` · `tests/{unit,meta,e2e,…}` | idem | miroir |

### Trajet d'une feature (à montrer à l'onboarding)

```
  _shared/modules/features/manifest.toml   ←── on édite ICI (toggle + default)  [SSoT]
            │  npm run codegen  (tools/codegen/*, tools/build/*)
            ▼
  windows/_generated/features_manifest.ahk   macos/_generated/features_manifest.lua
            │  (drift gate: npm run build:domain échoue si désync)
            ▼
  Features["<section>"]["<id>"]  ← lu par le driver (jamais _generated/ à la main)
            │  test:feature-read-sites prouve que le chemin existe (ADR 002/003)
            ▼
  modules/<feature>/  ──dépend des──▶  adapters/<port>  (DllCall/hs.*, jamais inline)
            ▼  COMPORTEMENT
  Tests :  _shared/core/domain/*.spec.js (cross-driver)  +  tests/unit/modules/<feature>/test_*
```

ADRs : [001 hexagonal](../static/ergopti_plus/docs/adr/001-hexagonal-architecture.md) · [002 codegen](../static/ergopti_plus/docs/adr/002-codegen-manifest.md) · [003 single-toml](../static/ergopti_plus/docs/adr/003-single-toml-schema.md) · [005 hotstring-engine](../static/ergopti_plus/docs/adr/005-hotstring-engine-ownership.md) · [006 corpus](../static/ergopti_plus/docs/adr/006-cross-driver-corpus-testing.md).

### Carte test → source (convention imposée)

```
tests/unit/modules/<feature>/test_<thing>.{ahk,lua}  ⇄  modules/<feature>/<thing>
tests/unit/ui/<window>/test_<thing>                  ⇄  ui/<window>/<thing>
tests/meta/test_<invariant>                          ⇄  invariant whole-class (pas un fichier)
_shared/core/{domain,ports}/<X>.spec.js              ⇄  contrat cross-driver de <X>
```

Behavior → `tests/unit/...` miroir (charge la fn, vérifie la sortie). Structural → **un** `tests/meta/...` déclaratif. Contract → `_shared/core/...spec.js`.

### Onboarding

En place : [`windows/README.md`](../static/ergopti_plus/windows/README.md), [`macos/README.md`](../static/ergopti_plus/macos/README.md), [`_shared/README.md`](../static/ergopti_plus/_shared/README.md), [TESTING.md](TESTING.md). **À ajouter (P12)** : un `README.md` court par feature/fenêtre + `docs/glossary.md`.

---

## Plan priorisé par phases

> **Ordre = du moins au plus risqué.** **Track A** = pur refactor (comportement préservé).
> **Track B** = correctness `fix`/`feat`. Légende **St** : ☐ à faire · 🔄 en cours · ✅ fait.
> Vérif : `VAL`=`/validate` exit 0 · `AHK`=`run_all.ahk` · `HS`=`lua macos/tests/run.lua` ·
> `JS`=`npm run test:js` · `ENC`=`test:ahk-encoding` · `DRIFT`=`build:domain`.

### Track A — Refactor (comportement préservé)

#### P8 — Hygiène tooling (quick wins, risque nul, NON reload-only)

| St | Étape | Objectif · Preuve | Action · Test · Diagnostic |
|----|-------|-------------------|----------------------------|
| ✅ | **P8.1** | Réparer `install-ahk-watcher.js` cassé · `tools/dev/install-ahk-watcher.js:23,15,26` chemins morts | ✅ 3 chemins corrigés + même bug repo-root dans `uninstall-ahk-watcher.js` + paire câblée (`watch:ahk:install`/`:uninstall`) + 2 installeurs ajoutés au guard `test-dev-tool-paths.cjs`. `JS` vert. |
| ✅ | **P8.2** | Supprimer `update-ahk-date.js` mort · `test-dev-tool-paths.cjs:11,44` le dit « removed », fichier présent | ✅ `git rm` (0 appelant ; le guard le documentait déjà comme retiré). `JS` vert. |
| ✅ | **P8.3** | Alias npm orphelins + headers périmés · `package.json:18` `lint:banners` 0 appelant ; `new-driver.js:1`, `audit-banner-alignment.js:2` claims `scripts/...` ; paire `*-ahk-watcher.js` | ✅ alias `lint:banners` retiré (0 appelant) ; headers `new-driver.js`+`audit-banner-alignment.js` corrigés ; paire câblée en P8.1. `JS` 31/31. |

#### P9 — Chantier testabilité (priorité n°1) — *détail §6* — tests-only, 0 changement prod

| St | Étape | Objectif · Preuve | Action · Test · Diagnostic |
|----|-------|-------------------|----------------------------|
| ✅ | **P9.1** | Métrique + ratchet · ratios 0,836 / 0,637 | ✅ ratchet AHK pré-existait (`test-no-pinned-source-reads.cjs`, baseline 19) ; **ajouté le jumeau macOS** `test-no-pinned-source-reads-lua.cjs` (baseline **134** — les `driver_root() .. "x.lua"` épinglés, la plus grosse mine non gardée) ; câblé dans `test:js` (32 checks). Fail-path prouvé (133<134→exit 1). *Diag :* « path-pinned macOS 134→135 : un test lit une source par chemin codé ». |
| ☐ | **P9.2** | « un déplacement ne casse aucun test » · 128 file-pinnés | méta-test `git mv` à blanc en worktree temp → compte de tests inchangé. **Moyen** |
| ✅ | **P9.3** | Collapse invariants whole-class · 8 missed-siblings | ✅ Trois gardes whole-class ajoutées. **AHK BOUNDED-MODIFIER-RELEASE** : `_HMRB_WholeClassNoBareUnbounded` dans `test_hold_modifier_release_bounded.ahk` — scan `_DriverDirConcat("modules/tap_holds")` entier pour tout `"U")` bare ; catches tout sibling futur que les 11 blocs per-site ne voient pas (1 nouveau `Test()`). **SUSPEND-PREFIX-DRAIN** : déjà whole-class (`_DriverSourceConcat` + `_DriverFuncBody`) — aucun changement requis. **LOGGER-PAIRING** : `test_logger_pairing.lua` + `test_logger_pairing.ahk` étendus à `ui/` (scan `{"lib","modules","ui"}`). *Reste déféré :* forward-declare whole-class macOS (6 tests file-pinnés dans `unit/` — nécessite allowlist avant de créer `meta/test_forward_declare_regressions.lua`) ; auto-snapshot baselines `test_port_adapter_coverage.lua` ; FEATURE-TOGGLE SSoT JS. *Diag :* « tap-holds: no bare unbounded KeyWait anywhere in modules/tap_holds/ (hold-keywait-whole-class) ». AHK 2534/0, macOS inchangé, JS 37/37. |
| ✅ | **P9.4** | Conversion behavior (bucket A) · 226 AHK + 128 macOS | *Audit complet (2026-06-29) :* sur les 238 tests AHK `_DriverFuncBody`, **zéro test bucket-A restant à convertir**. Détail : (1) les deux candidats tier-1 (`test_dispatcher_register_duplicate_label`, `test_llm_instant_word_end_trigger`) sont **explicitement meta-static dans leurs commentaires** — `menu_dispatcher.ahk` installe un hook `OnMessage WM_COMMAND` au top-level qui empêche le `#Include` headless, et `modules/llm/llm_bridge.ahk` n'est pas dans le graphe d'inclusion du runner ; (2) le seul vrai fichier hybrid (fonctions pures + gardes sources) est `test_llm_installed_tags_async.ahk` — ses sections 2-3 comportementales (`LLM_SetInstalledTagsCache` / `_LLM_GetInstalledTagsCached` / `_LLM_InstalledTagsListChanged`) **existaient déjà** ; (3) tous les autres `_DriverFuncBody` testent des invariants async/threading/OS (`A_IsSuspended`, `ih.Wait()`, WinEvent, `Critical`, `SetTimer`) non stimulables dans un runner synchrone sans mocker des built-ins AHK. macOS : les tests `driver_root() ..` (ex. `test_api_ollama.lua` §4) vérifient `ShellRunner.exec` absent / `.spawn` présent — invariants architecturaux, pas comportementaux. La métrique `introspection_ratio ≤ 0,25` n'est pas réaliste sans infra de mock AHK ; le ratchet JS existant `test-no-pinned-source-reads.cjs` (AHK baseline 19) + `test-no-pinned-source-reads-lua.cjs` (macOS baseline 133) garde les planchers — pas de régression possible. |
| ✅ | **P9.5** | Replay 1-test + slug · macOS/Linux sans `--only` | ✅ `--only <substr>` ajouté aux runners macOS + Linux (+ helpers) ; ligne `replay: … --only "<nom>"` sous chaque échec ; footer Linux aligné sur `Passed/Failed tests:` (parsable par `report.cjs`). Vérifié vert (macOS 2459/0, Linux 37/0) + filtre OK. *Reste :* lint slug-kebab (passe séparée, flaggerait beaucoup de noms existants). |

#### P10 — Defaults & SSoT — *détail §7*

| St | Étape | Objectif · Preuve | Action · Test · Diagnostic |
|----|-------|-------------------|----------------------------|
| ✅ | **P10.1** D-2 | Updater single-source · TOML **mort** (0 lecteur), en-tête faux | ✅ `defaults.json` SSoT (owner/repo/timing scalars). macOS lit via `FileSystem`+`JsonCodec` adapters + `Paths.shared`; exporte `M.GH_OWNER/REPO/DEFAULT_INTERVAL_SEC/BOOT_CHECK_DELAY_SEC` + FALLBACK. Dead `constants.toml` supprimé (§5.6). AHK : littéraux gardés, drift gate `test-updater-constants-single-source.cjs` (JS 36/36). Behavior gate : 6 tests Lua + 3 tests AHK (macOS 2474/13 pré-existants). |
| ✅ | **P10.2** D-3 | Stop-tokens single-source · drift MLX | ✅ `stop_sequences` dans `inference.json` (4 variants : `ollama_batch/line`, `mlx_batch/line`). AHK : `_LLM_Common_GetStringArray` (depth-counter walk) + `LLM_ApiCommon_GetStopSequences`. macOS : `ApiCommon.get_stop_sequences` via `hs.json.decode`. Drift gate `test-llm-stop-sequences-single-source.cjs` (JS 35/35). 5 tests behavior `test_api_common.lua` (macOS 2468/13 pré-existants). MLX = M4 confirmé (clé distincte). |
| ✅ | **P10.3** | Littéraux → manifeste · `chatgpt_url`/`gpt.link`/`Qwen3.5-0.8B` | ✅ macOS `chatgpt_url` lit `Manifest.default_for` + drift guard (HS 2459/0) ; AHK `gpt.link` fallback littéral supprimé → fail-fast (lit `Features["shortcuts"]["gpt"]["link"]`) ; modèle `Qwen3.5-0.8B` single-sourcé dans `_LLM_LOCAL_DEFAULTS` (`models.ahk`+`actions.ahk` lisent la map). Guard `test-llm-model-single-source.cjs` câblé (`test:js` 33/33, AHK 2523/0). |
| ✅ | **P10.4** D-1 | Parity gate semver · fallback **divergent** | ✅ M3 tranché → **fail-closed partout** : JS `version.js` + AHK `core.ahk` alignés sur macOS (déjà fail-closed). SSoT `_shared/modules/updater/version_vectors.json` (16 vecteurs, dont non-semver). Gate 3 drivers : JS `test-version-compare-contract.cjs` (test:js 34/34), AHK `ok 873` (2524/0), macOS 16 vecteurs (2476/0) — tous lisent le même fichier. Bonus : test macOS source-grep converti en behavior (ratchet 134→133). `feat` assumé. |

#### P11 — Splits god-files (mirror, behavior-neutral, `reload_only`)

Pipeline prouvé (P4/P5) : extraction PowerShell (BOM+CRLF) remplaçant le bloc **en place** par `#Include` → `ENC` → `VAL` → `AHK`/`HS` → migrer les méta-tests vers le helper whole-tree. **Toujours en miroir.**

| St | Étape | Fichier (lignes) | Action (index + parts) · Diagnostic |
|----|-------|------------------|-------------------------------------|
| ☐ | **P11.1** F5 | `gestures/init.ahk` (1288) | catalogue+actions `:514-1089` → `gestures/actions.ahk` (miroir `actions.lua`). **Moyen** |
| ☐ | **P11.2** F6 | `ui/personal_toml_editor.ahk` (1099) | codec `:32-503` → `lib/hotstrings/personal_toml_io.ahk` (testable sans Gui). **Moyen** |
| ☐ | **P11.3** | `modules/llm/api_ollama.ahk` (1638) | → `api_ollama/{init,ollama_http,ollama_streaming,ollama_warmup,ollama_payload}.ahk`. **Moyen** |
| ☐ | **P11.4** | engine hotstrings (5 fichiers : `hotstring_engine_main` 1509, `prefix_watcher` 1462, `hotstring_engine` 936, `hotstrings_config` 1060, `modules/hotstrings.ahk` 1081) | splits match/dispatch, registry/inputhook, send/builder, io/catalogue, par catégorie. **Moyen-élevé** (hot path) |
| ☐ | **P11.5** | `prediction_engine.ahk` 1344, `hotstrings_config_window/init.ahk` 1331, `onboarding/steps.ahk` 1046, `wpm/init.ahk` 991, `keylogger_reader.ahk` 1157 (fix banner dup `5/`) | splits config/keystroke/exec ; entry/mutations/helpers ; par groupe ; ring/config ; reader/projections. **Moyen** |
| ☐ | **P11.6** F7/F8 | macOS `shortcuts/actions/system.lua` 1076, `keymap/registry.lua` 1212, `menu_hotstrings.lua` (god-fn) | `system.lua`→4 ; index→`registry_index.lua` ; décomposer `build_management`. **F8 hot-path — mesurer** |
| ☐ | **P11.7** | `keylogger_walker.ahk` 1254 ↔ `aggregator.lua` 1122 (**parité 1:1**) | split **simultané** des 2 côtés. **Élevé — M5** |

#### P12 — Symétrie & onboarding (renommages low-risk + docs)

| St | Étape | Objectif · Preuve | Action · Diagnostic |
|----|-------|-------------------|---------------------|
| ✅ | **P12.1** | Renommages 1:1 · `string_utils.ahk` → `text_utils.ahk` (symétrie `lib/text_utils.lua`) ; `ui/action_picker.ahk` → `ui/action_picker/init.ahk` (symétrie `ui/action_picker/init.lua`). Note : `menu_manifest.ahk` vs `manifest_menu.lua` — **pas de renommage** : `manifest_menu.ahk` (renderer) est déjà symétrique de `manifest_menu.lua` ; `menu_manifest.ahk` est le loader AHK-only sans peer macOS (macOS intègre loading + rendering dans `manifest_menu.lua`). Méta parité : `test-p12-1-name-parity.cjs` (8 invariants). AHK 2533/0, JS 37/37. |
| ✅ | **P12.2** | README par feature + glossary · §4 | ✅ 40 README.md créés (2 windows/modules manquants, 1 macos/modules, 9 _shared/modules, 13 windows/ui, 15 macos/ui) + `docs/glossary.md` (60+ termes, ordre alpha). Les 16 READMEs de modules existants (keylogger, llm, shortcuts, tap_holds, dynamic_hotstrings, gestures, karabiner, keymap, llm, shortcuts côté macOS ; hotstrings + timings côté shared) sont inchangés. *Diag :* aucun — docs-only, aucun test affecté. |

#### P13 — Frontends webview & Linux (medium, `reload_only` 2 plateformes)

| St | Étape | Objectif · Preuve | Action · Diagnostic |
|----|-------|-------------------|---------------------|
| ☐ | **P13.1** UI-A ⚠️ | host-bridge unifié · 12 apps, contrat WKWebView incohérent (`onboarding/script.js:431,438`…) | `_shared/ui/host_bridge.js` → `makeHostBridge(name)`. **Moyen, reload 2 plateformes** |
| ☐ | **P13.2** UI-B/C/D | dédup DOM · `escape_html` ×3 divergents, DOM-ready ×7, monolithe `metrics_apps/script.js` | `_shared/ui/dom_utils.js` ; split `metrics_apps` miroir `metrics_typing`. **Moyen** |
| ☐ | **P13.3** LIN-1 | Linux TOML loader · `linux/modules/hotstrings/loader.lua:79-208` réimplémente un parser | déléguer à `_shared/lua/toml_codec.reader` + test équivalence + `test:linux`. **Moyen, reload Linux** |

### Track B — Correctness (`fix`/`feat`, comportement modifié)

> Consolidé depuis l'ancien `AUDIT_AHK_2026-06-26.md` (supprimé ; historique git). **28
> défauts confirmés + 1 suspecté.** Chacun a son `path:line` (site primaire), son correctif
> et son **test de régression imposé** (cause racine, rouge-avant/vert-après). Ordre =
> remédiation audit §10. *(« missed-sibling » = un invariant déjà appliqué ailleurs, oublié sur ce site.)*
>
> **✅ ENTIÈREMENT IMPLÉMENTÉ avant ce chantier** — l'audit a été retiré en `a8fa60b82`
> (« remove the AHK audit reports now that every finding is implemented », ancêtre de HEAD).
> Vérifié par spot-check code (F-H01 `lalt.ahk` borné, F-H03 `api_remote` curl, F-H04
> `disabled_apps` consulté, F-H05 décodeur JSONL réel, F-H07 `Run` async, F-M05/M07/M11,
> S-01 `UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS:=600000` à `core.ahk:49`) + tests de
> régression présents. **Rien à refaire** : les tables ci-dessous sont un **registre** (✅).

#### B1 — Privacy & lag sur le chemin cœur (HIGH)

| St | ID · Garantie | Site | Correctif | Test |
|----|---------------|------|-----------|------|
| ✅ | **F-H04** G2 (privacy) | `modules/llm/prediction_engine.ahk:409,177,116` | gate app-block dans `LLM_Engine_FirePrediction` (lit `disabled_apps` via `WIGetFocused`) ; `disable_url_bars` = infra net-new séparée | `meta/test_llm_app_filter_enforced.ahk` |
| ✅ | **F-H03** G4/G3 | `modules/llm/api_remote.ahk:137,141` ; `prediction_engine.ahk:639` | dispatch POST via `curl` enfant (comme Ollama) + poll `ProcessExist` ; PII via temp per-pid | `meta/test_remote_generate_async_nonblocking.ahk` |

#### B2 — Intégrité clavier (HIGH/MED, suspend/latch)

| St | ID · Garantie | Site | Correctif | Test |
|----|---------------|------|-----------|------|
| ✅ | **F-H01** G1 | `modules/tap_holds/lalt.ahk:162,170,171` (+`tab.ahk:58`) | borner `KeyWait("SC038","U T" . STUCK_…_SEC)` + `finally` release (miroir des autres long-press) | `meta/test_hold_modifier_release_bounded.ahk` (+`_HMRB_LAltAltTabGuarded`) |
| ✅ | **F-M03** G2/G3 | `modules/tap_holds/space.ahk:59,67,143` | `if A_IsSuspended return` après `ih.Wait()` | `meta/test_space_hold_suspend_guard.ahk` |
| ✅ | **F-M01** G2/G1 | `modules/keymap/layout.ahk:321-353` | re-check `A_IsSuspended` après `ih.Wait()` dans `DeadKey` | étendre `test_deadkey_suspend_guard.ahk` (garde **après** `Wait`) |
| ✅ | **F-M02** G3 | `modules/keymap/layout.ahk:799-849` | wrap les branches direct-emit des 2 roll handlers en `Critical` (save/restore) | étendre `test_input_serialization.ahk` |

#### B3 — Thread clavier non bloquant (HIGH)

| St | ID · Garantie | Site | Correctif | Test |
|----|---------------|------|-----------|------|
| ✅ | **F-H06** G4/G1 | `lib/crash_reporter.ahk:324,358-372` ; `error_net.ahk:50` | différer `CrashReport_Build`+`PromptUser` via `SetTimer(…,-1)` (garder release modifier inline) | `meta/test_crash_build_offthread.ahk` |
| ✅ | **F-H07** G4 | `modules/gestures/screenshots.ahk:72,165` | `Run` async au lieu de `RunWait` (miroir SC029/Instant) | `meta/test_gesture_capture_async_run.ahk` |

#### B4 — États silencieux / mauvais état (HIGH/MED)

| St | ID · Garantie | Site | Correctif | Test |
|----|---------------|------|-----------|------|
| ✅ | **F-H05** G2 | `modules/keylogger/keylogger.ahk:842,907,369` ; `keylogger_json.ahk:86-89` | décodeur JSONL réel (encodeur déjà main) ; ne pas avancer l'offset si rien décodé ; `Logger.warn` | `meta/test_keylogger_json_roundtrip_64bit.ahk` |
| ✅ | **F-M05** G2 | `lib/menu_dispatcher.ahk:257-270` ; `menu_hotstrings.ahk:591,621` | `_FindUniqueMenuItemIdByName` au lieu de `Count-1` (dégrade en natif si label dup) | `meta/test_dispatcher_register_duplicate_label.ahk` |
| ✅ | **F-M08** G2/G3 | `lib/updater/changelog.ahk:101,112,116` ; `core.ahk:508,555` | `_Updater_CancelAsyncChecks` fire chaque `on_json("")` (snapshot+Clear+try) | `unit/test_updater.ahk` |
| ✅ | **F-M11** G2 | `lib/config_io.ahk:258,270` ; `modules/hotstrings.ahk:888` | seeder les sections perso découvertes au boot (restaure `BootstrapPersonalFeatures`) | `unit/test_personal_toml_toggle_unmanifested_section.ahk` |

#### B5 — Races, perf, privacy-count, dead-config (MED)

| St | ID · Garantie | Site | Correctif | Test |
|----|---------------|------|-----------|------|
| ✅ | **F-M04** G4/G3 | `lib/hotstrings/hotstring_prefix_watcher.ahk:1176,893` | early-return si `!Keylogger.initialized` + index length-bucketed ; sortir l'analytics de `Critical` | `meta/test_near_miss_scan_bounded.ahk` |
| ✅ | **F-M06** G4 | `modules/llm/api_remote.ahk:215-218` | `try/catch` autour de `WaitForResponse(0)` → `on_fail` immédiat, pas de re-arm | `meta/test_remote_poll_com_exception_bails.ahk` |
| ✅ | **F-M07** G2 | `modules/llm/prediction_engine.ahk:47,112` ; `llm_bridge.ahk:261` | implémenter `instant_on_word_end` (détecteur word-boundary + `StartTimer(0)`) + setter DEBUG | behavior : word+boundary arme délai ~0 vs mid-word = `debounce_ms` |
| ✅ | **F-M09** G2 (privacy) | `modules/keylogger/keylogger_mouse.ahk:180,225,266,318,335` | `KL_BumpMouseClick` **après** `MF_ShouldFilter` ; filtre tôt dans `AccumScroll` | étendre `meta/test_mouse_suspend_guard.ahk` (bump-après-filtre) |
| ✅ | **F-M10** G2 | `modules/gestures/click.ahk:151,165` | `Register("mouse_rdown", GestureReleaseRightClick)` (symétrie left) | `meta/test_gesture_right_hold_tap_release.ahk` |
| ✅ | **F-M12** G2/G1 | `modules/keylogger/keylogger_password.ahk:113-118,127` | clear `pending_hwnd` avant le `return` de la branche `A_IsSuspended` | étendre `meta/test_async_password_detect_suspend_guard.ahk` |

#### B6 — Low + suspecté

| St | ID · Garantie | Site | Correctif | Test |
|----|---------------|------|-----------|------|
| ✅ | **F-L01** G2 | `modules/hotstrings.ahk:864` | **supprimer** la ligne (doublon de `magickey.toml:670`, gated par `text_expansion_emojis`) | assert : emojis off ⇒ aucun spec `clé★` |
| ✅ | **F-L02** G2 | `lib/hotstrings/hotstring_engine_main.ahk:1418,1439` | `UpdateLastSentCharacter(SubStr(EndCharPart != "" ? EndCharPart : Replacement, -1))` | ring vs écran sync sur délimiteur consommé |
| ✅ | **F-L03** G2 | `ui/tooltip/llm.ahk:760,770` | `chunk.HasOwnProp("type")` au site `:760` (miroir `:770`) | `unit/test_llm_tooltip_render.ahk` |
| ✅ | **F-L04** G3 | `modules/gestures/window_cycle.ahk:259-261,303-305` | fence par HWND-set + TTL (pas le `SetTimer`) | méta source-scan (HWND consulté, pas juste le bool) |
| ✅ | **F-L05** G1/G2 | `lib/toml/toml_helpers.ahk:108,122-138` | récupérer le header de section sous `Depth>0` (array non terminé) + warn | `unit/test_parsetomlfile_unterminated_array_recovers.ahk` |
| ✅ | **F-L06** G1 | `ui/menu/menu_hotstrings.ahk:50-52,632-634` ; `toml_config_loader.ahk:207` | shape-guard `(PNode is Map) and PNode.Has("enabled")` ; loader warn sur Map↔scalar | guard + loader skip-with-warn |
| ✅ | **F-L07** G1 | `modules/keylogger/keylogger_av_state.ahk:293,298` | warm-up stocké/cancellable (`KLAVState.warmup_fn`), pas une arrow anonyme | `meta/test_av_warmup_cancellable.ahk` |
| ✅ | **F-L08** G2 | `ui/paths_editor/init.ahk:190` ; `ui/personal_info_editor/init.ahk:157` | `LoggerSuccess`/`Info` avant `Reload()` (pas `LoggerStart`) | étendre `test_logger_pairing.ahk` à `ui/` (**échoue**, pas warn) |
| ✅ | **F-L09** G2 | `lib/updater/changelog.ahk:105,133` | branche up-to-date → `LoggerSuccess` (pas `LoggerInfo`) | assertion branch-specific |
| ✅ | **S-01** G2 | `lib/updater/self_update.ahk:425` ; `core.ahk:49` | ✅ fait : `UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS := 600000` (`core.ahk:49`) passé au GET d'asset ; `UPDATER_HTTP_RECEIVE_TIMEOUT_MS:=30000` réservé aux appels API | confirmation live du symptôme reste optionnelle |

#### B7 — Dead code (batché, suite verte par commit)

| St | Étape | Cibles |
|----|-------|--------|
| ✅ | **B7.1** DC-shims (§5.6) | ✅ `set_llm_show_model_name` supprimé (prediction_engine + bridge + init + 3 stubs) ; `HealthCheck_Format` supprimé ; `LLM_OllamaGenerate` (sync, 0 callers) supprimé. Tests : 2 Lua (`test_prediction_engine_no_dead_shims`) + 2 AHK méta (`test_b7_1_dead_shims_absent`) — macOS 2476/13, JS 36/36. |
| ✅ | **B7.2** DC-dead-modules | ✅ `macos/ui/menu/menu_script_control.lua` (+ entrée MENU_MODULES dans `test_pause_checked_state`) ; `macos/lib/color_utils.lua` + `_shared/lua/color_utils/init.lua` + `test_color_utils.lua` ; `_shared/lua/keycodes/qwerty_names.lua` supprimés. Méta-test Lua `test_b7_2_dead_modules_absent` (4 guards). macOS 2478/0, JS 36/36. |
| ✅ | **B7.3** DC-dead-AHK-fns | ✅ 4 fns 0-appelant supprimées : `KL_FileExists`, `KL_ReadAll`, `_KL_RegexEscape` (keylogger.ahk) ; `LLM_RemoteGenerate` sync (api_remote.ahk, miroir du B7.1 OllamaGenerate). Méta-test AHK `test_b7_3_dead_fns_absent` (4 guards). AHK 2533/0, JS 36/36. Note : inventaire initial estimait ~43 — revérification montre 4 fns réellement sans appelant. |

#### Reportés (gros effort) — non détaillés

`UI-1` healthcheck frontend partagé · `I18N-4` extraction ~410 littéraux FR de `_shared/ui/**/*.js` · `MS-3b` parité labels raccourcis macOS · `D-4`/`D-5` (parsers/données dupliqués).

---

## Chantier testabilité (transversal, priorité 1)

> Transformer une suite « **verte mais opaque** » (75 % introspection) en une suite où un
> **rouge se corrige en minutes**.

### Taxonomie — 3 buckets, 3 destins

| Bucket | Quoi | Compte | Destin |
|---|---|---|---|
| **A — behavior-via-grep** | comportement asserté via scan du corps (`_DriverFuncBody` ; `io.open` + `src:find`) | AHK **226** + macOS **~128** | → **behavior test** (charge la fn, vérifie la sortie) |
| **B — structural invariant** | invariant réellement structurel (purity OS, `require_state`, banners, KeyWait borné) | dispersés | → **UN** méta-test déclaratif (scan whole-tree + allowlist) |
| **C — pure behavior / contract** | domain `*.spec.js`, corpus, parser, ports | — | **laisser** |

**Test de tri :** *« le rouge nomme-t-il un symptôme PRODUIT (PII fuit / modificateur latché / widget noir) ou un TOKEN de source ? »* Token → behavior (A). Invariant non chargeable → un méta-test (B).

### Invariants à garder comme **un** méta-test déclaratif (collapse)

1. **BOUNDED-MODIFIER-RELEASE** — scan `_DriverDirConcat("modules/tap_holds")`. Collapse les 12 `Test()` de `test_hold_modifier_release_bounded.ahk` + `test_hold_layer_release_bounded.ahk` + `test_space_hold_*_guard.ahk`.
2. **SUSPEND-PREFIX-DRAIN** — collapse les 5 `Test()` de `test_suspend_watchdog_no_prefix_keywait.ahk`.
3. **FORWARD-DECLARED LOCALS / hs.task closure-capture** — collapse les **6** tests file-pinnés macOS (`test_forward_declare_regressions.lua`, `test_models_manager_mlx_task_forward_declared.lua`, `…ollama`, `menu_apps`, `menu_init_hk_box`, `karabiner/onboarding`).
4. **PORT/ADAPTER + SHARED-PURITY** — déjà `macos/tests/meta/test_port_adapter_coverage.lua` ; remplacer les baselines littérales (`hs.*≤956` `:243`, `io/os≤76` `:244`) par une valeur **auto-snapshotée**.
5. **REQUIRE_STATE GUARD** — **modèle-or** `macos/tests/meta/test_require_state_pattern.lua` (scan + allowlist décroissante) ; à imiter.
6. **HEADERS / BANNERS / NO-MAGIC / NO-DUP / LOGGER-PAIRING** — déjà collapsés ; étendre `test_logger_pairing` à `ui/` et le faire **échouer** sur START-avant-`Reload` (F-L08/L09).
7. **FEATURE-TOGGLE SSoT (à créer)** — analogue JS de `test_port_adapter_coverage.lua` (généralise `test:feature-read-sites`).

### Gabarit de message d'échec actionnable

```
not ok 7 - <comportement formulé comme assertion> (<replay-slug>) — expected: <X>, actual: <Y> [fichier.ext:LIGNE]
#   replay: <commande mono-test utilisant le slug>
```

Exemple réel (AHK le produit déjà : `test_framework.ahk:348` détail, `:359-360` replay) :

```
not ok 7 - tap-holds: LAlt backspace hold-modifier release is bounded (hold-modifier-unbounded-keywait) — expected: <true>, actual: <false> [test_hold_modifier_release_bounded.ahk:104]
#   replay: AutoHotkey64.exe tests\run_all.ahk --only "hold-modifier-unbounded-keywait"
```

**Nommage (nom = comportement, pas fichier)** : phrase-assertion sur un comportement observable + slug kebab-case unique repo-wide (handle de `--only`). macOS/Linux : ajouter `--only <substr>` + ligne `#   replay:` par FAIL.

### « Un déplacement ne casse aucun test » — la garantie

1. Behavior tests chargent par `require()`/`#Include` → immunisés au layout.
2. Méta-tests scannent via les concaténateurs whole-tree (`test_framework.ahk:157/218`, clé sur le **nom de fonction**) ; côté macOS remplacer `io.open(driver_root() .. "x.lua")` par `list_files(racine)` récursif clé sur le symbole.
3. Couverture port/adapter clé sur le mapping fichier→spec.
4. Preuve institutionnalisée : méta-test P9.2 (`git mv` à blanc, compte de tests inchangé).

### Métrique de réussite (ratchet)

| Métrique | Aujourd'hui | Cible |
|---|---|---|
| `introspection_ratio` = (# fichiers test scannant la source) / total | AHK 0,836 · macOS 0,637 | **≤ 0,25** chaque driver |
| `path_pinned_ratio` = (# tests épinglant un `driver_root() .. "x"` / `FileRead` mono-fichier, hors whole-tree + allowlist) | macOS 128 | **→ 0** |

CI gate **monotone** (échoue si ça monte), comme le ratchet `hs.*`.

---

## Defaults & SSoT

> **Consommation unique** : un défaut partagé est **lu** (codegen / TOML / JSON fail-fast),
> **jamais re-déclaré**. Tout fallback `if x == nil then x = …` viole §5.4 → fail-fast.
> Un drift test compare le défaut consommé à la SSoT → la dup redevient **impossible**.

### Inventaire → décision (exhaustif)

| St | # | Default · sites | Décision | feat | Drift test |
|----|---|-----------------|----------|------|------------|
| ✅ | 1 | Updater owner/repo · `core.ahk:19-20`,`updater.lua:14-15`,`constants.toml:7` (**mort**) | `shared_defaults` | non | ✅ `defaults.json` + drift gate `test-updater-constants-single-source.cjs` (P10.1) |
| ✅ | 2 | 12 presets · `core.ahk:71-84`,`updater.lua:38-51`,`constants.toml:23-69` | `shared_defaults` | non | ✅ Presets restent driver-specific (identiques, parseursToml complexes) ; drift guard sur owner/repo/timing couvre l'essentiel (P10.1) |
| ✅ | 3 | interval 86400 + boot 30 · `core.ahk:30`,`updater.lua:19-20`,`constants.toml:17,19` | `shared_defaults` | non | ✅ `defaults.json timing.*` + `test-updater-constants-single-source.cjs` vérifie `UPDATER_DEFAULT_INTERVAL` (P10.1) |
| ✅ | 4 | noms d'asset `.exe`/`.app.zip` · `updater.lua:16`,`constants.toml:12-13` | `driver_specific` | non | ✅ `constants.toml` supprimé (mort). Noms restent driver-specific — pas de drift avec un seul driver par plateforme (P10.1) |
| ✅ | 5 | semver + **fallback divergent** · `version.js:89-111`,`core.ahk:270-337`,`updater.lua:69-133` | `driver_specific` + gate | **oui** | ✅ fail-closed partout + `version_vectors.json` 3-driver gate (P10.4) |
| ✅ | 6 | stop-tokens (**drift MLX**) · `api_ollama.ahk:111-112`,`api_ollama.lua:280-281`,`api_mlx_inference.lua:104-105` | `shared_defaults` | non/M4 | ✅ `inference.json stop_sequences` + `test-llm-stop-sequences-single-source.cjs` (P10.2) |
| ☐ | 7 | `chatgpt_url` macOS · `bindings.lua:36`↔`manifest.toml:1048` | `manifest` | non | `test_shortcuts_chatgpt_url_from_manifest` |
| ☐ | 8 | `gpt.link` AHK · `gestures/init.ahk:604`↔`manifest.toml:1061` | `manifest` | non | `test_gpt_link_single_source` |
| ☐ | 9 | modèle `Qwen3.5-0.8B` ×3 · `llm_defaults.ahk:37`,`models.ahk:221`,`menu_llm/actions.ahk:436` | `driver_specific` (1 source) | non | `test_llm_model_default_single_source` |
| — | 10-11 | macOS `STAR_TRIGGER` 2.0 / `llm_prediction` 20.0 / per-group delays · `keymap/init.lua:52-58` | `driver_specific` (mono-sité, filet) | non | aucun requis (valeurs live = TOML catégorie) |

✅ **Vérifiés-clean (NE PAS toucher, modèles à copier)** : `_shared/modules/hotstrings/defaults.toml` (drift-gated), `_shared/tap_hold/defaults.toml` (fail-fast `karabiner/defaults.lua:54-73`), `_shared/modules/llm/defaults.json` (21 défauts), `_shared/modules/tooltip/tint.js` (parity-gated). Tables `DEFAULT_STATE` macOS lisent déjà via `Manifest.default_for`/`feat_enabled`.

### Mécanisme & preuve

`manifest.toml` **OU** `_shared/.../<defaults>.toml|json` **OU** `driver_specific` justifié. Rapatrier un défaut pouvant **déjà diverger** (semver #5, stop-tokens MLX #6) exige une **preuve d'équivalence byte**, sinon c'est un `feat`.

---

## Décisions maintainer requises

> Arbitrages à fort blast radius — **proposés, chiffrés ; non tranchés seul**.

| St | # | Décision | Options · Reco · Risque |
|----|---|----------|-------------------------|
| ☐ | **M1** | `lib/` foldérisé (Win) vs plat (macOS) | (a) Win→plat (b) macOS→folder (c) statu quo+doc. **Reco (c)** (l'ordre `#Include`/`#InputLevel` porte des invariants). **Élevé** |
| ☐ | **M2** | Frontière `keymap`/`llm` (`llm_bridge` sous `modules/llm` Win vs `modules/keymap` macOS) | aligner le parent. **Reco : différer** (couple M1). **Élevé** |
| ✅ | **M3** | D-1 fallback semver (lexico vs fail-closed, **déjà divergent**) | ✅ **tranché : fail-closed partout** (P10.4) — JS + AHK alignés sur macOS, parity gate à vecteurs partagés en place. |
| ☐ | **M4** | D-3 sous-ensemble MLX des stop-tokens (drop voulu ?) | unifier vs clé `mlx` distincte. **Reco : clé distincte** si drop voulu. **Faible** |
| ☐ | **M5** | Splits parité 1:1 (`keylogger_walker.ahk`↔`aggregator.lua`) | splitter **ensemble** ou laisser. **Reco : laisser** sauf besoin testabilité. **Élevé** |
| ☐ | **M6** | Adapters OS-helpers Windows (`shell_runner/toml_cache/json_codec`) | ajouter (symétrie/SOLID-I) vs accepter l'asymétrie. **Reco : ajouter `shell_runner`**, différer le reste. **Moyen** |
| ☐ | **M7** | Codec TOML + parser LLM AHK (transpile vs corpus) | **déjà tranché net-négatif** (transpile rejeté) — *confirmer*. **Élevé si rouvert** |
| ☐ | **M8** | `linux/` (même passe ou suivi séparé) | **Reco : LIN-1 maintenant, reste séparé**. **Moyen (reload Linux)** |

> **NE PAS rouvrir** (déjà tranché) : manifeste = SSoT ; `adapters/` = isolation OS (sortir
> json_codec/shell_runner/toml_cache **casse le ratchet de pureté**,
> [PROJECT_MEMORY](PROJECT_MEMORY.md) `project_hs_purity_ratchet_counts_comments`) ; menu =
> `menu_manifest.json` + drift-gate ; orphelins `_generated/registry.ahk`/`expander.ahk`
> supprimés ; `lib/app_state.ahk` + `ui/download_window` gardés (ancres de test / vivants).

---

## Risques & foot-guns

- **Encodage AHK (silencieux, mortel).** `.ahk` = **UTF-8 BOM + CRLF** ou abort mi-fichier sans erreur. Éditer via Edit, **jamais `cat >>`** ; tests **ASCII-only**, glyphes via `Chr(0xNNNN)` ; `test:ahk-encoding` après tout `.ahk`.
- **Ordre `#Include` / `#InputLevel`.** Porte des invariants (hoisting globals, `#InputLevel 2`). Split **en place** (un `#Include` à la ligne exacte) ; vérifier la séquence de boot au reload.
- **Ratchet `hs.*` compte les commentaires.** Router via adapter + mentionner l'adapter ; ne pas affaiblir le baseline (auto-snapshot).
- **`run_all.ahk` auto-découverte.** Changer l'ordre peut révéler des dépendances inter-tests → stager derrière `test-ahk-test-coverage.cjs`.
- **tap_hold partagé = paradigmes différents** (per-key AHK vs matrice Karabiner) → toute extension = `feat` si non byte-identique.
- **Churn du généré** → commit dédié ; jamais éditer `_generated/` à la main.
- **Splits hot-path** (F8, engine hotstrings, prediction) → mesurer avant/après (profilers).
- **`hs.task`/timer callbacks avalent les throws** → encoder la cause racine (pas un grep de présence, false-green).
- **macOS eventtap : aucun blocage** synchrone (sinon `kCGEventTapDisabledByTimeout`) → différer `hs.timer.doAfter(0)`.
- **Pas de merge `dev`/`main` sans test live ; pas de push sans demande ; pas de `Co-Authored-By`.**

---

## Definition of Done (du guide)

- [x] Chaque reco adossée à un `path:line` ou un chiffre reproductible.
- [x] Chaque étape : objectif, action, **test associé**, vérif, diagnostic, blast radius — et une **case St** pour le suivi.
- [x] **Priorité n°1 (testabilité)** = section dédiée §6 + métrique cible + plan des ~565 tests introspection.
- [x] Inventaire **defaults** exhaustif (§7) + décision + drift test par entrée.
- [x] Table de **symétrie** + divergences + sens de convergence / décision maintainer (§8).
- [x] **Tous les gros fichiers** > seuil ont un plan de split **miroir** (P11).
- [x] **Document unique** : remplace REFACTOR_PLAN / TODO / AUDIT (supprimés) ; prolonge PROJECT_MEMORY / ADRs.
- [x] **Track A** = comportement préservé ; **Track B** = `fix`/`feat` explicites, chacun avec son test.
- [x] Arbitrages irréversibles en **« Décisions maintainer »** (M1-M8).
- [x] Incrémental, vérifiable, réversible ; ordre du moins (P8) au plus risqué (Track B).

> **Quand un test casse plus tard, le dev lit :** le **nom** (= comportement), le message
> **expected/actual**, le **`path:line`**, et la **commande de replay** — et corrige à
> l'endroit que la carte test→source désigne, en **< 5 min**.
