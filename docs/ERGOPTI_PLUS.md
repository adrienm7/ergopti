<!-- docs/ERGOPTI_PLUS.md -->

# Ergopti+ — Comment ça marche, et comment y toucher

> **Lectorat.** Un développeur qui ouvre ce dépôt pour la première fois et doit modifier
> quelque chose aujourd'hui. Aucune connaissance préalable supposée.
>
> **Honnêteté.** Ce document décrit le code **tel qu'il est** au 2026-07-30, pièges inclus.
> Là où la procédure actuelle est douloureuse, les runbooks du §10 donnent **deux** réponses :
> `Aujourd'hui` (ce qu'il faut réellement faire) et `Cible` (ce que ce sera après le lot
> correspondant de [TODO.md](../TODO.md) §0). Si les deux diffèrent
> beaucoup, c'est le sujet du plan, pas une fatalité.
>
> **Règles du projet** (obligatoires, non négociées ici) :
> [.github/copilot-instructions.md](../.github/copilot-instructions.md).
> **Gotchas accumulés** : [docs/PROJECT_MEMORY.md](PROJECT_MEMORY.md).

---

## Table des matières

1. [Ce qu'est Ergopti+](#1-ce-quest-ergopti)
2. [La carte du dépôt](#2-la-carte-du-dépôt)
3. [Les sources de vérité partagées](#3-les-sources-de-vérité-partagées)
4. [Le cycle de vie d'un driver](#4-le-cycle-de-vie-dun-driver)
5. [Le trajet d'une frappe](#5-le-trajet-dune-frappe)
6. [Les sous-systèmes](#6-les-sous-systèmes)
7. [Ports et adaptateurs](#7-ports-et-adaptateurs)
8. [Codegen : ce qui est généré et pourquoi](#8-codegen--ce-qui-est-généré-et-pourquoi)
9. [Les tests](#9-les-tests)
10. [Runbooks — comment faire X](#10-runbooks--comment-faire-x)
11. [Les asymétries irréductibles](#11-les-asymétries-irréductibles)
12. [Pièges par langage](#12-pièges-par-langage)
13. [Les pièges transverses à connaître avant de toucher au code](#13-les-pièges-transverses-à-connaître-avant-de-toucher-au-code)

---

## 1. Ce qu'est Ergopti+

Ergopti+ est la **couche logicielle** de la disposition clavier Ergopti. La disposition
elle-même (quelle touche produit quel caractère) est une donnée ; Ergopti+ est ce qui tourne
en tâche de fond et ajoute tout le reste :

| Fonctionnalité | En une phrase |
|---|---|
| **Hotstrings** | ~3 000 abréviations qui s'étendent en tapant (`btw` → `by the way`), classées en catégories activables |
| **Magic key (★)** | une touche combinatoire qui répète, complète ou transforme selon ce qui précède |
| **Hotstrings dynamiques** | expansions calculées à la volée (dates, informations personnelles) via un préfixe |
| **Remap / tap-hold** | une touche fait une chose en tape et une autre en maintien (CapsLock = Entrée / Ctrl) |
| **Gestes trackpad** | 2 à 5 doigts, balayages et axes continus, liés à des actions |
| **Raccourcis** | une couche de raccourcis propre au driver, plus des accords assignables |
| **Prédiction LLM** | complétion de mot/phrase par modèle local (Ollama, MLX) ou distant, affichée en infobulle |
| **Métriques de frappe** | keylogger local, WPM, n-grammes, heatmap, temps par application, tableaux de bord webview |
| **Infobulle** | aperçu des expansions et des prédictions, rendu natif |
| **Widget WPM** | affichage à l'écran de la vitesse de frappe |
| **Mise à jour** | polling GitHub, changelog, installation |

Trois implémentations, une par OS, appelées **drivers** :

| Driver | Langage / hôte | Rôle du remappage | Injection de texte |
|---|---|---|---|
| `windows/` | AutoHotkey v2 | émulation en processus (`Hotkey()` par scancode) | `SendInput` |
| `macos/` | Lua sur Hammerspoon | disposition `.bundle` installée dans l'OS + Karabiner-Elements pour le tap-hold | `hs.eventtap` |
| `linux/` | Lua sur LuaJIT, daemon | `kanata` (daemon séparé, `/dev/input` + `uinput`) | `ydotool` |

**Ce que les trois partagent** : les données (hotstrings, actions, manifestes, locales), la
logique pure en Lua, les frontends web des fenêtres de configuration, les contrats de ports,
et les corpus de vecteurs qui certifient qu'ils se comportent pareil.

**Maturité, à savoir avant de lire le code** : Windows et macOS sont complets. Linux est
partiel — 16 733 lignes de production contre ~80 000 pour chacun des deux autres, avec
plusieurs sous-systèmes présents mais non câblés. Le §13 dit lesquels.

---

## 2. La carte du dépôt

```
static/ergopti_plus/
├── _shared/          la source de vérité — tout ce qui est consommé par plus d'un driver
│   ├── core/         contrats JS : ports/*.spec.js, domain/*.spec.js, config_schema/
│   ├── data/         donnée pure : 21 locales, keycodes, schéma SQL
│   ├── lua/          code Lua exécuté au runtime par macOS et Linux
│   ├── modules/<x>/  donnée + specs + scripts (TOML/JSON/MD/py/ps1/sh) — jamais de .lua runtime
│   ├── tap_hold/     défauts tap-hold partagés
│   ├── tests/        corpus de vecteurs cross-driver + fixtures
│   └── ui/           14 frontends webview partagés (html/js/css) + i18n.js + host_bridge.js
├── windows/          driver AHK v2
├── macos/            driver Hammerspoon
├── linux/            driver LuaJIT
├── kanata/           layouts kanata (consommés par Linux)
├── extensions/       packs d'extensions (hotstrings + raccourcis tiers)
└── docs/             architecture.md (généré), ADR, spec keylogger, glossaire
```

**La frontière la plus source de confusion** : `_shared/lua/` contre `_shared/modules/`. Ce
ne sont pas deux endroits pour la même chose.

| Dossier | Contenu | Consommé par |
|---|---|---|
| `_shared/lua/` | **du code Lua exécuté** — `require`é au runtime | macOS + Linux |
| `_shared/modules/<x>/` | **de la donnée, des specs, des scripts** — aucun `.lua` runtime | les trois drivers (comme donnée) + l'outillage JS |
| `_shared/core/` | **des contrats JS** — le contrat *est* le test cross-driver | la suite JS |
| `_shared/data/` | de la donnée pure, aucun code | tous, plus le site |
| `_shared/ui/` | des frontends webview agnostiques de l'hôte | Windows + macOS (+ Linux partiellement) |

`llm/` et `logger/` existent dans `lua/` **et** dans `modules/` : il n'y a aucun
recouvrement, seulement une coïncidence de nom. `lua/llm/parser.lua` est du code ;
`modules/llm/defaults.json` est de la donnée.

⚠ **Et `_shared/lua/` n'est partagé qu'à 37,7 %.** Sur ses 8 473 lignes, **3 195 seulement**
sont réellement requises en production par **les deux** drivers Lua ; **36,9 % sont
macOS-only** (dont `llm/parser.lua` 843 l, `text_utils` 634 l, `toml_codec/codec.lua`
612 l) et **22,7 % Linux-only** (dont `llm/linux_bridge.lua` 365 l, `logger/init.lua` 282 l
et — le cas le plus frappant — `hotstring_engine/` 282 l, que **macOS ne `require` jamais**
malgré une docstring affirmant l'inverse). Vérifiez toujours qui consomme réellement un
module de `_shared/lua/` avant de supposer qu'une modification y atteint les deux drivers.

### 2.1 L'arbre d'un driver, aujourd'hui

⚠ Les trois arbres **divergent**, et c'est le sujet principal du plan de simplification
(§5 du plan). Le chiffre à avoir en tête : sur 53 sous-répertoires distincts de profondeur
≤ 2 à travers les trois drivers, **10 seulement sont présents dans les trois — soit 18,9 %
d'identité d'arborescence**. Voici donc le tableau de correspondance dont vous avez besoin
pour naviguer aujourd'hui :

| Concept | `windows/` | `macos/` | `linux/` |
|---|---|---|---|
| Point d'entrée | `ErgoptiPlus.ahk` | `init.lua` | `ergopti_hotstrings.lua` |
| Adaptateurs OS | `adapters/` (21) | `adapters/` (24) | `adapters/` (22) |
| Infra transverse | `lib/` (39 fichiers plats + 6 dossiers, 24 017 l) | `lib/` (27 + `toml/`) | `lib/` (6 fichiers) |
| **Moteur de hotstrings** | `lib/hotstrings/` (17 fichiers) | **`modules/keymap/`** | `modules/hotstrings/` |
| **Remappage clavier** | **`modules/keymap/`** | `modules/karabiner/` + `modules/keymap/{layout_install,input_sources}.lua` | `modules/kanata/` |
| Tap-hold | `modules/tap_holds/` + `lib/tap_hold/` | `modules/karabiner/` | `modules/kanata/` |
| Menu tray | `ui/menu/` (+ barrel `ui/tray_menu.ahk`, **hors dossier**) | `ui/menu/` (barrel `init.lua` **dans** le dossier) | **`modules/menu/`** |
| Fenêtres webview | `ui/<fenêtre>/` (+ 5 fichiers plats à la racine de `ui/`) | `ui/<fenêtre>/` | **`modules/ui/bridge_handlers/`** + `ui/webkit_host.lua` |
| Métriques (hôtes) | `modules/keylogger/keylogger_{ui,webview,prefetch}.ahk` | `ui/metrics_{typing,apps}/` | `modules/ui/bridge_handlers/` |
| Updater | `lib/updater/` | `lib/updater.lua` | `modules/updater/` |
| Crash reporter | `lib/crash_reporter.ahk` | `lib/crash_reporter.lua` | `modules/diagnostics/` |
| Chemins de config | `lib/boot.ahk` | **`ui/menu/menu_paths.lua`** | *(aucun résolveur)* |
| Généré | `_generated/` (8 fichiers) | `_generated/` (3) | `_generated/` (1, vide) |

**Les deux pièges de nommage à mémoriser tout de suite :**

1. **`modules/keymap/` désigne deux sous-systèmes opposés.** Sur Windows c'est le remappage
   physique (couches base/Shift/CapsLock/AltGr, touches mortes) ; sur macOS c'est le moteur
   d'expansion (boucle eventtap, registre, expander). Les deux README sont corrects
   séparément — c'est le *nom* qui est le bug.
2. **`registry` désigne deux choses.** `windows/lib/registry.ahk` est un wrapper du registre
   Windows ; `macos/modules/keymap/registry.lua` est le registre de hotstrings.

---

## 3. Les sources de vérité partagées

Le tableau à connaître par cœur. « Généré ? » signifie qu'un `npm run` produit le fichier :
ne jamais l'éditer à la main.

| Fichier | Contenu | Généré ? | Lu par | Barrière |
|---|---|---|---|---|
`_shared/modules/features/manifest.toml` (3 313 l) | tout toggle de fonctionnalité, son défaut, sa clé i18n, ses plateformes | non — **c'est la source** | via les manifestes générés | `test:manifest-parity`, `test:feature-read-sites` |
`windows/_generated/features_manifest.ahk`, `macos/_generated/features_manifest.lua` | projection pré-résolue du précédent | **oui** (`build:manifest`) | `lib/manifest_reader.*` | `test-features-manifest-no-drift` |
`_shared/modules/menu/menu_manifest.json` (862 l) | l'arbre de menu : ordre, types, filtres de plateforme | **oui** (`build:menu`) | Windows + macOS. **Pas Linux** | `test-menu-manifest`, `test:manifest-equivalence` |
`_shared/modules/gestures/actions.toml` (765 l) | le catalogue d'actions : id, plateforme, ordre, paramètres | non | les trois drivers | `test-gesture-slots-single-source` |
`_shared/modules/gestures/modifier_chords.json` | **le seul fichier exprimant une équivalence de modificateur par OS** | non | les trois + le générateur Karabiner | — |
`_shared/modules/hotstrings/*.toml` (2 994 entrées) | les hotstrings livrées, par catégorie | non | les trois | corpus `hotstrings/` |
`_shared/modules/hotstrings/priority.json` | les 3 rangs de priorité (10/30/50) | non | Windows + macOS | `test:priority-parity` |
`_shared/tap_hold/defaults.toml` (430 l) | défauts tap-hold ⚠ **deux espaces de noms non reliés dans un seul fichier** | non | Windows + kanata (`[tap_hold.*]`) ; macOS (`[hs_*]`) | `test:kanata-defalias-parity` |
`_shared/modules/timings/constants.toml` (523 l) | tous les délais nommés | non | les trois | `test-keylogger-timings-single-source` etc. |
`_shared/modules/tooltip/constants.toml` (360 l) | style visuel de l'infobulle | non | Windows + macOS (échec bruyant si manquant) | `test:tooltip-shared-style` (partiel) |
`_shared/modules/llm/*.json` | fournisseurs, modèles, profils, défauts, layout du menu IA | `models.json` **oui** | les trois (partiellement) | famille `*-single-source` |
`_shared/data/locales/en.json` + 20 autres | **toutes** les chaînes visibles par l'utilisateur | non | les trois + les webviews | `test_locale_json_valid.ahk` |
`_shared/data/keycodes/{azerty,evdev}.json` | espaces de codes de touches | non | heatmap métriques + agrégateur macOS | `test:keycode-data-js-parity` |
`_shared/data/db/schema.sql` (661 l, 44 tables) | le DDL des métriques | non | les trois | — |
`_shared/core/ports/*.spec.js` (20) + `contracts.json` | les contrats de ports | `contracts.json` **oui** | la suite JS + macOS | `test:port-compliance` |
`_shared/ui/apps.manifest.json` (14 apps) | géométrie et nom d'hôte de chaque fenêtre | non | les trois hôtes | `test:webview-geometry-single-source` |
`_shared/tests/corpus/**` (16 fichiers, 258 vecteurs) | le comportement attendu, en donnée | non | les 3 suites | ADR-006 |

**La règle qui gouverne tout ça** : quand vous changez une valeur ou un comportement que
plus d'un driver implémente, vous devez **soit** le déplacer dans `_shared/` et faire lire
tout le monde là, **soit** ajouter un test single-source qui épingle les copies l'une à
l'autre. Jamais deux copies maintenues à la main sans test entre elles — c'est comme ça que
« corrigé sur Windows, encore cassé sur macOS » part en production.

---

## 4. Le cycle de vie d'un driver

Les trois drivers font les mêmes choses dans un ordre voisin, mais **aucun vocabulaire de
phase n'est partagé** : deux logs de boot de deux drivers ne sont pas comparables. Voici la
séquence commune, avec les correspondances.

| Phase | Windows | macOS | Linux |
|---|---|---|---|
| **1. Garde de processus** | mutex nommé (premier statement), classe de priorité, 6 globales pré-pompe, `OnError` armé **au-dessus** de l'extraction du bundle | implicite (Hammerspoon est un singleton) | **aucune** — seul `Restart=on-failure` de systemd |
| **2. Amorçage** | `_StaticDir` / `_VendorDir` / `_SharedDir` / `_DriverDir`, extraction du zip embarqué en mode compilé | injection de `package.path` vers `_shared/lua`, chercheur custom pour le vendor tactile | `SCRIPT_DIR` par `debug.getinfo`, `package.path`, installation du polyfill `utf8` (LuaJIT n'a pas celui de Lua 5.3) |
| **3. Journalisation** | `LoggerInit()` — ⚠ **après** ~40 appels `try Logger*` antérieurs | `require("lib.logger")`, patch de `hs.logger.new` pour museler les modules bruyants, `Logger.init_log_path` | `require("logger.shim")` — ⚠ **aucun sink n'est installé, rien n'est écrit** (blocage B1 du plan) |
| **4. Chemins** | `lib/boot.ahk` : lecture de `paths.toml`, `_ConfigDir`, chargement des défauts partagés | `ui/menu/menu_paths.init(base_dir)` ⚠ un module de menu porte la SSOT des chemins | ⚠ **aucun résolveur** — 12 expressions indépendantes |
| **5. Configuration** | `ManifestEnsureLoaded()` → `Features := ManifestBuildFeaturesMap()`, `ApplyConfigToml`, `I18nInit` | `manifest_reader`, `config_overrides.apply`, `i18n.init`, cache TOML | ⚠ **pas de manifeste du tout** ; défauts par fichier |
| **6. Adaptateurs** | 21 `#Include`, avant tout `lib/` ou `modules/` qui les référence | `require` à la demande | `require` à la demande |
| **7. Premier lancement** | `Onboarding_Run()` (bloquant) | garde `onboarding.should_run` → `return` (le reste du fichier est sauté) | **aucun** (stub de menu) |
| **8. Moteurs** | moteur de hotstrings, tap-holds, gestes, raccourcis | keymap (registre/expander/LLM bridge s'initialisent **au moment du `require`**), gestes, raccourcis, Karabiner | moteur de hotstrings, prédiction, hotstrings dynamiques |
| **9. Contenu** | `RegisterAllHotstrings(false)`, index du prefix watcher | découverte du répertoire de hotstrings, ordre en 3 niveaux, `keymap.flush_sort()` | `hotstrings_config.init` + `load_all()` |
| **10. Entrée** | `HookDispatcher.Start()` — la frontière de propriété du clavier | `keymap.start()` (l'eventtap de frappe) | `keyboard_hook.start{...}` en mode observe |
| **11. UI** | `ui/tray_menu.ahk`, tooltip, hôtes webview | `menu.start(...)` — ⚠ 8 arguments positionnels | tray **seulement si `--tray`** ⚠ (blocage B2) |
| **12. Watchers** | timer de polling de disposition (1 s), poller d'updater | `file_watchers.start`, watcher de source d'entrée | `file_watchers.start`, `process_lifecycle.start` |
| **13. Prêt** | `_DriverReady := true`, 6 `SetTimer` différés | bannière de fin de boot, `karabiner.regenerate()` | `Logger.success("Daemon ready")` puis `event_loop.run{...}` |

**Comment le câblage se fait, par driver** — c'est là que la lecture devient difficile :

| | Windows | macOS | Linux |
|---|---|---|---|
| Mécanisme | **912 globales de portée fichier** | `require` + injection `M.init(state)` | locales dans un `main()` + tables d'options |
| Ce qui décide l'ordre | la **position** du `#Include` (149 dans le point d'entrée) | l'ordre des `require` + une séquence d'appels écrite à la main | l'ordre des statements dans `main()` |
| Objet d'état partagé | aucun (`lib/app_state.ahk` est 35 lignes de commentaire, zéro code) | `modules/keymap/state.lua` `CoreState` (portée keymap) + `hs.settings` + 10 `_G.*` | les locales de `main()`, projetées dans deux tables ad hoc |

**Conséquence pratique** : sur Windows, la liste d'`#Include` **est** le graphe de
dépendances, et l'ordre y est sémantique. Un fichier a été délibérément sorti de son dossier
d'origine et hissé plus haut dans la liste pour qu'une globale sentinelle soit déclarée avant
son chargeur. Il y a 11 méta-tests dont le seul sujet est de comparer des positions de texte
dans ce fichier, et **64 contraintes d'ordre écrites en prose** (`before` / `after` / `order`)
dans le point d'entrée. Rien d'autre ne déclare ces dépendances : les 3 198 symboles AHK
vivent dans **un seul espace de noms plat**, avec 1 760 arêtes de couplage fichier→fichier
qu'aucun fichier n'annonce.

**Sur macOS, le couplage se lit dans la profondeur de la chaîne de `require` : 15.** La plus
profonde, chaque saut vérifié :

```
macos/init.lua
 → ui/menu/init.lua → ui/menu/menu_hotstrings.lua
 → modules/keymap/init.lua → modules/keymap/llm_bridge.lua
 → modules/llm/prediction_engine.lua
 → modules/keylogger/init.lua → watchers → log_manager → aggregator → aggregator/events → aggregator/core
 → lib/timings.lua → lib/toml/reader.lua → _shared/lua/toml_codec/reader.lua → _shared/lua/logger/shim.lua
```

Lisez-la comme un énoncé de risque de changement : **ouvrir le menu Hotstrings charge
transitivement le keylogger, son agrégateur SQLite et le lecteur TOML partagé.**

⚠ **Et une partie du couplage est invisible à la lecture.** Deux mécanismes à connaître :

- **`package.loaded` sert de bus de callbacks global.** 25 sites de production le touchent, et
  deux y **écrivent de faux modules** pour se parler : `menu_llm/models_manager.lua:376-382`
  publie `download_abort_hook` / `download_retry_hook`, que
  `ui/download_window/init.lua:111-112` lit. **Aucun des deux ne `require` l'autre.** Le seul
  moyen de trouver ce lien est de greper la chaîne littérale.
- **`pcall(require, …)` est utilisé pour tout**, pas seulement pour l'optionnel : 172 sites,
  et sur Linux **tous** les sous-systèmes majeurs (tray, menu, LLM, updater, gestes,
  raccourcis, webview, kanata…) sont chargés ainsi, en 12 blocs consécutifs. Conséquence :
  une faute de frappe dans un chemin de module ne casse rien, elle fait disparaître la
  fonctionnalité en silence.

**Extinction** : 6 étapes sur Windows (`OnExit`), 8 sur macOS (`hs.shutdownCallback`), 3+5
qui se recouvrent sur Linux (handler de signal + queue post-boucle). Les trois listes sont
maintenues à la main et **aucune n'est dérivée de ce qui a réellement démarré**.

---

## 5. Le trajet d'une frappe

L'utilisateur tape `w`, complétant le déclencheur `btw` dont le remplacement est
`by the way`. Les colonnes sont numérotées identiquement pour être diffées.

| Étape | Windows | macOS | Linux |
|---|---|---|---|
| **1. Capture** | `InputHook` en mode `"V"` (pass-through). Le `w` **a déjà atteint l'application** | `hs.eventtap` → `onKeyDownRaw`. Le `w` **n'a pas atteint l'application** : le tap peut le consommer | lecture evdev → `on_char`. Mode observe, pas d'`EVIOCGRAB` : le `w` **a déjà atteint l'application** |
| **2. Gardes** | `A_IsSuspended`, gating de catégorie, branche de sélection UIA, puis `Critical("On")` | jeu de sortie rapide par keycode, drain d'écho synthétique, fenêtre ignorée | garde d'injection en cours (met en file), pré-passe CapsWord |
| **3. Tampon + plafond** | append, trim à **256** ; au trim, `StartIsWordBoundary := false` | append, trim à **500** codepoints ; idem | append, trim à **256** ; ⚠ **pas de drapeau de frontière de mot** |
| **4. Recherche de candidat** | **deux chemins**, tous deux balayés : STAR (suffixes contre l'index étoile) et END-CHAR (si le caractère est un terminateur). Le plus long gagne, toutes catégories | **trois passes en ordre fixe** : bucket auto, bucket terminateur, feature repeat. **La première correspondance retourne** | **un** bucket par dernier codepoint minuscule, plus long d'abord. ⚠ **aucun chemin terminateur** |
| **5. Prédicat** | égalité de suffixe, repli de casse sauf `C`, frontière de mot, suppression « étoile couvre le corps » | `would_fire()` — **source de vérité unique partagée avec l'aperçu infobulle** | égalité de suffixe + caractère précédent |
| **6. Collisions** | longueur ▸ priorité ▸ ordre de groupe ▸ séquence ; étoile bat un end-char de longueur égale | longueur ▸ priorité ▸ **`is_word`** ▸ ordre de groupe ▸ séquence | ⚠ **longueur seulement** |
| **7. Porte de délai** | portes d'activation temporelle | porte de vitesse de frappe, contournée pour la magic key | ⚠ aucune |
| **8. Émission** | **un** `SendInput` atomique sous `Critical` : backspaces + remplacement + terminateur. Toujours le déclencheur complet | `eraseChars` **puis** `emit` — deux étapes ; suppressions minimisées par préfixe commun | trois phases avec un `sleep` entre |
| **9. Terminateur** | effacé avec le déclencheur puis réinjecté dans la même rafale, sauf s'il est dans la liste des consommés | consommé et rejoué par un module dédié | **jamais consommé** (mode observe) |
| **10. Resynchro tampon** | épissage du tampon pour refléter l'écran | épissage à l'offset du déclencheur | ⚠ **tout le tampon est jeté** |
| **11. Nettoyage** | reset du tampon de préfixe, suppression du watcher différée | compteurs d'écho synthétique armés, infobulle masquée | drain de la file d'injection, rejeu des caractères physiques |

**L'étape 4 est la plus lourde de conséquences.** Windows balaye les deux chemins et laisse
le plus long gagner ; macOS retourne à la première correspondance auto, donc **un
déclencheur terminateur plus long ne peut jamais battre un déclencheur auto plus court sur
macOS alors qu'il le fait sur Windows** ; Linux n'a pas de chemin terminateur, donc une
hotstring avec `auto_expand = false` **ne se déclenche jamais sur Linux** — son chargeur ne
lit même pas le champ.

**L'étape 8 explique pourquoi `backspace_count` du corpus n'est pas portable** : pour `btw`,
la bonne réponse est 3 sur Windows et Linux (la frappe est déjà à l'écran) et 1 sur macOS
(elle est consommée, plus l'optimisation de préfixe commun). Les trois produisent
`by the way`. Le corpus a tort, pas macOS.

**La machine à états n'est écrite nulle part.** `docs/STATE_TRANSITION_MATRIX.md` décrit le
cycle de vie du *driver*, pas le tampon. Les variables d'état réelles ne sont **nommées**
que sur Windows (`HSE_Buffer`, `HSE_StartIsWordBoundary`, `HSE_Suppressed`,
`HSE_RebuildInProgress`, `HSE_LastEndChar`), et les commentaires de leur fichier sont la
chose la plus proche d'une spec écrite dans le dépôt.

**Aucun driver n'a d'annulation d'expansion.** Ctrl+Z est traité uniquement comme un
événement qui invalide le tampon.

---

## 6. Les sous-systèmes

Pour chacun : où il vit, comment il est câblé, ce qui est partagé, et ce qui diverge
aujourd'hui.

### 6.1 Hotstrings

**Cinq implémentations du matcher existent** ; trois tournent en production.

| # | Implémentation | Utilisée par |
|---|---|---|
| 1 | `_shared/lua/hotstring_engine/init.lua` (281 l) | **Linux uniquement** — malgré une docstring affirmant « partagée par tous les drivers Lua » |
| 2 | `macos/modules/keymap/{registry*,expander}.lua` (2 302 l) | macOS |
| 3 | `windows/lib/hotstrings/hotstring_match.ahk` + `hotstring_engine_main.ahk` | Windows |
| 4 | un matcher **écrit dans un fichier de test AHK** | personne (fixture) |
| 5 | un algorithme de référence JS dans un script de mutation | personne |

**Données** : `_shared/modules/hotstrings/<catégorie>.toml`. La forme réelle d'une entrée :

```toml
[[assign]]
" #!" = { output = " := ", is_word = false, auto_expand = true, is_case_sensitive = true, final_result = true }
```

⚠ `_shared/modules/hotstrings/schema.md` décrit un **format qui n'existe pas** (`trigger` /
`replacement` / `flags[]`). Ignorez-le ; les champs réels sont ceux ci-dessus plus
`is_case_sensitive_strict` (utilisé par 1 302 entrées, documenté nulle part) et les blocs
`[_meta]` / `[_meta.sections]` / `sections_order` / `section_priorities`.

**Priorité** : `individual > section > file > défaut de source`, avec les rangs
`common: 10`, `package: 30`, `personal: 50` dans `priority.json`. ⚠ Linux n'a **aucune**
résolution de priorité, et Windows et macOS divergent sur trois points (repli quand une
candidate n'a pas de priorité : 50 vs 10 ; catégorie `custom` ; un niveau de départage
supplémentaire sur macOS).

**Le seul composant du moteur qui n'a jamais dérivé** est le catalogue de terminateurs :
une source (`_shared/core/domain/Terminators.spec.js`), un générateur qui émet **les deux
cibles en une passe** (AHK + Lua). C'est le patron à copier pour le reste.

### 6.2 Hotstrings dynamiques

Expansions calculées : `@p★` → un numéro de téléphone, dates relatives, informations
personnelles. macOS a un moteur de règles complet ; Linux n'a que `@<lettre>` plus trois
règles de date, ignore l'activation par section, et ⚠ **son magic key par défaut est `\` et
non `★`** — le point d'entrée écrase la valeur correcte du manifeste, et l'injecteur de
libellés i18n renvoie aussi `\`, donc tous les libellés `★` de l'UI Linux affichent un
antislash.

### 6.3 Remap : disposition et tap-hold

| | Windows | macOS | Linux |
|---|---|---|---|
| Disposition de base | émulée en processus, table écrite à la main | **ressource OS installée** (`.bundle` + sélection TIS) | `(defalias)` écrit à la main dans le `.kbd` |
| Tap-hold | 14 modules `#HotIf` (dont **4 templates de 60 lignes identiques à l'octet**) | JSON `complex_modifications` généré pour Karabiner | directives `(tap-hold-press …)` de kanata |
| Touches mortes | machine à états dans `layout.ahk` | dans le bundle `.keylayout` | un seul `@deadtrema` |
| Seuil de maintien | **par touche**, 200–350 ms | **un seul global, 1000 ms** | **par touche**, 200–350 ms |

`_shared/tap_hold/defaults.toml` **n'est pas un fichier partagé** : les lignes 17–163
servent Windows et kanata, les lignes 168–430 servent macOS, avec des ids différents
(`left_ctrl` vs `left_control`), des actions différentes (`paste` vs `cut` sur la même
touche) et un seuil 3 à 5 fois différent. Le chargeur AHK ignore chaque en-tête `[hs_*]`,
le lecteur macOS ignore chaque `[tap_hold.*]`, et rien ne les recoupe.

⚠ Le générateur kanata de Linux produit aujourd'hui une configuration **inchargeable**
(quatre alias pendants, blocage B3 du plan).

### 6.4 Gestes

Il n'y a **pas trois reconnaisseurs** : il y a un reconnaisseur (macOS, frames tactiles
brutes), une délégation à l'OS (Windows programme le registre pour que le pilote émette
`Ctrl+Win+Shift+F1..F10`, et l'AHK capture ces raccourcis), et un squelette (Linux, dont
le lecteur libinput est un stub qui journalise « deferred »).

Slots : 10 sur Windows (limite du pilote), 39 sur macOS, 39 déclarés et inatteignables sur
Linux. L'espace de slots est **déclaré six fois** ; la barrière n'en couvre que trois.

Les défauts sont déclarés **deux fois par driver** (registre du driver + manifeste partagé),
et la paire macOS a déjà divergé — le driver ne lit qu'**une seule** valeur du manifeste, le
reste est de la donnée morte.

### 6.5 Actions et raccourcis

C'est la zone la plus fragmentée du dépôt, et celle qui répond à la question « comment
j'ajoute une action ? ». Aujourd'hui : **cinq catalogues**, trois sources de libellés,
quatre dialectes de notation d'accord.

Windows a trois couches de liaison dont **deux se recouvrent** et lient la même intention à
deux touches physiques différentes (l'une résout contre la disposition Ergopti, l'autre
contre celle de l'OS, parce qu'elle est enregistrée avant l'inclusion du remappage). macOS
a un module de slots assignables qui est du **matériel mort** : aucun sélecteur, aucune
entrée de menu, aucune clé de config ne peut assigner un slot. Linux n'enregistre **aucun**
raccourci clavier — son « shortcuts manager » est un sac d'utilitaires de texte.

**L'équivalence de modificateur qui compte réellement dans ce dépôt n'est pas
`cmd ⇄ ctrl`, c'est `win ⇄ ctrl`** : la couche de raccourcis propre au driver est sur
`Win+lettre` sur Windows et sur `Ctrl+lettre` sur macOS, parce que `Ctrl` est pris par les
applications sur Windows et `Cmd` l'est sur macOS. `cmd ⇄ ctrl` est une **seconde**
équivalence, nécessaire seulement quand l'action signifie « envoie le raccourci de
l'application » (copier/coller/annuler). Voir le runbook §10.2.

### 6.6 LLM et prédiction

```
_shared/modules/llm/*.json          données : fournisseurs, modèles, profils, défauts
_shared/core/domain/*.js            implémentation de référence JS (jamais exécutée par un driver)
_shared/lua/llm/                    runtime Lua : parser (842 l), prompt_builder, profile_selector
   ├── macos : deux shims fins + un wrapper i18n
   ├── linux : consomme prompt_builder + profile_selector, PAS le parser
   └── windows : prompt_builder « généré » ; parser écrit à la main (946 l)
```

⚠ Trois pièges à connaître :

1. Le générateur de prompt-builder **ne lit jamais** le Lua dont il prétend dériver. Toutes
   ses constantes sont des littéraux JS retapés. Elles ont déjà divergé : le correctif qui
   fait que `llm_context_length` a un effet n'a jamais été porté côté AHK.
2. **Six** implémentations de « POST une complétion » existent (curl enfant, trois objets
   COM WinHTTP distincts, `hs.http`, `io.popen` bloquant). Le port `HttpClient` existe dans
   les trois drivers et n'est utilisé que par le chemin MLX de macOS.
3. Sur Linux, la réponse est renvoyée verbatim : un `<think>…</think>` de modèle de
   raisonnement est **tapé dans le document de l'utilisateur**.

`menu_persistence_contract.json` (436 l) documente que les deux drivers écrivent des **clés
différentes, des unités différentes et des types différents** pour les mêmes trois réglages
(debounce en ms vs en secondes ; raccourci en chaîne plate vs table imbriquée). Un
`config.toml` n'est donc pas portable d'un OS à l'autre. Ses deux validateurs Python ne sont
câblés nulle part, et l'un pointe vers un chemin disparu depuis un renommage.

### 6.7 Métriques (keylogger)

Trois pipelines, une base de données déclarée partagée, trois formes sur disque.

| | Windows | macOS | Linux |
|---|---|---|---|
| Capture | `InputHook("V L0")` — voit la sortie *résolue* du remappage | `hs.eventtap` (6 types d'événements) | evdev observe |
| Filtres de confidentialité | 4 (applications désactivées, champ mot de passe *fail-closed*, processus d'auth système, titre de navigation privée) | 4 (observateur AX pour le champ sécurisé) | ⚠ **1** : sous-chaîne contre 8 noms d'app en dur |
| Flush | timer 200 ms → file RAM → tick d'ingestion 5 s | piloté par événement, **écriture disque synchrone** dans le flush | ⚠ **seulement à la sortie du processus** |
| Agrégation | dans un processus détaché | en processus | aucun marcheur |
| Disque | `metrics/by_device/<uuid>/{device.json,data.sql,today.log}` | idem + un `db.sqlite` en tmpdir | un unique `metrics.sqlite`, pas de `by_device/`, pas de synchro multi-appareils |
| Désactivable | oui (opt-out) | oui (opt-in par conception) | ⚠ **non** |

`_shared/data/db/schema.sql` est vraiment la source DDL unique — les trois l'exécutent.
Mais **aucun runner de migration n'existe** sur aucun driver, et
`migrations/0001_initial.sql` est un fichier de commentaires sans une seule instruction SQL.
Le schéma utilise `CREATE TABLE IF NOT EXISTS` partout : les changements additifs
s'appliquent seuls, les destructifs échouent silencieusement.

⚠ Quatre problèmes de confidentialité vivants sont listés en §13.

### 6.8 Menu tray

Le manifeste `menu_manifest.json` est généré par une projection **verbatim** des tables
`[menu.*]` du manifeste de fonctionnalités : aucune validation, aucune normalisation,
aucune expansion de plateforme au build. Toute la sémantique vit dans deux « marcheurs »
runtime, l'un AHK, l'autre Lua — c'est pourquoi ils peuvent diverger, et divergent.

| | Windows | macOS | Linux |
|---|---|---|---|
| Lignes de code de menu | 9 456 | **18 613** | 833 |
| Part rendue par le marcheur générique | **45 %** | **31 %** | **0 %** |
| Sites créant une ligne | 265 | 399 | 101 |
| Libellés en dur | 0 | 1 | **101 (français)** |

Le type d'item le plus fréquent du manifeste est `dynamic` — l'échappatoire « j'abandonne,
appelle du code driver ». Les 14 capacités manquantes qui expliquent chaque `dynamic` sont
recensées dans le plan (§6, lot 5).

⚠ Trois lignes du manifeste sont marquées exclusives à une plateforme alors qu'elles
existent sur les deux drivers : le manifeste **désinforme activement** sur le produit.

### 6.9 Infobulle, widget WPM, spotlight

L'infobulle est **trois implémentations indépendantes**. `_shared/modules/tooltip/`
contient 1 483 lignes de modules JS de référence + une spec normative de 392 lignes… que
**rien ne `require`**. La barrière nommée « tooltip corpus parity » ne charge aucun des deux
modules JS qu'elle prétend comparer ; le test macOS rejoue un clone interne au fichier de
test au lieu du renderer ; le test AHK ne compare jamais les 6 valeurs d'or du corpus.

Ce qui **fonctionne** dans cette zone, et sert de modèle : `constants.toml` est
véritablement chargé par les deux drivers avec échec bruyant si une clé manque. ⚠ Sauf deux
clés `[positioning]` qui n'atteignent jamais Windows, avec trois commentaires affirmant le
contraire.

Linux n'a **ni infobulle ni widget WPM** : son `tooltip_renderer` shell-oute vers `yad` en
ne gardant que le texte brut, et il a zéro appelant. Les utilisateurs Linux n'ont donc
aucun aperçu de hotstring ni de prédiction.

`spotlight` (un halo autour du curseur) est Windows-only comme dossier, et existe sur macOS
dans un fichier d'actions ; ses 9 constantes sont dupliquées sans source partagée, et le
canal vert a déjà dérivé de 1.

### 6.10 Fenêtres webview

C'est la partie **la mieux mutualisée du dépôt** : 31 684 lignes de frontends dans
`_shared/ui/`, 14 applications, consommées sans friction.

Le pont JS↔hôte : `makeHostBridge(name)` sonde `window.chrome.webview.postMessage`
(WebView2, Windows) puis `window.webkit.messageHandlers[name].postMessage`
(WKWebView macOS / WebKitGTK Linux).

⚠ **Ce n'est un protocole unique que dans le sens sortant.** Le retour est trois mécanismes
différents, branchés à l'intérieur des pages partagées : push WebView2 (Windows), **polling
à 0,3 s** de `window._lua_request` (macOS), et un canal requête/réponse
`__hostBridgeResponse` en base64 + polling 2 s (Linux). Et sur Windows le nom du pont est
**structurellement sans effet** : WebView2 n'expose qu'un canal par webview, donc le nom est
jeté à l'arrivée. Le « contrat de nom de handler » documenté dans `host_bridge.js` ne
gouverne donc que 2 drivers sur 3 — et ce n'est écrit nulle part.

Couverture : Windows héberge **13 des 14** applications, macOS **14 sur 14**, Linux **3 sur
14** (les 14 handlers existent, 12 sont inatteignables, et 3 ids ne peuvent pas résoudre
leur module à cause d'un écart de convention de nommage).

Et **aucune des 14 fenêtres ne vit au même chemin sur les trois drivers.**

### 6.11 Socle transverse

| Bibliothèque | État |
|---|---|
**TOML** | **exemplaire.** Un codec partagé (1 733 l), trois shims d'une ligne sur macOS, une barrière de pureté, deux corpus rejoués par les trois suites. Copiez ce patron |
**locale (lookup + cascade)** | bon. Un cœur partagé, deux wrappers fins, un corpus. L'AHK réimplémente la cascade (inévitable) et s'accorde |
**updater (algorithmes purs)** | bon. `version` + `release_parser` partagés et rejoués partout ; le transport est triple, majoritairement à raison |
**logger** | ⚠ deux implémentations de ~1 100 lignes de la même spec de 300 lignes, plus un cœur partagé de 281 lignes que **seul Linux charge — et sur Linux rien n'est écrit** |
**paths** | ⚠ Windows et macOS résolvent en un point (avec contournements documentés) ; **Linux n'a aucun résolveur**, d'où deux bugs vivants |
**i18n (couche au-dessus de locale)** | ⚠ trois wrappers indépendants aux fonctionnalités différentes ; la table des 21 locales écrite en dur 3 fois (16 entrées sur Linux) ; `_shared/ui/i18n.js` n'a **aucune** chaîne de repli |
**healthcheck** | bon, sauf que `warn_count`/`err_count` signifient deux choses différentes derrière un seul nom de champ |

---

## 7. Ports et adaptateurs

L'ADR-001 déclare une architecture hexagonale : 20 contrats de ports en JS, implémentés par
un adaptateur par driver, et les modules de fonctionnalités ne devraient toucher que des
ports.

**Les 20 ports** (méthodes entre parenthèses) :

`AppLauncher` (launch, launchWithArgs, isRunning) · `Clipboard` (read, write, save, restore
+4 optionnelles) · `Crypto` (sha256 — **et rien d'autre**) · `FileSystem` (read, write,
append, exists, delete) · `GraphicsRenderer` (createWindow, destroyWindow, drawBitmap, show,
hide) · `HttpClient` (post, cancel, isActive) · `KeyState` (isDown, isUp) · `KeyboardHook`
(start, stop, isRunning, refreshContext, getContext) · `MouseControl` (getPos, setPos,
getMonitorCount, getMonitorBounds) · `NetworkInfo` (getSsidHash — **jamais le SSID brut**,
getSignalStrength, isInternetReachable, isVpnActive) · `Notifier` (send) ·
`ProcessLifecycle` (start, stop, onAppLaunch, onAppQuit, onFocusChange, getForegroundApp) ·
`SecureFieldDetector` (isSecureField, isSecureApp, refresh) · `Storage` (set, get, delete,
has, keys, clear) · `TextSender` (send, eraseChars, pressKey) · `TimerScheduler` (after,
every, cancel, cancelAll, activeCount) · `TooltipRenderer` (show, hide, isVisible,
updateElement) · `TrayMenu` (setIcon, setMenu, setTooltip, destroy) · `WindowInfo`
(getFocused, getAll) · `WindowManager` (activate, exists, kill, getTitle, getList,
getFocused)

`adapters/` contient aussi des helpers d'isolation OS qui **ne sont pas des ports** et c'est
volontaire : `shell_runner` (les trois), `event_tap_guard` / `json_codec` / `toml_cache`
(macOS), `event_loop` (Linux). La règle est « `adapters/` est la couche d'isolation OS », pas
« exactement les 20 ports ».

**⚠ Ce que la couche vaut réellement, mesuré :**

| | Windows | macOS | Linux |
|---|---|---|---|
| Adaptateurs avec **zéro** appelant de production | **12 / 21** | 2 / 24 (composition entre adaptateurs, légitime) | **11 / 22** |
| Lignes d'adaptateur mortes | **1 361** | ~0 | **1 740** |
| Sites de primitives OS **hors** `adapters/` | **1 854** | 1 622 lignes `hs.*` | 61 shell-outs + 54 quotings manuels |
| Barrière de reachability | **aucune** | oui | **aucune** |

**Donc : la couche est porteuse sur macOS et décorative sur les deux autres.** Concrètement,
si vous suivez la piste `expander.lua` → `adapters/text_sender` → `TextSender.spec.js` sur
macOS, les trois sauts sont vrais. Sur Windows la même piste est un **piège** : la spec en
prose vous dit que l'implémentation AHK de `KeyboardHook` est une fonction du module
keylogger, l'adaptateur prétend le contraire, la barrière de conformité valide l'adaptateur,
et le code qui tourne implémente la fonction du module. Et le diagnostic santé affiche
« 100 % sain » pour les 12 adaptateurs morts.

**Ce qu'il faut en faire aujourd'hui** : pour une nouvelle interaction OS, préférez le port
s'il existe **et a déjà du trafic de production** (`FileSystem`, `TextSender`, `Clipboard`,
`KeyState`, `GraphicsRenderer`, `WindowManager`, `WindowInfo`, `NetworkInfo`, `Notifier`,
`TimerScheduler`, `HttpClient`, `SecureFieldDetector`, `TrayMenu`, `KeyboardHook`). Pour les
autres, lisez le plan (§6, lot 10) avant d'investir.

---

## 8. Codegen : ce qui est généré et pourquoi

**Rien n'est transpilé dans ce dépôt.** Tous les générateurs émettent de la **donnée**. Deux
d'entre eux portent en plus de l'AHK écrit à la main sous forme de littéraux de chaîne
dans un générateur JS, ce qui crée l'illusion d'une transpilation — et ⚠
`_shared/README.md` documente le contraire comme un fait.

Le prétexte historique « l'AHK ne peut pas lire les données partagées » est **faux** :
`windows/lib/json.ahk` et `windows/lib/toml/` existent, et l'AHK lit déjà au runtime
`menu_manifest.json`, `priority.json`, les 21 locales, tous les TOML de hotstrings et
`profiles.json`. Le codegen n'a donc jamais été une question de **capacité**, seulement de
**coût de boot** et de **pré-résolution**.

**La règle, applicable mécaniquement :**

> On génère uniquement quand le driver ne peut pas lire la source, ou quand la lire au boot
> coûterait des millisecondes mesurables ; sinon on lit la donnée au runtime. Et quand on
> génère, on génère de la **donnée**, jamais de la **logique**.

| Artefact généré | Source | Verdict |
|---|---|---|
`{windows,macos}/_generated/features_manifest.*` | `manifest.toml` (3 313 l) | **garder** — collapse en 263/714 lignes pré-résolues, résout le filtre de plateforme et l'aplatissement |
`_shared/modules/menu/menu_manifest.json` | tables `[menu.*]` | **garder** — 64 lignes de générateur, les deux drivers lisent déjà le JSON au runtime |
`_shared/lua/keymap/terminators_catalogue.lua` + `windows/_generated/terminators.ahk` | `Terminators.spec.js` | **garder le catalogue** ; sortir les 130 lignes de logique de classe du générateur vers une source AHK écrite à la main, pour que les deux côtés aient la **même forme** (donnée générée + logique écrite) |
`_shared/ui/metrics_typing/_generated/keycode_data.js` | `azerty.json` | **garder** — les pages partagées se chargent en `<script src>` sans bundler |
`_shared/core/ports/contracts.json` | les 20 specs | **garder**, et l'utiliser sur les trois drivers (Windows a des tests de surface écrits à la main, Linux une liste de 9 noms en dur) |
`windows/_generated/prompt_builder.ahk` | *prétend* `prompt_builder.lua` | **supprimer le générateur** : il ne lit rien. Déplacer le fichier tel quel en source écrite à la main, le corpus devient le contrat |
`windows/_generated/llm_profiles_data.ahk` | `legacy_ids.json` + `profiles.json` | **remplacer par une lecture runtime** : 215 lignes de générateur pour livrer une Map de 4 entrées, dans un fichier qui parse déjà le JSON voisin |
`{macos,linux}/_generated/config_template.toml` | `manifest.toml` | **aucun lecteur** — supprimer la sortie ou lui donner un premier-boot |
`tools/codegen/codegen-prompt-builder-hs.cjs` | — | **supprimer** : 34 lignes qui n'émettent rien, dont la docstring dit qu'elles existent pour documenter une asymétrie |

**La commande à lancer** après avoir édité une donnée partagée : `npm run codegen` (alias de
`build:domain`). ⚠ Elle lance 6 des 9 générateurs vivants : `codegen:contracts` et
`gen:diagram` en sont exclus (le second sans justification), et un générateur de corpus n'a
aucun alias npm et code en dur le chemin absolu de la machine du mainteneur.

---

## 9. Les tests

Quatre suites. Elles pèsent **96 % de la production** (≈ 207 000 lignes).

| | Windows | macOS | Linux | Barrières JS |
|---|---|---|---|---|
Runner | `tests/run_all.ahk` (1 233 l) | `tests/run.lua` | `tests/run.lua` | `tools/test/run-js-suite.cjs` |
Enregistrement | **manuel : 942 `#Include`** | balayage du système de fichiers | balayage | tableau `CHECKS` |
Isolation inter-fichiers | inutile (un processus, un espace de noms) | **purge de `modules.*`/`adapters.*`/`lib.*`/`ui.*` entre chaque fichier** | ⚠ **aucune** |
Stubs | `test_stubs.ahk` (711 l) | `tests/stubs/hs.lua` (727 l) | ⚠ **aucun** |
Assertions | `AssertEqual(attendu, obtenu)` | `assert_eq(obtenu, attendu)` | idem macOS | — |

⚠ **Deux pièges immédiats** :

1. **L'ordre des arguments d'assertion est inversé** entre AHK et Lua, sur 1 587 sites AHK.
   Un test porté d'un driver à l'autre échange silencieusement attendu et obtenu — le verdict
   reste juste, le message d'échec se lit à l'envers.
2. **`AssertEqual` est insensible à la casse** (l'opérateur `!=` d'AHK v2 l'est). Le dépôt
   connaît le piège et l'a documenté ailleurs, mais le helper l'utilise. Conséquence :
   `AssertEqual("BTW", "btw")` passe.

**Le paradigme dominant n'est pas le test unitaire, c'est le méta-test** : 664 des 829
fichiers de test Windows (80 %) lisent le **texte source** du driver et assertent des
invariants structurels. C'est le mécanisme par lequel les conventions sont épinglées dans un
dépôt sans analyseur statique. C'est aussi ce qui rend un déménagement de dossier dangereux :

⚠ **`_DriverDirConcat(RelDir)` retourne `""` quand le répertoire n'existe pas**, et
`InStr("", x)` vaut 0 — donc **toute assertion « ne doit pas contenir » passe à vide**. 220
sites d'appel, 24 noms de répertoires en dur. Le jumeau macOS est sûr par accident : il
retourne `nil`, et `nil:find(...)` lève. Corrigez le helper avant de renommer quoi que ce
soit (plan, lot 2.1).

**Le corpus partagé** est le mécanisme de parité : 16 fichiers, 258 vecteurs, plus 168
vecteurs de contrat exportés par les specs de ports. L'ADR-006 dit que **toutes** les suites
doivent les consommer. ⚠ Mesuré : **2 corpus sur 16** sont réellement rejoués par les trois
drivers ; 9 sur 16 ne le sont que par un ou deux ; les « skips » Linux sont pour six d'entre
eux des `assert_true(true, "skip acknowledged")`.

**Comment lancer** :

```bash
npm run test:js        # ~100 barrières cross-driver + parité + single-source
npm run test:hs        # suite macOS   (lua tests/run.lua)
npm run test:linux     # suite Linux   (luajit/lua tests/run.lua)
# Windows : pointer AutoHotkey64.exe sur windows/tests/run_all.ahk
npm run verify         # sélectionne les barrières selon les fichiers modifiés
```

⚠ `npm run verify` ne sélectionne **que** la barrière JS quand vous éditez un vecteur de
corpus — c'est-à-dire précisément le type de fichier que l'ADR-006 déclare obligatoire pour
tous les drivers.

---

## 10. Runbooks — comment faire X

Chaque runbook donne la procédure **d'aujourd'hui**, puis la cible après le lot
correspondant du plan. Si l'écart vous choque, c'est l'intérêt du plan.

### 10.1 Ajouter une action commune aux trois OS

**Exemple** : « copier le mot courant », déclenchée par `mod+alt+w`.

**Aujourd'hui — 8 fichiers minimum, et elle restera non liable sur macOS et Linux :**

1. `_shared/modules/gestures/actions.toml` : ajouter `[sg_actions.copy_word]` avec
   `platform = "all"`, puis ajouter l'id à `[sg_order].items` dans le bon groupe.
2. `_shared/data/locales/en.json` : ajouter `"sg_actions.copy_word"`, puis
   `python tools/locale/check_locales.py --fix` pour la propager aux 20 autres locales.
3. `windows/modules/gestures/actions.ahk` : ajouter la lambda dans `GESTURE_ACTIONS`.
4. `macos/modules/gestures/actions.lua` : ajouter l'entrée `sg(...)`.
5. `linux/modules/gestures/manager.lua` : ajouter une branche `elseif` dans
   `_execute_action` **et** une entrée dans la table `ACTION_LABELS` (français en dur).
6. Pour la lier à un accord clavier : `windows/lib/feature_state.ahk`
   `KEYBOARD_SHORTCUT_DEFAULTS`, **plus** un support de préfixe dans
   `_KeyboardSlotSendCode` (qui ne comprend que 4 préfixes — `win_alt_` n'existe pas).
7. macOS : rien à faire, parce qu'**il n'y a aucun sélecteur** capable d'assigner un slot.
8. Linux : rien à faire, parce qu'**aucun raccourci clavier n'est enregistré**.

**Cible (plan, lot 6) — 2 fichiers, aucun fichier de driver :**

```toml
# _shared/modules/actions/actions.toml
[actions.copy_word]
platforms     = ["windows", "macos", "linux"]
label_key     = "actions.copy_word"
emit          = "ctrl+shift+left cmdorctrl+c"
emit_macos    = "alt+shift+left cmdorctrl+c"   # macOS navigue par mot avec Option
default_chord = "driver+alt+w"
ports         = []
```

+ la clé i18n. Résultat : `Win+Alt+W` sur Windows, `Ctrl+Alt+W` sur macOS, `Super+Alt+W` sur
Linux ; l'action apparaît dans le sélecteur des trois, liable à un geste, un tap-hold ou un
autre accord sans toucher au code.

### 10.2 Ajouter une action spécifique à un OS (« cmd+lettre sur macOS vs ctrl+lettre ailleurs »)

**Corrigeons d'abord la question**, parce que la mesure montre que la réponse intuitive est
insuffisante. Sur les 24 actions implémentées comme une pure émission de frappe sur **les
deux** drivers : **11 sont identiques à l'octet**, **2** ne diffèrent que par `ctrl → cmd`,
et **11 diffèrent réellement** (macOS utilise `alt` pour la navigation par mot, `cmd+↑/↓`
pour les bornes de document, `cmd+w` au lieu d'`alt+F4` pour fermer, `cmd+ctrl+f` au lieu de
`F11` pour le plein écran).

Un unique jeton `mod` ne résout donc que **2 cas sur 24**. Il faut **deux modificateurs
logiques et des overrides par OS de première classe** :

| Jeton logique | Signification | Windows | macOS | Linux |
|---|---|---|---|---|
| `cmdorctrl` | *le modificateur que les applications utilisent pour leurs raccourcis* | `ctrl` | `cmd` | `ctrl` |
| `driver` | *le modificateur réservé à la couche Ergopti+* | `win` | `ctrl` | `super` |

Les jetons littéraux `ctrl`, `alt`, `shift`, `cmd`, `win`, `super`, `altgr` restent
disponibles pour les cas réellement spécifiques.

**Aujourd'hui** : il n'existe aucune notation neutre. Quatre dialectes coexistent (préfixes
AHK `^+!#`, forme touche-préfixe `SC138 & SC01C`, tableau de modificateurs Hammerspoon,
`key_code` Karabiner, `xdotool`). Le seul fichier exprimant une équivalence par OS est
`_shared/modules/gestures/modifier_chords.json` — mais c'est une table de *modificateurs*,
pas une *notation d'accord* : les ids d'action qui en résultent sont eux-mêmes spécifiques à
la plateforme (`win_a` / `cmd_a` / `super_a`), donc un accord ne peut jamais être nommé
portablement.

**Cible — trois cas de figure, tous déclaratifs :**

```toml
# 1) Même action, accord logique unique
[actions.close_window]
platforms  = ["windows", "macos", "linux"]
emit       = "alt+f4"
emit_macos = "cmdorctrl+w"

# 2) Même action, accord de déclenchement différent par OS
[actions.paste_plain]
default_chord       = "driver+v"
default_chord_macos = "cmd+shift+v"

# 3) Action qui n'existe que sur un OS
[actions.stage_manager]
platforms = ["macos"]
native    = "space.stage_manager"     # → macos/modules/actions/space.lua
ports     = ["WindowManager"]
reason_key = "platform.stage_manager_macos_only"
```

Windows et Linux n'ont **aucune** édition à faire pour le cas 3 : leurs chargeurs filtrent
sur `platforms`, l'entrée de menu s'affiche grisée avec l'infobulle de `reason_key`, et un
contrôle au démarrage vérifie que toute action déclarée pour ce driver a un `emit` ou un
`native` résoluble — **échec bruyant au boot** au lieu d'une disparition silencieuse.

**Le piège AHK à connaître** (il survivra au refactor) : pour un accord dont le suffixe est
un **caractère**, le traducteur doit émettre `RetrieveScancode(<char>)` et non le caractère
brut, sinon l'accord atterrit sur la mauvaise touche physique sous l'émulation Ergopti.
C'est exactement le défaut de la couche B actuelle. Pour une touche nommée (`enter`,
`home`…), le nom AHK brut est correct.

### 10.3 Ajouter une entrée de menu

**Aujourd'hui**, selon ce que vous voulez :

- **Un toggle de fonctionnalité simple** : ajouter l'entrée dans `manifest.toml` (section
  sémantique + `platforms`), ajouter une ligne `{"type":"feature","id":…}` dans la table
  `[menu.<sous-menu>]`, `npm run build:domain`, puis vérifier que le marcheur générique de
  votre driver gère bien ce type (⚠ le marcheur macOS **saute silencieusement** `toggle` et
  `feature`, et lève un WARN sur `letter_picker`).
- **Tout le reste** (coche liée à un état, libellé composé, liste dynamique, groupe radio,
  dialogue, compteur) : le manifeste ne l'exprime pas. Vous ajoutez une ligne `dynamic` et
  vous écrivez un handler dans `ui/menu/*` sur Windows et macOS, et dans
  `modules/menu/menu_builder.lua` sur Linux — trois fois, en trois langues, avec les
  libellés en dur sur Linux.
- **Sur Windows uniquement** : tout item actionnable doit passer par `RegisterMenuItem` /
  `RegisterMenuItemInsert`, jamais par `Menu.Add` brut. AHK 2.0 perd silencieusement 30 à
  50 % des clics de menu tray sans ce contournement. **Non négociable.**

**Cible (plan, lot 5)** : une ligne dans `_shared/modules/menu/menu.toml`, avec au besoin un
`action` / `state` / `provider` déclaré dans `registry.json` et implémenté une fois par
driver. Le manifeste devient **tout** le menu ; le renderer par driver fait moins de 300
lignes ; macOS et Linux partagent le même.

### 10.4 Ajouter ou modifier un toggle de fonctionnalité

1. Éditer `_shared/modules/features/manifest.toml` : une entrée `[[features.<chemin>]]`
   avec `id`, `default`, `description_key`, et `platforms` si la fonctionnalité n'est pas
   universelle.
2. `npm run build:domain` — régénère les manifestes des drivers, le gabarit de config, et
   valide.
3. Lire la valeur : `Features["section"]["id"]` (AHK) ou
   `Manifest.feat_enabled("section.id")` (macOS). **Jamais** lire `_generated/`
   directement.
4. Toute chaîne visible passe par une clé i18n (§10.7).

⚠ Ne créez **pas** de nouvelle section nommée d'après un driver (`[sections.ahk.*]`,
`[sections.hs.*]`). Elles existent, elles sont la cause racine n°1 de la divergence
(61,5 % des fonctionnalités y sont), et le lot 4 du plan les supprime. Utilisez
`platforms = [...]` et `default_per_platform = { ... }`.

⚠ La chaîne `linux` n'apparaît nulle part dans ce manifeste aujourd'hui, bien que le schéma
l'autorise. Si votre fonctionnalité existe sur Linux, ajoutez-la — c'est le début du lot 4.

### 10.5 Modifier le moteur de hotstrings

**D'abord, identifiez la couche que vous changez** — c'est 90 % du travail :

| Je veux changer… | J'édite | Puis |
|---|---|---|
Le texte ou les flags d'une hotstring | `_shared/modules/hotstrings/<catégorie>.toml` | rien d'autre. Les trois drivers lisent ce fichier. Supprimer le cache `.tsv` si le côté Windows semble périmé (il s'auto-répare par mtime) |
Le délai / la couleur / l'infobulle par défaut d'une catégorie | le bloc `[_meta]` / `[_meta.sections]` de ce TOML | `npm run test:js` |
Le repli global de délai / couleur | `_shared/modules/hotstrings/defaults.toml` | les deux drivers échouent bruyamment sur une clé manquante — lancer les deux suites |
Un rang de priorité de collision | `priority.json` **et** les constantes `HSE_PRIORITY_*` (AHK) **et** `PRIORITY_*` (macOS) | `npm run test:priority-parity` (scan de texte sur les trois) |
Quels caractères terminent un mot | `_shared/core/domain/Terminators.spec.js` | `npm run codegen:terminators`, puis les trois suites. **Ne jamais** éditer les deux fichiers générés |
Le plafond de tampon | 4 sites : le moteur partagé, deux fichiers AHK, et `macos/modules/keymap/init.lua` | ⚠ la barrière de parité de plafond **ne vérifie pas le site macOS** (d'où la valeur 500 contre 256 ailleurs) |
**La logique de correspondance / frontière de mot / départage** | trois endroits non symétriques, voir ci-dessous | corpus obligatoire |

**Changer la logique de correspondance** — les trois sites, avec ce qu'il faut savoir de
chacun :

1. **Windows** — `windows/lib/hotstrings/hotstring_match.ahk` : `_HSE_Beats` (départage),
   `_HSE_EndCharBeats` (étoile vs end-char), `HSE_FindMatchAtEnd` (les deux chemins de
   balayage), `_HSE_WordBoundaryAllows` et `_HSE_WordBoundarySet`. L'état du tampon est dans
   le fichier voisin `hotstring_engine_main.ahk`.
   ⚠ `_HSE_WordBoundarySet()` est **dérivé à chaque lecture, jamais mis en cache** : une
   copie cachée est précisément ce qui a laissé le matcher et l'aperçu dériver.
   ⚠ `HSE_RebuildInProgress` fait répondre `""` au matcher **pour tout** — cela signifie
   « je ne peux pas répondre », pas « pas de correspondance ».
2. **macOS** — `macos/modules/keymap/expander.lua` : `would_fire()` est **la** source de
   vérité de « est-ce que ça va se déclencher ? », et **l'aperçu infobulle l'appelle
   aussi**. Sa docstring documente que deux implémentations indépendantes avaient auparavant
   divergé sur quatre points. **N'ajoutez jamais un second prédicat.** L'ordre de tri est
   dans `registry.lua`.
3. **Linux** — `_shared/lua/hotstring_engine/init.lua` : `is_word_char`, `engine:on_char`,
   le tri du bucket. ⚠ Ce fichier est `require`é **par Linux uniquement** : une modification
   ici n'atteint pas macOS, malgré ce que dit sa propre docstring.

**Étendre le corpus est obligatoire** (règle du projet : tout bug corrigé part avec son test
de régression). Ajoutez le vecteur dans `_shared/tests/corpus/hotstrings/vectors.json`
(`vectors` pour un comportement simple, `collision_vectors` pour un départage) et **fixez
`is_word` explicitement** : les consommateurs ne s'accordent pas sur le défaut (le
consommateur AHK suppose `true`, le Linux et le moteur partagé supposent `false`).

⚠ **N'utilisez pas `backspace_count` comme assertion cross-driver** tant que le contrat du
corpus n'est pas corrigé (§5, et lot 8.1 du plan) : il n'est significatif que pour Windows
et Linux.

**Trois pièges d'émission à ne jamais casser** : l'expansion AHK est **une** rafale
`SendInput` atomique (la découper est documenté comme la source d'une classe de corruption
du texte tapé) ; sur macOS, tout injecteur doit passer par le point d'étranglement
`perform_text_replacement`, sinon les **deux** compteurs de synthétique indépendants se
désynchronisent et le texte tapé peut être corrompu ; sur Linux, le mode observe implique
que le terminateur n'est jamais consommé.

### 10.6 Ajouter ou modifier une hotstring livrée

Un seul fichier : `_shared/modules/hotstrings/<catégorie>.toml`. Les champs réels sont
`output`, `is_word`, `is_case_sensitive`, `is_case_sensitive_strict`, `auto_expand`,
`final_result`. Les trois drivers lisent le TOML directement.

⚠ Si vous mettez `auto_expand = false`, sachez que la hotstring **ne se déclenchera jamais
sur Linux** (pas de chemin terminateur, et le chargeur ne lit pas le champ).
⚠ Si vous comptez sur la propagation de casse (`BTW` → `By The Way`), elle n'existe **pas
sur Linux**.

### 10.7 Ajouter une chaîne visible par l'utilisateur

**Règle absolue du projet : aucune chaîne visible n'est écrite en dur, nulle part, webviews
incluses.** 21 langues.

1. Ajouter la clé dans `_shared/data/locales/en.json` — c'est le jeu de clés canonique.
2. `python tools/locale/check_locales.py --fix` — remplit la clé dans les 20 autres locales
   avec le texte anglais comme placeholder. Les traductions viennent après.
3. Lire : `t("ma.cle")` (AHK), `i18n.get("ma.cle")` (macOS/Linux), `data-i18n` (webviews
   partagées).
4. La parité est imposée en CI par un méta-test AHK qui construit l'union des clés de toutes
   les locales et vérifie que chaque fichier la contient intégralement.

⚠ Les libellés de profil LLM utilisent des placeholders **en accolades** (`{n}`, `{s}`), pas
`printf` : un `%d` fuirait verbatim dans l'UI.
⚠ Seul l'AHK **avertit** quand une clé ne résout pas ; macOS et Linux retournent la clé en
silence. Une clé périmée est donc invisible sur deux drivers sur trois.
⚠ `_shared/ui/i18n.js` n'a **aucune chaîne de repli** : une locale partiellement traduite
affiche des libellés **vides** dans toutes les webviews partagées.

### 10.8 Ajouter une fenêtre de configuration (webview)

1. Créer `_shared/ui/<nom>/{index.html,script.js,style.css}`. Le JS poste vers l'hôte via
   `makeHostBridge('<nom>_bridge')` et attend un `init(data)`.
2. Ajouter l'entrée dans `_shared/ui/apps.manifest.json` (largeur, hauteur, minimums, nom de
   vhost) — c'est la source unique de la géométrie.
3. Écrire l'hôte par driver. ⚠ Aujourd'hui : `windows/ui/<nom>/init.ahk` +
   `<nom>_webview.ahk` (12 hôtes écrits à la main ; la factory `WebViewHost` construite
   pour les unifier a **zéro appelant**), `macos/ui/<nom>/init.lua` (utilise
   `ui_builder.get_app_geometry`, échec bruyant si l'entrée manque), et sur Linux un handler
   dans `modules/ui/bridge_handlers/<nom>_bridge.lua` **plus** un appel à
   `webview_manager.show("<nom>")` — sans quoi la fenêtre est inatteignable (c'est le cas de
   12 des 14).
4. ⚠ **Le nom du handler doit être exactement `<app_id>_bridge`** sur Linux : trois ids ne
   résolvent pas aujourd'hui à cause de cet écart (`dl_bridge`,
   `hotstrings_config_bridge`, `token_bridge`).
5. Sur Windows, respecter l'ordre de démontage : libérer l'abonnement aux messages **avant**
   `Controller.Close()`, sinon la libération tardive tape dans des interfaces déjà relâchées
   (crash SEH non capturable). Une barrière le vérifie — pour 7 hôtes sur 12.
6. Utiliser un seul échappeur JS. ⚠ Il en existe 12 copies, dont **3 suppriment les `\r` au
   lieu de les échapper**.

**Cible (plan, lots 3c et 5)** : `modules/<feature>/window.<ext>`, même chemin sur les trois
drivers, un seul hôte lisant la géométrie du manifeste, un seul protocole de retour.

### 10.9 Ajouter une valeur de configuration ou un délai

- **Un délai** : `_shared/modules/timings/constants.toml`, section existante. Lire par
  `Timings.ms(...)` / `Timings.sec(...)`. Ne jamais retaper le nombre.
- **Un scalaire partagé** (port, température, plafond…) : le mettre dans le JSON/TOML
  partagé du domaine concerné **et** ajouter son test single-source dans le même commit —
  copiez le plus proche existant dans `tools/test/`, ils sont volontairement quasi
  identiques.
- **Un défaut de fonctionnalité** : `manifest.toml`, jamais une deuxième déclaration
  ailleurs. Les défauts vivent à **exactement un** endroit ; les autres modules les lisent
  depuis là.

⚠ Il n'y a **pas** de section `[logger]` dans le registre de timings : la rétention,
la taille d'anneau, la fenêtre de déduplication et l'intervalle de flush sont des littéraux
recopiés dans 2 à 4 fichiers, sans barrière (lot 7.5 du plan).

### 10.10 Ajouter un adaptateur ou un port

1. Écrire le contrat : `_shared/core/ports/<Port>.spec.js` — `portContract` (méthodes +
   arités), `contractTestVectors()`, `validateAdapter()`.
2. `npm run codegen:contracts` régénère `contracts.json`.
3. Implémenter `adapters/<snake_case>.{ahk,lua}` dans les trois drivers.
4. Sur Windows, déclarer la map `global ADAPTER_<Nom> := Map(...)` — la barrière de
   conformité la parse (⚠ ces maps n'ont **aucun** consommateur de production ; elles
   existent pour la barrière).
5. Ajouter les vecteurs à la suite de conformité de chaque driver. ⚠ Aujourd'hui ils sont
   **transcrits à la main** : 1 050 lignes AHK couvrant 19 ports sur 20, 951 lignes macOS
   couvrant 10 sur 20, 0 sur Linux. Rien ne détecte les manques.

⚠ Avant d'investir : lisez §7. Sur Windows et Linux, la moitié des adaptateurs n'a aucun
appelant. Si votre besoin est une primitive OS ponctuelle, vérifiez d'abord qu'un port
existant a du trafic réel.

### 10.11 Ajouter un quatrième driver

`npm run new:driver <nom>` est censé produire le squelette depuis les specs de ports.
⚠ **Il est cassé** : `REPO_ROOT` résout vers `tools/`, les trois chemins de specs sont
périmés, et le générateur produit **zéro adaptateur** avec un README annonçant « Ports to
implement (0) ». Le réparer et le rendre piloté par la donnée est la dernière étape du lot 3
du plan — après quoi il devient la **définition exécutable** de l'arbre canonique.

### 10.12 Corriger un bug

La procédure du projet, condensée :

1. Consulter `docs/PROJECT_MEMORY.md` — il y a de bonnes chances que le piège soit déjà
   documenté, ou que votre idée ait déjà été tentée et revertée.
2. Corriger la **cause racine**, pas le symptôme. Et auditer **toute la classe** : le bug
   récurrent de ce dépôt est le site frère oublié, ou une garantie défaite un niveau
   d'indirection plus bas.
3. **Écrire le test de régression** qui échoue avant et passe après, en encodant la cause
   racine et non le symptôme. Écrivez-le comme une **boucle sur un ensemble énuméré depuis
   la source**, pas comme une assertion sur le site unique où le bug est apparu.
4. Lancer les barrières qui couvrent ce que vous avez touché (`npm run verify` les
   sélectionne), plus la suite de chaque driver modifié.
5. Un commit par correction, en Conventional Commits, sans trailer de co-auteur.
6. **Ne jamais `git push` sur `dev` ou `main`** sans autorisation explicite dans la
   conversation en cours : un push déclenche la CI et coupe une release.

---

## 11. Les asymétries irréductibles

Ce sont les seules différences qu'il est légitime de conserver. Toute autre différence est
un bug ou une dette. **Cette liste doit vivre à un seul endroit** ; en attendant que le plan
crée `_shared/remap/SPEC.md`, elle est ici et dans `docs/PROJECT_MEMORY.md`.

| # | Asymétrie | Niveau | Pourquoi |
|---|---|---|---|
| I1 | Reconnaissance des gestes : frames brutes (macOS) / pré-classification par le pilote (Windows) / libinput (Linux) | pilote OS | Windows n'expose aucune API tactile par doigt en userland |
| I2 | Windows n'a que 10 slots de gestes | pilote OS | le registre n'en supporte pas plus |
| I3 | macOS n'a qu'un seuil tap-hold global | extension noyau | le modèle Karabiner utilisé n'expose qu'une valeur ; du par-touche exigerait une variante de manipulateur par touche |
| I4 | `cmd` ↔ `ctrl`, `option` ↔ `alt`, `fn` seulement sur claviers Apple | OS | résolu par les jetons logiques, pas supprimé |
| I5 | macOS ne voit jamais les keycodes pré-Karabiner ; Windows/Linux jamais les post-remap | noyau vs userland | ordre des couches |
| I6 | La disposition de base macOS est une ressource OS installée | OS | pas d'équivalent Windows sans outil tiers |
| I7 | Linux en mode observe ne consomme jamais le terminateur | noyau | exigerait `EVIOCGRAB` + ré-émission sans perte, validée sur matériel |
| I8 | La matrice N×N de combos de modificateurs macOS n'a pas d'analogue | extension noyau | ni AHK ni kanata ne l'expriment |
| I9 | Le pipeline métriques AHK ne persiste pas les agrégats | conception | anti-gonflement (~140 Mo/jour) |
| I10 | Les prédicats de frontière de mot divergent sur des caractères précédents exotiques | conception | ils s'accordent sur toute entrée française normale |
| I11 | Le gating par catégorie est AHK-only | conception | macOS n'a pas cette couche |
| I12 | `adapters/` est la couche d'isolation OS, pas « exactement les 20 ports » | convention | déplacer les helpers ferait exploser les cliquets de pureté |
| I13 | Le `.tsv` de locale Windows est un cache gitignoré auto-réparateur | perf | règle dure : aucune duplication versionnée |
| I14 | Pas d'emoji drapeau dans les menus Windows | OS | d'où `[DE] Deutsch` |
| I15 | Alphas de bordure de tooltip différents | conception | arbitré |

---

## 12. Pièges par langage

Ce sont ceux qui ont réellement mordu, avec leur symptôme. Liste complète dans les skills
`.claude/skills/{ahk,hammerspoon,linux}-driver/`.

### AutoHotkey v2 (`windows/`)

| Piège | Symptôme |
|---|---|
Encodage : **UTF-8 avec BOM + LF** obligatoire | sans BOM, le parseur abandonne **au milieu du fichier**, en silence — des tests « disparaissent ». ⚠ `windows/README.md` dit CRLF : il a tort, la barrière impose LF |
Escape de guillemet dans une chaîne : `` `" `` | `""` est de la syntaxe v1 |
` ;` (espace + point-virgule) démarre un commentaire **même dans une chaîne** | erreur de parsing « Missing `"` » sur un `;` littéral |
`Map[clé_absente]` **lève** | utiliser `.Has()` / `.Get(clé, défaut)` |
`IsSet(obj.prop)` est un **crash au chargement** | les tests d'introspection de source ne peuvent pas l'attraper |
`static _prop := unset` laisse la propriété **illisible** | toute lecture lève ; utiliser `false` comme sentinelle |
`"0" = false` est **vrai** | comparer une valeur `String|false` à `false` avale tout succès numérique |
Nommer une locale `Catch` (ou tout mot-clé) | AHK **se bloque avec zéro sortie** : ni erreur, ni dialogue, ni log |
Les hotkeys `::` s'enregistrent au **chargement** | un `if` runtime autour d'un hotkey est décoratif ; utiliser `Hotkey()` + `HotIf()` |
`SC138` comme préfixe au parse-time | casse AltGr natif **pour tout le processus** |
`AltGr == Ctrl+Alt` sur Windows | `^!x` et un vrai AltGr sont indiscernables par préfixe ; d'où les gardes `IsRealAltGrPress()` |
`Suspend()` ne désarme **que** les hotkeys | InputHooks, timers et `OnMessage` continuent : gardes `A_IsSuspended` explicites |
`#Include` exécute les statements top-level **à la position de l'include** | l'ordre de la liste est sémantique |
`Critical("On")` est de portée thread et **fuit** dans le thread principal quand un test appelle la fonction directement | gèle tous les timers de fond pour le reste de la suite |
Le menu tray perd 30–50 % des clics | tout item actionnable doit passer par `RegisterMenuItem` |
`Map.Delete(k)` lève si la clé est absente | — |
`/validate` d'Ahk2Exe **ne valide pas** | le drapeau est ignoré et le script **s'exécute**. Utiliser une compilation (`exit 17` sur erreur de syntaxe) |

### Lua / Hammerspoon (`macos/`)

| Piège | Symptôme |
|---|---|
Un `local` déclaré **après** une closure qui l'utilise n'est pas capturé | la closure lie la globale `nil` ; le `pcall` du runner avale l'erreur en silence |
`local x = cond and expr` vaut **nil**, pas `false`, quand `cond` est nil | et `not nil` est `true` : une garde « négative » s'inverse silencieusement |
Hammerspoon **avale** un throw dans un callback `hs.timer` | classe de mort silencieuse ; capturée aujourd'hui par un hook de logger qui doit rester installé |
`hs.fs.dir` renvoie **(iterator, state)** | un stub laxiste a masqué l'état perdu |
`os.exit()` **contourne** le shutdown callback | le raccourci « quitter » doit tuer Karabiner lui-même |
Ne jamais faire de travail bloquant dans un callback `hs.eventtap` | macOS désactive le tap (`kCGEventTapDisabledByTimeout`) et le raccourci meurt ; différer avec `doAfter(0, …)` |
Le cliquet de pureté `hs.*` compte la sous-chaîne `hs.` **dans les commentaires** | un commentaire mentionnant `hs.timer.new` incrémente le compteur |
Ne jamais créer un `hs.window.filter` sur un chemin de boot ou de première frappe | coût mesuré prohibitif |
`pcall(hs.json.decode, …)` **imprime quand même** l'erreur native | — |
Séparer un module stateful de son appelant exige de l'ajouter à la liste de rechargement des stubs | sinon les stubs cessent d'intercepter |
`utf8.offset` / `utf8.len` peuvent renvoyer `nil` sur séquence malformée | envelopper dans `pcall` ou tester le résultat |

### LuaJIT (`linux/`)

| Piège | Symptôme |
|---|---|
Pas de bibliothèque `utf8` de Lua 5.3 | le polyfill `_shared/lua/compat/utf8.lua` doit être installé au boot |
Le hook tourne en **mode observe** | tout ce qui est tapé pendant la fenêtre de boot est tamponné puis rejoué avec un horodatage lu **au rejeu**, ce qui biaise les délais inter-frappes du premier burst |
`string.format("%q")` est un quoteur de **littéral Lua**, pas de shell | il laisse `$`, `` ` `` et `$( )` vivants ; utiliser `shell_runner.quote()` |
Le décodeur evdev n'est ni exécuté ni testé | — |
Aucune isolation inter-fichiers dans le runner de tests | un `package.loaded[…] = stub` au niveau module suffit à créer un flake dépendant de l'ordre |
kanata choisit son périphérique sans coordination avec le hook | — |

---

## 13. Les pièges transverses à connaître avant de toucher au code

Douze défauts vivants, mesurés. Ils sont détaillés avec preuves dans le
[registre des blocages](../TODO.md#04-the-remaining-blockers) ; ils sont
répétés ici parce qu'ils changent la façon de lire le code.

**Linux, quatre blocages :**

1. **Le daemon n'écrit aucun log, nulle part.** Le shim résout vers le cœur partagé, qui
   n'écrit que dans un sink injecté, et aucun `set_sink` n'est appelé. Y compris les erreurs
   fatales. Si vous déboguez Linux, ne cherchez pas de log : il n'y en a pas.
2. **Le menu n'existe dans aucune installation packagée** : le tray est conditionné par
   `--tray`, et aucune des 5 unités systemd ne le passe.
3. **La config kanata générée est inchargeable** (quatre alias pendants).
4. **Le keylogger tourne toujours, en clair, sans détection de champ sécurisé et sans
   possibilité de désactivation**, et le texte tapé transite par un fichier `/tmp` lisible
   par tous à chaque flush.

**macOS :** l'option « Chiffrement » du menu est un **no-op complet** dont le backend est
dix stubs vides, et la documentation de sécurité dit à l'utilisateur de l'activer.

**Windows :** `resolve_disabled_when` échoue **ouvert** (macOS échoue fermé, avec test) ;
le LLM **journalise le texte tapé de l'utilisateur en INFO à chaque prédiction** ;
`llm_context_length` n'a aucun effet sur le chemin automatique.

**Les trois :** le chemin des packs d'extensions est faux depuis un reorg, avec échec
silencieux partout — le sous-menu extensions ne s'affiche jamais et l'arbre est absent des
bundles livrés.

**Et pour les tests :** `_DriverDirConcat` retourne `""` sur répertoire absent, ce qui rend
vides 220 assertions dès qu'un dossier est renommé, tandis que le cliquet certifie ces
fichiers comme résistants aux déplacements. **C'est le premier chose à corriger avant tout
renommage.**

---

## Où aller ensuite

| Question | Document |
|---|---|
« Que faut-il changer, dans quel ordre, et pour quel gain ? » | [TODO.md](../TODO.md) — §0 porte le programme de simplification complet |
« Quelles sont les règles de style, de log, de nommage ? » | [.github/copilot-instructions.md](../.github/copilot-instructions.md) |
« Ce piège a-t-il déjà mordu quelqu'un ? » | [PROJECT_MEMORY.md](PROJECT_MEMORY.md) |
« Comment lancer quoi ? » | [TESTING.md](TESTING.md) |
« Que veut dire ce terme ? » | [glossary.md](glossary.md) (français) et [../static/ergopti_plus/docs/glossary.md](../static/ergopti_plus/docs/glossary.md) (anglais) — ⚠ **ce ne sont pas deux versions du même document** ; l'anglais annonce « neuf ports » puis en liste treize alors qu'il y en a 20, et nomme des répertoires `hammerspoon/` / `autohotkey/` qui n'existent pas |
« Pourquoi cette décision d'architecture ? » | [../static/ergopti_plus/docs/adr/](../static/ergopti_plus/docs/adr/) — ⚠ plusieurs ADR contiennent des chemins périmés, voir §14 du plan |
« Comment faire une tâche récurrente (fix, commit, audit) ? » | `.claude/skills/` — index dans [../AGENTS.md](../AGENTS.md) |
