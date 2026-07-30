<!-- docs/PLAN_SIMPLIFICATION.md -->

# Ergopti+ — Audit de mise en commun et plan de simplification

> **Objet.** Réduire à une seule implémentation, un seul arbre et un seul comportement tout
> ce qui n'a pas de raison OS d'être triple. Rendre le code lisible par un développeur
> junior sans documentation préalable.
>
> **Base de mesure.** Passe d'audit du 2026-07-30 sur `static/ergopti_plus/`. 14 axes,
> chaque affirmation vérifiée à la ligne citée. Les nombres sont étiquetés **mesuré** ou
> **estimé**. Les rapports détaillés par axe ont servi de source ; ce document est la
> synthèse décisionnelle.
>
> **Document jumeau.** [ERGOPTI_PLUS.md](ERGOPTI_PLUS.md) décrit comment le système
> fonctionne aujourd'hui et contient les runbooks « comment faire X ». Ce document-ci dit
> quoi changer et dans quel ordre.

---

## État de livraison — branche `simplification`

> Dérivée de `dev`, worktree `.claude/worktrees/simplification`. **Non fusionnée.**
> Les quatre suites sont vertes à chaque commit : JS 80 · macOS 3 701 · Linux 1 241 ·
> AHK 3 764 (baseline avant travaux : 78 · 3 701 · 1 217 · 3 761).

| Lot / blocage | État | Commit |
|---|---|---|
| **Lot 0** — la vérité (README menteurs, specs partagées, angles morts de lint, `.gitattributes`) | ✅ livré, sauf la suppression du codegen no-op et la purge des refs de phase | 6 commits |
| **B1** — le daemon Linux n'écrivait aucun log, nulle part | ✅ livré, 10 cas de test | `fix(linux): install a log sink…` |
| **B2** — le tray Linux absent de toute unité packagée | ✅ livré, barrière étendue | `fix(linux): pass --tray…` |
| **B7** — `resolve_disabled_when` AHK échouait *ouvert* | ✅ livré, jumeau AHK du test macOS | `fix(menu): …fail closed…` |
| **B8** — chemins des packs d'extensions (7 sites) | ✅ livré, nouvelle barrière + bundler fail-fast | `fix(extensions): …resolve again` |
| **B11** — le LLM Windows journalisait le texte tapé | ✅ livré, nouvelle barrière de classe | `fix(llm): stop logging…` |
| **B12** — le bloc `<think>` était tapé dans le document (Linux) | ✅ livré, filtre streaming partagé + 14 cas | `fix(linux): stop typing…` |
| **B3, B4, B5, B6, B9, B10** | ⏳ restants — listés avec leurs pièges dans [`TODO.md`](../TODO.md) | — |
| **Lots 2 à 10** | ⏳ non commencés. Le lot 2.1 (`_DriverDirConcat` doit lever sur vide) reste le prérequis absolu de tout renommage | — |

Trois affirmations de cet audit se sont révélées **fausses** à la vérification et sont
corrigées dans le texte ci-dessous : l'absence de `.husky/`, la suppression de
`PKGBUILD`, et le branchement de `secure_field_detector` sur Linux. Voir §14 et
l'entrée `project-simplification-branch-2026-07-30` de la mémoire projet.

---

## Table des matières

1. [Le diagnostic en une page](#1-le-diagnostic-en-une-page)
2. [Les chiffres](#2-les-chiffres)
3. [Les huit constats structurels](#3-les-sept-constats-structurels)
4. [Les cinq invariants cibles](#4-les-cinq-invariants-cibles)
5. [L'arborescence canonique](#5-larborescence-canonique)
6. [Le plan par lots](#6-le-plan-par-lots)
7. [Registre des blocages](#7-registre-des-blocages)
8. [Ledger de duplication mesuré](#8-ledger-de-duplication-mesuré)
9. [Asymétries légitimes — ne pas « corriger »](#9-asymétries-légitimes--ne-pas-corriger)
10. [Déjà rejeté — ne pas re-proposer](#10-déjà-rejeté--ne-pas-re-proposer)
11. [Barrières CI : à créer, étendre, retirer](#11-barrières-ci--à-créer-étendre-retirer)
12. [Risques du refactor](#12-risques-du-refactor)
13. [Décisions attendues du mainteneur](#13-décisions-attendues-du-mainteneur)
14. [Annexe — corrections apportées à des artefacts existants](#14-annexe--corrections-apportées-à-des-artefacts-existants)

---

## 1. Le diagnostic en une page

**Le projet n'est pas mal conçu. Il est à moitié migré, trois fois de suite.**

Tous les bons mécanismes existent déjà et sont opérationnels :

| Mécanisme existant | État |
|---|---|
| Architecture hexagonale : 20 contrats de ports, 67 fichiers d'adaptateurs | présent, **contourné** |
| Manifeste de fonctionnalités partagé (3 313 lignes, une entrée par toggle) | présent, **découpé par driver** |
| Manifeste de menu déclaratif généré (862 lignes) | présent, **rendu à 31–45 %**, ignoré par Linux |
| Cœur logger neutre partagé, conçu avec injection de sink (281 lignes) | présent, **utilisé par 1 driver sur 3** |
| Corpus de vecteurs cross-driver (16 fichiers, 258 vecteurs) | présent, **2 corpus sur 16 rejoués par les 3 drivers** |
| Codec TOML partagé, avec barrière de pureté et deux corpus rejoués partout | présent et **exemplaire — c'est le modèle à copier** |
| ~100 barrières CI, dont une famille `*-single-source` | présent, **portée partielle : la plupart ignorent Linux et `ui/`** |
| Générateur de squelette de nouveau driver (`new:driver`) | présent, **cassé : 3 chemins périmés, produit 0 adaptateur** |

Le travail n'est donc pas « ajouter une couche d'abstraction ». C'est **terminer les
abstractions déjà écrites et supprimer ce qui les court-circuite**. C'est une bonne
nouvelle : le risque est bien plus faible qu'un refactor architectural, et chaque lot est
livrable indépendamment.

**La cause racine unique.** Trois artefacts partagés encodent la divergence au lieu de
l'éliminer :

1. `_shared/modules/features/manifest.toml` possède des sections **nommées d'après les
   drivers** (`[sections.ahk]`, `[sections.hs]`). 206 des 335 fonctionnalités (61,5 %,
   mesuré) vivent dans ces silos. Les gestes existent en **deux arbres indépendants** :
   `features.ahk.gestures` = 11 entrées, `features.hs.gestures` + `.modes` +
   `.sensitivities` = 109 entrées — pour la même fonctionnalité, avec la **même clé i18n**
   `menu.gestures` de part et d'autre (`manifest.toml:239` et `:258`).
2. La chaîne `linux` apparaît **0 fois** dans ce manifeste de 3 313 lignes et **0 fois**
   dans `menu_manifest.json` (mesuré) — alors que le schéma autorise déjà la valeur
   (`manifest.schema.json:47`). Linux est structurellement invisible aux données
   partagées ; c'est pourquoi son menu est un fichier écrit à la main de 833 lignes avec
   101 libellés français en dur.
3. Le mécanisme qui aurait dû l'empêcher — le champ `platforms` par entrée — existe et
   fonctionne (le sous-menu Debug le prouve sur les deux drivers). Il est simplement
   sous-utilisé : sur 116 déclarations `platforms`, **65 sont AHK-only, 30 macOS-only, 20
   communes** (mesuré).

**Conséquence produite.** Aucune des 14 fenêtres UI partagées ne vit au même chemin sur
les trois drivers. `modules/keymap/` désigne le remappage clavier sur Windows et le moteur
d'expansion sur macOS. Le même geste à trois doigts vers la gauche fait trois choses
différentes selon l'OS, sans qu'aucune ligne de code n'en donne la raison.

---

## 2. Les chiffres

Tous **mesurés** le 2026-07-30 (`find … | xargs cat | wc -l`, `wc -l`, scripts de
comptage). Les totaux précédemment cités dans les README du projet sont faux d'un
facteur ~2,5 — voir §14.

### 2.1 Masse

| | Fichiers prod | Lignes prod | Fichiers tests | Lignes tests |
|---|---:|---:|---:|---:|
| `windows/` (AHK v2) | 234 | **82 867** | 842 | **91 900** |
| `macos/` (Lua/Hammerspoon) | 193 | **78 622** | 605 | **86 485** |
| `linux/` (LuaJIT) | 66 | **16 733** | 76 | **15 934** |
| `_shared/` | — | **37 489** | — | 258 vecteurs / 17 fichiers |
| `tools/test/` (barrières JS) | 75 | **12 967** | — | — |
| **Total** | | **≈ 215 700** | **1 523** | **≈ 207 000** |

**Les tests pèsent 96 % de la production.** C'est le fait qui borne tout le refactor :
aucun déplacement d'arbre n'est faisable sans traiter d'abord la façon dont les tests
épinglent les chemins (§12).

### 2.2 Concentration et couplage

| Métrique | Windows | macOS | Linux |
|---|---:|---:|---:|
| `#Include` dans le point d'entrée / `require` distincts | **149** | 37 | 27 (**13 en `pcall`**) |
| Nœuds du graphe transitif / profondeur max | 239 / **3** | 218 / **15** | 62 / **4** |
| Fichiers atteignables depuis le point d'entrée | 239 / 239 (100 %) | 218 / 226 (96,5 %) | **62 / 98 (63,3 %)** |
| Cycles de `require` | n/a | **2** (tous deux dans `modules/llm/`) | 0 |
| Globales de portée fichier | **911** (515 constantes, **396 mutables**) | 0 vraie globale ; **689 locales mutables de module** | 0 ; **241 locales mutables** |
| Symboles dans un **unique** espace de noms plat | **3 198** | n/a (vrais modules) | n/a |
| Arêtes de couplage fichier→fichier | **1 760** sur 239 fichiers (fan-out moyen 7,4) | 771 | — |
| Wrappers pass-through (corps = 1 appel transféré) | 25 | **65** | 4 |
| Fonctions exportées sans aucune référence de production | 51 | 44 | 12 (+ 14 dans `_shared`) |
| Sites de primitives OS **hors** `adapters/` | **1 854** | **1 622** lignes `hs.*` | 61 shell-outs + 54 quotings manuels |
| Adaptateurs sans aucun appelant en production | **12 / 21** | 2 / 24 (composition légitime) | **11 / 21** (≈ 1 750 lignes) |

Autres mesures transverses :

| Métrique | Valeur |
|---|---:|
| Fichiers de production > 600 lignes | **110**, contenant **45,0 %** de tout le code de production |
| **Ratio d'identité d'arborescence** : sous-répertoires (profondeur ≤ 2) présents dans les **trois** drivers | **10 sur 53 → 18,9 %** |
| `_shared/lua/` réellement partagé (requis en production par **les deux** drivers Lua) | **3 195 / 8 473 lignes → 37,7 %** (36,9 % macOS-only, 22,7 % Linux-only, 2,7 % tests) |
| `pcall(require, …)` en production (macOS + Linux) | **172** |
| `require` émis **dans un corps de fonction** (invisible à toute lecture statique) | macOS 151, Linux 58 |
| Contraintes d'ordre exprimées **en prose** dans `ErgoptiPlus.ahk` | **64** occurrences de `before`/`after`/`order` |
| Formes de paramètres distinctes pour `M.init/setup/start` (Lua) | **26** |
| Préfixes de noms de fonction AHK distincts | **101**, plus **768 fonctions sans aucun préfixe** |
| Fichiers indentés majoritairement à l'**espace** (convention : tabulation) | **78**, dont **30 mixtes** |

Le fan-in le plus élevé du dépôt : `macos/lib/logger.lua`, **165 modules entrants** ;
`windows/lib/logger.ahk`, **154 fichiers** ; `windows/lib/locale.ahk`, **132**.

Sur Windows, la liste d'`#Include` du point d'entrée **est** le graphe de dépendances (149
arêtes directes, profondeur 3) — et cette platitude n'est pas de la simplicité, c'est
l'absence de toute frontière de module : aucun fichier ne déclare ses dépendances, et ce qui
en tient lieu est **64 contraintes d'ordre écrites en prose** dans le fichier d'entrée.

Sur macOS, la chaîne de `require` la plus profonde (chaque saut re-vérifié) dit tout du
couplage : **ouvrir le menu Hotstrings charge transitivement le moteur keymap, le pont LLM,
le moteur de prédiction, le keylogger, son agrégateur SQLite, puis le lecteur TOML
partagé** — 15 sauts, `ui/menu` → `modules/keymap` → `modules/llm` → `modules/keylogger` →
`_shared/lua/toml_codec`.

### 2.3 Le taux de mutualisation, par sous-système

| Sous-système | Lignes par driver (total) | Lignes dans `_shared` | Taux |
|---|---:|---:|---:|
Moteur de hotstrings | 14 737 | 519 | **3,4 %** |
Keylogger / métriques | 21 750 | 551 | **2,5 %** |
LLM | 32 877 | 3 039 | 8,5 % |
Menu | 28 902 | 862 (données) | 2,9 % |
Tooltip | 6 148 | 1 843 (oracle non exécuté) | **0 % effectif** |
UI webview (frontends) | 0 | 31 684 | **100 %** |
Codec TOML | 51 (shims) + 1 837 (AHK) | 1 733 | exemplaire |

La ligne `UI webview` est la preuve que la mutualisation totale est atteignable dans ce
projet : 31 684 lignes de frontends sont partagées et consommées sans friction. La ligne
`Tooltip` est l'inverse : 1 843 lignes de « référence partagée » que **rien ne `require`**.

### 2.4 Le facteur de duplication, et l'ordre de priorité qu'il impose

Facteur = lignes totales implémentant le sous-système ÷ lignes de la plus grosse
implémentation d'un seul driver, c'est-à-dire « combien de fois payons-nous cette
fonctionnalité ». Mesuré par classification de chaque fichier de production.

| Sous-système | Lignes totales | Facteur | Lecture |
|---|---:|---:|---|
| `i18n / locale` | 1 762 | **2,57** | facteur le plus élevé **et** taille absolue la plus faible → **la mutualisation complète la moins chère du dépôt** |
| `adapters` | 11 093 | **2,72** | le plus élevé parmi les sous-systèmes à contrat partagé — mais les implémentations ne sont pas partageables par construction : l'action n'est pas « partager », c'est **« brancher ou retirer »** |
| `logger` | 3 583 | **2,25** | **meilleur coût par ligne** : fan-in le plus élevé sur les trois drivers, et l'implémentation partagée existe déjà et sert un driver |
| `ui / webview` | 14 349 | 2,49 | |
| `llm` | 24 415 | 2,36 | |
| `keylogger / metrics` | 48 005 (**21 % du code**) | 3,33 | facteur gonflé par 20 600 lignes de dashboard JS **déjà partagées et qui doivent être grosses** ; le vrai sujet est les 26 851 lignes côté driver, dont la divergence d'agrégation est sur la liste « ne pas toucher » |
| `hotstrings` | 24 542 | 2,14 | |
| `tooltip` | 5 068 | 2,00 | |
| `menu` | 24 230 | 1,64 | **facteur le plus bas des quatre gros, et pourtant le signal le plus fort** — le problème n'est pas la duplication, c'est l'**asymétrie** |

Le cas du menu mérite son détail, parce qu'il chiffre exactement le gain du lot 5 : macOS
dépense **14 818** lignes là où Windows en dépense **7 778** pour les mêmes menus.

| Sous-menu | macOS | Windows | Ratio |
|---|---:|---:|---:|
| **Disposition clavier** | **721** | **41** | **17,6×** |
| Hotstrings | 1 530 | 810 | 1,9× |
| Métriques | 674 | 338 | 2,0× |
| Raccourcis | 674 | 288 | 2,3× |
| Gestes | 374 | 177 | 2,1× |

Le 17,6× n'est pas un mystère : `windows/ui/menu/menu_layout.ahk` fait 41 lignes **parce que
c'est le manifeste qui travaille** — ses deux handlers ne font qu'itérer
`ManifestFeaturesForSection("ahk.layout")`. C'est la migration déjà planifiée et déjà
gardée par une barrière de dérive, et le delta de 680 lignes est son gain mesuré. Il n'y a
donc rien à inventer pour le lot 5 : il faut faire sur macOS ce que Windows fait déjà.

---

## 3. Les huit constats structurels

### C1 — Le manifeste partagé documente la divergence au lieu de l'interdire

Sections `[sections.ahk]` / `[sections.hs]`, 206/335 fonctionnalités en silo, `linux`
absent. Le champ `platforms` et `default_per_platform` existent et ne sont utilisés qu'à
la marge (3 usages réels de `default_per_platform`).

**Preuve la plus parlante** : `[sections.ahk.gestures].description_key = "menu.gestures"`
et `[sections.hs.gestures].description_key = "menu.gestures"` — le manifeste sait déjà
qu'il s'agit d'une seule fonctionnalité.

### C2 — Le port `TrayMenu` décrit exactement la solution, et n'est pas la couture

`_shared/core/ports/TrayMenu.spec.js:17-22` déclare un `setMenu(nodes)` déclaratif
(`id / label / enabled / checked / onClick / children / separator`) et écrit noir sur
blanc « *Callers do NOT call platform menu APIs directly* ».

La réalité : `macos/ui/menu/init.lua:31` importe l'adaptateur puis appelle
`hs.menubar.new` directement ligne 143, et 21 fichiers construisent des tables décrites
dans leurs propres docstrings comme « `hs.menubar`-compatible ». Sur Windows,
`TrayMenuSetMenu` n'a **aucun appelant de production** et son implémentation **ignore le
champ `children`** — elle est structurellement incapable de rendre l'arbre que le port
décrit. Le seul driver où le port est réellement la couture est Linux.

Masse concernée : **28 902 lignes** de code de menu (macOS 18 613, Windows 9 456, Linux
833) autour d'un manifeste de 862 lignes rendu à 31–45 %.

### C3 — Il n'existe pas de concept « action », mais cinq catalogues

`_shared/modules/gestures/actions.toml` (765 l, sain, lu par les trois),
`modifier_chords.json` (100 l, le seul fichier exprimant une équivalence de modificateur
par OS), `_shared/modules/features/shortcuts.toml` (420 l, **lu par personne** — son
générateur a été supprimé le 2026-06-13 comme code mort et le fichier de données est
resté), `macos/modules/karabiner/data/actions.json` (73 actions, libellés français en
dur, aucune clé i18n), et une table Lua de 42 entrées en dur sur Linux.

**Douze actions sont déclarées `platform = "ahk"` alors qu'elles sont pleinement
implémentées sur macOS** (`select_line`, `teleport_mouse`, `pick_color`, `paste_plain`,
`toggle_capslock`…) — simplement rangées dans `macos/modules/shortcuts/actions/*.lua` au
lieu du registre de gestes. Le catalogue partagé affirme donc que la fonctionnalité
n'existe pas sur macOS, et le sélecteur d'action macOS ne les propose pas.

**54 % du registre d'actions Windows est de la donnée déguisée en code** : 62 des 115
lambdas sont une pure émission de frappe (mesuré).

### C4 — La couche de ports est décorative sur deux drivers sur trois

12 des 21 adaptateurs Windows et 11 des 22 adaptateurs Linux n'ont **aucun appelant de
production** : **3 101 lignes mortes** (mesuré). Les 11 fichiers Linux morts proviennent
d'un unique commit, `f2776a0bd` « *feat(linux): implement all 11 missing port adapters* » —
écrits pour verdir une barrière de présence.

Pire qu'inutile : c'est une **fausse carte**. `_shared/core/ports/SPEC.md:126-131` dit au
lecteur que l'implémentation AHK de `KeyboardHook` est `KL_Hook_Start()` (dans
`modules/keylogger/`) ; `adapters/keyboard_hook.ahk` prétend le contraire ; la barrière de
conformité valide la seconde version ; le code qui tourne implémente la première. Et le
diagnostic santé Windows affiche « 100 % sain » pour les 12 adaptateurs morts — le bug
exact que macOS a corrigé et gardé par un test de reachability que les deux autres drivers
n'ont jamais reçu.

### C5 — Le socle transverse est triplé alors que le partagé existe

| Bibliothèque | État |
|---|---|
| **logger** | `_shared/lua/logger/init.lua` (281 l, cœur neutre avec injection de sink) **n'est utilisé que par Linux**. macOS a 1 145 lignes propres, Windows 1 077. Et **sur Linux aucun `set_sink` n'est appelé : le daemon n'écrit aucun log, nulle part** (vérifié par exécution). |
| **paths** | Windows et macOS résolvent `_shared` en un point ; **Linux n'a aucun résolveur** — 12 expressions indépendantes avec 4 profondeurs différentes et 14 fichiers dérivant `$HOME` séparément. Deux bugs vivants en découlent (§7). |
| **i18n** | 3 wrappers indépendants (307 / 325 / 259 l) avec 3 jeux de fonctionnalités différents ; la table des 21 locales est écrite en dur 3 fois (16 entrées seulement sur Linux) ; `_shared/ui/i18n.js` **n'a aucune chaîne de repli** là où les trois drivers natifs ont `active → en → fr`. |
| **TOML** | **exemplaire.** Un codec partagé, 3 shims d'une ligne sur macOS, une barrière de pureté, deux corpus rejoués par les trois suites. C'est le patron. |
| **updater** | Les algorithmes purs (`version`, `release_parser`) sont partagés et rejoués partout — bon. Le transport est triple, majoritairement à raison. |

### C6 — La séquence de boot n'est pas une donnée, donc elle est assertée par position d'octet

Trois mécanismes de câblage incompatibles (globales AHK / injection `M.init(state)` /
locales dans un `main()`), aucun objet d'état applicatif unique, et **23 tests dont le
sujet est la position d'un texte dans un fichier source** (11 méta-tests AHK comparant des
offsets `InStr`, 12 tests macOS lisant `init.lua` comme une chaîne). Ces tests cassent à
tout reformatage et passent à tout réordonnancement sémantiquement faux qui préserve
l'ordre du texte.

`windows/lib/app_state.ahk` est un fichier de **35 lignes entièrement en commentaire**,
zéro code exécutable, `#Include` dans le point d'entrée : il documente une consolidation
tentée puis abandonnée.

Le corollaire mesuré : une grande partie de l'organisation actuelle des fichiers Windows est
le **résidu de deux passes mécaniques de découpage**. En-têtes comptés :
« Split out of … » 23 fichiers, « hoisted » 40, « load order (is irrelevant) » 32,
« Extracted verbatim » 4. `windows/lib/config_io.ahk:8-10` le dit lui-même : *« Extracted
verbatim from ErgoptiPlus.ahk … functions are hoisted so their boot-time call sites are
unaffected. »* Le découpage a réduit la taille des fichiers **sans créer de modules**.

### C7 — Une part du couplage est structurellement invisible

Trois mécanismes rendent des dépendances réelles introuvables par lecture :

1. **L'espace de noms plat AHK** : **3 198 symboles** dans un seul espace global, **1 760
   arêtes** de couplage fichier→fichier que rien ne déclare, et **768 fonctions sans aucun
   préfixe** de module (contre 101 préfixes distincts par ailleurs).
2. **`package.loaded` utilisé comme bus de callbacks global** : 25 sites de production le
   touchent, et deux y **écrivent de faux modules** pour se parler —
   `macos/ui/menu/menu_llm/models_manager.lua:376-382` publie des hooks
   `download_abort_hook` / `download_retry_hook` que
   `macos/ui/download_window/init.lua:111-112` lit. **Aucun des deux fichiers ne `require`
   l'autre.** Il n'existe aucun moyen de trouver ce couplage sauf en grepant la chaîne
   littérale.
3. **La monoculture `pcall(require, …)`** : 172 sites. Sur Linux, **tous** les sous-systèmes
   majeurs sont chargés par l'idiome réservé aux dépendances réellement optionnelles (12
   blocs consécutifs dans le point d'entrée), et un module va jusqu'à re-`pcall(require)` à
   **chaque appel** derrière des accesseurs « imports paresseux ». Conséquence : sur Linux,
   **rien n'échoue jamais franchement** — une faute de frappe dans un chemin de module
   dégénère silencieusement en « fonctionnalité absente ». C'est l'exact opposé de la règle
   *fail fast* du projet.

### C8 — Les deux glossaires ne décrivent pas le code

Il existe **deux** glossaires qui ne sont pas des versions l'un de l'autre :
`docs/glossary.md` (189 l, français, alphabétique) et
`static/ergopti_plus/docs/glossary.md` (483 l, anglais, par sous-système). Le second annonce
« les **neuf** interfaces OS », « les **neuf** contrats de ports », puis en liste **treize** —
alors qu'il y en a **20**. Il nomme aussi les répertoires de drivers `hammerspoon/` et
`autohotkey/`, qui n'existent pas.

Donc « le code ne respecte pas le glossaire » est le mauvais cadrage : **le glossaire ne
décrit pas le code**. Toute proposition de vocabulaire canonique doit commencer par le
régénérer ou le réécrire.

### C7 — La documentation interne mentait sur presque tous les points vérifiés

Ce n'est pas un détail cosmétique : c'est la première chose qu'un développeur junior lit,
et elle l'envoie dans le mur. Liste vérifiée fichier par fichier en §14. Échantillon :

- `windows/README.md` prescrit **CRLF** pour les `.ahk` — la barrière `test:ahk-encoding`
  impose **LF** (un contributeur qui suit le README casse la CI).
- `windows/README.md` et `macos/README.md` affirment tous deux un miroir
  « répertoire-par-répertoire » : mesuré faux sur toute la ligne.
- `_shared/README.md:31-33` affirme que l'AHK consomme une « transpilation générée » du
  Lua partagé. **Rien n'est transpilé dans ce dépôt** ; tous les générateurs émettent de
  la donnée, et deux d'entre eux cachent de l'AHK écrit à la main dans un générateur JS.
- `_shared/modules/features/shortcuts.toml` (420 l) documente en tête un générateur
  supprimé il y a sept semaines.
- `_shared/modules/logger/README.md:5` nomme une suite de conformité qui n'existe pas ;
  `SPEC.md:279` affirme que l'AHK n'a pas de déduplication de lignes — il en a une, avec
  deux tests de régression.
- `linux/modules/README.md` se décrit comme « intentionnellement vide au stade de
  squelette » et contient 8 213 lignes.
- **`.husky/` n'existe pas** (rien n'y est suivi par git) alors que `package.json` déclare
  `"prepare": "husky install"` : il n'y a **aucun hook git** dans ce checkout, tandis que
  les conventions du projet parlent de comportements pre-commit.

---

## 4. Les cinq invariants cibles

Chaque invariant est formulé comme une phrase qu'un junior peut appliquer, et il est
accompagné de la barrière qui le rend vrai. **Un invariant sans barrière est un vœu.**

### I1 — Un seul arbre

> *Le jeu des noms de dossiers sous `modules/` est identique sur les trois drivers. Une
> fonctionnalité non implémentée est un dossier avec un `init` qui déclare pourquoi, jamais
> une absence.*

**Point de départ mesuré : le ratio d'identité d'arborescence est de 18,9 %** — sur 53
sous-répertoires distincts de profondeur ≤ 2 à travers les trois drivers, **10 seulement sont
présents dans les trois**. C'est le chiffre que cet invariant doit porter à 100 %, et c'est
aussi la métrique de progression du lot 3.

Barrière : `tools/test/test-driver-tree-parity.cjs` — compare les ensembles de noms de
répertoires récursifs des trois drivers et échoue s'ils diffèrent ; vérifie qu'aucun
chemin hors `platform/` et `adapters/` ne contient un nom d'OS ou de produit
(`karabiner|kanata|webkit|webview2|hammerspoon|gtk|dbus|ydotool|autohotkey`) ; vérifie que
`_shared/` ne contient aucun segment de chemin dans `{windows, macos, linux, ahk, hs}`.

`diff <(ls -R windows/modules) <(ls -R macos/modules)` doit être vide. L'exigence n°1 du
mainteneur devient une ligne de commande.

### I2 — Un seul espace de noms de fonctionnalités

> *Une fonctionnalité vit à son chemin sémantique, jamais sous un nom de driver. Les
> plateformes sont `windows | macos | linux`. Une fonctionnalité absente d'une plateforme
> porte une `reason_key` traduite.*

Barrières : un lint qui échoue sur toute section nommée d'après un driver
(`[sections.ahk*]`, `[sections.hs*]`) ; extension de `KNOWN_PLATFORMS` à `linux` dans
`test-menu-manifest.cjs:36` ; un rapport de couverture plateforme qui exige une
`reason_key` pour toute entrée non universelle.

Corollaire visible par l'utilisateur : **le menu est identique partout**. Une entrée
indisponible sur cet OS est affichée **grisée avec une infobulle traduite expliquant
pourquoi**, pas absente. Le port `TrayMenu` supporte déjà `enabled: false` par contrat.

### I3 — Un seul menu

> *Le manifeste décrit ce que l'utilisateur voit. Le renderer décrit comment cet OS dessine
> une ligne. Le driver ne fournit que des actions nommées, des getters d'état nommés et des
> providers de liste nommés. Si la position ou le libellé d'une ligne vit dans du code
> driver, c'est un bug.*

Cible : un manifeste v3 complet (14 capacités manquantes recensées, §6 lot 5) + **un
renderer par driver**, budget ≤ 300 lignes ; macOS et Linux **partagent le même renderer
Lua** car leurs deux adaptateurs acceptent déjà la même forme d'item.

Barrières : `test-menu-parity` rend le manifeste pour les trois plateformes et compare les
arbres de libellés ; bijection `action_id` ↔ handler dans les deux sens ; **cliquet « aucune
ligne de menu créée hors du renderer »**, calibré au comptage post-migration (aujourd'hui
265 sites AHK + 399 macOS + 101 Linux) et qui ne peut que descendre. C'est ce cliquet qui
empêche la repousse.

### I4 — Un seul registre d'actions

> *Une action est une ligne de `_shared/modules/actions/actions.toml` : id, clé i18n,
> plateformes, et soit `emit` (une chaîne d'accord de touches en notation neutre) soit
> `native` (une `famille.fonction` implémentée dans `modules/actions/<famille>` du driver).*

Deux modificateurs logiques, parce que la mesure montre deux équivalences distinctes :

| Jeton logique | Signification | Windows | macOS | Linux |
|---|---|---|---|---|
| `cmdorctrl` | *le modificateur que les applications utilisent pour leurs raccourcis* | `ctrl` | `cmd` | `ctrl` |
| `driver` | *le modificateur réservé à la couche Ergopti+* | `win` | `ctrl` | `super` |

Barrières : bijection registre ↔ handlers ; validité de la notation d'accord par driver ;
corpus de vecteurs `notation neutre → accord natif` rejoué par les trois suites ; contrôle
au démarrage que toute action déclarée pour ce driver possède un `emit` ou un `native`
résoluble — **échec bruyant au boot** plutôt que disparition silencieuse du sélecteur.

### I5 — Une seule implémentation par comportement

> *La logique pure vit dans `_shared/lua/`. macOS et Linux la `require`. L'AHK obtient soit
> la **donnée** par codegen, soit un **jumeau porté épinglé par un corpus de vecteurs
> partagé**. Une deuxième copie écrite à la main sans corpus est interdite.*

La règle de décision codegen, en une phrase applicable mécaniquement :

> **On génère uniquement quand le driver ne peut pas lire la source, ou quand la lire au
> boot coûterait des millisecondes mesurables ; sinon on lit la donnée au runtime. Et quand
> on génère, on génère de la donnée, jamais de la logique.**

Le prétexte historique « l'AHK ne peut pas lire les données partagées » est **faux** :
`windows/lib/json.ahk` et `windows/lib/toml/` existent, et l'AHK lit déjà au runtime
`menu_manifest.json`, `priority.json`, les 21 locales, tous les TOML de hotstrings et
`profiles.json`.

### La couture de plateforme, en une phrase

> **L'unicité OS n'a le droit de vivre qu'à deux endroits : `adapters/` (le *comment*) et
> une colonne d'override par OS dans une donnée partagée (le *quoi*). Partout ailleurs,
> c'est un bug.**

C'est la réponse complète à « comment j'ajoute cmd+lettre sur macOS vs ctrl+lettre
ailleurs ? » : **on ne le fait pas**. On écrit `driver+w` une fois, et la couture résout.

---

## 5. L'arborescence canonique

### 5.1 Pourquoi la découpe actuelle `lib/` / `modules/` / `ui/` ne porte aucune information

Mesuré :

- `windows/lib/` contient **24 017 lignes**, soit 29 % du driver, dont **deux
  fonctionnalités complètes** (`lib/hotstrings/` 7 373 l, `lib/updater/` 2 040 l) qui sont
  dans `modules/` sur Linux.
- `ui/` n'est pas une couche : la *même* application webview est hébergée depuis `ui/`
  (macOS), depuis `modules/llm/` et `modules/keylogger/` (Windows) et depuis `modules/ui/`
  (Linux).
- Le seul dossier qui porte une information est `adapters/`, **parce qu'il a un contrat**.
- `lib/toml/` contient le parseur réel de 1 837 lignes sur Windows et trois shims de 17
  lignes sur macOS : même chemin, sens opposé.

### 5.2 La règle, imprimable sur une ligne

> **Si ça a un nom visible par l'utilisateur, c'est `modules/<ce nom>/`. Si ça a un contrat
> dans `_shared/core/ports/`, c'est `adapters/`. Si c'est unique à l'OS, c'est
> `platform/`. Tout le reste est un fichier plat dans `infra/`.**

### 5.3 L'arbre

Identique sur les trois drivers ; seule l'extension change.

```
<driver>/
  main.{ahk,lua}            # LE point d'entrée, même basename partout (~40 lignes)
  README.md                 # généré depuis l'arbre, pas écrit à la main
  adapters/                 # 20 ports + shell_runner + helpers OS locaux
  infra/                    # plat ; plomberie transverse uniquement
    logger  i18n  locale  shared_paths  config_paths  timings  json
    crash_reporter  boot_profiler  hotpath_profiler  lifecycle
    file_watchers  manifest_reader  menu_render  menu_host  ui_host  text_utils
    toml/                   # le seul sous-namespace autorisé
  modules/<feature>/        # un dossier par fonctionnalité, MÊMES NOMS partout
    init.{ahk,lua}          # API publique + init()/start()/stop()
    actions.{ahk,lua}       # handlers d'actions, indexés par id partagé
    menu.{ahk,lua}          # providers de menu dynamiques, si la feature en a
    window.{ahk,lua}        # hôte de fenêtre webview/GUI, si la feature en a
    platform.{ahk,lua}      # le backend OS, S'IL EN FAUT UN — seul lieu de différence
    README.md
  platform/                 # SEUL endroit où l'unicité OS peut vivre
    remap/                  # tap_holds (win) | karabiner (mac) | kanata (linux)
    launcher/               # app Swift (mac) | bin/ + .service (linux) | — (win)
    packaging/              # install.sh, scripts de build
  _generated/               # mêmes noms de fichiers sur les trois drivers
  tests/                    # même arborescence, même nom de runner
  vendor/
```

### 5.4 La liste canonique des `modules/`

Dérivée de `_shared/ui/apps.manifest.json` (14 apps) + `_shared/modules/` (11 namespaces)
+ `menu_manifest.json`. Elle devient elle-même une donnée
(`_shared/core/features.json`) lue par le générateur `new:driver`, par la barrière de
parité d'arbre et par les drivers.

`action_picker` · `apps` · `changelog` · `diagnostics` · `download` · `dynamic_hotstrings`
· `gestures` · `healthcheck` · `hotstring_editor` · `hotstrings` · `hotstrings_config` ·
`layout` · `llm` · `menu` · `metrics` · `model_browser` · `onboarding` · `paths` ·
`personal_info` · `prompt_editor` · `shortcuts` · `spotlight` · `tooltip` · `updater` ·
`wpm`

### 5.5 Les renommages non négociables

Ce sont ceux qui, seuls, débloquent « connaître un driver permet de déduire les autres » :

| Aujourd'hui | Cible | Motif |
|---|---|---|
| `windows/modules/keymap/` (remap physique) | `modules/layout/` | le nom `keymap` désigne deux sous-systèmes opposés selon le driver |
| `macos/modules/keymap/` (moteur d'expansion) | `modules/hotstrings/` | idem |
| `windows/lib/hotstrings/` | `modules/hotstrings/` | une fonctionnalité n'est pas une bibliothèque |
| `windows/modules/tap_holds/` + `lib/tap_hold/` | `platform/remap/` | pluriel/singulier dans le même driver, reliés par un `#Include ../` |
| `macos/modules/karabiner/`, `linux/modules/kanata/` | `platform/remap/` | trois noms, aucun parent commun |
| `modules/keylogger/` | `modules/metrics/` | « keylogger » est le mécanisme ; la fonctionnalité s'appelle métriques, et `_shared/ui/` utilise déjà ce mot |
| `linux/modules/menu/`, `linux/modules/ui/` | `modules/menu/`, `modules/<feature>/window.lua` | Linux a **deux** namespaces `ui` |
| `windows/ui/personal_toml_editor*` | `modules/hotstring_editor/` | le nom Windows désigne autre chose que sur Linux |
| `_shared/lua/linux/tray_protocol.lua` | `_shared/lua/tray/protocol.lua` | un nœud nommé d'après une plateforme dans `_shared/` |
| `_shared/lua/llm/linux_bridge.lua` | `linux/infra/llm_bridge.lua` | 364 lignes « partagées » à consommateur unique |
| `windows/lib/registry.ahk` (registre Windows) | `infra/win_registry.ahk` | collision de nom avec le registre de hotstrings macOS |
| `ErgoptiPlus.ahk` / `init.lua` / `ergopti_hotstrings.lua` | `main.{ahk,lua}` | trois noms pour un rôle — **à différer si le mainteneur veut le plus petit changeset sûr** (§12) |

### 5.6 Les deux conventions qui rendent l'asymétrie lisible

**Convention P — `platform/` est le seul mot de l'arbre qui signifie « ceci diffère selon
l'OS ».** Chaque driver a `platform/` avec les **mêmes sous-dossiers**. Un driver qui n'a
rien pour l'un d'eux livre le dossier avec un unique `README.md` expliquant le mécanisme
qu'il utilise à la place. Aucun fichier hors `platform/` et `adapters/` ne peut nommer un
OS ou un produit tiers. C'est un `grep`, et c'est toute la règle.

**Convention S — le stub avec un motif.** Chaque dossier de la liste canonique existe sur
chaque driver. Quand un driver ne l'implémente pas :

```lua
--- modules/wpm/init.lua

--- ==============================================================================
--- MODULE: WPM Widget (Linux — not implemented)
--- DESCRIPTION:
--- Placeholder for the on-screen WPM widget. Windows renders it with GDI+ in a
--- layered window (windows/modules/wpm/); macOS uses hs.canvas (macos/modules/wpm/).
--- Linux has no implementation yet: the blocker is the Wayland overlay protocol.
--- STATUS: not implemented. This file exists so the tree matches its siblings.
--- REASON_KEY: platform.wpm_unavailable_linux
--- ==============================================================================

local M = {}
function M.init() return M end   -- no-op: feature unavailable on this platform
return M
```

Trois propriétés achetées : la parité d'arbre devient un `diff` ; « non implémenté »
devient **visible et daté** au lieu d'être une absence ; et un junior à qui l'on demande
« ajoute le widget WPM sur Linux » sait exactement quel fichier ouvrir. La `REASON_KEY`
alimente l'infobulle de l'entrée de menu grisée (I2).

---

## 6. Le plan par lots

Ordre choisi selon trois contraintes dures : **les chemins avant les déménagements ; les
déménagements avant les changements de contenu ; les données avant le code.** Chaque lot
est livrable seul et vert seul.

Les charges sont en jours-homme et **estimées**.

### Lot 0 — La vérité (1 j, risque nul)

Rien de fonctionnel. On supprime la fausse carte avant que quiconque navigue avec.

- Corriger `windows/README.md` (CRLF→LF, retirer le `data/` inexistant, retirer la
  prétention de miroir), `macos/README.md`, la section « Directory structure » de
  `linux/README.md` (9 adaptateurs → 22 ; ajouter `lib/`, les 9 dossiers `modules/`
  manquants et `ui/`), `linux/modules/README.md` (« intentionnellement vide » → 8 213 l),
  `macos/_generated/README.md:9` (`terminators.lua` inexistant).
- Corriger `_shared/README.md:31-36` : remplacer « transpilation générée » par la vraie
  règle (§4, I5).
- Corriger l'en-tête de `_shared/modules/features/shortcuts.toml` : dire qu'il n'est lu par
  personne et que son générateur a été retiré en `794204fe6`. **Ne pas le supprimer** — il
  est le meilleur artefact de la zone et devient la cible de conception du lot 6.
- Corriger `_shared/modules/logger/{README.md,SPEC.md}` (suite de conformité inexistante,
  dédup AHK niée, portée limitée à 2 drivers alors que Linux est le seul à exécuter le cœur
  partagé).
- Supprimer les 23 références de phase de plan mortes (`P5 refactor`, `P0 SSoT`, `P6
  split`) dans les sources, dont 8 pointent vers des fichiers disparus.
- Ajouter `linux/ui` à la portée de `tools/lint/audit-file-headers.cjs` (angle mort actuel :
  la barrière annonce 555/555 propres tout en ignorant le dossier).
- Décider du sort de `.husky/` : soit réintroduire les hooks, soit retirer
  `"prepare": "husky install"` de `package.json` et corriger les conventions qui en
  parlent.
- Supprimer les débris du reorg : `static/drivers/autohotkey/` (vide, non suivi, non
  ignoré), `tools/temp/`, `tools/build/PKGBUILD` (référencé nulle part),
  `tools/codegen/codegen-prompt-builder-hs.cjs` (34 lignes qui n'émettent rien).

### Lot 1 — Les blocages fonctionnels (5 j, risque faible)

Les 12 items du §7. Ce sont des bugs, pas du refactor ; chacun part avec son test de
régression, un commit par correction. **Priorité absolue aux quatre items de
confidentialité.**

### Lot 2 — Le filet avant tout déménagement (4 j, risque faible)

Sans ce lot, le lot 3 désarme silencieusement un cinquième de la suite Windows.

1. **`_DriverDirConcat` et `_DriverFuncBody` doivent lever une exception sur vide.**
   Aujourd'hui ils renvoient `""` quand le répertoire ou la fonction n'existe pas, et
   `InStr("", x)` vaut 0 — donc **toute assertion « ne doit pas contenir » passe à vide**.
   220 sites d'appel sur 139 fichiers, 24 noms de répertoires en dur. Et le cliquet
   `test-no-pinned-source-reads.cjs:48` **certifie ces 139 fichiers comme résistants aux
   déplacements** parce qu'ils utilisent le helper. *Rien d'autre dans ce plan ne compte
   avant que ce point soit corrigé.*
2. Étendre `test-git-mv-resilience.cjs` (macOS uniquement aujourd'hui) aux épinglages de
   répertoire AHK et aux épinglages de fichier Linux.
3. Convertir les 88 lectures épinglées macOS auto-convertibles
   (`tools/lint/fix-pinned-source-reads.cjs --all --fix`), traiter les 90 restantes à la
   main, **abaisser** les deux cliquets.
4. Corriger les 16 assertions de corpus AHK qui `return` silencieusement quand le corpus
   est illisible (`test_corpus_hotstrings.ahk`, `test_corpus_tap_hold.ahk`,
   `test_tooltip_dequeue_contract.ahk`) : déplacer le corpus produirait 1 rouge et 16 verts
   au lieu de 100+ rouges.
5. Ajouter à `verify-change.cjs` la règle « une édition de `_shared/tests/**` ou
   `_shared/core/**` sélectionne les trois suites de drivers » — 4 lignes, et cela referme
   le trou où le seul type de fichier que l'ADR-006 déclare obligatoire pour tous est celui
   dont l'édition ne déclenche aucune suite de driver.
6. Couverture de parsing par driver : les **115 fichiers de production AHK sur 240 (48 %)
   atteignables depuis le point d'entrée mais pas depuis `run_all.ahk`** ne sont validés
   par aucune barrière autrement que comme du texte ; le point d'entrée Linux a **zéro**
   couverture de parsing. (Ne **pas** utiliser `/validate` — le drapeau est ignoré et le
   script s'exécute.)

### Lot 3 — Une seule arborescence (8 j, risque moyen)

Quatre étapes indépendantes, chacune verte seule. La liste complète des `git mv` est
dérivable de §5.5 ; l'ordre importe :

**3a — `platform/`** (le plus petit rayon d'action, le plus grand gain conceptuel) :
extraire `tap_holds`/`karabiner`/`kanata`, `launcher`, `packaging`, `apps`.
**3b — `lib/` → `infra/` + promotion des fonctionnalités** hors de `lib/`. Attention : les
shims `macos/infra/text_utils.lua` et `macos/infra/toml/*.lua` **doivent garder leur
basename** — ~30 modules de production les `require` et ~12 fichiers de test stubent
`package.loaded["lib.text_utils"]` ; le renommage de préfixe `lib.` → `infra.` doit toucher
production **et** stubs dans le même commit, sinon chaque stub cesse silencieusement
d'intercepter.
**3c — `ui/` se dissout dans `modules/<feature>/{menu,window}.<ext>`.** À lui seul, ce
point supprime la classe entière « le lecteur doit savoir que Windows cache la fenêtre de
métriques dans `modules/keylogger/keylogger_webview.ahk` ».
**3d — dé-plateformisation de `_shared/`** + réparation de `tools/codegen/new-driver.js`
(trois constantes de chemin fausses, `REPO_ROOT` résolvant vers `tools/`, `DRIVER_SUBDIRS`
faux dans les deux sens) pour qu'il génère l'arbre canonique **piloté par la donnée**.

Puis la barrière `test-driver-tree-parity.cjs` (I1), et les stubs de la convention S.

Le générateur devient alors la définition exécutable de l'arbre canonique, et la barrière
devient « les drivers existants ressemblent encore à ce que `new:driver` produirait ». Le
lot se termine par : `npm run new:driver bsd` produit un squelette immédiatement conforme.

### Lot 4 — Un seul espace de noms de fonctionnalités (6 j, risque moyen)

- Migrer les 206 fonctionnalités des silos `[ahk.*]` / `[hs.*]` vers leur chemin
  sémantique, avec `platforms` par entrée. **C'est une rupture de schéma de configuration**
  (les clés de config changent) — acceptable sous carte blanche, et le précédent v1→v2 a
  établi la procédure : l'utilisateur supprime son `config.toml`, le driver le régénère.
- Ajouter `linux` aux `platforms` des fonctionnalités que Linux implémente réellement, et à
  `KNOWN_PLATFORMS` dans `test-menu-manifest.cjs:36`.
- Créer `linux/_generated/features_manifest.lua` + `linux/infra/manifest_reader.lua` ;
  étendre `test-config-schema.cjs` au gabarit Linux. Supprimer les deux gabarits
  `config_template.toml` sans lecteur (macOS 425 l, Linux 5 l) **ou** leur donner un
  premier-boot, au choix (§13).
- Fusionner les doublons de toggles : les trois filtres de confidentialité existent
  **deux fois** dans le manifeste partagé (`metrics.*_filter_enabled` avec
  `platforms = ["ahk","hs"]` **et** `ahk.metrics.filter_*`), et l'AHK ne lit ni l'un ni
  l'autre — il code `:= true` en dur.

### Lot 5 — Un seul menu (15 j, risque moyen)

Le manifeste v3 doit gagner exactement les 14 capacités qui expliquent chaque ligne écrite
à la main aujourd'hui — c'est le cahier des charges, mesuré ligne par ligne :

`checked_when` (liaison d'état pour la coche, ~14 lignes débloquées) · `action` id résoluble
(12) · composition de libellé `format` + `args` avec valeurs vives (~20) · `provider` de
liste dynamique (~15 slots, des centaines de lignes) · `radio_group` (~5 groupes) ·
`toggle_shape` (`parent` sur macOS/Linux, `first_row` sur AHK — déjà résolu pour le seul
sous-menu IA, à généraliser) · `prompt` déclaratif (~12 corps de 20 lignes) · compteurs et
badges (~12) · le jeton `linux` · groupes imbriqués au-delà d'un niveau (~4 sous-arbres) ·
sémantique de séparateur (réimplémentée 3 fois) · champ `emoji`/icône · `visible_when`
(~8) · liste de sections de premier niveau (les 9 ids de tête ne sont lus par personne).

Séquencement recommandé, du plus sûr au plus risqué :

1. **Pilote sur le menu Métriques** — le mieux couvert par des tests, et le plus mécanique :
   ~280 lignes de handlers sur deux drivers deviennent ~26 lignes de manifeste + ~26
   entrées de registre. C'est la preuve du patron avant de toucher quoi que ce soit de
   moins couvert.
2. Tuer les cinq duplications de clés mortes du manifeste (ordre des hotstrings dynamiques,
   lettres accentuées, combos de modificateurs, double décodage macOS du manifeste, et les
   3 filtres `platforms` qui mentent sur le produit). Ajouter la barrière **« toute clé
   tableau du manifeste doit avoir au moins un lecteur »** — c'est elle qui empêche la
   6ᵉ clé morte.
3. **Linux devient une plateforme de première classe** : écrire
   `_shared/lua/menu/render.lua` (partagé macOS + Linux, ~230 l) et
   `linux/infra/menu_host.lua` (~180 l), supprimer `menu_builder.lua` (833 l), router les
   101 littéraux français vers les locales partagées. Sûr, parce que le menu Linux est
   opt-in.
4. Migrer les sous-menus Hotstrings puis Layout de macOS vers le manifeste. Le second exige
   d'abord que le manifeste gagne des lignes `platforms:["macos"]` pour les fonctionnalités
   TIS/bundle : aujourd'hui `layout_menu` décrit un menu **Windows-only** que la barrière de
   dérive macOS épingle sans que macOS l'implémente. Supprimer
   `test_menu_hotstrings_layout_drift_gate.lua` **après**, jamais avant.
5. Sortir de `macos/ui/menu/` les 1 812 lignes qui ne sont pas de la mise en page de menu
   (`preferences.lua`, `menu_state.lua`, `menu_watchers.lua`, `shortcut_utils.lua`,
   `menu_paths.lua`).
6. Absorber `_shared/modules/llm/menu_layout.json` dans v3 : son schéma est un
   sous-ensemble strict de v3 et possède exactement les champs que v1 n'avait pas — inventé
   séparément, pour un seul sous-menu, après la même classe de bug.
7. Poser le **cliquet « aucune ligne de menu hors du renderer »**.

Résultat attendu (estimé) : macOS `ui/menu/` de 20 fichiers → 4 ; Windows de 12 → 5 ;
suppression nette ≈ 7 800 lignes, ~3 200 lignes déplacées vers leur module propriétaire.

### Lot 6 — Un seul registre d'actions (15 j, risque moyen)

1. Corriger les 12 actions mal déclarées `platform = "ahk"` (enregistrer les fonctions
   macOS existantes dans le registre, basculer `platform` à `all`). Gain immédiat visible :
   « Téléporter la souris » devient assignable à un geste sur macOS.
2. Déplacer `_shared/modules/gestures/actions.toml` vers
   `_shared/modules/actions/actions.toml` (il a cessé d'être spécifique aux gestes le jour
   où les tap-holds, les accords de script et les slots clavier ont commencé à le lire) et
   lui ajouter `emit` / `emit_<os>` / `native` / `default_chord` / `ports`.
3. Convertir les **62 actions Windows de pure émission de frappe** en lignes `emit` : cela
   supprime 62 lambdas AHK, 27 closures Lua et ~30 branches `elseif` Linux.
4. Écrire `chord.{ahk,lua}` (le traducteur notation neutre → accord natif) et ajouter le
   **21ᵉ port, `HotkeyRegistrar`** — les 20 ports existants n'ont aucune opération « lier un
   accord à un callback », ce qui est précisément pourquoi chaque driver a inventé la
   sienne.
5. Remplacer les couches A+B de Windows (deux mécanismes qui lient la même intention à deux
   touches physiques différentes, parce que la couche B est enregistrée **avant** l'inclusion
   de `modules/keymap/layout.ahk` et résout donc contre la disposition de l'OS et non celle
   d'Ergopti) par une table unique consciente de la disposition.
6. Donner à macOS l'interface de liaison qui lui manque : son module de slots clavier est
   du **matériel mort** — `M.DEFAULTS` est vide par conception et le seul appelant de
   production de `set_action` est la fonction qui écrit `"none"`. Aucun sélecteur, aucune
   entrée de menu, aucune clé de config ne peut assigner un slot.
7. Fusionner `karabiner/data/actions.json` (73 actions, français en dur) dans le registre
   unique. La capacité `holdable` devient un drapeau par action, pas un second registre.
8. Réparer le pont `action_picker` de Linux, qui implémente un protocole **différent et
   fictif** (`execute`/`search`/`ready`/`close` et trois libellés français en dur) : il
   n'appelle jamais `init(...)`, donc la page s'afficherait vide. Le test de contrat ne
   vérifie que deux hôtes sur trois.
9. Remplacer les groupes `ctrl_shortcuts` / `cmd_shortcuts` (macOS-only) et
   `modifier_combos` (AHK-only) du manifeste par **un** groupe `chord_bindings` rendu
   identiquement partout. C'est la plus grosse asymétrie visible du menu Raccourcis.
10. Supprimer le repli de 136 lignes de libellés en dur de macOS et les 13 clés de locale
    `shortcuts.label_*` qui doublonnent une clé `sg_actions.*` (13 paires × 21 locales =
    **273 chaînes de traduction redondantes**).

### Lot 7 — Le socle transverse (10 j, risque faible à moyen)

Ordre imposé par les dépendances :

1. **Sink de logger sur Linux** (blocage, §7-B1) — prérequis de tout le reste.
2. **`linux/infra/shared_paths.lua` + `config_paths.lua`**, en miroir de macOS et de
   `windows/lib/boot.ahk` ; router les 12 expressions et les 14 sites `$HOME`. Cela corrige
   **deux bugs vivants comme classe** (§7-B2, B3), ce qui est le meilleur argument
   disponible pour dire que ce n'est pas cosmétique. Barrière associée :
   `test-shared-root-resolvers.cjs` — énumère toutes les expressions de résolution en
   production et **exécute chacune contre l'arbre réel** en vérifiant que le fichier
   existe. Il doit affirmer qu'un vrai fichier a été trouvé, jamais seulement que le module
   s'est chargé.
3. Sortir la SSOT des chemins de configuration macOS de `ui/menu/menu_paths.lua` (25 sites
   d'appel) : aujourd'hui `lib/` dépend de `ui/menu/`, ce qu'un lecteur de
   `windows/lib/boot.ahk` ne devinera jamais.
4. **Générer les tables de routage de sous-fichiers du logger** depuis `sub_files.toml` :
   supprime deux parseurs TOML « array of tables » écrits à la main (150 + 112 lignes) qui
   portent **le même correctif du même bug** (« un `]` dans un motif entre guillemets
   fermait le tableau trop tôt »), et rend ce bug structurellement impossible.
5. Section `[logger]` dans `_shared/modules/timings/constants.toml` + barrière
   single-source : rétention 14 (4 copies), anneau 200 (3), fenêtre de dédup 5 s (2
   littéraux magiques), intervalle de flush 500 ms.
6. Chaîne de repli `active → en → fr` dans `_shared/ui/i18n.js` — aujourd'hui il récupère
   un seul fichier et laisse les clés manquantes **vides**, alors que les trois drivers
   natifs cascadent. Une locale partiellement traduite affiche donc des libellés blancs
   dans toutes les webviews partagées.
7. Générer les trois tables de 21 locales depuis `locale_order.json` + un nouveau
   `locale_names.json` (la colonne drapeau/tag reste par driver : sur Windows les emojis
   drapeau ne s'affichent pas, c'est une contrainte OS réelle).
8. **Ensuite seulement**, faire consommer le cœur logger partagé par macOS — et pas avant
   d'avoir écrit le corpus de comportement (`_shared/tests/corpus/logger/`). C'est le module
   au pire historique de bugs du dépôt ; il ne doit pas être refactoré sans vecteurs
   exécutables.

### Lot 8 — Les moteurs (20 j, risque moyen à élevé)

Le seul lot où « une seule implémentation » doit être promis avec précision. **Ne pas
promettre un moteur unique pour 12 000 lignes.** Le cœur réellement agnostique et digne
d'être unifié fait **~350 lignes** : bucketing par caractère de queue, égalité de suffixe
avec repli de casse, prédicat de frontière de mot, chaîne de départage des collisions. Le
reste (stratégie d'émission, synchronisation tampon/écran, comptabilité de suppression, I/O
TOML, aperçu tooltip, quirks OS) est légitimement par driver.

Séquence :

1. **Corriger le contrat du corpus avant tout.** `backspace_count` **ne peut pas** être un
   contrat cross-driver : Windows et Linux laissent la frappe déclenchante atteindre l'écran
   avant d'effacer, macOS la consomme et applique en plus une optimisation de préfixe
   commun. Pour `btw → by the way`, la bonne réponse est 3 sur Windows/Linux et 1 sur
   macOS. C'est la raison pour laquelle le consommateur macOS a dégénéré en contrôles
   structurels — **le corpus a tort, pas macOS**. Tant que ce point n'est pas réglé, une
   implémentation correcte serait rejetée.
2. Étendre le corpus aux branches non couvertes, mesurées comme absentes : `auto_expand`,
   `final_result`, le chemin terminateur, les déclencheurs étoile/magic-key, `case_conform`,
   `is_case_sensitive_strict` (1 302 entrées l'utilisent !), la règle typographique NBSP, le
   plafond de tampon, les délimiteurs consommés, les niveaux de priorité
   `individual > section > file`, `is_word` comme critère de départage.
3. Générer le cœur de matcher unique dans les deux langues cibles, avec **le générateur de
   terminateurs comme modèle** : `codegen-terminators.cjs` fait déjà exactement cela, vers
   exactement ces deux cibles, et c'est **le seul composant du moteur qui n'a jamais
   dérivé**. On étend une machinerie prouvée, on n'invente pas une architecture.
4. Aligner les huit divergences mesurées, dont : Linux ne déclenche **jamais** une hotstring
   non-`auto_expand` (son loader ne lit même pas le champ), Linux n'a aucune propagation de
   casse ni priorité de collision, et son magic key par défaut est `\` alors que le
   manifeste partagé dit `★`.
5. **LLM** : constantes du prompt-builder depuis un JSON unique (5 copies écrites à la main
   aujourd'hui, et **elles ont déjà divergé** — le correctif `context_window_chars` n'a
   jamais été porté côté AHK, donc `llm_context_length` n'a aucun effet sur le chemin
   automatique Windows) ; donner à Linux `strip_thinking` (sans quoi le `<think>…</think>`
   d'un modèle de raisonnement est **tapé dans le document de l'utilisateur**) ; router les
   six implémentations de « POST une complétion » par le port `HttpClient` — macOS-MLX prouve
   déjà que le port suffit ; générer la table de correspondance de réglages, ce qui supprime
   `menu_persistence_contract.json` (436 l) et ses deux validateurs Python non câblés.
6. **Métriques** : cœur d'agrégation partagé (deux marcheurs de ~1 330 lignes dont les noms
   de fonctions correspondent 1:1, et dont l'un déclare en commentaire qu'il « MIRRORS »
   l'autre) ; huit constantes déclarées trois fois dont la copie partagée n'existe que pour
   être masquée ; la formule WPM écrite **sept** fois.
7. **Remap** : une IR tap-hold partagée + trois émetteurs
   (`emit_kanata` / `emit_karabiner` / `emit_ahk`), là où il n'existe aujourd'hui qu'un
   émetteur kanata garé dans `_shared/`. Et `_shared/tap_hold/defaults.toml` doit devenir
   **un** espace de noms : c'est aujourd'hui deux fichiers non reliés dans un seul, décrivant
   les mêmes sept touches physiques avec des ids différents, des actions différentes et un
   seuil 3 à 5 fois différent.
8. **Tooltip** : câbler les 1 483 lignes de JS partagé **comme oracle** (générateur de
   vecteurs + harnais de conformité), pas comme runtime. Aujourd'hui la barrière nommée
   « tooltip corpus parity » ne `require` aucun des deux modules JS qu'elle prétend
   comparer, le test macOS rejoue un clone interne au test au lieu du renderer, et le test
   AHK ne compare jamais les 6 valeurs d'or. La constante `caret_offset_x` du TOML partagé
   n'atteint jamais Windows, avec trois commentaires affirmant le contraire.

### Lot 9 — Les tests (10 j, risque faible)

Le plafond honnête : les répertoires `meta/` seuls font **84 956 lignes (44 %)** et chacun
asserte sur le texte source d'**un** driver. Ce n'est pas du gâchis — c'est le mécanisme par
lequel les invariants structurels sont épinglés dans un dépôt sans analyseur statique. Le
plan **ne doit pas** promettre que les suites de tests se partagent comme les drivers.

Ce qui est atteignable, mesuré : **≈ −11 500 lignes**.

| Cible | Aujourd'hui | Après | Mécanisme |
|---|---:|---:|---|
Consommateurs de corpus (16 corpus, 258 vecteurs) | 9 122 | ~1 900 | un schéma de rejeu par corpus + un runner générique de ~120 l par driver |
Vecteurs de contrat de ports (129 vecteurs) | 2 001 | ~700 | générer `_shared/tests/corpus/ports/<Port>_vectors.json` depuis `contractTestVectors()` |
Harnais e2e | 1 319 | ~750 | un harnais, piloté par corpus, qui échoue bruyamment si le corpus manque |
Bibliothèque d'assertions Lua | 352 | 176 | le `diff` des deux fichiers montre **62 lignes différentes, toutes des commentaires, bannières et ordre de déclaration** |
Invariants de convention (8, en 2-3 langages) | 1 594 | ~450 | une barrière `.cjs` par invariant, balayant les trois arbres — et Linux gagne 6 invariants qu'il n'a pas |
Présence/conformité des ports | 1 575 | ~500 | une barrière JS sur `contracts.json` × les trois arbres |

Points à traiter au passage :

- **Ordre des arguments d'assertion inversé** entre AHK (`AssertEqual(attendu, obtenu)`) et
  Lua (`assert_eq(obtenu, attendu)`), sur **1 587 sites**. Un test porté d'un driver à
  l'autre — exactement l'opération que le mainteneur veut rendre triviale — échange
  silencieusement attendu et obtenu.
- **`AssertEqual` est insensible à la casse** (AHK v2 `!=`), sur ces 1 587 sites. Le dépôt
  connaît le piège et l'a documenté dans un autre fichier. Conséquence concrète : la
  direction *positive* des vecteurs de sensibilité à la casse n'est pas épinglée sur
  Windows. À corriger dans un commit dédié, avec triage des rouges.
- **Les skips deviennent de la donnée**, pas des assertions :
  `_shared/tests/conformance/manifest.json` avec `{status, reason, tracked}` par
  (corpus × driver). Une entrée `full` sans consommateur échoue ; un `skip` sans motif
  échoue ; un `skip` dont le driver a depuis acquis la capacité échoue. Cela convertit les
  6 tautologies Linux et les 7 skips `AssertTrue(true, "…macOS-only…")` en registre qui ne
  peut pas pourrir.
- Deux fichiers macOS (593 lignes) rejouent 36 vecteurs contre **une réimplémentation
  interne au test** du parseur LLM, avec une docstring affirmant que toute divergence
  d'avec le module devient un échec de test. C'est faux : aucun `require` du module. Le
  jumeau AHK fait 136 lignes et appelle le vrai code.
- 8 fichiers sous `windows/tests/` que rien n'invoque, dont le **seul** consommateur Windows
  de `process_prediction_vectors.json` (17 vecteurs, donc zéro couverture Windows en CI).
- 20 fichiers de test nommés d'après une date ou une phase de plan
  (`test_audit_2026_07_20_batch4.ahk`, `test_b7_1_*`, `test_audit_v5_fixes.lua`) : ~2 900
  lignes qu'un junior cherchant « le test qui protège X » ne trouvera jamais.

### Lot 10 — Élagage (5 j, risque faible)

- Porter la barrière de reachability macOS vers Windows et Linux ; puis **supprimer les
  3 101 lignes d'adaptateurs morts** (11 fichiers Linux, 8 Windows) avec leurs `ADAPTER_*`
  maps, leurs lignes de diagnostic santé et leurs sections de vecteurs. Chaque suppression
  porte dans le corps du commit la preuve mesurée de zéro consommateur (le dépôt a une règle
  explicite : supprimer un module inutilisé supprime aussi la preuve qu'il n'a jamais
  fonctionné).
- Réduire `contracts.json` aux ports survivants (ceux avec trafic de production mesuré) et
  remplacer l'ADR-001 par la réalité mesurée. Les candidats à la démotion honnête :
  `AppLauncher`, `Crypto`, `Storage`, `ProcessLifecycle`, `MouseControl`, `TooltipRenderer`
  — chacun mort sur au moins deux drivers sur trois.
- Étendre les deux cliquets de pureté à `ui/` et au point d'entrée, et ajouter à celui d'AHK
  les familles non surveillées (`SetTimer` 264 lignes, `Hotkey/Hotstring/HotIf` 203,
  `Gui/Menu` 162, `Run` 59, `Win*` 54, `GetKeyState` 45…) : **874 lignes non surveillées**
  aujourd'hui, plus 130 lignes dans `ui/` qui sont dans les catégories du cliquet mais hors
  de son périmètre de scan.
- Router les 61 shell-outs de modules Linux et les 54 quotings manuels par
  `shell_runner` — l'adaptateur existe depuis le 2026-07-29, sa docstring explique
  exactement pourquoi (`string.format("%q")` est un quoteur de littéral Lua, pas de shell :
  il laisse `$`, `` ` `` et `$( )` vivants), et **aucun module ne le `require`**.
- Une seule commande : `npm run gen` régénère tout, déterministe, dans un seul processus
  Node ; `npm run gen:check` écrit dans un temporaire et compare. Cela remplace les
  barrières de fraîcheur éparpillées et corrige par construction le fait que la barrière
  `test-features-manifest-no-drift.cjs` **réécrit silencieusement trois fichiers qu'elle ne
  garde pas** (elle sauvegarde 2 cibles, lance un générateur qui en écrit 5, restaure 2).
- Une seule convention `_generated/` : même première ligne, même bannière, jamais
  d'horodatage, un `README.md` lui-même généré ; les fichiers écrits par le driver au
  runtime déménagent dans `_runtime/`, un nom qui dit la vérité.
- Ajouter `*.json`, `*.toml`, `*.js` à `.gitattributes` en `eol=lf` : 6 des 12 fichiers
  générés suivis n'ont pas de règle, ce qui produit de faux « modifié » sur un checkout
  Windows — le symptôme est visible dans le `git status` actuel, et une barrière porte déjà
  un contournement `normalizeEol` écrit à la main pour cette raison.

### 6.1 Récapitulatif

| Lot | Contenu | Jours (estimé) | Risque |
|---|---|---:|---|
| 0 | La vérité (docs, orphelins, débris) | 1 | nul |
| 1 | Blocages fonctionnels | 5 | faible |
| 2 | Filet avant déménagement | 4 | faible |
| 3 | Une arborescence | 8 | moyen |
| 4 | Un espace de noms | 6 | moyen |
| 5 | Un menu | 15 | moyen |
| 6 | Un registre d'actions | 15 | moyen |
| 7 | Socle transverse | 10 | faible-moyen |
| 8 | Les moteurs | 20 | moyen-élevé |
| 9 | Les tests | 10 | faible |
| 10 | Élagage | 5 | faible |
| | **Total** | **≈ 99** | |

Suppression nette attendue, **estimée** en sommant les lignes mesurées par lot :
**≈ 26 000 lignes de production et de test**, sans perte de fonctionnalité — dont
≈ 7 800 (menu), ≈ 3 100 (adaptateurs morts), ≈ 11 500 (tests mutualisés), ≈ 2 200
(logger), ≈ 1 100 (LLM).

**Les lots 0 à 2 sont à faire quoi qu'il arrive.** Ils coûtent 10 jours, ne changent aucun
comportement, corrigent 12 bugs dont 4 de confidentialité, et sont le prérequis mécanique de
tout le reste.

---

## 7. Registre des blocages

Douze items qui sont des bugs, non du refactor. Chacun part avec un test de régression qui
encode la cause racine.

| # | Blocage | Preuve | Sévérité |
|---|---|---|---|
| **B1** | **Le daemon Linux n'écrit aucun log, nulle part.** `require("logger.shim")` résout vers le cœur partagé (car `_shared/lua` est sur le `package.path`), donc le repli `print` n'est jamais atteint ; le cœur n'écrit que dans un sink injecté ; **`set_sink` n'est appelé nulle part dans le driver**. Vérifié par exécution. Y compris `Logger.error("No keyboard device found…")` et `Logger.error("Keyboard hook failed to start — exiting.")`. Le menu propose « ouvrir les logs » sur un dossier que rien n'écrit. | `linux/ergopti_hotstrings.lua:72,78` ; `_shared/lua/logger/shim.lua:35-43` ; `_shared/lua/logger/init.lua:185-190` | blocage |
| **B2** | **Le menu Linux n'existe dans aucune installation packagée.** `opts.tray` vaut `false` par défaut et tout le bloc tray est conditionné par `--tray` ; **aucune** des 5 définitions de service systemd ne passe ce drapeau. Combiné à B1 : l'installation supportée donne un driver sans menu, sans icône et sans log. | `linux/ergopti_hotstrings.lua:200,558` ; `linux/ergopti-hotstrings.service:26` ; `install.sh:342` ; `build-linux-{deb,rpm}.sh` ; `PKGBUILD:92` | blocage |
| **B3** | **La config kanata générée sur Linux est inchargeable.** Le générateur remplace le *dernier* bloc `(defalias)` du gabarit, qui définit 12 alias, et n'en émet que 7 : `@copy` et `@paste` sont référencés par le bloc généré lui-même, `@rollx` et `@deadtrema` par le `deflayer default` préservé — quatre références pendantes. Le seul contrôle structurel du test est `kbd:find("defalias")`. | `linux/modules/kanata/manager.lua:206-251,292` ; `kanata/kanata.kbd:23,25,107-129` ; `_shared/lua/tap_hold/kanata_generator.lua:40-41,152-155` | blocage |
| **B4** | **Le keylogger Linux enregistre les frappes en clair, sans détection de champ sécurisé, sans possibilité de désactivation.** `keylogger.init({})` est inconditionnel ; le seul filtre est une comparaison de sous-chaîne contre huit noms d'application en dur ; il n'y a ni détection de navigation privée ni détection d'authentification système. Un mot de passe tapé dans un formulaire Firefox est écrit verbatim dans `events_typing.text`.<br><br>⚠ **Piège de correction, vérifié mot pour mot** : `linux/adapters/secure_field_detector.lua` existe et n'a aucun consommateur, mais **le brancher naïvement est une régression de confidentialité**. `keylogger.lua:90-98` documente pourquoi : l'adaptateur AT-SPI matche le `WM_CLASS` **exactement** sur une liste plus courte, donc déléguer **réduirait** la couverture en perdant `gpg`, `ssh-agent`, `polkit`, `sudo` et toutes les variantes par sous-chaîne — et un garde de test verrouille « la couverture ne doit jamais se réduire ». La correction est **additive** : garder la liste de sous-chaînes, y ajouter le signal de l'adaptateur, plus l'interrupteur d'arrêt manquant et les deux filtres absents. | `linux/ergopti_hotstrings.lua:338-339` ; `linux/modules/keylogger/keylogger.lua:90-102` | blocage |
| **B5** | **Le texte tapé transite par un fichier `/tmp` lisible par tous à chaque flush (Linux).** `_exec()` écrit tout le SQL — chaque valeur `text` et `events_json` — dans `os.tmpname() .. ".sql"` en 0644 moins umask, le passe à `sqlite3`, puis le supprime. Un crash entre les deux laisse le fichier. Le nom étant dérivé de `tmpnam(3)` puis **muté**, ce n'est pas le fichier réservé : cible classique de symlink/TOCTOU. | `linux/modules/keylogger/sqlite_writer.lua:96-112,127-139` | blocage |
| **B6** | **L'option « Chiffrement » du menu macOS est un no-op complet**, et la documentation de sécurité dit à l'utilisateur de l'activer pour la confidentialité au repos. Le backend est dix stubs vides ; le scan cherche des `*.log.gz` que le keylogger ne produit plus ; le bouton « ouvrir l'encrypteur » pointe vers un chemin où l'app n'est pas.<br><br>Le **mécanisme exact**, par lecture : la garde `type(log_manager.process_files_async) == "function"` est **toujours vraie** (le stub existe), le stub appelle `pcall(on_done, false)`, et le `on_complete` du menu fait alors un `string.format` d'une clé i18n à deux `%d` avec les arguments `false, nil` — ce qui lève, se fait avaler par le `pcall` du stub, et laisse donc le canevas de progression **jamais supprimé** et **aucune boîte de dialogue**. Le flux entier est du comportement mort déguisé en vivant. | `macos/modules/keylogger/log_manager.lua:1273-1294` ; `macos/ui/menu/menu_metrics.lua:114-131,498-587` ; `docs/security/keylogger_privacy.md:93` | blocage |
| **B7** | **`resolve_disabled_when` échoue *ouvert* sur AHK et *fermé* sur macOS.** macOS retourne `true` + `Logger.error` sur item introuvable, avec un test de régression dont la docstring nomme le risque (« un toggle keylogger-désactivé rendu comme toujours activé ») ; le frère AHK retourne `false` sans log. Barrière de sécurité sur le menu Métriques Windows. | `windows/lib/manifest_menu.ahk:361-364` vs `macos/lib/manifest_menu.lua:355-363` | majeur |
| **B8** | **Le chemin des packs d'extensions est faux sur Windows et macOS.** `static/extensions/` n'existe plus (déplacé en `static/ergopti_plus/extensions/` au commit `3a9a06a2b`) ; 6 consommateurs n'ont pas suivi, et l'échec est silencieux partout (`*i` supprime l'erreur d'include AHK, `DirExist` renvoie faux, le script de bundle avertit et continue). Le sous-menu extensions ne s'affiche jamais, et l'arbre est absent du bundle compilé comme de `Ergopti.app`. | `windows/ErgoptiPlus.ahk:357` ; `windows/ui/menu/menu_shortcuts.ahk:58` ; `macos/init.lua:606` ; `macos/ui/menu/hotstring_counter.lua:223` ; `macos/ui/menu/menu_shortcuts.lua:542` ; `tools/build/build_static_bundle.py:69,71,125-127` | majeur |
| **B9** | **`llm_context_length` n'a aucun effet sur le chemin automatique Windows.** Le correctif Lua (`cap_context` acceptant `context_window_chars`) n'a jamais été porté dans le générateur AHK ; `grep -c context_window windows/**/*.ahk` = 0. Aucun des 12 vecteurs du corpus ne fixe le paramètre, donc le corpus ne peut pas l'attraper. | `_shared/lua/llm/prompt_builder.lua:147` vs `windows/_generated/prompt_builder.ahk:168,209` | majeur |
| **B10** | **Défauts opposés du filtre de champ sécurisé LLM.** macOS bloque les prédictions dans les champs mot de passe par défaut (valeur `true` **codée en dur**, contredisant `defaults.json`, et les deux clés sont absentes de `_SHARED_SCALAR_KEYS` donc la valeur partagée est inatteignable) ; Windows envoie le contexte au fournisseur. Linux n'a aucun filtrage. | `macos/modules/llm/prediction_engine.lua:161-162` ; `macos/modules/llm/init.lua:38-45` ; `windows/modules/llm/prediction_engine.ahk:51` ; `_shared/modules/llm/defaults.json:21-22` | majeur |
| **B11** | **Le LLM Windows journalise le texte tapé de l'utilisateur en INFO, à chaque prédiction** (`preview := SubStr(tail, -40)`). macOS ne journalise que la longueur. Le log quotidien accumule donc un échantillon glissant de 40 caractères de tout ce qui est tapé quand le LLM est actif ; la politique de confidentialité du keylogger ne couvre pas ce puits. | `windows/modules/llm/prediction_exec.ahk:170-171` vs `macos/modules/llm/api_remote.lua:685` | majeur |
| **B12** | **Le langage de sortie des modèles de raisonnement n'est pas nettoyé sur Linux** : le driver ne charge jamais le parseur, `linux_bridge.parse_response` retourne `data.message.content` verbatim, donc un bloc `<think>…</think>` est **tapé dans le document de l'utilisateur**. | `_shared/lua/llm/linux_bridge.lua:304-315` ; absence mesurée de `strip_thinking` dans `linux/modules/llm/` | majeur |

Deux bugs de chemin de moindre gravité, à traiter dans le lot 7 comme classe : la liste de
langues Linux n'offre **2 locales sur 21** (`driver_root .. "/../../_shared/data/locales"`
est un cran trop haut, le scan ne trouve rien et le repli est `{ "en", "fr" }`), et le
chargement du schéma SQLite du keylogger Linux est **dépendant du répertoire courant** (deux
crans trop haut ; seul le repli relatif au CWD peut fonctionner).

---

## 8. Ledger de duplication mesuré

Trié par (lignes supprimables × faible risque). « Comment » indique le mécanisme, y compris
la façon dont l'AHK obtient la logique partagée.

| Duplication | Copies | Lignes | Partageable | Mécanisme |
|---|---|---:|---|---|
Consommateurs de corpus de tests | 3 | 9 122 | oui | schéma de rejeu + runner générique |
Code de menu autour du manifeste | 3 | 28 902 | à ~90 % | manifeste v3 + 1 renderer (macOS et Linux en partagent un) |
Adaptateurs sans appelant | 19 fichiers | 3 101 | suppression | barrière de reachability puis suppression |
Logger 8-variantes | 3 (dont 1 partagé inutilisé) | 2 503 | oui | macOS consomme le cœur partagé ; AHK garde le sien, scalaires générés |
Parseurs TOML `[[array]]` du logger | 2 | 262 | oui | générer les tables depuis `sub_files.toml` |
Marcheur d'agrégation métriques | 2 | 2 703 | partiellement | constantes générées + comportement épinglé par corpus |
Vecteurs de contrat de ports transcrits à la main | 2 | 2 001 | oui | générer les vecteurs depuis `contractTestVectors()` |
Invariants de convention en 2-3 langages | 17 fichiers | 1 594 | oui | une barrière JS par invariant, 3 arbres |
Tooltip (2 implémentations + 1 oracle mort) | 3 | 6 148 | partiellement | oracle câblé, constantes réellement lues |
Templates tap-hold Windows | 4 identiques + 10 | ~550 | oui | enregistrement piloté par la donnée (le driver le fait déjà pour la disposition) |
Constantes du prompt-builder | 5 + 3 listes en commentaire | ~60 | oui | un JSON, lu par Lua/JS, émis vers AHK |
Table de correspondance des réglages LLM | 4 (dont 2 AHK déjà divergentes) | ~490 | oui | générer depuis `llm_settings.json` ; supprime le contrat + 2 validateurs |
Géométrie des gestes (deux drivers Lua) | 2 | ~46 (32 identiques à l'octet) | oui | `_shared/lua/gestures/geometry.lua` |
Table des 21 locales | 3 (16 entrées sur Linux) | 63 | oui | générer depuis `locale_order.json` + `locale_names.json` |
Formule WPM | 7 littéraux `5` | 7 | oui | `_shared/lua/keylogger/metrics.lua` existe déjà |
Bibliothèque d'assertions Lua | 2 | 352 | oui | 62 lignes de différence, toutes cosmétiques |
Script d'installation Ollama | 2 (1 ligne d'écart) | 164 | oui | pointer vers la copie partagée |
Constantes du spotlight | 2 | 9 valeurs (1 déjà dérivée) | oui | `_shared/modules/spotlight/constants.toml` |
Wrappers pass-through | 101 | ~101 | oui | supprimer les 3 niveaux de transfert pur |
Échappeur JS pour webview (Windows) | 12 | ~108 | oui | un helper ; **3 des 12 suppriment les `\r` au lieu de les échapper** |
Clés de locale doublonnées `shortcuts.label_*` | 13 paires × 21 locales | 273 chaînes | oui | un seul namespace `actions.*` |

---

## 9. Asymétries légitimes — ne pas « corriger »

Ces différences sont irréductibles ou déjà arbitrées. Elles doivent être **nommées une
seule fois** — proposition : `_shared/remap/SPEC.md` pour celles du remap, et le registre
existant de `docs/PROJECT_MEMORY.md` pour les autres — et jamais re-litigées.

| Asymétrie | Niveau | Pourquoi elle ne peut pas disparaître |
|---|---|---|
Reconnaissance de gestes : frames brutes (macOS) vs pré-classification par le pilote (Windows) vs libinput (Linux) | pilote/OS | Windows n'expose aucune API tactile par doigt en userland ; le pilote Precision Touchpad n'émet que le raccourci configuré |
Windows a exactement **10** slots de gestes | pilote OS | le registre n'en supporte pas plus : ni diagonales, ni 2/5 doigts, ni axe continu |
La disposition de base macOS est une **ressource OS installée** (`.bundle` + TIS), pas du code driver | OS | pas de chemin d'installation équivalent sur Windows sans outil tiers |
macOS ne voit jamais les keycodes pré-Karabiner ; Windows/Linux ne voient jamais les post-remap | noyau vs userland | Karabiner est sous l'eventtap ; AHK et kanata sont en userland |
`cmd` ↔ `ctrl`, `option` ↔ `alt`, `fn` n'existe que sur les claviers Apple | OS | l'exemple même du mainteneur ; résolu par les jetons logiques, pas supprimé |
Linux tourne en mode observe et ne consomme jamais le terminateur | noyau | corriger exige `EVIOCGRAB` + ré-émission sans perte, validé sur matériel |
La matrice N×N de combos de modificateurs macOS n'a pas d'analogue AHK/kanata | extension noyau | matchers `simultaneous` de Karabiner ; ni AHK ni kanata n'expriment la matrice |
`adapters/` n'est pas « exactement les 20 ports » : c'est la couche d'isolation OS | convention | déplacer `shell_runner`/`toml_cache`/`json_codec` hors de `adapters/` ferait exploser les cliquets de pureté |
Le pipeline métriques AHK ne persiste pas les agrégats (anti-gonflement, ~140 Mo/jour) | conception | passer en pur-walker réintroduit le gonflement ; une colonne écrite des deux côtés = double comptage |
Les trois prédicats de frontière de mot divergent sur des caractères précédents exotiques | conception | ils s'accordent sur toute entrée française normale ; « mieux » est ambigu |
Le gating par catégorie (`CategoryEnabled[…]`) est AHK-only | conception | macOS n'a aucune couche de gating à refléter |
`KLW_VK_FINGER` est une 3ᵉ carte de doigts laissée exprès | donnée | `azerty.json` n'a pas de champ VK ; dériver à la main risque de corrompre les stats |
Les shims `lib.text_utils` et `lib/toml/*` de macOS sont porteurs | test | ~30 modules les `require` et ~12 tests stubent `package.loaded["lib.text_utils"]` |
Alphas de bordure de tooltip différents par driver | conception | déjà arbitré |
Le `.tsv` de locale Windows est un cache gitignoré auto-réparateur | perf | règle dure : aucune duplication versionnée. **Ne pas re-proposer un `.tsv` généré et versionné** |
Les emojis drapeau ne s'affichent pas dans les menus Windows | OS | d'où `[DE] Deutsch` au lieu de `🇩🇪 Deutsch` |
Le keylogger Linux **n'utilise pas** `adapters/secure_field_detector.lua` | conception | délibéré et documenté : l'adaptateur matche exactement sur une liste plus courte ; déléguer **réduirait** la couverture (perte de `gpg`/`ssh-agent`/`polkit`/`sudo`). Garde de test « la couverture ne doit jamais se réduire ». **La correction de B4 doit être additive** |
`windows/modules/llm/ollama_webview.ahk` (532 l) est orphelin **et n'est pas un écart de parité** | conception | Windows délègue l'installation à `winget`, qui fournit sa propre UI de progression ; macOS n'a pas d'équivalent et garde sa fenêtre. Le module est un résidu — mais il est épinglé par 4 méta-tests qui documentent le fonctionnement de la garde d'époque WebView2. **Décision, pas nettoyage** |

---

## 10. Déjà rejeté — ne pas re-proposer

Extrait du registre de `docs/PROJECT_MEMORY.md`, avec le motif. Toute proposition future
touchant ces sujets doit d'abord expliquer ce qui a changé.

| Idée | Motif du rejet |
|---|---|
Réutiliser la fenêtre de tooltip au lieu de la détruire/recréer | 3 blocages : AHK v2 ne peut pas retirer un contrôle d'une `Gui` ; les tests tooltip sont contractuels et n'exercent aucun cycle de vie de fenêtre réel ; piège d'ordre-Z sur la bordure. Gain ~2-4 ms |
Découper l'enregistrement différé des emojis en tranches via `SetTimer(self,-1)` | **Tenté et reverté** (`e7072a7c8`). +7 969 ms mesurés au démarrage à froid, ~12× le bloc monolithique. La prémisse était fausse : les threads AHK sont interruptibles |
Dé-contentionner le démarrage à froid de WebView2 par des ruses de timing | Corrigé à la racine : le widget WPM est passé de WebView2 à GDI+, supprimant le démarrage à froid au lieu de le planifier |
Rendre le pipeline métriques AHK « pur walker » comme macOS | Réintroduit ~140 Mo/jour de gonflement ; cause racine n°1 du bug #17 |
Aligner le prédicat de frontière de mot AHK sur la liste macOS | Divergence délibérée, impact faible, « mieux » ambigu |
Migrer les ids `CategoryEnabled` PascalCase vers snake_case | Re-examiné et confirmé KEEP : macOS n'a aucune couche à refléter ; ~27 sites de churn cosmétique |
Supprimer les shims `lib.text_utils` / `lib/toml/*` de macOS | La suite de tests est indexée sur le chemin `lib.*` ; dé-shimer contourne silencieusement chaque stub |
Dériver `KLW_VK_FINGER` de `azerty.json` | Pas de champ VK dans le JSON ; risque de corruption silencieuse des stats WPM/SFB |
Générer et versionner le `.tsv` de locale (ou de hotstrings) | C'était la conception précédente, retirée. Règle dure : aucune duplication versionnée |
Porter le replay de terminateur macOS sur Linux | Linux est en mode observe et ne consomme jamais le terminateur : le rejouer le **doublerait** |
Porter le correctif de bascule de date du logger AHK vers macOS | Réfuté : macOS repointe déjà les deux fichiers, avec test |
Restaurer les helpers de miroir v1→v2 / ajouter des shims de compatibilité | Supprimés au basculement ; la rétrocompatibilité est hors périmètre par décision |
Remplacer le littéral `0.5` du debounce de file-watcher par une constante nommée | Explicitement interdit : une barrière single-source épingle le littéral macOS à celui de Linux |
Balayer les timings de télémétrie du keylogger AHK vers le registre partagé | Délibérément non balayés : sous-modules AHK-only, absents de `run_all.ahk`, donc non vérifiables en CI |
Plafond par queue dans la boucle de correspondance de fin de mot (OPT-9b) | Refusé : 5 sites à synchroniser, un oubli = hotstring qui cesse silencieusement de déclencher ; gain sub-microseconde |
Aligner `macos/adapters/` sur exactement les 20 ports | Rejeté par le cliquet de pureté `hs.*` : déplacer ces helpers ferait grimper les compteurs hors `adapters/` |

---

## 11. Barrières CI : à créer, étendre, retirer

### À créer

| Barrière | Invariant | Lot |
|---|---|---|
`test-driver-tree-parity.cjs` | I1 : ensembles de noms de dossiers identiques ; aucun nom d'OS hors `platform/`+`adapters/` ; `_shared/` sans segment de plateforme ; chaque app de `apps.manifest.json` a un hôte ou un stub STATUS | 3 |
`test-shared-root-resolvers.cjs` | chaque expression résolvant `_shared` **s'exécute** et trouve un vrai fichier ; cliquet descendant | 7 |
`test-menu-parity.cjs` | le manifeste rendu pour les 3 plateformes produit le même arbre de libellés ; bijection `action_id` ↔ handler | 5 |
« aucune ligne de menu hors du renderer » | cliquet sur les sites de création de ligne, calibré au comptage post-migration | 5 |
« toute clé tableau du manifeste a ≥ 1 lecteur » | empêche la 6ᵉ clé morte | 5 |
`test-logger-sink-installed.cjs` | chaque driver installe un sink et une ligne atteint un vrai fichier | 1/7 |
`test-logger-scalars-single-source.cjs` | anneau, dédup, rétention, flush | 7 |
`test-locale-catalogue-complete.cjs` | chaque code de `locale_order.json` a un nom natif dans les 3 tables | 7 |
`_shared/tests/corpus/logger/behaviour_vectors.json` | filtrage par sévérité, ordre de l'anneau, flush forcé, dédup, bascule de date | 7 |
`_shared/tests/conformance/manifest.json` + runner | les skips deviennent de la donnée vérifiée | 9 |
`test-boot-manifest-parity.cjs` et frères | tout `id` résout ; aucune arête `requires` vers une phase ultérieure | 8 |
« aucun doublon écrit à la main d'une logique partagée » | détecte un test définissant une fonction homonyme d'un symbole de production qu'il ne `require` pas | 9 |

### À étendre

| Barrière | Trou mesuré |
|---|---|
`test-git-mv-resilience.cjs` | macOS uniquement ; doit couvrir les épinglages de répertoire AHK et de fichier Linux |
`test-no-pinned-source-reads*.cjs` | le `HELPER_RE` certifie « résistant au déplacement » 139 fichiers qui sont en fait épinglés par répertoire |
Cliquet de pureté AHK | 3 familles sur ~12 ; ignore `ui/` et le point d'entrée ; 874 lignes non surveillées |
Cliquet de pureté macOS | ignore `macos/ui/` (636 lignes `hs.*`) et `init.lua` (45) |
`test-webview-geometry-single-source.cjs` | zéro couverture Linux ; 3 apps Windows absentes |
`test-webview-teardown-order.cjs` | 7 hôtes sur 12 ; épingle des espaces internes exacts |
`test_jsstr_cr_escaped.ahk` | nomme 2 helpers sur 12 ; 3 frères ont encore le bug |
`test-config-schema.cjs` | 2 gabarits sur 3 ; celui de macOS n'a aucun lecteur |
`test-updater-constants-single-source.cjs` | exclut Linux (798 lignes de 3ᵉ implémentation) |
`test-menu-labels-single-source.cjs` | aveugle à Linux ; doit devenir un cliquet d'exclusion (il signalerait immédiatement la copie AHK) |
`test-priority-parity.cjs` | scan de texte sur 3 déclarations ; ne voit ni Linux, ni le repli du site de comparaison, ni la chaîne de départage |
`gen-architecture-diagram.cjs` | **0 occurrence de « linux »** dans un document titré « architecture à trois couches » |
`test-ahk-test-coverage.cjs` | `readdirSync` profondeur 1 ; ignore `run_*.ahk` et `bench_*.ahk` |
`test-dev-tool-paths.cjs` | limité à `tools/dev/` ; `tools/build/` porte 2 chemins absolus de la machine du mainteneur |
`verify-change.cjs` | une édition de corpus ne sélectionne que la barrière JS |

### À retirer, après migration seulement

`macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua` (après le lot 5.4) ·
`test_menu_top_level_drift_gate.{lua,ahk}` (une fois le tail piloté par le manifeste avec
ids validés — et **un jumeau Linux doit exister d'abord**) ·
`linux/tests/unit/meta/test_port_adapter_presence.lua` (liste de 9 noms en dur, 13 de
retard) · `windows/tests/{COVERAGE.md,macos/tests/COVERAGE.md}` (inventaires écrits à la
main, périmés — le principe correct est déjà énoncé dans `docs/TESTING.md` : l'inventaire
des contrôles, c'est l'exécution).

---

## 12. Risques du refactor

**R1 — Le déménagement d'arbre désarme 220 assertions en silence.** C'est le risque n°1 et
il est entièrement mitigé par le lot 2.1. `_DriverDirConcat("modules/keylogger")` est
épinglé par *répertoire* : renommer le dossier transforme 36 sites en succès vides tandis
que le cliquet annonce « aucune nouvelle lecture épinglée (20/20) ». Le jumeau macOS est sûr
par accident (`read_driver_source` retourne `nil`, et `nil:find(...)` lève). **Le défaut est
la conception du helper AHK, pas les tests.**

**R2 — Les stubs macOS cessent d'intercepter.** Le renommage de préfixe `lib.` → `infra.`
doit toucher la production **et** les ~1 942 sites `require`/`package.loaded` de l'arbre de
test dans le même commit.

**R3 — Le renommage du point d'entrée est le geste le plus dangereux du plan** et son gain
fonctionnel est nul. Sept familles de consommateurs l'épinglent (outils de synchronisation
AHK privés, scripts de build deb/rpm/PKGBUILD, le wrapper `bin/`, l'unité systemd, le
`main.swift` du launcher macOS, quatre barrières). **Recommandation : différer §5.5 dernière
ligne** si le mainteneur veut le plus petit changeset sûr ; la dé-plateformisation de
`_shared/` est en revanche peu coûteuse et doit partir quoi qu'il arrive.

**R4 — Les déplacements internes à `_shared/` ne sont pas couverts par la SSOT par couche.**
Plusieurs sites contournent le résolveur ; seules les suites de tests attrapent un
renommage. Tout déplacement dans `_shared/` doit s'accompagner d'un test qui affirme que le
résolveur a trouvé un **vrai fichier**, jamais seulement que le module s'est chargé.

**R5 — Ne pas affaiblir un cliquet pour permettre un déplacement.** Un bump de baseline dû à
une pure relocalisation doit porter la mention explicite « relocalisation, pas de nouveaux
appels OS » dans le commit.

**R6 — Le corpus de hotstrings rejetterait aujourd'hui une implémentation correcte** (le
contrat `backspace_count`). Corriger le contrat avant de générer le matcher.

**R7 — Une barrière génératrice de constats posée en milieu de refactor produit du bruit.**
La barrière « aucun doublon écrit à la main » va lever des dizaines de constats : la poser en
dernier.

**R8 — Les agents et les scripts lisent un arbre mouvant.** Les numéros de ligne de ce
document sont vrais au 2026-07-30. **Re-lire le site avant d'appliquer une édition, et
apparier par symbole, jamais par numéro de ligne.**

---

## 13. Décisions attendues du mainteneur

Chacune bloque ou redimensionne un lot. Aucune n'est déductible du code.

| # | Décision | Enjeu |
|---|---|---|
| D1 | **Migrer les silos `[ahk.*]` / `[hs.*]` ?** 206 fonctionnalités sur 335. Mécaniquement faisable, mais **rupture de schéma de configuration** : chaque clé de config concernée change de nom. La carte blanche dit oui ; je veux confirmation avant de commencer. | Lot 4 entier |
| D2 | **Linux entre-t-il dans le manifeste de fonctionnalités ?** Ajouter `linux` aux 116 déclarations `platforms` est peu coûteux ; câbler un `features_manifest.lua` + reader ne l'est pas. Le triage existant du mainteneur dit « pas d'heures supplémentaires sur Linux avant 2-3 vrais testeurs ». | Lots 4, 5.3 |
| D3 | **Stubs de la convention S sur Linux, ou parité d'arbre limitée à Windows ↔ macOS pour l'instant ?** Créer ~10 dossiers stub rend les arbres diff-égaux mais fait paraître Linux plus complet qu'il n'est. | Lot 3, barrière I1 |
| D4 | **`infra/` ou garder le nom `lib/` ?** Le renommage est ce qui force le re-triage des 39 fichiers plats Windows, mais coûte ~851 sites `require` de production + ~1 942 de test sur macOS. Alternative : garder `lib/` avec une barrière interdisant les sous-dossiers. | Lot 3b |
| D5 | **`modules/keylogger/` → `modules/metrics/` ?** Le mécanisme est un keylogger, la fonctionnalité est les métriques, et `_shared/ui/` utilise déjà « metrics ». Le renommage touche 36 sites `_DriverDirConcat` et une spec de 44 Ko. | Lot 3, 8.6 |
| D6 | **Le seuil tap-hold de 1000 ms sur macOS est-il délibéré ?** Il est 3 à 5 fois celui de Windows/kanata. Des seuils par touche sur macOS exigeraient de générer une variante de manipulateur Karabiner par touche : faisable, mais c'est un vrai changement. | Lot 8.7 |
| D7 | **`left_ctrl` tap = `paste` (Win/Linux) vs `cut` (macOS) est-il délibéré ?** Idem `left_alt` tap = `backspace` vs `delete_fwd`, et la couche nav sur `left_alt` vs `left_command`. Rien dans le code ni la mémoire projet n'en donne la raison. | Lot 8.7 |
| D8 | **Le même geste doit-il faire trois choses différentes ?** `swipe_3_left` = `tab_prev` (Win) / `word_prev` (macOS) / `ws_prev` (Linux, id absent du catalogue). | Lot 6.1 |
| D9 | **Quel défaut gagne pour le filtre de champ sécurisé du LLM ?** C'est une posture de sécurité, pas un refactor (B10). | Lot 1 |
| D10 | **Les 7 tables d'événements en écriture seule ont-elles un lecteur prévu ?** Elles coûtent ~2 582 lignes de producteur AHK, 7 tables et 7 index, et rien ne les lit. C'est une décision, pas un nettoyage. | Lot 10 |
| D11 | **Linux adopte-t-il le modèle `by_device/data.sql` ?** C'est ce qui rend atteignables ses tableaux de bord, la synchro multi-appareils et le marcheur partagé. Sinon Linux affichera définitivement un sous-ensemble des graphiques. | Lot 8.6 |
| D12 | **`docs/keylogger_spec.md` (44 Ko) est-elle encore normative ?** Elle précède Linux, décrit une organisation de fichiers AHK (§11) qui n'a aucun rapport avec les 27 fichiers livrés, et spécifie une couche `view_cache` que personne n'a construite. Soit elle devient l'ossature du document de documentation, soit elle passe par le protocole de retrait. | Lot 0/8 |
| D13 | **Retirer les fenêtres natives de repli Windows ?** ~3 400 lignes qui doublonnent une UI webview partagée. Les conserver coûte une double maintenance ; les retirer signifie « pas de fenêtre du tout » sous 1,5 Gio libres ou sans le Runtime WebView2. Recommandation : retirer celles dont l'hôte ne consulte même pas la garde mémoire (7 hôtes sur 12). | Lot 5/8.8 |
| D14 | **`--tray` par défaut sur Linux, ou toutes les unités systemd le passent ?** Le premier change le comportement d'un lancement à la main ; le second laisse le défaut piégé. | Lot 1, B2 |
| D15 | **`spotlight` reste-t-il Windows-only ?** 244 lignes, et le TODO note que l'espace des lanceurs est considéré perdu face à Raycast/Alfred. Si c'est mort, supprimer coûte moins cher que stuber sur deux drivers. | Lot 3 |

---

## 14. Annexe — corrections apportées à des artefacts existants

Cet audit a corrigé ses propres sources. À reporter dans les fichiers concernés.

**Chiffres du brief d'audit initial, faux.** J'avais annoncé `windows 31,7k / macos 62,4k /
linux 32,7k` lignes ; ces nombres venaient d'un `wc -l | tail -1` qui ne capturait que le
dernier lot d'`xargs`. Les valeurs mesurées correctement sont `82 867 / 78 622 / 16 733`
pour la production et `91 900 / 86 485 / 15 934` pour les tests.

**Items de planification devenus obsolètes** (à retirer de `TODO.md` /
`docs/PROJECT_MEMORY.md`) :

| Item | Réalité mesurée |
|---|---|
`TODO.md:98-100` « l'adaptateur `shell_runner` manque sur Linux » | Il existe depuis le 2026-07-29 (`2f1f309ef`), 185 lignes, atteignable depuis le point d'entrée |
`.claude/skills/linux-driver/SKILL.md:44-52` « Linux est le seul driver sans `shell_runner` … 137 shell-outs » | Le chiffre 137/36 était exact au commit parent ; il est aujourd'hui 101 (129 en motif large), et la tête de phrase est fausse |
« Câbler les 4 scripts de `tools/test/` que rien n'invoque » | Fait pour les 4 ; l'instance survivante de la classe est le couple CI-only `test:port-compliance` + `test:manifest-parity`, absent de `run-js-suite.cjs`. À quoi s'ajoutent deux **nouveaux** non câblés : `validate_menu_persistence_contract.py` et `validate_api_providers.py` |
`PROJECT_MEMORY` « `test_taphold_timings_load_order.ahk` épingle 1 chargeur sur 5 » | Son second test énumère désormais les cinq |
`linux/tests/unit/meta/test_logger_shim_only.lua:8` « il n'y a pas de répertoire `linux/lib/` » | Il en existe un, 6 fichiers. Et l'assertion principale du fichier affirme l'inverse de ce qui se produit (B1) |

**Constat d'agent réfuté par vérification.** Un des axes d'audit a rapporté que
`.husky/pre-commit:21` prescrit CRLF pour les `.ahk`, en contradiction avec la barrière
d'encodage. **Vérifié : `.husky/` n'existe pas et rien n'y est suivi par git.** Le constat
est faux ; le fait réel, plus intéressant, est qu'il n'y a **aucun hook git** dans ce
checkout alors que `package.json` déclare `"prepare": "husky install"` et que les
conventions du projet évoquent des comportements de pre-commit.

**Documents et barrières dont l'affirmation ne correspond pas au code** (échantillon vérifié
ligne par ligne ; liste complète dans les rapports d'axe) :

| Artefact | Affirmation | Réalité |
|---|---|---|
`windows/README.md:15-17` | `.ahk` en **CRLF** | La barrière impose **LF** |
`windows/README.md:29` | un dossier `data/` | Absent |
`windows/README.md:3-5`, `macos/README.md:3-5` | miroir répertoire-par-répertoire | Mesuré faux partout |
`linux/README.md:54-79` | 9 adaptateurs, pas de `lib/`, « pas de GUI native prévue » | 22 adaptateurs, 6 fichiers `lib/`, 2 379 lignes d'hébergement WebKitGTK |
`_shared/README.md:31-36` | l'AHK consomme une transpilation générée | Rien n'est transpilé ; deux générateurs cachent de l'AHK écrit à la main |
`_shared/modules/features/shortcuts.toml:5-7` | consommé par un codegen | Ce codegen a été supprimé le 2026-06-13 ; le fichier est lu par personne |
`macos/_generated/README.md:9` | `terminators.lua` généré ici, câblé | Le fichier n'existe pas ; le vrai est un shim de 32 lignes vers le catalogue partagé |
`_shared/modules/logger/README.md:5` | conformité vérifiée par `Logger.spec.js` | Ce fichier n'existe pas |
`_shared/modules/logger/SPEC.md:279` | l'AHK n'a pas de déduplication | Il en a une, plus deux tests de régression |
`tools/codegen/codegen-prompt-builder-ahk.cjs:11-13` | « aucune divergence n'est possible » | Le script ne lit jamais sa source ; la divergence a déjà eu lieu (B9) |
`test-features-manifest-no-drift.cjs:19-22` | « ne laisse jamais l'arbre sale » | Faux pour 3 des 5 fichiers écrits |
`tools/test/test-tooltip-corpus-parity.cjs` (nom de la barrière) | compare le corpus aux vecteurs JS | Ne `require` ni l'un ni l'autre des modules JS |
`macos/tests/unit/ui/test_tooltip_layout_corpus.lua:12-14` | épingle le renderer contre les vecteurs | Rejoue un clone interne au test ; le renderer n'est jamais chargé |
`macos/tests/unit/llm/test_llm_parser_vectors.lua:9-16` | toute divergence d'avec le module = échec | Aucun `require` du module ; 593 lignes testent une copie |
`_shared/core/domain/GestureRecognizer.spec.js` | « le driver HS DOIT utiliser ces valeurs exactes » | Exécuté par rien, et déjà divergent sur 4 points (noms de slots, nombre de slots, méthodes de contrat) |
`_shared/core/config_schema/tap_hold.schema.json` | valide `_shared/tap_hold/defaults.toml` | Exécuté par rien, et **rejetterait son propre sujet** (`additionalProperties: false`) |
`ADR-002:40` | émet un `_generated/tap_hold_template.toml` par driver | Cette chaîne n'apparaît nulle part ailleurs ; le fichier n'a jamais existé |
`ADR-005:15` | le moteur AHK est `hotstring_engine.ahk`, qui gère la détection | Ce fichier fait 172 lignes de sondage AltGr-Kana + 2 `#Include` ; la détection est ailleurs |
`ADR-001` | « les modules de domaine ne dépendent que d'interfaces de ports » | `_shared/core/domain/` contient 6 specs + 2 vrais `.js` ; aucun driver n'exécute de JS ; les deux vrais fichiers atteignent les drivers par codegen |
`docs/architecture.md` | « architecture hexagonale à trois couches » | **0 occurrence de « linux »** pour 22 adaptateurs Linux |
`_shared/modules/tooltip/{README.md,SPEC.md}` | côté AHK dans `lib/tooltip.ahk` + `ui/tooltip_llm.ahk` | Ni l'un ni l'autre n'existe |
`_shared/modules/hotstrings/schema.md` | entrées `trigger`/`replacement`/`flags[]` | 0 occurrence de `flags` ou `replacement` dans les 2 994 entrées réelles ; les vrais champs (`output`, `is_word`, `is_case_sensitive_strict`…) n'y figurent pas |
`_shared/lua/hotstring_engine/init.lua:6-8` | « implémentation canonique partagée par tous les drivers Lua » | Consommée par Linux seul ; macOS a la sienne |
`_shared/lua/keylogger/aggregator_helpers.lua:1-8` | « partagé par macOS, Linux et tout futur driver » | Un seul `require` de production, côté macOS |
`_shared/lua/linux/tray_protocol.lua:145-147` | sonde 3 chemins d'icône | Aucun des trois n'existe ; la résolution retourne toujours `""` |
`tools/codegen/new-driver.js:36` | scaffolde un driver | `REPO_ROOT` résout vers `tools/` ; produit 0 adaptateur et un README annonçant « Ports to implement (0) » |
`tools/lint/lint-conventions.js:571` | lint des TOML du dépôt | Parcourt un répertoire supprimé au reorg : **0 des 22 TOML de `_shared`** n'est vérifié |
`_shared/core/config_schema/SCHEMA.md:146` | `audit-banner-alignment.js` tourne en pre-commit | Aucun alias npm, aucun hook, absent de la suite |
`static/ergopti_plus/docs/glossary.md:412,451,467-471` | « les **neuf** interfaces OS », « les **neuf** contrats de ports », « Les **neuf** ports sont : » | suivi d'une liste de **treize** noms, alors qu'il y en a **20** |
`static/ergopti_plus/docs/glossary.md:429-433,482-483` | les drivers sont sous `hammerspoon/` / `autohotkey/` | ces répertoires n'existent pas ; ce sont `macos/` et `windows/` |
`_shared/lua/hotstring_engine/init.lua` + `linux/modules/hotstrings/engine.lua:5-8` | « source de vérité unique de l'algorithme de correspondance pour tous les drivers Lua » | macOS ne le `require` jamais ; l'unique référence dans les deux drivers est ce shim Linux |
`macos/modules/keylogger/log_manager.lua:1267-1294` | « Legacy compatibility stubs — no-ops so loading the old UI does not crash » | 13 no-ops, dont **8 sans aucune référence** ; violation directe de la règle « pas de shim de compatibilité » |

**Deux angles morts de convention, mesurés :** **78 fichiers de production** sont indentés
majoritairement à l'**espace** alors que la convention impose la tabulation, dont **30
mélangent les deux** ; et le linter de bannières dérive son index d'un nombre de lignes de
règle **supposé** au lieu de le vérifier, ce qui laisse passer **68 bannières majeures** avec
un nombre de lignes non conforme tandis que `npm run lint:conventions` rapporte zéro
violation.

---

*Fin du plan. Les runbooks « comment faire X » et la description du fonctionnement actuel
sont dans [ERGOPTI_PLUS.md](ERGOPTI_PLUS.md).*
