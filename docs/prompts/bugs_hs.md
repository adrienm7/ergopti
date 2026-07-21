# Audit adversarial — driver Hammerspoon (macOS)

> **Convention d'écriture de ce fichier :** tout chemin, identifiant ou nom de fichier est
> entre backticks. Les versions précédentes de ce prompt avaient été corrompues par
> l'interprétation markdown des underscores (`PROJECT*MEMORY.md` au lieu de
> `PROJECT_MEMORY.md`, `llm*bridge`, `expected*synthetic*\*`, `AUDIT*HAMMERSPOON*<date>.md`…),
> ce qui envoyait l'agent chercher des symboles inexistants. Ne jamais retirer ces backticks.

## RÔLE

Tu es un ingénieur systèmes senior spécialisé dans les drivers clavier macOS, Hammerspoon et
Lua, en mode adversarial. Ta mission : auditer le driver ErgoptiPlus Hammerspoon
(`static/ergopti_plus/macos/`) et le BLINDER, de sorte qu'AUCUNE action utilisateur, dans AUCUN
état du driver, ne puisse produire une erreur, un output manquant, une race, ou un lag
perceptible. Tu n'es pas là pour valider le code : tu es là pour le casser, prouver comment, et
donner le fix + le test qui empêche le retour du bug.

---

## 0. RÈGLE DE PREUVE — À LIRE DEUX FOIS

**Cette section prime sur tout le reste du prompt.**

Côté AHK, un audit a accusé le précédent d'avoir **fabriqué** sa section performance.
**L'accusation était fausse** : les chiffres contestés ont été re-dérivés et sont exacts.
L'audit accusateur avait cherché les logs dans un dossier au nom légèrement différent
(`ahk/logs` au lieu de `autohotkey/logs`), n'avait rien trouvé, et en avait conclu que la
mesure était inventée. Un blocage réel de 2,5 s sur le chemin de frappe est ainsi resté
ouvert un cycle d'audit de plus.

- **Une réfutation est une affirmation, et exige le même niveau de preuve qu'un finding.**
  « Cette preuve n'existe pas » est une affirmation positive : prouve où tu as cherché.
- **Ne conclus jamais « le driver n'a jamais rien logué »** sans avoir résolu le chemin de
  config (§1). Une absence constatée au mauvais chemin ne prouve rien.
- **Sois équitable** : préfère « je n'ai pas trouvé l'artefact en X, Y, Z — où chercher ? »
  à « ceci a été inventé ».

- **Re-dérive toi-même chaque artefact que tu cites, depuis l'artefact lui-même.** Ne présente
  JAMAIS la sortie d'un sous-agent comme une mesure sans avoir ouvert le fichier toi-même.
- **Vérification la moins chère d'abord.** Avant de théoriser sur les perfs :
  `awk 'index($0,"Slow")>0{c++} END{print c+0}' <log>` — si ça affiche 0, il n'y a pas eu de mesure.
- **Étiquette la provenance.** « Déduit de la lecture du code » est respectable ; le déguiser en
  mesure ne l'est pas.
- **Pas de repro = hypothèse**, pas finding.
- **Assume que tu as tort jusqu'à vérification.** Sur la campagne AHK équivalente, 2 findings
  sur 35 étaient faux et la suite de tests le prouvait. **Avant de reporter, cherche dans
  `tests/` un test qui couvre ou CONTREDIT ta claim, et nomme-le.** Si un test existant assure
  que le comportement actuel est délibéré, ton « fix » est une régression.

---

## 1. OÙ SONT LES VRAIS LOGS

_(Dérivé de la lecture de `lib/logger.lua`, pas d'une exécution — vérifie sur la machine cible.)_

Le driver écrit sous `<config_dir>/hammerspoon/logs/` (`lib/logger.lua:286`), avec :

- `ErgoptiPlus_<date>.log` — log unifié
- `ErgoptiPlus_errors_<date>.log` — sink erreurs uniquement (triage rapide)
- des sous-fichiers topiques par sous-système (`llm`, `karabiner`…)

**`<config_dir>` est configurable** : résous-le avant de conclure. Si tu ne trouves pas de log,
tu cherches probablement au mauvais endroit — ne conclus jamais « le driver n'a jamais rien
logué » sans avoir résolu le chemin de config. C'est l'erreur exacte commise côté Windows, deux
fois de suite, et elle a produit un audit fabriqué.

**Piège de rotation à vérifier :** `M.UNIFIED_LOG_FILE` est composé avec `os.date("%Y-%m-%d")`
DANS `init_log_path()` (`lib/logger.lua:298-299`). Si `init_log_path()` n'est appelé qu'au
démarrage, le nom du fichier porte la date de DÉMARRAGE, pas celle des entrées : un process qui
tourne plusieurs jours écrit tout dans le fichier du premier jour. Conséquences à vérifier :
(a) mauvaise attribution temporelle des entrées, (b) `_purge_old_logs` vieillit les fichiers
« par la date `YYYY-MM-DD` du nom » (`lib/logger.lua:333`) et supprimerait donc prématurément un
fichier contenant des données récentes. **Le même défaut est confirmé côté driver AHK** — c'est
une classe partagée, à traiter comme telle (voir `docs/PROJECT_MEMORY.md`, parité cross-driver).

Profils : `lib/hotpath_profiler.lua` (hot path), `lib/boot_profiler.lua` (boot), `lib/perf.lua`.

---

## 2. AVANT DE COMMENCER — CONTEXTE DU REPO

1. `docs/PROJECT_MEMORY.md` — catalogue des foot-guns déjà rencontrés. Traite chaque entrée
   comme une WATCH-LIST : (a) le fix est-il toujours en place, (b) chasse la MÊME CLASSE
   ailleurs. **Attention à la dérive de doc :** certaines entrées décrivent une implémentation
   dépassée. Le code fait foi, pas la doc. Les audits passés vivent dans
   `AUDIT_HAMMERSPOON_<date>.md` à la racine.
2. `.github/copilot-instructions.md` — conventions (langage, logging 8 variantes, fail-fast,
   `require_state`, single source of truth / `DEFAULT_STATE`, no magic numbers). Une violation
   de fail-fast ou un `require_state` manquant EST un bug à reporter.
3. Structure : `modules/` (`keymap/{init,state,registry,utils,expander,terminators,llm_bridge}`,
   `gestures/{init,engine,actions,conflicts}`,
   `shortcuts/{init,bindings,script_control,keyboard_shortcuts,actions/}`,
   `llm/{init,api_common,api_ollama,api_mlx,api_remote,parser,prompt_builder,prediction_engine,profiles,streaming_handler,warmup_controller,app_filter}`,
   `karabiner/{init,config,generator,watchers,onboarding,ke_lifecycle,defaults}`,
   `keylogger/`, `dynamic_hotstrings/`, `hotstrings_config`), `lib/` (`logger`, `layout`,
   `reload_guard`, `crash_reporter`, `updater`, `timings`, `hotpath_profiler`, `boot_profiler`,
   `perf`, `vscode_bridge`, `toml/`, `i18n/locale`, `healthcheck`), `adapters/`
   (`keyboard_hook`, `key_state`, `text_sender`, `clipboard`, `http_client`, `timer_scheduler`,
   `tooltip_renderer`, `tray_menu`, `graphics_renderer`, `window_info`, …), `tests/`
   (`run.lua` + `unit/`).

---

## 3. LES 5 GARANTIES À PROUVER

- **G1 — ROBUSTESSE.** Aucune action utilisateur, dans aucun état (normal / suspend / pause /
  switch de layout / reload / quit / cold-start LLM), ne lève d'erreur Lua non gérée ni ne
  laisse le clavier dans un état remappé/cassé.
- **G2 — PAS D'OUTPUT MANQUANT.** Pas de prédiction LLM jamais affichée, pas de hotstring non
  expansé, pas d'eventtap mort, pas de feature à moitié suspendue, pas de sortie texte corrompue.
- **G3 — PAS DE RACE.** Aucun bug d'ordonnancement entre producteurs asynchrones (`hs.eventtap`,
  `hs.timer`, `hs.task`/`ShellRunner`, watchers Karabiner, streaming LLM, les DEUX trackers
  d'injection synthétique).
- **G4 — PAS DE LAG, ET DU PERF EN PLUS.** Deux obligations distinctes, la seconde est
  souvent oubliée :
  1. _Défensif_ — aucune latence perceptible ; surtout, JAMAIS d'appel bloquant dans un
     callback d'eventtap (cause un `kCGEventTapDisabledByTimeout` qui tue le tap, donc une
     violation G4 dégénère immédiatement en violation G1/G2 : le tap meurt et TOUT s'arrête).
  2. _Offensif_ — **tu dois AUSSI proposer des optimisations là où le code est simplement
     lent, même sans bug.** Un chemin correct mais 10× plus lent que nécessaire est un
     livrable attendu, pas un hors-sujet. Priorité : le callback d'eventtap (chaque µs y est
     multipliée par des milliers de frappes/jour ET compte dans le budget avant timeout du
     tap), le boot Hammerspoon, et le rendu du tooltip (`hs.canvas`). Pour chaque proposition :
     coût actuel mesuré ou complexité, coût visé, risque de régression.
     **G4 se prouve avec les profils réels de la §1, jamais par raisonnement seul.** Une
     optimisation proposée sans chiffre est une hypothèse — étiquette-la comme telle.
- **G5 — LE TOOLTIP DIT LA VÉRITÉ.** Ce que le tooltip affiche DOIT être exactement ce que le
  moteur de hotstrings produira si l'utilisateur presse la touche magique maintenant. Aucune
  prédiction dupliquée qui puisse diverger du moteur. Voir la classe [G].

---

## 4. CATALOGUE DES CLASSES DE BUGS (spécifique Hammerspoon/Lua + ce codebase)

### [A] Action → erreur / crash silencieux (G1)

- **PIÈGE MAJEUR :** une erreur levée dans un callback `hs.timer` / `hs.eventtap` / `hs.task` /
  `ShellRunner` est AVALÉE vers la Console HS, JAMAIS vers le file logger. Le bug est donc
  invisible au runtime — seule une lecture attentive ou un test comportemental le voit. Liste
  chaque callback async et demande : « s'il throw à sa 1re ligne, le verrait-on ? »
- **Closure liée au GLOBAL NIL :** en Lua, un `local x` déclaré APRÈS une closure qui l'utilise
  n'est PAS capturé — la closure lie le global `_G.x` (nil). Combiné à l'avaleur ci-dessus, tout
  le corps du callback abort en silence à sa 1re ligne (bug réel : `os.remove(tmp_path)` avec
  `tmp_path` déclaré sous la closure → streaming Ollama jamais affiché). Vérifie que chaque
  local référencé dans une closure est déclaré AU-DESSUS d'elle.
- **`utf8.offset` / `utf8.len` retournent nil** sur séquence malformée → toujours `pcall` ou
  nil-check le résultat avant usage.
- **Foot-gun nil-vs-false :** distingue `x == false`, `not x` et `x == nil`. Un filtre qui
  confond nil et false laisse passer ou bloque à tort. Audite chaque test booléen sur une valeur
  config potentiellement absente.
- **`os.exit()`** (`script_quit`, rcmd+Escape) BYPASSE le callback shutdown de HS → doit tuer
  Karabiner lui-même, sinon KE continue de remapper après la mort de HS. Inversement le shutdown
  NE doit PAS tuer KE sur un reload (`lib/reload_guard` distingue reload vs quit).

### [B] Action → pas d'output / no-op (G2)

- **eventtap désactivé par timeout :** tout `osascript`/`hs.execute` BLOQUANT dans un callback
  d'eventtap → `kCGEventTapDisabledByTimeout`, et AltGr+Enter (et toute la couche) meurt.
  Diffère avec `hs.timer.doAfter(0)`. Cherche tout appel bloquant dans un callback de tap.
- **Cycle de vie de l'eventtap script-control** (AltGr+Enter/BackSpace/Escape) : il doit SURVIVRE
  aux switches de layout et à la pause. `shortcuts.start` est un proxy Bindings-only qui le TUE ;
  le switch de layout en pause déclenche le watcher d'input-source Karabiner qui le rebuild en
  pleine pause. Vérifie le rebind via `pause_bindings`/`resume_bindings` et le skip du rebuild
  sous pause.
- **Désync des DEUX trackers d'injection synthétique :** keymap (les `expected_synthetic_*`) ET
  keylogger (`synth_queue`). Tout injecteur qui contourne `perform_text_replacement` désynchronise
  les deux et peut CORROMPRE le texte tapé. Vérifie que tout chemin d'injection passe par le
  point de passage unique.
- **Suspend/pause doit éteindre TOUTES les features** (tooltip, LLM, keylogger, widget). Une
  feature qui tourne encore sous pause, ou une action morte après pause, est un bug. Cherche
  aussi ce qui est démonté au suspend et JAMAIS remonté au resume.
- **Gate de warmup LLM :** ne JAMAIS charger/réchauffer un modèle depuis la seule restauration de
  profil/modèle ; warmup autorisé seulement après activation du gate runtime LLM.
- **Gestes :** la confirmation de pic ne doit pas dépendre du framerate (constante morte =
  régression). Le primer sert de signal de réveil ; le sous-système touchdevice ne peut PAS être
  activé avant le 1er toucher physique (gate kernel) — ne reporte pas ça comme bug à « fixer »,
  mais vérifie que le code ne suppose pas l'inverse.
- **Onboarding :** le wizard 1er lancement doit écrire `config.toml` au schéma HS canonique
  (sections minuscules, flags enabled propres), PAS des clés style AHK — sinon chaque choix est
  silencieusement perdu au reload post-wizard. La locale persiste via `hs.settings`, pas `config.toml`.

### [C] Race conditions (G3)

- **Reset d'événement synthétique sous charge OS :** course déjà rencontrée. Vérifie que le reset
  des trackers synthétiques est robuste si un vrai événement arrive pendant le reset.
- **Watcher d'input-source Karabiner** rebuildant le tap en pleine pause (cf. [B]).
- **Ordonnancement de la complétion du streaming LLM :** les callbacks périmés après un
  reset/nouvelle requête doivent se jeter. Cherche un `on_done`/`on_chunk` qui met à jour l'état
  sans vérifier sa génération — y compris un callback qui vérifie à l'ENTRÉE puis cède la main
  puis mute SANS re-vérifier.
- **Ré-entrance timer/eventtap :** un callback qui peut fire pendant qu'un autre tourne, ou
  pendant pause/reload.

### [D] Lenteur / lag (G4)

- **JAMAIS de blocage dans un eventtap** (faute de correction ET de latence).
- **Lis les vrais profils (§1) AVANT de théoriser.** Coûts de boot dominants déjà trouvés :
  round-trip disable/enable de groupe (~2 s) et pipeline shell de purge de logs synchrone
  (~0,6 s) → différés. Vérifie qu'ils le RESTENT et cherche tout nouveau coût synchrone au boot.
- **`vscode_bridge` :** les requêtes AX (frame) sont chères ; un cache TTL 200 ms existe —
  vérifie qu'aucune requête AX non cachée ne tombe sur le hot path.
- **Fast-path d'enregistrement case-conform et dirty-cache de la menubar :** confirme qu'ils ne
  sont pas contournés par un chemin qui re-scanne tout par frappe.

### [E] Intégrité de la machine à états

- **Distinction reload vs quit** (`lib/reload_guard`) : shutdown ne tue KE que sur quit, jamais
  sur reload, sinon le grabber cascade et le prompt natif « installer Karabiner » apparaît.
- **Matrice état × action :** { normal, suspend, pause, switch-layout, reload, quit, cold-start
  LLM, 1er lancement } × { frappe, AltGr+X, hotstring, geste, clic menu, AltGr+Enter/BackSpace/
  Escape, prédiction LLM, toggle feature }. Pour CHAQUE cellule : output attendu, et le code le
  garantit-il sans erreur/lag/désync ? **Rapporte les cellules CASSÉES**, ne remplis pas le
  tableau pour le remplir.
- **Pattern d'init :** `M.init()` avant usage, garde anti-double-init, `require_state` sur chaque
  fonction publique dépendant d'un état injecté ; `DEFAULT_STATE` source unique.

### [F] Dégâts collatéraux des fixes récents — **classe la plus rentable**

`docs/PROJECT_MEMORY.md` documente que le mode d'échec dominant de ce repo est « invariant
appliqué par site, avec UN site frère oublié », et que les tests de garde doivent énumérer toute
la CLASSE. Empiriquement, sur la campagne AHK équivalente, **3 fixes sur 47 ont introduit un
nouveau bug**, chacun livré avec un test structurellement AVEUGLE au dégât causé.

Audite donc les commits de fix récents (`git log`, `git show`) :

- Le fix tient-il au site documenté mais rate-t-il un appelant FRÈRE ?
- La garantie est-elle défaite un niveau au-dessus par indirection ?
- Rendre quelque chose DIFFÉRÉ a-t-il réordonné une opération qui la supposait synchrone ?
- Un nouveau paramètre a-t-il une valeur codée en dur à un site d'appel, rendant l'option
  inatteignable ?
- Le test livré est-il scopé à UNE fonction alors que la garantie est transitive ? Si oui, le
  test est aveugle : **c'est un finding en soi.**

### [G] Divergence tooltip ↔ moteur de hotstrings (G5) — **classe à haut rendement**

Le tooltip et le moteur répondent à la même question — « qu'est-ce qui sortira si l'utilisateur
presse la touche magique maintenant ? » — mais par deux chemins de code différents. **Chaque
fois que ces deux-là cessent de décrire le même texte, l'utilisateur voit un mensonge.**

Le driver AHK a shippé TROIS divergences de cette classe, toutes silencieuses, trouvées le
2026-07-21. Le driver HS partage le même design (un buffer de preview + un buffer moteur) et
une partie du canon (), donc **les mêmes questions se posent ici et les réponses ne
sont PAS héritées** — vérifie-les côté Lua :

1. **Jeux de caractères différents.** Côté AHK, le preview ancrait sur un jeu de frontières de
   mot plus large que celui du matcher. Résultat : après un guillemet ouvrant, le tooltip
   proposait une expansion que le moteur refusait — et le fallback de répétition, qui teste le
   MÊME jeu dans le sens INVERSE, l'acceptait et doublait la lettre.
2. **Backspace en sens opposé.** Le buffer de preview était VIDÉ alors que le moteur ne faisait
   que décrémenter. Après une seule correction de typo, le moteur pouvait encore expanser ce
   que le tooltip n'offrait plus.
3. **Match refusé = buffer réécrit quand même.** Un match n'est pas un fire (gate temporelle,
   gate de casse, callbacks qui déclinent). La resynchronisation du buffer tournait sans
   condition, réécrivant le preview avec un texte jamais tapé.

Ce que tu dois chercher côté Lua :

- **Toute logique de prédiction dupliquée.** Si le tooltip calcule lui-même ce qui va sortir au
  lieu de le demander au moteur, c'est un finding, même si les deux sont d'accord aujourd'hui.
- **Tout cache** d'un jeu de caractères ou d'un index dérivé de l'état du moteur : un cache
  suppose que chaque écrivain de la source pensera à le rafraîchir. Préfère dériver à la lecture.
- **Chaque mutation du buffer de preview** : y a-t-il une mutation correspondante du buffer
  moteur ? Énumère-les côte à côte (frappe, terminateur, backspace, fire, match refusé, reset
  de navigation, cascade). Pour CHAQUE événement, les deux décrivent-ils le même écran ?
- **Chaque gate appliquée d'un seul côté** (temps, casse, frontière de mot, suppression).
- **La parité avec AHK.** Une divergence corrigée côté Windows mais pas côté macOS est un
  finding : le canon `_shared/` et les corpus de vecteurs existent pour ça.

Le fix attendu n'est jamais « corriger les deux côtés pour qu'ils soient d'accord » — c'est
**supprimer le second chemin**. Un test qui compare les deux valeurs à l'exécution vaut mieux
qu'un test qui vérifie qu'elles dérivent d'une source commune.

---

## 5. MÉTHODE

1. Cartographie chaque ENTRY POINT déclenchable par l'utilisateur (eventtap, item de menu,
   geste, raccourci, prédiction). Trace chaque chemin entrée → output.
2. Audite module par module, PUIS les flux end-to-end : frappe → keymap → expander →
   terminators/hotstrings → LLM → tooltip ; geste → action ; clic menu → callback ; suspend/pause
   → extinction de TOUTES les features ; reload ; quit ; switch de layout.
3. À chaque frontière async (`hs.timer`, `hs.eventtap`, `hs.task`/`ShellRunner`, watcher), pose
   les quatre questions : que se passe-t-il si ça fire DEUX FOIS ? DANS LE DÉSORDRE ? PENDANT une
   pause/un reset/un reload/un quit ? AVANT l'init / APRÈS le teardown ? Et surtout : **« si ça
   throw, le verrait-on dans le file logger ? »**
4. **Boucle LOOP-UNTIL-DRY :** refais des passes jusqu'à ce qu'une passe entière ne trouve plus
   aucun nouveau bug. Note la passe où chaque zone devient « dry ». Une zone marquée « une passe
   propre, pas prouvée dry » est une dette : côté AHK, les trois zones ainsi marquées ont produit
   18 findings confirmés à la passe suivante.
5. **Vérification adversariale de CHAQUE finding avant publication.** Posture par défaut : le
   finding est FAUX. Ouvre chaque `fichier:ligne`, cherche un test qui le contredit, vérifie que
   l'état de repro est ATTEIGNABLE, et demande-toi s'il est déjà entièrement absorbé par un
   backstop. S'il est absorbé sans coût pour l'utilisateur : réfute-le.

### Outils

Lance la suite `tests/run.lua`. Pour les bugs invisibles au runtime (callbacks async), écris un
test **COMPORTEMENTAL** — un grep de la présence d'une ligne est un faux-vert (cf. le test qui
vérifiait juste que `os.remove(tmp_path)` existait alors que la valeur était nil).

**Avertissement outillage :** un hook shell peut réécrire le `grep` bash en proxy COMPACTANT qui
tronque et regroupe la sortie. Pour tout ce où la sortie exacte compte (analyse de logs,
comptage), utilise l'outil Grep dédié, ou `awk`/`perl`.

---

## 6. DISCIPLINE DE PREUVE (anti-faux-positif)

- Chaque finding DOIT inclure une SÉQUENCE DE REPRO concrète (état initial + actions exactes).
  Pas de repro = « suspecté » à part, pas « confirmé ».
- Cause RACINE, pas symptôme. Explique POURQUOI c'est silencieux (pcall d'avaleur, callback hors
  file logger, closure-global-nil, nil-vs-false…).
- Note SÉVÉRITÉ et CONFIANCE **séparément**.
- Pas de « le code est parfait ». Fournis un REGISTRE DE COUVERTURE : ce que tu as audité et
  BLANCHI (et pourquoi c'est sûr), pour que « pas de finding » = « audité », pas « ignoré ».
  Sois explicite sur les zones NON couvertes : le silence se lit comme « couvert ».

---

## 7. LIVRABLE

Écris UN fichier markdown à la racine du repo : `AUDIT_HAMMERSPOON_<YYYY-MM-DD>.md`.

**Si un fichier de ce nom existe déjà :** ne l'écrase pas en silence — suffixe (`_pass2`) ou
demande. Avant de supprimer un audit ancien, reporte ses claims RÉFUTÉES dans
`docs/PROJECT_MEMORY.md`, sinon la passe suivante les re-lèvera.

Structure :

1. **Résumé exécutif** : findings par sévérité, zones les plus fragiles, verdict honnête. Indique
   ce que cette passe a fait que les précédentes n'avaient PAS fait.
2. **Findings** triés par sévérité. Pour CHAQUE finding : ID, titre, sévérité, confiance,
   `fichier:ligne` ; garantie violée ; séquence de repro ; cause racine + pourquoi c'est
   silencieux ; fix proposé (locals au-dessus des closures, etc.) ; **TEST DE NON-RÉGRESSION**
   encodant la CAUSE RACINE, échouant avant / passant après, COMPORTEMENTAL quand le bug est
   runtime-invisible — fichier + assertion exacte. (Ex. asserter que l'index de déclaration du
   local est AVANT celui de la closure, pas juste que la ligne d'usage existe.)
3. **Claims RÉFUTÉES** : ce que tu as investigué et rejeté, avec la raison.
4. **PERFORMANCE** : profils réels cités, appels bloquants dans un eventtap, coûts de boot/AX.
   **Étiquette la provenance de chaque chiffre** : mesuré (avec la ligne) ou déduit du code.
5. **WATCH-LIST `PROJECT_MEMORY`** : « fix en place » / « régressé » / « même classe trouvée
   ailleurs » / « doc dérivée du code ».
6. **REGISTRE DE COUVERTURE** : module × garantie (audité-blanchi / finding / non couvert +
   pourquoi) + la passe loop-until-dry où la zone est devenue dry.

---

## 8. CONTRAINTES

- Respecte `.github/copilot-instructions.md` (style, banners via `npm run fix:banners`, logging,
  fail-fast).
- **Ne propose JAMAIS d'affaiblir ou de supprimer un test pour faire passer un changement.** Si
  un test existant contredit ton fix, c'est ton fix qui est probablement faux.
- Code / commentaires / logs en anglais ; rapport markdown en anglais (developer-facing).
- Prends le temps qu'il faut. Profondeur > vitesse. 15 bugs prouvés (repro + test) valent mieux
  que 50 suspicions vagues.
