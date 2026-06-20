# Audit Hammerspoon (macOS) — bugs, races & corrections

> Audit exhaustif du driver **Hammerspoon / macOS** d'Ergopti+
> (`static/ergopti_plus/macos/` + shared Lua `static/ergopti_plus/_shared/lua/`).
> Périmètre : moteur de remap/hotstrings (`modules/keymap`), keylogger
> (`modules/keylogger`), hotstrings dynamiques (`modules/dynamic_hotstrings`),
> LLM, tooltip, gestes/raccourcis, adaptateurs.
> **Le driver AHK/Windows et tout `static/drivers/` ont été volontairement
> ignorés** (audit en parallèle). Aucun fichier n'a été modifié — ce document
> est le seul livrable.

**Méthodo.** 14 auditeurs ont analysé le code module par module *et* en
end‑to‑end (keylogger + hotstrings ensemble, injection synthétique,
interleaving frappe utilisateur/synthétique). Chaque constat a ensuite été
**vérifié de façon adverse** par un agent indépendant (réfutation par défaut) :
**37 confirmés, 5 réfutés**. Après déduplication des constats redondants, il
reste **~30 problèmes distincts** ci‑dessous. Chaque entrée donne : symptôme,
emplacement, cause racine, reproduction, **correctif** et **test de
non‑régression** (calé sur le harnais `tests/run.lua` + `tests/e2e/run_e2e.lua`).

---

## 0. Résumé exécutif

Le risque « `triggerabcd` → `outpuabtcd` / `outputbcd` » est **réel et localisé**,
mais **pas** dans le moteur d'expansion standard (`expander.perform_text_replacement`),
qui est correct : il arme `expected_synthetic_deletes`/`expected_synthetic_chars`,
notifie le keylogger, resynchronise le buffer — c'est le **point de passage de
référence**.

Le danger vient des **injecteurs qui contournent ce point de passage** :

1. **`dynamic_hotstrings/rules_engine`** émet ses backspaces+texte **sans**
   `suppress_rescan`, **sans** armer les compteurs synthétiques, **sans**
   notifier le keylogger → le buffer du moteur se désynchronise, le texte
   réinjecté peut **re‑déclencher une expansion** (corruption type `outputbcd`),
   et l'injection différée (`doAfter(0)` + flag 0,15 s) ouvre une fenêtre
   d'**interleaving** avec la frappe réelle (type `outpuabtcd`).
2. **`personal_info`** appelle bien `suppress_rescan` (donc le moteur est
   protégé) mais **ne notifie pas le keylogger** → vos données perso
   (IBAN/SSN/téléphone) sont enregistrées comme frappe humaine (fuite + WPM faussé).
3. **`llm_bridge.apply_prediction`** saute la notif keylogger sur le chemin
   *paste* (prédiction > 50 caractères).

**Recommandation transverse n°1 (corrige A1‑A5, A7 d'un coup) :** exposer un
**point d'injection unique** `keymap.inject_replacement(deletes, text, variant)`
qui encapsule toute la comptabilité de `perform_text_replacement`
(armer compteurs + `suppress_rescan` + `notify_synthetic` + resync buffer), et
**router *tous* les injecteurs** (`rules_engine`, `personal_info`, LLM, futurs)
à travers lui. C'est la correction architecturale prioritaire.

### Décompte par sévérité (constats distincts)

| Sévérité | Nb | Exemples |
|---|---|---|
| **HIGH** | 11 | rules_engine désync (A1), keylogger non silencieux en pause (C1), pas de watchdog keylogger (C2), double‑agrégation minuit (C3), data.sql dupliqué (C4), actions modificateur mortes (G1), Ollama sans timeout (D1), clipboard écrasé (CLIP) |
| **MEDIUM** | 8 | buckets périmés après `disable_group` (B1), F16 mort (D2), synth_queue sans reset (C5), tooltip empilé persistant (E1/E2), `show_tooltip` jamais relu (F1) |
| **LOW** | 11 | paste desync (A5), reset chaîne (D3), terminateur re‑tapé (A7), etc. |
| **Dormant (port layer)** | 4 | `secure_field_detector`, `keyboard_hook`, `key_state` (non câblés dans le chemin macOS live) |

---

## 1. Injection synthétique — le cœur du risque « triggerabcd »

### A1 — [HIGH] `rules_engine` n'appelle pas `suppress_rescan` et n'arme pas les compteurs synthétiques → désync buffer + ré‑expansion

*(Constats fusionnés : `rules-engine-no-suppress-rescan-double-expansion`,
`dynhs-rules-no-synth-tracking`, `rules-engine-no-synthetic-bookkeeping`.)*

- **Où :** [rules_engine.lua:93‑124](static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua#L93-L124), à comparer à [personal_info.lua:240‑242](static/ergopti_plus/macos/modules/dynamic_hotstrings/personal_info.lua#L240-L242) et au point de passage de référence [expander.lua:75‑123](static/ergopti_plus/macos/modules/keymap/expander.lua#L75-L123).
- **Cause racine :** l'interceptor consomme le caractère déclencheur (`return "consume"`) puis, dans `hs.timer.doAfter(0, …)`, émet `n_back` `keyStroke("delete")` bruts + `emit_text(result)`. Contrairement à `perform_text_replacement` et à `personal_info`, il **n'incrémente jamais** `CoreState.expected_synthetic_deletes`, **n'ajoute jamais** `result` à `expected_synthetic_chars`, et **n'appelle jamais** `_km.suppress_rescan()`.
- **Conséquences** (les évènements synthétiques re‑traversent le tap clavier du moteur) :
  1. chaque `delete` synthétique tombe dans le handler backspace réel ([init.lua:619‑642](static/ergopti_plus/macos/modules/keymap/init.lua#L619-L642), le garde `expected_synthetic_deletes > 0` est faux) et **rogne le buffer réel** au‑delà du suffixe ;
  2. chaque caractère de `result` est ajouté au buffer ([init.lua:685](static/ergopti_plus/macos/modules/keymap/init.lua#L685)) et passé à `run_trigger_checks` (`no_rescan_until == 0` ⇒ pas de suppression) — si une portion de `result` forme un trigger `auto_expand` (les préfixes téléphone/SSN/IBAN générés par `register_prefix_entries` partagent par construction un préfixe avec le résultat), une **seconde expansion se déclenche en plein milieu**, laissant un texte faux à l'écran.
- **Repro :** `phone_number = "0612345678"` (⇒ mapping auto `"0612" → "0612345678"`). Taper un suffixe dynamique résolvant vers le téléphone puis ★ : la frappe différée tape `0612345678` ; dès que `0612` est dans le buffer, le mapping auto re‑tire, backspace + re‑tape → sortie corrompue + buffer désynchronisé.
- **Correctif :** router l'injection via le point d'injection unique recommandé en §0 ; *a minima*, avant la boucle de delete : `_km.suppress_rescan()` (comme `personal_info`) **et** armer les compteurs (`expected_synthetic_deletes += n_back`, `expected_synthetic_chars ..= result`) **et** `keylogger.notify_synthetic(result, "hotstring", n_back, "dynamic")`.
- **Test :** `tests/unit/modules/dynamic_hotstrings/test_rules_engine_sync.lua`. Charger `rules_engine` avec un faux `_km` capturant `register_interceptor`/`suppress_rescan`/compteurs + un keylogger espion. Enregistrer un mapping auto chevauchant, piloter l'interceptor sur un buffer qui matche une règle, exécuter le callback `doAfter(0)` (le stub `hs.timer` l'enregistre), puis asserter : (a) `suppress_rescan` appelé **avant** l'émission, (b) `expected_synthetic_deletes` incrémenté de `n_back`, (c) aucune expansion imbriquée (pas de `delete` au‑delà de `n_back` dans `hs.eventtap.__keystrokes`). Échoue aujourd'hui.

### A2 — [HIGH] Les injecteurs dynamiques (`rules_engine` + `personal_info`) n'appellent jamais `keylogger.notify_synthetic` → fuite de données + WPM faussé

*(Constats fusionnés : `dynhotstrings-keylogger-desync`, `personal-info-keylogger-desync`, `dynamic-and-personal-injection-not-notified-to-keylogger`, `rules-engine-keylogger-synth-desync`.)*

- **Où :** [rules_engine.lua:89‑108](static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua#L89-L108), [personal_info.lua:232‑270](static/ergopti_plus/macos/modules/dynamic_hotstrings/personal_info.lua#L232-L270) ; canal keylogger : [keylogger/init.lua:546‑571](static/ergopti_plus/macos/modules/keylogger/init.lua#L546-L571) (consommation `synth_queue`) et [1070‑1102](static/ergopti_plus/macos/modules/keylogger/init.lua#L1070-L1102) (`notify_synthetic`).
- **Cause racine :** le keylogger est un tap **indépendant** ; il ne sait qu'un évènement est synthétique que via `synth_queue`, alimenté *uniquement* par `notify_synthetic`. Le moteur standard l'appelle ([expander.lua:95‑97](static/ergopti_plus/macos/modules/keymap/expander.lua#L95-L97)) ; les deux injecteurs dynamiques **non** (ils n'appellent que `log_hotstring`, voire rien). `synth_queue` reste vide ⇒ chaque backspace injecté est compté comme correction humaine et chaque caractère du résultat (adresse, **IBAN, SSN, téléphone, n° carte**) est enregistré comme frappe humaine (buffer_text, n‑grammes, fenêtres WPM, dict caractères).
- **Impact :** atteinte à la vie privée (données perso loguées en clair, taggées humaines) + WPM/statistiques corrompus.
- **Correctif :** appeler `keylogger.notify_synthetic(<texte émis>, "hotstring", n_back, "dynamic"/"personal")` **avant** d'émettre, dans chaque injecteur (pour `personal_info`, inclure les `\t` séparateurs). Idéalement : point d'injection unique (§0).
- **Test :** étendre `test_rules_engine_sync.lua` (+ variante personal_info) avec un keylogger espion ; asserter `notify_synthetic` appelé une fois avec `deletes == n_back` et `text == result`, **avant** tout `keyStroke` delete. Échoue aujourd'hui.

### A3 — [MEDIUM] Injection différée (`doAfter(0)` + flag 0,15 s) : fenêtre d'interleaving avec la frappe réelle

- **Où :** [rules_engine.lua:66‑124](static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua#L66-L124), [personal_info.lua:232‑270 / 343‑378](static/ergopti_plus/macos/modules/dynamic_hotstrings/personal_info.lua#L343-L378).
- **Cause racine :** l'interceptor `return "consume"` de façon synchrone mais **planifie** les deletes+emit sur un tour de runloop ultérieur (`doAfter(0)`) et ne relâche `_is_injecting`/`_replacing` que 0,15 s plus tard. Ces flags ne gèlent **pas** la file d'évènements OS : toute touche physique pressée entre le `consume` et la fin de l'injection s'**intercale** avec la rafale delete/insert — c'est exactement le mode `outpuabtcd`.
- **Repro :** taper `td` puis ★, puis immédiatement `x` (avant que le callback `doAfter(0)` ne s'exécute) : le `x` peut atterrir avant les 2 deletes synthétiques, qui suppriment alors `x` et `d` au lieu de `t` et `d`.
- **Correctif :** émettre **synchronement** dans l'interceptor (le chemin terminateur de `expander` le fait déjà sans risque — cf. commentaire [expander.lua:400‑403](static/ergopti_plus/macos/modules/keymap/expander.lua#L400-L403) : `CGEventPost` non‑bloquant). Si un report est inévitable, consommer (`"consume"`) toute touche reçue tant que l'injection est en cours, et borner la fenêtre à la durée réelle d'émission (pas 0,15 s fixe). À combiner avec A1.
- **Test :** dans le harnais (stub `hs.timer` déterministe), simuler une frappe utilisateur `x` arrivant entre le `consume` et l'exécution du callback différé ; asserter que la séquence résultante n'est pas entrelacée. Échoue tant que l'injection est différée et que l'interceptor laisse passer les touches intermédiaires.

### A4 — [HIGH] `apply_prediction` (LLM) : le chemin *paste* saute `notify_synthetic`, donc les backspaces ne sont pas mis en file côté keylogger

- **Où :** [llm_bridge.lua:660‑666](static/ergopti_plus/macos/modules/keymap/llm_bridge.lua#L660-L666), [utils.lua:144‑154](static/ergopti_plus/macos/modules/keymap/utils.lua#L144-L154).
- **Cause racine :** pour une complétion > `PASTE_THRESHOLD` (50 codepoints — banal pour une phrase), `emit_text` colle via Cmd+V et renvoie `(1, "")`. La notif keylogger est gardée par `if emitted_str ~= "" then …` ⇒ sur le chemin paste, `notify_synthetic` **n'est jamais appelé**, alors que `delete_count` backspaces ont bien été émis (le moteur, lui, est correct car `expected_synthetic_deletes` est armé inconditionnellement). Les `delete_count` backspaces echos sont loggés comme corrections humaines et dépilent le buffer keylogger.
- **Correctif :** découpler la notif de `emitted_str` : `if delete_count > 0 or emitted_str ~= "" then keylogger.notify_synthetic(emitted_str, "llm", delete_count, nil, deleted_text) end` (comme `perform_text_replacement`, qui notifie toujours les deletes).
- **Test :** `tests/unit/modules/keymap/test_llm_bridge.lua` — stuber `emit_text` pour renvoyer `(1,"")` (branche paste) et `engine.consume(1)` pour renvoyer `{deletes=3, to_type=("x"):rep(60)}` ; asserter `notify_synthetic` appelé une fois avec `deletes==3`. Échoue aujourd'hui.

### A5 — [LOW] Chemin *paste* (emoji ou > 50 car.) : `expected_synthetic_chars` reste vide → buffer effacé par le Cmd+V echo

*(Constats fusionnés : `paste-path-synth-desync`, `paste-path-emitted-empty-bs-queued`.)*

- **Où :** [utils.lua:136‑160](static/ergopti_plus/macos/modules/keymap/utils.lua#L136-L160), [expander.lua:83‑93](static/ergopti_plus/macos/modules/keymap/expander.lua#L83-L93), [init.lua:611‑616](static/ergopti_plus/macos/modules/keymap/init.lua#L611-L616).
- **Cause racine :** `emit_text`/`emit_tokens` renvoient `(1,"")` dès que `should_paste` est vrai (texte > 50 codepoints **ou** tout codepoint > U+FFFF, ex. un hotstring `:smile:` → 😀). `perform_text_replacement` ajoute alors `""` à `expected_synthetic_chars`. Le Cmd+V synthétique re‑traverse le tap et tombe dans la branche Cmd/Ctrl ([init.lua:611‑616](static/ergopti_plus/macos/modules/keymap/init.lua#L611-L616)) qui **vide inconditionnellement** `CoreState.buffer` ⇒ le buffer reconstruit est détruit (chaînage perdu, `start_is_word_boundary` faussé). Effet secondaire : un faux raccourci « Cmd+V » est logué par le keylogger.
- **Correctif :** faire renvoyer au chemin paste la vraie chaîne logique (`(utf8_len(text), text)`) pour alimenter `expected_synthetic_chars`, **et/ou** poser un flag court `expect_paste` testé dans la branche Cmd/Ctrl avant de vider le buffer ; suppimer le faux raccourci Cmd+V côté keylogger.
- **Test :** étendre `run_e2e.lua` (ou un unit test) avec une expansion de 60 caractères ASCII (force le paste) puis un emoji ; asserter `expected_synthetic_chars == replacement` (≠ `""`).

### A6 — [LOW] Le reset `dt > 0,5 s` peut effacer des compteurs synthétiques en vol → sur‑suppression

- **Où :** [init.lua:552‑561](static/ergopti_plus/macos/modules/keymap/init.lua#L552-L561) (reset) vs [expander.lua:78‑93](static/ergopti_plus/macos/modules/keymap/expander.lua#L78-L93) (armement).
- **Cause racine :** `onKeyDownRaw` remet à zéro `expected_synthetic_deletes`/`_chars` dès que l'écart depuis l'évènement *traité* précédent dépasse 0,5 s. Si la runloop cale (> 0,5 s) entre l'expansion et la livraison OS des évènements synthétiques, le 1er echo synthétique arrive avec `dt > 0,5`, les compteurs sont vidés, et les deletes restants sont traités comme des backspaces réels → texte réel supprimé. Race difficile à reproduire (nécessite un stall), mais le garde est mal placé.
- **Correctif :** ne pas vider aveuglément ; horodater l'armement et ignorer le reset s'il a eu lieu < ~1 s, ou faire du reset un no‑op quand une expansion vient d'armer les compteurs.
- **Test :** armer `expected_synthetic_deletes=3`, livrer un backspace synthétique avec `dt=0.6` ; asserter qu'il est consommé (compteur → 2) et non traité comme backspace réel. Échoue aujourd'hui.

### A7 — [LOW] Terminateur Return/Tab re‑tapé absent des deux trackers synthétiques

- **Où :** [expander.lua:362‑392](static/ergopti_plus/macos/modules/keymap/expander.lua#L362-L392) (la branche `keyStroke({}, "return"/"tab")` n'ajoute pas le caractère à `s`, contrairement à la branche `keyStrokes(chars)`).
- **Cause racine :** sur un terminateur non‑consommé Return/Tab, `emitted_str` omet le `\r`/`\t`. Ni `expected_synthetic_chars` ni `notify_synthetic` ne le voient ⇒ le keylogger logue un `[ENTER]`/`[TAB]` humain et **flushe le buffer en plein milieu** de l'expansion (Enter/Tab sont `consume=false`, `default_enabled=true` — flux « taper le trigger puis Entrée » le plus courant).
- **Correctif :** dans la branche return/tab, faire `s = s .. chars` comme la branche `keyStrokes`.
- **Test :** `test_expander.lua` — terminateur `"\r"` non‑consommé ; asserter que `notify_synthetic`/`expected_synthetic_chars` se termine par `\r` (et `\t`).

### CLIP — [HIGH] Pastes d'expansion qui se chevauchent : le presse‑papiers réel de l'utilisateur est écrasé définitivement

- **Où (chemin live) :** [utils.lua:110‑117](static/ergopti_plus/macos/modules/keymap/utils.lua#L110-L117) et [145‑150](static/ergopti_plus/macos/modules/keymap/utils.lua#L145-L150). *(Le miroir [adapters/text_sender.lua:79‑93](static/ergopti_plus/macos/adapters/text_sender.lua#L79-L93) est dormant — cf. §6.)*
- **Cause racine :** le chemin paste sauve le presse‑papiers, le remplace, colle, puis programme une restauration via `doAfter(CLIPBOARD_RESTORE_SEC = 0,15 s)`, **sans garde contre le chevauchement**. Si un 2ᵉ paste survient dans les 150 ms, son `save()` lit *le texte de la 1ʳᵉ expansion* (la restauration n'a pas encore eu lieu) comme « contenu précédent ». Les deux restaurations s'enchaînent : la 2ᵉ (plus tardive) ré‑écrit le presse‑papiers avec le texte de la 1ʳᵉ expansion ⇒ l'utilisateur perd ce qu'il avait copié.
- **Repro :** copier `IMPORTANT` ; déclencher une expansion paste (> 50 car. ou emoji) puis, < 150 ms après, une 2ᵉ (autre hotstring ou complétion LLM longue). Au final le presse‑papiers contient le texte d'expansion, pas `IMPORTANT`.
- **Correctif :** sérialiser la propriété du presse‑papiers — garder `{saved_original, pending_timer}` au niveau module : sur nouveau paste, si `pending_timer` alors `pending_timer:stop()` et **conserver** `saved_original` (ne pas relire `getContents()`); la restauration finale restaure cette unique valeur d'origine.
- **Test :** `tests/unit/test_clipboard_paste_overlap.lua` avec un stub pasteboard à état + `doAfter` en file ; `clipboard='ORIG'`, deux `emit_text` paste consécutifs sans tirer les timers, puis tirer les timers dans l'ordre ; asserter presse‑papiers final `== 'ORIG'` (échoue aujourd'hui : finit en `expansionA`).

---

## 2. Registre / matching des hotstrings

### B1 — [MEDIUM, mais impact frappe] `disable_group` laisse des buckets tail périmés → un hotstring désactivé peut encore se déclencher

- **Où :** [registry.lua:936‑954](static/ergopti_plus/macos/modules/keymap/registry.lua#L936-L954) (`disable_group`), vs `rebuild_tail_indexes` appelé seulement par `sort_mappings` ([registry.lua:255](static/ergopti_plus/macos/modules/keymap/registry.lua#L255)).
- **Cause racine :** deux trous. (1) Pour les groupes **fichier**, `disable_group` purge `_state.mappings` et appelle `rebuild_lookup()` mais **jamais** `rebuild_tail_indexes()` → `mappings_by_tail_char`/`mappings_by_star_tail_char` gardent des pointeurs vers les entrées supprimées (les toggles menu ne déclenchent aucun `sort` derrière). (2) Pour les groupes **programmatiques** (`g.path == nil`, ex. le groupe `dynamichotstrings`), la branche de purge est gardée par `if g.path ~= nil` → leurs mappings ne sont **jamais retirés** des buckets. Comme le hot‑path (`run_trigger_checks`/`mappings_for_tail`) lit ces buckets, **un hotstring « désactivé » continue de se déclencher**.
- **Repro :** désactiver le groupe `dynamichotstrings` depuis le menu, puis taper un préfixe téléphone enregistré suivi de ★ : l'expansion se produit quand même.
- **Correctif :** dans `disable_group`, purger **inconditionnellement** les entrées `m.group == name` (les groupes programmatiques sont recréés par le hook de `enable_group`), puis appeler `rebuild_lookup()` **et** `rebuild_tail_indexes()`.
- **Test :** dans `test_registry.lua`, enregistrer un groupe programmatique avec un trigger, `sort_mappings`, vérifier qu'il est dans `mappings_for_tail`, puis `disable_group` et asserter que le bucket ne le contient plus.

---

## 3. Keylogger — vie privée, métriques, robustesse

### C1 — [HIGH] Le keylogger continue de loguer (modificateurs/souris/keyUp/idle) pendant la pause

- **Où :** [keylogger/init.lua:489](static/ergopti_plus/macos/modules/keylogger/init.lua#L489) (le garde `is_paused()` est **après** les branches souris/keyUp/flagsChanged en [430‑483](static/ergopti_plus/macos/modules/keylogger/init.lua#L430-L483)) ; [script_control.lua:128‑160](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L128-L160) (`pause_all` ne touche jamais le keylogger).
- **Cause racine :** l'invariant « pause = tout éteint » repose sur le garde interne du keylogger, mais ce garde n'arrive qu'**après** le comptage clics/scrolls, l'enregistrement des hold‑times keyUp et le log des press/hold de modificateurs. Seuls les caractères tapés sont supprimés.
- **Correctif :** remonter le garde `is_paused()` tout en haut de `handle_key`, juste après `if not CoreState.is_enabled then return end`, pour qu'il filtre **tous** les types d'évènements.
- **Test :** test d'invariant par ordre source (comme les regex‑tests existants de `test_script_control.lua`) : asserter que l'offset du garde `is_paused` est **avant** la branche `flagsChanged`. Échoue aujourd'hui.

### C2 — [HIGH] Aucun watchdog sur le tap keylogger — macOS peut le tuer silencieusement sans récupération

- **Où :** [keylogger/init.lua:1425‑1435](static/ergopti_plus/macos/modules/keylogger/init.lua#L1425-L1435) (tap), [757‑761](static/ergopti_plus/macos/modules/keylogger/init.lua#L757-L761) (pcall qui se contente de logger), à comparer aux défenses keymap [init.lua:761‑776](static/ergopti_plus/macos/modules/keymap/init.lua#L761-L776) + watchdog [878‑919](static/ergopti_plus/macos/modules/keymap/init.lua#L878-L919).
- **Cause racine :** un callback qui dépasse le timeout système (~300 ms) fait désactiver le tap par macOS. Le keymap se ré‑arme (re‑enable + watchdog 5 s) ; le keylogger **n'a ni l'un ni l'autre** — alors que `handle_key` fait *plus* de travail synchrone par frappe (`frontmostApplication()`, `mainWindow():title()`, écritures SQLite sur `.` final…). Une fois tué, plus rien n'est enregistré jusqu'à un `hs.reload`.
- **Correctif :** dans la branche d'échec du pcall, `if _event_tap and not _event_tap:isEnabled() then pcall(function() _event_tap:start() end) end` ; + ajouter un watchdog (réutiliser `TAP_WATCHDOG_SEC`) dans `M.start`, arrêté dans `M.stop`.
- **Test :** `test_tap_watchdog.lua` — stub tap avec flag `enabled` contrôlable ; passer `enabled=false`, invoquer le watchdog (ou faire lever le pcall), asserter ré‑activation. Échoue aujourd'hui.

### C3 — [HIGH] Rotation de minuit : ré‑agrégation de tout `today.log` déjà ingéré (compteurs `agg_*` doublés)

- **Où :** [rotation.lua:174‑182](static/ergopti_plus/macos/modules/keylogger/rotation.lua#L174-L182), [log_manager.lua:483‑554 / 566‑578](static/ergopti_plus/macos/modules/keylogger/log_manager.lua#L483-L554).
- **Cause racine :** `read_new_entries()` contient un self‑heal : si la date a changé, il remet `_today_log_offset = 0` et relit `today.log` depuis 0. Mais le timer d'ingest est indépendant du timer de rollover : le 1er ingest après minuit voit le changement de date **avant** que `rollover()` n'ait supprimé `today.log` ⇒ il relit **toutes** les lignes de la veille déjà ingérées et les ré‑agrège. Les tables `events_*` (INSERT OR IGNORE) dédupliquent, mais `Aggregator.walk_*` re‑incrémente `agg_app_day.chars`, n‑grammes, bursts…
- **Correctif :** rendre le self‑heal non destructif — ne remettre l'offset à 0 que lorsque le fichier a réellement rétréci (`fs.attributes(today.log).size < _today_log_offset`), c.‑à‑d. après que `rollover` ait recréé un fichier neuf ; sinon ne pas traiter tant que `rollover` n'a pas tourné.
- **Test :** suite rotation — init `offset=5000`, date veille, stub `fs.attributes` `{size=5000}` (non rétréci) + lignes déjà vues ; `os.date` → jour suivant ; asserter `read_new_entries()` renvoie 0 entrée (pas de reset offset). Puis simuler rollover (`size=0`) et asserter relecture. Échoue avant correctif.

### C4 — [HIGH] `data.sql` (source canonique append‑only) écrit **avant** la transaction SQLite et non annulé → doublons sur échec d'ingest

- **Où :** [log_manager.lua:486‑552](static/ergopti_plus/macos/modules/keylogger/log_manager.lua#L486-L552), [sqlite_writer.lua:246‑250](static/ergopti_plus/macos/modules/keylogger/sqlite_writer.lua#L246-L250), [export.lua:257‑262](static/ergopti_plus/macos/modules/keylogger/export.lua#L257-L262).
- **Cause racine :** `ingest_once` écrit `batch_text` dans `data.sql` **avant** d'ouvrir la transaction. Si une instruction échoue, le côté SQLite est `ROLLBACK` mais l'offset n'avance pas → au tick suivant, les mêmes entrées sont relues, ré‑allouées avec de **nouveaux** ids, et ré‑appendées à `data.sql`. `data.sql` contient alors deux copies (ids différents) ⇒ un appareil pair qui rejoue `data.sql` (sync) insère les deux ⇒ doublons.
- **Correctif :** écrire `data.sql` **après** COMMIT réussi ; snapshot/restore de `_next_event_id` sur rollback.
- **Test :** piloter `ingest_once` avec un `db:exec` stubé renvoyant une erreur (force le ROLLBACK) + un `io.open` enregistrant les writes `data.sql` ; lancer deux fois ; asserter que `data.sql` n'a reçu le batch **qu'une seule** fois (ou zéro). Aujourd'hui : deux fois.

### C5 — [MEDIUM] `synth_queue` keylogger sans auto‑reset (contrairement aux compteurs keymap) → une entrée orpheline empoisonne toutes les frappes suivantes

- **Où :** [keylogger/init.lua:187 / 545‑571 / 1070‑1102](static/ergopti_plus/macos/modules/keylogger/init.lua#L545-L571), vs reset keymap [init.lua:556‑561](static/ergopti_plus/macos/modules/keymap/init.lua#L556-L561).
- **Cause racine :** `synth_queue` n'est jamais vidée sur idle, flush, fin de session ou `M.stop` — seulement par match exact. Toute entrée non consommée (normalisation Unicode OS, évènement coalescé, ou injecteur dynamique qui n'a rien mis en file mais dont les chars réels arrivent) reste indéfiniment ; une frappe humaine ultérieure correspondant à la tête périmée est taguée synthétique et perdue des stats.
- **Correctif :** imiter le self‑heal keymap — `if delay > IDLE_MS and #synth_queue > 0 then synth_queue = {} end` (ex. 250‑500 ms) ; vider aussi sur `flush_buffer`/`session_end`/`M.stop` ; cap dur.
- **Test :** empiler 2 chars via `notify_synthetic("ab", …)`, ne pas les livrer, puis frappe humaine longue‑idle ; asserter que la frappe compte au WPM (file vidée).

### C6 — [LOW] `synth_queue` empoisonnée quand l'expansion est supprimée par un garde vie‑privée/app‑désactivée

- **Où :** [keylogger/init.lua:398‑416](static/ergopti_plus/macos/modules/keylogger/init.lua#L398-L416) (gardes early‑return avant la consommation `synth_queue`).
- **Cause racine :** `notify_synthetic` empile, mais si les keyDown synthétiques sont supprimés par le garde fenêtre privée / champ sécurisé / app désactivée (tous `return` avant la conso), les entrées restent. Au retour dans un champ normal, les premières frappes réelles sont taguées synthétiques.
- **Correctif :** vider `synth_queue` sur changement de contexte (app_watcher_cb / détection champ sécurisé), et/ou horodater + TTL chaque entrée (option robuste, borne aussi la croissance).
- **Test :** empiler en contexte privé (entrées non livrées), basculer en app normale, frappe réelle avec délai large ; asserter `is_synthetic=false`.

### C7 — [LOW, race] `kc_bridge` : truncate avec fenêtre TOCTOU perd des lignes kc concurrentes

- **Où :** [kc_bridge.lua:256‑268](static/ergopti_plus/macos/modules/keylogger/kc_bridge.lua#L256-L268).
- **Cause racine :** après drain, vérifie `current_size` puis tronque avec `io.open(path,'w')`. Entre la vérif et le truncate, Karabiner peut append de nouvelles lignes (vitesse HID) ⇒ tronquées et perdues du heatmap. Fenêtre étroite mais touchée pendant les rafales de frappe.
- **Correctif :** ne pas tronquer côté lecteur — laisser croître et ne réinitialiser l'offset que sur rotation par l'écrivain (la détection de shrink existante gère déjà la rotation), ou re‑lire la taille juste avant le `'w'` et ne pas tronquer si elle a grandi.
- **Test :** stub `io.open` modélisant le fichier ; après drain à EOF, faire grandir le fichier juste avant la branche truncate ; asserter que la nouvelle ligne survit au drain suivant.

---

## 4. Pipeline LLM

### D1 — [HIGH] Streaming Ollama sans timeout connect/hard → spinner « chargement » bloqué à l'infini

- **Où :** [api_ollama.lua:608‑621 / 534‑594](static/ergopti_plus/macos/modules/llm/api_ollama.lua#L608-L621) ; le jumeau MLX se garde lui ([api_mlx.lua:1519‑1546](static/ergopti_plus/macos/modules/llm/api_mlx.lua#L1519-L1546)).
- **Cause racine :** `llm_streaming = true` par défaut. Le `curl` streaming Ollama n'a **ni** `--connect-timeout`, **ni** `--max-time`, **ni** watchdog `TimerScheduler`. Si le serveur accepte la connexion mais ne stream jamais (modèle en cours de chargement, deadlock, trou réseau), `curl` bloque, `on_done`/`on_fail` ne sont jamais appelés, le spinner reste affiché indéfiniment.
- **Correctif :** copier les gardes MLX — ajouter `--connect-timeout <STREAM_CONNECT_TIMEOUT_SEC>` à l'argv, et armer `TimerScheduler.after(STREAM_HARD_TIMEOUT_SEC, …)` (annulé au 1er chunk et sur `on_done`) qui termine la tâche et appelle `on_fail`. Constantes depuis `lib.timings [llm]` comme MLX.
- **Test :** `test_api_ollama_stream_timeout.lua` — stub `shell_runner.spawn` enregistrant `args` + `timer_scheduler.after` enregistrant `(sec, fn)` ; appeler le fetch streaming ; asserter que `args` contient `--connect-timeout` et qu'un watchdog est armé.

### D2 — [MEDIUM] Signal de chaînage F16 « fast‑exité » → code mort, chaque chaînage LLM en retard de 500 ms

- **Où :** [init.lua:523 / 539 / 587](static/ergopti_plus/macos/modules/keymap/init.lua#L523) (`FAST_EXIT_KEYCODES[106]`), [llm_bridge.lua:703](static/ergopti_plus/macos/modules/keymap/llm_bridge.lua#L703), [prediction_engine.lua:760‑766](static/ergopti_plus/macos/modules/llm/prediction_engine.lua#L760-L766).
- **Cause racine :** `apply_prediction` envoie F16 (keycode 106) comme signal « frappe terminée » devant être capté par `handle_llm_keys → engine.handle_chain_signal`. Mais un commit perf a ajouté 106 à `FAST_EXIT_KEYCODES` : `onKeyDownRaw` retourne **avant** d'appeler `handle_llm_keys`. Le signal n'est donc jamais traité ; `chain_pending` n'est levé que par le timer de secours `CHAIN_FALLBACK_SEC` (~500 ms) — dont le log dit lui‑même « fallback… F16 missed ». Chaque chaînage est ~500 ms en retard.
- **Correctif :** router le signal avant le fast‑exit générique (`if keyCode == Keycodes.F16_LLM_CHAIN_SIGNAL then return LLMBridge.handle_llm_keys(...)`), et retirer 106 de `FAST_EXIT_KEYCODES`.
- **Test :** garde anti‑régression — asserter que `FAST_EXIT_KEYCODES` ne contient pas `F16_LLM_CHAIN_SIGNAL` ; + livrer keycode 106 et asserter un appel `handle_chain_signal(106)`.

### D3 — [LOW, race] `engine.reset()` ne nettoie pas `chain_pending` ni le timer de secours → une prédiction rejetée peut encore lancer une requête chaînée

- **Où :** [prediction_engine.lua:700‑729 / 752‑767 / 835‑842](static/ergopti_plus/macos/modules/llm/prediction_engine.lua#L700-L729).
- **Cause racine :** `arm_chain` lève `chain_pending` + arme `_chain_trigger_timer`. `reset()` démonte le pipeline mais ne remet **pas** `chain_pending=false` ni `:stop()` le timer ; seul `handle_chain_signal` (sur F16 observé) les nettoie. Si une voie de reset (Escape, nav, pause) tourne avant F16 et que F16 est ensuite perdu, le timer de secours tire `perform_check(true)` → requête LLM non sollicitée.
- **Correctif :** dans `reset()`, `chain_pending=false` + `if _chain_trigger_timer then _chain_trigger_timer:stop(); _chain_trigger_timer=nil end`.
- **Test :** `arm_chain()` puis `reset()` ; asserter `is_chain_pending()==false` et que tirer le callback de secours n'appelle pas `fetch`.

### D4 — [LOW] Un succès streaming périmé réinitialise le compteur d'échecs avant le garde de génération → masque des pannes backend persistantes

- **Où :** [streaming_handler.lua:251‑258](static/ergopti_plus/macos/modules/llm/streaming_handler.lua#L251-L258).
- **Cause racine :** `_consecutive_llm_failures = 0` s'exécute **avant** le garde `if get_fetch_id() ~= my_fetch_id then return end`. Un succès tardif d'une requête supplantée remet à zéro le compteur partagé même si son résultat est jeté ⇒ le seuil d'alerte (backend down) ne se déclenche jamais sur un backend qui « clignote ».
- **Correctif :** déplacer le reset **après** le garde de stale‑callback.
- **Test :** `get_fetch_id()=2` (stale) puis `on_success` ; asserter qu'il ne reset pas (en enchaînant 4 `on_fail` matchés et en vérifiant qu'une notification part une fois).

---

## 5. Tooltip / preview & config

### E1 — [MEDIUM] Le canvas empilé du preview hotstring survit à la transition vers le LLM (lignes périmées à l'écran)

- **Où :** [renderer.lua:566](static/ergopti_plus/macos/ui/tooltip/renderer.lua#L566) (`hide_stacked`, seul appelant = [tooltip_hotstring.lua:307](static/ergopti_plus/macos/ui/tooltip/tooltip_hotstring.lua#L307)), [tooltip_hotstring.lua:206/239](static/ergopti_plus/macos/ui/tooltip/tooltip_hotstring.lua#L206), [tooltip_llm.lua:746](static/ergopti_plus/macos/ui/tooltip/tooltip_llm.lua#L746), [init.lua:112‑135](static/ergopti_plus/macos/ui/tooltip/init.lua#L112-L135).
- **Cause racine :** le preview empilé vit sur `Renderer.stacked_canvas`, séparé du canvas standard/LLM. `hide_stacked()` n'est appelé que depuis le `M.hide_forced` réassigné — toutes les autres transitions (`show_loading`, `show_predictions`, `dismiss_silent`, `TooltipLLM.hide`) ne le cachent pas. Avec un délai de preview à 0 (= `INFINITE_TOOLTIP_SEC`), les lignes empilées restent affichées sous le tooltip LLM.
- **Correctif :** appeler `Renderer.hide_stacked()` (pcall) sur chaque transition qui abandonne le preview empilé (`dismiss_silent`, `show_loading`, `show`, et `TooltipLLM.hide`).
- **Test :** `test_tooltip_stacked_lifecycle.lua` — renderer espion ; `show_stacked` → `stacked_shown=true`, puis `show_loading`/`show_predictions` → asserter `stacked_shown==false`. Échoue avant correctif.

### E2 — [MEDIUM, race] Le watcher du tooltip chaîné est annulé par les propres frappes synthétiques du moteur (tap séparé sans filtre synthétique)

- **Où :** [expander.lua:79 / 81‑93 / 114](static/ergopti_plus/macos/modules/keymap/expander.lua#L114), [tooltip_hotstring.lua:123‑144](static/ergopti_plus/macos/ui/tooltip/tooltip_hotstring.lua#L123-L144).
- **Cause racine :** `perform_text_replacement` ré‑affiche un preview empilé après émission (`_llm.update_preview`) pour les autocorrections chaînées ; ce ré‑affichage arme un nouveau watcher keyDown. Ce watcher est un tap **séparé** sans comptabilité `expected_synthetic` : les caractères synthétiques de la complétion (livrés async) le déclenchent → `M.hide_forced()` → le preview chaîné disparaît avant que l'utilisateur ne le voie.
- **Correctif :** soit différer le `update_preview` post‑expansion via `doAfter(0)` (après vidange des évènements synthétiques), soit exposer au watcher une fenêtre de suppression/état synthétique pour ignorer ces frappes.
- **Test :** piloter `try_auto_expand` d'une chaîne T1→T2 avec tooltip stubé ; re‑livrer chaque char synthétique au handler capturé ; asserter que le preview chaîné n'est **pas** démonté.

### E3 — [LOW, fuite] `M.show`/`M.show_loading` n'arrêtent pas un cycle de dequeue actif → timer orphelin

- **Où :** [tooltip_hotstring.lua:214](static/ergopti_plus/macos/ui/tooltip/tooltip_hotstring.lua#L214) (`M.show` n'appelle pas `stop_dequeue`), [75‑84 / 318‑328](static/ergopti_plus/macos/ui/tooltip/tooltip_hotstring.lua#L318-L328).
- **Cause racine :** `M.show()` ne démonte pas un dequeue en cours ; le timer de dequeue tire ensuite `_dequeue_tick` qui re‑affiche les anciennes lignes empilées par‑dessus, ou `hide_forced()` qui arrache le tooltip courant. `M.show_loading` appelle `stop_watchers` ; `M.show` non.
- **Correctif :** appeler `stop_dequeue()` (ou `stop_watchers()`) en tête de `M.show()`.
- **Test :** `show_stacked(...)` (arme le timer), puis `show('x', …)` ; asserter qu'aucun timer de dequeue ne tourne (`hs.timer.__timers`).

### F1 — [MEDIUM] L'override utilisateur `show_tooltip` n'est jamais relu — le pattern Lua `(true|false)` ne matche jamais

- **Où :** [hotstrings_config.lua:191](static/ergopti_plus/macos/modules/hotstrings_config.lua#L191) (parse), [242 / 266](static/ergopti_plus/macos/modules/hotstrings_config.lua#L242) (serialize).
- **Cause racine :** `line:match("^show_tooltip%s*=%s*(true|false)%s*$")` — les patterns Lua **ne supportent pas** l'alternation `|` ; `(true|false)` matche la chaîne littérale `true|false`. Or `serialize_overrides` écrit `show_tooltip = true`/`false`. Le round‑trip écrit‑sur‑disque mais ne relit jamais ⇒ le réglage « masquer le tooltip » d'une catégorie est perdu à chaque reload.
- **Correctif :** `local bool_val = line:match("^show_tooltip%s*=%s*([%a]+)%s*$") ; if bool_val=="true" or bool_val=="false" then target.show_tooltip = (bool_val=="true") end`.
- **Test :** dans `test_hotstrings_config.lua`, à côté du round‑trip `priority` : `set_override("rolls", nil, "show_tooltip", false)`, recharger le module depuis le même fichier, asserter `resolve("rolls").show_tooltip == false`. Échoue avant correctif.

---

## 6. Gestes / raccourcis / pause

### G1 — [HIGH] Toutes les actions modificateur+lettre/chiffre/touche‑spéciale (gestes & raccourcis) sont des no‑ops morts

- **Où :** [gestures/actions.lua:70‑72](static/ergopti_plus/macos/modules/gestures/actions.lua#L70-L72) (registrar `sg(name, fn)` à **2** args), appels en [515‑571](static/ergopti_plus/macos/modules/gestures/actions.lua#L515-L571) à **3** args, garde [965‑987](static/ergopti_plus/macos/modules/gestures/actions.lua#L965-L987).
- **Cause racine :** `local function sg(name, fn) SG[name] = { fn = fn } end` (2 paramètres). Mais les enregistrements en masse appellent `sg("cmd_"..letter, "⌘ …", function() … end)` (3 args : un **label** en 2ᵉ). Lua jette l'argument en trop ⇒ `fn` est lié au **label (string)**, la vraie closure est perdue. `execute_single` garde `type(s.fn) ~= "function"` et **sort sans rien faire**. Toutes les familles `cmd_`/`cmd_shift_`/`hs_ctrl_`/`hs_ctrl_shift_`/`hs_option_`/chiffres/touches‑spéciales sont mortes.
- **Repro :** assigner un geste ou un raccourci à `cmd_a` (ou `hs_ctrl_5`, `hs_option_space`) → rien ne se passe.
- **Correctif :** soit passer la closure en 2ᵉ arg (supprimer le label), soit élargir `sg` : `local function sg(name, a, b) if type(a)=="function" then SG[name]={fn=a} else SG[name]={fn=b, label=a} end end`. Auditer les 7 boucles.
- **Test :** dans `test_actions.lua`, reset `hs.eventtap.__keystrokes`, `execute_single("cmd_a")`, asserter 1 keystroke `key=="a"` mods `cmd`. Répéter pour un représentant de chaque famille. Échoue aujourd'hui.

### G2 — [LOW] `ScriptControl.pause_all()`/`resume_all()` **publics** ne quiescent rien → le test d'invariant de pause est faussé

- **Où :** [script_control.lua:128‑178](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L128-L178) (interne) vs [443‑456](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L443-L456) (public), test [test_script_control.lua:179‑246](static/ergopti_plus/macos/tests/unit/modules/shortcuts/test_script_control.lua#L179-L198).
- **Cause racine :** deux `pause_all` co‑existent. L'interne (l.128) quiesce réellement (keymap, gestes, karabiner, tooltip, prédictions) et n'est atteint que par `dispatch_action('script_pause_toggle')`. Le **public** (l.443) ne fait que `_is_paused = true` + event — il **n'appelle pas** l'interne. Or tout le bloc « pause invariant » de test pilote le public ⇒ le test passe en ne vérifiant qu'un booléen, sans valider l'extinction réelle.
- **Correctif :** faire appeler par le public la logique de quiescence interne (renommer une paire, ex. `_quiesce_all`/`_unquiesce_all`), avec l'idempotence existante ; puis renforcer le test avec des stubs espions (keymap/gestes/karabiner) et asserter les appels réels.
- **Test :** voir correctif — stubs espions injectés via `SC.start(...)`, asserter `pause_processing`/`disable_all`/`pause` appelés.

---

## 7. Adaptateurs « port » — DORMANTS (non câblés dans le chemin macOS live)

> Ces modules `adapters/*` ne sont référencés **que** depuis
> [lib/healthcheck.lua](static/ergopti_plus/macos/lib/healthcheck.lua) (couche
> d'abstraction multi‑plateforme, pour le futur driver Linux). Le chemin macOS
> live utilise directement `modules/keymap` + `modules/keylogger` + les API
> `hs.*`. **Impact runtime actuel ≈ nul**, mais ce sont de vraies violations de
> contrat qui mordront si/quand la couche port est activée — et `healthcheck`
> peut afficher « sain » à tort. À corriger ou à marquer explicitement dormant.

| Réf | Constat | Où |
|---|---|---|
| **H2** | `SecureFieldDetector.isSecureField()` ne peut jamais renvoyer `true` (appelle `hs.axuielement.focusedElement()` inexistant + lit `.AXRole` en champ direct). *La détection live, elle, est dans [keylogger/context_tracker.lua](static/ergopti_plus/macos/modules/keylogger/context_tracker.lua) et fonctionne.* | [secure_field_detector.lua:75‑100](static/ergopti_plus/macos/adapters/secure_field_detector.lua#L75-L100) |
| **H3** | `KeyboardHook.onKey` émet le keycode numérique brut au lieu du nom normalisé et omet `isDown` ; `onChar` filtre `#char==1` (octets) → rejette les caractères multi‑octets (é, à…). | [keyboard_hook.lua:65‑91](static/ergopti_plus/macos/adapters/keyboard_hook.lua#L65-L91) |
| **H4** | `KeyState.isDown()` ne marche que pour les modificateurs (`checkKeyboardModifiers`) ; renvoie `false` pour toute vraie touche et ne mappe pas `LShift`/`RShift`. | [key_state.lua:35‑49](static/ergopti_plus/macos/adapters/key_state.lua#L35-L49) |
| **H5** | `KeyboardHook.start()` fuit un tap désactivé : si `_tap` existe mais a été désactivé par l'OS, un nouveau tap est créé sans `:stop()` l'ancien. | [keyboard_hook.lua:102‑128](static/ergopti_plus/macos/adapters/keyboard_hook.lua#L102-L128) |

**Correctifs :** H2 → recopier la requête canonique de `context_tracker` (`applicationElementForPID(pid):attributeValue("AXFocusedUIElement")` puis `AXRole`/`AXSubrole`). H3 → mapper le keycode vers `KEY_NAMES`, ajouter `isDown`, utiliser `utf8.len(char)==1`. H4 → normaliser `LShift→shift` etc. (ou documenter modificateurs‑seuls). H5 → `pcall(_tap:stop)` + `_tap=nil` avant de recréer (ou ré‑`:start()`). **Tests :** via les vecteurs de contrat existants (`test_adapter_contract_vectors.lua`) en pilotant réellement le handler.

---

## 8. Recommandations transverses

1. **Point d'injection synthétique unique (priorité 1).** Exposer
   `keymap.inject_replacement(deletes, text, source_variant)` encapsulant la
   comptabilité de `perform_text_replacement` (compteurs + `suppress_rescan` +
   `notify_synthetic` + resync buffer), et router `rules_engine`, `personal_info`
   et le chemin paste LLM à travers lui. Élimine la **classe** A1‑A5/A7.
   Verrouiller par un **test méta** qui interdit `hs.eventtap.keyStroke("delete")`
   / `keyStrokes(` bruts hors de ce point de passage (grep‑invariant, comme les
   tests d'ordonnancement existants).
2. **Unifier le suivi synthétique des deux taps.** Le keymap et le keylogger
   maintiennent deux files indépendantes (`expected_synthetic_*` vs
   `synth_queue`) avec des politiques de récupération divergentes (C5/A6).
   Donner au keylogger le même self‑heal idle, le drain sur flush/stop, et un
   cap dur.
3. **Parité des défenses de tap.** Le keylogger doit avoir le watchdog +
   ré‑arme que le keymap possède déjà (C2).
4. **Invariant de pause testé pour de vrai.** Remonter le garde keylogger (C1)
   et faire que le `pause_all` public quiesce réellement (G2), puis durcir les
   tests d'invariant avec des stubs espions plutôt qu'un simple booléen.

---

## 9. Pistes examinées mais **non retenues** (réfutées en vérification adverse)

Par honnêteté — elles ont été soulevées puis écartées après lecture du code :

- **`run_trigger_checks` différé lisant des upvalues `_tc_*` périmées** (fenêtre ignorée) : mécaniquement vrai mais **non exploitable** en pratique (le comportement résultant reste correct). *À re‑vérifier si vous changez la logique des fenêtres ignorées.*
- **Chemin paste LLM : chars non suivis double‑ajoutés au buffer** : réfuté — un Cmd+V n'émet pas d'évènements keyDown par caractère.
- **Heuristique `SYNTH_MATCH_DELAY_MS` (3 ms) divergente des 20 ms keymap** : surface réelle, mais pas de scénario de corruption substantié.
- **`kc_bridge` drain ré‑entrant (pathwatcher + timer)** : pas de corruption démontrée.
- **Defer rate‑limit rebind du timer d'inactivité avec args périmés** : mécanisme réel, **impact nul**.

---

## 10. Plan de tests de non‑régression (rappel harnais)

- **Tests unitaires** : `static/ergopti_plus/macos/tests/unit/**/test_*.lua`, découverts par [tests/run.lua](static/ergopti_plus/macos/tests/run.lua). Utiliser `require("tests.helpers")` (`describe`/`it`) et `helpers.load_with_stubs(<module>)` (reset `package.loaded` + stub `hs` frais). Le stub `tests/stubs/hs.lua` enregistre les frappes dans `hs.eventtap.__keystrokes` et les timers dans `hs.timer.__timers` (avec exécution inline de `doAfter(0)`), ce qui permet de piloter les callbacks différés de façon déterministe.
- **Tests E2E « clavier virtuel »** : [tests/e2e/run_e2e.lua](static/ergopti_plus/macos/tests/e2e/run_e2e.lua) (`make_vkb` → `inject(buffer, terminator)` → `emitted()`/`backspaces()`). C'est l'endroit naturel pour pinner les régressions **frappe‑correcte** (`triggerabcd → output…`).
- **Priorité d'écriture des tests** : A1 → A2 → C1 → C3/C4 → G1 → B1 → D1, puis le reste. Chaque test doit encoder la **cause racine** (appel `suppress_rescan`/`notify_synthetic` manquant, ordre du garde de pause, reset de bucket, etc.), pas seulement le symptôme — conformément à la règle §5.9 de `copilot-instructions.md`.

---

*Aucun fichier source n'a été modifié par cet audit. Les fichiers AHK/Windows et
`static/drivers/` n'ont été ni lus ni touchés (audit parallèle). Un brouillon
intermédiaire du digest se trouve sous `tools/dev/_audit_*.txt` (supprimable).*
