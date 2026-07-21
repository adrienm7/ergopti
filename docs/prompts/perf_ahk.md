# Audit de performance — driver AHK (Windows)

> **Convention d'écriture de ce fichier :** tout chemin, identifiant ou nom de fichier est
> entre backticks. Ne jamais les retirer : des versions antérieures des prompts de ce dossier
> ont été corrompues par l'interprétation markdown des underscores, ce qui envoyait l'agent
> chercher des fichiers inexistants.

## RÔLE

Tu es un ingénieur performance senior, spécialisé dans les applications interactives à latence
contrainte et dans AutoHotkey v2. Ta mission : rendre le driver ErgoptiPlus
(`static/ergopti_plus/windows/`) **ultra fluide**, en particulier à la frappe, **y compris sur
une machine peu puissante**.

Ce prompt n'est PAS un audit de bugs — pour ça, voir `bugs_ahk.md`. Ici, un code parfaitement
correct mais inutilement lent est le sujet. Tu es là pour trouver le travail inutile et le
supprimer, pas pour valider que ça marche.

---

## 0. LA CONTRAINTE QUI DOMINE TOUT — À LIRE EN PREMIER

Windows impose un **délai maximal aux hooks clavier bas niveau**
(`LowLevelHooksTimeout`, ~300 ms par défaut, registre `HKCU\Control Panel\Desktop`). Si un
callback de hook dépasse ce délai, **Windows ne l'attend pas : il DÉLIVRE la frappe sans
l'attendre et peut désinstaller le hook.** Concrètement, l'utilisateur perd des caractères,
silencieusement, sans aucune erreur nulle part.

Conséquences à intérioriser :

- **La performance du hot path de frappe n'est pas du confort, c'est de la correction.** Un
  ralentissement suffisant devient une perte de données utilisateur. C'est la raison pour
  laquelle ce fichier existe séparément.
- **Le budget n'est pas « imperceptible pour un humain » (~50 ms), il est bien plus serré.**
  Vise **< 1 ms** en médiane sur le chemin de frappe et **< 5 ms** au p99. Le profiler du repo
  logge déjà au-delà de `_HOTPATH_SLOW_MS := 5.0`, ce qui te donne la cible.
- **Sur une machine peu puissante, ces budgets sont les mêmes mais la marge disparaît.** Un
  chemin qui coûte 8 ms sur la machine du mainteneur peut en coûter 40 sur un portable
  d'entrée de gamme sous charge. Raisonne en **facteur**, pas en millisecondes absolues :
  « ce chemin fait N allocations et M lookups par frappe » se transpose, « ça prend 3 ms »
  non.
- Le driver tourne **en permanence, en arrière-plan**. Un coût CPU au repos ou une croissance
  mémoire sur une session de 10 h comptent autant qu'un pic.

---

## 1. MESURER AVANT DE TOUCHER — OÙ SONT LES VRAIS CHIFFRES

**Aucune optimisation ne se propose sans chiffre.** Une optimisation « évidente » non mesurée
est une hypothèse, et souvent une régression de lisibilité pour rien.

Le driver écrit ses logs sous `<ConfigDir>/autohotkey/logs/`. **`<ConfigDir>` n'est PAS le
dossier par défaut** : il est redirigé par `%APPDATA%\Ergopti\paths.toml`. Sur la machine du
mainteneur :

```
D:\Documents\GitHub\config\ergopti_plus\autohotkey\logs\
```

- `lib/hotpath_profiler.ahk` logge `Slow <segment>: <ms>` au-delà de `_HOTPATH_SLOW_MS := 5.0`
- `lib/boot_profiler.ahk` fait l'équivalent pour le boot
- Rétention 14 jours ; le nom de fichier porte la date de DÉMARRAGE du driver, pas celle des
  entrées — lis toujours le timestamp de la ligne

Vérification la moins chère d'abord :

```bash
awk 'index($0,"Slow")>0{c++} END{print c+0}' <log>
```

Si ça affiche 0, il n'y a pas eu de mesure — ne théorise pas par-dessus.

### Agrégation utile

```bash
# Top segments par max, sur tous les logs
awk 'match($0,/Slow ([A-Za-z.]+): ([0-9.]+)/,m){
  n[m[1]]++; s[m[1]]+=m[2]; if(m[2]>x[m[1]])x[m[1]]=m[2]; if(m[2]>100)h[m[1]]++
} END{ for(k in n) printf "%-28s n=%-6d max=%-9.1f mean=%-7.1f >100ms=%d\n",k,n[k],x[k],s[k]/n[k],h[k]+0 }' \
  <logdir>/ErgoptiPlus_*.log | sort -t= -k3 -rn
```

### Référence mesurée (2026-07-20, 10 jours de logs)

Point de comparaison — **re-dérive-la, ne la recopie pas**.

| Segment                   | Count | Max ms     | Mean ms | >100 ms |
| ------------------------- | ----- | ---------- | ------- | ------- |
| `Tooltip.Present`         | 2470  | 238.8      | 15.7    | 5       |
| `OnChar`                  | 2018  | 701.3      | 18.6    | 35      |
| `Tooltip.ResolvePos`      | 1764  | **2560.3** | 18.1    | 41      |
| `HSE.FeedChar`            | 1426  | 700.8      | 19.5    | 26      |
| `Tooltip.Build`           | 842   | 295.8      | 13.9    | 5       |
| `HSE.Dispatch`            | 329   | 121.0      | 11.6    | 1       |
| `Tooltip.BorderPixelLoop` | 109   | 224.5      | 12.4    | 2       |

`OnChar` et `HSE.FeedChar` portent le même timestamp et la même durée : ce sont des segments
**IMBRIQUÉS** qui mesurent le même blocage. Ne les additionne jamais.

**Lecture de cette table :** les moyennes (~15 ms) sont déjà 15× au-dessus de la cible, et le
max de `Tooltip.ResolvePos` (2,5 s) est un blocage total du clavier. Le tooltip est le premier
chantier.

### Si le profiler ne couvre pas ce que tu veux mesurer

Instrumente temporairement avec `A_TickCount` (résolution ~15 ms, insuffisante pour le hot
path) ou `DllCall("QueryPerformanceCounter", …)` (µs). **Retire l'instrumentation temporaire
avant de livrer**, ou intègre-la proprement au profiler existant — ne laisse pas de mesure
orpheline dans le code.

---

## 2. AVANT DE COMMENCER — CONTEXTE DU REPO

1. `docs/PROJECT_MEMORY.md` — foot-guns connus, dont plusieurs sont des pièges de perf
   (Critical trop large qui affame le hook, snapshot vs dérivation, caches qui se
   désynchronisent). Lis-le avant de proposer un cache.
2. `.github/copilot-instructions.md` — conventions. **Une optimisation qui viole les
   conventions n'est pas livrable** : pas de magic number, pas de fallback codé en dur, pas de
   duplication d'une source de vérité.
3. `lib/hotpath_profiler.ahk` et `lib/boot_profiler.ahk` — l'instrumentation existante.
4. La suite de tests : `static/ergopti_plus/windows/tests/run_all.ahk`. **Toute optimisation
   doit laisser la suite verte.** Elle est ta police d'assurance contre une « optimisation »
   qui change le comportement.

---

## 3. LES CHEMINS À OPTIMISER, PAR PRIORITÉ

L'ordre compte : le gain d'une micro-optimisation est proportionnel à sa fréquence.

### P0 — Le chemin de frappe (chaque caractère tapé)

C'est le seul endroit du repo où une économie de quelques µs a un vrai retour : il est
parcouru des milliers de fois par jour, et il est sous contrainte de timeout OS.

Y passent notamment : le hook clavier → `_RemapEmit` / dispatch de layer → `HSE_FeedChar` →
matching → le watcher de préfixe (`OnChar`) → planification du rendu du tooltip.

À chasser :

- **Travail répété par frappe qui pourrait être mémoïsé** : résolution de config, `StrLower`
  sur tout le buffer, reconstruction de `Map`, `HotstringsResolve` non caché, relecture d'un
  fichier ou d'une clé de registre.
- **Scans O(n) par frappe.** L'enregistrement emoji/symbol (~3000 entrées) doit rester une
  sonde `Map` bornée par trigger, jamais un parcours. Cherche aussi ce qui grandit avec la
  session : un `lower()` sur tout le buffer à chaque frappe est O(n) **par caractère**, donc
  O(n²) sur un mot long.
- **Allocation / recompilation de regex par frappe.** Ancre les patterns, hisse-les en
  `static`, cache les résultats.
- **Objets créés puis jetés à chaque frappe** ; buffers redimensionnés au lieu d'être réutilisés.
- **`Clone()` profond d'une structure large** sur un chemin chaud.
- **Concaténation en boucle** là où un tableau + un `Join` final serait linéaire.
- **Toute I/O synchrone** : `FileRead`, `FileAppend`, `RegRead`, shell, COM/UIA, HTTP. Sur le
  chemin de frappe, c'est une faute, pas une optimisation possible.

### P0bis — La portée de `Critical`

`Critical` est l'outil de sérialisation du driver, mais **il coupe la pompe de messages** :
trop large, il affame le hook clavier et provoque exactement le timeout décrit en §0. Trop
étroit, on retombe sur des transpositions.

Pour chaque section `Critical` du hot path : est-elle **minimale** ? Contient-elle un `Sleep`,
une I/O, un appel COM/UIA, une attente bloquante ? Si oui, c'est un finding P0 — le pattern
correct est de relâcher autour de l'opération lente et de restaurer dans un `finally`.

### P1 — Le tooltip

C'est le composant le plus cher du driver, et de loin (voir la table §1).

- Le rendu détruit et recrée des fenêtres top-level à chaque update. Chaque piste qui permet
  de **réutiliser** la fenêtre / le canvas au lieu de la recréer est à chiffrer en priorité.
- `Tooltip.ResolvePos` a un max mesuré de 2,5 s : cherche l'appel COM/UIA **sans timeout**.
  Une app focalisée qui ne répond pas bloque le driver aussi longtemps qu'elle veut.
  Un timeout explicite est ici une optimisation ET une correction.
- Le debounce existe déjà — vérifie qu'il **coalesce** réellement (une frappe rapide ne doit
  produire AUCUN rendu) et qu'aucun chemin ne le contourne.
- Le calcul de bordure pixel par pixel (`Tooltip.BorderPixelLoop`) est un candidat évident à
  la mise en cache ou à une approche non itérative.

### P2 — Le boot

Le temps entre le lancement et la première frappe utilisable. Sur machine lente, c'est la
première impression et le seul moment où l'utilisateur attend explicitement.

- Qu'est-ce qui est fait au boot et pourrait être **différé** (lazy) jusqu'au premier usage ?
- Qu'est-ce qui est fait au boot **et refait plus tard** ?
- Les parsings TOML / constructions d'index sont-ils faits une fois, ou par module ?
- Y a-t-il de l'I/O réseau (updater) qui retarde la disponibilité du clavier ?

### P3 — Le coût au repos et la croissance mémoire

- Timers récurrents : leur période est-elle justifiée ? Un timer à 100 ms qui ne fait rien
  99 % du temps réveille le CPU inutilement — surtout sur batterie.
- Structures qui grandissent sans borne sur une longue session (caches, rings, maps de
  timestamps). Y a-t-il un élagage ? Est-il O(1) amorti ou O(n) à chaque insertion ?
- I/O périodique (métriques, flush de logs, sauvegardes) : groupée ou déclenchée plus souvent
  que nécessaire ?

---

## 4. MÉTHODE

1. **Mesure d'abord.** Agrège les logs existants (§1). Établis la ligne de base AVANT toute
   modification. Sans base, tu ne pourras pas prouver le gain.
2. **Trace les chemins P0** ligne à ligne, du hook jusqu'à l'émission. Pour chaque appel :
   qu'est-ce que ça coûte, et est-ce nécessaire **à cette fréquence** ?
3. **Compte, ne devine pas.** Pour chaque chemin chaud, écris le nombre d'allocations, de
   lookups, de comparaisons et d'I/O **par frappe**. C'est cette grandeur qui se transpose sur
   une machine lente, pas un timing absolu.
4. **Cherche le travail dont le résultat ne change pas.** La plus grosse source de gain n'est
   presque jamais « rendre l'opération plus rapide », c'est « ne pas la refaire ».
5. **Vérifie chaque hypothèse de cache contre `PROJECT_MEMORY`.** Ce repo a shippé deux bugs
   de cache désynchronisé (un snapshot au boot, puis une copie rafraîchie construite depuis
   une expression différente de celle du consommateur). **Un cache n'est une optimisation que
   si son invalidation est prouvée.** Quand le calcul est court, dériver à la lecture est
   souvent la bonne réponse et supprime toute une classe de bugs.
6. **Mesure après.** Rejoue la même agrégation. Un gain non mesuré n'est pas un gain.
7. **Lance la suite complète.** Une optimisation qui casse un test est une régression, pas une
   optimisation — et on ne modifie JAMAIS un test pour faire passer un changement.

---

## 5. DISCIPLINE — LES PIÈGES DE CET EXERCICE

- **Ne pas optimiser ce qui n'est pas chaud.** Un gain de 40 % sur un chemin parcouru une fois
  au boot ne vaut pas la complexité ajoutée. La fréquence prime sur le coût unitaire.
- **Ne pas confondre latence et débit.** Ici seule la latence compte, et surtout la latence
  du pire cas : un p99 à 300 ms fait perdre des caractères même si la moyenne est à 1 ms.
  **Rapporte toujours les max, pas seulement les moyennes.**
- **La lisibilité est une contrainte, pas une variable d'ajustement.** Une optimisation qui
  rend le code illisible pour un gain non mesurable est un anti-livrable : ne la propose pas.
  Si tu la proposes quand même parce que le gain est réel et gros, dis explicitement ce que ça
  coûte en maintenabilité.
- **Attention aux micro-benchmarks trompeurs.** Mesurer une fonction isolée en boucle serrée
  ne dit rien de son coût sur le hot path réel (cache CPU chaud, pas de contention, pas de
  pompe de messages). Préfère toujours la mesure in situ via le profiler.
- **Ne casse pas une garantie pour gagner du temps.** Notamment : ne réduis pas la portée d'un
  `Critical` au point de rouvrir une race, et ne rends pas asynchrone une opération dont
  l'ordre est observable. Si une optimisation touche à `Critical`, à un ordre d'émission ou à
  un buffer partagé, dis-le explicitement et propose le test qui protège l'invariant.
- **Étiquette la provenance de chaque chiffre** : mesuré (avec la ligne de log citée) ou
  déduit du code. Les deux sont acceptables ; les confondre ne l'est pas.

---

## 6. LIVRABLE

Écris UN fichier markdown à la racine du repo : `PERF_AHK_<YYYY-MM-DD>.md`.

**Si un fichier de ce nom existe déjà**, ne l'écrase pas en silence : suffixe (`_pass2`) ou
demande.

Structure :

1. **Ligne de base mesurée** : la table agrégée des segments, la méthode d'agrégation utilisée,
   la fenêtre temporelle des logs. C'est le point de comparaison de tout le reste.
2. **Budget et verdict** : pour chaque chemin P0/P1/P2/P3, le coût actuel face à la cible
   (§0), et si le budget est tenu — y compris l'extrapolation « machine peu puissante ».
3. **Optimisations proposées**, classées par **gain × confiance**. Pour chacune :
   - chemin concerné (`fichier:ligne`)
   - coût actuel : mesuré (log cité) **ou** complexité asymptotique + compte par frappe
   - la transformation proposée, concrètement
   - coût visé, et comment tu le prouveras
   - risque de régression + le test qui protège l'invariant touché
   - verdict maintenabilité : le code devient-il plus simple, neutre, ou plus complexe ?
4. **Optimisations écartées** : ce que tu as envisagé et rejeté, avec la raison (gain trop
   faible, risque trop élevé, déjà optimal). Évite à la passe suivante de refaire le travail.
5. **Ce qui reste non mesuré** : les chemins pour lesquels tu n'as pas de chiffre, et ce qu'il
   faudrait instrumenter pour en avoir. Le silence se lit comme « optimal » — sois explicite.

---

## 7. CONTRAINTES

- **Ne propose JAMAIS d'affaiblir ou de supprimer un test** pour faire passer une optimisation.
  Si un test bloque, c'est l'optimisation qui est fausse, ou le test protège un invariant que
  tu dois préserver autrement.
- Respecte les conventions du repo (`.github/copilot-instructions.md`) : constantes nommées,
  source de vérité unique, fail-fast, logging.
- **Ne pousse jamais sur `dev` ou `main`.**
- Toute optimisation livrée doit venir avec sa mesure avant/après. Un commit de perf sans
  chiffre n'est pas recevable.
