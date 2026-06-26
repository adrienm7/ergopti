# Audit — Mise en commun maximale & simplification (2026-06-26)

> **Nature.** Rapport d'audit actionnable et priorisé, **sans modification de code**.
> Chaque constat est prouvé par `chemin:ligne` réels. Méthode : 11 investigateurs
> parallèles (un par sous-axe + un dédié à la réouverture des décisions rejetées),
> vérification adversariale des affirmations de suppression, critique de complétude.
> Confronté systématiquement à `docs/REFACTOR_PLAN.md` et `docs/PROJECT_MEMORY.md`.
>
> **Consigne mainteneur intégrée** : « partir d'un état clean, ne pas s'autocensurer,
> réexaminer même les pistes rejetées ». Les rejets passés ont donc été re-soumis à
> l'épreuve du code actuel ; ceux qui tiennent encore sont listés en §4, ceux dont la
> prémisse a bougé sont signalés `REOPEN`.
>
> **À fusionner dans `REFACTOR_PLAN.md`** (mémoire canonique) une fois trié — ce
> fichier est un feeder, pas un concurrent du plan.

---

## 1. Résumé exécutif — meilleures opportunités (valeur/risque)

| # | Opportunité | Axe | Effort | Risque | Gain |
|---|---|---|---|---|---|
| 1 | **Purger 3 entrées fantômes du drift-gate** (`build-domain.cjs`) + drift-gater le vrai `terminators_catalogue.lua` | 2 | S | très bas | tue une fausse-confiance + ajoute une vraie couverture |
| 2 | **Supprimer `_generated/registry.ahk` + `expander.ahk`** (orphelins prouvés) — résout la décision #4 | 2 | S | bas | −565 l / 20 Ko + 2 codegen + 2 npm + 2 steps |
| 3 | **Supprimer le bloc mort `_platform_defaults`** de `defaults.json` (zéro lecteur) | 1 | S | très bas | −12 l, supprime une surface de drift silencieux |
| 4 | **Documenter la frontière `_shared/lua/` (code) vs `_shared/modules/` (data)** | 2 | S | nul | tue la confusion récurrente n°1 du dépôt |
| 5 | **Retirer les micro-shims identité `color_utils`/`text_utils`** (re-export même nom) | 2 | S | bas | −2 fichiers, une seule orthographe de `require` |
| 6 | **Port Ollama `11434` en source unique côté AHK** (macOS le lit déjà) + ratchet | 1 | M | bas | vraie violation §5.2 corrigée + verrouillée |
| 7 | **Compacter l'émetteur `features_manifest.lua`** (2351 l. pour la densité d'AHK 263 l.) | 2 | M | bas | −30-45 Ko committés, 0 comportement |
| 8 | **Splitter `windows/keylogger.ahk`** (1867 l., monolithe vs 10 fichiers macOS) | 2 | L | bas | meilleur ROI lisibilité, rétablit le miroir |
| 9 | **Frontend `_shared/ui/healthcheck/` partagé** (HTML/CSS dupliqué octet-pour-octet) | 1 | L | moyen | −~300 l, ferme une surface de drift cross-driver |
| 10 | **Réparer la fuite de pureté `_shared/lua/toml_codec`** (require macOS-only → Linux a forké son parseur) | 2 | M | moyen* | débloque la convergence Linux |
| 11 | **Extraction i18n des frontends webview** (français en dur dans 20/~30 JS) | 1 | XL | moyen* | localise ~410 lignes UI sur les 2 plateformes |

\* `behavior_change` assumé (texte devient dépendant de la locale ; routage logger/i18n).

**Constat global rassurant.** Le gros du travail de mise en commun est **déjà fait** et
**vérifié** : webviews partagées (FEAT C), menu SSoT (FEAT B), tap_hold unifié (FEAT A),
parseurs certifiés par corpus partagés, locales en parité. Les catalogues de données
(`AXE 1.4`) sont **entièrement propres** (single-source + gate de parité modèle).
Ce qui reste est de la **finition** : quelques orphelins/copies mortes, des god-files
non-miroir, une fuite d'architecture `_shared/lua`, et la dette i18n des webviews.

---

## 2. AXE 1 — Mise en commun (réduire la duplication cross-driver)

### 2.1 UI / webviews

**UI-1 — Le rapport healthcheck est dupliqué octet-pour-octet ; en faire le prochain frontend partagé. `[REOPEN FEAT C]`**
- **Constat.** Les deux drivers rendent DÉJÀ le rapport de diagnostic en webview (WebView2 / `hs.webview`) avec fallback texte natif, mais chacun construit la page depuis son PROPRE générateur HTML/CSS inline. Le CSS et le balisage de table sont dupliqués verbatim. La P5 n'a fait que déplacer le fichier `lib→ui` de chaque côté, jamais unifié la présentation. C'est une conversion « pattern prouvé » que le plan a manquée, pas une idée rejetée.
- **Preuve.** `windows/ui/healthcheck/helpers.ahk:351` `"table{border-collapse:collapse;width:100%;…}"` ≡ `macos/lib/healthcheck.lua:967` même règle ; `helpers.ahk:362` `.ok{color:#1a7f37…}.fail{color:#cf222e…}` ≡ `healthcheck.lua:979` mêmes hex. Générateurs : `helpers.ahk:333-486` (~153 l.) ≡ `healthcheck.lua:950-1110` (~160 l.), mêmes 6 sections depuis un snapshot Map structuré (`core.ahk:83-98`).
- **Proposition.** Créer `_shared/ui/healthcheck/{index.html,script.js,style.css}` ; le host injecte le snapshot en JSON (pattern seed-before-scripts), un seul bouton « copier + fermer ». Cloner le host `changelog` (WebView2 `NavigateToString` déjà utilisé) ; repointer macOS sur les assets partagés. **Libellés en anglais** (diagnostic, `helpers.ahk:330-332` mandate non-i18n) → **pas de pont i18n** = plus simple que les fenêtres déjà livrées.
- **Gain.** −~150 l. HTML/CSS dupliquées/plateforme (~300 l.), un seul rendu, ferme une vraie surface de drift.
- **Risque.** Moyen. Réconcilier les clés snapshot (Windows `os_name/os_build/ahk_version` vs macOS `os_version/hs_version/arch`) ; le frontend doit tolérer les clés optionnelles. Rendu + bouton copie vérifiables **uniquement au reload** (2 plateformes).
- **Effort.** L.
- **Vérif.** dry-run `/validate`, `test:js`, `test:hs`, `test:ahk-encoding` ; **+test de régression §5.9** : les clés JSON consommées par `script.js` existent dans `HealthCheck_Run()` (AHK) et le snapshot macOS. Reload-test des 2 plateformes.

**UI-2/3/4/5 — Inventaire propre, classifications fermées (constats négatifs, ne rien supprimer).**
- Doublons natif/webview (`action_picker.ahk`+`_webview`, `personal_toml_editor.ahk`+`_webview`, `editors.ahk` PII) = **fallbacks vivants** : chaque entrée appelle `_…Web_TryOpen()` puis `return` avant le Gui natif (`action_picker.ahk:81`, `personal_toml_editor.ahk:578`, `editors.ahk:54`). §5.6 satisfait, **rien à supprimer**.
- **WPM widget + tooltip restent natifs** : réexaminé contre le pont prouvé et **maintenu** — le WPM a déjà été réécrit WebView2→GDI+ car un cold-start `msedgewebview2` sur le chemin de frappe coûtait **476 ms/keystroke** (`PROJECT_MEMORY:424-426`) ; tooltip = canvas/GDI+ curseur, même contrainte hot-path. Garde `test_wpm_widget_native_render.ahk`.
- `spotlight` (overlay per-pixel-alpha suivant la souris, pas de twin macOS), `MagicKeyEditor`/`GPTLinkEditor` (micro-modals 10-12 l.), `token_prompt` (macOS-only MLX) = **légitimement spécifiques**.
- `tooltip/llm.ahk` + `tooltip/tooltip_llm.ahk` = **split moteur+API** (P5), pas un doublon mort.

**UI-opt (AXE 2) — Consolider les 3 hosts WebView2 quasi-identiques** (`action_picker_webview.ahk`, `personal_toml_editor_webview.ahk`, `personal_info_editor/init.ahk`) sur un helper de host partagé (`lib/webview_utils.ahk` existe déjà). Effort M, dédup de glue, à confirmer au reload.

### 2.2 Menu

**MS-1 / MS-4 — `menu_manifest.json` est un VRAI SSoT structurel (constats négatifs).** Les deux renderers itèrent les tableaux du manifest et dispatchent par type ; **0 arbre de menu codé en dur** (`manifest_menu.ahk:138`, `manifest_menu.lua:136`). Les god-files menu (`menu_keyboard_layout.lua`, `menu_hotstrings.lua`) ne contiennent **pas** de DATA de menu éligible au manifest — c'est de la glue TIS/install (`ERGOPTI_VARIANTS`, `ACTIVE_LAYOUTS_PY`) ou des libellés dérivés d'un SSoT existant (`hotstrings_config`, `text_acts.WRAP_GROUPS`).

**MS-2 — Libellés non-i18n résiduels (macOS, panneaux LLM).**
- **Constat/Preuve.** 5 littéraux `title="…"` dans `macos/ui/menu/menu_llm/{backend_panel,models_manager_mlx}.lua` + un fallback anglais algorithmique `menu_shortcuts.lua:61` (`"Layer + Scroll"` + Title-case par défaut). AHK = 0 littéral accentué dans les builders de menu.
- **Proposition.** Router ces libellés via `i18n.get()`/`t()`. Hygiène **macOS-locale** (AHK n'a pas de couche MLX), pas une parité.
- **Gain / Risque / Effort / Vérif.** −5-7 chaînes non traduites ; bas ; S ; `audit-translations` + `test_locale_json_valid` attrapent les nouvelles clés. `needs_verify` : confirmer que les 5 littéraux sont des titres UI (pas des ids/noms de modèles à garder verbatim).

**MS-3 — Pont de résolution : 2 petits doublons §5.2 dans une réimplémentation par-langage légitime. `[partiel behavior_change]`**
- **Constat.** Le **loop de dispatch** (`manifest_menu.ahk` 328 l. / `manifest_menu.lua` 269 l.) est intrinsèquement par-langage (AHK↔Lua, aucun runtime partagé) → **KEEP**. Mais : (a) la décoration de titre de section `"— X —"` est codée en dur des DEUX côtés (`macos/lib/i18n.lua:279` + `windows/lib/menu_helpers.ahk:212`) ; (b) la **chaîne de substitution dynamique** est asymétrique — AHK applique `(N)`/`{date}` via le manifest (`menu_engine.ahk:35-39`), macOS réimplémente la dérivation de libellés de raccourcis dans `pretty_key` avec des cas codés en dur (`menu_shortcuts.lua:56-62`).
- **Proposition.** (a) Déplacer la décoration `— X —` dans la couche manifest/locale (une seule source). (b) Traiter l'asymétrie comme un **gap de parité** : macOS résout les libellés de raccourcis depuis la clé i18n du manifest (comme AHK), `pretty_key` en fallback uniquement pour les ids absents.
- **Gain / Risque / Effort / Vérif.** −1 doublon §5.2 + ferme un gap de parité ; (b) `behavior_change=true` (peut changer des chaînes affichées) ; M ; `test-menu-manifest.cjs` + nouveau test macOS « `pretty_key` seulement hors-manifest ». `needs_verify` : énumérer les ids couverts par `pretty_key` vs ceux ayant une clé i18n.

### 2.3 Valeurs par défaut (§5.2)

**DD-1 — Port Ollama `11434` codé en dur côté AHK (3 endroits), jamais lu depuis la source partagée. `[vraie violation §5.2]`**
- **Constat.** `llm_ollama_port=11434` est partagé dans `defaults.json:25` ; macOS le lit correctement (`api_ollama.lua:53-61`, `11434` seulement en fail-fast loggé). AHK code en dur `global LLM_OLLAMA_PORT := 11434` (`api_ollama.ahk:42`), **omet la clé** dans `llm_defaults.ahk:190-191`, et la re-déclare au menu (`_index.ahk:99`).
- **Proposition.** Ajouter `llm_ollama_port` à la liste Numbers de `llm_defaults.ahk` ; remplacer le littéral `:= 11434` par un sentinelle réassigné au boot depuis `LLM_Defaults` (pattern `LLMApiLoadTimings()` `api_ollama.ahk:63-69`) ; seeder `_index.ahk` via `LLM_Menu_ApplySharedDefaults()`.
- **Gain / Risque / Effort / Vérif.** −2 déclarations AHK redondantes ; bas (ordre de boot établi par le précédent timings) ; M ; `test_llm_api_ollama.ahk:413-436` reste vert. `needs_verify` : `grep 11434` les 3 fichiers AHK. **Recommandé** : ajouter un ratchet (comme `test:max-tokens-single-source`) — actuellement le port AHK n'est couvert par aucun gate.

**DD-2 — Bloc mort `_platform_defaults` dans `defaults.json` (zéro lecteur, copie drift-prone).**
- **Constat/Preuve.** `defaults.json:27-38` `_platform_defaults` re-énonce les modèles/backends par plateforme que les drivers codent DÉJÀ en dur (`llm_defaults.ahk:36-39`, `init.lua:51-57`). **Aucun driver ne le lit** (`grep _platform_defaults` → seule la ligne JSON). C'est une copie en forme de doc qui peut driver en silence.
- **Proposition.** **Supprimer** le bloc (chemin `behavior_change=false`, recommandé) — les valeurs sont légitimement par-plateforme et vivent en code ; documenter dans `defaults.json` qu'elles vivent dans les drivers.
- **Gain / Risque / Effort / Vérif.** −12 l., tue le drift silencieux ; très bas (rien ne le lit) ; S ; `grep _platform_defaults` = 0 avant suppression, `test_llm_defaults.ahk` reste vert.

**DD-3/4/5 — Constats négatifs (déjà single-source + souvent ratchetés).** Scalaires/arrays LLM partagés lus-une-fois sur les 2 drivers avec fail-fast (`llm_defaults.ahk:180-223`, `init.lua:91-118`) ; timings via `_shared/modules/timings/constants.toml` (fail-fast, sentinelle-0) ; tooltip `constants.toml` ; constantes canoniques `DEFAULT_MAX_TOKENS=150`/`CONTEXT_TAIL_WORDS=5` dans `prompt_builder.ahk` (généré), protégées par `test:max-tokens-single-source` + `test:temperature-single-source` + `test:no-fallbacks`. `debounce_ms` (500) = une valeur consommée en ms (AHK) / ÷1000 (macOS), **pas** un doublon. tap_hold toujours unifié, aucun nouveau drift.

### 2.4 Données & catalogues — **AXE entièrement propre (constats négatifs)**

Tous single-source avec lecture par-plateforme — **rien à faire** :
- **wrap_symbols** : `windows/lib/wrap_symbols_config.ahk` lit le MÊME `_shared/modules/wrap_symbols/wrap_symbols.json` que macOS ; c'est un loader+merge avec un fallback ASCII d'urgence minimal, pas un catalogue parallèle.
- **keycodes** : `macos/lib/keycodes.lua` = shim metatable (`setmetatable({}, {__index=require("keycodes")})`, 0 constante), canonique dans `_shared/lua/keycodes/init.lua` ; Windows n'a aucune table. `azerty.json` = dataset distinct de l'UI metrics, pas un doublon.
- **gestures** : `_shared/modules/gestures/actions.toml` (778 l.) = source unique des noms/ordre/`platform` ; les deux drivers la parsent (`init.ahk:972`, `actions.lua:667`) ; `GESTURE_ACTIONS`/`sg()` ne tiennent que des closures par-plateforme.
- **priority.json** = source unique **avec gate de parité** `test:priority-parity` (lit le JSON, asserte que les constantes AHK+Lua l'égalent) → **le pattern modèle** à généraliser si durcissement souhaité.

### 2.5 i18n

**I18N-1 — `.tsv` correctement gitignorés (constat négatif).** 21 `.json` trackés, 0 `.tsv` (cache self-healing, `.gitignore:97`). **Pas de régression de duplication.**

**I18N-2 — `tools/locale/check_locales.py` orphelin du CI, MAIS pas supprimable. `[vérif adversariale : suppression REFUTÉE]`**
- **Constat.** La parité des clés est PARFAITE (21 locales = 2208 clés, 0 drift) et **réellement** gardée en CI par `windows/tests/meta/test_locale_json_valid.ahk:141-173` (`run_all.ahk:419`, job `test-ahk`). Mais `PROJECT_MEMORY:44,984-985` + le docstring du script prétendent que la parité est imposée par `check_locales.py` via `.github/workflows/test_locales.yml` — **ce workflow n'existe pas**, et `check_locales.py` n'est invoqué par aucun CI/husky/npm.
- **Vérif adversariale.** La reco initiale « supprimer le script (§5.6) » est **réfutée** : son mode `--fix` (`check_locales.py:113-124,169-174`) est le **seul** outil qui backfill les locales depuis `en.json`, et `PROJECT_MEMORY:988-995` le documente comme le **workflow canonique** d'ajout/retrait de clé. Le test AHK **asserte** mais ne **produit** pas la parité.
- **Proposition.** **GARDER** `check_locales.py` ; corriger son docstring (`:6` `static/locales/` → `_shared/data/locales/`) ; corriger `PROJECT_MEMORY:44,975,984-985` (workflow inexistant → « imposé par le meta-test AHK ; `--fix` = outil dev manuel ») ; bumper `2196→2208`. Optionnel : câbler une étape Linux Python cheap dans `ci.yml`.
- **Gain / Risque / Effort / Vérif.** Élimine une garantie de sécurité documentée mais fausse ; bas ; S ; `lint:conventions:strict` + `test:ahk`.

**I18N-3 — ADR 007 périmé (constat doc).** `static/ergopti_plus/docs/adr/007-i18n-audit-findings.md:4` dit « pending » mais les 17 violations trackées sont **toutes corrigées** (vérifié : `ErgoptiPlus.ahk:396` `MsgBox(t("startup.manifest_missing")…)`, `menu_about.lua` 24 `i18n.get`, `karabiner/onboarding.lua` 0 accent). → Passer le statut à « Resolved », pointer vers I18N-4.

**I18N-4 — Français en dur dans 20/~30 JS webview partagés — bien plus large que le backlog ADR (2 fichiers). `[REOPEN scope ADR][behavior_change]`**
- **Constat.** La vraie dette i18n est dans `_shared/ui/**/*.js` (chargés par les 2 hosts → un fix couvre les 2 plateformes). 20 fichiers contiennent des lignes accentuées (605 totales ; ~195 commentaires `//` = violation §1 séparée, ~410 littéraux UI injectés par template literals/`textContent`, contournant `_t()`/`data-i18n`). Pires : `metrics_typing/data.js` (177), `metrics_apps/script.js` (131, **mappe ses couleurs sur des clés FR** → structurellement non-localisable), `metrics_typing/table.js` (104), `state.js` (52), `hotstring_editor/script.js` (37), `onboarding/script.js` (29).
- **Preuve.** `git grep -c '[éèêàùçâîôûœ]' _shared/ui/**/*.js` ; `metrics_apps/script.js:66-130` (map catégories+couleurs FR) ; `i18n.js:20-22,80-87` (le contrat `_t()`/`data-i18n` contourné). Les copies par-driver (`windows/ui`, `macos/ui`) sont **propres** → la dette est `_shared`.
- **Proposition.** Reprendre le `[BACKLOG]` ADR mais étendu aux 7 fichiers riches : extraire chaque littéral vers une clé (`metrics.typing.kpi.*`, `metrics.apps.category.*`, `hotstrings.editor.*`), `check_locales.py --fix` pour backfill 21 locales, remplacer par `_t(key)`. Pour `metrics_apps` : clé sur un id enum stable, localiser le label. Même passe : ~195 commentaires `//` FR → anglais (§1).
- **Gain / Risque / Effort / Vérif.** ~410 lignes UI FR localisables sur 21 locales × 2 plateformes (fix `_shared` unique) ; `behavior_change=true` (texte dépend de la locale) ; **XL** ; étager fichier-par-fichier derrière `test:js` + `test_locale_json_valid.ahk` + **nouveau ratchet** « aucun littéral accentué hors commentaire dans `_shared/ui/**/*.js` ».

---

## 3. AXE 2 — Simplicité & maintenabilité

### 3.1 `_generated/` — verdict par artefact

**Windows (8 artefacts) :**

| Artefact | Verdict | Preuve clé |
|---|---|---|
| `features_manifest.ahk` (56.5K) | **KEEP** | `manifest_reader.ahk:38` `#Include *i` (runtime) ; drift-gated |
| `terminators.ahk` (9.6K) | **KEEP** | `ErgoptiPlus.ahk:156` (hard include) |
| `prompt_builder.ahk` (7.5K) | **KEEP** | `ErgoptiPlus.ahk:234` ; constantes LLM canoniques |
| `config_template.toml` (8.9K) | **KEEP** | `first_boot.ahk:45` seed ; double gate (drift + schema) |
| `paths.toml` (269B) | **KEEP** | runtime machine-specific, gitignored |
| `personal_shortcuts.ahk` (350B) | **KEEP** | stub de forwarding runtime, gitignored |
| **`registry.ahk` (9.8K)** | **DELETE** | orphelin prouvé (voir GEN-1) |
| **`expander.ahk` (7.8K)** | **DELETE** | orphelin prouvé (voir GEN-2) |

**macOS (2 artefacts) :** `features_manifest.lua` (58K) + `config_template.toml` (8.5K) — KEEP (voir GA).

**GEN-1/GEN-2 + TRANSVERSAL-1 — Supprimer `registry.ahk` + `expander.ahk`. `[REOPEN décision #4 — résolue KEEP, à inverser]`**
- **Constat.** Les deux classes générées (`class Registry`/`class Expander`, 565 l. / 20 Ko) ne sont **jamais** `#Include`'d (grep exhaustif = 0), jamais instanciées, 0 consommateur de symbole. Le `#Include lib/registry.ahk` (`ErgoptiPlus.ahk:102`) est un module DIFFÉRENT (RegRead/RegWrite). Les tests `test_domain_{registry,expander}.ahk` exercent le moteur de PROD `HSE_*` (`hotstring_engine_main.ahk`), **pas** les classes générées (`test_domain_registry.ahk:11-15`). Le `README.md:12` les marque lui-même « ⏳ Orphaned ».
- **Vérif adversariale (important).** La décision #4 fut **résolue KEEP** (`PROJECT_MEMORY:580-582`, `TODO.md`) au motif qu'elles sont « TESTÉES et la seule impl exercée des specs » — **provablement faux** (les tests exercent `HSE_*`). Donc supprimer = **inverser** une décision documentée → le commit doit l'assumer comme `REOPEN décision #4`. **De plus** : `test_generated_substr_minus_one.ahk` est `#Include`'d vivant (`run_all.ahk:559`) et `FileRead` les 2 fichiers en asserant « must be readable » → supprimer les fichiers seuls **rend ce test rouge**, et supprimer le test perd la couverture §5.9 du bug `SubStr(-0)` que le moteur de prod utilise activement (`hotstring_engine_main.ahk:295,315`).
- **Proposition.** (1) **Retarget** `test_generated_substr_minus_one.ahk` vers `hotstring_engine_main.ahk` (asserter `SubStr(…,-1)` présent / `SubStr(…,-0)` absent) — déplace le garde du bug vers le code vivant. (2) PUIS supprimer `_generated/{registry,expander}.ahk` + `codegen-{registry,expander}-ahk.cjs` + scripts npm `codegen:registry`/`codegen:expander:ahk` + steps `build-domain.cjs:169-182` (+ commentaire faux `:152-153`). (3) Corriger `README.md`/`COVERAGE.md`/`TODO.md`/`PROJECT_MEMORY:580-582`.
- **Gain / Risque / Effort / Vérif.** −565 l./20 Ko + 2 codegen + 2 npm + 2 steps + 1 commentaire faux ; bas (orphelins prouvés) ; S ; `build:domain` drift-check + suite AHK (jamais inclus) + `test:ahk-encoding`. `needs_verify` : `rg "#Include[^\n]*_generated[\\/](registry|expander)"` = 0 avant suppression.

**GA — Asymétrie cross-driver `_generated` : la pré-génération est CORRECTE (structurelle), un seul vrai gain.**
- **GA-1 (KEEP).** Les deux drivers pré-génèrent un manifest **boot-critique** (`ErgoptiPlus.ahk:399` `Features := ManifestBuildFeaturesMap()` ; `manifest_reader.lua:63` `loadfile` au require). L'asymétrie n'est **pas** réductible Windows-only : la seule différence est que macOS génère du `.lua` qu'il `loadfile`, AHK ne peut PAS conscommer du `.lua` → il transpile en `Map(...)`. Le motif « ~1 Mo hors boot » **n'est pas dans le plan** et est faux (source = 79.9K, pas 1 Mo). Passer AHK au runtime-TOML est **net négatif** (couple le boot à 79.9K de parse + désynchronise les drivers).
- **GA-2 (KEEP).** `config_template.toml` est **légitimement 2 fichiers** : ils divergent structurellement (`[ahk.layout]`/`[ahk.shortcuts.*]` vs `[hs.gestures.*]`) ET sur des valeurs par-plateforme (`selected=ollama`/`mlx`, `debounce_ms 500`/`200`). Source unique = `manifest.toml` filtré par plateforme. Fusionner réintroduirait le filtrage runtime que la génération pré-résout.
- **GA-3 (KEEP).** `codegen-prompt-builder-hs.cjs` no-op **justifié** : `macos/modules/llm/prompt_builder.lua` (93 l.) est un shim qui délègue à `_shared/lua/llm/prompt_builder.lua` (require natif) ; AHK transpile car il ne peut requérir du `.lua`. Le no-op se documente lui-même (`build-domain.cjs:156`).
- **GA-4 (RÉDUCTION RÉELLE).** Le **seul** gain : l'émetteur macOS produit `features_manifest.lua` en **2351 lignes** vs **263** côté AHK pour la MÊME donnée (un `{` imbriqué par ligne). **Compacter l'émetteur** dans `build-features-manifest.js` (plusieurs clés/ligne). Gain ~30-45 Ko + ~2000 lignes de bruit de revue, `behavior_change=false` ; M ; `build:domain` drift + `test:hs` `loadfile` + `test:manifest-equivalence`. `needs_verify` : confirmer la forme verbeuse de l'émetteur + qu'aucun test n'asserte un nombre de lignes.

### 3.2 Simplifier `_shared/`

**SS-1 — Frontière `_shared/lua/` vs `_shared/modules/` = principielle, à DOCUMENTER.**
- **Constat/Preuve.** Le « chevauchement » `llm/` et `logger/` n'en est pas un : `_shared/lua/` = modules Lua runtime `require`'d par les drivers Lua ; `_shared/modules/<sub>/` = data (JSON/TOML), specs JS, scripts d'install/validation, `SPEC.md`. `_shared/modules/llm/` = `*.json` + `install/*.{ps1,sh}` + `*.py` (0 `.lua`) ; `_shared/modules/logger/` = `SPEC.md` + `test_vectors.json` (0 `.lua`).
- **Proposition.** Garder le split ; ajouter un README à la racine `_shared/` énonçant l'invariant (`lua/` = code runtime ; `modules/<sub>/` = data+specs+scripts ; `core/` = contrats JS ; `data/` ; `ui/` ; `tests/`). Optionnel : meta-test « pas de `.json` data dans `lua/`, pas de `.lua` runtime dans `modules/` ».
- **Gain / Risque / Effort.** Tue la confusion n°1 du dépôt ; nul ; S.

**SS-2 — `_shared/lua/` n'est PAS pur-Lua : `toml_codec` reader/writer requièrent du macOS-only → Linux a forké son parseur. `[behavior_change][défaut d'architecture]`**
- **Constat.** Les shims annoncent `toml_codec` « no hs.* deps, safe for any runtime ». En réalité `reader.lua:23` `require("lib.logger")` et `writer.lua:24-25` `require("lib.logger")` + `require("lib.i18n")` — des **packages du driver macOS**, absents sur Linux. Conséquence visible : Linux a **écrit son propre** parseur TOML zéro-dépendance (`linux/modules/hotstrings/loader.lua:4-12`) au lieu de réutiliser le partagé → la promesse « une impl pour tous les drivers Lua » (`macos/lib/toml_codec.lua:11-15`) est **cassée**.
- **Proposition.** Remplacer les deps dures par les fallbacks neutres déjà présents : `require("logger.shim")` au lieu de `lib.logger`, et `pcall`-gater `i18n` (passthrough de clé si absent). PUIS : (a) migrer `linux/.../loader.lua` sur le reader partagé (supprime le parseur parallèle) **OU** (b) si le subset Linux est volontairement plus léger, corriger les en-têtes des shims pour cesser de prétendre au partage (`codec.lua` est genuinement pur — garder cette affirmation).
- **Gain / Risque / Effort / Vérif.** Réalise le partage promis OU corrige une doc trompeuse (§5.6) ; `behavior_change=true` (routage logger/i18n dans le runtime macOS) ; M ; `test:hs` (reader/writer macOS verts après swap) + `test:linux` (si migration). `needs_verify` : confirmer que `logger.shim` résout vers `lib.logger` sur macOS (`shim.lua:35-39` tente `require('logger')` puis `require('lib.logger')`).

**SS-3 — Micro-shims `color_utils`/`text_utils` = re-exports identité, indirection retirable.**
- **Constat/Preuve.** `macos/lib/color_utils.lua:10` `return require("color_utils")` et `text_utils.lua:10` `return require("text_utils")` — re-export sous le **même nom**, 0 extension HS. Pas morts (7 sites pour `lib.text_utils`) mais inutiles : le code `_shared` requiert déjà le nom nu (`parser.lua:30`, `keymap/utils.lua:24`) → **deux orthographes pour un module**. Linux les ignore.
- **Proposition.** (a) Supprimer les 2 fichiers + repointer les 7 sites macOS sur `require("color_utils")`/`require("text_utils")` (= ce que fait `_shared`), OU (b) standardiser TOUS les callers sur un alias `lib.*` — mais pas les deux orthographes. **À distinguer de SS-4** (les shims `toml_*` remappent un sous-chemin et sont porteurs — garder).
- **Gain / Risque / Effort / Vérif.** −2 micro-fichiers, une seule orthographe ; bas (édition mécanique, échec bruyant au load) ; S ; `test:hs`. `needs_verify` : `grep 'require("lib.color_utils"|"lib.text_utils")'` pour énumérer tous les sites.
- **✅ VERDICT RÉVISÉ (exécution 2026-06-26) → GARDER.** Le `needs_verify` a invalidé la prémisse « 7 sites, édition mécanique » : il y a **6 requires de prod** (`keymap/{utils,registry,init,llm_bridge,expander}` + un `pcall` dans `dynamic_hotstrings/personal_info`) **et ~15 sites de test** qui stubbent `package.loaded["lib.text_utils"]` / `helpers.load_with_stubs("lib.text_utils")` pour contrôler le module vu par le code testé. Supprimer les shims + repointer la prod sur le nom nu casserait **silencieusement** l'interception des stubs (la clé `lib.text_utils` ne matcherait plus `require("text_utils")`) → réécriture de ~21 sites d'infra de test pour 2 fichiers d'une ligne (`lib.color_utils` n'a **aucun** require de prod, seulement des tests). **Net négatif** (§5.9 : ne pas churner/risquer les tests pour du cosmétique). Documenté dans `PROJECT_MEMORY` ([[project-macos-lib-namespace-shims]]) pour ne pas le retenter. Même catégorie que SS-4 (shims `toml_*` porteurs, gardés).

**SS-4 / SS-5 — KEEP (constats négatifs).** Les shims `macos/lib/toml_{codec,reader,writer}.lua` **remappent** `lib.toml_reader`→`toml_codec.reader` (adaptation de namespace, 15+ sites) = adaptateurs porteurs. La couche `core/ports` (20 contrats `.spec.js` + `SPEC.md`) est **proportionnée** à un design hexagonal 3-drivers (le contrat EST le test cross-driver).

### 3.3 God-files & indirection

**F1 (TOP ROI) — Splitter `windows/keylogger.ahk` (1867 l., 0 include frère) en miroir des 10 fichiers macOS.**
- **Constat/Preuve.** Plus gros fichier non-splitté des 2 drivers, `#Include` unique (`ErgoptiPlus.ahk:213`), 0 frère. Mélange ≥4 préoccupations auto-contenues que macOS a déjà factorisées : §11 SQL builders (246 l. ≈ `sqlite_writer.lua`), §13 filtre password UIA (208 l. ≈ `context_tracker.lua`), §5 identité device (112 l.), §7 helpers JSON (125 l.).
- **Proposition.** Pipeline P4/P5 en place : extraire §5/7/11/13 en frères `keylogger_{device,json,sql,password}.ahk`, `#Include`'d après `keylogger.ahk`. Garder l'orchestrateur (classe+lifecycle+tick+hot path) dans l'index. Meta-tests repointés via `_DriverDirConcat`/`_DriverFuncBody`.
- **Gain / Risque / Effort / Vérif.** ~1867→~1100 l., rétablit le miroir 1-vs-10 ; **bas, vérifié** (§5/11/13 = définitions pures, 0 appel top-level ; AHK résout les noms cross-unit → ordre `#Include` indifférent) ; L ; dry-run `/validate` + `test:ahk-encoding` + suite (≈25 meta-tests d'introspection move-resilients) + reload.

**F2 — Splitter `macos/lib/healthcheck.lua` (1112 l.) `lib→ui`, miroir inversé. `[REOPEN claim P5]`**
- **Constat.** P5 (`REFACTOR_PLAN:141`) déclare le split healthcheck « miroir macOS » **fait** ; mais macOS est resté **1 fichier dans `lib/`** alors que Windows est **3 fichiers dans `ui/`**. §3 « Internal Helpers » (551 l.) ≡ `helpers.ahk` ; §2 « Public API » (416 l.) ≡ `core.ahk`. Seulement **2 sites** `require` (`crash_reporter.lua:173`, `ui/menu/builder.lua:486`).
- **Proposition.** Déplacer → `macos/ui/healthcheck/{init,core,helpers}.lua`, surface `M.*` byte-identique, repointer les 2 `require` sur `ui.healthcheck`.
- **Gain / Risque / Effort / Vérif.** Rétablit le miroir que le plan prétend déjà fait + sort une fenêtre de `lib/` ; bas ; M ; `test:hs` (require cassé = échec bruyant) + `test_file_headers.lua` + reload.

**F3 — Splitter `windows/ui/wpm/init.ahk` (1266 l.) vs 3 fichiers macOS. `[vérif : proposition incomplète — corriger]`**
- **Constat.** Monolithe 8 sections vs `macos/ui/wpm/{shared,wpm_menubar,wpm_widget}.lua`. `verify_focus` PASSE : 0 construction Gui top-level (lazy) → extraction non sensible à l'ordre de boot.
- **Vérif adversariale (à intégrer).** La proposition échoue son propre « tests verts » : `test_wpm_widget_native_render.ahk` lit `ui/wpm/init.ahk` par **chemin littéral** et asserte `GdiplusStartup/GR_DrawBitmap/WPMWidget_DrawGraph` (§5, 580-860) que le split déplace → **rouge**. `test_audit_test_gaps.ahk` (garde « no live WebView2 ») cesserait de couvrir le renderer relogé. Et le split 4-fichiers proposé **ne** mirroite **pas** macOS (qui garde config+state+render ensemble dans `wpm_widget.lua`).
- **Proposition corrigée.** Split en **`init.ahk` + `wpm_widget.ahk`** (pour vraiment mirrorer macOS) ; **migrer dans le MÊME commit** les tests chemin-pinnés vers `_DriverDirConcat("ui/wpm")` (helper split-transparent existant) + retirer les `_ReadSource` morts.
- **Gain / Risque / Effort / Vérif.** Miroir + isole la couche GDI+ ; bas-moyen (migration de tests obligatoire) ; M ; suite AHK + `test_wpm_widget_native_render.ahk` + reload.

**F4 — Splitter `macos/ui/menu/menu_keyboard_layout.lua` (1647 l., plus gros macOS) : glue install/TIS vs builder de menu. `[vérif : frontière non triviale]`**
- **Constat.** `M.build(ctx)` (417 l.) noyé sous ~30 locals d'install/TIS/osascript (`install_user/system`, `set_input_source`, `build_kl_name_to_tis_id`, énumération input-source §4 ~660 l.). Doc auto-admet 4 responsabilités.
- **Vérif adversariale.** L'évidence cross-driver est **mal attribuée** (`REFACTOR_PLAN:145` = consolidation **Windows** physique, pas un module install macОС ; Windows remappe via `Hotkey()`, aucun analogue de bundle installable). La frontière n'est **pas propre** : les caches file-local `_active_layouts_cache/_installed_cache/_latest_bundle_cache` (sur le côté système) sont consommés DANS `M.build` et les seams de test `M._set_active_layouts_cache/_invalidate_bundle_caches` les ferment → l'extraction exige migrer les caches derrière des accesseurs (vrai changement de surface publique).
- **Proposition.** Extraire `modules/keymap/layout_install.lua` (+ `input_sources.lua`), garder `M.build/M.prime/M.set_layout_by_kl_name` ; **migrer les caches partagés** derrière getter/invalidator. Pas une parité (rien à mirrorer côté Windows).
- **Gain / Risque / Effort / Vérif.** 1647→~700 l. + module install testable ; **moyen** (état partagé file-local) ; L ; `test:hs` (seams `M._*` déjà pinnés) + reload.

**F8 — Renommer `hotstring_engine_main.ahk` (1509 l.), ne PAS splitter.** Le suffixe `_main` suggère à tort qu'il est l'entrée de `hotstring_engine.ahk` ; ce sont **deux moteurs distincts** (le `_main` est le moteur custom HSE buffer-owning, 328 refs `HSE_`). Cohésion interne autour du buffer HSE unique + couplage by-design avec `hotstring_prefix_watcher.ahk` (SSoT) → **rename** vers `hotstring_engine_custom.ahk`/`hse_engine.ahk`. S ; fan-out doc/`#Include`/test-pins.

**F5/F6/F7 — NE PAS toucher (constats négatifs / rejets confirmés).**
- **F5** `api_ollama.ahk` streaming : **vérif réfute** l'extraction — macOS co-localise le streaming curl dans `api_ollama.lua` (pas dans `streaming_handler.lua` qui est un module moteur sans twin Windows) → extraire **divergerait** ; frontière non propre (§5 dépend de §6 + exporte des utilitaires file-wide).
- **F6** `gestures/init.ahk` : floor d'extraction documenté (cœur entrelacé top-level, `REFACTOR_PLAN:142-143`).
- **F7** §5.6 : **propre** — 0 dead-code/`_compat` dans les 14 god-files (les 2 hits `registry.lua` sont une API vivante + un commentaire §5.7).

### 3.4 Tooling & tests

**TT-1 (HIGH) — 3 chemins fantômes dans le drift-gate `build-domain.cjs` → fausse-confiance.**
- **Constat/Preuve.** `build-domain.cjs:139,142` listent `windows/_generated/tap_hold_template.toml` + `macos/_generated/tap_hold_template.toml`, `:165` liste `macos/_generated/terminators.lua` — **aucun n'est produit** : `build-features-manifest.js:469-485` écrit exactement 4 sorties (sans tap_hold_template, malgré son en-tête `:15-18` qui le prétend encore) ; `codegen-terminators.cjs:368` écrit le catalogue Lua vers `_shared/lua/keymap/terminators_catalogue.lua`. `git ls-files macos/_generated` = 3 fichiers. `build-domain.cjs:279` `filter(fs.existsSync)` **drop** les fantômes avant `git diff` → ils passent en silence.
- **Proposition.** Supprimer les 2 refs `tap_hold_template` + corriger l'en-tête menteur (`build-features-manifest.js:15-18`, §5.6). **Repointer** la ref terminators vers `_shared/lua/keymap/terminators_catalogue.lua` (le vrai output, actuellement **non drift-gaté**) — OU investiguer si un `macos/_generated/terminators.lua` était attendu (régression codegen). Ajouter une meta-assertion : tout chemin de `PIPELINE[].generated` existe sur disque après son step.
- **Gain / Risque / Effort / Vérif.** −3 entrées fausses-vertes + couvre réellement le catalogue Lua ; bas (tap_hold) / moyen (terminators si vrai gap) ; S ; `build:domain` (la nouvelle assertion doit faire échouer jusqu'au fix).

**TT-2 — `tools/lint/audit-gui-titles.cjs` totalement orphelin (aucun script/CI/import, en-tête malformé).** Vérificateur fonctionnel du format de titre `ErgoptiPlus — Nom`, jamais câblé (créé par un commit `style:`, jamais wiré). → **Câbler** (ajouter à `run-js-suite.cjs` CHECKS + corriger l'en-tête `//`) **OU** supprimer (§5.6). `needs_verify` : `grep gui-titles` = 0 + dry-run pour savoir s'il passe sur l'arbre actuel.

**TT-3 — ~7 scripts `test:*` non câblés en CI (gates dormants).** CI invoque seulement ~8 scripts npm par nom (`build:domain`, `test:port-compliance`, `test:priority-parity`, `test:properties`, `test:mutation`, `lint:conventions:strict`, `build:manifest`, `test:manifest-parity`) — `test:js` (umbrella) **n'apparaît pas** dans `ci.yml`. Non joignables : `test:no-fallbacks`, `test:click-lock`, `test:ui-focus`, `test:hs-integrity`, `test:diagnostic-ui`, `test:manifest-equivalence` (26 Ko, probable ancêtre de `test:manifest-parity`), `test:ahk-encoding`. **Nuance vérifiée** : l'encodage AHK EST vérifié en CI mais par une **étape PowerShell inline** (`ci.yml:293-317`), pas par `test-ahk-encoding.cjs` → ce dernier est un outil dev-local **doublé** par une réimpl CI (risque de drift entre 2 vérificateurs). → **Trier par script** : dev-local-only (OK) vs invariant à gater (câbler) vs superseded (supprimer `test-manifest-equivalence` si subsumé). Les `-fix` (`click-lock`/`ui-focus`) sont des régressions §5.9 → **doivent** être joignables. `needs_verify` par script.

**TT-4 — Stryker (mutation) tourne à CHAQUE push, coût disproportionné.** `ci.yml:130-132` sans `if`/filtre de chemin, et `validate-js` est un `needs` des 3 jobs drivers → Stryker bloque tout le graphe. Sa portée réelle est **JS-domain only** (`stryker.config.mjs:26`), il ne mute ni AHK ni Lua. → Le passer en `paths-filter` sur les specs JS, ou en cadence main-only (comme `bench.yml`). Le pendant `test:properties` est moins coûteux. M ; `behavior_change=false` (quand il tourne, pas ce qu'il asserte).

---

## 4. Pistes écartées (rejets ré-examinés et MAINTENUS)

Conformément à la consigne, chaque rejet a été re-soumis au code actuel. Ceux-ci **tiennent** :

- **WPM widget + tooltip → webview** : rejeté à raison (cold-start 476 ms/keystroke sur le chemin de frappe ; `PROJECT_MEMORY:424`). Le pont prouvé ne change pas le coût de cold-start. **MAINTENU.**
- **Split `gestures/init.ahk`** : cœur entrelacé top-level, floor d'extraction documenté + reload-vérifié (`REFACTOR_PLAN:142-143`). **MAINTENU.**
- **Extraction streaming `api_ollama.ahk`** : la vérif montre que macOS co-localise aussi le streaming curl → extraire **divergerait** ; frontière non propre. **MAINTENU (ne pas faire).**
- **Fusion `config_template.toml` en 1 fichier** : divergence structurelle + valeurs par-plateforme réelles. **MAINTENU (GA-2).**
- **De-générer le manifest AHK (runtime-TOML)** : net négatif (couple le boot + désynchronise). **MAINTENU (GA-1).**
- **Générer un `prompt_builder.lua`** : macOS le requiert nativement, no-op justifié. **MAINTENU (GA-3).**
- **tap_hold inc 4** (`tap_hold_keys.json`/`mod_combos.json` dans le TOML partagé) : data structurelle Karabiner pure. **MAINTENU.** *(inc 3 = MOOT : `generator.lua` n'a jamais lu `defaults.lua` ; les défauts arrivent via `state` seedé du TOML partagé — voir T-2.)*
- **Migration gating PascalCase→v2** : `category_enabled` est **AHK-only** (`manifest.toml` section `ahk.category_enabled` ; macOS n'a aucune couche de gating) → 0 parité cross-driver, 27 sites/10 fichiers de risque pour du cosmétique. **MAINTENU (T-3).** À documenter dans `PROJECT_MEMORY` comme détail d'implémentation AHK volontaire.
- **Déplacer adapters `shell_runner`/`toml_cache`/`json_codec` → `lib/`** : ratchet de pureté OS (`adapters/` = couche d'isolation OS, `PROJECT_MEMORY:202`). **MAINTENU.**
- **Transpile codec TOML / parser LLM Lua→AHK** : le « subset partageable » EXISTE déjà via les **corpus cross-driver partagés** (`fuzz_corpus.json`, `parser_test_vectors.json`…) ; transpiler des parseurs qui marchent = risque pour gain nul. **MAINTENU.**
- **Garder `lib/app_state.ahk`, `download_window`, `generate_models.py`/`pyproject`/`uv.lock`** : ancres de test / hosts vivants / racine venv MLX. **MAINTENU.**
- **Supprimer `check_locales.py`** : la vérif **réfute** — `--fix` est le workflow canonique de backfill. **GARDER** (fix docs seulement, I18N-2).
- **Shims `toml_*` macOS / couche `core/ports`** : remap porteur (15+ sites) / proportionnée à 3 drivers. **MAINTENU (SS-4/SS-5).**
- **`path_translator.ahk`** : confirmé **entièrement supprimé** (0 ref vivante). **CLOSE.**
- **Catalogues de données (AXE 1.4)** : tous single-source. **RIEN À FAIRE.**

---

## 5. Plan d'exécution incrémental (moins → plus risqué)

Chaque incrément = un commit conventionnel autonome, vérifié par les portes existantes.
🖥️ = vérifiable **uniquement au reload** (GUI Windows / boot Hammerspoon) par le mainteneur.

**Palier 0 — Docs & refs mortes (risque ≈ nul).**
1. `fix(codegen)` : purger les 3 entrées fantômes du drift-gate + en-tête menteur, repointer terminators sur `terminators_catalogue.lua`, +meta-assertion d'existence (TT-1).
2. `chore(llm)` : supprimer le bloc mort `_platform_defaults` de `defaults.json` (DD-2).
3. `docs(i18n)` : corriger `check_locales.py` docstring + `PROJECT_MEMORY` (workflow inexistant, 2196→2208) (I18N-2) ; passer ADR 007 à « Resolved » (I18N-3).
4. `docs(shared)` : README de frontière `_shared/lua` vs `modules` (+meta-test optionnel) (SS-1) ; documenter `category_enabled` AHK-only (T-3) ; corriger commentaire « gitignored » de `features_manifest.ahk` (GEN-3) ; fixer 2 log strings tap_hold (T-2).

**Palier 1 — Suppression de code mort (drift-gaté, 0 comportement).**
5. `refactor(hotstrings)` : retarget `test_generated_substr_minus_one.ahk` vers le moteur vivant, PUIS supprimer `registry.ahk`+`expander.ahk` + 2 codegen + 2 npm + 2 steps (GEN-1/2/T-1) — **assumé `REOPEN décision #4`**.
6. `chore(lint)` : câbler **ou** supprimer `audit-gui-titles.cjs` (TT-2).
7. `perf(codegen)` : compacter l'émetteur `features_manifest.lua` (GA-4).

**Palier 2 — Source unique & simplification (0 comportement).**
8. `refactor(llm)` : port Ollama en source unique côté AHK + ratchet (DD-1). 🖥️ (boot LLM)
9. `refactor(shared)` : retirer les shims identité `color_utils`/`text_utils` + repointer 7 sites (SS-3). 🖥️
10. `refactor(hotstrings)` : renommer `hotstring_engine_main.ahk` (F8).

**Palier 3 — Splits de god-files (reload-vérifiables).**
11. `refactor(keylogger)` : splitter `windows/keylogger.ahk` (F1). 🖥️
12. `refactor(healthcheck)` : `macos/lib/healthcheck.lua` → `ui/healthcheck/{init,core,helpers}` (F2). 🖥️
13. `refactor(wpm)` : split `init.ahk`+`wpm_widget.ahk` **+ migration des tests chemin-pinnés** (F3). 🖥️
14. `refactor(keymap)` : extraire la glue install/TIS de `menu_keyboard_layout.lua` + migrer les caches (F4). 🖥️

**Palier 4 — Changements de comportement assumés / gros chantiers.**
15. `fix(shared)` : réparer la fuite de pureté `toml_codec` (logger.shim + pcall i18n), puis migrer Linux **ou** corriger les en-têtes (SS-2). 🖥️ (Linux + macOS)
16. `feat(menu)` : i18n des libellés LLM macOS + parité `pretty_key`→manifest (MS-2/MS-3). 🖥️
17. `feat(healthcheck)` : frontend `_shared/ui/healthcheck/` partagé + hosts (UI-1). 🖥️ (2 plateformes)
18. `feat(i18n)` : extraction des littéraux FR des webviews `_shared/ui/**/*.js`, fichier par fichier + ratchet (I18N-4). 🖥️

**Palier 5 — Cadence CI.**
19. `ci(perf)` : Stryker en paths-filter/main-only (TT-4) ; trier les ~7 `test:*` dormants (TT-3).

---

## 6. Zones non auditées (à investiguer séparément)

Le critique de complétude a identifié des zones hors scope des 11 axes, à traiter en passe dédiée :

- **Driver Linux (40 fichiers, décision #6 différée)** : 20 adapters non audités pour la parité ; vérifié que le cœur EST partagé (`engine.lua:17-35` re-exporte `_shared/lua/hotstring_engine`, `metrics_collector.lua` requiert le keylogger partagé) ; mais le fork TOML (SS-2) montre que la convergence est incomplète. Avec le pattern port/adapter mûr sur 3 drivers, la convergence est peut-être moins chère qu'au moment du report.
- **`macos/apps/` — binaires Mach-O committés** (`AppCloner`, `Encryptor/droplet_bin` 100K, `Assets.car` 412K) sans consommateur de code driver (grep vide) — candidats `.gitignore` (build outputs reproductibles depuis les sources `.applescript`/`.py`/`.sh` présentes).
- **`old/kalamine` (78 fichiers, 1.5 Mo)** : **PAS** du code mort — asset de benchmark **du site** (`src/lib/js/getVersions.js:52-58`, `comparateurs_dispositions.svelte:95`). **Ne pas supprimer** ; documenter dans `PROJECT_MEMORY` pour qu'une passe de nettoyage du driver ne le cible jamais.
- **`tools/codegen/new-driver.js`** : scaffold possiblement périmé vs le layout canonique réel (pas de `tests/unit/meta/` ni de stubs d'adapters par port) — à valider par un test de conformité.
- **Autres** : `extensions/ergopti-demo` (dual `menu.ahk`+`menu.lua` — candidat partage), arbres `vendor/` (parité de dépendances vendorisées), scripts `tools/build/build_macos_app.sh`/`generate_appcast.sh`/`tools/dev/*`, `_shared/modules/llm/install/ollama_install.{ps1,sh}` vs `macos/.../ensure-*-deps.sh` (divergence ?).

---

*Audit produit sans modification de code. Tous les chemins sont réels ; vérifications adversariales appliquées aux affirmations de suppression (registry/expander, check_locales, wpm tests, menu_keyboard_layout, api_ollama). Méthode : 11 investigateurs + critique + vérificateurs.*
