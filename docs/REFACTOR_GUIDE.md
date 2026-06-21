# ErgoptiPlus — Guide de refactor (lisible · SOLID · 100 % testable)

> **Statut.** Ce guide **prolonge** [docs/REFACTOR_PLAN.md](REFACTOR_PLAN.md) (phases
> P0→P7) et s'appuie sur [docs/PROJECT_MEMORY.md](PROJECT_MEMORY.md) et les
> [ADR 001-007](../static/ergopti_plus/docs/adr/). Il ne le contredit pas : il chiffre
> l'état réel, raffine les priorités, et détaille la **priorité n°1 — rendre un test
> rouge diagnosticable en < 5 min** — qui n'était pas encore traitée.
>
> **Toutes les affirmations sont adossées à un `path:line` ou une commande
> reproductible.** Les chiffres ont été mesurés le 2026-06-21 puis re-vérifiés par une passe
> de cross-check adverse multi-agents (8 vérificateurs indépendants) ; les écarts trouvés
> (FileRead AHK 152→36, adapters macOS 20→23, citation `run.lua:186`→`helpers/init.lua:237`,
> plage `hotstrings.ahk`, comptes d'assertions) ont été corrigés. **Aucune étape ne change le comportement** sauf celles
> explicitement marquées `feat`/`fix`.
>
> ⚠️ **Foot-gun de mesure** : `git grep` / `grep` POSIX renvoie **0** sur les fichiers
> `.ahk` (UTF-16/BOM + CRLF). Tout comptage AHK doit se faire avec **ripgrep**
> (l'outil `Grep`) sinon on conclut à tort « 0 occurrence ». Voir
> [§8 Risques](#8-risques--foot-guns).

---

## 1. TL;DR

Par impact décroissant (gain entre parenthèses) :

1. **Diagnostic d'échec — priorité absolue.** **344 / 411** tests AHK
   (`windows/tests/test_*.ahk`) scannent le *source* ; côté macOS **32** meta-tests
   font pareil. À rouge ils disent *« texte X absent du fichier Y »*, **jamais**
   *« le comportement Z est cassé »*. (→ *diagnostic d'échec*, [§5](#5-chantier-testabilité-transversal--priorité-1)).
2. **~141 tests AHK sont *location-pinned*** (FileRead d'un chemin source codé en dur)
   et **cassent à chaque déplacement de fichier** — alors que **3 helpers
   move-resilient existent déjà** dans le framework. Migration mécanique. (→ *refactor débloqué*).
3. **Ergonomie d'échec inégale.** Barème mesuré : **JS A-** (`run-js-suite.cjs`
   imprime `reproduce:` + tail), **AHK C** (le `path:line` pointe le helper, pas le
   test ; 0 replay par test), **macOS/Linux B-**. Hisser AHK/Lua au niveau JS. (→ *diagnostic*).
4. **DIP asymétrique = le gain max / risque min.** macOS a un *ratchet de pureté OS*
   (917/950 `hs.*`, **70/70 `io.open` — ZÉRO marge**) ; **AHK n'en a aucun** →
   117 `DllCall` + 36 `FileRead` hors `adapters/` non gardés. Ajouter le ratchet AHK
   (baseline = comptes actuels) est *test-only, blast faible*. (→ *zéro dérive*).
5. **Defaults : l'infra `_shared/` existe déjà et marche** (timings, hotstrings, llm,
   wpm, tooltip). Restent **~5 poches** de duplication / fallback §5.4 : WPM HS
   **15** `or <litt>`, LLM **27** `tonumber(x) or <litt>`, `DELAYS_DEFAULT`↔
   `DYN_HOTSTRINGS_DEFAULT_DELAY`, `language 'fr'` ×4, `max_tokens` divergent. (→ *zéro dup*).
6. **Gros fichiers : 116 fichiers > 400 l.** (57 AHK + 59 Lua). Splits **miroir** via
   le pipeline déjà prouvé. En tête : `gestures.ahk` (2076 l., risque `#InputLevel`)
   et le couple keylogger central (1867 ↔ 1609). (→ *lisibilité, SRP*).
7. **La plupart des « divergences UI » sont superficielles.** 5 frontends webview sont
   **déjà 1:1 dans `_shared/ui/`** ; seul le contrôleur per-OS diffère → renommages
   `flat → ui/<window>/init` = **les wins de symétrie les moins chers**. (→ *symétrie*).
8. **Open/Closed : `hotstrings.ahk` = 96 sites `Features[` + 34 `if`-blocks
   hand-maintained.** Ajouter un groupe = éditer ce fichier au lieu du seul manifeste.
   → boucle data-driven (le macOS le fait déjà). (→ *SOLID-O*).
9. **Liskov : 11 / 20 ports n'ont aucun test de contrat *comportemental*** sur aucun
   driver ; les vecteurs des 9 autres sont *hand-mirrored* depuis le JS et peuvent
   dériver. → dériver du `*.spec.js`. (→ *correction cross-driver*).
10. **Symétrie structurelle à fort blast radius = décisions maintainer**, pas
    décidées seul : `keymap` location, `lib/` foldé (Win) vs plat (macOS), placement
    menu LLM, **accessor fail-fast des 294 sites `Features[`** (reporté en P4),
    **`tap_hold` non unifiable** (modèles divergents → `feat`). (→ [§7](#7-décisions-maintainer-requises)).
11. **Réutiliser, ne pas réinventer.** Le pipeline d'extraction AHK (PowerShell
    in-place + `#Include` + `_DriverDirConcat`) est éprouvé sur 4 splits ; le harnais
    de vérif est établi ([REFACTOR_PLAN.md:19-27](REFACTOR_PLAN.md#L19)). Chaque étape s'y branche.

---

## 2. État des lieux (mesuré)

### 2.1 Architecture de test — le problème n°1 (chiffré)

Bucketisation des **411** `windows/tests/test_*.ahk` (commandes reproductibles) :

| Bucket | Fichiers | Que dit l'échec ? | Commande |
|---|---|---|---|
| **Comportement / contrat** (aucun primitive d'introspection) | **67** | ✅ comportement attendu vs obtenu | `grep -LE '_DriverSourceConcat\|_DriverFuncBody\|_DriverDirConcat\|FileRead' $(find …/tests -name 'test_*.ahk')` |
| **Scan-source *move-resilient*** (`_Driver*` helpers) | **189** (168 `_DriverFuncBody`, 28 `_DriverSourceConcat`, 14 `_DriverDirConcat`) | ⚠️ « le *texte* de la fonction n'a pas X » | `grep -lE '_DriverSourceConcat\|_DriverFuncBody\|_DriverDirConcat' …` |
| **`FileRead` *location-pinned* de source** | **~141** (sur 155 fichiers `FileRead`-sans-helper ; ~11-13 lisent des fixtures, légitime) | ❌ « *fichier.ahk* must be readable » (erreur de **chemin** sur déplacement) | helper `_XXX_ReadSource(rel)` répliqué par fichier |
| **Union introspection** | **344 / 411 (84 %)** | — | `grep -lE '_DriverSourceConcat\|_DriverFuncBody\|_DriverDirConcat\|FileRead' … \| wc -l` |

- Helpers move-resilient **déjà fournis** :
  [`test_framework.ahk:151`](../static/ergopti_plus/windows/tests/test_framework.ahk#L151)
  (`_DriverSourceConcat`), `:171` (`_DriverFuncBody`), `:212` (`_DriverDirConcat`).
- L'arbre AHK est **plat** : `find windows/tests -type d` ⇒ `{tests, tests/meta, tests/e2e}`
  uniquement ; **0** mirror `tests/unit/modules/<feature>/`. À l'inverse macOS **mirroir
  exact** : [`macos/tests/unit/modules/gestures/test_conflicts.lua`](../static/ergopti_plus/macos/tests/unit/modules/gestures/test_conflicts.lua) ↔ `modules/gestures/conflicts.lua`.
- macOS porte **aussi** l'anti-pattern : **32** meta-tests `io.open`/`io.read`/`io.lines`
  de source (ex. [`test_gestures_ghost_timer_guard.lua:25`](../static/ergopti_plus/macos/tests/meta/test_gestures_ghost_timer_guard.lua#L25) lit un chemin fixe `modules/gestures/init.lua` et `:match` du texte).

**Échantillon de messages d'échec réels** (aucun ne pointe le comportement) :

| Test | Message à rouge | Pointe vers |
|---|---|---|
| [`test_activate_hotstrings_sleep_gate.ahk:82`](../static/ergopti_plus/windows/tests/meta/test_activate_hotstrings_sleep_gate.ahk#L82) | « the HSE_Buffer gate must precede the space poke… » | ordre de *texte* |
| [`test_av_focus_mode_dead_code.ahk:76`](../static/ergopti_plus/windows/tests/meta/test_av_focus_mode_dead_code.ahk#L76) | « KL_AV_SlowTick must NOT call KL_AV_PollFocusMode… » | *absence* de texte |
| [`test_native_hotstrings_migrated.ahk:41`](../static/ergopti_plus/windows/tests/meta/test_native_hotstrings_migrated.ahk#L41) | « hotstring_engine_main.ahk must be readable » | erreur **I/O** sur déplacement |

### 2.2 Ergonomie d'échec — barème par couche

| Couche | Attendu vs obtenu ? | Indice `path:line` ? | Replay d'un seul test ? | Note |
|---|---|---|---|---|
| **JS** (`tools/test`) | ✅ par check, + tail ([`run-js-suite.cjs:71`](../tools/test/run-js-suite.cjs#L71)) | implicite (stack si throw) | ✅ `reproduce:` ([`run-js-suite.cjs:70`](../tools/test/run-js-suite.cjs#L70)) | **A-** (la barre) |
| **macOS** (`macos/tests`) | partiel — `assert_eq` oui, `assert_true` nu → « expected truthy » ([`helpers/init.lua:236`](../static/ergopti_plus/macos/tests/helpers/init.lua#L236)) ; **~530** sites nus (estim.) | ✅ `error(msg,2)` → site du test ([`helpers/init.lua:237`](../static/ergopti_plus/macos/tests/helpers/init.lua#L237)) | ❌ aucun filtre CLI | **B-** |
| **Linux** (`linux/tests`) | partiel (`assert_true` nu [`helpers.lua:87`](../static/ergopti_plus/linux/tests/helpers.lua#L87)) | ✅ `error(msg,2)` | ❌ aucun filtre | **B-** |
| **AHK** (`windows/tests`) | partiel — `AssertEqual/True/False/Contains` rendent les valeurs ([`test_framework.ahk:88`](../static/ergopti_plus/windows/tests/test_framework.ahk#L88)) ; `Assert()`/`AssertThrows()` **sans valeur** ; **2008** sites `Assert(` (mesuré) + **598** `AssertTrue(` | ⚠️ mal placé — `[e.File:e.Line]` pointe la **ligne du helper** dans `test_framework.ahk:290`, pas le test | ❌ `run_all.ahk` ne lit que `--dry-run` ([`:29`](../static/ergopti_plus/windows/tests/run_all.ahk#L29)) | **C** |

**La barre existe déjà** : [`run-js-suite.cjs:67-74`](../tools/test/run-js-suite.cjs#L67) imprime, par
check rouge, (a) le nom, (b) `reproduce: <cmd exact>`, (c) les 12 dernières lignes de
sortie. C'est le gabarit à généraliser.

### 2.3 Defaults hors manifeste — inventaire

L'infra `_shared/modules/*/` **existe déjà** et est **lue** par les deux drivers (à ne
PAS re-proposer) : `timings/constants.toml` (101 read-sites/30 fichiers via
`TimingsGet`/`Timings.ms`), `hotstrings/defaults.toml`, `llm/defaults.json` +
`inference.json`, `wpm_widget/constants.toml`, `tooltip/constants.toml`. Restent :

| Défaut | Win | macOS | Sites | Devrait vivre | Risque divergence |
|---|---|---|---|---|---|
| WPM widget visuels | fail-fast sentinelle ([`ui/wpm_widget.ahk:48`](../static/ergopti_plus/windows/ui/wpm_widget.ahk#L48)) | **15× `or <litt>`** §5.4 ([`ui/wpm/wpm_widget.lua:117`](../static/ergopti_plus/macos/ui/wpm/wpm_widget.lua#L117)) | 15 | `_shared/.../wpm_widget/constants.toml` (déjà SSoT) | aucune (valeurs égales) — **fix §5.4** |
| LLM temperature 0.1 / max_tokens 50 | lit `defaults.json` | **27× `tonumber(x) or <litt>`** ([`modules/llm/api_common.lua:142`](../static/ergopti_plus/macos/modules/llm/api_common.lua#L142), `api_mlx.lua:1098,1301`) | 27 | `defaults.json` / `inference.json` | temperature égale (refactor) ; **max_tokens divergent** |
| `max_tokens` cap | ollama **150** ([`api_ollama.ahk:345`](../static/ergopti_plus/windows/modules/llm/api_ollama.ahk#L345)), remote **256** ([`api_remote.ahk:65`](../static/ergopti_plus/windows/modules/llm/api_remote.ahk#L65)) | mlx **50** ([`api_mlx.lua:1098`](../static/ergopti_plus/macos/modules/llm/api_mlx.lua#L1098)) | — | `inference.json` (par backend) | **DIVERGENT → `feat`** (3 valeurs) |
| Délais d'expansion par catégorie | `DYN_HOTSTRINGS_DEFAULT_DELAY:=2.0` ([`hotstrings_config.ahk:51`](../static/ergopti_plus/windows/lib/hotstrings/hotstrings_config.ahk#L51), commentaire « Mirrors the macOS DELAYS_DEFAULT ») | `DELAYS_DEFAULT` ([`keymap/init.lua:51`](../static/ergopti_plus/macos/modules/keymap/init.lua#L51)) | 2+ | `_shared/.../hotstrings/defaults.toml [delays]` | **égal** (2.0/2.0/20.0) → refactor après diff |
| `language 'fr'` (prompt LLM) | `prediction_engine.ahk:45`, `_generated/prompt_builder.ahk:206` | `profiles.lua:199` | ≥4 | manifeste `script.locale` (déjà défini) | aucune — refactor |
| `tap_hold` seuils | par-clé 0.20-0.35 s ([`data/tap_hold/defaults.toml:38`](../static/ergopti_plus/windows/data/tap_hold/defaults.toml#L38)) | global 1000 ms ([`karabiner/defaults.lua:14`](../static/ergopti_plus/macos/modules/karabiner/defaults.lua#L14)) | — | **rester driver-specific** | **MODÈLES divergents → `feat`** |
| Gesture sensitivity 3.5 | (gestures = macOS only) | `gestures/init.lua:106` | 1 | macOS-local (légitime) | aucune |

Le garde existant [`test_no_duplicate_defaults.lua`](../static/ergopti_plus/macos/tests/meta/test_no_duplicate_defaults.lua#L42)
**ne voit que le Lua macOS** et ne fait que `WARN` → aucune des dup ci-dessus n'est
attrapée en CI.

### 2.4 Gros fichiers — 116 > 400 l. (57 AHK + 59 Lua)

`find static/ergopti_plus/{windows,macos} -name '*.ahk' -o -name '*.lua' | grep -vE '/tests?/|/_generated/|/vendor/' | xargs wc -l | awk '$1>400'` ⇒ 116. Top + statut miroir :

| # | Fichier (`static/ergopti_plus/`) | L. | Statut miroir |
|---|---|---|---|
| 1 | `windows/modules/gestures.ahk` | 2076 | macOS `modules/gestures/` **déjà splitté** → AHK rattrape. **HIGH-RISK** (`#InputLevel 2`) |
| 2 | `windows/modules/keylogger/keylogger.ahk` | 1867 | parallèle de `macos/.../keylogger/init.lua` (1609) — splitter **ensemble** |
| 3 | `macos/modules/llm/api_mlx.lua` | 1799 | **macOS-only** (MLX = Apple Silicon) → split unilatéral |
| 4 | `macos/ui/menu/menu_llm/models_manager_mlx.lua` | 1790 | macOS-only ; corps = 1 closure `M.new()` (extraction par dépendance) |
| 5 | `macos/ui/menu/menu_keyboard_layout.lua` | 1647 | macOS-only (TIS) ; Win `menu_layout.ahk` = stub 41 l. |
| 6 | `macos/modules/keylogger/init.lua` | 1609 | parallèle de #2 |
| 7 | `windows/lib/hotstrings/hotstring_engine_main.ahk` | 1509 | déjà 2-way (`engine.ahk` 936 + `_main`) ; macOS `dynamic_hotstrings/` = 989 l. (non 1:1) |
| 8 | `windows/modules/llm/api_ollama.ahk` | 1467 | macOS `api_ollama.lua` 824 (parité lâche) |
| 9 | `windows/lib/hotstrings/hotstrings_config_window.ahk` | 1428 | macOS `ui/hotstrings_config_window/` **déjà folder** → AHK rattrape (+ `lib/`→`ui/`) |
| 10 | `windows/lib/hotstrings/hotstring_prefix_watcher.ahk` | 1328 | AHK-spécifique |
| … | (+ 106 fichiers 400-1309 l.) | | `windows/ui/wpm_widget.ahk` 1266 (macOS `ui/wpm/` folder), `macos/lib/healthcheck.lua` 1112 (Win `ui/healthcheck/` folder), … |

Invariants porteurs (ne pas casser, [§8](#8-risques--foot-guns)) : `gestures.ahk` hotkeys
top-level `^#+F1::..^#+F10::` ([`:1805`](../static/ergopti_plus/windows/modules/gestures.ahk#L1805)) dépendants de `#InputLevel 2`
(non exercés headless) ; `keylogger.ahk` doit rester **1er** `#Include` keylogger
([`ErgoptiPlus.ahk:242`](../static/ergopti_plus/windows/ErgoptiPlus.ahk#L242)) ; `hotstring_engine_main.ahk` partage des globals avec
`hotstring_engine.ahk` (adjacence `ErgoptiPlus.ahk:183-184`).

### 2.5 SOLID & couplage — chiffres clés

| Mesure | Valeur | Source |
|---|---|---|
| Sites `Features[` **production** AHK (ripgrep) | **294 / 29 fichiers** (pire : `hotstrings.ahk`=96, `altgr.ahk`=23, `path_translator.ahk`=23, `win.ahk`=20) | `Grep 'Features\['` (exclut tests) — confirme [REFACTOR_PLAN.md:74](REFACTOR_PLAN.md#L74) |
| `if`-blocks `Features[…]{LoadHotstringsSection}` hand-maintained | 34 dans [`hotstrings.ahk:66-1002`](../static/ergopti_plus/windows/modules/hotstrings.ahk#L66) | violation **O** |
| Ports avec test de contrat **comportemental** | **9 / 20** (macOS), ~8/20 (AHK) ; **11 ports = 0** (Crypto, KeyState, MouseControl, GraphicsRenderer, WindowManager, NetworkInfo, Clipboard, Storage, ProcessLifecycle, AppLauncher, SecureFieldDetector) | [`test_adapter_contract_vectors.lua:34`](../static/ergopti_plus/macos/tests/unit/test_adapter_contract_vectors.lua#L34) |
| Ratchet OS macOS `hs.*` (hors `adapters/`) | **917 / 950** (33 de marge) | [`test_port_adapter_coverage.lua:243`](../static/ergopti_plus/macos/tests/meta/test_port_adapter_coverage.lua#L243) |
| Ratchet OS macOS `io.open`/`os.execute` | **70 / 70 — ZÉRO marge** | idem `:244` |
| OS direct AHK **hors `adapters/`, NON gardé** | **117 `DllCall` + 21 COM + 36 `FileRead`** | `windows/{modules,lib}` ; le garde AHK ne scanne que `_shared/` JS ([`test_port_adapter_coverage.ahk:222`](../static/ergopti_plus/windows/tests/meta/test_port_adapter_coverage.ahk#L222)) |
| Fonctions-dieu (SRP) | `handle_key()` ~390 l. ([`keylogger/init.lua:448`](../static/ergopti_plus/macos/modules/keylogger/init.lua#L448)), `onKeyDownRaw()` ~290 l. ([`keymap/init.lua:592`](../static/ergopti_plus/macos/modules/keymap/init.lua#L592)) | |
| Fallback `if x == nil then x =` (macOS modules+lib) | 2 ([`api_common.lua:104`](../static/ergopti_plus/macos/modules/llm/api_common.lua#L104) `=300`, `gestures/init.lua:375`) | violation §5.4 |

**Contredit une hypothèse du prompt** : les 3 drivers implémentent **les 20 ports** (Win 20,
Linux 20, **macOS 23 fichiers = 20 ports + 3 adapters helpers OS** `json_codec/shell_runner/toml_cache`) ;
macOS `mouse_control/graphics_renderer/window_manager/crypto/network_info/key_state` sont de
**vraies** implémentations. Le trou Liskov n'est pas « adapters manquants » mais
« 11 ports sans vecteurs ». La doc [`architecture.md:100`](../static/ergopti_plus/docs/architecture.md#L100) est **périmée** (n'y dessine que 13 ports HS) → à régénérer.

### 2.6 Linux — driver partiel (état)

`linux/` = **4303 l.** prod, **20 adapters** (parité 1:1 macOS par nom de fichier),
`modules/{hotstrings,keylogger}`, `bin/`, `tests/`. **Pas** de `lib/`, `ui/`, `data/`,
`_generated/`. **0 site `Features[`** (`Grep 'Features\['` linux/ ⇒ aucun) → **pas de
surface de crash brute** (répond à la décision maintainer #6). Ne **pas** forcer le
miroir complet : son absence de `ui/`/`_generated/` est par conception (pas de GUI, pas
encore consommateur du codegen).

---

## 3. Architecture cible

### 3.1 Structure miroir 1:1 (reprise/raffinée de [REFACTOR_PLAN.md:31-44](REFACTOR_PLAN.md#L31))

| Concept | `windows/` | `macos/` | Note |
|---|---|---|---|
| Entrée | `ErgoptiPlus.ahk` (manifeste d'`#Include` + boot) | `init.lua` (idem) | déjà minci (P4 : 2397→1189) |
| Adapters | `adapters/` (20 ports **+ helpers OS**) | idem | **isolation OS**, pas « 20 pile » ([REFACTOR_PLAN.md:96](REFACTOR_PLAN.md#L96)) |
| Infra/domaine | `lib/` (aucun UI) | `lib/` | macOS `healthcheck.lua` à sortir de `lib/` |
| Features | `modules/<feature>/` | `modules/<feature>/` | |
| Fenêtres UI | `ui/<window>/init.*` | `ui/<window>/init.lua` | frontends webview **partagés** dans `_shared/ui/` |
| Données | `data/` | `data/` | |
| Généré | `_generated/` | `_generated/` | **jamais édité main** |
| Tests | `tests/{unit,integration,e2e,…,meta}` | idem (déjà fait) | **AHK à mettre au niveau** |

### 3.2 Trajet d'une feature (point d'extension unique — principe O)

```
manifest.toml  ──build:manifest──▶  _generated/features_manifest.{ahk,lua}
   (SSoT toggle)                         │
                                         ▼
            driver lit Features[...]  ◀── (cible : accessor fail-fast, P4)
                                         │
   _shared/modules/<f>/defaults.toml ───▶ DEFAULT_STATE / consts (lecture, jamais re-déclaré)
                                         │
                              adapters/<port>.<ext>  (tout appel OS)
                                         │
   _shared/core/{domain,ports}/*.spec.js ─▶ vecteurs ─▶ test behavior + contrat (rouge=CI, pas clavier)
```

Ajouter une feature/un défaut = **éditer `manifest.toml` (ou un `defaults.toml`
cousin) + `npm run codegen`**, jamais patcher N call-sites. Le **drift gate**
(`npm run build:domain`) échoue si le généré n'est pas resync.

### 3.3 Carte test → source (modèle = macOS, déjà en place)

`tests/unit/modules/<feature>/test_<unit>.<ext>` ↔ `modules/<feature>/<unit>.<ext>`.
macOS le respecte ([`tests/unit/modules/gestures/`](../static/ergopti_plus/macos/tests/unit/modules/gestures/) ↔ `modules/gestures/`). **AHK
doit l'adopter** (aujourd'hui plat). Depuis un rouge, le module fautif devient
trouvable **par le chemin du test**.

---

## 4. Plan priorisé par phases

Ordonné **du moins au plus risqué**, en **4 tiers**. Chaque étape référence la phase
[REFACTOR_PLAN.md](REFACTOR_PLAN.md) qu'elle prolonge. Format compact : **Obj · SOLID/douleur ·
Preuve · Action · Test · Vérif · Diagnostic d'échec · Rollback · Blast.**

### Tier 0 — Zéro code (doc + mesure), blast **nul**

**T0.1 — Corriger les docs fausses** *(prolonge P0)*
- **Obj** : aligner la doc sur le code réel. **Preuve** : `architecture.md:100` ne dessine
  que 13 ports HS (les 20 existent) ; [`adr/002`](../static/ergopti_plus/docs/adr/002-codegen-manifest.md) + `SCHEMA.md:185` prétendent que macOS rend
  `windows/data/tap_hold/defaults.toml` — **faux** (le générateur Karabiner lit
  `karabiner/data/*.json` + `defaults.lua`) ; `REFACTOR_PLAN.md:38` dit « adapters/ 20
  exactement » mais `:96` corrige « isolation OS » (utiliser `:96`) ; `macos/tests/README.md`
  cite l'ancien chemin `static/drivers/hammerspoon`.
- **Action** : `npm run gen:diagram` (régénère `architecture.md`) ; corriger les 3 proses.
- **Test** : `test:diagram`/lecture ; pas de régression. **Vérif** : `npm run test:js`.
- **Diagnostic d'échec** : N/A (doc). **Rollback** : revert. **Blast** : nul.

**T0.2 — Re-confirmer la baseline verte (geler la DoD)** *(prolonge P2)*
- **Obj** : pinner les compteurs avant tout déplacement. **Preuve** : [REFACTOR_PLAN.md:19](REFACTOR_PLAN.md#L19)
  cite une baseline mais elle n'a pas été re-jouée.
- **Action/Vérif** : `AutoHotkey64 /ErrorStdOut run_all.ahk --dry-run` (exit 0), idem sans
  `--dry-run`, `lua macos/tests/run.lua`, `npm run test:js`, `npm run test:ahk-encoding`.
  Noter les counts exacts → ce sont les chiffres de la [§9 DoD](#9-definition-of-done).
- **Blast** : nul.

### Tier 1 — Low risk (test-only, fail-fast, renommages frontend-déjà-partagé)

**T1.1 — Ratchet de pureté OS côté AHK** *(NOUVEAU ; symétrise le garde macOS)* ⭐ *gain max / risque min*
- **Obj** : garder les appels OS hors `adapters/` côté AHK comme macOS le fait. **SOLID-D.**
- **Preuve** : 117 `DllCall` + 36 `FileRead` non gardés ; `test_port_adapter_coverage.ahk:222`
  ne scanne que `_shared/` JS.
- **Action** : étendre le test pour compter `DllCall|ComObject|FileRead` dans
  `windows/{modules,lib}` (hors `adapters/`), **baseline = comptes actuels** (pas 0 : §5.6
  interdit le code mort, mais un baseline figé + TODO-vers-le-bas est légitime).
- **Test** : `test_ahk_os_purity_ratchet.ahk` — rouge si on ajoute un `DllCall` hors adapter,
  vert au baseline (encode la cause : « nouvel appel OS non isolé »).
- **Vérif** : dry-run exit 0 + suite + `test:ahk-encoding`. **Diagnostic d'échec** : le message
  nomme le fichier+compte (« +1 DllCall hors adapters/ dans modules/X.ahk ») → le dev sait
  router via le port. **Rollback** : retirer le test. **Blast** : faible (test-only).

**T1.2 — Migrer les ~141 tests *location-pinned* vers les helpers move-resilient** *(prolonge le durcissement P4/P5)* ⭐
- **Obj** : qu'un déplacement de fichier **ne casse plus aucun test**. **Douleur n°2.**
- **Preuve** : ~141 `FileRead`-de-source via `_XXX_ReadSource(rel)` ; helpers déjà fournis
  `test_framework.ahk:151-219`.
- **Action** : remplacer `_XXX_ReadSource("modules/gestures.ahk")` → `_DriverSourceConcat()`
  ou `_DriverFuncBody("Fn")` (assertions inchangées). Mécanique, par lots.
- **Test** : les tests migrés eux-mêmes ; + un **meta-test unique** asserte « aucun
  `FileRead` d'un chemin source codé en dur dans `tests/` » (interdit la réintroduction).
- **Vérif** : dry-run + suite (count inchangé) + `test:ahk-encoding`. **Diagnostic d'échec** :
  si le meta-test casse → « FileRead source-pinné réintroduit dans test_X.ahk:L ».
  **Rollback** : par lot. **Blast** : moyen (réécriture par fichier, assertions identiques).

**T1.3 — Gabarit de message d'échec actionnable (AHK + Lua au niveau JS)** *(prolonge P2)* ⭐
- **Obj** : `path:line` du **test** + attendu/obtenu + **commande de replay** par test.
- **Preuve** : barème §2.2 ; `run-js-suite.cjs:67-74` = la barre ; `test_framework.ahk:290`
  pointe le helper ; `run_all.ahk:29` ignore tout filtre.
- **Action** : (a) AHK — les asserts remontent 1 frame (`e.Stack`, `run_all.ahk:55`) ;
  bannir `Assert()`/`AssertThrows()` nus ; ajouter `run_all.ahk --only <substr>` + ligne
  `replay:` par `not ok`. (b) macOS/Linux — `assert_true` rend l'actual ; `run.lua arg[1]`
  = filtre substring + ligne `replay:`.
- **Test** : `test_framework_failure_format.ahk` / `test_runner_replay.lua` — asserte qu'un
  échec simulé contient `expected:`, `actual:`, `at:`, `replay:`.
- **Gabarit mandaté** :
  ```
  not ok / FAIL  <test nommé par comportement, ex. "SFD_IsSecureApp returns 0 for unknown app">
      expected: <E>
      actual:   <A>
      at:       <test_file>:<line>
      replay:   AutoHotkey run_all.ahk --only "<name>"   |   lua tests/run.lua "<name>"
  ```
- **Vérif** : suites vertes, exit-code CI préservé. **Diagnostic d'échec** : méta. **Rollback** :
  additif. **Blast** : moyen (touche les runners partagés, couverts par leurs propres tests).

**T1.4 — Vecteurs de contrat dérivés des `*.spec.js` + 11 ports manquants** *(prolonge ADR-006)*
- **Obj** : un port mal implémenté **échoue en CI, pas au clavier**. **SOLID-L.**
- **Preuve** : 9/20 ports couverts ; vecteurs « hard-coded mirroring the JS source »
  ([`test_adapter_contract_vectors.lua:16`](../static/ergopti_plus/macos/tests/unit/test_adapter_contract_vectors.lua#L16)).
- **Action** : exposer `contractTestVectors()` dans chaque `_shared/core/ports/*.spec.js`
  comme **source exécutée** ; charger ces vecteurs côté Lua/AHK (loader mince) ; ajouter
  vecteurs pour Crypto/SecureFieldDetector/Clipboard d'abord.
- **Test** : les vecteurs partagés tournent sur **chaque** adapter (même corpus).
- **Vérif** : `test:hs` + suite AHK + `test:port-compliance`. **Diagnostic d'échec** : « adapter
  crypto.lua sha256 ≠ vecteur attendu » → comportement, pas structure. **Rollback** : test-only.
  **Blast** : moyen (aucun code prod).

**T1.5 — Renommer les contrôleurs webview `flat → ui/<window>/init`** *(prolonge P5 §131,133)* ⭐ *win le moins cher*
- **Obj** : symétrie de chemin pour 5 fenêtres. **Preuve** : `_shared/ui/` héberge déjà
  leurs assets web 1:1 (`index.html`+JS+`style.css` ; metrics_typing = JS modularisé en 10 fichiers)
  pour `changelog, download_window, metrics_apps, metrics_typing, model_browser`, résolus par les deux drivers
  ([`macos/ui/model_browser/init.lua:47`](../static/ergopti_plus/macos/ui/model_browser/init.lua#L47), [`windows/ui/changelog_window.ahk:399`](../static/ergopti_plus/windows/ui/changelog_window.ahk#L399)).
- **Action** : `windows/ui/changelog_window.ahk → ui/changelog/init.ahk`,
  `llm_model_browser.ahk → ui/model_browser/init.ahk` (le frontend ne bouge pas ; le path
  `file://` lit déjà `_SharedDir`).
- **Test** : migrer les meta-tests via `_DriverDirConcat("ui/changelog")` ; un test asserte
  que le path résolu **existe** (cf. foot-gun wpm_widget, [PROJECT_MEMORY.md:1549](PROJECT_MEMORY.md#L1549)).
- **Vérif** : dry-run + suite + `test:ahk-encoding` ; graphe d'`#Include` résout.
  **Diagnostic d'échec** : « ui/changelog/index.html introuvable au chargement ».
  **Rollback** : renommer en arrière. **Blast** : faible (frontend partagé, pas de hotkey).

**T1.6 — Defaults byte-équivalents → `_shared/` + drift test** *(prolonge P7, sous-étape low-risk)*
- **Obj** : zéro dup §5.2/§5.4. **Preuve** : §2.3.
- **Action** : (a) WPM HS — retirer les **15** `or <litt>`, fail-fast comme AHK ;
  (b) `language 'fr'` ×4 → lire `manifest script.locale` ; (c) `DELAYS_DEFAULT`↔
  `DYN_HOTSTRINGS_DEFAULT_DELAY` → `_shared/.../hotstrings/defaults.toml [delays]` **après
  diff byte** (valeurs 2.0/2.0/20.0 égales — pur refactor). **Exclure** `max_tokens` et
  `tap_hold` (→ Tier 3 / décisions).
- **Test** : `test_wpm_no_inline_fallback.lua` (rouge si un `or <litt>` revient) +
  **cross-driver drift test** (la valeur lue par AHK == celle lue par HS depuis la clé partagée).
- **Vérif** : `test:hs` + suite AHK + `test:no-fallbacks`. **Diagnostic d'échec** : « WPM HS
  width fallback réintroduit » / « delays_sec AHK≠HS ». **Rollback** : par item. **Blast** : faible.

### Tier 2 — Medium (splits miroir via le pipeline prouvé)

> **Pipeline réutilisé** ([REFACTOR_PLAN.md:108](REFACTOR_PLAN.md#L108)) : extraction PowerShell qui remplace le
> bloc **en place** par un `#Include` (garantit UTF-8 BOM+CRLF, préserve l'ordre boot et
> les `global X :=`) → `test:ahk-encoding` → dry-run exit 0 → suite → `_DriverDirConcat`
> pour les meta-tests. **Ne pas inventer un autre pipeline.**

**T2.1 — Split miroir du keylogger central (les deux drivers ensemble)** *(prolonge P5/P6)*
- **Obj** : SRP. **Preuve** : `keylogger.ahk` 1867 (16 sections, 0 `#Include`) ↔
  `keylogger/init.lua` 1609 (7 sections) — même forme « foldé mais central monolithe ».
- **Action** : AHK → `keylogger_storage/_sql/_hotpath/_secure_field.ahk` ; macOS → extraire
  `event_tap.lua` (§5, L440-837) + `watchers.lua` (§6). L'index garde l'état global
  `Keylogger`/`CoreState` et reste **1er** include (`ErgoptiPlus.ahk:242`).
- **Test** : tests behavior keylogger existants (filet d'équivalence) + 1 test pinnant
  l'ordre de dispatch de `handle_key`. **Vérif** : dry-run + suite + encoding + `test:hs`.
- **Diagnostic d'échec** : tests keylogger behavior rouges = comportement de capture cassé.
  **Rollback** : ré-inline. **Blast** : moyen-haut (hot path ; ordre d'include).

**T2.2 — Sortir l'UI de `lib/` + flat→folder (rattrapage par driver)** *(prolonge P5 §131 / P6)*
- **Obj** : `lib/ = aucun UI` ; symétrie. **Preuve** : `windows/lib/hotstrings/hotstrings_config_window.ahk`
  (1428, UI dans `lib/`) ; `windows/ui/wpm_widget.ahk` (1266 flat) ; `macos/lib/healthcheck.lua`
  (1112, UI dans `lib/` — **macOS est ici le retardataire**).
- **Action** : `hotstrings_config_window.ahk` → `windows/ui/hotstrings_config_window/` (miroir
  macOS) ; `wpm_widget.ahk` → `windows/ui/wpm/{init,widget,menubar}.ahk` ; `macos/lib/healthcheck.lua`
  → `macos/ui/healthcheck/` (miroir Windows). ⚠️ **Vérifier d'abord** que sortir `healthcheck`
  de `lib/` est **neutre pour le ratchet** (le garde compte `hs.*`/`io` dans `modules/`+`lib/` —
  si `ui/` n'est pas scanné, le move **baisse** les compteurs : OK ; sinon ajuster baseline avec note).
- **Test** : `_DriverDirConcat` pour les meta-tests ; test « path résolu existe ».
- **Vérif** : dry-run + suite + encoding + `test:hs` + ratchet vert. **Diagnostic d'échec** :
  fenêtre ne s'ouvre pas / ratchet spike. **Rollback** : move inverse. **Blast** : moyen.

**T2.3 — Splits macOS-only (pas de miroir AHK)** *(prolonge P6 §143)*
- **Obj** : SRP sur les 4 plus gros macOS-only. **Preuve** : `api_mlx.lua` 1799,
  `models_manager_mlx.lua` 1790 (1 closure `M.new`), `menu_keyboard_layout.lua` 1647 (TIS),
  `healthcheck.lua` 1112.
- **Action** : `modules/llm/mlx/{server,discovery,warmup,request,fetch}.lua` ;
  `menu_llm/{mlx_server_launcher,mlx_model_puller}.lua` (extraction par **passage de
  dépendances** — closures partagent des upvalues, pas un `#Include` libre comme AHK) ;
  `menu_keyboard_layout/{bundles,input_source,menu}.lua`.
- **Test** : tests unit macOS des modules concernés (filet). **Vérif** : `test:hs`.
- **Diagnostic d'échec** : `loadfile` parse (cf. [PROJECT_MEMORY.md:1559](PROJECT_MEMORY.md#L1559)) + tests unit rouges.
  **Rollback** : re-merge. **Blast** : moyen. **Note guide** : NE PAS apparier à un fichier AHK.

**T2.4 — Refactor des fonctions-dieu (SRP par fonction)** *(prolonge P6)*
- **Obj** : `handle_key()`/`onKeyDownRaw()` deviennent des dispatchers. **Preuve** : §2.5.
- **Action** : extraire `should_skip_event()` (chaîne de gardes), bookkeeping idle/souris,
  sous-handlers key-up/key-down. **Pur refactor**, testable sur le stub `hs`.
- **Test** : test pinnant l'ordre de dispatch (rouge avant/vert après). **Vérif** : `test:hs`.
- **Diagnostic d'échec** : ordre de dispatch cassé = test nommé. **Blast** : moyen (hot path).

**T2.5 — Taxonomie de test miroir AHK (un-defer P2)** *(prolonge/dé-reporte [P2 §87](REFACTOR_PLAN.md#L87))*
- **Obj** : `tests/unit/<area>/` path-mirror (modèle macOS). **Preuve** : arbre AHK plat (§2.1).
- **Action** : déplacer les ~82 tests plats + meta vers `tests/unit/modules/<feature>/`, en
  **réécrivant `run_all.ahk` `#Include` en lockstep**, staged **derrière**
  `test_run_all_include_integrity.ahk` + dry-run.
- **Test** : `test_run_all_include_integrity` (asserte que tout `test_*.ahk` est inclus).
- **Vérif** : dry-run + suite (count identique). **Diagnostic d'échec** : « test_X non inclus
  dans run_all ». **Rollback** : git revert (un seul commit). **Blast** : moyen-haut (réécrit le
  graphe d'include — d'où le staging ; cf. [§7](#7-décisions-maintainer-requises)).

### Tier 3 — High / décisions maintainer requises ([§7](#7-décisions-maintainer-requises))

**T3.1 — `gestures.ahk` flat → folder miroir** *(P5 §130, déjà flaggé ⚠️)*
- **Preuve** : 2076 l. ; hotkeys top-level `^#+F1::` (`:1805`) sous `#InputLevel 2` **non
  exercés headless** → régression visible seulement au reload utilisateur ; 23 tests référencent
  `Gesture*`. **Action** : miroir `modules/gestures/{init,actions,window_cycle,mouse_hold,dispatch,config}.ahk`,
  **hotkeys conservés dans l'index** à la position exacte vs `#InputLevel 2`. **Test** : behavior +
  **reload-test live explicite** (le headless ne couvre pas). **Blast** : **HAUT**.

**T3.2 — Consolider la couche layout → `windows/modules/keymap/`** *(P5 §132)*
- **Preuve** : pas de `windows/modules/keymap` ; logique éparpillée `modules/layout.ahk` (901) +
  `lib/layout/*` (1565) ; macOS = `modules/keymap/` (4471). **Action** : converger **vers macOS**.
  **Blast** : **HAUT** (hotkeys top-level, `#InputLevel`). **Décision** : `lib/keymap/` vs
  `modules/keymap/` (cf. [REFACTOR_PLAN.md:166](REFACTOR_PLAN.md#L166)).

**T3.3 — Hotstrings engine `lib/ → modules/` + nom unifié** *(prolonge P5)*
- **Preuve** : engine Win dans `lib/hotstrings/` vs macOS `modules/dynamic_hotstrings/` (couches
  opposées, noms différents). **Décision** : nom (`hotstrings` vs `dynamic_hotstrings`). **Blast** :
  **HAUT** (hot-path, ordre d'include).

**T3.4 — `hotstrings.ahk` : 34 `if`-blocks → boucle data-driven** *(SOLID-O)*
- **Preuve** : 96 sites `Features[` + 34 `LoadHotstringsSection` hand-maintained
  ([`:66-1002`](../static/ergopti_plus/windows/modules/hotstrings.ahk#L66)) ; macOS data-driven via `_index.toml`. **Action** : itérer les groupes
  déclarés au manifeste. **Test** : « un nouveau groupe manifeste-only se charge **sans** édition de
  code ». **Blast** : **HAUT** (load path hot).

**T3.5 — Accessor fail-fast des `Features[`** *(P4 reporté → décision)*
- **Preuve** : **294** sites prod / 29 fichiers, dont profonds
  `Features["hotstrings"]["distances_reduction"]["qu"]["enabled"]`. [REFACTOR_PLAN.md:74](REFACTOR_PLAN.md#L74) l'a reporté
  (conversion de masse risquée sans GUI ; accessor dormant = §5.6). **Décision maintainer** sur la
  forme + le timing (dans la réécriture d'entrée, vérifiable). **Blast** : **HAUT**.

**T3.6 — Mutualisation profonde** *(P7, sous-étape par sous-étape)*
- Logger → `_shared/lua/logger` via `set_sink()` ; tooltip AHK lit
  `_shared/modules/tooltip/constants.toml` (⚠️ alpha per-platform). **`tap_hold` et `max_tokens`
  = `feat`, pas refactor** (voir [§6](#6-defaults--ssot) / [§7](#7-décisions-maintainer-requises)). **Blast** : **HAUT**, livré isolément avec
  snapshot avant/après.

---

## 5. Chantier testabilité (transversal · priorité 1)

> **Cadre.** Ce chantier **dé-reporte** explicitement l'item [P2 §87-88](REFACTOR_PLAN.md#L87) (« taxonomie
> miroir + auto-découverte », reportée comme « gros + risqué »), staged derrière
> `test_run_all_include_integrity` + dry-run vert. Il ne touche **pas** le ratchet de
> pureté ([`test_port_adapter_coverage`](../static/ergopti_plus/macos/tests/meta/test_port_adapter_coverage.lua)) ni les helpers de scan (344 tests en dépendent).

### 6.1 Taxonomie cible

| Tier | Définition | Aujourd'hui | Cible |
|---|---|---|---|
| **Behavior** | appelle la fonction, asserte la sortie | 67 AHK | **majorité** |
| **Contrat** | vecteurs `*.spec.js` sur chaque adapter | 9/20 ports | **20/20** (T1.4) |
| **Scan-source move-resilient** | `_Driver*` helpers, invariant structurel | 189 AHK | **centralisé** (6.3) |
| **Scan-source location-pinned** | `FileRead` chemin fixe | **~141 AHK + 32 macOS** | **0** (T1.2) |

### 6.2 Convertir les ~141+32 location-pinned → 0 (mécanique, T1.2)
`_XXX_ReadSource("modules/gestures.ahk")` → `_DriverFuncBody("Fn")` (AHK) ;
`io.open(DRIVER_ROOT.."modules/X.lua")` → un `driver_concat()` macOS (miroir de
`_DriverSourceConcat`). **Métrique : un déplacement de fichier ne casse plus aucun test.**

### 6.3 Un seul méta-test déclaratif pour les invariants structurels
Au lieu de N assertions file-pinnées, **une** table déclarative par invariant :
- « tout appel OS vit dans `adapters/` » → c'est déjà le ratchet (ne pas dupliquer).
- « tout site `Features[…]` résout contre le manifeste » → déjà
  [`test-feature-read-sites.js`](../tools/test/test-feature-read-sites.js) — **généraliser l'esprit**, pas multiplier.
- Nouveau : « tout module prod a un dossier de test co-localisé » (rendu possible par T2.5).

### 6.4 Contrats dérivés de la SSoT
Chaque **default** (drift test cross-driver, T1.6) et chaque **port** (vecteurs, T1.4) est
couvert par un test **dérivé** de `manifest.toml` / `*.spec.js` → un défaut qui diverge ou un
port non conforme **échoue au CI, pas au clavier**.

### 6.5 Convention de nommage + gabarit
- **Nom = comportement** : `expands "tdej" -> "déjeuner" after a word boundary`, pas
  `test_expander_file_has_function`.
- **Gabarit de message** mandaté (T1.3) : `expected / actual / at:<test:line> / replay:<cmd>`.
- **Bannir** `Assert()`/`AssertThrows()` sans valeur (**~2008** `Assert(` AHK) et `assert_true(x)` nu (~530 macOS).

### 6.6 Métrique de réussite
- Ratio behavior:scan-source **inversé** sur la part convertible (cible : behavior ≥ scan-source).
- **0** test location-pinned (un `git mv` ne casse aucun test).
- **20/20** ports avec vecteurs comportementaux.
- Un rouge ⇒ le dev lit *comportement attendu/obtenu + `path:line` du test + `replay:`* — **< 5 min**.

---

## 6. Defaults & SSoT

**Mécanisme unique de consommation** (déjà la norme, à étendre) : le driver **lit** le défaut
partagé (`_shared/modules/<f>/{defaults.toml,constants.toml,*.json}`) via un loader prenant la
**cible en paramètre** ; il ne le **re-déclare jamais** ; tout fallback `if x == nil then x = …`
est une violation §5.4 (garde : [`test:no-fallbacks`](../tools/test/test-no-fallback-literals.cjs)).

| Défaut | Décision | Étape | Drift test |
|---|---|---|---|
| Timings, hotstring global delay/color, LLM toggles, WPM consts, LLM inference (diversity/retry/rate) | ✅ **déjà `_shared/`, lus, fail-fast** — ne rien faire | — | déjà testé |
| WPM HS `or <litt>` (15) | `_shared/wpm_widget/constants.toml` (déjà SSoT) → **fail-fast** | T1.6 | `test_wpm_no_inline_fallback` |
| `language 'fr'` (≥4) | manifeste `script.locale` | T1.6 | read-site test |
| `DELAYS_DEFAULT`↔`DYN_HOTSTRINGS_DEFAULT_DELAY` (byte-égal) | `_shared/hotstrings/defaults.toml [delays]` | T1.6 | cross-driver byte-equiv |
| LLM temperature 0.1 (27 `tonumber or`) | lire `defaults.json` / fail-fast | T1.6/T2 | drift test |
| **`max_tokens` 150/256/50** | **DIVERGENT → `feat`** : choisir la valeur/backend **avant** `inference.json` | [§7](#7-décisions-maintainer-requises) | post-décision |
| **`tap_hold` (per-key vs global 1000 ms)** | **modèles divergents → `feat`** ; rester driver-specific | [§7](#7-décisions-maintainer-requises) | — |
| Gesture sensitivity 3.5 | macOS-local (légitime) | hygiène §5.1 opt. | — |

**Le drift redevient impossible** quand un test compare la valeur **consommée** à la SSoT
(cross-driver) et casse sinon — généralise l'esprit de `test:manifest-parity`/`priority-parity`.
⚠️ Tout rapatriement d'un défaut potentiellement déjà divergent exige une **preuve d'équivalence
byte** d'abord (sinon `feat`, cf. avertissement P7 `tap_hold`).

---

## 7. Décisions maintainer requises

Arbitrages **irréversibles / fort blast radius** — options + reco + risque. **Ne pas trancher seul.**

| # | Décision | Options | Reco | Risque |
|---|---|---|---|---|
| 1 | **Layout/keymap Windows** | `lib/keymap/` vs `modules/keymap/` | `modules/keymap/` (miroir macOS) | HAUT (hotkeys, `#InputLevel`) |
| 2 | **Placement menu** | plié dans `manifest.toml` (1 SSoT, gros codegen) vs `menu_manifest.json` + drift gate | `menu_manifest.json` (existe déjà) sauf volonté de tout coder-générer | MOYEN |
| 3 | **`lib/` foldé (Win, 7 sous-dossiers) vs plat (macOS, 0)** | folderiser macOS vs aplatir Win vs garder | **ne pas** mass-folderiser macOS ; folder seulement si >1 fichier des 2 côtés | HAUT (réécrit `require`/`#Include`) |
| 4 | **Orphelins `_generated/{registry,expander}.ahk`** | adopter vs supprimer (+ scripts codegen) | grep `#Include` d'abord ([REFACTOR_PLAN.md:169](REFACTOR_PLAN.md#L169)) | MOYEN |
| 5 | **Codec TOML + parser LLM AHK** | transpile Lua→AHK vs génération corpus-driven + hand-port | corpus-driven (testable) | HAUT |
| 6 | **`linux/`** | même passe vs suivi séparé | **suivi séparé** — 0 surface `Features[` (vérifié), driver partiel par conception | FAIBLE |
| 7 | **Accessor fail-fast `Features[` (294 sites)** | maintenant vs dans la réécriture d'entrée | dans la réécriture (vérifiable GUI), forme à valider | HAUT |
| 8 | **`tap_hold` unifié** | unifier (per-key vs 1000 ms global) vs garder divergent | **garder** ; unifier = `feat`/UX | HAUT |
| 9 | **`max_tokens` (150/256/50)** | valeur unique/backend vs garder | décider la valeur par backend (change la longueur de sortie LLM) | MOYEN |
| 10 | **Fenêtres UI macOS-only** (`hotstring_editor`, `prompt_editor`, `token_prompt`, contrôleur `download_window`) | porter sur Windows vs assumer macOS-only | au cas par cas | MOYEN |
| 11 | **Métriques Windows** : dashboards standalone vs menu-embedded | ajouter `ui/metrics_*` Win (frontend déjà `_shared`) vs garder menu | clarifier l'intention produit | MOYEN |
| 12 | **Taxonomie test AHK (T2.5)** | déplacer ~411 tests + réécrire `run_all` vs garder plat | faire, staged derrière include-integrity | MOYEN-HAUT |

---

## 8. Risques & foot-guns

Repris/complétés de [PROJECT_MEMORY.md](PROJECT_MEMORY.md) et [REFACTOR_PLAN.md](REFACTOR_PLAN.md) :

- **Encodage AHK** : `.ahk` = UTF-8 **BOM + CRLF**. LF-only / sans-BOM ⇒ **abort silencieux
  mi-fichier** (moins de tests enregistrés, sans erreur). → outil **Edit**, jamais `cat >>` ;
  tests **ASCII-only** (glyphes via `Chr(0xNNNN)`) ; `npm run test:ahk-encoding` après chaque move.
- **Mesure des `.ahk`** : `grep`/`git grep` POSIX renvoie **0** sur ces fichiers (UTF-16/BOM) →
  utiliser **ripgrep** (outil `Grep`). Tout comptage `Features[`/symbole AHK fait au `grep` est faux.
- **Ordre `#Include` + `#InputLevel`** : portent des invariants (hoisting des globals,
  `#InputLevel 2` avant les includes de layer). Réordonner casse les hotkeys **sans erreur de
  compile**. → préserver l'ordre ; `gestures.ahk` `^#+F1::` non exercé headless → **reload-test**.
- **Ratchet de pureté** ([`test_port_adapter_coverage.lua:243`](../static/ergopti_plus/macos/tests/meta/test_port_adapter_coverage.lua#L243)) : compte le **substring `hs.`** (commentaires
  inclus, [PROJECT_MEMORY.md:187](PROJECT_MEMORY.md#L187)). **`io.open`/`os.execute` = 70/70 — ZÉRO marge** : tout nouvel
  appel OS hors `adapters/` casse le build → router via adapter. `hs.*` = 917/950 (33 de marge).
- **`adapters/` = isolation OS** (20 ports **+** helpers OS), **pas** « 20 pile ». Sortir
  `json_codec`/`shell_runner`/`toml_cache` de `adapters/` est **rejeté** ([REFACTOR_PLAN.md:96](REFACTOR_PLAN.md#L96)).
- **`init.lua` / entrée = 0 couverture d'exécution** : seul un **parse** la garde
  ([`test_lua_sources_compile.lua`](../static/ergopti_plus/macos/tests/meta/test_lua_sources_compile.lua), [PROJECT_MEMORY.md:1554](PROJECT_MEMORY.md#L1554)). Après tout split touchant l'entrée, `loadfile`/dry-run.
- **`tap_hold` & `max_tokens` déjà divergents** : `feat`, pas refactor (prouver l'équivalence
  byte sinon).
- **Test path-résolu** : un test qui asserte juste « module ≠ nil » **n'attrape pas** un chemin
  cassé (le module dégrade en silence) — asserter que le fichier a **résolu** (foot-gun wpm_widget,
  [PROJECT_MEMORY.md:1549](PROJECT_MEMORY.md#L1549)).
- **Garde par *forme* de code** : un meta-test qui impose une *écriture* précise peut **cimenter
  un bug** ([PROJECT_MEMORY.md:1569](PROJECT_MEMORY.md#L1569)) — asserter l'**invariant**, jamais une orthographe.
- **Churn du généré** : le drift gate produit un gros diff one-time → **commit dédié**.
- **Ne jamais affaiblir un test** pour faire passer un changement (§5.9) — on renforce le filet.

---

## 9. Definition of Done

Du **guide** (auto-vérifié) :

- [x] Chaque reco adossée à un `path:line` ou un chiffre reproductible — zéro conseil générique.
- [x] Chaque étape : objectif, preuve, action, **test associé** (cause racine), commande de vérif,
      **scénario de diagnostic d'échec**, rollback, blast radius.
- [x] La **priorité n°1 (testabilité)** a sa section ([§5](#5-chantier-testabilité-transversal--priorité-1)) avec métrique cible et plan pour les ~141+32
      location-pinned + 189 helper-scan.
- [x] Inventaire **defaults** exhaustif, chaque entrée décidée (manifeste / `_shared` /
      driver-specific) + drift test ([§6](#6-defaults--ssot)).
- [x] **Table de symétrie** Win↔macOS complète, divergences marquées avec sens de convergence ([§2.4](#24-gros-fichiers--116--400-l-57-ahk--59-lua)/[§4](#4-plan-priorisé-par-phases)).
- [x] Tous les **gros fichiers** (>400) ont un plan de split miroir ([§2.4](#24-gros-fichiers--116--400-l-57-ahk--59-lua)).
- [x] Le guide **ne contredit pas** `REFACTOR_PLAN`/`PROJECT_MEMORY`/ADRs ; il les prolonge.
- [x] **Aucune étape ne change le comportement** sauf marquée `feat`/`fix` (`tap_hold`, `max_tokens`).
- [x] Arbitrages irréversibles en **[§7](#7-décisions-maintainer-requises)**, pas tranchés seul.
- [x] Tout est **incrémental, vérifiable, réversible** ; ordre du moins au plus risqué.

**Critère de sortie par étape exécutée** (harnais, [docs/TESTING.md](TESTING.md)) :
`AutoHotkey64 /ErrorStdOut run_all.ahk --dry-run` exit 0 · suite AHK count ≥ baseline ·
`lua macos/tests/run.lua` 0 failed · `npm run test:js` vert · `npm run test:ahk-encoding` vert ·
drift gate (`npm run build:domain`) vert. **Geler ces counts via T0.2 avant de commencer.**
