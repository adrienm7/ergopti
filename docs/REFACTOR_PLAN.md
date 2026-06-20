# ErgoptiPlus — Plan de simplification & mise en commun (pur refactor)

> **But.** Faire converger les drivers `windows/` (AHK), `macos/` (Hammerspoon/Lua) et
> `linux/` vers **une seule structure miroir**, pousser le **maximum de logique/config
> dans `shared/`**, et rendre le code assez simple pour qu'un junior comprenne un driver
> en quelques heures. **Aucun changement de comportement** : chaque étape est un refactor
> vérifié.
>
> Ce document remplace les anciens rapports d'audit racine (`AUDIT_*`, `RAPPORT_AUDIT*`)
> qui ont servi à le construire. On coche au fur et à mesure.

## Comment on travaille

1. On exécute les phases **dans l'ordre** (`P0` → `P7`), de la moins risquée à la plus risquée.
2. Chaque étape est cochée **uniquement après** sa vérification.
3. Chaque phase est un (ou plusieurs) commit conventionnel sur `dev`.
4. **Règle d'or** (CLAUDE.md §5.9) : tout fix embarque son test de régression dans le même commit.

### Harnais de vérification (établi, baseline verte le 2026-06-20)

| Cible | Commande | Sens |
|---|---|---|
| Parse AHK (include graph) | `& "C:\Program Files\AutoHotkey\v2.0.19\AutoHotkey64.exe" /ErrorStdOut <runner> --dry-run` | exit 0 = tout parse (`1..2208` au baseline) |
| Tests unitaires AHK | idem sans `--dry-run` | runner = `static/ergopti_plus/windows/tests/run_all.ahk` |
| E2E AHK | runner = `static/ergopti_plus/windows/tests/e2e/run_e2e.ahk` | |
| Suite node | `npm run test:manifest-parity test:port-compliance test:ahk-encoding test:manifest-equivalence test:config-schema test:hs-integrity` (+ autres `test:*`) | |
| Lua (macOS, stubs) | `lua static/ergopti_plus/macos/tests/run.lua` | |

---

## Structure cible (miroir 1:1)

Chemin identique d'un driver à l'autre → l'analogue se trouve au même endroit.

| Concept | `windows/` | `macos/` | Rôle |
|---|---|---|---|
| Entrée | `ErgoptiPlus.ahk` (mince) | `init.lua` (mince) | directives + manifeste d'include + filet d'erreur + `Boot_Run()` |
| Adapters | `adapters/` (20 exactement) | `adapters/` (20 exactement) | 1 fichier / port de `shared/ports/contracts.json` |
| Infra/domaine | `lib/` (aucun UI) | `lib/` (aucun UI) | |
| Features | `modules/<feature>/` | `modules/<feature>/` | 1 dossier / feature |
| Fenêtres UI | `ui/<window>/` | `ui/<window>/` | 1 dossier / fenêtre |
| Données | `data/` (data pure) | `data/` (data pure) | |
| Généré | `_generated/` | `_generated/` | jamais édité à la main |
| Tests | `tests/{unit,integration,e2e,bench,fixtures,helpers,stubs,meta}` | idem | même taxonomie |

---

## P0 — Hygiène repo (zéro impact code)

**But.** Nettoyer le tracking git et la racine pour que la structure soit lisible avant tout déplacement de code.

- [ ] Archiver les 8 audits markdown uniques (`AUDIT_*.md`, `RAPPORT_AUDIT*.md`, `audit_ergoptiplus.md` = doublon de `RAPPORT_AUDIT_FINAL.md`) sous `docs/archive/audits/` (préserve l'historique, nettoie la racine).
- [ ] `git rm` les dumps git-log jetables `all_fix_commits.txt`, `fix_commits.txt`.
- [ ] `git rm --cached static/ergopti_plus/windows/build/static_bundle.zip` (déjà gitignore, CI le reconstruit).
- [ ] `git rm --cached reports/mutation/mutation.html` + ajouter `/reports/` à `.gitignore`.
- [ ] `git rm static/ergopti_plus/kanata/{kanata,kanata_winIOv2.exe}` (binaires non référencés ; `install.sh` n'utilise que `kanata.kbd` — vérifié). Garder `kanata.kbd`.
- [ ] Supprimer du working tree les logs scratch non trackés (`ci.log`, `failed_run.log`, `windows/out.log`, `tests/test_run.log`, `macos/tests/scratch_*.log`, `luac.out`).
- [ ] Ajouter `luac.out`/`*.luac` déjà couverts ; vérifier la couverture `.gitignore`.

**Vérif.** `git status` propre ; suite node + AHK dry-run inchangées (vert) ; `grep` confirme aucune référence cassée.

---

## P1 — Drift gate codegen + accesseur feature fail-fast (tue la classe de crash)

**But.** Rendre le manifest source unique **imposée**, et transformer l'`UnsetItemError` opaque (crash `ctrl_magic_save`, [layout.ahk:743]) en erreur nommée et actionnable.

- [ ] Régénérer + commiter `windows/_generated/config_template.toml` (périmé — prouvé) — **commit séparé, AVANT le gate**.
- [ ] Ajouter le script `codegen` parapluie (`build:manifest` + `build:domain` + tous les `codegen:*`) dans `package.json`.
- [ ] Ajouter l'étape CI drift gate : `npm run codegen && git diff --exit-code` sur **tous** les artefacts générés trackés (les deux `_generated/`, `shared/lua/.../terminators_catalogue.lua`, `shared/ports/contracts.json`).
- [ ] Corriger `tools/test/test-manifest-parity.cjs` : supprimer/réparer l'exclusion des flags `platforms=['ahk']` (le trou exact qui a laissé passer `ctrl_magic_save`).
- [ ] **Nouveau** check statique node : tout site de lecture de feature (AHK + Lua) a une entrée manifest correspondante (couvre les flags ahk-only).
- [ ] Accesseur AHK `FeatureEnabled(path)` / `FeatureValue(path)` (+ `FeatureSet(path,val)` pour les ~10 sites d'écriture) dans `lib/manifest_reader.ahk`. **🔴 LIT LA MAP `Features` LIVE** (mutée par `master_gates.ahk` + éditeurs), le manifest ne sert qu'à composer le message d'erreur nommé.
- [ ] Remplacer les 31 lectures brutes `Features[..][..]` (23 dans l'entrée, 8 dans `layout.ahk`) par l'accesseur.
- [ ] Régressions : (a) chemin inconnu → erreur **nommée** (pas `UnsetItemError`) ; (b) feature zéro-tée par un master gate → `false` **live** via l'accesseur.

**Vérif.** Valeurs de flags byte-identiques pour tout chemin existant **après** `ApplyMasterGatesToFeatures` et après une écriture simulée ; drift gate vert ; retirer volontairement une entrée manifest → échec CI lisible (plus de crash runtime).

---

## P2 — Tests miroir + auto-découverte (CI lisible)

**But.** Un point d'entrée unique, des échecs lisibles, ajouter un test sans éditer le runner.

- [ ] Scripts `package.json` : `test:ahk`, `test:hs`, `test:linux`, `test:js`, `test:all` ; repointer `ci.yml` dessus (local == CI).
- [ ] Câbler (ou documenter local-only) les `tools/test/*.cjs` orphelins ; traiter `test-mutation-targets.cjs`.
- [ ] Format de résultat unique : TAP + ligne JSON `{passed,failed,failures:[{name,file,line,msg}]}` côté AHK **et** Lua ; `tools/test/report.cjs` parse → liste en tête de step + annotations GitHub `::error` + artefact.
- [ ] Adopter la taxonomie macOS `tests/{unit/{lib,adapters,modules,ui},integration,e2e,bench,fixtures,helpers,stubs,meta}` sur Windows ; collapse `macos/tests/unit/meta` → `tests/meta`.
- [ ] **(haut risque, en dernier)** Remplacer les ~370 `#Include` de `run_all.ahk` par auto-découverte (glob) + `_generated/test_includes.ahk` ; **derrière** `test_run_all_include_integrity.ahk`, en comparant la liste découverte à l'ancienne avant suppression. Retirer les `FileAppend [marker]`.

**Vérif.** Même ensemble de tests avant/après (comparer compteurs + liste de noms découverts) ; un test cassé volontairement remonte en tête du step avec `file:line`.

---

## P3 — Parité adapters (structurel bas risque)

- [ ] Déplacer `macos/adapters/{json_codec,shell_runner,toml_cache}.lua` → `macos/lib/` (maj require-paths) → 20 ports exactement des deux côtés.
- [ ] Ajouter les maps `ADAPTER_<NAME>` aux 6 adapters AHK qui en manquent ; **vérifier** ; **puis** durcir `test-port-compliance.cjs` (exiger les 20 ports). *(Ordre atomique : maps avant durcissement, sinon CI rouge en cours de phase.)*
- [ ] Normaliser les 2 en-têtes de chemin d'adapters AHK + indentation `key_state.ahk`.
- [ ] Codegen des vecteurs de contrat AHK depuis les specs JS (`test_adapter_contract_vectors.ahk`).

**Vérif.** `test:port-compliance` vert ; `adapters/` = 20 des deux côtés ; vecteurs générés == vecteurs hand-typés.

---

## P4 — Décomposition de l'entrée Windows

**But.** `ErgoptiPlus.ahk` 2397 → ~150 lignes, miroir de `init.lua`.

- [ ] Extraire : boot → `lib/boot.ahk` ; config IO → `lib/config_io.ahk` ; lifecycle → `lib/lifecycle.ahk` ; hotkeys AltGr → `lib/script_altgr_hotkeys.ahk` ; tables d'état → `lib/feature_state.ahk`.
- [ ] Pickers/éditeurs → `ui/action_picker.ahk` + `ui/editors.ahk` ; sondes `DllCall` → `adapters/key_state.ahk`.
- [ ] Bannières 5-blank-lines / 7-`=` dans chaque nouveau fichier.
- [ ] **Préserver exactement** l'ordre d'`#Include` et les directives `#InputLevel` (assertion : `ApplyMasterGatesToFeatures` tourne avant la 1re lecture via accesseur dans `boot.ahk`).

**Vérif.** Dry-run AHK exit 0 ; suite AHK verte ; séquence des phases de boot (log) inchangée ; e2e vert.

---

## P5 — Folderisation `modules/` + `ui/` Windows

- [ ] `tray_menu.ahk` (2975 l.) → `ui/menu/{init,menu_layout,menu_hotstrings,menu_metrics,menu_gestures,menu_shortcuts,menu_taphold,menu_about,menu_debug}.ahk`.
- [ ] Fusionner `ui/tray_llm.ahk` (barrel) + `ui/tray_llm/` → un seul `ui/menu_llm/` (`init.ahk`).
- [ ] `lib/tooltip.ahk` (94 Ko) → `ui/tooltip/{core,helpers,llm}.ahk`.
- [ ] `lib/updater.ahk` (75 Ko) + `modules/gestures.ahk` (79 Ko) + `lib/healthcheck.ahk` → sous-fichiers le long des sections.
- [ ] Sortir l'UI de `lib/` → `ui/<window>/` (onboarding, changelog, hotstrings_config_window, hotstring_editor, model_browser, wpm, healthcheck, spotlight).
- [ ] Consolider la couche layout → `modules/keymap/` ; supprimer le stub `lib/app_state.ahk`.
- [ ] Renommages 1:1 : `menu_renderer.ahk`→`manifest_menu.ahk` ; `llm_model_browser.ahk`→`ui/model_browser/init.ahk` ; `tooltip_llm.ahk`→`ui/tooltip/` ; extraire `lib/locale.ahk`.

**Vérif.** Dry-run + suite + e2e verts ; menu/LLM/tooltip/onboarding/updater testés ; graphe d'include résout sans symbole manquant.

---

## P6 — Symétrie macOS

- [ ] Extraire les algos inline d'`init.lua` (découverte hotstrings, cleanup MLX, scan personal-hotstrings, file-watcher) → modules/lib.
- [ ] Renuméroter/réaligner les bannières d'`init.lua` ; renommer le `boot_llm_enabled` dupliqué.
- [ ] `lib/{mlx,ollama}_deps_checker.lua` → `modules/llm/` ; `modules/hotstrings_config.lua` → `modules/hotstrings/` ; splitter `healthcheck.lua` + les 2 fichiers MLX ~1800 l.
- [ ] Supprimer les assets morts `ui/download_window/*` (après diff vs `shared/`) ; ajouter `init.lua` à `paths_editor/` & `token_prompt/`.
- [ ] Déplacer `data/generate_models.py` + `pyproject.toml` + `uv.lock` → `tools/`.
- [ ] Ajouter `windows/README.md` + `macos/README.md` + `docs/TESTING.md` ; maj `new-driver.js` (`DRIVER_SUBDIRS` canonique).

**Vérif.** Suite macOS verte ; ordre des phases de boot (log) inchangé.

---

## P7 — Mise en commun profonde (gros blast radius — en dernier, livré sous-étape par sous-étape)

- [ ] Logger → cœur partagé `shared/lua/logger` via `set_sink()` (les deux drivers).
- [ ] Tooltip AHK lit `shared/tooltip/constants.toml` ; ⚠️ divergences d'alpha → clés per-platform reproduisant l'existant (gate : snapshot avant/après).
- [ ] **tap_hold** → `shared/tap_hold/defaults.toml`. ⚠️ **TOML Windows vs JSON macOS diffèrent probablement déjà** → prouver l'équivalence byte d'abord, sinon c'est un `feat`, pas un refactor.
- [ ] Codegen du codec TOML + parser LLM AHK depuis `shared/lua` ; éliminer `path_translator.ahk` (map d'ids générée ou migration snake_case).
- [ ] Promouvoir les frontends web restants → `shared/ui/` ; plier le placement du menu dans `manifest.toml` + émettre l'arbre par codegen.

**Vérif.** Corpus `shared/tests/` identique sur les deux moteurs ; test de conformité logger exerce la prod ; parité constantes tooltip ; suite + drift gate verts après chaque sous-étape (livrée indépendamment).

---

## Décisions maintainer (à trancher avant les phases concernées)

1. **layout/keymap Windows** : `lib/keymap/` ou `modules/keymap/` ? (macOS = `modules/keymap/`.)
2. **Placement menu** : plié dans `manifest.toml` (1 SSoT, gros codegen) ou `menu_manifest.json` + drift gate ?
3. **`lib/` Windows foldéré vs `lib/` macOS plat** : converger dans quel sens ?
4. **`_generated/registry.ahk` + `expander.ahk` orphelins** : adopter ou supprimer (+ scripts codegen) ? *(P0/P5 : ne PAS supprimer sans grep des `#Include`.)*
5. **Codec TOML + parser LLM AHK** : transpile Lua→AHK ou génération corpus-driven + bannière hand-port ?
6. **`linux/`** : même passe ou suivi séparé ? (Au min. vérifier l'absence de surface de crash `Features` brute.)

---

## Risques transverses

- **AHK sensible encodage/espaces** : tout split risque l'abort silencieux mi-fichier si LF-only/sans BOM. → Edit tool (jamais `cat >>`), tests ASCII-only via `Chr(0xNNNN)`, lancer `test:ahk-encoding` après chaque move.
- **Ordre d'`#Include` + `#InputLevel`** portent des invariants réels (hoisting globals, `#InputLevel 2` avant les includes de layer). Réordonner casse les hotkeys **sans erreur de compile** → préserver l'ordre, vérifier la séquence de boot.
- **`run_all.ahk` auto-découverte (P2)** : changer l'ordre de chargement peut révéler des dépendances inter-tests latentes → stager derrière le test d'intégrité.
- **`tap_hold` partagé (P7)** : probablement déjà divergent → traiter comme `feat` si non prouvé identique.
- **Churn de fichiers générés** : le drift gate produit un gros diff one-time → commit dédié.
