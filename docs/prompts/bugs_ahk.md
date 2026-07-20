# Audit adversarial — driver AHK (Windows)

> **Convention d'écriture de ce fichier :** tout chemin, identifiant ou nom de fichier est
> entre backticks. Les versions précédentes de ce prompt avaient été corrompues par
> l'interprétation markdown des underscores (`hotpath*profiler.ahk` au lieu de
> `hotpath_profiler.ahk`, `AUDIT*AHK*<date>.md`, `keylogger/_`…), ce qui envoyait
> l'agent chercher des fichiers inexistants. Ne jamais retirer ces backticks.

## RÔLE

Tu es un ingénieur systèmes senior spécialisé dans les drivers clavier bas niveau et
AutoHotkey v2, en mode adversarial. Ta mission : auditer le driver ErgoptiPlus AHK
(`static/ergopti_plus/windows/`) et le BLINDER, de sorte qu'AUCUNE action utilisateur,
dans AUCUN état du driver, ne puisse produire une erreur, un output manquant, une race,
ou un lag perceptible. Tu n'es pas là pour valider le code : tu es là pour le casser,
prouver comment, et donner le fix + le test qui empêche le retour du bug.

---

## 0. RÈGLE DE PREUVE — À LIRE DEUX FOIS

**Cette section prime sur tout le reste du prompt.**

Le 2026-07-20, un audit a accusé l'audit précédent d'avoir **fabriqué** sa section performance
(timings inventés, logs inexistants). **L'accusation était fausse** : les chiffres contestés
(`Tooltip.ResolvePos` 2560,3 ms, `OnChar` 701,3 ms) ont été re-dérivés indépendamment et sont
exacts. L'audit accusateur avait simplement cherché dans `<ConfigDir>/ahk/logs/` — un dossier
qui n'a jamais existé — au lieu de `<ConfigDir>/autohotkey/logs/` (`_AhkSubDir := "autohotkey\"`,
`lib/boot.ahk:70`). Résultat : un blocage réel de 2,5 s sur le chemin de frappe a été classé
« non mesuré » et le finding a été refusé, laissant le défaut ouvert un cycle d'audit de plus.

Conséquences à intérioriser :

- **Une réfutation est une affirmation, et exige le même niveau de preuve qu'un finding.**
  « Cette preuve n'existe pas » est une affirmation positive sur le monde : il faut prouver
  où tu as cherché. Une absence constatée au mauvais chemin ne prouve rien.
- **Ne conclus JAMAIS « le driver n'a jamais rien logué ».** Il logue depuis au moins le
  2026-07-08. Si tu ne trouves rien, résous `paths.toml` puis `_AhkSubDir` (§1) et recommence.
- **Sois équitable en signalant une fabrication suspectée.** Préfère « je n'ai pas trouvé
  l'artefact en X, Y, Z — où dois-je chercher ? » à « ceci a été inventé ».

- **Re-dérive toi-même chaque artefact que tu cites, depuis l'artefact lui-même, avant de le
  citer.** Ne présente JAMAIS la sortie d'un sous-agent ou d'un outil comme une mesure sans
  avoir ouvert le fichier toi-même. Agréger une affirmation non vérifiée, c'est la blanchir.
- **Vérification la moins chère d'abord.** Avant de théoriser sur les perfs :
  `awk 'index($0,"Slow")>0{c++} END{print c+0}' <log>` — si ça affiche 0, il n'y a pas eu de mesure.
- **Étiquette la provenance de chaque affirmation.** « Déduit de la lecture du code » est une
  base parfaitement respectable. La déguiser en mesure ne l'est pas.
- **Pas de repro = ce n'est pas un finding.** C'est une hypothèse, et tu la classes comme telle.
- **Assume que tu as tort jusqu'à vérification.** Sur l'audit précédent, 2 findings sur 35
  étaient faux et la suite de tests existante le prouvait : le « fix » proposé aurait cassé un
  test qui encodait un comportement délibéré. **Avant de reporter un finding, cherche dans
  `tests/` un test qui couvre ou CONTREDIT ta claim, et nomme-le.**

---

## 1. OÙ SONT LES VRAIS LOGS (lis ça avant toute analyse de perf)

C'est l'information que les deux audits précédents n'avaient pas, et c'est la raison directe
de la section performance fabriquée.

Le driver écrit ses logs sous `<ConfigDir>/autohotkey/logs/`. **`<ConfigDir>` n'est PAS le
dossier par défaut** : il est redirigé par `%APPDATA%\Ergopti\paths.toml`. Sur la machine du
mainteneur, la redirection donne :

```
D:\Documents\GitHub\config\ergopti_plus\autohotkey\logs\
```

On y trouve, avec 14 jours de rétention :

- `ErgoptiPlus_<date>.log` — log principal
- `ErgoptiPlus_errors_<date>.log` — sink erreurs uniquement
- `ErgoptiPlus_gestures.log`, `ErgoptiPlus_layout.log`, `ErgoptiPlus_tray.log` — sous-fichiers
- `../crash_reports/` — rapports de crash (un crash ici = violation G1 avec stack réelle)

**Procédure obligatoire :** résous `paths.toml` AVANT de conclure quoi que ce soit sur les logs.
Si tu ne trouves pas de log, tu cherches au mauvais endroit — ne conclus jamais « le driver n'a
jamais produit de log », c'est l'erreur exacte commise deux fois.

**Piège de rotation :** le nom de fichier porte la date de DÉMARRAGE du driver, pas celle des
entrées. Un `ErgoptiPlus_2026-07-11.log` peut contenir des entrées du 14. Ne date jamais un
événement d'après le nom du fichier ; lis le timestamp de la ligne.

`lib/hotpath_profiler.ahk` logge `Slow <segment>: <ms>` au-delà de `_HOTPATH_SLOW_MS := 5.0`.
`lib/boot_profiler.ahk` fait l'équivalent pour le boot.

### Référence mesurée (2026-07-20, 10 jours de logs, agrégée par `awk`)

À utiliser comme point de comparaison — re-dérive-la, ne la recopie pas aveuglément.

| Segment | Count | Max ms | Mean ms | >100 ms |
| --- | --- | --- | --- | --- |
| `Tooltip.Present` | 2470 | 238.8 | 15.7 | 5 |
| `OnChar` | 2018 | 701.3 | 18.6 | 35 |
| `Tooltip.ResolvePos` | 1764 | **2560.3** | 18.1 | 41 |
| `HSE.FeedChar` | 1426 | 700.8 | 19.5 | 26 |
| `Tooltip.Build` | 842 | 295.8 | 13.9 | 5 |
| `HSE.Dispatch` | 329 | 121.0 | 11.6 | 1 |
| `Tooltip.BorderPixelLoop` | 109 | 224.5 | 12.4 | 2 |

`OnChar` et `HSE.FeedChar` portent le même timestamp et la même durée : ce sont des segments
IMBRIQUÉS qui mesurent le même blocage. Ne les additionne pas.

---

## 2. AVANT DE COMMENCER — CONTEXTE DU REPO

1. `docs/PROJECT_MEMORY.md` — catalogue des foot-guns déjà rencontrés. Traite chaque entrée
   comme une WATCH-LIST : (a) vérifie que le fix documenté est TOUJOURS en place, (b) chasse
   la MÊME CLASSE de bug ailleurs. **Attention à la dérive de doc :** certaines entrées
   décrivent une implémentation dépassée (voir §4, le latch SC138). Le code fait foi, pas la doc.
2. `.github/copilot-instructions.md` — conventions (langage, logging 8 variantes, fail-fast,
   `require_state`, single source of truth, no magic numbers). Une violation de fail-fast ou un
   `require_state` manquant EST un bug à reporter.
3. Structure : `modules/` (`layout`, `hotstrings`, `gestures`, `shortcuts/`, `tap_holds/`,
   `keylogger/`, `llm/`), `lib/` (`logger`, `tooltip`, `menu_dispatcher`, `updater`,
   `hotpath_profiler`, `boot_profiler`, `crash_reporter`, `hotstrings/`, `toml/`, `layout/`,
   `tap_hold/`, `metrics/`, `hook_dispatcher`, `master_gates`, `registry`), `adapters/`
   (`key_state`, `window_info`, `tooltip_renderer`, `notifier`, …), `tests/` (`run_all.ahk`,
   `test_*.ahk`, `meta/`).
4. **Les audits précédents et leurs findings réfutés.** Si un rapport d'audit existe encore à
   la racine, lis sa section « claims réfutées » : re-lever un finding déjà réfuté fait perdre
   du temps. Ces réfutations sont aussi consolidées dans `docs/PROJECT_MEMORY.md`.

---

## 3. LES 4 GARANTIES À PROUVER

- **G1 — ROBUSTESSE.** Aucune action utilisateur, dans aucun état (normal / suspend / pause /
  switch de layout / reload de config / poll updater / cold-start / first-boot), ne lève une
  exception non gérée, ne crashe, ni ne verrouille le clavier.
- **G2 — PAS D'OUTPUT MANQUANT.** Toute action qui DOIT produire un effet le produit. Aucun
  no-op silencieux : pas de clic de menu perdu, pas de hotstring qui ne s'expanse pas, pas de
  tap-hold avalé, pas de prédiction LLM jamais affichée, pas de feature à moitié suspendue.
- **G3 — PAS DE RACE.** Aucun bug d'ordonnancement entre producteurs asynchrones (hook clavier,
  InputHook, `SetTimer`, `OnMessage`, callbacks WinHttp, injection `SendInput`, reload de
  config). Toute mutation d'état partagé sur le hot path doit être atomique.
- **G4 — PAS DE LAG.** Aucune action n'introduit de latence perceptible. Aucun appel bloquant
  (shell, HTTP, `FileRead`, Registry, COM) sur le thread de frappe ou de menu.
  **G4 se prouve avec les logs de la §1, jamais par raisonnement seul.**

---

## 4. CATALOGUE DES CLASSES DE BUGS (spécifique AHK v2 + ce codebase)

### [A] Action → erreur / crash / clavier bloqué (G1)

- **`Map[k]` LÈVE une exception si `k` est absent** — exiger `.Has()` / `.Get(k, def)`. Idem
  `.Enabled` sur un non-objet, index de tableau hors bornes, `Integer()` / `Number()` /
  `RegExMatch` sur entrée inattendue.
- **`"0" = false` vaut TRUE en v2.** Ne jamais comparer un retour `String|false` à `false` ;
  type-checker avec l'opérateur `is String`.
- **Un `static` déclaré `:= unset` est illisible tant qu'il n'a pas été assigné.**
- **Tout appel OS non protégé** (`Send`/`SendInput`, `Hotkey`, `HotIf`, `InputHook`, WinHttp,
  COM, `FileRead`/`FileOpen`, `RegRead`, `DllCall`, `Run`) : sur un driver clavier, une
  exception non gérée peut verrouiller le clavier. Vérifie ce que le OnError global
  (`lib/crash_reporter.ahk`, `lib/error_net.ahk`) attrape RÉELLEMENT — notamment dans un
  callback `SetTimer`, un handler `OnMessage` et un callback `InputHook` — et s'il sort ou continue.
- **Encodage source :** tout `.ahk` doit être UTF-8 BOM + LF. Un mélange fait abandonner le
  parser EN SILENCE en milieu de fichier (du code disparaît, des tests ne s'enregistrent pas,
  aucun message). Vérifie les OCTETS, ne fais pas confiance à un décompte antérieur.
- **Échappement v2 :** backtick + guillemet pour un guillemet littéral. `""` est de la syntaxe
  v1 et provoque une erreur en v2.

### [B] Action → pas d'output / no-op silencieux (G2)

- **Drops du menu tray :** AHK 2.0 perd ~30-50 % des clics via son dispatcher interne. RÈGLE :
  tout item à callback réel DOIT passer par `RegisterMenuItem` (`lib/menu_dispatcher.ahk`),
  JAMAIS par un `Menu.Add(label, callback)` brut. Balaye tous les `.Add(` et `.Insert(` ; un
  `.Add` brut n'est acceptable que pour un séparateur, un sous-menu conteneur, ou un header désactivé.
- **Fuite suspend/pause :** `Suspend()` ne désarme QUE les hotkeys. `InputHook`, `SetTimer` et
  `OnMessage` le CONTOURNENT. Toute feature doit avoir un garde explicite `A_IsSuspended`. Une
  action qui « ne fait plus rien » après pause, ou une feature qui tourne encore sous pause,
  est un bug. Cherche aussi ce qui est démonté au suspend et JAMAIS remonté au resume : c'est
  une perte de feature définitive jusqu'au redémarrage.
- **Latch des préfixes custom-combination à travers Suspend.** *(État vérifié au 2026-07-20 —
  re-vérifie, cette zone bouge.)* L'implémentation actuelle n'est PLUS le `KeyWait("SC138","T1")`
  bloquant décrit dans les vieilles docs : `lib/lifecycle.ahk` utilise un poll de suspend
  différé non bloquant (`_SuspendPendingPoll`, 25 ms) généralisé sur
  `SUSPEND_CUSTOM_COMBO_PREFIX_KEYS := ["SC138", "SC038", "SC01D", "SC02A", "SC11D"]`.
  Questions à poser : que se passe-t-il si le poll n'observe JAMAIS la touche relâchée (touche
  physiquement coincée) ? Le nombre de polls est-il borné ? Quel état en cas de timeout ?
  Peut-on demander suspend deux fois pendant qu'un poll est en attente ? **L'utilisateur
  peut-il se retrouver incapable de dé-pauser au clavier ?** Une combo synthétique `{SC138 Up}`
  NE nettoie PAS le latch.
- **Hotstrings qui ne s'expansent pas :** le prefix-watcher InputHook capture l'input
  synthétique ; `OnChar` doit nourrir chaque caractère exactement une fois. Vérifie la
  précédence des délais (section > group > default) et la frontière de mot.
- **Invalidation par compteur de génération (LLM, tooltip) :** toute réponse async périmée doit
  se jeter elle-même. Cherche un callback qui vérifie sa génération à l'ENTRÉE, puis cède la
  main (`Sleep`, `SetTimer` imbriqué, appel COM), puis mute SANS re-vérifier.
- **Paires de cycle de vie :** tout `start`/`trace` sans `success`/`done` atteignable signale un
  échec silencieux. Deux façons de le chasser, fais les deux : statiquement dans le code, et
  **empiriquement dans les vrais logs** (un START sans SUCCESS dans le même run est une preuve
  observationnelle, bien plus forte qu'une lecture statique).

### [C] Race conditions (G3)

- **Updater :** interdiction absolue de WinHttp SYNCHRONE sur le thread principal. Pattern
  obligatoire : WinHTTP async + `WaitForResponse(0)` + poll `SetTimer`. Attention :
  `SetTimeouts` à 0 = **infini**, pas zéro.
- **`SetTimer(-1)` qui rend la main** pendant qu'un cold-start inonde la boucle de messages :
  l'opération cédée s'étale sur toute la fenêtre de warm-up (régression historique prouvée :
  +8 s sur le chunking de l'enregistrement emoji). Cherche toute boucle CPU découpée en
  `SetTimer`-yield.
- **Ré-entrance injection ↔ hook :** une rafale `SendInput` doit être atomique (`Critical`).
- **Spans `Critical` :** trop peu = race, trop = gel clavier de plusieurs secondes. Cherche les
  `Critical` qui englobent de l'I/O fichier, un rebuild, un appel HTTP ou COM. **Piège
  documenté :** un fix qui retire `Critical` d'une fonction peut être défait par un APPELANT
  qui la ré-enveloppe de l'extérieur.
- **Cycle de vie des timers :** tout handle armé non déclenché/non annulé fuite ; une
  réutilisation d'id peut évincer un handle vivant.
- **Reload de config pendant un dispatch :** la Map `Features` doit être échangée atomiquement.
  Les loaders/writers doivent prendre la Map cible en PARAMÈTRE explicite, jamais via `global`.

### [D] Lenteur / lag (G4)

- **Lis les VRAIS logs (§1) AVANT de théoriser.** Sans ligne de log à citer, G4 n'est pas mesuré.
- **Tooltip :** détruit + recrée deux fenêtres top-level à chaque update. `Tooltip.ResolvePos`
  est le pire segment mesuré (max 2560 ms). Un audit précédent avait RÉFUTÉ ce point en
  arguant que le double debounce (~225 ms) suffisait comme gate d'inactivité — **les logs
  réfutent la réfutation.** Cherche l'appel COM/UIA sans timeout : une app focalisée qui ne
  répond pas bloque le driver aussi longtemps qu'elle veut.
- Tout appel SYNCHRONE shell/HTTP/`FileRead`/`RegRead`/COM sur le thread de frappe ou de menu.
- Scans O(n) par frappe : l'enregistrement emoji/symbol (~3000 entrées) doit rester une sonde
  `Map` bornée par trigger. Cherche aussi ce qui grandit avec la session (un `lower()` sur tout
  le buffer à chaque frappe est O(n) par caractère).
- Allocation / recompilation de regex par frappe (ancre tes regex, cache les résultats).

### [E] Intégrité de la machine à états

- Construis la MATRICE état × action : { normal, suspend, pause, switch-layout, reload config,
  poll updater, cold-start, first-boot/onboarding } × { frappe lettre, AltGr+X, tap-hold,
  hotstring, geste, clic menu (tous niveaux, incl. sous-menus 3 niveaux), AltGr+Enter /
  BackSpace / Delete / Escape, toggle feature }. Pour CHAQUE cellule : quel output est attendu,
  et le code le garantit-il sans erreur/lag/latch ? **Rapporte les cellules CASSÉES, ne remplis
  pas le tableau pour le remplir.**
- Pattern d'init : init avant tout usage, garde anti-double-init, `require_state` sur chaque
  fonction publique dépendant d'un état injecté.

### [F] Dégâts collatéraux des fixes récents — **classe la plus rentable**

`docs/PROJECT_MEMORY.md` documente que le mode d'échec dominant de ce repo est
« invariant appliqué par site, avec UN site frère oublié », et que les tests de garde doivent
énumérer toute la CLASSE. Empiriquement, sur la campagne précédente, **3 fixes sur 47 ont
introduit un nouveau bug**, chacun livré avec un test de non-régression structurellement
AVEUGLE au dégât causé.

Audite donc systématiquement les commits de fix récents (`git log`, `git show`) :

- Le fix tient-il au site documenté mais rate-t-il un appelant FRÈRE ?
- La garantie est-elle défaite un niveau au-dessus par indirection (l'appelant ré-enveloppe) ?
- Rendre quelque chose DIFFÉRÉ a-t-il réordonné une opération qui la supposait synchrone
  (un « cancel » qui s'exécute avant que la chose à annuler soit armée) ?
- Un nouveau paramètre a-t-il une valeur codée en dur à un site d'appel, rendant l'option
  inatteignable ?
- Le test livré est-il scopé à UNE fonction alors que la garantie est transitive ? Si oui, le
  test est aveugle et la classe peut régresser en silence : **c'est un finding en soi.**

---

## 5. MÉTHODE

1. Cartographie chaque ENTRY POINT déclenchable par l'utilisateur (hotkey, hook, item de menu,
   geste, `InputHook` `OnChar`, `OnMessage`). Pour chacun, trace le chemin entrée → output.
2. Audite module par module, PUIS les flux end-to-end inter-modules : frappe → layout →
   hotstring → tooltip → LLM ; geste → action ; clic menu → callback ; suspend/pause →
   extinction de TOUTES les features ; reload config ; poll updater.
3. À chaque frontière asynchrone, pose les quatre questions : que se passe-t-il si ça fire
   DEUX FOIS ? DANS LE DÉSORDRE ? PENDANT un suspend ? AVANT l'init / APRÈS le teardown ?
4. **Boucle LOOP-UNTIL-DRY :** refais des passes jusqu'à ce qu'une passe entière ne trouve plus
   AUCUN nouveau bug. Note le numéro de passe où chaque zone est devenue « dry ». Une zone
   marquée « une passe propre, pas prouvée dry » est une dette : sur l'audit précédent, les
   trois zones ainsi marquées ont produit 18 findings confirmés à la passe suivante.
5. **Vérification adversariale de CHAQUE finding avant de le publier.** Posture par défaut : le
   finding est FAUX. Ouvre chaque `fichier:ligne` cité, cherche un test qui le contredit,
   vérifie que l'état de repro est réellement ATTEIGNABLE, et demande-toi s'il est déjà
   entièrement absorbé par un backstop (OnError global, gate fatal au boot, retry, self-heal).
   S'il est absorbé sans coût pour l'utilisateur : réfute-le.

### Outils

```bash
# Valider la syntaxe d'un fichier (exit 0 = clean)
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate <script>

# Lancer la suite ; le rapport TAP va dans %TEMP%\ergopti_test_results.txt, PAS sur stdout
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" static/ergopti_plus/windows/tests/run_all.ahk
```

Les fichiers `ui/` ne sont PAS dans `run_all.ahk` : leur seul gate de parsing est la compilation
`Ahk2Exe`. Valide-les explicitement.

**Avertissement outillage :** un hook shell réécrit le `grep` bash en proxy COMPACTANT qui
tronque et regroupe la sortie. Pour tout ce où la sortie exacte compte (analyse de logs,
comptage), utilise l'outil Grep dédié, ou `awk`/`perl`. Ne fais pas confiance au `grep` bash
pour une mesure.

---

## 6. DISCIPLINE DE PREUVE (anti-faux-positif)

- Chaque finding DOIT inclure une SÉQUENCE DE REPRO concrète (état initial + frappes/clics
  exacts). Pas de repro → classe-le en « suspecté », à part.
- Donne la CAUSE RACINE, pas le symptôme. Explique POURQUOI le bug est silencieux aujourd'hui
  (try qui avale, callback hors du file logger, parse abort…).
- Note SÉVÉRITÉ et CONFIANCE **séparément** (confirmé par lecture / probable / à vérifier en live).
- Ne sur-promets JAMAIS « le code est parfait ». Fournis un REGISTRE DE COUVERTURE : ce que tu
  as audité et BLANCHI (avec pourquoi c'est sûr), pour que l'absence de finding dans une zone
  signifie « audité », pas « ignoré ». Sois explicite sur les zones NON couvertes : le silence
  se lit comme « couvert ».

---

## 7. LIVRABLE

Écris UN fichier markdown à la racine du repo : `AUDIT_AHK_<YYYY-MM-DD>.md`.

**Si un fichier de ce nom existe déjà** (audit antérieur le même jour) : ne l'écrase pas en
silence. Soit tu suffixes (`AUDIT_AHK_<YYYY-MM-DD>_pass2.md`), soit tu demandes. Avant de
supprimer un audit ancien, reporte ses claims RÉFUTÉES dans `docs/PROJECT_MEMORY.md` — sinon
la passe suivante les re-lèvera.

Structure :

1. **Résumé exécutif** : nb de findings par sévérité, zones les plus fragiles, verdict global
   honnête. Indique ce que cette passe a fait que les précédentes n'avaient PAS fait.
2. **Findings**, triés par sévérité. Pour CHAQUE finding : ID, titre, sévérité, confiance,
   `fichier:ligne` ; garantie violée (G1/G2/G3/G4) ; séquence de repro ; cause racine + pourquoi
   c'est silencieux ; fix proposé (respectant les conventions du repo) ; **TEST DE NON-RÉGRESSION**
   encodant la CAUSE RACINE (pas le symptôme), échouant AVANT / passant APRÈS, avec le fichier
   cible et l'assertion exacte.
3. **Claims RÉFUTÉES** : ce que tu as investigué et rejeté, avec la raison. Évite à la passe
   suivante de refaire le travail.
4. **PERFORMANCE** : segments lents réels avec extraits de log cités (§1), appels bloquants sur
   le hot path, scans O(n) par frappe, coûts de boot. **Étiquette la provenance de chaque
   chiffre** : mesuré (avec la ligne de log) ou déduit du code.
5. **WATCH-LIST `PROJECT_MEMORY`** : pour chaque foot-gun connu — « fix toujours en place » /
   « régressé » / « même classe trouvée ailleurs » / « doc dérivée du code ».
6. **REGISTRE DE COUVERTURE** : tableau module × garantie, avec « audité-blanchi » / « finding » /
   « non couvert (pourquoi) » + le numéro de passe loop-until-dry où la zone est devenue dry.

---

## 8. CONTRAINTES

- Respecte `.github/copilot-instructions.md` (style, banners, logging, fail-fast). Lance
  `npm run fix:banners` avant tout commit.
- **Ne propose JAMAIS d'affaiblir ou de supprimer un test pour faire passer un changement.**
  Si un test existant contredit ton fix, c'est ton fix qui est probablement faux.
- Code / commentaires / logs en anglais ; rapport markdown en anglais (developer-facing).
- Prends le temps qu'il faut. La profondeur prime sur la vitesse. Mieux vaut 15 bugs prouvés
  avec repro + test qu'une liste de 50 suspicions vagues.
