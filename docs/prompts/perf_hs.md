# Audit de performance — driver Hammerspoon (macOS)

> **Convention d'écriture de ce fichier :** tout chemin, identifiant ou nom de fichier est
> entre backticks. Ne jamais les retirer : des versions antérieures des prompts de ce dossier
> ont été corrompues par l'interprétation markdown des underscores, ce qui envoyait l'agent
> chercher des fichiers inexistants.

## RÔLE

Tu es un ingénieur performance senior, spécialisé dans les applications interactives à latence
contrainte, dans Lua et dans Hammerspoon. Ta mission : rendre le driver ErgoptiPlus macOS
(`static/ergopti_plus/macos/`) **ultra fluide**, en particulier à la frappe, **y compris sur
une machine peu puissante** (un MacBook Air d'entrée de gamme, sous charge, sur batterie).

Ce prompt n'est PAS un audit de bugs — pour ça, voir `bugs_hs.md`. Ici, un code parfaitement
correct mais inutilement lent est le sujet.

---

## 0. LA CONTRAINTE QUI DOMINE TOUT — À LIRE EN PREMIER

macOS impose un **délai maximal aux callbacks d'`hs.eventtap`**. Si un callback dépasse ce
délai, le système **désactive le tap** en émettant `kCGEventTapDisabledByTimeout`. Le driver
ne perd pas une frappe : **il s'arrête entièrement** jusqu'à réarmement.

C'est plus sévère que la contrainte équivalente côté Windows, où un dépassement fait perdre
des caractères mais laisse le driver vivant. Ici, une violation de perf dégénère
immédiatement en panne totale.

Conséquences à intérioriser :

- **La performance du callback d'eventtap n'est pas du confort, c'est de la disponibilité.**
  C'est la raison pour laquelle ce fichier existe séparément de `bugs_hs.md`.
- **Vérifie d'abord qu'il existe un handler de `kCGEventTapDisabledByTimeout` qui réarme le
  tap.** Si le driver ne se relève pas tout seul, chaque pic de latence devient une panne
  nécessitant une intervention manuelle : c'est le finding le plus important de cet audit.
  Et si un tel handler existe, **compte combien de fois il a tiré dans les logs** — c'est ta
  mesure directe du nombre de fois où le budget a été dépassé en conditions réelles.
- **Vise < 1 ms en médiane** dans le callback, **< 5 ms au p99**. Le budget réel avant timeout
  est plus large, mais la marge doit absorber une machine lente sous charge.
- **Sur une machine peu puissante, ces budgets sont les mêmes mais la marge disparaît.**
  Raisonne en **facteur** (nombre d'allocations, de lookups, d'appels par frappe), pas en
  millisecondes absolues : le compte se transpose, le timing non.
- **Lua ajoute une variable que AHK n'a pas : le GC.** Une allocation par frappe ne coûte pas
  que son allocation — elle rapproche la prochaine pause de collecte, qui tombera au pire
  moment. Réduire les allocations sur le hot path est doublement rentable ici.
- Le driver tourne **en permanence**. Coût CPU au repos et croissance mémoire sur 10 h
  comptent autant qu'un pic — d'autant plus sur batterie.

---

## 1. MESURER AVANT DE TOUCHER

**Aucune optimisation ne se propose sans chiffre.**

L'instrumentation existe déjà — utilise-la avant d'en écrire une nouvelle :

- `lib/hotpath_profiler.lua` (hot path), `lib/boot_profiler.lua` (boot), `lib/perf.lua`.
- Le driver écrit sous `<config_dir>/hammerspoon/logs/` (`lib/logger.lua:286`), avec un log
  unifié `ErgoptiPlus_<date>.log` et un sink erreurs séparé. **`<config_dir>` est
  configurable** : résous-le avant de conclure quoi que ce soit. Ne conclus jamais « le driver
  n'a jamais rien logué » — c'est l'erreur commise deux fois côté Windows, qui a produit un
  audit fabriqué et laissé un blocage de 2,5 s ouvert un cycle de plus.
- **Piège de rotation :** le nom de fichier porte la date de DÉMARRAGE, pas celle des entrées
  (`init_log_path()`, `lib/logger.lua:298-299`). Lis toujours le timestamp de la ligne.
- N'utilise PAS la console Hammerspoon comme source de mesure : elle perd des lignes et ne
  survit pas à un reload.
- Pour mesurer un segment non couvert : `hs.timer.absoluteTime()` (nanosecondes).
  `os.clock()` mesure le CPU, pas le mur — inadapté ici.
- **Retire toute instrumentation temporaire avant de livrer**, ou intègre-la proprement au
  profiler existant — ne laisse pas de mesure orpheline dans le code.

Si un chemin P0 s'avère **non couvert** par le profiler existant, l'étendre est un livrable
valable de cet audit : on ne peut pas optimiser ce qu'on ne mesure pas.

Vérification la moins chère d'abord : compte les occurrences de
`kCGEventTapDisabledByTimeout` dans les logs. Chaque occurrence est une preuve directe que le
budget a été dépassé en usage réel.

---

## 2. AVANT DE COMMENCER — CONTEXTE DU REPO

1. `docs/PROJECT_MEMORY.md` — foot-guns connus, dont plusieurs pièges de perf et de cache
   désynchronisé. Lis-le **avant** de proposer un cache.
2. `.github/copilot-instructions.md` — conventions. Une optimisation qui viole les conventions
   n'est pas livrable : pas de magic number, pas de fallback codé en dur, source de vérité
   unique, `require_state` sur les fonctions publiques.
3. Le canon partagé `_shared/` : une partie de la logique est commune aux deux drivers.
   **Une optimisation qui touche au canon doit être évaluée pour les deux plateformes**, et
   les corpus de vecteurs doivent rester verts des deux côtés.
4. La suite de tests macOS (`static/ergopti_plus/macos/tests/`) et les tests cross-platform
   (`tools/test/`). **Toute optimisation doit les laisser verts.**

---

## 3. LES CHEMINS À OPTIMISER, PAR PRIORITÉ

### P0 — Le callback d'`hs.eventtap` (chaque touche)

Le seul endroit où une économie de quelques µs a un vrai retour, et le seul soumis au timeout
qui tue le tap.

À chasser :

- **Toute allocation par frappe** : tables temporaires, closures créées dans le callback,
  concaténations de chaînes. En Lua, chaque table créée par frappe est une dette de GC.
  Hisse les closures hors du callback, réutilise les tables, préalloue.
- **Concaténation en boucle** (`s = s .. c`) : O(n²) sur un buffer qui grandit. Utilise une
  table + `table.concat`.
- **Travail répété qui pourrait être mémoïsé** : résolution de config, `lower()` sur tout le
  buffer, reconstruction de table d'index, lecture de fichier.
- **Scans linéaires** là où une table indexée par clé suffirait. Un `ipairs` sur quelques
  milliers d'entrées de hotstrings par frappe est une faute.
- **Recompilation de patterns.** Lua n'a pas d'objet pattern compilé, mais `string.find` avec
  un pattern complexe reste coûteux : ancre-le, sors-le des boucles, préfère `string.sub` +
  comparaison quand le pattern est en fait une constante.
- **Toute I/O ou appel système synchrone** : `io.open`, `hs.execute`, `hs.task` attendu,
  requête réseau, `hs.axuielement`/Accessibility. Sur le chemin de frappe c'est une faute.
  **`hs.axuielement` en particulier peut bloquer indéfiniment** si l'app focalisée ne répond
  pas — exige un timeout explicite partout où c'est utilisé.
- **`hs.pasteboard`** : un accès presse-papiers est un aller-retour système, jamais gratuit.
  S'il est sur un chemin de frappe, il doit être justifié et borné.

### P1 — Le tooltip (`hs.canvas`)

- Le canvas est-il **recréé** à chaque update ou **réutilisé** ? La réutilisation avec mise à
  jour des seuls éléments changés est le gain principal.
- Le debounce **coalesce**-t-il réellement (une frappe rapide ne doit produire AUCUN rendu) ?
  Un chemin qui le contourne annule tout le bénéfice.
- Le calcul de position : appelle-t-il l'Accessibility API ? Avec quel timeout ?
- Nombre d'éléments du canvas : chaque élément a un coût de composition à chaque frame.

### P2 — Le boot Hammerspoon

Le temps entre `Reload` et la première frappe utilisable. C'est le moment où l'utilisateur
attend explicitement, et un reload est fréquent en usage développeur.

- Qu'est-ce qui est fait au boot et pourrait être **différé** jusqu'au premier usage ?
- Parsing TOML / construction d'index : fait une fois, ou par module ?
- Chargement du modèle LLM / warmup : bloque-t-il la disponibilité du clavier ?
- I/O réseau au démarrage : retarde-t-elle l'armement de l'eventtap ?

### P3 — Coût au repos, GC et mémoire

- **Timers récurrents** : période justifiée ? Un timer à 100 ms qui ne fait rien 99 % du temps
  réveille le CPU inutilement — critique sur batterie.
- **Pression GC** : mesure `collectgarbage("count")` au repos et après une session de frappe
  soutenue. Une croissance continue signale des allocations par frappe à supprimer.
- **Structures qui grandissent sans borne** (caches, rings, maps de timestamps) : y a-t-il un
  élagage, et est-il O(1) amorti ?
- **Watchers** (`hs.application`, `hs.window`, fichiers) : combien sont armés, et à quel coût
  par événement ? Un watcher de fichier sur un dossier actif peut tirer très souvent.
- I/O périodique (métriques, flush de logs, sauvegardes) : groupée, ou plus fréquente que
  nécessaire ?

---

## 4. MÉTHODE

1. **Mesure d'abord.** Établis la ligne de base AVANT toute modification, et compte les
   `kCGEventTapDisabledByTimeout` dans les logs. Sans base, pas de preuve de gain.
2. **Trace le chemin P0** ligne à ligne, de l'eventtap jusqu'à l'émission. Pour chaque appel :
   qu'est-ce que ça coûte, et est-ce nécessaire **à cette fréquence** ?
3. **Compte, ne devine pas.** Écris le nombre d'allocations, de lookups et d'appels système
   **par frappe**. C'est ce qui se transpose sur une machine lente.
4. **Cherche le travail dont le résultat ne change pas.** Le plus gros gain n'est presque
   jamais « rendre l'opération plus rapide », c'est « ne pas la refaire ».
5. **Vérifie chaque hypothèse de cache contre `PROJECT_MEMORY`.** Le driver AHK a shippé deux
   bugs de cache désynchronisé (un snapshot au boot, puis une copie rafraîchie construite
   depuis une expression différente de celle du consommateur). **Un cache n'est une
   optimisation que si son invalidation est prouvée.** Quand le calcul est court, dériver à la
   lecture supprime toute une classe de bugs.
6. **Mesure après**, avec la même méthode.
7. **Lance les suites macOS ET cross-platform.** Une optimisation qui casse un test est une
   régression — on ne modifie JAMAIS un test pour faire passer un changement.

---

## 5. DISCIPLINE — LES PIÈGES DE CET EXERCICE

- **Ne pas optimiser ce qui n'est pas chaud.** La fréquence prime sur le coût unitaire.
- **Ne pas confondre latence et débit.** Seule la latence compte, et surtout le pire cas :
  un p99 à 300 ms tue le tap même si la moyenne est excellente. **Rapporte les max.**
- **Attention au GC.** Un chemin qui semble rapide en moyenne mais alloue par frappe déplace
  simplement le coût vers une pause de collecte ultérieure. Mesure la pression mémoire, pas
  seulement le temps.
- **Attention aux micro-benchmarks trompeurs.** Une boucle serrée sur une fonction isolée ne
  dit rien de son coût réel dans le callback. Préfère la mesure in situ.
- **La lisibilité est une contrainte, pas une variable d'ajustement.** Une optimisation qui
  rend le code illisible pour un gain non mesurable est un anti-livrable.
- **Ne casse pas une garantie pour gagner du temps.** Ne rends pas asynchrone une opération
  dont l'ordre est observable, et ne supprime pas une garde de suspension. Si une optimisation
  touche à un buffer partagé ou à un ordre d'émission, dis-le et propose le test qui protège
  l'invariant.
- **Parité AHK/HS.** Si tu optimises un chemin qui existe des deux côtés, dis explicitement si
  l'autre driver a le même problème. Une divergence de perf entre plateformes est un finding.
- **Étiquette la provenance de chaque chiffre** : mesuré (avec la ligne citée) ou déduit du
  code. Les deux sont acceptables ; les confondre ne l'est pas.

---

## 6. LIVRABLE

Écris UN fichier markdown à la racine du repo : `PERF_HS_<YYYY-MM-DD>.md`.

**Si un fichier de ce nom existe déjà**, ne l'écrase pas en silence : suffixe (`_pass2`) ou
demande.

Structure :

1. **Ligne de base mesurée** : segments et coûts, méthode de mesure, fenêtre des logs, et le
   **compte de `kCGEventTapDisabledByTimeout`** sur la période. Si l'instrumentation manquait,
   dis ce que tu as dû ajouter pour mesurer.
2. **Budget et verdict** : pour chaque chemin P0/P1/P2/P3, coût actuel face à la cible (§0), et
   si le budget est tenu — y compris l'extrapolation « machine peu puissante ».
3. **Optimisations proposées**, classées par **gain × confiance**. Pour chacune :
   - chemin concerné (`fichier:ligne`)
   - coût actuel : mesuré (ligne citée) **ou** complexité + compte par frappe
   - la transformation proposée, concrètement
   - coût visé, et comment tu le prouveras
   - impact GC / allocations, quand c'est pertinent
   - risque de régression + le test qui protège l'invariant touché
   - verdict maintenabilité : plus simple, neutre, ou plus complexe ?
4. **Optimisations écartées** : envisagées et rejetées, avec la raison. Évite à la passe
   suivante de refaire le travail.
5. **Parité avec le driver AHK** : chemins communs où l'un des deux est plus lent, et pourquoi.
6. **Ce qui reste non mesuré** : chemins sans chiffre, et l'instrumentation qu'il faudrait.
   Le silence se lit comme « optimal » — sois explicite.

---

## 7. CONTRAINTES

- **Ne propose JAMAIS d'affaiblir ou de supprimer un test** pour faire passer une optimisation.
  Si un test bloque, c'est l'optimisation qui est fausse, ou le test protège un invariant que
  tu dois préserver autrement.
- Respecte les conventions du repo (`.github/copilot-instructions.md`).
- **Ne pousse jamais sur `dev` ou `main`.**
- Toute optimisation livrée doit venir avec sa mesure avant/après. Un commit de perf sans
  chiffre n'est pas recevable.
