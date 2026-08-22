# Audit exhaustif — mise en commun maximale + simplification du code

> **Rôle.** Tu es un architecte logiciel chargé d'auditer **ErgoptiPlus** en
> profondeur. Tu produis un **rapport d'audit actionnable et priorisé**, pas du
> code. Tu lis le dépôt, tu prouves chaque constat par des chemins/lignes réels,
> et tu proposes des changements **sans régression de comportement**.

## Contexte du projet (à vérifier, ne pas présumer)

ErgoptiPlus est un outil de clavier multi-plateforme avec trois drivers qui
doivent **converger vers une structure miroir** et partager un **maximum** de
logique/config/UI :

- `static/ergopti_plus/windows/` — driver AutoHotkey v2 (`ErgoptiPlus.ahk`).
- `static/ergopti_plus/macos/` — driver Hammerspoon/Lua (`init.lua`).
- `static/ergopti_plus/linux/` — driver Lua/kanata.
- `static/ergopti_plus/_shared/` — code/données/UI partagés : `core/`, `data/`,
  `lua/`, `modules/`, `tap_hold/`, `tests/`, `ui/`.

Documents de référence à lire **avant** de conclure (ils contiennent l'historique
des décisions, y compris des pistes déjà écartées comme « net négatif » — ne
re-propose pas ce qui a été rejeté à raison, mais signale si une décision mérite
d'être rouverte) :

- `AGENTS.md` — contrat universel de sécurité, de livraison et de langue ; les
  skills ciblés sous `.agents/skills/` et le `SPEC.md` du logger portent les
  règles propres aux drivers et au logging.
- `docs/memory/README.md` — routeur des gotchas et invariants accumulés.
- `docs/REFACTOR_PLAN.md` — le plan de refacto P0→P7 + FEAT A/B/C, avec le
  raisonnement des items faits ET rejetés. **C'est la mémoire canonique** : ton
  audit doit s'y greffer, pas la contredire sans preuve.

Contexte récent (déjà fait — à confirmer, pas à refaire) : la plupart des
fenêtres sont déjà des **webviews partagées** (`_shared/ui/<nom>/` rendues par un
host WebView2 côté Windows et WKWebView côté macOS, frontend `script.js`
host-agnostique `chrome.webview`↔`webkit`) : `paths_editor`,
`personal_info_editor`, `hotstrings_config_window`, `prompt_editor`,
`hotstring_editor`, `onboarding`, `model_browser`, `download_window`,
`metrics_typing`, `metrics_apps`, `changelog`, `action_picker`, et
`token_prompt` (frontend partagé, non câblé Windows faute de backend MLX). Le
menu a une SSoT dans `manifest.toml` → codegen `menu_manifest.json` (FEAT B).

---

## Harnais de vérification (à exécuter pour étayer chaque constat)

Toute proposition doit préciser comment elle serait vérifiée. Les portes
existantes :

| Couche | Commande | Sens |
|---|---|---|
| Parse/validate AHK | `& "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in ErgoptiPlus.ahk /out "$env:TEMP\probe.exe"` (depuis `windows/`, **PowerShell uniquement** — Git Bash réécrit `/in` et `/out` en chemins) | exit 0 = tout parse, exit 17 = erreur de syntaxe. **Jamais `/validate`** : le flag est ignoré et le script s'EXÉCUTE (`feedback_ahk_ui_syntax_validation`) |
| Suite AHK | `AutoHotkey64.exe tests\run_all.ahk` (TAP dans `%TEMP%\ergopti_test_results.txt`) | unitaires + meta |
| Suite JS/CI | `npm run test:js` | drift gates, lint, parité, headers… |
| Encodage AHK | `npm run test:ahk-encoding` | UTF-8 BOM + LF |
| Lint conventions | `npm run lint:conventions:strict` | bannières/sections/espacement |
| Headers de fichier | `node tools/lint/audit-file-headers.cjs` | 1re ligne = chemin |
| Suite macOS | `cd static/ergopti_plus/macos && lua tests/run.lua` | unitaires Lua |
| Pipeline domaine | `npm run build:domain` | régénère `_generated` + drift-check |

Règle d'or : **aucun changement de comportement** ; chaque fix embarque son test
de régression ; ne jamais affaiblir un test pour faire passer un changement.

---

## AXE 1 — Mise en commun maximale (réduire la duplication cross-driver)

Objectif : pousser **encore plus** de choses dans `_shared/`, jusqu'à ce qu'un
driver ne contienne que ce qui est **intrinsèquement spécifique à sa plateforme**
(API OS, rendu natif minimal, glue d'amorçage).

Analyse exhaustivement, avec preuves :

1. **UI / webviews.** Recense **toutes** les fenêtres et dialogues des deux
   drivers (`windows/ui/**`, `macos/ui/**`). Pour chacune, classe-la :
   - déjà webview partagée ✅,
   - **devrait** devenir une webview partagée (toute UI non triviale),
   - peut **rester native** car « petite » (un seul `OK`/`Annuler`, un seul
     sélecteur, un seul `InputBox`) — justifie le « petit ».
   Cible explicitement les natifs restants : p.ex. `windows/ui/editors.ahk`
   (modales clé magique / touche de répétition / lien GPT / infos perso),
   `tooltip`, `healthcheck`, `spotlight`, `wpm`, et tout équivalent macOS. Pour
   chaque candidate à convertir : frontend à créer/partager, host à cloner
   (pattern `model_browser`/`paths_editor`), contrat de pont, fallback natif,
   risque, et **ce qui n'est vérifiable qu'au reload**.

2. **Menu.** Le menu est-il **entièrement** piloté par la SSoT partagée
   (`manifest.toml` → `_shared/modules/menu/menu_manifest.json`) sur les DEUX
   drivers ? Reste-t-il des données de menu codées en dur, des libellés non
   i18n, des divergences d'ordre/structure entre AHK et HS ? Le pont de
   résolution (labels, catégories dynamiques) est-il dupliqué ?

3. **Valeurs par défaut.** Applique le contrat SSoT d'`AGENTS.md` à GRANDE
   échelle : trouve **tout défaut dupliqué** entre drivers ou entre code et
   `manifest.toml` / `*.toml` / `DEFAULT_STATE` (délais, couleurs, priorités,
   timeouts, tailles de fenêtres, seuils, presets de couleur, etc.). Pour chaque
   doublon : où vit la vérité, qui devrait la lire, comment l'unifier sans
   changer la valeur effective. (Voir le précédent `tap_hold` : superset à
   sections par plateforme dans `_shared/tap_hold/defaults.toml`.)

4. **Données & catalogues.** `_shared/data/` (locales, etc.),
   `_shared/modules/` (gestures `actions.toml`, hotstrings, priority.json…) :
   reste-t-il des catalogues parallèles par driver qui pourraient être une
   source unique + lecture par plateforme ?

5. **i18n.** Les 21 locales sont-elles cohérentes (parité de clés déjà testée) ?
   Y a-t-il des chaînes UI codées en dur dans un driver au lieu de passer par
   `t()`/`i18n.get()` + locales partagées ?

Pour chaque opportunité de l'axe 1, indique : **constat → preuve (fichiers:lignes)
→ proposition → gain cross-driver → risque → effort → vérif**.

---

## AXE 2 — Simplicité & maintenabilité (réduire la masse et la complexité)

Objectif : rendre le code **beaucoup plus simple à comprendre et maintenir** —
un junior doit saisir un driver en quelques heures. Cherche la suppression et la
réduction, pas l'ajout.

1. **Dossiers `_generated/` — sont-ils encore utiles ? peut-on réduire leur
   contenu ?** C'est une question centrale. Analyse chaque artefact généré :
   - `windows/_generated/` : `features_manifest.ahk` (~56 Ko), `registry.ahk`,
     `expander.ahk`, `terminators.ahk`, `prompt_builder.ahk`,
     `config_template.toml`, `paths.toml`, `personal_shortcuts.ahk`.
   - `macos/_generated/` : `features_manifest.lua` (~58 Ko), `config_template.toml`.
   Pour CHACUN : (a) est-il encore **lu au runtime** (grep des `#Include` /
   `require` / lectures) ? (b) quel codegen le produit (`tools/codegen/**`,
   `tools/build/**`, `npm run build:*`) et est-il branché en CI/drift-gate ? (c)
   pourrait-il être **supprimé** (orphelin), **réduit** (gros fichier qui pourrait
   être lu à la volée depuis `_shared` au lieu d'être pré-généré et committé),
   ou **remplacé** par une lecture directe de la source partagée ? Évalue le
   compromis taille-committée / coût-boot / risque (certains `_generated` ont été
   créés pour sortir ~1 Mo de tables du chemin de boot — vérifie si c'est encore
   le cas et si une alternative plus simple existe). **Ne propose aucune
   suppression sans grep prouvant l'absence de consommateur** (cf. P0/P5).

2. **Simplifier `_shared/`.** `core/`, `lua/`, `modules/`, `tap_hold/`,
   `tests/`, `data/`, `ui/` : y a-t-il des sous-arbres redondants, mal nommés,
   ou qui mélangent les préoccupations ? Des couches d'indirection inutiles ?
   Des fichiers morts ? Une structure plus plate/lisible possible ? Le contrat
   `core/ports/contracts.json` ↔ `adapters/` est-il proportionné ?

3. **God-files & indirection.** Repère les fichiers volumineux ou à
   responsabilités multiples (des deux côtés) qui gagneraient à être scindés —
   ou au contraire des micro-fichiers/indirections à fusionner. Signale les
   patterns de complexité accidentelle (ponts de compat, alias et fallbacks
   morts) interdits par `AGENTS.md`.

4. **Tooling & tests.** `tools/` (codegen, lint, test) est-il cohérent et
   non redondant ? Des scripts `package.json` orphelins ? La suite de tests
   couvre-t-elle les invariants critiques sans doublons coûteux ?

Pour chaque opportunité de l'axe 2 : **constat → preuve → proposition (supprimer /
réduire / fusionner / aplatir) → gain (lignes/fichiers/complexité en moins) →
risque → effort → vérif**.

---

## Format du livrable

Produis un **rapport Markdown unique**, structuré et priorisé :

1. **Résumé exécutif** — 5–10 opportunités à plus fort ratio valeur/risque, en
   tête, chacune en une ligne.
2. **Axe 1 (mise en commun)** puis **Axe 2 (simplification)** — sections
   détaillées, chaque item au format `constat → preuve → proposition → gain →
   risque → effort → vérif`.
3. **Plan d'exécution incrémental** — ordonné du moins au plus risqué, chaque
   incrément étant un commit conventionnel autonome, vérifié par les portes
   ci-dessus, avec mention explicite de ce qui n'est validable qu'au reload
   (Windows GUI / boot Hammerspoon).
4. **Pistes écartées** — ce qui *paraît* mutualisable/simplifiable mais ne l'est
   pas (avec la raison : net négatif, spécifique plateforme, risque
   disproportionné), pour éviter d'y revenir.

Contraintes : ne modifie pas le code pendant l'audit ; cite des chemins réels ;
quantifie quand tu peux (Ko, nb de fichiers, nb de doublons) ; respecte la règle
« aucun changement de comportement » et « un test de régression par fix » dans
toutes tes propositions ; et confronte systématiquement tes conclusions à
`docs/REFACTOR_PLAN.md` et `docs/memory/README.md`.
