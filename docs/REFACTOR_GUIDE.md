<!-- docs/REFACTOR_GUIDE.md -->

# Guide de refactor — lisible, SOLID, diagnostiquable

> Produit le 2026-08-04 en exécutant `docs/prompts/refactor.md`.
> Prolonge `docs/REFACTOR_PLAN.md`, ne le contredit pas.
> **Aucune recommandation ici n'est écrite sans un chiffre reproductible ou un
> `path:line`.**

---

## 0. Ce que la mesure a démenti, avant toute recommandation

Le prompt fournit trois douleurs chiffrées et demande explicitement de les
re-confirmer. **Deux sur trois ont changé de sens depuis leur mesure**, et
l'ignorer aurait produit un guide qui attaque des problèmes résolus tout en
manquant celui qui a doublé.

| Douleur                    | Chiffre du prompt   | Mesuré 2026-08-04             | Verdict                    |
| -------------------------- | ------------------- | ----------------------------- | -------------------------- |
| Tests fragiles (source)    | ~206 / 411 (50 %)   | **755 / 841 (90 %)**          | **nettement pire**         |
| Gros fichiers fourre-tout  | 6 fichiers nommés   | **5 sur 6 fondus ou disparus** | **largement résolu**       |
| Defaults éparpillés        | « 2+ endroits »     | 34 `DEFAULT_STATE` / 26 gates  | **encadré, pas résolu**    |

### 0.1 Les gros fichiers ont fondu

| Fichier nommé par le prompt                     | Alors   | Aujourd'hui | Δ         |
| ----------------------------------------------- | ------- | ----------- | --------- |
| `windows/modules/gestures.ahk`                  | ~2 076  | **absent**  | supprimé  |
| `macos/ui/menu/menu_llm/models_manager_mlx.lua` | ~1 790  | 346         | −1 444    |
| `macos/modules/llm/api_mlx.lua`                 | ~1 799  | 829         | −970      |
| `macos/ui/menu/menu_keyboard_layout.lua`        | ~1 647  | 721         | −926      |
| `windows/modules/keylogger/keylogger.ahk`       | ~1 867  | 1 494       | −373      |
| `macos/modules/keylogger/init.lua`              | ~1 583  | **1 674**   | **+91**   |

Cinq des six ont fondu ou disparu. **Un seul a grossi**, et c'est le seul qui
reste à traiter au titre de cette douleur.

### 0.2 La fragilité des tests a doublé

```sh
find static/ergopti_plus/windows/tests -name "test_*.ahk" | wc -l          # 841
grep -rl "_DriverFuncBody"        … --include="test_*.ahk" | wc -l         # 576
grep -rl "_DriverDirConcat"       … --include="test_*.ahk" | wc -l         # 147
grep -rl "_DriverSourceNoComments" … --include="test_*.ahk" | wc -l        #  68
grep -rl "_DriverSourceConcat"    … --include="test_*.ahk" | wc -l         #  60
# au moins un des quatre, ou FileRead                                      # 755
```

**Ces deux faits ne sont pas indépendants — c'est le cœur de ce guide.**

Les gros fichiers ont pu être découpés *parce que* quelqu'un a payé le prix de
recâbler les tests d'introspection à chaque fois. Et la proportion de tests
d'introspection a monté précisément parce que découper un fichier crée de
nouveaux tests « la fonction X vit bien dans le fichier Y » pour verrouiller le
découpage. **La solution d'hier est la dette d'aujourd'hui.**

---

## 1. Le problème n°1, formulé correctement

Le prompt le dit : « quand un test casse, le dev sait en < 5 min *quel
comportement* a régressé ». Avec 576 fichiers utilisant `_DriverFuncBody`, un
échec typique dit :

> `AltTabMonitor must wrap the per-window enumeration body in a try`

Ce message a été produit pour de vrai le 2026-08-03, en déplaçant l'énumération
dans un helper partagé. **Le comportement était intact.** Le test disait « la
fonction n'est plus là où je l'attends », pas « le comportement Z est cassé ».

Mais — et c'est ce qui empêche d'en faire une croisade — **ce test avait raison
d'exister**. Il garde une protection contre une course TOCTOU qui, sans lui,
serait retombée dans le trou. Le supprimer aurait rendu le refactor plus facile
et le driver plus fragile.

### La règle qui en sort

> **Un test d'introspection est légitime quand l'invariant qu'il garde n'est pas
> observable depuis le comportement. Il est de la dette quand il l'est.**

Deux exemples réels, du même jour, pour calibrer :

- **Légitime** — `_AltTabCycle` doit avoir un `catch` qui `continue`. Le
  comportement fautif (une fenêtre qui meurt en cours d'énumération) ne se
  reproduit pas dans un test unitaire : il faut une vraie course. La source est
  la seule surface disponible.
- **De la dette** — `try_auto_expand` doit contenir `M.would_fire` dans ses
  1 200 premiers caractères. C'est un test de *mise en page*. Il est tombé le
  2026-08-03 parce qu'un commentaire de 16 lignes avait repoussé l'appel hors de
  la fenêtre, alors que la délégation était intacte.

---

## 2. Étapes, par ordre de rendement

Chaque étape est livrable seule, derrière le harnais : suite verte,
`npm run test:ahk-encoding`, drift gate.

### Étape 1 — Classer les 755, ne pas les réécrire

**Ne commence pas par convertir des tests.** Commence par les compter par
catégorie, parce que la seule question qui compte est « combien sont de la
dette ? » et personne ne le sait aujourd'hui.

Livrable : un gate `test-introspection-tests-are-justified.cjs` qui exige de
chaque test d'introspection une **raison déclarée** parmi un ensemble fermé —
`race-condition`, `boot-order`, `encoding`, `layout` — et gèle le compte de la
catégorie `layout`, la seule qui soit de la dette pure.

Test de régression : le gate lui-même, prouvé rouge en retirant une raison.

**Pourquoi d'abord :** c'est la seule étape qui transforme « 755 tests fragiles »
en un chiffre sur lequel un ratchet peut mordre. Toutes les suivantes se mesurent
contre lui.

### Étape 2 — `macos/modules/keylogger/init.lua` (1 674 l.)

Le seul fichier de la liste d'origine qui a **grossi**. Ses voisins montrent la
découpe : `log_manager.lua` (1 292) en est déjà sorti, donc le module sait être
découpé — il a simplement continué à accumuler.

Test de régression : les tests comportementaux existants du keylogger doivent
rester verts sans être touchés. **Si un test doit être modifié pour que la
découpe passe, c'est un test d'introspection** — étape 1 l'aura déjà classé.

### Étape 3 — La symétrie, mesurée avant d'être visée

`test-driver-tree-parity.cjs` mesure 25/47 répertoires partagés (53,2 %) et
14/25 features canoniques sur les trois drivers. Le ratchet a été resserré sur sa
mesure le 2026-08-04 (il portait deux chemins de mou).

**Ne vise pas 47/47.** Le gate porte déjà l'historique qui explique pourquoi
l'union rétrécit quand une réorganisation réussit. Vise les 11 features
canoniques manquantes, une par une, chacune avec sa raison si elle reste absente
— l'infrastructure `reason_key` existe depuis le 2026-08-03 et alimente le
rapport de santé.

### Étape 4 — Les défauts, en resserrant plutôt qu'en déplaçant

34 tables `DEFAULT_STATE` sur macOS, et **26 gates `*-single-source.cjs`** les
encadrent déjà. La douleur n'est plus « les défauts sont éparpillés » mais
« combien de ces 34 ne sont couverts par aucun des 26 ».

Livrable : croiser les deux listes, et pour chaque table non couverte, soit un
gate, soit une justification driver-specific explicite.

---

## 3. Ce que ce guide refuse de proposer

- **Convertir les 755 tests d'introspection en tests comportementaux.** Une
  partie garde des invariants qu'aucun test comportemental ne peut atteindre
  (§1). Une conversion en masse détruirait ce filet et se présenterait comme un
  progrès.
- **Sortir les helpers OS de `adapters/`.** `PROJECT_MEMORY` le prouve non
  faisable : le ratchet de pureté `hs.*` s'y oppose, et il a raison.
- **Porter Windows sur le cœur de matcher partagé.** Mesuré le 2026-08-04 : le
  cœur est en **Lua** et le driver Windows ne contient **aucun** fichier Lua hors
  de son arbre de tests. Windows partage le **contrat comportemental** — le
  corpus cross-driver — pas le code.

---

## 4. Le harnais, inchangé

```sh
node tools/test/run-js-suite.cjs                      # 154 checks
cd static/ergopti_plus/macos  && lua tests/run.lua    # 3807
cd static/ergopti_plus/linux  && lua tests/run.lua    # 1340
# AutoHotkey : spawnSync(AutoHotkey64.exe, ['run_all.ahk'], {cwd: windows/tests})
node tools/test/test-ahk-encoding.cjs
node tools/lint/lint-conventions.js --fail-on-violations
```

**La suite AHK est un binaire GUI** : lancée depuis PowerShell avec `&`, elle rend
la main immédiatement et ne capture rien. Il faut `spawnSync` depuis node.

---

## 5. La leçon de méthode, parce qu'elle vaut le guide

Le prompt fournissait trois chiffres et demandait de les re-vérifier. **Deux
avaient changé de sens.** Sur la session du 2026-08-03, quinze entrées de
`TODO.md` ont été corrigées de la même façon, et environ une sur deux inversait
le travail à faire — dont deux corrections écrites une heure plus tôt par la même
personne qui les corrigeait.

Un plan a une date. Le code n'en a pas. **Re-mesurer coûte quelques minutes ;
refactorer contre un plan périmé coûte la session.**
