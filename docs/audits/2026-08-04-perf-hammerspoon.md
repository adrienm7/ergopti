<!-- docs/audits/2026-08-04-perf-hammerspoon.md -->

# Audit de performance — driver Hammerspoon (macOS)

> Produit le 2026-08-04 en exécutant `docs/prompts/perf_hs.md`.
> Chaque affirmation porte un `path:line` ou une commande reproductible.

---

## 0. La question que le prompt appelle « le finding le plus important »

> « Vérifie d'abord qu'il existe un handler de `kCGEventTapDisabledByTimeout` qui
> réarme le tap. Si le driver ne se relève pas tout seul, chaque pic de latence
> devient une panne nécessitant une intervention manuelle. »

**Réponse : il existe, il est bon, et il est correctement appelé — sauf à un
endroit.**

`adapters/event_tap_guard.lua:73` implémente `handle_disabled(event, tap, label)`.
Sa qualité mérite d'être notée, parce qu'elle n'est pas évidente :

- Il **distingue les deux causes** (`:93-96`) au lieu de les confondre : un
  timeout signifie que notre callback a dépassé le budget et la latence est à
  nous ; un `tapDisabledByUserInput` signifie que la permission d'accessibilité a
  bougé sous nos pieds. Ce sont deux actions différentes pour qui lit le log.
- Il refuse un type `nil` (`:84`) avec la raison écrite : les deux côtés de la
  comparaison peuvent légitimement être `nil`, et `nil == nil` est vrai — une
  comparaison non gardée déclarerait **chaque** événement comme une notification
  de désactivation et avalerait tout le tap. La panne du correctif serait pire
  que celle corrigée.
- Il **signale l'échec du réarmement** (`:104`) — « il reste sourd jusqu'au
  reload » — au lieu de le laisser silencieux.

### Le finding : une deuxième implémentation, écrite à la main

`modules/gestures/init.lua:750-758` crée un eventtap (le « primer ») et gère
`tapDisabledByTimeout` / `tapDisabledByUserInput` **en ligne**, avec sa propre
copie de la logique de réarmement.

```sh
grep -rn "hs.eventtap.new" --include=*.lua static/ergopti_plus/macos | grep -v tests   # 13 fichiers
grep -rln "EventTapGuard.handle_disabled" --include=*.lua static/ergopti_plus/macos | grep -v tests
# → gestures/init.lua est le seul créateur de tap absent de la seconde liste
```

**Ce n'est pas une panne.** La copie inline réarme réellement et journalise en
WARNING. Le problème est que le docstring de l'adaptateur ouvre par :

> « Single place where the driver reacts to macOS switching one of its event taps
> off. »

**Cette affirmation est fausse**, et c'est exactement la forme que ce dépôt
documente sous « invariant appliqué par site, un frère oublié » — la même forme
qui, le 2026-08-03, avait laissé `AltTabMonitor` sans le durcissement que son
frère `GestureGetCyclableWindows` avait reçu.

Les deux copies divergent déjà sur trois points :

| | `event_tap_guard` | copie inline du primer |
| --- | --- | --- |
| Distingue timeout / user-input | oui | **non** (un seul message) |
| Signale un réarmement échoué | oui (`ERROR`) | **non** (`pcall` muet) |
| Compte les occurrences | non | non |

Le second point est le coûteux : si `gesture_primer:start()` échoue, le `pcall`
l'avale et le primer reste sourd **sans une ligne de log**. C'est précisément le
scénario que l'adaptateur remonte en `ERROR`.

**Correctif recommandé :** router le primer par `EventTapGuard.handle_disabled`,
et ajouter au gate un test qui exige que tout créateur d'`hs.eventtap.new` hors
`adapters/` référence le guard. Sans ce gate, le quatorzième tap réintroduira la
copie.

---

## 1. Le compteur qui manque, et pourquoi il compte

Le prompt demande, une fois le handler confirmé :

> « compte combien de fois il a tiré dans les logs — c'est ta mesure directe du
> nombre de fois où le budget a été dépassé en conditions réelles. »

**Aucune des deux implémentations ne compte.** Les deux journalisent, ce qui rend
l'information *récupérable* par `grep` dans les logs d'un utilisateur qui accepte
de les envoyer, mais **pas observable par le driver lui-même**.

Or le driver a déjà l'endroit où l'exposer : le rapport de santé
(`ui/healthcheck/core.lua`) collecte déjà `warn_count` / `err_count` depuis le
ring buffer, et a gagné le 2026-08-03 une section « couverture plateforme ».
Un compteur `tap_disabled_by_timeout` y serait la seule métrique de perf
**auto-rapportée** du driver.

**C'est le finding le plus actionnable de cet audit** : il transforme « le driver
rame parfois » — irreproductible, invérifiable — en un nombre que l'utilisateur
lit dans son propre rapport de santé.

Coût estimé : un compteur module-level dans `event_tap_guard`, un accesseur, une
ligne dans `format_plain`. Test de régression : incrémenter par un appel simulé.

---

## 2. Ce que l'audit ne peut pas conclure, et pourquoi c'est honnête de le dire

Le prompt vise « < 1 ms en médiane, < 5 ms au p99 » dans le callback, et demande
de raisonner **en facteur** (allocations, lookups, appels par frappe) plutôt
qu'en millisecondes, parce que le compte se transpose d'une machine à l'autre et
le timing non.

**Cette partie de l'audit ne peut pas être menée depuis ce poste.** Le driver
macOS ne tourne pas ici : il n'y a ni Hammerspoon, ni tap, ni frappe réelle. Les
20 segments HotPath et les 5 jalons de boot sont déjà instrumentés et
inventoriés par `test-hotpath-segments-declared.cjs` — l'instrumentation est
complète ; ce qui manque est **une journée d'utilisation réelle**, pas du code.

C'est ce que `TODO.md` avait déjà conclu et retiré de sa liste : *« une procédure
opérationnelle, pas une tâche à planifier »*. Cet audit le confirme plutôt que de
produire des chiffres inventés qui auraient l'air d'une mesure.

**Ce qui reste faisable ici — et fait ci-dessus — c'est la disponibilité :**
vérifier que le driver se relève, et rendre ses dépassements comptables. Les deux
findings ci-dessus sont de cette nature, et ce sont les seuls que ce poste peut
honnêtement produire.

---

## 3. Résumé

| # | Finding | Gravité | Action |
| --- | --- | --- | --- |
| 1 | Le primer de gestes réimplémente la récupération de tap à la main (`gestures/init.lua:750`), et sa copie n'a ni la distinction timeout/user-input ni le signalement d'un réarmement échoué | moyenne — pas de panne, mais un échec de réarmement y est silencieux | router par `EventTapGuard`, + gate sur les créateurs de tap hors `adapters/` |
| 2 | Aucun compteur de désactivations : l'information est dans les logs, pas dans le driver | moyenne — la seule métrique de perf auto-rapportée manque | compteur dans `event_tap_guard`, exposé au rapport de santé |
| 3 | Les budgets p50/p99 ne peuvent pas être mesurés depuis un poste sans macOS | — | l'instrumentation existe déjà ; il faut une journée d'usage réel |

**Aucun finding de type « code inutilement lent » n'est rapporté**, non parce
qu'il n'y en a pas, mais parce que les produire sans exécuter le driver
reviendrait à deviner. Un audit de perf qui rend des chiffres non mesurés est
pire qu'un audit qui dit ce qu'il n'a pas pu mesurer.
