# ErgoptiPlus — Plan de simplification & mise en commun (pur refactor)

> **But.** Faire converger les drivers `windows/` (AHK), `macos/` (Hammerspoon/Lua) et
> `linux/` vers **une seule structure miroir**, pousser le **maximum de logique/config
> dans `_shared/`**, et rendre le code assez simple pour qu'un junior comprenne un driver
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
| Adapters | `adapters/` (20 exactement) | `adapters/` (20 exactement) | 1 fichier / port de `_shared/ports/contracts.json` |
| Infra/domaine | `lib/` (aucun UI) | `lib/` (aucun UI) | |
| Features | `modules/<feature>/` | `modules/<feature>/` | 1 dossier / feature |
| Fenêtres UI | `ui/<window>/` | `ui/<window>/` | 1 dossier / fenêtre |
| Données | `data/` (data pure) | `data/` (data pure) | |
| Généré | `_generated/` | `_generated/` | jamais édité à la main |
| Tests | `tests/{unit,integration,e2e,bench,fixtures,helpers,stubs,meta}` | idem | même taxonomie |

---

## P0 — Hygiène repo (zéro impact code)

**But.** Nettoyer le tracking git et la racine pour que la structure soit lisible avant tout déplacement de code.

- [x] Archiver les 8 audits markdown uniques (`AUDIT_*.md`, `RAPPORT_AUDIT*.md`) sous `docs/archive/audits/` ; supprimer `audit_ergoptiplus.md` (doublon byte-identique de `RAPPORT_AUDIT_FINAL.md`, md5 vérifié).
- [x] `git rm` les dumps git-log jetables `all_fix_commits.txt`, `fix_commits.txt`.
- [x] `git rm --cached static/ergopti_plus/windows/build/static_bundle.zip` (déjà gitignore l.153, reste sur disque, CI le reconstruit).
- [x] `git rm --cached reports/mutation/mutation.html` + ajouter `/reports/` à `.gitignore` (l.132).
- [x] `git rm static/ergopti_plus/kanata/{kanata,kanata_winIOv2.exe}` (binaires non référencés ; `linux/install.sh` n'utilise que `kanata.kbd` — vérifié). Garder `kanata.kbd`.
- [x] Supprimer du working tree les logs scratch non trackés (`ci.log`, `failed_run.log`, `windows/out.log`, `tests/test_run.log`, `macos/tests/scratch_*.log`, `luac.out`).
- [x] `luac.out`/`*.luac` déjà couverts par `.gitignore` (l.65-66) — vérifié.

**Vérif. ✅** `git check-ignore` confirme zip + `reports/` ignorés ; `test:ahk-encoding` (571 fichiers) + `test:config-schema` verts ; aucun fichier tracké cassé.

---

## P1 — Drift gate codegen + accesseur feature fail-fast (tue la classe de crash)

**But.** Rendre le manifest source unique **imposée**, et transformer l'`UnsetItemError` opaque (crash `ctrl_magic_save`, [layout.ahk:743]) en erreur nommée et actionnable.

- [x] Régénérer + commiter `windows/_generated/config_template.toml` (périmé — prouvé) — commit séparé `fix(codegen): sync config_template + schema`. A aussi révélé que `config.schema.json` (hand-maintained) rejetait `ctrl_magic_save` → corrigé.
- [x] Script `codegen` parapluie ajouté dans `package.json` (= `npm run build:domain`, qui régénère + vérifie).
- [x] Drift gate CI : **existe déjà** dans `build:domain` (drift-check sur 8 fichiers générés + `contracts.json` via port-compliance), **et la CI le lance déjà** (`ci.yml:102`). Vérifié : il a bien attrapé le `config_template` périmé.
- [x] **Nouveau** check statique `tools/test/test-feature-read-sites.js` : tout site de lecture `Features[...]` AHK (279 sites) résout contre la map construite depuis le manifest — couvre les flags ahk-only. Câblé dans `build:domain` (step 10) → tourne en CI.
- [x] Régression : self-test **toujours actif** dans le guard, encode la classe de crash exacte — forme buggée `Features["ahk.layout"]["ctrl_magic_save"]` **rejetée**, forme correcte `Features["layout"][...]` **acceptée**, clé inconnue **rejetée**.
- [x] `test-manifest-parity.cjs` laissé tel quel : son exclusion des flags `platforms=['ahk']` est **correcte** (la parité est cross-driver ; un flag ahk-only n'existe pas côté HS). Le trou réel — l'absence de contrôle interne des flags ahk-only — est désormais comblé par le guard ci-dessus.
- [ ] ~~Accesseur AHK `FeatureEnabled/FeatureValue/FeatureSet` + conversion des sites~~ → **REPORTÉ en P4**. Raison : il y a **294** sites `Features[...]` (pas 31), beaucoup dans des `#HotIf ... IsSet(Features)` — une conversion de masse à l'aveugle (sans lancer le driver GUI) est risquée, et ajouter un accesseur dormant violerait §5.6 (pas de code mort). Le guard statique atteint l'objectif anti-crash sans toucher au runtime. La migration vers un accesseur fail-fast (lisant la **map live**) se fera dans P4 où l'entrée est réécrite et vérifiable.

**Vérif. ✅** `build:domain` 10/10 vert (guard inclus) ; `config_template` + schéma synchronisés ; suite node verte ; le guard distingue précisément la forme buggée de la forme correcte.

---

## P2 — Tests miroir + auto-découverte (CI lisible)

**But.** Un point d'entrée unique, des échecs lisibles, ajouter un test sans éditer le runner.

- [x] Scripts `package.json` : `test:js` (umbrella node, mirror des jobs "Validate ·"), `test:hs`, `test:linux`. `test:ahk` documenté dans `docs/TESTING.md` (chemin de l'exe AHK variable → laissé en doc plutôt qu'en script hardcodé).
- [x] **Point d'entrée + échecs lisibles** : `tools/test/run-js-suite.cjs` affiche un résumé pass/fail par check et, sur échec, **la commande exacte pour rejouer** + le tail de sortie. `docs/TESTING.md` = doc unique « comment lancer/diagnostiquer chaque couche, local == CI ».
- [ ] ~~Format TAP+JSON unifié + `report.cjs` + annotations GitHub côté AHK/Lua~~ → **REPORTÉ** (refactor des deux runners, gros ; le résumé `test:js` couvre déjà la couche node qui est celle qui casse le plus souvent).
- [ ] ~~Taxonomie de tests miroir sur Windows (déplacer ~90 tests plats + 327 meta)~~ → **REPORTÉ** : nécessite de réécrire les ~370 `#Include` de `run_all.ahk` ; gros + risqué, n'adresse pas la douleur CI (déjà couverte). À faire en passe dédiée, vérifiée par dry-run + suite.
- [ ] ~~Auto-découverte `run_all.ahk`~~ → **REPORTÉ** (haut risque, cf. risques).

**Vérif. ✅** `test:js` 4/4 vert ; `test:hs` 2228 tests verts ; doc TESTING.md couvre les 4 couches avec la commande exacte de chacune.

---

## P3 — Parité adapters (structurel bas risque)

- [x] ~~Déplacer `macos/adapters/{json_codec,shell_runner,toml_cache}.lua` → `macos/lib/`~~ → **REJETÉ** par l'architecture. Le test `tests/meta/test_port_adapter_coverage.lua` impose que tout appel OS (`hs.*`, `io.open`/`os.execute`) vive dans `adapters/`. Ces 3 helpers **touchent l'OS** (exec shell, I/O fichier) → ils sont légitimement dans `adapters/`. Affaiblir le baseline du test pour permettre le move est interdit (§5.9). **Conclusion : `adapters/` = couche d'isolation OS (les 20 ports + helpers OS), pas « exactement 20 ports ».** La parité visée doit être documentée ainsi, pas forcée par un déplacement. Voir [PROJECT_MEMORY](PROJECT_MEMORY.md).
- [ ] ~~Maps `ADAPTER_<NAME>` + durcir `test-port-compliance`~~ → **REPORTÉ** : `test:port-compliance` passe déjà (20 ports couverts) ; durcir un test vert pour une valeur marginale = risque net négatif sans bénéfice clair. À reconsidérer seulement si une vraie lacune de couverture est prouvée.
- [ ] ~~Normaliser en-têtes + codegen vecteurs de contrat~~ → **REPORTÉ** (cosmétique / gros pour valeur faible).

**Vérif. ✅** Le filet de test (`test:hs`, 2228 tests) a rejeté le move ; revert propre, suite re-verte. P3 : aucun changement de code — le principal item était architecturalement incorrect.

---

## P4 — Décomposition de l'entrée Windows

**But.** `ErgoptiPlus.ahk` 2397 → ~150 lignes, miroir de `init.lua`.

**Pipeline d'extraction prouvé et sûr** (chaque incrément) : extraction PowerShell (garantit UTF-8 BOM + CRLF) qui remplace le bloc **en place** par un `#Include` (préserve l'ordre de boot et les statements top-level type `global X := …`) → `test:ahk-encoding` → dry-run AHK (parse, exit 0) → suite complète AHK (2224/0) → repointer les meta-tests qui scannent le source de `ErgoptiPlus.ahk` (≈25 tests pinnent des fonctions à ce fichier — le filet les attrape).

- [x] Hotkeys AltGr → `lib/script_altgr_hotkeys.ahk` (incrément 1 ; 2 meta-tests repointés).
- [x] Éditeurs (magic key, repeat key, infos perso, lien GPT) → `ui/editors.ahk` (incrément 2).
- [x] Pickers (`ShowActionPicker`, `ShowKeyboardSlotPicker`, `ShowKeyboardShortcutPicker`, `FilePathsEditor`) → `ui/action_picker.ahk` (incrément 3).
- [x] Config IO (toggles, `SaveFullConfig`, `_CollectFeatureUpdates`, shortcut config) → `lib/config_io.ahk` (incrément 4). **Bonus** : durcissement des meta-tests d'introspection — `_DriverSourceConcat()` (tout l'arbre `windows/**/*.ahk`) + `_DriverFuncBody()` (ancre sur la *définition*, indentée ou non) dans `test_framework.ahk` ; ~28 tests migrés → **désormais indépendants de l'emplacement des fonctions** (plus de casse à chaque déplacement).
- [x] Lifecycle (suspend/shutdown/tray/debug) → `lib/lifecycle.ahk` (incrément 5).
- [x] Tables d'état globales (`ScriptInformation`, `SCRIPT_SHORTCUT_*`, `KEYBOARD_SHORTCUT_*`, `CategoryEnabled` + readers) → `lib/feature_state.ahk` (incrément 6 ; in-place ; 0 fix de test grâce au durcissement).
- [ ] *(optionnel, plus risqué)* Sondes `DllCall` (AltGr-Kana, scan magic-key) → `adapters/key_state.ahk` ; séquence de boot → `lib/boot.ahk`. **Repoussé** : ce qui reste dans l'entrée (manifeste d'`#Include` + orchestration de boot) est désormais le rôle légitime de l'entrée ; extraire le boot touche l'ordre `#Include`/`#InputLevel`/exécution top-level (risque élevé pour un gain de lisibilité faible).
- [ ] Bannières 5-blank-lines / 7-`=` dans les nouveaux fichiers (passe `npm run fix:banners` à faire en fin de P4/P5).

**Vérif. ✅** Driver rechargé par le mainteneur — fonctionne comme avant. Chaque incrément : dry-run exit 0 + suite **2230/0** + encoding vert. **Entrée : 2397 → 1189 lignes (−50 %).** Cœur de P4 atteint ; le reste de l'entrée est manifeste + boot.

---

## P5 — Folderisation `modules/` + `ui/` Windows

- [x] `tray_menu.ahk` (2975 l.) → **`ui/menu/` (12 fichiers)** : `menu_engine`, `menu_gestures`, `menu_metrics`, `menu_metrics_actions`, `menu_layout`, `menu_hotstrings`, `menu_submenus`, `menu_shortcuts`, `menu_taphold`, `menu_init`, `menu_actions`, `menu_rebuild`. `tray_menu.ahk` = index de 95 l. (header + globals d'état + `#Include` in-place → ordre d'exécution top-level préservé à l'octet). 5 meta-tests file-pinnés migrés vers `_DriverSourceConcat()`/`_DriverFuncBody()`. **Vérif** : dry-run exit 0, suite 2230/0, encoding 589 fichiers.
- [ ] Fusionner `ui/tray_llm.ahk` (barrel) + `ui/tray_llm/` → un seul `ui/menu_llm/` (`init.ahk`).
- [x] `lib/tooltip.ahk` (2251 l.) → **`ui/tooltip/{init,core,helpers,llm}.ahk`** (move lib→ui + split, miroir macOS). `init.ahk` = index (module doc + 3 `#Include`). Includes mis à jour : `ErgoptiPlus.ahk` + `tests/run_all.ahk`. Nouveau helper `_DriverDirConcat("ui/tooltip")` dans `test_framework.ahk` (scan source par module, indépendant du sous-découpage) ; 7 tests d'introspection migrés. Orphelin non-CI rotté `run_llm_tooltip_grace.ahk` supprimé (déjà rouge sur un contrat de garde périmé ; superseded par `test_llm_tooltip_grace.ahk` dans run_all). **Vérif** : dry-run exit 0, suite 2228/0, encoding 591.
- [x] `lib/updater.ahk` (1838 l.) → **`lib/updater/{core,changelog,self_update}.ahk`** (split en place ; `updater.ahk` reste l'index dans `lib/`, aucun changement d'`#Include`). Nouveau helper `_DriverDirConcat` réutilisé ; **7 fichiers de tests d'introspection migrés** (16 assertions) vers `_DriverDirConcat("lib/updater")`/`_DriverFuncBody` ; `test_webview2_temp_leak` passe en scope module (create + cleanup `_Updater_CloseGui` désormais dans des sous-fichiers frères). **Vérif** : dry-run exit 0, suite 2234/0, encoding 594.
- [x] `lib/healthcheck.ahk` (956 l.) → **`ui/healthcheck/{init,core,helpers}.ahk`** (move lib→ui, miroir macOS ; module UI). `init.ahk` = index. 4 tests d'introspection migrés vers `_DriverDirConcat("ui/healthcheck")`/`_DriverFuncBody`. **Vérif** : dry-run exit 0, suite 2232/0, encoding 596.
- [ ] `modules/gestures.ahk` (2076 l.) → sous-fichiers. ⚠️ **risque élevé** : hotkeys top-level `^#+F1::` dépendants de `#InputLevel 2` (non exercés par la suite headless → régression visible seulement au reload utilisateur) + ~18 tests d'introspection dépendants. À traiter avec un reload-test explicite.
- [ ] Sortir l'UI de `lib/` → `ui/<window>/` : ~~onboarding~~ ✅ (`ui/onboarding/{init,core,steps,finish}.ahk`), ~~healthcheck~~ ✅ (`ui/healthcheck/`), ~~tooltip~~ ✅ (`ui/tooltip/`) ; **reste** : changelog_window, hotstrings_config_window, hotstring_editor, model_browser, wpm, spotlight.
- [ ] Consolider la couche layout → `modules/keymap/` ; supprimer le stub `lib/app_state.ahk`.
- [ ] Renommages 1:1 : `menu_renderer.ahk`→`manifest_menu.ahk` ; `llm_model_browser.ahk`→`ui/model_browser/init.ahk` ; `tooltip_llm.ahk`→`ui/tooltip/` ; extraire `lib/locale.ahk`.

**Vérif.** Dry-run + suite + e2e verts ; menu/LLM/tooltip/onboarding/updater testés ; graphe d'include résout sans symbole manquant.

---

## P6 — Symétrie macOS

- [ ] Extraire les algos inline d'`init.lua` (découverte hotstrings, cleanup MLX, scan personal-hotstrings, file-watcher) → modules/lib.
- [ ] Renuméroter/réaligner les bannières d'`init.lua` ; renommer le `boot_llm_enabled` dupliqué.
- [ ] `lib/{mlx,ollama}_deps_checker.lua` → `modules/llm/` ; `modules/hotstrings_config.lua` → `modules/hotstrings/` ; splitter `healthcheck.lua` + les 2 fichiers MLX ~1800 l.
- [ ] Supprimer les assets morts `ui/download_window/*` (après diff vs `_shared/`) ; ajouter `init.lua` à `paths_editor/` & `token_prompt/`.
- [ ] Déplacer `data/generate_models.py` + `pyproject.toml` + `uv.lock` → `tools/`.
- [ ] Ajouter `windows/README.md` + `macos/README.md` + `docs/TESTING.md` ; maj `new-driver.js` (`DRIVER_SUBDIRS` canonique).

**Vérif.** Suite macOS verte ; ordre des phases de boot (log) inchangé.

---

## P7 — Mise en commun profonde (gros blast radius — en dernier, livré sous-étape par sous-étape)

- [ ] Logger → cœur partagé `_shared/lua/logger` via `set_sink()` (les deux drivers).
- [ ] Tooltip AHK lit `_shared/tooltip/constants.toml` ; ⚠️ divergences d'alpha → clés per-platform reproduisant l'existant (gate : snapshot avant/après).
- [ ] **tap_hold** → `_shared/tap_hold/defaults.toml`. ⚠️ **TOML Windows vs JSON macOS diffèrent probablement déjà** → prouver l'équivalence byte d'abord, sinon c'est un `feat`, pas un refactor.
- [ ] Codegen du codec TOML + parser LLM AHK depuis `_shared/lua` ; éliminer `path_translator.ahk` (map d'ids générée ou migration snake_case).
- [ ] Promouvoir les frontends web restants → `_shared/ui/` ; plier le placement du menu dans `manifest.toml` + émettre l'arbre par codegen.

**Vérif.** Corpus `_shared/tests/` identique sur les deux moteurs ; test de conformité logger exerce la prod ; parité constantes tooltip ; suite + drift gate verts après chaque sous-étape (livrée indépendamment).

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
