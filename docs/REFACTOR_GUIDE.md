# ErgoptiPlus — Guide de refactor (lisible · SOLID · 100 % testable)

> **Statut.** Ce guide **prolonge** [docs/REFACTOR_PLAN.md](REFACTOR_PLAN.md) (phases
> P0→P7) et s'appuie sur [docs/PROJECT_MEMORY.md](PROJECT_MEMORY.md) et les
> [ADR 001-007](../static/ergopti_plus/docs/adr/). Il ne le contredit pas : il chiffre
> l'état réel, raffine les priorités, et détaille la **priorité n°1 — rendre un test
> rouge diagnosticable en < 5 min**.
>
> **Toutes les affirmations sont adossées à un `path:line` ou une commande
> reproductible.** Mesuré le 2026-06-21, puis **re-vérifié le 2026-06-21 par une seconde
> passe d'audit multi-agents (10 clusters, exécution séquentielle).** Cette passe a
> trouvé que **le code a avancé depuis la rédaction initiale** : plusieurs étapes
> recommandées sont **déjà faites** et marquées ✅ **DONE** ci-dessous —
> > • vecteurs de contrat **20/20 macOS + 18/20 AHK** (étaient 9/20 ; T1.4 quasi close),
> > • runner AHK : `--only` + ligne `replay:` + `[file:line]` pointant le **test** (pas le helper) **déjà livrés** (le cœur de T1.3 est fait),
> > • defaults WPM-HS / `DYN_HOTSTRINGS_DEFAULT_DELAY` / `profiles.lua 'fr'` **déjà rapatriés dans `_shared/`** fail-fast,
> > • `architecture.md` **déjà régénéré** (dessine bien 20 ports HS).
> >
> ~20 chiffres/citations dérivés ont été corrigés (détaillés en ligne). **Aucune étape
> ne change le comportement** sauf celles explicitement marquées `feat`/`fix`.
>
> ⚠️ **Foot-gun de mesure** : `git grep` / `grep` POSIX renvoie **0** sur les fichiers
> `.ahk` (UTF-16/BOM + CRLF). Tout comptage AHK doit se faire avec **ripgrep**
> (l'outil `Grep`) sinon on conclut à tort « 0 occurrence ». Voir
> [§8 Risques](#8-risques--foot-guns).

---

## 1. TL;DR

Par impact décroissant (gain entre parenthèses) :

1. **Diagnostic d'échec — priorité absolue, mais le périmètre a rétréci.** **346 / 415**
   tests AHK (`windows/tests/test_*.ahk`) scannent encore le *source* ; à rouge ils
   disent *« texte X absent du fichier Y »*, **jamais** *« le comportement Z est cassé »*.
   En revanche, l'**outillage** de diagnostic (pointer le test, filtrer, rejouer) est
   **désormais en place côté AHK** (cf. #3). Le travail restant est la **conversion
   introspection→behavior**, pas l'outillage. (→ [§5](#5-chantier-testabilité-transversal--priorité-1)).
2. **~144 tests AHK restent *location-pinned*** (`FileRead` d'un chemin source codé en
   dur) et **cassent à chaque déplacement de fichier** — alors que **3 helpers
   move-resilient existent déjà**. Migration mécanique. (→ *refactor débloqué*).
3. ✅ **Ergonomie d'échec — l'outillage AHK est livré (re-noté B+/A-, pas C).** Le runner
   pointe `[file:line]` sur le **test** via `_TestCallSite` ([test_framework.ahk:256-268](../static/ergopti_plus/windows/tests/test_framework.ahk#L256)),
   accepte `--only <substr>` ([run_all.ahk:37-47](../static/ergopti_plus/windows/tests/run_all.ahk#L37)) et imprime une ligne `replay:`
   par `not ok` ([test_framework.ahk:358-360](../static/ergopti_plus/windows/tests/test_framework.ahk#L358)). **Reste** : bannir
   `Assert()`/`AssertThrows()` **nus** (sans valeur attendu/obtenu). (→ *diagnostic*).
4. **DIP asymétrique = le gain max / risque min.** macOS a un *ratchet de pureté OS*
   (**918/950** `hs.*`, **70/70 `io.open` — ZÉRO marge**) ; **AHK n'en a aucun** →
   117 `DllCall` + 21 COM + 36 `FileRead` hors `adapters/` non gardés. Ajouter le ratchet
   AHK (baseline = comptes actuels) est *test-only, blast faible*. (→ *zéro dérive*).
5. ✅ **Defaults : l'infra `_shared/` existe et la dette a été largement payée.** WPM-HS,
   `DYN_HOTSTRINGS_DEFAULT_DELAY` et `profiles.lua 'fr'` sont **déjà** rapatriés fail-fast.
   **Restent** : `language 'fr'` Windows (≥4 sites), 41 `tonumber(x) or <litt>` LLM macOS
   (temperature). (→ *zéro dup*).
6. **Gros fichiers : 116 fichiers > 400 l.** (57 AHK + 59 Lua, scope windows+macos).
   Splits **miroir** via le pipeline déjà prouvé. En tête : `gestures.ahk` (2076 l.,
   risque hotkeys) et le couple keylogger central (1867 ↔ 1609). (→ *lisibilité, SRP*).
7. **La plupart des « divergences UI » sont superficielles.** 5 frontends webview sont
   **déjà 1:1 dans `_shared/ui/`** ; seul le contrôleur per-OS diffère → renommages
   `flat → ui/<window>/init` = **les wins de symétrie les moins chers**. (→ *symétrie*).
8. **Open/Closed : `hotstrings.ahk` = 96 sites `Features[` + 34 `if`-blocks
   hand-maintained.** Ajouter un groupe = éditer ce fichier au lieu du seul manifeste.
   → boucle data-driven (le macOS le fait déjà). (→ *SOLID-O*).
9. ✅ **Liskov : la couverture de contrat est quasi complète (20/20 macOS, 18/20 AHK).**
   Étaient 9/20 ; 5 commits l'ont étendue. **Reste** : 2 ports AHK (KeyboardHook,
   TooltipRenderer) + dériver les vecteurs des `*.spec.js` plutôt que les hand-mirrorer. (→ *correction cross-driver*).
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

Bucketisation des **415** `windows/tests/test_*.ahk` (82 à la racine + 333 sous
`tests/meta/` + 0 sous `tests/e2e/` ; commandes reproductibles) :

| Bucket | Fichiers | Que dit l'échec ? | Commande |
|---|---|---|---|
| **Comportement / contrat** (aucun primitive d'introspection) | **69** | ✅ comportement attendu vs obtenu | `415 − 346 (union)` |
| **Scan-source *move-resilient*** (`_Driver*` helpers) | **190** (169 `_DriverFuncBody`, 29 `_DriverSourceConcat`, 14 `_DriverDirConcat`) | ⚠️ « le *texte* de la fonction n'a pas X » | Grep `_DriverSourceConcat\|_DriverFuncBody\|_DriverDirConcat` |
| **`FileRead` *location-pinned* de source** | **~144** (sur 156 fichiers `FileRead`-sans-helper ; ~12 lisent des fixtures `.tsv`, légitime) | ❌ « *fichier.ahk* must be readable » (erreur de **chemin** sur déplacement) | helper `_XXX_ReadSource(rel)` répliqué par fichier |
| **Union introspection** | **346 / 415 (~83 %)** | — | Grep union des 4 patterns ⇒ `Found 346 files` |

- Helpers move-resilient **déjà fournis**, anchorés sur la **définition** :
  [`test_framework.ahk:157`](../static/ergopti_plus/windows/tests/test_framework.ahk#L157)
  (`_DriverSourceConcat`), `:177` (`_DriverFuncBody`), `:218` (`_DriverDirConcat`).
- L'arbre AHK est **plat** : 3 dossiers seulement (`tests`, `tests/meta`, `tests/e2e`) ;
  **0** mirror `tests/unit/modules/<feature>/`. À l'inverse macOS **mirroir exact** :
  [`macos/tests/unit/modules/gestures/test_conflicts.lua`](../static/ergopti_plus/macos/tests/unit/modules/gestures/test_conflicts.lua) ↔ `modules/gestures/conflicts.lua`.
- macOS porte **aussi** l'anti-pattern, et **plus largement qu'il n'y paraît** : les
  **32** meta-tests `io.open`/`io.read`/`io.lines` de source ne sont qu'un sous-ensemble
  des **~185 fichiers** qui, sur tout l'arbre `macos/tests/`, lisent un source entier +
  `:match`/`:find` (ex. [`test_gestures_ghost_timer_guard.lua:25`](../static/ergopti_plus/macos/tests/meta/test_gestures_ghost_timer_guard.lua#L25) lit `modules/gestures/init.lua` et `:match` du texte).
  La suite macOS est donc **majoritairement** scan-source, pas behavior-first.

**Échantillon de messages d'échec réels** (tous sous `tests/meta/` ; aucun ne pointe le comportement) :

| Test (sous `windows/tests/meta/`) | Message à rouge (texte réel) | Pointe vers |
|---|---|---|
| [`test_activate_hotstrings_sleep_gate.ahk:82`](../static/ergopti_plus/windows/tests/meta/test_activate_hotstrings_sleep_gate.ahk#L82) | « ActivateHotstrings must early-return before the poke when HSE_Buffer is empty… » | ordre de *texte* |
| [`test_av_focus_mode_dead_code.ahk:61`](../static/ergopti_plus/windows/tests/meta/test_av_focus_mode_dead_code.ahk#L61) | « KL_AV_SlowTick must NOT call KL_AV_PollFocusMode — its recursive registry walk blocks… » | *absence* de texte |
| [`test_native_hotstrings_migrated.ahk:41`](../static/ergopti_plus/windows/tests/meta/test_native_hotstrings_migrated.ahk#L41) | « hotstring_engine_main.ahk must be readable » | erreur **I/O** sur déplacement |

### 2.2 Ergonomie d'échec — barème par couche (re-mesuré)

| Couche | Attendu vs obtenu ? | Indice `path:line` ? | Replay d'un seul test ? | Note |
|---|---|---|---|---|
| **JS** (`tools/test`) | ✅ par check, + tail ([`run-js-suite.cjs:75`](../tools/test/run-js-suite.cjs#L75)) | implicite (stack si throw) | ✅ `reproduce:` ([`run-js-suite.cjs:74`](../tools/test/run-js-suite.cjs#L74)) | **A-** (la barre) |
| **AHK** (`windows/tests`) | partiel — `AssertEqual/True/False/Contains` rendent les valeurs ([`test_framework.ahk:94`](../static/ergopti_plus/windows/tests/test_framework.ahk#L94)) ; `Assert()`/`AssertThrows()` **nus** ; **2091** sites `Assert(` (355 fichiers) + **598** `AssertTrue(` (59 fichiers) | ✅ **pointe le test** via `_TestCallSite(e.Stack)` ([`:256-268`](../static/ergopti_plus/windows/tests/test_framework.ahk#L256), utilisé `:343-348`) | ✅ `--only <substr>` ([`run_all.ahk:37-47`](../static/ergopti_plus/windows/tests/run_all.ahk#L37)) + ligne `replay:` par `not ok` ([`:358-360`](../static/ergopti_plus/windows/tests/test_framework.ahk#L358)) | **B+/A-** |
| **macOS** (`macos/tests`) | partiel — `assert_eq` rend attendu/obtenu ([`helpers/init.lua:226`](../static/ergopti_plus/macos/tests/helpers/init.lua#L226)) ; `assert_true` nu → « expected truthy » ([`:237`](../static/ergopti_plus/macos/tests/helpers/init.lua#L237)) ; **~406** sites nus (sur 1983 ; 1577 ont un message) | ✅ `error(msg,2)` → site du test ([`:237`](../static/ergopti_plus/macos/tests/helpers/init.lua#L237)) | ❌ aucun filtre CLI dans `run.lua` | **B-** |
| **Linux** (`linux/tests`) | partiel (`assert_true` nu [`helpers.lua:87`](../static/ergopti_plus/linux/tests/helpers.lua#L87)) | ✅ `error(msg,2)` | ❌ aucun filtre | **B-** |

**La barre existe déjà** : [`run-js-suite.cjs:71-77`](../tools/test/run-js-suite.cjs#L71) imprime, par
check rouge, (a) le nom, (b) `reproduce: <cmd exact>` (`:74`), (c) les 12 dernières lignes
(`:75`). **Et l'AHK l'atteint déjà** pour le filtre + replay + localisation (gardé par
[`meta/test_runner_only_filter.ahk`](../static/ergopti_plus/windows/tests/meta/test_runner_only_filter.ahk) +
[`meta/test_runner_failure_ergonomics.ahk`](../static/ergopti_plus/windows/tests/meta/test_runner_failure_ergonomics.ahk), câblés `run_all.ahk:308-309`). Le seul reste : le rendu **valeur** des asserts nus.

### 2.3 Defaults hors manifeste — inventaire (dette largement payée)

L'infra `_shared/modules/*/` **existe** et est **lue** par les deux drivers (à ne PAS
re-proposer) : `timings/constants.toml` (~113 read-sites/32 fichiers, ou ~89/27 hors
tests, via `TimingsGet`/`TimingsGetSec`/`Timings.ms`/`Timings.sec`), `hotstrings/defaults.toml`,
`llm/defaults.json` + `inference.json`, `wpm_widget/constants.toml`, `tooltip/constants.toml`.
État des poches restantes :

| Défaut | Win | macOS | Sites | Devrait vivre | Statut |
|---|---|---|---|---|---|
| WPM widget visuels | sentinelle fail-fast ([`ui/wpm_widget.ahk:47`](../static/ergopti_plus/windows/ui/wpm_widget.ahk#L47)) | **fail-fast, 0 fallback** ([`ui/wpm/wpm_widget.lua:115`](../static/ergopti_plus/macos/ui/wpm/wpm_widget.lua#L115), commit `8122ea848`) | — | `_shared/.../wpm_widget/constants.toml` | ✅ **DONE** |
| Délai dynamic-hotstrings 2.0 | `DYN_HOTSTRINGS_DEFAULT_DELAY:=""` (fail-fast) ([`hotstrings_config.ahk:54`](../static/ergopti_plus/windows/lib/hotstrings/hotstrings_config.ahk#L54)) | `DELAYS_DEFAULT` fallback ultime résolu du TOML au boot ([`keymap/init.lua:51`](../static/ergopti_plus/macos/modules/keymap/init.lua#L51)) | — | `_shared/.../hotstrings/defaults.toml:63` (`dynamichotstrings_sec = 2.0`) | ✅ **DONE** |
| `language 'fr'` macOS (prompt LLM) | — | lit `i18n.get_locale() or Manifest.default_for("script.locale")` ([`profiles.lua:203`](../static/ergopti_plus/macos/modules/llm/profiles.lua#L203)) | — | manifeste | ✅ **DONE** |
| `language 'fr'` Windows | `prediction_engine.ahk:45`, `_generated/prompt_builder.ahk:206`, `_generated/features_manifest.ahk:46` (default manifeste, légitime), `ui/tray_llm/_index.ahk:106`, `lib/i18n.ahk:61` | (refactoré) | ≥4 | manifeste `script.locale` | **À FAIRE** (refactor) |
| LLM temperature 0.1 | lit `defaults.json` | **41× `tonumber(x) or <litt>`** / 9 fichiers ([`api_common.lua:142`](../static/ergopti_plus/macos/modules/llm/api_common.lua#L142), `api_ollama.lua:292`, `api_mlx.lua:1011`, `api_remote.lua:283`…) | 41 | `defaults.json` | **À FAIRE** (refactor) |
| `max_tokens` cap | ollama **150** ([`api_ollama.ahk:345`](../static/ergopti_plus/windows/modules/llm/api_ollama.ahk#L345)), remote **256** ([`api_remote.ahk:65`](../static/ergopti_plus/windows/modules/llm/api_remote.ahk#L65)) | mlx **50** ([`api_mlx.lua:1098`](../static/ergopti_plus/macos/modules/llm/api_mlx.lua#L1098)) | — | `inference.json` (par backend) | **DIVERGENT → `feat`** |
| `tap_hold` seuils | par-clé 0.20-0.35 s ([`data/tap_hold/defaults.toml:38`](../static/ergopti_plus/windows/data/tap_hold/defaults.toml#L38)) | global 1000 ms ([`karabiner/defaults.lua:14`](../static/ergopti_plus/macos/modules/karabiner/defaults.lua#L14)) | — | **rester driver-specific** | **MODÈLES divergents → `feat`** |
| Gesture sensitivity 3.5 | (gestures = macOS only) | `gestures/init.lua:106` | 1 | macOS-local (légitime) | — |

> **Attention citation** : `api_mlx.lua:1098` et `:1301` sont des `max_tokens … or 50`
> (cap mlx), **pas** la temperature ; la temperature 0.1 mlx est à `:1011/1643/1725/1780`.

Le garde existant [`test_no_duplicate_defaults.lua:42`](../static/ergopti_plus/macos/tests/meta/test_no_duplicate_defaults.lua#L42)
**ne voit que le Lua macOS** et ne fait que `WARN` (it-block au corps vide) → aucune des
dup restantes n'est attrapée en CI.

### 2.4 Gros fichiers — 116 > 400 l. (57 AHK + 59 Lua)

`find static/ergopti_plus/{windows,macos} -name '*.ahk' -o -name '*.lua' | grep -vE '/tests?/|/_generated/|/vendor/' | xargs wc -l | awk '$1>400'` ⇒ 116. **Scope = windows+macos** ;
`_shared/` ajoute 4 fichiers prod > 400 l. (`lua/llm/parser.lua` 842, `toml_codec/reader.lua` 666,
`text_utils/init.lua` 562, `toml_codec/codec.lua` 535), délibérément exclus ; `linux/` aucun.
Top + statut miroir :

| # | Fichier (`static/ergopti_plus/`) | L. | Statut miroir |
|---|---|---|---|
| 1 | `windows/modules/gestures.ahk` | 2076 | macOS `modules/gestures/` **déjà splitté** → AHK rattrape. **HIGH-RISK** (hotkeys top-level) |
| 2 | `windows/modules/keylogger/keylogger.ahk` | 1867 | parallèle de `macos/.../keylogger/init.lua` (1609) — splitter **ensemble** |
| 3 | `macos/modules/llm/api_mlx.lua` | 1799 | **macOS-only** (MLX = Apple Silicon) → split unilatéral |
| 4 | `macos/ui/menu/menu_llm/models_manager_mlx.lua` | 1790 | macOS-only ; corps = 1 closure `M.new()` (extraction par dépendance) |
| 5 | `macos/ui/menu/menu_keyboard_layout.lua` | 1647 | macOS-only (TIS) ; Win `menu_layout.ahk` = stub |
| 6 | `macos/modules/keylogger/init.lua` | 1609 | parallèle de #2 |
| 7 | `windows/lib/hotstrings/hotstring_engine_main.ahk` | 1509 | déjà 2-way (`engine.ahk` 936 + `_main`) ; macOS `dynamic_hotstrings/` ≈ 989 l. (non 1:1) |
| 8 | `windows/modules/llm/api_ollama.ahk` | 1467 | macOS `api_ollama.lua` 824 (parité lâche) |
| 9 | `windows/lib/hotstrings/hotstring_prefix_watcher.ahk` | 1328 | AHK-spécifique |
| 10 | `windows/lib/hotstrings/hotstrings_config_window.ahk` | **1327** | macOS `ui/hotstrings_config_window/` **déjà folder** → AHK rattrape (+ `lib/`→`ui/`) |
| … | (+ 106 fichiers 400-1309 l.) | | `windows/ui/wpm_widget.ahk` 1266 (macOS `ui/wpm/` folder), `macos/lib/healthcheck.lua` 1112 (Win `ui/healthcheck/` folder), … |

> **Correction de rang** : `hotstrings_config_window.ahk` fait **1327** l. (et non 1428) →
> `hotstring_prefix_watcher.ahk` (1328) le **dépasse** ; #9/#10 inversés vs la version
> précédente du guide.

Invariants porteurs (ne pas casser, [§8](#8-risques--foot-guns)) :
- `gestures.ahk` hotkeys top-level `^#+F1::..^#+F10::` ([`:1805-1814`](../static/ergopti_plus/windows/modules/gestures.ahk#L1805)). ⚠️ **Nuance `#InputLevel`** :
  `gestures.ahk` ne pose **aucune** directive `#InputLevel` (ses 3 mentions sont des
  commentaires) ; il est inclus à [`ErgoptiPlus.ahk:823`](../static/ergopti_plus/windows/ErgoptiPlus.ahk#L823), **après** `#InputLevel 0` (`:814`)
  et **avant** le `#InputLevel 2` suivant (`:1090`). Le commentaire inline de `gestures.ahk`
  affirme que le parent met le niveau 2 avant l'include — **conflit avec le niveau observé (0)**.
  → à **trancher par un reload-test live** (le headless ne couvre pas ces hotkeys).
- `keylogger.ahk` doit rester le **1er include ENGINE** keylogger ([`ErgoptiPlus.ahk:242`](../static/ergopti_plus/windows/ErgoptiPlus.ahk#L242)) ;
  le sidecar `keylogger_app_categories.ahk` (`:241`) le précède mais ne porte pas l'état global.
- `hotstring_engine_main.ahk` partage les globals `HSE_*` avec `hotstring_engine.ahk`
  (adjacence `ErgoptiPlus.ahk:183-184`).

### 2.5 SOLID & couplage — chiffres clés

| Mesure | Valeur | Source |
|---|---|---|
| Sites `Features[` **production** AHK (ripgrep) | **294 / 29 fichiers** (modules 187/9, lib 58/10, ui 37/9, entrée 12/1 ; pire : `hotstrings.ahk`=96, `altgr.ahk`=23, `path_translator.ahk`=23, `win.ahk`=20) | Grep `Features\[` (exclut tests) — confirme [REFACTOR_PLAN.md:74](REFACTOR_PLAN.md#L74) |
| `if`-blocks `Features[…]{LoadHotstringsSection}` hand-maintained | 34 dans [`hotstrings.ahk:66-1002`](../static/ergopti_plus/windows/modules/hotstrings.ahk#L66) | violation **O** |
| Ports avec test de contrat **comportemental** | ✅ **20 / 20 macOS** (20 `describe` blocks, [`test_adapter_contract_vectors.lua:34-915`](../static/ergopti_plus/macos/tests/unit/test_adapter_contract_vectors.lua#L34)) ; **18 / 20 AHK** (manquent KeyboardHook, TooltipRenderer) ; vecteurs encore *hand-mirrored* du JS (`:17`) | étendu par 5 commits (`4db56c273`…`57fa6a85b`) |
| Ratchet OS macOS `hs.*` (hors `adapters/`) | **918 / 950** (32 de marge) | [`test_port_adapter_coverage.lua:243`](../static/ergopti_plus/macos/tests/meta/test_port_adapter_coverage.lua#L243) (comptage `:365`, motif `%f[%w]hs%.`) |
| Ratchet OS macOS `io.open`/`os.execute` | **70 / 70 — ZÉRO marge** | idem `:244` |
| OS direct AHK **hors `adapters/`, NON gardé** | **117 `DllCall` + 21 COM + 36 `FileRead`** | `windows/{modules,lib}` ; le garde AHK ne scanne que `_shared/` JS ([`test_port_adapter_coverage.ahk:216,222`](../static/ergopti_plus/windows/tests/meta/test_port_adapter_coverage.ahk#L216)) |
| Fonctions-dieu (SRP) | `handle_key()` 384 l. ([`keylogger/init.lua:448`](../static/ergopti_plus/macos/modules/keylogger/init.lua#L448)), `onKeyDownRaw()` 284 l. ([`keymap/init.lua:592`](../static/ergopti_plus/macos/modules/keymap/init.lua#L592)) | |
| Fallback `if x == nil then x =` (macOS modules) | 2 ([`api_common.lua:104`](../static/ergopti_plus/macos/modules/llm/api_common.lua#L104) `=300`, `gestures/init.lua:375` `=true`) | violation §5.4 |

**Contredit une hypothèse du prompt** : les 3 drivers implémentent **les 20 ports** (Win 20,
Linux 20, **macOS 23 fichiers = 20 ports + 3 adapters helpers OS** `json_codec/shell_runner/toml_cache` ;
Linux = sous-ensemble 1:1 par nom). Le trou Liskov n'est **plus** « 11 ports sans vecteurs »
mais « 2 ports AHK + vecteurs non dérivés de la SSoT ». La doc
[`architecture.md`](../static/ergopti_plus/docs/architecture.md) **a été régénérée** (commit `d1c48b9ec`) et dessine désormais bien
les 20 ports HS + 20 AHK (arêtes `:95-136`) — la mention « 13 ports HS » est obsolète, et
`:100` est en fait une arête **AHK** (`P_HttpClient → AHK_http_client`).

### 2.6 Linux — driver partiel (état)

`linux/` = **4303 l.** prod (27 fichiers), **20 adapters** (sous-ensemble 1:1 macOS par nom ;
macOS = superset 23 — les 3 non-portés sont `json_codec`/`shell_runner`/`toml_cache`),
`modules/{hotstrings,keylogger}`, `bin/`, `tests/`. **Pas** de `lib/`, `ui/`, `data/`,
`_generated/`. **0 site `Features[`** → **pas de surface de crash brute** (répond à la décision
maintainer #6). Cruft à gitignorer : `linux/__pycache__/` ; `linux/vendor/` n'a qu'un
`README.md` placeholder. Ne **pas** forcer le miroir complet : l'absence de `ui/`/`_generated/`
est par conception.

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
- **Obj** : aligner la doc sur le code réel. **Preuve** : (a) `architecture.md` est **déjà
  à jour** (régénérée `d1c48b9ec`, 20 ports HS dessinés) — **ne pas** la régénérer pour
  « 13 ports » ; (b) [`SCHEMA.md:185`](../static/ergopti_plus/_shared/SCHEMA.md#L185) sur-attribue `windows/data/tap_hold/defaults.toml`
  aux **deux** drivers — **faux** : macOS lit `karabiner/data/tap_hold_keys.json` +
  `karabiner/defaults.lua` (le générateur ne référence aucun `defaults.toml`) ; (c)
  [`macos/tests/README.md:47`](../static/ergopti_plus/macos/tests/README.md#L47) garde encore `cd static\drivers\hammerspoon` (bloc PowerShell
  **manqué** par le commit de migration `a3590e6`) ; (d) `REFACTOR_PLAN.md:38` « adapters/ 20
  exactement » vs `:96` « isolation OS » (utiliser `:96`).
- **Action** : scoper `SCHEMA.md:185` au driver AHK ; corriger `README.md:47` →
  `static\ergopti_plus\macos` ; aucune régénération de `architecture.md` requise.
- **Test** : `test:js` (drift gate) reste vert. **Vérif** : `npm run test:js`.
- **Diagnostic d'échec** : N/A (doc). **Rollback** : revert. **Blast** : nul.

**T0.2 — Re-confirmer la baseline verte (geler la DoD)** *(prolonge P2)*
- **Obj** : pinner les compteurs avant tout déplacement. **Preuve** : [REFACTOR_PLAN.md:19](REFACTOR_PLAN.md#L19).
- **Action/Vérif** : `AutoHotkey64 /ErrorStdOut run_all.ahk --dry-run` (exit 0), idem sans
  `--dry-run`, `lua macos/tests/run.lua`, `npm run test:js`, `npm run test:ahk-encoding`.
  Noter les counts exacts → chiffres de la [§9 DoD](#9-definition-of-done). **Blast** : nul.

### Tier 1 — Low risk (test-only, fail-fast, renommages frontend-déjà-partagé)

**T1.1 — Ratchet de pureté OS côté AHK** *(NOUVEAU ; symétrise le garde macOS)* ⭐ *gain max / risque min*
- **Obj** : garder les appels OS hors `adapters/` côté AHK comme macOS le fait. **SOLID-D.**
- **Preuve** : 117 `DllCall` + 21 COM + 36 `FileRead` non gardés ; `test_port_adapter_coverage.ahk:222`
  ne scanne que `_shared/` JS.
- **Action** : étendre le test pour compter `DllCall|ComObject|FileRead` dans
  `windows/{modules,lib}` (hors `adapters/`), **baseline = comptes actuels** (117/21/36) avec
  TODO-vers-le-bas (un baseline figé est légitime ; §5.6 interdit le code mort, pas un seuil).
- **Test** : `test_ahk_os_purity_ratchet.ahk` — rouge si on ajoute un `DllCall` hors adapter,
  vert au baseline (encode la cause : « nouvel appel OS non isolé »).
- **Vérif** : dry-run exit 0 + suite + `test:ahk-encoding`. **Diagnostic d'échec** : le message
  nomme fichier+compte (« +1 DllCall hors adapters/ dans modules/X.ahk ») → router via le port.
  **Rollback** : retirer le test. **Blast** : faible (test-only).

**T1.2 — Migrer les ~144 tests *location-pinned* vers les helpers move-resilient** *(prolonge le durcissement P4/P5)* ⭐
- **Obj** : qu'un déplacement de fichier **ne casse plus aucun test**. **Douleur n°2.**
- **Preuve** : ~144 `FileRead`-de-source via `_XXX_ReadSource(rel)` (sur 156 sans helper) ;
  helpers déjà fournis `test_framework.ahk:157-218`.
- **Action** : remplacer `_XXX_ReadSource("modules/gestures.ahk")` → `_DriverSourceConcat()`
  ou `_DriverFuncBody("Fn")` (assertions inchangées). Mécanique, par lots. Préserver les ~12
  `FileRead` de **fixtures** (`.tsv`), légitimes.
- **Test** : les tests migrés eux-mêmes ; + un **meta-test unique** asserte « aucun
  `FileRead` d'un chemin source codé en dur dans `tests/` ».
- **Vérif** : dry-run + suite (count inchangé) + `test:ahk-encoding`. **Diagnostic d'échec** :
  meta-test rouge → « FileRead source-pinné réintroduit dans test_X.ahk:L ». **Rollback** : par
  lot. **Blast** : moyen (réécriture par fichier, assertions identiques).

**T1.3 — Finir le gabarit de message d'échec (asserts nus)** *(prolonge P2 — l'outillage est déjà livré)*
- **Obj** : attendu/obtenu sur **tout** assert. ✅ Le `path:line` du test, le filtre `--only`
  et la ligne `replay:` **existent déjà** côté AHK ; **reste uniquement** le rendu de valeur.
- **Preuve** : §2.2 ; 2091 `Assert(` nus + cas `AssertThrows()` sans valeur ; côté macOS/Linux,
  ~406 `assert_true` nus.
- **Action** : (a) AHK — convertir `Assert(cond, msg)` vers une forme qui rend l'expression
  testée (ou bannir le nu via le garde existant `test_runner_failure_ergonomics`) ; (b)
  macOS/Linux — `assert_true` rend l'actual + (option) filtre `run.lua arg[1]` + ligne `replay:`.
- **Test** : `test_framework_failure_format.ahk` / `test_runner_replay.lua` — un échec simulé
  contient `expected:`, `actual:`, `at:`, `replay:`.
- **Gabarit mandaté** :
  ```
  not ok / FAIL  <test nommé par comportement, ex. "SFD_IsSecureApp returns 0 for unknown app">
      expected: <E>
      actual:   <A>
      at:       <test_file>:<line>      (déjà fourni côté AHK via _TestCallSite)
      replay:   AutoHotkey run_all.ahk --only "<name>"   |   lua tests/run.lua "<name>"
  ```
- **Vérif** : suites vertes, exit-code CI préservé. **Diagnostic d'échec** : méta. **Rollback** :
  additif. **Blast** : faible-moyen (runners partagés, couverts par leurs propres tests).

**T1.4 — Combler les 2 ports AHK + dériver les vecteurs de la SSoT** *(prolonge ADR-006 ; périmètre réduit)*
- **Obj** : un port mal implémenté **échoue en CI, pas au clavier**. **SOLID-L.** ✅ 20/20 macOS +
  18/20 AHK déjà couverts.
- **Preuve** : manquent KeyboardHook + TooltipRenderer côté AHK ; vecteurs encore « hard-coded
  mirroring the JS source » ([`test_adapter_contract_vectors.lua:17`](../static/ergopti_plus/macos/tests/unit/test_adapter_contract_vectors.lua#L17)).
- **Action** : ajouter les 2 sections AHK manquantes ; **puis** exposer `contractTestVectors()`
  dans chaque `_shared/core/ports/*.spec.js` comme source exécutée, chargée par un loader mince
  des deux côtés (élimine la dérive hand-mirror).
- **Test** : les vecteurs partagés tournent sur **chaque** adapter (même corpus).
- **Vérif** : `test:hs` + suite AHK + `test:port-compliance`. **Diagnostic d'échec** : « adapter
  crypto.lua sha256 ≠ vecteur attendu » → comportement, pas structure. **Rollback** : test-only.
  **Blast** : faible (aucun code prod).

**T1.5 — Renommer les contrôleurs webview `flat → ui/<window>/init`** *(prolonge P5 §131,133)* ⭐ *win le moins cher*
- **Obj** : symétrie de chemin pour 5 fenêtres. **Preuve** : `_shared/ui/` héberge déjà
  leurs assets web 1:1 (`index.html`+JS+`style.css` ; `metrics_typing` = **9 fichiers JS** +
  `i18n.js` partagé = 10 includes) pour `changelog, download_window, metrics_apps, metrics_typing,
  model_browser`, résolus par les deux drivers
  ([`macos/ui/model_browser/init.lua:47`](../static/ergopti_plus/macos/ui/model_browser/init.lua#L47), [`windows/ui/changelog_window.ahk:399`](../static/ergopti_plus/windows/ui/changelog_window.ahk#L399)).
- **Action** : `windows/ui/changelog_window.ahk → ui/changelog/init.ahk`,
  `llm_model_browser.ahk → ui/model_browser/init.ahk` (le frontend ne bouge pas ; le path
  `file://` lit déjà `_SharedDir`).
- **Test** : migrer les meta-tests via `_DriverDirConcat("ui/changelog")` ; un test asserte
  que le path résolu **existe** (cf. foot-gun wpm_widget, [PROJECT_MEMORY.md:1549](PROJECT_MEMORY.md#L1549)).
- **Vérif** : dry-run + suite + `test:ahk-encoding` ; graphe d'`#Include` résout.
  **Diagnostic d'échec** : « ui/changelog/index.html introuvable au chargement ».
  **Rollback** : renommer en arrière. **Blast** : faible (frontend partagé, pas de hotkey).

**T1.6 — Defaults restants → `_shared/` + drift test** *(prolonge P7, sous-étape low-risk ; gros morceau déjà fait)*
- **Obj** : zéro dup §5.2/§5.4. **Preuve** : §2.3 (WPM, delays, `profiles.lua 'fr'` = ✅ déjà
  faits). **Restent** : `language 'fr'` Windows (≥4), 41 `tonumber(x) or <litt>` LLM macOS (temperature).
- **Action** : (a) `language 'fr'` Windows → lire `manifest script.locale` (le default
  `features_manifest.ahk:46` est légitime) ; (b) LLM temperature → lire `defaults.json` fail-fast,
  supprimer les `or 0.1`. **Exclure** `max_tokens` et `tap_hold` (→ Tier 3 / décisions).
- **Test** : `test_llm_no_inline_temp_fallback.lua` (rouge si un `or 0.1` revient) +
  **cross-driver drift test** (la valeur lue par AHK == celle lue par HS depuis la clé partagée).
- **Vérif** : `test:hs` + suite AHK + `test:no-fallbacks`. **Diagnostic d'échec** : « temperature
  fallback réintroduit » / « locale AHK≠HS ». **Rollback** : par item. **Blast** : faible.

### Tier 2 — Medium (splits miroir via le pipeline prouvé)

> **Pipeline réutilisé** ([REFACTOR_PLAN.md:108](REFACTOR_PLAN.md#L108)) : extraction PowerShell qui remplace le
> bloc **en place** par un `#Include` (garantit UTF-8 BOM+CRLF, préserve l'ordre boot et
> les `global X :=`) → `test:ahk-encoding` → dry-run exit 0 → suite → `_DriverDirConcat`
> pour les meta-tests. **Ne pas inventer un autre pipeline.**

**T2.1 — Split miroir du keylogger central (les deux drivers ensemble)** *(prolonge P5/P6)*
- **Obj** : SRP. **Preuve** : `keylogger.ahk` 1867 (16 sections, 0 `#Include`) ↔
  `keylogger/init.lua` 1609 — même forme « foldé mais central monolithe » ; fonction-dieu
  `handle_key` 384 l. (`init.lua:448`).
- **Action** : AHK → `keylogger_storage/_sql/_hotpath/_secure_field.ahk` ; macOS → extraire
  `event_tap.lua` + `watchers.lua`. L'index garde l'état global `Keylogger`/`CoreState` et reste
  **1er include ENGINE** (`ErgoptiPlus.ahk:242`).
- **Test** : tests behavior keylogger existants (filet d'équivalence) + 1 test pinnant
  l'ordre de dispatch de `handle_key`. **Vérif** : dry-run + suite + encoding + `test:hs`.
- **Diagnostic d'échec** : tests keylogger behavior rouges = comportement de capture cassé.
  **Rollback** : ré-inline. **Blast** : moyen-haut (hot path ; ordre d'include).

**T2.2 — Sortir l'UI de `lib/` + flat→folder (rattrapage par driver)** *(prolonge P5 §131 / P6)*
- **Obj** : `lib/ = aucun UI` ; symétrie. **Preuve** : `windows/lib/hotstrings/hotstrings_config_window.ahk`
  (1327, UI dans `lib/`) ; `windows/ui/wpm_widget.ahk` (1266 flat) ; `macos/lib/healthcheck.lua`
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
- **Obj** : `handle_key()` (384 l.)/`onKeyDownRaw()` (284 l.) deviennent des dispatchers. **Preuve** : §2.5.
- **Action** : extraire `should_skip_event()` (chaîne de gardes), bookkeeping idle/souris,
  sous-handlers key-up/key-down. **Pur refactor**, testable sur le stub `hs`.
- **Test** : test pinnant l'ordre de dispatch (rouge avant/vert après). **Vérif** : `test:hs`.
- **Diagnostic d'échec** : ordre de dispatch cassé = test nommé. **Blast** : moyen (hot path).

**T2.5 — Taxonomie de test miroir AHK (un-defer P2)** *(prolonge/dé-reporte [P2 §87](REFACTOR_PLAN.md#L87))*
- **Obj** : `tests/unit/<area>/` path-mirror (modèle macOS). **Preuve** : arbre AHK plat (§2.1).
- **Action** : déplacer les ~82 tests racine + meta vers `tests/unit/modules/<feature>/`, en
  **réécrivant `run_all.ahk` `#Include` en lockstep**, staged **derrière**
  `test_run_all_include_integrity.ahk` + dry-run.
- **Test** : `test_run_all_include_integrity` (asserte que tout `test_*.ahk` est inclus).
- **Vérif** : dry-run + suite (count identique). **Diagnostic d'échec** : « test_X non inclus
  dans run_all ». **Rollback** : git revert (un seul commit). **Blast** : moyen-haut (réécrit le
  graphe d'include — d'où le staging ; cf. [§7](#7-décisions-maintainer-requises)).

### Tier 3 — High / décisions maintainer requises ([§7](#7-décisions-maintainer-requises))

**T3.1 — `gestures.ahk` flat → folder miroir** *(P5 §130, déjà flaggé ⚠️)*
- **Preuve** : 2076 l. ; hotkeys top-level `^#+F1::` (`:1805`) — la **dépendance `#InputLevel`
  est non résolue** (include au niveau 0 observé vs commentaire affirmant niveau 2, cf. §2.4) →
  régression visible seulement au reload utilisateur ; 23 tests référencent `Gesture*`.
  **Action** : miroir `modules/gestures/{init,actions,window_cycle,mouse_hold,dispatch,config}.ahk`,
  **hotkeys conservés dans l'index** à la position exacte. **Test** : behavior +
  **reload-test live explicite** (le headless ne couvre pas ; il faut aussi trancher le niveau réel).
  **Blast** : **HAUT**.

**T3.2 — Consolider la couche layout → `windows/modules/keymap/`** *(P5 §132)*
- **Preuve** : pas de `windows/modules/keymap` ; logique éparpillée `modules/layout.ahk` (901) +
  `lib/layout/*` ; macOS = `modules/keymap/`. **Action** : converger **vers macOS**.
  **Blast** : **HAUT** (hotkeys top-level, `#InputLevel`). **Décision** : `lib/keymap/` vs
  `modules/keymap/` (cf. [REFACTOR_PLAN.md:166](REFACTOR_PLAN.md#L166)).

**T3.3 — Hotstrings engine `lib/ → modules/` + nom unifié** *(prolonge P5)*
- **Preuve** : engine Win dans `lib/hotstrings/` vs macOS `modules/dynamic_hotstrings/` (couches
  opposées, noms différents). **Décision** : nom. **Blast** : **HAUT** (hot-path, ordre d'include).

**T3.4 — `hotstrings.ahk` : 34 `if`-blocks → boucle data-driven** *(SOLID-O)*
- **Preuve** : 96 sites `Features[` + 34 `LoadHotstringsSection` hand-maintained
  ([`:66-1002`](../static/ergopti_plus/windows/modules/hotstrings.ahk#L66)) ; macOS data-driven. **Action** : itérer les groupes déclarés au
  manifeste. **Test** : « un nouveau groupe manifeste-only se charge **sans** édition de code ».
  **Blast** : **HAUT** (load path hot).

**T3.5 — Accessor fail-fast des `Features[`** *(P4 reporté → décision)*
- **Preuve** : **294** sites prod / 29 fichiers, dont profonds
  `Features["hotstrings"]["distances_reduction"]["qu"]["enabled"]`. [REFACTOR_PLAN.md:74](REFACTOR_PLAN.md#L74) l'a reporté.
  **Décision maintainer** sur la forme + le timing (dans la réécriture d'entrée, vérifiable).
  **Blast** : **HAUT**.

**T3.6 — Mutualisation profonde** *(P7, sous-étape par sous-étape)*
- Logger → `_shared/lua/logger` via `set_sink()` ; tooltip AHK lit
  `_shared/modules/tooltip/constants.toml` (⚠️ alpha per-platform). **`tap_hold` et `max_tokens`
  = `feat`, pas refactor** (voir [§6](#6-defaults--ssot) / [§7](#7-décisions-maintainer-requises)). **Blast** : **HAUT**, livré isolément avec
  snapshot avant/après.

---

## 5. Chantier testabilité (transversal · priorité 1)

> **Cadre.** Ce chantier **dé-reporte** explicitement l'item [P2 §87-88](REFACTOR_PLAN.md#L87) (« taxonomie
> miroir + auto-découverte »), staged derrière `test_run_all_include_integrity` + dry-run vert.
> Il ne touche **pas** le ratchet de pureté ([`test_port_adapter_coverage`](../static/ergopti_plus/macos/tests/meta/test_port_adapter_coverage.lua)) ni les helpers
> de scan (346 tests en dépendent). **Mise à jour majeure** : l'*outillage* de diagnostic
> (pointer le test, `--only`, `replay:`) est **déjà livré côté AHK** — le travail résiduel
> est la **sémantique** (introspection→behavior + asserts nus), pas l'infrastructure.

### 5.1 Taxonomie cible

| Tier | Définition | Aujourd'hui | Cible |
|---|---|---|---|
| **Behavior** | appelle la fonction, asserte la sortie | 69 AHK | **majorité** |
| **Contrat** | vecteurs `*.spec.js` sur chaque adapter | ✅ 20/20 macOS, 18/20 AHK | **20/20 partout** (T1.4) + vecteurs dérivés |
| **Scan-source move-resilient** | `_Driver*` helpers, invariant structurel | 190 AHK | **centralisé** (5.3) |
| **Scan-source location-pinned** | `FileRead` chemin fixe | **~144 AHK + ~185 macOS (tree-wide)** | **0** (T1.2) |

### 5.2 Convertir les location-pinned → 0 (mécanique, T1.2)
`_XXX_ReadSource("modules/gestures.ahk")` → `_DriverFuncBody("Fn")` (AHK) ;
`io.open(DRIVER_ROOT.."modules/X.lua")` → un `driver_concat()` macOS (miroir de
`_DriverSourceConcat`). **Métrique : un déplacement de fichier ne casse plus aucun test.**

### 5.3 Un seul méta-test déclaratif pour les invariants structurels
Au lieu de N assertions file-pinnées, **une** table déclarative par invariant :
- « tout appel OS vit dans `adapters/` » → c'est déjà le ratchet (ne pas dupliquer ; symétriser
  AHK en T1.1).
- « tout site `Features[…]` résout contre le manifeste » → déjà
  [`test-feature-read-sites.js`](../tools/test/test-feature-read-sites.js) — **généraliser l'esprit**, pas multiplier.
- Nouveau : « tout module prod a un dossier de test co-localisé » (rendu possible par T2.5).

### 5.4 Contrats dérivés de la SSoT
Chaque **default** (drift test cross-driver, T1.6) et chaque **port** (vecteurs dérivés des
`*.spec.js`, T1.4) couvert par un test **dérivé** de `manifest.toml` / `*.spec.js` → un défaut
qui diverge ou un port non conforme **échoue au CI, pas au clavier**.

### 5.5 Convention de nommage + gabarit
- **Nom = comportement** : `expands "tdej" -> "déjeuner" after a word boundary`, pas
  `test_expander_file_has_function`.
- **Gabarit de message** mandaté (T1.3) : `expected / actual / at:<test:line> / replay:<cmd>`
  (la partie `at:` + `replay:` est **déjà fournie côté AHK** — reste le `expected/actual`).
- **Bannir** `Assert()`/`AssertThrows()` sans valeur (**2091** `Assert(` AHK) et `assert_true(x)` nu (~406 macOS).

### 5.6 Métrique de réussite
- Ratio behavior:scan-source **inversé** sur la part convertible (cible : behavior ≥ scan-source).
- **0** test location-pinned (un `git mv` ne casse aucun test).
- **20/20** ports avec vecteurs comportementaux **dérivés** (pas hand-mirror) sur les 2 drivers.
- Un rouge ⇒ le dev lit *comportement attendu/obtenu + `path:line` du test + `replay:`* — **< 5 min**.

---

## 6. Defaults & SSoT

**Mécanisme unique de consommation** (déjà la norme, à étendre) : le driver **lit** le défaut
partagé (`_shared/modules/<f>/{defaults.toml,constants.toml,*.json}`) via un loader prenant la
**cible en paramètre** ; il ne le **re-déclare jamais** ; tout fallback `if x == nil then x = …`
est une violation §5.4 (garde : [`test:no-fallbacks`](../tools/test/test-no-fallback-literals.cjs)).

| Défaut | Décision | Étape | Drift test |
|---|---|---|---|
| Timings, hotstring global delay/color, **WPM consts**, **dynamic-hotstrings 2.0**, **`profiles.lua 'fr'` macOS**, LLM toggles/inference | ✅ **déjà `_shared/`, lus, fail-fast** — ne rien faire | — | déjà testé |
| `language 'fr'` **Windows** (≥4) | manifeste `script.locale` | T1.6 | read-site test |
| LLM temperature 0.1 (41 `tonumber or` macOS) | lire `defaults.json` / fail-fast | T1.6 | drift test |
| **`max_tokens` 150/256/50** | **DIVERGENT → `feat`** : choisir la valeur/backend **avant** `inference.json` | [§7](#7-décisions-maintainer-requises) | post-décision |
| **`tap_hold` (per-key vs global 1000 ms)** | **modèles divergents → `feat`** ; rester driver-specific | [§7](#7-décisions-maintainer-requises) | — |
| Gesture sensitivity 3.5 | macOS-local (légitime) | hygiène §5.1 opt. | — |

**Le drift redevient impossible** quand un test compare la valeur **consommée** à la SSoT
(cross-driver) et casse sinon — généralise l'esprit de `test:manifest-parity`/`priority-parity`.
⚠️ Tout rapatriement d'un défaut potentiellement déjà divergent exige une **preuve d'équivalence
byte** d'abord (sinon `feat`, cf. avertissement P7 `tap_hold`). Le garde macOS-only
`test_no_duplicate_defaults.lua` (WARN seulement) ne suffit pas → drift test cross-driver dur.

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
| 12 | **Taxonomie test AHK (T2.5)** | déplacer ~415 tests + réécrire `run_all` vs garder plat | faire, staged derrière include-integrity | MOYEN-HAUT |
| 13 | **`#InputLevel 2` de `gestures.ahk`** | confirmer par reload-test que les hotkeys dépendent bien du niveau (commentaire) ou non (include observé au niveau 0) | mesurer avant de splitter (T3.1) | HAUT |

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
  compile**. → préserver l'ordre ; `gestures.ahk` `^#+F1::` non exercé headless. ⚠️ **De plus,
  le niveau réel sous lequel `gestures.ahk` s'inclut n'est pas confirmé** (include observé au
  niveau 0 à `ErgoptiPlus.ahk:823` vs commentaire affirmant 2) → **reload-test** avant split (T3.1/déc.13).
- **Ratchet de pureté** ([`test_port_adapter_coverage.lua:243`](../static/ergopti_plus/macos/tests/meta/test_port_adapter_coverage.lua#L243)) : compte (motif `%f[%w]hs%.`, frontière
  de mot, commentaires inclus, [PROJECT_MEMORY.md:187](PROJECT_MEMORY.md#L187)) au `:365`. **`io.open`/`os.execute` = 70/70 —
  ZÉRO marge** : tout nouvel appel OS hors `adapters/` casse le build → router via adapter.
  `hs.*` = **918/950** (32 de marge).
- **`adapters/` = isolation OS** (20 ports **+** helpers OS), **pas** « 20 pile ». Sortir
  `json_codec`/`shell_runner`/`toml_cache` de `adapters/` est **rejeté** ([REFACTOR_PLAN.md:96](REFACTOR_PLAN.md#L96)).
- **`init.lua` / entrée = 0 couverture d'exécution** : seul un **parse** la garde
  ([`test_lua_sources_compile.lua`](../static/ergopti_plus/macos/tests/meta/test_lua_sources_compile.lua), [PROJECT_MEMORY.md:1554](PROJECT_MEMORY.md#L1554)). Après tout split touchant l'entrée, `loadfile`/dry-run.
- **`tap_hold` & `max_tokens` divergents** : `feat`, pas refactor (prouver l'équivalence byte sinon).
- **Test path-résolu** : un test qui asserte juste « module ≠ nil » **n'attrape pas** un chemin
  cassé (le module dégrade en silence) — asserter que le fichier a **résolu** (foot-gun wpm_widget,
  [PROJECT_MEMORY.md:1549](PROJECT_MEMORY.md#L1549)).
- **Garde par *forme* de code** : un meta-test qui impose une *écriture* précise peut **cimenter
  un bug** ([PROJECT_MEMORY.md:1569](PROJECT_MEMORY.md#L1569)) — asserter l'**invariant**, jamais une orthographe.
- **Doc qui dérive plus vite que le code** : `architecture.md` régénérable (`gen:diagram`) mais les
  proses (`SCHEMA.md`, `macos/tests/README.md`) sont hand-maintained et **déjà désynchronisées**
  (cf. T0.1). Préférer les artefacts générés aux proses recopiées.
- **Churn du généré** : le drift gate produit un gros diff one-time → **commit dédié**.
- **Ne jamais affaiblir un test** pour faire passer un changement (§5.9) — on renforce le filet.

---

## 9. Definition of Done

Du **guide** (auto-vérifié) :

- [x] Chaque reco adossée à un `path:line` ou un chiffre reproductible — zéro conseil générique.
- [x] Chaque étape : objectif, preuve, action, **test associé** (cause racine), commande de vérif,
      **scénario de diagnostic d'échec**, rollback, blast radius.
- [x] La **priorité n°1 (testabilité)** a sa section ([§5](#5-chantier-testabilité-transversal--priorité-1)) avec métrique cible et plan pour les ~144 AHK +
      ~185 macOS location-pinned + 190 helper-scan ; l'outillage déjà livré est marqué ✅.
- [x] Inventaire **defaults** exhaustif, chaque entrée décidée (manifeste / `_shared` /
      driver-specific) + drift test, items **déjà faits** marqués ✅ ([§6](#6-defaults--ssot)).
- [x] **Table de symétrie** Win↔macOS complète, divergences marquées avec sens de convergence ([§2.4](#24-gros-fichiers--116--400-l-57-ahk--59-lua)/[§4](#4-plan-priorisé-par-phases)).
- [x] Tous les **gros fichiers** (>400) ont un plan de split miroir ([§2.4](#24-gros-fichiers--116--400-l-57-ahk--59-lua)).
- [x] Le guide **ne contredit pas** `REFACTOR_PLAN`/`PROJECT_MEMORY`/ADRs ; il les prolonge.
- [x] **Aucune étape ne change le comportement** sauf marquée `feat`/`fix` (`tap_hold`, `max_tokens`).
- [x] Arbitrages irréversibles en **[§7](#7-décisions-maintainer-requises)**, pas tranchés seul.
- [x] Tout est **incrémental, vérifiable, réversible** ; ordre du moins au plus risqué.
- [x] Chiffres **re-vérifiés** (passe 2, 2026-06-21) ; les étapes rendues caduques par l'avancée
      du code sont marquées ✅ DONE plutôt que re-proposées.

**Critère de sortie par étape exécutée** (harnais, [docs/TESTING.md](TESTING.md)) :
`AutoHotkey64 /ErrorStdOut run_all.ahk --dry-run` exit 0 · suite AHK count ≥ baseline ·
`lua macos/tests/run.lua` 0 failed · `npm run test:js` vert · `npm run test:ahk-encoding` vert ·
drift gate (`npm run build:domain`) vert. **Geler ces counts via T0.2 avant de commencer.**
