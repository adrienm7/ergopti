# Prompt — « Génère le guide de refactor : lisible, SOLID, 100 % testable »

> **Quoi.** Prompt prêt à coller à un agent ayant accès en lecture au dépôt
> `ergopti`. Sa sortie n'est **pas** un refactor : c'est **un seul fichier
> markdown** (`docs/REFACTOR_GUIDE.md`) décrivant, étape par étape et preuves à
> l'appui, comment continuer à simplifier/standardiser les drivers
> `windows/` (AHK), `macos/` (Hammerspoon/Lua) et `linux/` pour qu'ils
> deviennent **évidents à comprendre, SOLID, sans duplication, et surtout
> entièrement testables avec un diagnostic d'échec immédiat**.
>
> **Langue.** Prose en français, **tout le technique en anglais** (chemins,
> identifiants, types, commandes) — exactement comme `docs/REFACTOR_PLAN.md`.
>
> **Comment l'utiliser.** Coller tout ce qui suit la ligne `---` à l'agent.
> Lui donner accès au dépôt. Récupérer `docs/REFACTOR_GUIDE.md`.

---

## 0. Rôle & mission

Tu es un **staff engineer** spécialiste de l'architecture logicielle, de la
testabilité et de la lisibilité du code. Tu interviens sur **ErgoptiPlus**, une
suite multi-plateforme qui réimplémente le même comportement clavier sur trois
runtimes : `windows/` (AutoHotkey v2), `macos/` (Hammerspoon/Lua) et
`linux/` (LuaJIT), avec un cœur partagé `_shared/` (domaine en JS, ports/contrats,
manifeste de features, data, libs Lua, UI web).

**Ta mission unique :** produire **`docs/REFACTOR_GUIDE.md`**, un plan de refactor
**incrémental, priorisé et adossé à des preuves**, qui amène le code à cet état
cible mesurable :

1. **Onboarding.** Un dev qui n'a jamais vu le repo comprend **un driver de bout
   en bout en < 1 journée**, et sait dire « telle feature vit ici, son défaut vient
   de là, son test est celui-là » **sans demander à personne**.
2. **Diagnostic d'échec immédiat (priorité absolue).** Quand un test casse, le dev
   sait en **< 5 minutes** _quel comportement_ a régressé, _où_ est le code fautif,
   et _comment_ le corriger — **uniquement** en lisant le nom + le message d'échec du
   test. **Aujourd'hui ce n'est pas le cas** : c'est le problème n°1 à résoudre.
3. **Zéro duplication.** Aucune logique ni valeur par défaut dupliquée entre
   drivers ; les défauts vivent dans `_shared/` sauf si réellement spécifiques au
   pilote (et alors c'est justifié explicitement).
4. **SOLID & petits fichiers.** Responsabilités uniques, dépendances par
   abstraction (les ports existants), aucun fichier-fourre-tout.
5. **Symétrie.** `windows/` et `macos/` sont des miroirs structurels : l'analogue
   d'un fichier se trouve au **même chemin** dans l'autre driver.

**Tu ne modifies pas le code de production.** Tu écris un guide. Le seul fichier
que tu crées est `docs/REFACTOR_GUIDE.md`.

---

## 1. Contexte vérifié du dépôt (point de départ — à **re-vérifier**, pas à croire)

Voici l'état connu au moment d'écrire ce prompt. **Traite-le comme une hypothèse :
re-lance les commandes, confirme les chiffres, et cite `path:line` pour chaque
affirmation de ton guide.** Si un fait a changé, corrige-le dans ton rendu.

**Topologie.** Le code driver est sous `static/ergopti_plus/` :
`_shared/`, `windows/`, `macos/`, `linux/`. Le repo racine est un projet SvelteKit ;
la toolchain de test/codegen est en Node sous `tools/`.

**Architecture déjà en place (à respecter, pas à réinventer) :**

- **Hexagonale** (ADR `static/ergopti_plus/docs/adr/001-hexagonal-architecture.md`).
  Le **domaine** est en JS testé : `_shared/core/domain/*.js` + `*.spec.js`
  (`Expander`, `HotstringMatcher`, `Registry`, `GestureRecognizer`, `Terminators`,
  `ProfileSelector`, `PromptBuilder`). Les **ports** sont des contrats :
  `_shared/core/ports/*.spec.js` + `contracts.json` (≈ 20 ports).
- **Manifeste = source unique** (ADR `002-codegen-manifest.md`,
  `003-single-toml-schema.md`). `_shared/modules/features/manifest.toml` déclare
  **chaque feature toggle et son `default`** (et `default_per_platform` quand les
  drivers divergent légitimement). Du codegen (`tools/codegen/*`, `tools/build/*`)
  régénère les fichiers `_generated/` ; un **drift gate** (`npm run build:domain`)
  échoue si le généré n'est pas resync. **Ne jamais éditer `_generated/` à la main.**
- **4 couches de test** (`docs/TESTING.md`) : `npm run test:js` (domaine + codegen +
  drift), `npm run test:hs` (Lua/macOS sur stubs), `npm run test:linux`, et la suite
  AHK headless `windows/tests/run_all.ahk` via `AutoHotkey64.exe /ErrorStdOut`.
- **Un plan de refactor existe déjà** : `docs/REFACTOR_PLAN.md` (phases P0→P7,
  certaines faites, beaucoup REPORTÉES avec la raison). **Ton guide le prolonge et le
  raffine — il ne le contredit pas.** Lis-le en entier d'abord, et réutilise sa
  « Structure cible (miroir 1:1) » et son « Harnais de vérification ».
- **Mémoire projet** : `docs/PROJECT_MEMORY.md` encode les foot-guns et les décisions
  arrêtées. **Lis-la** : plusieurs « refactors évidents » y sont déjà prouvés
  _non faisables_ (ex. déplacer les helpers OS hors de `adapters/` casse le ratchet
  de pureté ; `adapters/` = couche d'isolation OS, pas « exactement 20 ports »).
  Ne re-propose pas ce qui y est déjà rejeté.

**Les 3 douleurs réelles à instrumenter (confirme les chiffres) :**

| Douleur                                  | Signal mesuré (à reconfirmer)                                                                                                                                                                                                                                              | Pourquoi ça fait mal                                                                                                                                                                                 |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tests fragiles, illisibles à l'échec** | ~**206 / 411** fichiers `test_*.ahk` scannent le _source_ (`_DriverSourceConcat`, `_DriverFuncBody`, `_DriverDirConcat`, `FileRead … .ahk`) pour asserter _où vit une fonction_                                                                                            | un refactor casse des dizaines de tests « introspection » ; à rouge ils disent « fonction X absente du fichier Y », **jamais** « le comportement Z est cassé » → diagnostic lent, refactor découragé |
| **Defaults éparpillés**                  | `manifest.toml` couvre les _toggles_, mais des défauts non-toggle traînent : `windows/infra/llm_defaults.ahk`, `windows/infra/hotstrings/hotstrings_config.ahk`, `windows/platform/remap/*`, et côté HS les tables `DEFAULT_STATE` dans `macos/modules/*/init.lua`               | même valeur définie en 2+ endroits → divergence silencieuse driver vs driver                                                                                                                         |
| **Gros fichiers fourre-tout**            | côté AHK : `modules/gestures.ahk` (~2076 l.), `modules/keylogger/keylogger.ahk` (~1867) ; côté HS : `modules/llm/api_mlx.lua` (~1799), `ui/menu/menu_llm/models_manager_mlx.lua` (~1790), `ui/menu/menu_keyboard_layout.lua` (~1647), `modules/keylogger/init.lua` (~1583) | un fichier = trop de responsabilités → illisible, intestable unité par unité                                                                                                                         |

---

## 2. Contraintes absolues (non négociables — tout item du guide les respecte)

1. **Comportement préservé.** Chaque étape proposée est un **pur refactor** : aucun
   changement de comportement observable. Si une étape changerait le comportement,
   marque-la `feat`/`fix` séparément et exige une preuve d'équivalence avant/après.
2. **Conventions maison** (`.github/copilot-instructions.md`, `CLAUDE.md`) :
   bannières de section (5 lignes vides / `=` alignés), **tabs**, ligne 1 = chemin
   relatif, docstrings finissant par `.`, **code anglais / UI française**, i18n
   obligatoire pour tout texte utilisateur (21 langues), logger 8-variants avec
   paires lifecycle, **fail-fast** via `require_state`, **pas de magic numbers**,
   **SSoT des défauts**, pas de code mort / shim de compat.
3. **Discipline de test de régression (§5.9).** _Chaque_ étape qui corrige ou
   déplace quelque chose **embarque son test** dans le même commit, encodant la
   _cause racine_, rouge avant / vert après. Le guide doit nommer ce test pour
   chaque étape.
4. **Foot-gun encodage AHK.** Fichiers `.ahk` = **UTF-8 BOM + LF**. Éditer via
   l'outil Edit, **jamais `cat >>`** (abort silencieux mi-fichier). Tests AHK
   **ASCII-only**, glyphes non-ASCII via `Chr(0xNNNN)`. Lancer `npm run test:ahk-encoding`
   après tout `.ahk` touché. Préserver l'**ordre des `#Include` / `#InputLevel`** et
   les `global X := …` top-level (porteurs d'invariants de boot).
5. **Décisions déjà arrêtées : ne pas les rouvrir.** Manifeste = SSoT ;
   `adapters/` = isolation OS ; ports/contrats ; ADRs 001-007. Si tu veux dévier,
   exige un nouvel ADR explicite et justifie.
6. **Incrémental & vérifiable.** Chaque étape est livrable **seule**, derrière le
   harnais de vérif (dry-run AHK exit 0 + suite verte + encoding + drift gate), avec
   un **rollback** trivial. Pas de big-bang.
7. **Jamais affaiblir un test pour faire passer un changement.** On renforce le
   filet, on ne le coupe pas.
8. **Pas de crédit LLM/outil** dans les commits suggérés ; pas de `Co-Authored-By`.

---

## 3. Investigation à mener (des preuves, pas des opinions)

Avant d'écrire le guide, **mène l'enquête et chiffre**. Pour chaque axe, commande
exacte + résultat → tableau dans le rendu. N'écris **aucune** recommandation qui ne
s'appuie pas sur un `path:line` ou un chiffre reproductible.

- **Duplication de logique & de défauts.** Inventorie toute valeur par défaut hors
  `manifest.toml` (grep `default`, `DEFAULT_STATE`, `:= ` de constantes, tables de
  config) dans `windows/` et `macos/`. Pour chacune : _quelle valeur, où (combien de
  sites), devrait-elle vivre dans `_shared/` ou est-elle légitimement driver-specific ?_
- **Asymétrie hs ↔ ahk.** Construis la **table de correspondance** `windows/` ↔
  `macos/` (par feature/module/fenêtre UI). Marque chaque divergence de
  chemin/découpage/nommage et dis dans quel sens converger.
- **Gros fichiers.** Liste tout fichier de prod > ~400 lignes (`.ahk`, `.lua`),
  avec ses responsabilités distinctes → proposition de découpage **miroir** sur les
  deux drivers.
- **Architecture de test (axe n°1).** Classe les tests en : _behavior/contract/
  integration/e2e_ vs _introspection_ (scan de source / assertion d'emplacement).
  Chiffre le ratio. Pour un échantillon de tests « introspection », montre le message
  d'échec réel et démontre qu'il **ne pointe pas** vers le comportement cassé.
- **Ergonomie d'échec.** Pour chaque couche, lance volontairement un test au rouge
  et capture ce que voit le dev. Est-ce qu'il a : le _comportement_ attendu vs obtenu,
  le `path:line` du code, et **la commande exacte pour rejouer ce seul test** ?
  (`tools/test/run-js-suite.cjs` le fait déjà côté JS — sers-t'en de référence.)
- **Couplage / SOLID.** Repère les violations concrètes : fonctions à
  responsabilités multiples, modules qui touchent l'OS hors `adapters/`, état global
  mutable partagé, `if driver == …` au lieu d'un port, défauts hardcodés en fallback.

---

## 4. Doctrine de qualité à appliquer (le barème du guide)

### 4.1 Testabilité & diagnostic d'échec — **PRIORITÉ N°1**

C'est le cœur de la commande. Le guide doit transformer la suite « verte mais
opaque » en suite **où un rouge se corrige en minutes**. Exige :

- **Une raison d'échouer par test.** Chaque test unitaire couvre **un**
  comportement et a **un** motif de rupture. Son **nom décrit le comportement**
  (`expands "tdej" -> "déjeuner" after a word boundary`), pas le fichier.
- **Messages d'échec actionnables.** Tout assert affiche **attendu vs obtenu** et
  un indice de localisation. Bannis les `assert(x)` nus. Un dev doit corriger sans
  ouvrir le test.
- **Découpler les tests de l'emplacement du code.** Les ~206 tests AHK
  « introspection » sont la cause directe de la douleur : propose de
  (a) **convertir** ceux qui valident un _comportement_ en tests behavior réels qui
  appellent la fonction et vérifient la sortie ; (b) pour les invariants
  _structurels_ qu'on veut vraiment garder (ex. « tout appel OS vit dans `adapters/` »,
  « tout site `Features[...]` résout contre le manifeste »), les **centraliser en
  un seul test méta déclaratif** générique, au lieu de N assertions file-pinned qui
  cassent à chaque déplacement. Objectif chiffré : **réduire drastiquement** le ratio
  introspection/behavior, et garantir qu'un _déplacement de fichier ne casse plus
  aucun test_.
- **Carte test → source.** Le guide impose une convention où, depuis un test rouge,
  le module de prod responsable est **évident** (miroir de chemins
  `tests/unit/modules/<feature>/…` ↔ `modules/<feature>/…`, nommage 1:1). Documente-la.
- **Contrats dérivés de la SSoT.** Chaque **default** et chaque **port** est couvert
  par un test généré/dérivé de `manifest.toml` / `contracts.json`, de sorte qu'un
  défaut qui diverge ou un port non implémenté **échoue au CI, pas au clavier**
  (généralise l'esprit de `test:feature-read-sites`).
- **Un point d'entrée, une commande, par couche** (déjà partiellement vrai) ; sortie
  lisible ; **la commande de reproduction d'un seul test** affichée à l'échec ;
  local == CI byte-pour-byte (cf. `docs/TESTING.md`).
- **Isolation & déterminisme.** Pas d'ordre inter-tests caché, pas d'horloge/réseau
  réels, fixtures explicites (rappel : un loader qui mutate un Map prend la cible en
  **paramètre**, jamais via `global`).
- **Le test précède/accompagne le refactor.** Pour toute étape de découpage, le
  guide indique le test behavior qui prouve l'équivalence avant/après (filet), pas
  seulement le dry-run.

### 4.2 Zéro duplication & **defaults dans `_shared/`**

- **Inventaire → décision** pour chaque défaut : _manifeste_ (toggle/valeur de
  feature), _defaults `_shared/` dédié_ (paramètres non-toggle partagés : timings
  hotstrings, params LLM, délais tap-hold…), ou _driver-specific assumé_ (justifié,
  ex. chemins OS, choix de modèle par plateforme via `default_per_platform`).
- **Un mécanisme unique** de consommation : les drivers **lisent** le défaut
  partagé (codegen ou lecture TOML), **ne le re-déclarent jamais**. Tout fallback
  hardcodé `if x == nil then x = …` est une violation (§5.4) → fail-fast.
- **Drift test** : la duplication redevient impossible parce qu'un test compare le
  défaut consommé à la SSoT et casse sinon.
- Étends `manifest.toml` (ou un `_shared/.../defaults.toml` cousin) **avec preuve
  d'équivalence byte** quand tu rapatries un défaut qui pourrait déjà diverger entre
  drivers (sinon c'est un `feat`, pas un refactor — cf. avertissement tap_hold de P7).

### 4.3 Découpage des gros fichiers (en gardant l'ordre de boot)

- **Seuil objectif** (ex. > ~400 l. ou > 1 responsabilité claire) → split en
  sous-fichiers à responsabilité unique, le fichier d'origine devenant un **index**
  (`init` / barrel) qui `#Include`/`require` ses parties **in-place** (préserve
  l'ordre top-level et les hotkeys `#InputLevel`).
- **Toujours en miroir** : si tu splittes `gestures` côté AHK, propose le même
  découpage côté HS, mêmes noms de parties.
- Chaque split : dry-run exit 0 + suite verte + encoding + tests d'introspection
  survivants migrés vers le helper générique (cf. 4.1).

### 4.4 Symétrie `windows/` ↔ `macos/` (↔ `linux/`)

- Chemin identique ⇒ analogue au même endroit. Produis la **table de mapping
  complète** et, pour chaque ligne divergente, l'action de convergence et le sens.
- Tranche (ou pose en « décision maintainer ») les divergences structurelles
  connues du plan : `lib/` foldérisé (Win) vs plat (macOS) ; emplacement
  `keymap`/`layout` ; placement du menu (manifest vs json). Ne décide pas seul une
  divergence à fort blast radius : **propose, chiffre le risque, demande l'arbitrage**.

### 4.5 SOLID, appliqué **concrètement à ce repo** (pas de récitation théorique)

Pour **chaque** principe, donne au moins un exemple réel du repo (`path:line`) +
l'action :

- **S** — un fichier/fonction = une responsabilité (cf. 4.3 ; les gros `init` mêlent
  découverte, cleanup, watchers…).
- **O** — ajouter une feature/un défaut = éditer le **manifeste** + regen, pas
  patcher N call-sites (le codegen est déjà ton point d'extension).
- **L** — toute implémentation d'un port respecte le **contrat** (`contracts.json`) ;
  les tests de contrat doivent être les mêmes pour chaque adapter.
- **I** — ports fins et ciblés (déjà ~20) ; pas de port obèse ; un module ne dépend
  que des ports qu'il utilise.
- **D** — les modules dépendent des **abstractions/ports**, jamais d'un appel OS en
  dur ni d'un `if driver == "ahk"`. Tout `hs.*` / `DllCall` / `io.*` vit dans
  `adapters/`.

### 4.6 Lisibilité & onboarding

- Chaque dossier de feature/fenêtre a un `README.md` court : _rôle, entrée, défaut
  (→ SSoT), test associé_. Ajoute `windows/README.md` + `macos/README.md` (carte du
  driver) et un schéma « une feature, son trajet manifest → codegen → adapter → test ».
- Nommage 1:1 cross-driver ; supprime les barrels/alias morts ; aucune abréviation
  obscure non documentée dans `docs/glossary.md`.

---

## 5. Structure EXACTE du livrable `docs/REFACTOR_GUIDE.md`

Génère **un seul** fichier markdown avec **exactement** ces sections, dans cet ordre :

1. **`# ErgoptiPlus — Guide de refactor (lisible · SOLID · 100 % testable)`**
2. **`## TL;DR`** — 8-12 puces : les chantiers majeurs, par impact décroissant, avec
   pour chacun le gain (« onboarding », « diagnostic d'échec », « zéro dup »…).
3. **`## État des lieux (mesuré)`** — les tableaux de l'investigation §3 (duplication,
   defaults épars, gros fichiers, ratio tests introspection/behavior, ergonomie
   d'échec), chiffrés, avec `path:line`. C'est la base factuelle ; tout le reste s'y
   réfère.
4. **`## Architecture cible`** — la structure miroir visée (réutilise/raffine le
   tableau de `REFACTOR_PLAN.md`) + le schéma « trajet d'une feature » + la **carte
   test → source**.
5. **`## Plan priorisé par phases`** — phases ordonnées **du moins au plus risqué**,
   alignées/numérotées en cohérence avec `REFACTOR_PLAN.md` (prolonge, ne renumérote
   pas à l'aveugle). Pour **chaque étape** :
   - **Objectif** (1 phrase) et **principe SOLID / douleur** adressé.
   - **Preuve** : `path:line` ou chiffre qui justifie l'étape.
   - **Action** précise (fichiers déplacés/splittés, défaut rapatrié, test converti).
   - **Test** : le test de régression/behavior qui passe au vert (nom + ce qu'il
     encode, cause racine).
   - **Vérification** : commandes exactes du harnais (dry-run / `test:js` / `test:hs`
     / encoding / drift) et critère de succès.
   - **Diagnostic d'échec** : _si ce test casse plus tard, le dev lit quoi et corrige
     où_ — la garantie « < 5 min ».
   - **Rollback** et **blast radius** (faible/moyen/élevé).
6. **`## Chantier testabilité (transversal, priorité 1)`** — la cible de §4.1
   détaillée : taxonomie de test, conversion des ~206 introspection-tests, test méta
   déclaratif unique pour les invariants structurels, contrats dérivés de la SSoT,
   convention de nommage des tests, gabarit de message d'échec actionnable, et la
   **métrique de réussite** (ratio cible, « un déplacement de fichier ne casse aucun
   test »).
7. **`## Defaults & SSoT`** — le tableau inventaire→décision (§4.2) + le mécanisme de
   consommation unique + le drift test qui rend la dup impossible.
8. **`## Décisions maintainer requises`** — les arbitrages à fort blast radius
   (divergences structurelles, codegen vs hand-port…), chacun avec options + reco +
   risque. Ne tranche pas seul ce qui est irréversible.
9. **`## Risques & foot-guns`** — repris/complétés depuis `PROJECT_MEMORY.md` et
   `REFACTOR_PLAN.md` (encodage AHK, ordre `#Include`/`#InputLevel`, ratchet de
   pureté, tap_hold possiblement déjà divergent, churn du généré…).
10. **`## Definition of Done`** — la checklist vérifiable de §6.

**Format de chaque étape : un tableau ou un bloc compact**, scannable. Pas de pavés.
Priorise : si tu dois couper, garde les étapes à fort gain / faible risque.

---

## 6. Definition of Done du **guide** (auto-vérifie avant de rendre)

- [ ] **Chaque** recommandation est adossée à un `path:line` ou un chiffre
      reproductible — zéro conseil générique.
- [ ] Chaque étape précise : objectif, action, **test associé** (cause racine),
      commande de vérif, **scénario de diagnostic d'échec**, rollback, blast radius.
- [ ] La **priorité n°1 (testabilité / diagnostic d'échec)** a sa section dédiée avec
      une métrique cible et un plan concret pour les ~206 introspection-tests.
- [ ] L'inventaire des **defaults** est exhaustif et chaque entrée a une décision
      (manifeste / `_shared` / driver-specific justifié) + un drift test.
- [ ] La **table de symétrie** `windows/`↔`macos/` est complète, divergences marquées
      avec sens de convergence.
- [ ] Tous les **gros fichiers** (> seuil) ont un plan de split miroir.
- [ ] Le guide **ne contredit pas** `REFACTOR_PLAN.md`, `PROJECT_MEMORY.md`, les ADRs ;
      il les prolonge et s'y réfère par lien.
- [ ] **Aucune étape ne change le comportement** (sinon explicitement marquée
      `feat`/`fix` avec preuve d'équivalence exigée).
- [ ] Les arbitrages irréversibles sont en **« Décisions maintainer »**, pas tranchés
      seul.
- [ ] Tout est **incrémental, vérifiable, réversible** ; ordre du moins au plus risqué.
- [ ] Le rendu respecte les conventions maison (prose FR, technique EN, liens
      cliquables `path:line`).

---

## 7. Anti-patterns à éviter (rejet immédiat du rendu)

- ❌ Du conseil générique (« appliquez SOLID », « ajoutez des tests ») sans
  `path:line` ni action concrète propre à ce repo.
- ❌ Re-proposer un refactor **déjà rejeté** dans `PROJECT_MEMORY.md` /
  `REFACTOR_PLAN.md` (ex. casser le ratchet de pureté `adapters/`).
- ❌ Un big-bang non découpé, ou des étapes qui changent le comportement déguisées en
  refactor.
- ❌ Affaiblir/supprimer un test pour « simplifier » — on renforce le filet.
- ❌ Ignorer les foot-guns AHK (encodage, ordre `#Include`/`#InputLevel`).
- ❌ Trancher seul une divergence structurelle à fort blast radius au lieu de la poser
  en décision maintainer.
- ❌ Éditer `_generated/` ou dupliquer un défaut « pour aller plus vite ».
- ❌ Des pavés non scannables au lieu de tableaux/étapes compactes.

**Avant de rendre**, relis la _Definition of Done_ (§6) et coche chaque case. Si une
case ne peut pas être cochée, **corrige le guide** plutôt que de rendre incomplet.
