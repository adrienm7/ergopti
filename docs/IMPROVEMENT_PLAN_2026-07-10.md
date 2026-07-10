# Ergopti — Plan d'amélioration multi-driver

> **Généré le 2026-07-10** par un audit multi-agents en lecture seule (18 investigateurs sur
> 7 dimensions × 3 drivers + une passe de vérification adversariale des findings critiques).
> 78 findings : **2 critical, 21 high, 35 medium, 20 low**.
> Chaque finding porte : où (fichier:ligne), le problème, le correctif concret, et le test de
> non-régression à ajouter.
>
> **Ce document est le brief d'exécution d'un agent.** Il se suffit à lui-même : décisions déjà
> prises (§5), répartition des lots (§0.1), discipline anti-erreur (§0.2), commandes de vérif
> exactes (§0.3), protocole de suivi par commit (§6). Le **relecteur final = l'agent Opus** :
> tiens la checklist §6 à jour (SHA de commit + nom du test par item) pour que la relecture se
> fasse commit par commit.

---

## 0. Mode d'emploi

### 0.1 Qui fait quoi (répartition des lots)

| Lot | Responsable | Statut |
|---|---|---|
| Races (Linux #66/#67 grab + cluster medium), Perf, Fail-fast, Tests, SSoT couleurs WPM | 🟢 **Agent exécutant** | à faire |
| **i18n** — router + traduire les 21 langues (§3.4, 20 findings) | 🔵 **Opus (relecteur)** | réservé — NE PAS exécuter |
| **Structure** — shell_runner + renommages manager→init + relocalisation lib/ (§3.7, 4 findings) | 🔵 **Opus (relecteur)** | réservé — NE PAS exécuter |
| Webview Windows (§4.1), câblage timings (§4.2), hardware Linux (§4.3), macOS #63 | ⏸️ **Différé** | en attente écran/machine |

> 🔵 = le mainteneur a explicitement demandé que **lui/Opus** fasse ces deux lots (traductions et
> renommages de structure demandent jugement et soin). **L'agent exécutant ne touche NI aux fichiers
> de locale `_shared/data/locales/*.json`, NI à la structure des dossiers Linux** — il les laisse
> intacts pour éviter les conflits de fusion. Si un finding 🟢 croise malgré tout un de ces fichiers,
> il s'arrête et le note en §6 plutôt que de forcer.

### 0.2 Discipline — anti-erreur (À LIRE avant le premier commit)

- **Lire d'abord les règles canoniques du repo** — elles priment et ne se réinventent pas :
  `.github/copilot-instructions.md` (langage, bannières, docstrings, **8 variantes de logger**,
  pattern `M.init()` + `require_state`, §5.9) et `docs/PROJECT_MEMORY.md` (gotchas durement acquis).
- **NE JAMAIS pusher.** Commits **locaux** sur `dev` uniquement. `git push` déclenche les GitHub
  Actions (crédits du mainteneur). Aucun push, aucune PR, aucun `--force`, aucun `--no-verify`.
- **Historique linéaire.** Jamais de merge commit. [Conventional Commits](https://www.conventionalcommits.org/) :
  sujet impératif minuscule ≤ 72 char, sans point final ; le corps explique le *pourquoi*, pas le *quoi*.
- **Un commit = un finding** (ou un cluster de cause racine serré). Chaque commit embarque son test §5.9.
  C'est ce qui rend la relecture bisectable — voir le protocole §6.
- **§5.9 obligatoire, PROUVÉ.** Test rouge-AVANT / vert-APRÈS dans la bonne suite, encodant la **cause
  racine** (pas le symptôme). Prouver le rouge (muter/stasher le fix → le test échoue), puis le vert.
  Un fix sans rouge-avant prouvé = incomplet.
- **Aucune ref de plan dans le code/les commits.** Interdits : `P0-…`, `P2.5`, `DL-3`, `Phase 2B`,
  `REFACTOR_GUIDE`, **et les IDs de finding de ce doc** (`#66`, `race:linux#66`…). Ils vivent **dans ce
  MD uniquement**. Les gates `tools/test/test-no-plan-refs-in-source.cjs` + le hook `.husky/commit-msg`
  les rejettent — décris le *comportement* corrigé, pas le numéro d'item.
- **Aucun crédit LLM.** Jamais de `Co-Authored-By` ; ne jamais mentionner Claude/Copilot/agent dans
  un commit ou le code.
- **Encodage AHK.** `.ahk` = UTF-8 **BOM + CRLF**. Éditer via l'outil Edit (préserve l'encodage) ;
  **jamais** `cat >>` / heredoc POSIX (casse l'encodage → parser AHK abort **silencieux** → tests
  fantômes non déclarés = faux vert). Suite v2 = **ASCII-only**, glyphes non-ASCII via `Chr(0xNNNN)`.
  Escape guillemet dans un littéral = `` `" `` (pas `""`, qui est de l'AHK v1).
- **Après TOUT edit `.ahk`** : `npm run test:ahk-encoding` (attrape le BOM/CRLF cassé avant qu'il ne
  devienne des tests fantômes).
- **Suite AHK = Git Bash UNIQUEMENT**, exe appelé en direct avec `/ErrorStdOut`. **Jamais** via
  PowerShell `Start-Process` ni stdout redirigé (l'exe GUI perd stdout → abort → faux vert).
- **Réinitialiser `test_config.ini` après CHAQUE run AHK** (le run le mute) :
  `git checkout -- static/ergopti_plus/windows/tests/test_config.ini`.
- **Lancer les suites concernées AVANT chaque commit** (§0.3). Jamais commiter sur un rouge. Un même
  bug racine peut couvrir plusieurs findings → regroupe-les.
- **SSoT.** Zéro duplication cross-driver ; le canonique vit dans `_shared`. Duplication tolérée
  **seulement** si un drift gate la verrouille.
- **Code anglais, UI localisée.** Bannières respectées (section = 5 lignes vides + `=`×7 alignés ;
  sous-section = 3 lignes vides + `=`×5). `npm run lint:conventions:strict` doit passer.

### 0.3 Commandes de vérification (exactes)

```bash
# JS / domain / codegen (rapide — à lancer quasi systématiquement) :
npm run build:domain                                    # attendre "15 passed, 0 failed"
node tools/test/run-js-suite.cjs                        # attendre "All 60 JS check(s) passed."

# macOS (Lua, stubs — pas de Hammerspoon requis) :
cd static/ergopti_plus/macos && lua tests/run.lua       # attendre "[OK] All Lua unit tests passed."

# Linux (Lua ; luajit si dispo, sinon lua5.4/lua) :
cd static/ergopti_plus/linux && luajit tests/run.lua    # attendre "Failed tests:  0"

# Windows (AHK) — GIT BASH UNIQUEMENT :
AHK="C:/Program Files/AutoHotkey/v2.0.19/AutoHotkey64.exe"                    # adapter à la version installée
"$AHK" /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --dry-run  # 1) le graphe #Include parse
"$AHK" /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk            # 2) suite complète (TAP)
#   → chercher "not ok" dans la sortie ; ligne de résumé "# NNNN passed, 0 failed."
git checkout -- static/ergopti_plus/windows/tests/test_config.ini            # 3) reset OBLIGATOIRE après run
npm run test:ahk-encoding                                                    # 4) après tout edit .ahk
```

> Un même bug racine peut apparaître dans plusieurs findings (les races convergent sur *une* cause) —
> regroupe-les au moment d'exécuter, un seul commit + un seul test déterministe.

---

## 1. Déjà corrigé cette nuit (non pushé — commits locaux uniquement sur `dev`)

| Commit | Correctif |
|---|---|
| `c8e34f616` | codec TOML partagé décode les tableaux multi-lignes |
| `27c478ed3` `418073847` `366fa15fb` | `os.clock`→horloge murale monotone : taps gestes, debounce watchers, timestamp keylogger (tous cassés sur le daemon Linux I/O-bound) |
| `4c786753c` | slot-space gestes Linux **dérivé** de `actions.toml` partagé (plus de liste en dur) |
| `f8df076a1` | timeout one-shot kanata en fail-fast (plus de fallback 2000 ms en dur) |
| `a900d89a0` | registre timings keylogger réconcilié + drift gate |
| `2d5c614f1` | couverture privacy des password-apps **verrouillée** (délégation refusée : elle *réduirait* la couverture) |
| `85efe3273` | purge des refs de plan (75 fichiers) + gate zéro-hit + hook commit-msg |

Suites en fin de nuit : **Linux 1040/0 · macOS [OK] · AHK 2992/0 · JS 60/60 · build:domain 15/15**.

> ⚠️ Ces findings d'audit **ne rejouent pas** ce qui est déjà corrigé ci-dessus.

---

## 2. Résumé exécutif & ordre d'exécution recommandé

> ⚠️ **Lots** : l'ordre ci-dessous est l'ordre d'impact *global*. Pour savoir qui exécute quoi,
> l'autorité est §0.1 + §6. Rappel : **i18n (§3.4) et structure (§3.7) sont réservés à Opus** —
> l'agent exécutant les saute.

**Par dimension** : races 9 · perf 9 · fail-fast 11 · i18n 20 · tests 22 · SSoT 3 · structure 4.

**Ordre conseillé (impact décroissant) :**

1. **Les 2 CRITICAL d'abord.**
   - `race:linux#66` (VÉRIFIÉ) — mode *observe* ne grab pas le clavier → les frappes physiques
     s'interleavent avec l'erase-then-type ydotool asynchrone. **C'est exactement ton bug
     "abcd"→"acd".** Cause racine commune à `race:linux#67`, `race:macos#63` (variante Hammerspoon
     "aboutpdut"), `race:windows#60/61`.
   - `perf:linux#75` (fluidité) — chaque frappe spawn jusqu'à 5 sous-process (xdotool×3 + cat +
     readlink) sur le thread d'entrée mono-thread. Latence de frappe garantie.
2. **Le cluster races** (#63 macOS, #67 Linux, #60/61 Windows, #64/65/68 medium) — même famille,
   à traiter ensemble après le grab. Ta remarque sur Hammerspoon = `race:macos#63`.
3. **Perf du chemin de frappe** (blocking I/O dans le tap : `perf:macos#72`, `perf:windows#69`,
   `perf:linux#76`) — pour la fluidité.
4. **i18n** — surfaces les plus visibles d'abord : menu tray Linux 100% français (`i18n:linux#31/32`),
   bridges healthcheck/onboarding qui forcent `locale='fr'` (`i18n:linux#33`).
5. **Fail-fast** — priorité `failfast:macos#9` (VÉRIFIÉ : config Karabiner corrompue = reset
   silencieux de toute la config utilisateur).
6. **Tests** — combler les ~50 tests no-op Windows (`tests:windows#38`), i18n jamais testé
   (`tests:macos#42`), moteur hotstring partagé jamais rejoué contre le corpus (`tests:tools#56`).
7. **SSoT / structure** — nettoyage de fond (adapter `shell_runner` Linux manquant, `manager.lua`
   → `init.lua`, couleurs WPM déjà driftées).

---

# 3. Findings détaillés


## 3.1 Races & ordre des frappes (le bug que tu décris)

### 🔴 CRITICAL — Default observe mode does not grab the keyboard, so real keystrokes typed during the async ydotool erase-then-type window interleave with the synthetic output (dropped/reordered chars)

**Driver** : linux  ·  **Confiance** : high  ·  **Vérifié (adversarial)** : `confirmed`

- **Où** : `static/ergopti_plus/linux/adapters/keyboard_hook.lua:363`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:126`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:132`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:471`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:397`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:134`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:51`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:55`
- **Problème** : The daemon calls keyboard_hook.start() with no `intercept` field (ergopti_hotstrings.lua:471-476), so keyboard_hook.lua:363 leaves _intercept=false and the hook runs `libinput debug-events` (keyboard_hook.lua:132) in OBSERVE mode. libinput debug-events is a passive monitor: it never acquires EVIOCGRAB, so every physical keystroke is delivered to the focused application in real time, completely independent of the daemon. When engine:on_char returns a match, on_char (ergopti_hotstrings.lua:397) synchronously calls injector.inject(), which erases the trigger via `ydotool key` and retypes the replacement via `ydotool type` — over a SEPARATE uinput virtual device with a wide time window: INTER_PHASE_DELAY_MS=20ms between phases (injector.lua:51) plus YDOTOOL_KEY_DELAY_MS=12ms per replacement char (injector.lua:55) plus process-spawn latency, i.e. ~90ms+ for a 6-char expansion. Nothing suppresses, queues, or coalesces physical input during that window. Any key the user presses between trigger completion and end of `send_text` is delivered by the kernel/compositor INTERLEAVED with the synthetic backspaces and text, and neither the daemon nor the engine controls the relative ordering. Concrete interleaving for a hotstring input->output while the user keeps typing 'c': app shows i n p u t (physical); daemon (behind by pipe+pump latency) detects the match on 't' and starts 5 backspaces + type 'output'; the physical 'c' lands somewhere among the backspaces/type events -> e.g. app applies BS BS BS ('in'), then 'c' ('inc'), then BS BS ('i'), then 'output' -> 'ioutput'; different scheduling yields the scrambled 'aboutpdut'/'acd'-style output the user reports. This is non-deterministic corruption exactly matching the bug report. Note: the injector deliberately targets a virtual device and only the physical device is read, so there is no self-feedback loop and no in-daemon reorder — the corruption is purely app-level physical-vs-synthetic interleaving that observe mode makes unavoidable.
- **Correctif** : Hotstring replacement is only safe when the daemon owns the ONE serialized output stream to the app. Switch the default to intercept/grab mode (EVIOCGRAB via evtest --grab or a uinput-grab reader) so physical keys never reach the app directly, then re-emit EVERY keystroke — matching and non-matching alike — through the single ordered ydotool/uinput channel. CRITICAL: this fix is not just flipping keyboard_hook.lua:363 to default true — the daemon's on_char (ergopti_hotstrings.lua:354-427) currently re-injects ONLY on a match, so grabbing without adding pass-through re-injection of ordinary characters would make all normal typing vanish. Implement: (a) grab by default; (b) on non-match, re-inject the just-typed char through the same queue; (c) serialize backspaces+replacement so no physical event can splice in; and/or (d) add an input queue that buffers physical events captured during an in-flight injection and replays them in order after it completes. Also shrink the window (drop the 20ms inter-phase sleep in favor of a single atomic ydotool key+type sequence). If grab cannot be guaranteed on a given session, replacement must be disabled loudly rather than run in the racy observe path.
- **Test de non-régression** : Add static/ergopti_plus/linux/tests/unit/meta/test_injector_race.lua (register in linux/tests/run.lua). Introduce a test seam in injector.lua (e.g. injector._set_runner(fn) overriding shell_run) that mutates a shared virtual-document string table instead of shelling out. The stub models the interleave: after emitting the 2nd backspace it appends a physical char 'c' to the document (simulating a key typed mid-injection). Drive engine match input->output then inject(5,'output'); assert the resulting document is CORRUPTED (!= expected 'outputc') under the current straight-line injector — reproducing the race red. Then assert that a serialized/queued injector (which suppresses/queues the mid-injection char and replays it after) yields exactly 'outputc' — green after the fix. Complement with an invariant test asserting keyboard_hook exposes and defaults to grab/intercept mode (e.g. a new M.get_mode()=='intercept' when start() is called with no intercept opt), which stays red until the default is flipped and pass-through re-injection is wired.

### 🟠 HIGH — Character synthetic-echo filter has no source-PID gate: a real keystroke interleaving with in-flight injected echoes is dropped (reorder) or duplicates the echoes

**Driver** : macos  ·  **Confiance** : medium  ·  **Vérifié (adversarial)** : `partly`

- **Où** : `static/ergopti_plus/macos/modules/keymap/init.lua:792`, `static/ergopti_plus/macos/modules/keymap/init.lua:798`, `static/ergopti_plus/macos/modules/keymap/init.lua:801`, `static/ergopti_plus/macos/modules/keymap/init.lua:680`, `static/ergopti_plus/macos/modules/keymap/expander.lua:88`
- **Problème** : The keyDown tap runs in observe mode: real keystrokes are never suppressed during an expansion. perform_text_replacement (expander.lua:79-100) arms expected_synthetic_chars and posts the erase (keyStroke delete) + type (keyStrokes) events via CGEventPost, which the OS delivers back through the SAME tap asynchronously. onKeyDownRaw distinguishes those synthetic char-echoes from real input ONLY by content byte-match plus a 20 ms time tolerance (init.lua:792-807) — unlike the backspace filter one screen up (init.lua:680-686) which correctly gates on e:getProperty(eventSourceUnixProcessID)==hs.processInfo.processID. Every keyDown (including synthetic echoes) updates CoreState.last_key_time at init.lua:639, so the first real keystroke after an expansion frequently has dt<0.02 relative to the last-delivered echo. Two failure interleavings result while expected_synthetic_chars is still draining: (A) DROP/REORDER — expansion injects 'XY' (expected='XY'); echo 'X' strips to expected='Y'; a real 'a' arrives dt<0.02, fails the byte-match against head 'Y', hits the tolerance branch at line 798 and returns false: 'a' passes through to the app (appears on screen) but is NEVER appended to CoreState.buffer, and 'Y' echo lands after it — screen shows 'XaY' instead of 'XYa' and the engine buffer silently loses 'a' (matches 'abinputc'→'aboutpdut' interleave and 'abcd'→'acd' style buffer loss). (B) DUPLICATE — same setup but the real 'a' arrives dt>0.02: the else branch at line 801-805 purges expected_synthetic_chars=''; the still-pending 'Y' echo then arrives with expected empty, is treated as REAL input, appended to the buffer and can itself re-trigger matching — an extra/duplicated character. Root cause: synthetic-vs-real discrimination by content+time with no reliable source signal and no coalescing/suppression of real input during the send window.
- **Correctif** : Gate the character synthetic-echo filter on the event source PID exactly as the backspace filter already does (init.lua:681-682). Read source_pid = e:getProperty(hs.eventtap.event.properties.eventSourceUnixProcessID) once near the top of onKeyDownRaw; in the block at init.lua:792 only treat the event as a synthetic echo (byte-match strip AND the dt<0.02 tolerance swallow) when source_pid==hs.processInfo.processID. A real hardware keystroke (source PID 0 / not Hammerspoon's) must always fall through to the normal buffer-append path so it is neither dropped nor able to purge pending echoes. Keep the byte-match branch for OS-regrouped/normalized echoes but still require the own-PID source; if OS text-input normalization is observed to re-emit echoes under a different PID, additionally coalesce by suppressing (return true + re-queue) real keystrokes while expected_synthetic_chars/deletes/pastes are non-zero rather than letting them interleave. Verify the actual eventSourceUnixProcessID carried by keyStrokes-injected char echoes on the target macOS version before shipping.
- **Test de non-régression** : macOS suite: static/ergopti_plus/macos/tests/unit/modules/keymap/test_synthetic_char_filter_source_race.lua. (1) Replicate the init.lua:792-807 filter block as a pure function f(chars, dt, source_is_own, expected_ref)->{consumed, new_expected, appended_to_buffer}. Assert the FIXED behavior: with expected='XY', a hardware key ('a', dt=0.005, source_is_own=false) is appended to the buffer and does NOT strip/purge expected (fails today: current logic returns false and drops it); a same-PID echo ('X', dt=0.005, source_is_own=true) is still swallowed and strips expected to 'Y'. (2) Duplication guard: with expected='Y', a hardware key (dt=0.03, source_is_own=false) must NOT purge expected (so the later 'Y' echo is still recognized). (3) Source-permanence scan of init.lua asserting the expected_synthetic_chars filter references eventSourceUnixProcessID, mirroring test_synthetic_reset_guard.lua's source-scan style.
- **Note du vérificateur (partly)** : The code facts are all accurate. The keyDown tap is observe-mode (init.lua:954) and never suppresses real keys during a send window; the backspace filter gates on eventSourceUnixProcessID==hs.processInfo.processID (init.lua:681-682) while the char filter (init.lua:792-807) discriminates synthetic echoes from real input using only codepoint byte-match plus a dt<0.02 tolerance; last_key_time is bumped on every keyDown including echoes (init.lua:639); expander.lua:79/88/90/100 arms the counters and posts delete+keyStrokes echoes via CGEventPost. Both traced interleavings are faithful to the code: scenario A (dt<0.02 -> line 800 return false: real key reaches the app but is never appended, buffe
- **Correctif corrigé** : Step 1 (must precede any change): empirically confirm on the target macOS version what eventSourceUnixProcessID the keyStrokes()-injected unicode char echoes actually carry, both for the direct echo and for any OS-regrouped/normalized re-emission (the case comment 783-791 already handles). This is a hard gate: if those echoes do NOT reliably carry hs.processInfo.processID, a naive PID gate on the char filter would treat every echo as real input and duplicate the entire replacement on every expansion — strictly worse than the current race. Do not ship the PID gate until this is verified true.

Step 2a (if echoes DO carry HS's PID): mirror the backspace fix. Near the top of onKeyDownRaw read s

### 🟠 HIGH — Shared engine's backspace_count is computed under an atomicity assumption the Linux adapter cannot honor: injection is not atomic with input capture

**Driver** : linux  ·  **Confiance** : high  ·  **Vérifié (adversarial)** : `partly`

- **Où** : `static/ergopti_plus/_shared/lua/hotstring_engine/init.lua:246`, `static/ergopti_plus/_shared/lua/hotstring_engine/init.lua:248`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:400`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:212`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:331`
- **Problème** : The shared engine returns backspace_count = tlen (+1 terminator) at hotstring_engine/init.lua:246-254. This value is only valid if, at the instant the injection reaches the application, the last backspace_count codepoints in the app's document are EXACTLY the trigger (+terminator) and nothing else. The engine has no notion of wall-clock time and implicitly assumes the caller injects atomically with respect to input capture — the way the macOS Hammerspoon driver does it (synchronously inside the event-tap callback, consuming the event). The Linux adapter violates this: (1) it captures input through a subprocess pipe with unbounded latency, and keyboard_hook.pump/_pump_one use a BLOCKING _pipe:read('*l') (keyboard_hook.lua:212, acknowledged in the pump() comment) that stalls the whole event loop and widens the gap between the physical keypress and the daemon's match/inject; (2) it injects asynchronously via a separate uinput device. Between trigger completion and injection landing, additional real characters can enter the document, so backspace_count deletes the WRONG trailing characters (it erases whatever N chars happen to be last, not the trigger). engine:reset() at ergopti_hotstrings.lua:400 clears the engine buffer but does nothing to reconcile the app's actual cursor state, so the mismatch is silent. The result is over/under-deletion and scrambled text — the same class of corruption as finding 1, but here framed as a broken cross-driver contract: the linux adapter consumes the shared engine's fixed backspace_count without providing the atomic capture-and-inject the count presupposes.
- **Correctif** : Make capture-and-inject atomic on Linux so the backspace_count invariant holds: (a) replace the blocking pipe read with a non-blocking/luv-async reader so the event loop never stalls between keypress and injection, minimizing latency; (b) during an injection, suppress and queue physical input (see finding 1) so no character is appended to the document between trigger detection and replacement completion; (c) document the invariant explicitly at hotstring_engine/init.lua (backspace_count is only valid under atomic capture+inject) so future drivers do not silently re-break it. The shared engine itself is correct; the fix is in the Linux adapter honoring its precondition.
- **Test de non-régression** : Add static/ergopti_plus/linux/tests/unit/meta/test_backspace_count_atomicity.lua. Build the engine, load a mapping (trigger 'btw' -> 'by the way'), feed 'btw' and capture result.backspace_count. Then, using the injector test seam from finding 1's test, apply the injection to a virtual document that a stub mutates by appending one extra physical char BEFORE the backspaces are applied (modeling non-atomic capture); assert the resulting document is wrong (the extra char plus a mis-deleted tail). After wiring the suppress/queue path, assert the injection with the SAME backspace_count produces the correct 'by the way'. This locks the requirement that the adapter must deliver atomic capture+inject for the shared backspace_count to be valid.
- **Note du vérificateur (partly)** : The underlying race is real but the finding's distinctive claims are contradicted by the code.

REAL CORE: In the default observe mode (linux/adapters/keyboard_hook.lua:132, `_intercept=false`), `libinput debug-events` does NOT grab the keyboard, so physical keystrokes reach the app in real-time. On a match the daemon calls injector.inject() (linux/modules/hotstrings/injector.lua:134) which runs ydotool backspaces + a blocking 20ms sleep via os.execute. While the daemon is mid-injection, additional physical keystrokes land in the app directly, so the fixed backspace_count from the shared engine (_shared/lua/hotstring_engine/init.lua:246) can delete the wrong trailing characters. That non-ato
- **Correctif corrigé** : The real, race-closing fix is the same as finding 1 and lives entirely in the adapter, not the shared engine: give the daemon authoritative control over document state during expansion. Concretely, run in intercept/grab mode (evtest --grab / EVIOCGRAB, already partially wired at keyboard_hook.lua:129) so physical keystrokes never reach the app directly, re-inject normal keystrokes through the same uinput path, and suppress+queue any physical input that arrives between trigger detection and injection completion, replaying it afterward. Only then is the last backspace_count codepoints == trigger invariant guaranteed. Do NOT rely on the finding's proposed non-blocking read: it does not close th

### 🟡 MEDIUM — Cross-file timing invariant that prevents the 'abcd'->'acd' key-swallow is ungated

**Driver** : windows (AHK)  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/lib/hotstrings/hotstring_inputhook.ahk:87`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_dispatch.ahk:27`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_inputhook.ahk:84`
- **Problème** : The exact bug the user reports (typing 'abcd' yields 'acd') was originally caused by synchronous fired-hotstring logging stretching the 60 ms suppress window so keys typed during it were swallowed. The fix defers the metrics drain onto a one-shot timer (HSE_FIRE_LOG_DEFER_MS := 90) and relies on a strict ordering invariant: the drain (90 ms) MUST fire AFTER the suppress release (HSE_SUPPRESS_RELEASE_DELAY_MS := 60), so the drain never runs before — and thus never delays — that release. The two constants live in two different files and the '90 > 60' invariant exists ONLY as a code comment (hotstring_inputhook.ahk:84-87). No test locks it. Anyone raising HSE_SUPPRESS_RELEASE_DELAY_MS (e.g. to 100 ms to widen the OS-drain margin) or lowering HSE_FIRE_LOG_DEFER_MS silently inverts the ordering: the log drain then runs inside the suppress window, stretches OnChar, and re-swallows the keys typed right after a trigger — reintroducing 'abcd'->'acd' with zero test failure. This is precisely the kind of cross-module numeric invariant the project rules say must be locked by a drift gate.
- **Correctif** : Add a drift-gate test that reads both constants and asserts the ordering. Ideally also single-source the relationship: derive HSE_FIRE_LOG_DEFER_MS from HSE_SUPPRESS_RELEASE_DELAY_MS (e.g. release + a named MARGIN_MS constant) so the two can never be edited into an inverted state, and gate the margin as > 0.
- **Test de non-régression** : AHK windows suite (tests/meta/, registered in run_all.ahk): new test_fire_log_defer_after_suppress.ahk that FileReads lib/hotstrings/hotstring_inputhook.ahk and lib/hotstrings/hotstring_dispatch.ahk, extracts the two integer literals via RegExMatch on 'HSE_FIRE_LOG_DEFER_MS :=' and 'HSE_SUPPRESS_RELEASE_DELAY_MS :=', and Asserts fireDefer > suppressRelease. Red if a future edit inverts them, green today (90 > 60).

### 🟡 MEDIUM — Time-based suppress window (fixed 60 ms) drops physical keystrokes from the engine buffer, desyncing it and misfiring the next trigger

**Driver** : windows (AHK)  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/windows/lib/hotstrings/hotstring_inputhook.ahk:477`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_dispatch.ahk:344`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_engine_main.ahk:631`
- **Problème** : After a fire, HSE_Suppressed / _PrefixWatcherSuppressed stay latched for a FIXED 60 ms (released by SetTimer(-HSE_SUPPRESS_RELEASE_DELAY_MS)) so the injected backspace+replacement events are filtered out of the buffer. But the release is time-based, not tied to the actual injected-event count. Any PHYSICAL character the user types inside that 60 ms window hits _OnPrefixChar while suppressed and is silently skipped from both HSE_Buffer (hotstring_engine_main.ahk:631 early-returns) and _PrefixBuffer — yet it still reaches the application through the Visible hook. The engine buffer is now SHORTER than the on-screen text. The code acknowledges this as a 'blind spot ... the desync to inspect for abcd->acd reports' (hotstring_inputhook.ahk:477-488). Concrete failure: type 'cc*' -> expands to 'ç'; within 60 ms type 'x' (reaches screen: 'çx') then '*' intending repeat-key 'xx'. HSE_Buffer is 'ç*' (missing x), so HSE_TryRepeatKey repeats 'ç', not 'x' — wrong on-screen output. The output is only safe when no further trigger fires before the buffer is next reset. A fast typist landing a trigger-completing key in the window gets a wrong-trigger expansion (real corruption), not just a missed preview.
- **Correctif** : Make the suppress release count-based instead of purely time-based: on dispatch, record the exact number of synthetic events injected (BSCount backspaces + StrLen(Replacement) + endchar) as an expected-synthetic counter; decrement it as the suppressed OnChar/OnKeyDown callbacks consume events, and release suppression the instant the counter reaches zero — so a physical char arriving after the known synthetic burst is observed and buffered. Keep the 60 ms SetTimer purely as a safety backstop (release if the count never drains). This shrinks the physical-key blind spot from a fixed 60 ms to only the true in-flight burst.
- **Test de non-régression** : AHK windows unit suite (tests/unit/, alongside test_hse_conform_double_fire.ahk): drive a star-trigger fire through the production dispatch path with the _SendHook stub, then, with the expected-synthetic counter already satisfied (simulate the burst's char events consumed), feed one PHYSICAL char via HSE_FeedChar and assert it now appears at the tail of HSE_Buffer. Red today (time-based release leaves HSE_Suppressed set, so HSE_FeedChar drops the char); green after the count-based release lets the post-burst physical char land.

### 🟡 MEDIUM — No-op expansion guard consumes the triggering keystroke, deleting the character from the screen without injecting anything

**Driver** : macos  ·  **Confiance** : low

- **Où** : `static/ergopti_plus/macos/modules/keymap/expander.lua:284`, `static/ergopti_plus/macos/modules/keymap/expander.lua:391`, `static/ergopti_plus/macos/modules/keymap/init.lua:534`, `static/ergopti_plus/macos/modules/keymap/init.lua:563`, `static/ergopti_plus/macos/modules/keymap/init.lua:881`
- **Problème** : When a mapping's plain replacement equals what was typed, the expander short-circuits as a no-op and returns true: try_auto_expand at expander.lua:284-288 (repl_text==typed) and try_terminator_expand at expander.lua:391-395 (m.plain_repl==trigger). run_trigger_checks propagates that true (init.lua:534 / 563), and in the non-ignored path onKeyDownRaw does `if fired then return true` (init.lua:881-883). In an hs.eventtap keyDown callback, returning true CONSUMES the event — so the triggering character (auto path) or the terminator character (terminator path) is suppressed and never reaches the app, even though NO deletes and NO replacement were emitted. Net effect on screen: the last character of the trigger, or the terminating space/comma, silently vanishes — a dropped char ('abcd'→'acd'-style). The registry does not reject identity mappings (registry.lua add path has no plain_repl==trigger guard), and the case-conform path (expander.lua:260-267) can also yield conformed==typed for a given casing, so the no-op branch is reachable, not dead defensive code. The correct behavior for a genuine no-op is to leave the typed text on screen — i.e. let the event pass through (return false), not consume it.
- **Correctif** : Separate 'fired' (an expansion was applied — consume the event) from 'handled-as-no-op' (leave the on-screen text untouched — do NOT consume). Simplest: have the no-op branches at expander.lua:284-288 and 391-395 signal pass-through so onKeyDownRaw returns false for them (e.g. return a distinct sentinel, or return false from the no-op branch and only suppress rescan). The triggering/terminator character must remain on screen. Optionally also drop identity mappings at registration so the no-op path is only hit via case-conform.
- **Test de non-régression** : macOS suite: static/ergopti_plus/macos/tests/unit/modules/keymap/test_noop_expansion_passthrough.lua. Init Expander with the real CoreState/Registry stubs (as test_expander.lua does), register an identity mapping (trigger 'ok' → 'ok', auto) and a terminator identity mapping, drive the buffer to the trigger and invoke the match path. Assert that (a) no deletes and no chars are emitted (emit spy count == 0) AND (b) the handler signals pass-through so the triggering/terminator keystroke is NOT consumed (return value maps to eventtap 'false'). Fails today because both no-op branches return true (consume).

### 🟡 MEDIUM — keyboard_hook treats Shift as one-shot and never tracks key release, so holding Shift across multiple letters mis-cases (corrupts) all but the first character

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/adapters/keyboard_hook.lua:226`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:258`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:281`
- **Problème** : In the live input path (keyboard_hook._pump_one — input_reader.new with correct down/up shift tracking is never wired into the daemon, only into tests), key releases are dropped early at keyboard_hook.lua:226 (`if ev.value ~= 'down' then return true`). Shift-down sets _shift_held=true (line 258-261), but after resolving each printable key the code force-resets _shift_held=false (line 281-283). Because the Shift RELEASE is never observed, the only thing that clears _shift_held is the next keydown. So holding Shift and typing multiple letters (e.g. Shift held while typing 'A','B') resolves the first as shifted 'A' then unconditionally clears the flag, so the second resolves UNSHIFTED as 'b' -> output 'Ab' instead of 'AB'. This silently corrupts the characters entering the engine buffer, keylogger, and LLM context — wrong case, wrong tail codepoint for bucket lookup — and can both suppress legitimate hotstring matches and mis-case injected replacements. It is not the timing race of findings 1-2 but produces the same 'why did my text come out wrong' symptom, and it is deterministic.
- **Correctif** : Track modifier state from real key transitions rather than treating Shift as a per-key one-shot: process KEY_LEFTSHIFT/KEY_RIGHTSHIFT release events (do not early-return on releases for modifier codes) and set _shift_held = (value=='down'), mirroring the correct logic already present in input_reader.lua:279-281. Remove the unconditional _shift_held=false reset at keyboard_hook.lua:281-283. Apply the same to Ctrl/Alt if their held-state is used for shortcut suppression.
- **Test de non-régression** : Extend static/ergopti_plus/linux/tests/unit/meta/test_keyboard_hook_pump.lua (or add test_keyboard_hook_shift.lua): via M._test_inject_and_pump, feed a Shift-down line, then two letter keydown lines (KEY_A, KEY_B) with NO intervening Shift-up, collecting the chars delivered to on_char. Assert both are uppercase ('A','B'). Under the current one-shot logic the second is lowercase 'b' (red); after tracking release-based shift state it is 'B' (green). Add a second case: Shift-down, KEY_A, Shift-up, KEY_B -> expect 'A','b'.

### ⚪ LOW — Notepad clipboard expansion path is non-atomic with no guard keeping it Notepad-only

**Driver** : windows (AHK)  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/windows/lib/hotstrings/hotstring_dispatch.ahk:243`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_dispatch.ahk:258`
- **Problème** : For notepad.exe the expansion is split into SendNewResult(BackSpaceSeq) (SendEvent) + SendInstant(clipboard paste), and Critical is deliberately turned OFF (Critical('Off') at :258) because SendInstant Sleeps. The comment at :243-248 concedes 'a physical key typed mid-expansion can still interleave here' — i.e. the exact 'outpubct'-style interleave the atomic branch prevents is still live on this branch. It is an accepted tradeoff for Notepad, but the branch is selected purely by a runtime WinGetProcessName check with no test pinning that (a) the atomic branch is the default and (b) only notepad.exe takes the non-atomic route, so a future refactor could widen the non-atomic path to more apps and silently re-open the interleave for them.
- **Correctif** : No behavioral change needed for Notepad itself; add a guard test that pins IsNotepadApp as the sole selector of the clipboard branch and that the default (non-Notepad) path routes through the single atomic SendInput Burst. If Windows 11 Notepad's SendInput handling has since improved, consider collapsing to the atomic path and deleting the branch.
- **Test de non-régression** : AHK windows meta suite: extend tests/meta/test_input_serialization.ahk to assert that in HSE_DispatchMatch the clipboard/SendInstant branch is gated by an IsNotepadApp (exe = 'notepad.exe') condition and that the 'else' branch contains the single atomic SendInput(Burst) with Critical('On'). Red if a refactor broadens the non-atomic branch beyond Notepad.

### ⚪ LOW — Ignored-window expansion is deferred while the trigger char already passed through, so intervening keystrokes mutate the shared buffer the deferred expansion reads

**Driver** : macos  ·  **Confiance** : low

- **Où** : `static/ergopti_plus/macos/modules/keymap/init.lua:868`, `static/ergopti_plus/macos/modules/keymap/expander.lua:250`
- **Problème** : In ignored windows onKeyDownRaw schedules run_trigger_checks via hs.timer.doAfter(0,...) (init.lua:868-878) and falls through to return false, so the triggering keystroke passes through immediately. The H-19 fix captures the per-keystroke _tc_* context by value, but the deferred try_auto_expand still reads the LIVE shared CoreState.buffer (expander.lua:250-251, tstart_byte math) at execution time. A second real keystroke processed between the schedule and the deferred callback appends to CoreState.buffer, so the deferred expansion computes its erase count and buffer splice against a buffer that no longer ends where the trigger did — mis-sized backspaces / wrong splice in ignored windows. Impact is limited because ignored windows are typically the HS console / password fields where expansion is intentionally muted, so severity is low, but the async-vs-shared-buffer coupling is a latent ordering hazard.
- **Correctif** : Snapshot the buffer tail (or the exact trigger byte range) into the deferred closure alongside the _tc_* values at schedule time, and have the deferred expansion operate on that captured snapshot rather than re-reading CoreState.buffer; or run the ignored-window expansion synchronously like the normal path if it can be made non-blocking. At minimum, re-validate that CoreState.buffer still ends with the captured trigger before issuing deletes.
- **Test de non-régression** : macOS suite: static/ergopti_plus/macos/tests/unit/modules/keymap/test_ignored_window_deferred_buffer_snapshot.lua. Drive two rapid ignored-window keystrokes so two doAfter(0) expansions queue while CoreState.buffer keeps growing, fire the deferred queue, and assert each deferred expansion's computed delete-count/splice matches the buffer state at its own schedule time (not the mutated later buffer).


## 3.2 Performance & fluidité de la frappe

### 🔴 CRITICAL — Every keystroke synchronously spawns up to 5 subprocesses to query the focused window (xdotool x3 + cat + readlink) on the single-threaded input path

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/ergopti_hotstrings.lua:371-384`, `static/ergopti_plus/linux/adapters/window_info.lua:65-92`, `static/ergopti_plus/linux/adapters/window_info.lua:45-54`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:285-287`, `static/ergopti_plus/linux/adapters/process_lifecycle.lua:128-134`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:411-419`
- **Problème** : on_char (ergopti_hotstrings.lua:354) runs synchronously for every keydown — it is called inline from keyboard_hook._pump_one -> _on_char (keyboard_hook.lua:286), which itself runs inside the event loop's single thread. At line 372-375 on_char calls window_info.getFocused() on EVERY key, and the guard `if window_info and window_info.getFocused` is always true at runtime (adapters.window_info requires only logger.shim and always loads). window_info.getFocused() (window_info.lua:65-92) issues up to five io.popen calls per invocation: `xdotool getactivewindow`, `xdotool getwindowname <id>`, `xdotool getwindowpid <id>`, `cat /proc/<pid>/comm`, `readlink -f /proc/<pid>/exe`. Each shell_read (window_info.lua:45) wraps the command in `sh -c "... 2>/dev/null"`, so every call forks /bin/sh AND execs the tool — roughly 10 process creations per keystroke. Each blocks the reader until the child exits and its pipe closes (xdotool cold-start alone is typically 5-30 ms). At a normal 100 WPM (~8 keys/s) this is ~40-80 process spawns/s and tens of milliseconds of hard blocking injected into the input loop per key; during a fast burst _pump_one drains up to 50 queued lines and pays this cost for each one back-to-back, so keystrokes visibly lag and stall. The focused app almost never changes between two consecutive keystrokes, so this is pure redundant work on the hottest path, and it is the single largest source of typing latency in the driver. The daemon already has two ready-made off-path focus sources it ignores: keyboard_hook maintains a cached _context via getContext()/refreshContext() (keyboard_hook.lua:52,411-419), and process_lifecycle already polls focus every 250 ms and fans out to onFocusChange callbacks (process_lifecycle.lua:128-134,207-224) — but the daemon registers no focus callback and never reads either cache.
- **Correctif** : Remove the per-keystroke window query. Cache app_id in an upvalue that is refreshed OFF the input path: register a process_lifecycle.onFocusChange(function(appName) _cached_app_id = appName end) callback during daemon init (process_lifecycle.tick already runs on the 250 ms periodic timer), and in on_char read the cached value instead of calling window_info.getFocused(). This turns a ~10-process-spawn blocking call into a single table field read per keystroke. (Equivalently, read keyboard_hook.getContext().appId and drive keyboard_hook.refreshContext() from the periodic timer, not from on_char.) Password-app detection and per-app keylogger stats keep working because focus is still tracked, just at 250 ms granularity instead of per key.
- **Test de non-régression** : Add static/ergopti_plus/linux/tests/unit/meta/test_on_char_focus_no_subprocess.lua (auto-discovered by tests/run.lua). Monkeypatch package.loaded['adapters.window_info'] with a stub whose getFocused increments a global counter, and monkeypatch process_lifecycle.onFocusChange to capture the registered callback. Drive the daemon's focus-resolution path across N simulated keydowns and assert the getFocused counter stays 0 (focus comes from the cache, not per-key), while the cached app_id updates only when the captured onFocusChange callback is invoked. Complement with a source-level guard asserting the on_char body in ergopti_hotstrings.lua contains no window_info.getFocused / io.popen / xdotool call. Red before the fix (getFocused fires once per key), green after.

### 🟠 HIGH — Privacy filter runs blocking Win32 window-title queries synchronously on the keystroke thread

**Driver** : MF_ShouldFilter() → MF_RefreshFocus() performs WinGetID/WinGetProcessName/WinGetTitle/WinGetClass on the input-processin  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/lib/metrics/metrics_filters.ahk:114-144 (MF_RefreshFocus does the 4 WinGet* calls)`, `static/ergopti_plus/windows/lib/metrics/metrics_filters.ahk:187-188 (MF_ShouldFilter calls MF_RefreshFocus first thing)`, `static/ergopti_plus/windows/modules/keylogger/keylogger_hook.ahk:306 (per-char call site on OnChar)`, `static/ergopti_plus/windows/modules/keylogger/keylogger_hook.ahk:411 (per-special-key call site on OnKeyDown)`, `static/ergopti_plus/windows/modules/keylogger/keylogger.ahk:487 (KL_AppendLog re-invokes it for shortcuts/ROI events)`
- **Problème** : WinGetTitle sends WM_GETTEXT to the foreground window and blocks when that window is busy or Not-Responding (common Electron/Office cold-start). At the 50ms TTL a normal typist re-triggers a full refresh roughly every 1-3 keystrokes (the very staleness window test_metrics_focus_ttl_leak.ahk documents), so blocking Win32 window queries land on the input path continuously. This directly contradicts the codebase's own established invariant: keylogger_hook.ahk (KLHookConst.CONTEXT_REFRESH_MS, lines 74-83) deliberately moved the keylogger's OWN WinGetTitle/WinGetProcessName off the keystroke callback onto a 250ms timer, warning it 'would stall the in-flight keystroke past LowLevelHooksTimeout and drop it' — MF_ShouldFilter re-introduces exactly that blocking call on-thread. It is also a single-source-of-truth violation: two parallel focus caches exist (MetricsFocusCache refreshed on the hot thread, and Keylogger.session_app/session_title refreshed off-thread), fetching the same process name and title twice.
- **Correctif** : Refresh MetricsFocusCache OFF the keystroke thread and have MF_ShouldFilter/MF_ShouldFilterFor only READ the cached snapshot. Best: drive the cache from SetWinEventHook(EVENT_SYSTEM_FOREGROUND + EVENT_OBJECT_NAMECHANGE) so it updates immediately on focus/title change with zero hot-path cost and no polling — this is strictly fresher than 50ms polling AND removes the block, so it preserves the metrics-focus-cache-ttl-leak fix. Fallback: a dedicated SetTimer(MF_RefreshFocus,50) (matching the keylogger's off-thread context pattern). Ideally unify with the keylogger's off-thread context so a single foreground tracker feeds both the privacy filter and app-switch logging (removes the duplicate WinGet* work entirely).
- **Test de non-régression** : Add a source-guard in windows/tests/meta (sibling to test_metrics_focus_ttl_leak.ahk / test_metrics_focus_cache_atomic.ahk): FileRead lib/metrics/metrics_filters.ahk, isolate the MF_ShouldFilter() function body, and assert it does NOT textually contain a synchronous focus acquisition — no 'MF_RefreshFocus(' and no 'WinGetTitle'/'WinGetID'/'WinGetProcessName'/'WinGetClass' inside the predicate — and that the file registers the refresh off-thread (a SetTimer bound to the refresh fn OR a SetWinEventHook registration). Red today (MF_ShouldFilter's first line is MF_RefreshFocus() which calls WinGetTitle), green once the refresh is moved off the keystroke thread. Encodes the root cause: no blocking Win32 in the per-keystroke privacy predicate.

### 🟠 HIGH — Keylogger active event tap performs synchronous file open/write/close on the input-delivery thread — every space (always), and every keystroke when the metrics dashboard is open

**Driver** : Blocking filesystem I/O inside an active (non-listen-only) hs.eventtap callback. The keylogger tap is created with hs.ev  ·  **Confiance** : high

- **Où** : `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\rotation.lua:151`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:811`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:823`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:496`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:1317`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\log_manager.lua:295`
- **Problème** : Per-keystroke / per-word blocking disk I/O sits directly in the keystroke delivery path. handle_key at init.lua:811 flushes on every Space (keycode 49) and every sentence-ending char; each flush opens+writes+closes today.log. Worse, init.lua:823-828 calls flush_buffer() on EVERY keystroke whenever the typing-metrics webview is open (package.loaded["ui.metrics_typing.init"]._wv ~= nil), i.e. one open/write/close disk round-trip per character while the dashboard is visible. A scroll immediately after typing also flushes (init.lua:498). Because the tap is active and single-threaded, an append that stalls (busy disk, large/fragmented today.log, fsync pressure, Spotlight indexing, iCloud/Time-Machine contention) delays the Space (or every character) reaching the app — perceived as a typing hitch or a briefly 'swallowed' key. The open/close syscalls are pure overhead: the same handle could stay open.
- **Correctif** : Take the disk write off the delivery path: (1) keep a persistent append file handle for today.log — open once in Rotation.init, f:write() the JSONL line on flush, f:flush() at most on a low-frequency timer, and close on stop — eliminating the per-event open()/close() syscalls; and/or (2) push flushed entries into an in-memory queue that a hs.timer drains to disk off the keystroke path (the ingest tick already runs on a timer). For the metrics live-update at init.lua:823-828, do NOT flush to disk per keystroke — deliver the live update through an in-memory snapshot/throttled timer (coalesce to e.g. 4-10 Hz) instead of forcing a disk flush on every character.
- **Test de non-régression** : macOS suite (static/ergopti_plus/macos/tests/unit/modules/keylogger/): new test that instruments io.open (or spies Rotation.append_log) and drives handle_key with a burst of N ordinary character keydowns (no Space) while package.loaded["ui.metrics_typing.init"] = { _wv = {} }; assert the number of today.log open/append calls stays bounded (<= 1, or 0 until a flush boundary) rather than == N. Red before (one disk write per key), green after the batched/throttled live-update path. Add a second case asserting a typing burst ending in one Space triggers exactly one flush, not one-per-key.

### 🟡 MEDIUM — Keylogger re-queries frontmost app, main-window title (AX) and keyboard layout via ObjC on the first keystroke of every word, despite those values being cached event-driven

**Driver** : Redundant per-word ObjC/Accessibility calls on the active-tap keystroke path. Because flush_buffer() empties buffer_even  ·  **Confiance** : high

- **Où** : `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:603`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:605`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\init.lua:609`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keylogger\context_tracker.lua:335`
- **Problème** : init.lua:605-609 runs hs.application.frontmostApplication(), front_app:title(), front_app:mainWindow(), main_win:title(), and hs.keycodes.currentLayout() on the first keystroke after each flush — i.e. once per typed word, on the active keystroke tap. mainWindow():title() is an Accessibility (AX) query that can block for milliseconds and occasionally spike hard if the target app is momentarily unresponsive; stalling the active tap delays that keystroke's delivery. This work is redundant: the same identity is already maintained event-driven by the context_tracker app watcher (context_tracker.lua:335 sets _state.active_app_name / active_app_bundle / active_app_path on activation) and window-title changes are already observed by update_private_status. Fast typists pay the ObjC/AX cost every ~0.4-0.6 s of typing for data that only changes on focus/window change.
- **Correctif** : Read the cached, watcher-maintained fields for the session context instead of re-querying: use _state.active_app_name for session_app_name. Maintain session_win_title and session_layout as cached values updated from the existing focus/window-change watchers (context_tracker already computes the focused window title in update_private_status, and app activation is a natural point to refresh currentLayout()), and have handle_key read those cached slots. This drops the per-word ObjC/AX calls to zero in steady state (only refreshed on real focus/window/layout changes).
- **Test de non-régression** : macOS suite (static/ergopti_plus/macos/tests/unit/modules/keylogger/): seed _state.active_app_name (as the app watcher would), spy/counter on hs.application.frontmostApplication and hs.window/mainWindow title getters, then drive handle_key through several word-start keydowns (character, Space, character, Space, ...). Assert frontmostApplication and mainWindow():title() are NOT invoked once per word (call count stays 0 after context is watcher-populated). Red before (one query set per word), green after reading cached context.

### 🟡 MEDIUM — update_preview runs full per-keystroke provider calls + star/tail bucket scans on the keymap tap even when LLM and both hotstring previews are disabled (no output sink)

**Driver** : Missing early-out: the per-keystroke preview rebuild does its work unconditionally on every non-firing keystroke, then d  ·  **Confiance** : medium

- **Où** : `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keymap\llm_bridge.lua:353`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keymap\llm_bridge.lua:382`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keymap\llm_bridge.lua:397`, `D:\Documents\GitHub\ergopti\static\ergopti_plus\macos\modules\keymap\init.lua:891`
- **Problème** : On every keystroke that does not fire an expansion (and is not in an ignored window), keymap/init.lua:891 calls LLMBridge.update_preview(buffer). Even with LLM disabled (engine.get_llm_enabled()==false), star preview off, and autocorrect preview off, update_preview still: allocates last_word via buf:match('([^%s]+)$') (llm_bridge.lua:367), iterates every registered preview provider with a pcall each (personal_info + rules_engine register providers, so the loop runs — llm_bridge.lua:382), and when no provider matches walks BOTH the star bucket and the autocorrect tail bucket (llm_bridge.lua:397-488). Provider-produced rows are themselves gated behind is_autocorrect_preview_enabled (line 532-533), so in the all-disabled configuration none of this can ever surface a tooltip or arm a timer — it is pure per-keystroke waste on the latency-critical keymap tap, and for common tail chars (e/s/t) the tail bucket can hold dozens of mappings.
- **Correctif** : Add a cheap early guard at the top of update_preview (after the empty-buffer handling): if not llm_on and not is_star_preview_enabled and not is_autocorrect_preview_enabled then M.reset_predictions(); return end. In that state there is no sink for previews (provider rows are gated by the autocorrect toggle) and no LLM timer to arm, so all provider calls and bucket scans can be skipped. This is behavior-preserving and removes the scans/allocations from the hot path whenever those features are off.
- **Test de non-régression** : macOS suite (static/ergopti_plus/macos/tests/unit/modules/keymap/): with engine LLM disabled and both preview toggles off, spy on Registry.mappings_for_tail and Registry.mappings_for_star_tail (and on any registered preview provider), then call LLMBridge.update_preview('somebuf'). Assert none of them are invoked (early-out taken). Then flip one toggle on and assert the scans DO run again. Red before (scans/provider calls fire unconditionally), green after the guard.

### 🟡 MEDIUM — Hotstring/dynamic injection forks /bin/sleep and blocks the single-threaded reader for the whole expansion (20 ms pause + 12 ms per replacement char)

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/hotstrings/injector.lua:112-119`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:134-165`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:98-110`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:397-401`, `static/ergopti_plus/linux/adapters/keyboard_hook.lua:331-337`
- **Problème** : injector.inject() runs synchronously inside on_char on every hotstring/dynamic match (ergopti_hotstrings.lua:398, and dynamic_hotstrings/manager.lua:191). It performs, in order and all blocking on the single input thread: send_backspaces (one ydotool subprocess), sleep_ms(20) which does os.execute("sleep 0.003..") — forking /bin/sleep purely to pause AND blocking the reader for INTER_PHASE_DELAY_MS=20 ms — then send_text which runs `ydotool type --key-delay=12` that blocks for replacement_len * 12 ms plus process start. A 20-character expansion therefore blocks the reader for ~20 + 240 ms = a quarter second during which keyboard_hook.pump() cannot drain the evdev pipe (pump reads are the only thing servicing input; keyboard_hook.lua:331). Keys typed during that window are not lost but are delayed and then replayed in a burst — a perceptible hitch after every expansion. Forking a whole process (/bin/sleep) just to sleep is also wasteful versus a monotonic in-process nanosleep.
- **Correctif** : Stop forking a process to sleep and stop blocking the reader during injection. Minimum: replace sleep_ms's os.execute("sleep") with a non-process-spawning pause (luv timer callback when HAS_LUV, or an ffi nanosleep/poll fallback). Better: schedule the injection phases off the input path — enqueue (backspace_count, replacement) and drive send_backspaces -> delay -> send_text from the event loop's timer so keyboard_hook.pump keeps draining the evdev pipe while ydotool replays. This removes the post-expansion typing hitch inherent to the current single-threaded synchronous inject.
- **Test de non-régression** : Extend static/ergopti_plus/linux/tests/unit/meta/test_injector_commands.lua: stub os.execute/io.popen to record every command string, call injector.inject(3, "hello"), and assert no recorded command matches `^sleep ` (the inter-phase pause must not fork /bin/sleep). Add an assertion that the inter-phase delay is realized via the injected timer/sleep abstraction rather than os.execute. Red before the fix (a `sleep 0.020` command is recorded), green after.

### ⚪ LOW — HookDispatcher clones the subscriber array on every keyboard and mouse event

**Driver** : Dispatch() defensively Clone()s the per-event subscriber Array on every fire so a subscriber can Unregister itself mid-d  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/lib/hook_dispatcher.ahk:216 (for cb in ...[event_type].Clone())`
- **Problème** : Every physical key fans out through Dispatch twice (EVT_KB_DOWN and EVT_KB_CHAR), and each call allocates a fresh Array copy of that event type's subscriber list — steady-state per-keystroke heap churn on the process's hottest fan-out point. The Clone exists only to survive a subscriber that Unregisters itself during dispatch, but that case is exercised solely by the gesture mouse-click-hold release path; the keyboard subscribers (keylogger, LLM bridge, KH adapter) never self-unregister, so the allocation is pure overhead on the typing path.
- **Correctif** : Iterate the live array by DESCENDING index (RemoveAt of the current or an earlier slot is safe under reverse iteration, so self-Unregister no longer skips a peer), or gate the Clone behind a per-event 'mutated-during-dispatch' generation counter that Register/Unregister bump only when they touch a list that is currently being dispatched — the steady-state path then iterates in place with zero allocation. Either preserves the dispatch-skips-peer-on-self-unregister safety the Clone was added for.
- **Test de non-régression** : Add a windows/tests/meta behavioral test: register 3 stub callbacks on a synthetic event type, make the 2nd one call HookDispatcher.Unregister(itself) when invoked, call Dispatch once, and assert all 3 callbacks that were present at dispatch-start each ran exactly once (no skipped peer, no crash). Pair with a source assertion that Dispatch does not unconditionally '.Clone()' on the hot path. Red if a naive in-place for-loop is used (the middle self-unregister shifts and skips the 3rd), green with reverse-index/dirty-gen iteration.

### ⚪ LOW — HSE star-match allocates O(maxStarLen) substrings + StrLower on every character typed

**Driver** : HSE_FindMatchAtEnd's star path rebuilds a growing buffer suffix and lowercases it for each suffix length on every FeedCh  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/windows/lib/hotstrings/hotstring_match.ahk:121-149 (loop MaxSuffix: SubStr(HSE_Buffer,-A_Index) then StrLower(Suffix) each iteration)`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_inputhook.ahk:557 (HSE_FeedChar invoked per printable char, under Critical)`
- **Problème** : For every printable character the loop runs Min(BufLen, HSE_MaxStarTriggerLen) iterations, and each iteration allocates two transient strings: SubStr(HSE_Buffer,-A_Index) (length A_Index) and StrLower(Suffix). That is ~2*maxStarLen string allocations and O(maxStarLen^2) characters copied per keystroke, on the Critical (uninterruptible) match path, even for characters that are not the magic key. It is the largest per-keystroke allocation source in the matcher. The CS probe and its StrLower are also done unconditionally even when HSE_StarByTriggerCS is empty (the common case — magic-key star triggers are case-insensitive).
- **Correctif** : Maintain a lowercased tail of HSE_Buffer incrementally (append in HSE_FeedChar, chop in HSE_FeedBackspace/HSE_ApplyExpansion) so each probe reads a slice instead of re-lowercasing a growing suffix; compute LowerSuffix lazily only when HSE_StarByTriggerCI is non-empty, and skip the CS lookup entirely when HSE_StarByTriggerCS.Count == 0. Keep the ascending-length longest-wins and CS-before-CI ordering intact.
- **Test de non-régression** : Extend windows/tests/unit/test_hotstring_engine.ahk (or test_hotstring_engine_main.ahk): register a mix of CI and CS star triggers plus end-char triggers, then drive a fixed corpus of buffers through HSE_FeedChar and assert the returned Spec (and HSE_LastEndChar) are byte-identical to the current implementation for every case (longest-wins, CS-before-CI tie, word-boundary gating). The equivalence corpus is the guard that the allocation refactor cannot alter matching behavior; run it before and after the change.

### ⚪ LOW — engine:current_buffer() (table.concat over up to 256 codepoints) is recomputed twice per keystroke

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/ergopti_hotstrings.lua:407-409`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:415-424`, `static/ergopti_plus/_shared/lua/hotstring_engine/init.lua:274-276`
- **Problème** : In on_char the current typing buffer is materialized twice per keystroke: once at line 408 to feed prediction_engine.on_char(ch, engine:current_buffer()) and again at line 417 to feed dyn_hotstrings.on_trigger(engine:current_buffer(), ch). Each engine:current_buffer() call is table.concat(_buf_cps) over the rolling buffer, which grows to BUFFER_MAX_CHARS = 256 single-codepoint strings (hotstring_engine/init.lua:206,274-276). That is two full O(buffer) heap allocations of the same identical string on every keystroke (the buffer does not change between the two calls), i.e. redundant per-key allocation and copying on the hot path. prediction_engine then does buffer:sub(-#trigger) for each of 3 triggers and dyn_hotstrings does buffer:sub(-1)/sub(1,-2), so the concatenated string is consumed cheaply — only the double concat is wasteful.
- **Correctif** : Compute the buffer once per keystroke and pass the same string to both consumers: `local buf = engine:current_buffer()` right after the match block, then `prediction_engine.on_char(ch, buf)` and `dyn_hotstrings.on_trigger(buf, ch)`. Halves the per-key concat/allocation cost with no behavior change.
- **Test de non-régression** : Add a source/behavioral guard in static/ergopti_plus/linux/tests (e.g. extend tests/unit/meta/test_engine_current_buffer.lua): wrap an engine instance so current_buffer increments a counter, run the daemon's post-match dispatch for one simulated key with both prediction_engine and dyn_hotstrings enabled, and assert current_buffer is called at most once per keystroke. Red before the fix (2 calls), green after (1).


## 3.3 Fail-fast (échecs silencieux)

### 🟠 HIGH — Corrupt config_karabiner.toml is silently swallowed and masqueraded as "first launch", wiping ALL of the user's Karabiner tap/hold + combo config

**Driver** : macos  ·  **Confiance** : high  ·  **Vérifié (adversarial)** : `confirmed`

- **Où** : `static/ergopti_plus/macos/modules/karabiner/config.lua:54`, `static/ergopti_plus/macos/modules/karabiner/config.lua:59`, `static/ergopti_plus/macos/modules/karabiner/config.lua:242`, `static/ergopti_plus/macos/modules/karabiner/config.lua:245`
- **Problème** : `_load_toml_file` (lines 54-61) does `local ok, data = pcall(TomlCodec.decode, raw); if not ok or type(data) ~= "table" then return nil end` with NO log. The shared toml_codec.decode returns nil (not a throw) on malformed input (verified in _shared/lua/toml_codec/codec.lua: M.decode returns nil on PARSE_ERROR), so a present-but-corrupt file yields data=nil and this returns nil silently. `load_user_config` (line 242-247) then can't distinguish "file absent" from "file present but unparseable": both hit `if not data then ... return M.build_default_state(...)` and emit the misleading INFO "No user config found — initializing from defaults." The user's entire persisted Karabiner configuration (every tap/hold mapping, modifier combo, and timeout) is silently discarded and reset to defaults; the next setter call then persists defaults over the still-recoverable file (save_user_config), making the loss permanent. The file is documented as user-editable ('config_karabiner.toml is the single runtime truth'), so a hand-edit typo is a realistic trigger. This violates conventions 5.3 (no pcall swallow without a Logger.error) and 5.4 (no hardcoded fallback masking a failed config read). The sibling `load_json_file` in the SAME file (lines 63-77) correctly logs an ERROR on decode failure, proving the intended pattern.
- **Correctif** : In `_load_toml_file`, distinguish absent (io.open returns nil → return nil quietly, legitimate first-launch) from present-but-unparseable (raw read succeeded but decode failed): on the decode-failure branch call `Logger.error(LOG, "Cannot parse '%s' as TOML — refusing to silently reset user config.", path)` and signal the failure distinctly (e.g. return `nil, "parse_error"`). In `load_user_config`, only fall back to build_default_state on genuine absence; on a parse error, surface loudly (ERROR + do NOT overwrite the file / keep the corrupt file for recovery instead of resetting) so the user's config is never silently destroyed. At minimum, never log the 'No user config found' INFO when the file exists on disk.
- **Test de non-régression** : macOS unit suite — new tests/unit/modules/karabiner/test_config_corrupt_toml.lua (auto-discovered by tests/run.lua). Stub lib.logger with the capture helper (see tests/unit/lib/test_logger_runtime_capture.lua) and stub lib.toml.codec.decode to return nil (simulating malformed TOML). Point Config._load_toml_file at a temp file containing non-empty garbage and assert a Logger.error is emitted (RED before fix: zero error logs). Also drive Config.load_user_config with the corrupt file present and assert it does NOT emit the 'menu... No user config found' INFO and DOES emit an ERROR/WARN naming a parse failure — proving corruption is surfaced, not masked as first-launch.

### 🟡 MEDIUM — Metrics DB build failure (missing winsqlite3.dll / schema.sql) never reaches the central Logger — contradicts the module's own documented fail-fast contract

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/modules/keylogger/keylogger_prefetch.ahk:87-91`, `static/ergopti_plus/windows/modules/keylogger/keylogger_reader_db.ahk:129-139`, `static/ergopti_plus/windows/modules/keylogger/keylogger_reader_db.ahk:166-173`, `static/ergopti_plus/windows/modules/keylogger/keylogger_reader_db.ahk:62-68`, `static/ergopti_plus/windows/modules/keylogger/keylogger_ui.ahk:130-138`, `static/ergopti_plus/windows/modules/keylogger/keylogger_reader.ahk:28-31`
- **Problème** : keylogger_reader.ahk's module header (feature 4) explicitly promises: 'a missing schema.sql, an invalid data.sql, or an absent winsqlite3.dll all surface immediately as Logger.error'. The implementation does the opposite. KLR_BuildDatabase returns 0 on LoadLibraryW failure (line 129), GetProcAddress failure (line 136), :memory: open failure (line 166) and schema-load failure (line 169) with ONLY KLR_PrefetchDebug diagnostics — and KLR_PrefetchDebug (keylogger_reader_db.ahk:105-109) early-returns unless LoggerIsDebugEnabled(), which is false at the production INFO level. KLR_LoadSchema (line 64) returns false with no log when schema.sql is absent. The prefetch chokepoint KLPF_BuildAndWrite then does `if !db { KLPF_DbgWrite(dbg, "FAIL..."); return false }` (keylogger_prefetch.ahk:88-90), writing to a separate prefetch.log/prefetch_debug.log sidecar via a raw FileAppend, never the central Logger. The UI launcher's catch (keylogger_ui.ahk:132-138) likewise only FileAppends to the sidecar. Net effect: a genuine deployment failure (missing/mismatched winsqlite3.dll, corrupt shared schema.sql) makes the whole metrics dashboard silently show 'no data' with ZERO trace in ErgoptiPlus.log at the normal log level — the exact silent failure rule 5.3 forbids, and a direct violation of the module's stated contract. Grep confirms zero LoggerError/LoggerWarn calls exist anywhere in keylogger_reader*.ahk or keylogger_prefetch.ahk.
- **Correctif** : Emit a real central-log ERROR on the terminal (one-shot, non-hot-path) failure branches. The single cleanest chokepoint is KLPF_BuildAndWrite's `if !db` branch (keylogger_prefetch.ahk:88): add `try LoggerError("KLReader", "Metrics DB build failed (winsqlite3.dll/schema.sql/data.sql) — dashboard '{1}' shows no data.", which)` before `return false`. Also add a `try LoggerError(...)` in each KLR_BuildDatabase early-return-0 branch (LoadLibrary/GetProcAddress/open/schema) and in KLR_LoadSchema's missing-file branch. Keep the existing DEBUG-gated KLR_PrefetchDebug sidecar for the per-tick perf lines (that gating is correct and is guarded by test_klr_builddatabase_debug_fileappend_hot); these ERROR calls fire only on true terminal failure, so they do not reintroduce hot-path FileAppend. Update the keylogger_ui.ahk catch to also route through LoggerError instead of only the sidecar file.
- **Test de non-régression** : Add windows/tests/meta/test_klr_builddatabase_failure_logged.ahk (static-source meta scan, same pattern as the existing test_klr_builddatabase_debug_fileappend_hot.ahk since keylogger_reader/prefetch are not in the run_all include graph). Assert that the body of KLPF_BuildAndWrite (via _DriverFuncBody) contains a LoggerError call within/adjacent to its `if !db` failure branch, and that KLR_BuildDatabase's return-0 failure branches reference LoggerError — red before the fix (only KLPF_DbgWrite present), green after. This complements, rather than duplicates, the existing hot-path gate test.

### 🟡 MEDIUM — Personal hotstrings / personal-info TOML save failure is fully silent — WritePersonalToml/WritePersonalInfoToml swallow FileOpen failure with no log, and most callers ignore the False return, silently losing user edits

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/lib/hotstrings/personal_toml_io.ahk:319-322`, `static/ergopti_plus/windows/lib/hotstrings/personal_toml_io.ahk:400-403`, `static/ergopti_plus/windows/ui/personal_toml_editor.ahk:545`, `static/ergopti_plus/windows/ui/personal_toml_editor.ahk:572`, `static/ergopti_plus/windows/ui/personal_toml_editor.ahk:602`, `static/ergopti_plus/windows/ui/editors.ahk:85`, `static/ergopti_plus/windows/ui/personal_info_editor/init.ahk:169`
- **Problème** : WritePersonalToml does `FileObj := FileOpen(FilePath, "w", "UTF-8-RAW"); if !FileObj { return False }` (personal_toml_io.ahk:319-322) — on failure (file locked by AV/indexer, disk full, ACL-restricted path) it returns False with NO Logger call at all. WritePersonalInfoToml is identical (line 400-403). Three of the four native hotstring-editor call sites ignore the return entirely: _AddSection (personal_toml_editor.ahk:545), _RenameSection (line 572) and _DeleteSection (line 602) update the in-memory _PersonalEditorData and rebuild the dropdown, but if the disk write failed the change is silently lost on the next reload — no log, no user feedback. Both personal-info callers ignore it too: ui/editors.ahk:85 destroys the GUI on the very next line (line 86), and personal_info_editor/init.ahk:169. This is inconsistent with the codebase's own standard: the webview twin (ui/personal_toml_editor_webview.ahk:252-253) checks the return AND logs `LoggerError("HsEditor", "WritePersonalToml failed — personal hotstrings NOT saved.")`, and _SaveData (personal_toml_editor.ahk:405-408) at least surfaces an error status. The write functions themselves are the single chokepoint that should log, so a failure is invisible regardless of caller — violating rule 5.3 (no silent failures) for user-owned data.
- **Correctif** : Make the write functions the single source of truth for the failure log: in WritePersonalToml and WritePersonalInfoToml, before `return False`, add `try LoggerError("PersonalToml", "FileOpen('{1}') failed — personal data NOT saved.", FilePath)`. That guarantees every save failure hits the central log independent of caller. Additionally, have the three native callers that currently ignore the return (_AddSection/_RenameSection/_DeleteSection) surface it to the editor status bar the same way _SaveData already does (`StatusText.Value := t("editor.hotstrings.err_write")`), and have the personal-info save path warn the user before destroying the GUI.
- **Test de non-régression** : Add a unit test in windows/tests/unit (personal_toml_io.ahk is already loaded by the suite — see test_personal_toml_editor.ahk) that points PersonalTomlPath at an unwritable target (e.g. a path under a non-existent directory such as A_Temp . "\no_such_dir_xyz\personal.toml", which makes FileOpen mode "w" return ""), calls WritePersonalToml(minimalData), and asserts (a) the return is False and (b) a LoggerError was emitted (capture via the suite's logger spy used by test_logger_contract.ahk / test_api_entries_persist_error_logged.ahk). Red before the fix (no log), green after. Mirror it for WritePersonalInfoToml.

### 🟡 MEDIUM — First-launch onboarding safety guard is silently skipped if `require("ui.onboarding")` fails, arming gestures/shortcuts before the user consents

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/init.lua:269`, `static/ergopti_plus/macos/init.lua:270`, `static/ergopti_plus/macos/init.lua:277`
- **Problème** : The first-launch guard is `local ok_ob, onboarding_mod = pcall(require, "ui.onboarding"); if ok_ob and type(onboarding_mod) == "table" then ... if should_run then run(); return end end`. When the require fails (ok_ob=false) there is NO else branch and NO log: the guard is silently skipped and boot falls straight through to Section 1 pre-start (gestures.start()/shortcuts.start() at lines 289-291). The block's own comment states this guard exists precisely so 'gestures and shortcuts are never armed during the wizard (they default enabled=true which would fire touch callbacks and synthetic keys before the user consented).' A load failure of ui.onboarding on a fresh machine (no config.toml) therefore both skips the wizard AND arms input-affecting modules, with zero diagnostics — a silent failure of a boot-critical safety guard. Existing test_init_onboarding_before_prestart.lua only checks source ordering, not the require-failure path.
- **Correctif** : Add an explicit failure branch: `if not ok_ob or type(onboarding_mod) ~= "table" then Logger.error(LOG, "ui.onboarding failed to load (%s) — first-launch guard cannot run; aborting boot to avoid arming input modules without consent.", tostring(onboarding_mod)); return end`. Fail loud and stop rather than silently continuing into module pre-start.
- **Test de non-régression** : macOS meta suite — extend tests/meta/test_init_onboarding_before_prestart.lua (or new test_init_onboarding_require_failure_logged.lua). Source-scan init.lua and assert the `pcall(require, "ui.onboarding")` site is followed by a branch that calls Logger.error / returns on the not-ok case (RED before fix: the current block has no failure branch between the require and its closing `end`). Assert the error branch appears before `gestures.start()`.

### 🟡 MEDIUM — install_update() reports success even when extraction or the in-place move fails, leaving a bricked install

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/updater/manager.lua:625`, `static/ergopti_plus/linux/modules/updater/manager.lua:633`, `static/ergopti_plus/linux/modules/updater/manager.lua:640`
- **Problème** : The whole install path swallows failure. tar extraction errors are downgraded to a warn and execution continues (lines 625-628). The three os.execute calls that back up the old install and move the new files into place (rm -rf backup / mv install->backup / mv extract->install, lines 633-635) all discard their return values and redirect stderr to /dev/null. If the second `mv` fails (permission, cross-device rename, partial extract), the old install has already been moved to `.old` and the new tree is NOT in place, so the daemon directory is now broken/empty — yet the function unconditionally logs `Logger.success("Update installed…")` (line 640) and returns true (line 642). The user is told the update succeeded while their install is destroyed.
- **Correctif** : Capture each os.execute result (`local ok = os.execute(...)`; treat true/0 as success). Treat a non-empty tar stderr as a hard failure (Logger.error + return false), not a warn. If the `mv extract->install` fails, log an ERROR, attempt rollback (`mv backup_dir back to install_dir`), set `_state='idle'`, and return false. Only log success and return true when every step verifiably succeeded.
- **Test de non-régression** : Add to static/ergopti_plus/linux/tests/unit/meta/test_updater_manager.lua: make os.execute injectable (or inject a shim via package/env) so the test can force the `mv extract->install` step to return failure, then call M.install_update(fake_archive) and assert it returns false and logs an ERROR and does NOT log 'Update installed'. Red before the fix (currently returns true), green after.

### 🟡 MEDIUM — Malformed personal_info.toml is silently ignored — @-tag dynamic shortcuts vanish with no log

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/dynamic_hotstrings/manager.lua:65`, `static/ergopti_plus/linux/modules/dynamic_hotstrings/manager.lua:66`, `static/ergopti_plus/linux/modules/dynamic_hotstrings/manager.lua:108`
- **Problème** : _parse_personal_info_toml() calls the shared TomlCodec.decode(), which returns nil on any TOML spec violation (confirmed in _shared/lua/toml_codec/codec.lua:496-549 — malformed headers/values return nil). Line 66 then does `if type(parsed) ~= "table" then return {}, {}` with NO log at all. So a user whose personal_info.toml has a single syntax error gets zero @-tag letter shortcuts registered, while M.init() still reports success (get_rules_count() >= 3 from the always-added date rules, logged as 'Dynamic hotstrings initialised: 3 rule(s)'). The user has no signal their personal config is broken; the feature silently does nothing. This is exactly the 'silent fallback masking a failed config read' the conventions forbid — and it does not distinguish 'file absent' (expected) from 'file present but unparseable' (a real error to surface).
- **Correctif** : In _parse_personal_info_toml, keep the io.open==nil branch quiet (expected: no personal file), but when io.open succeeded and TomlCodec.decode returns nil, log Logger.error(LOG, 'personal_info.toml at %s is malformed — @-tag shortcuts disabled.', path) before returning empty. Surface the malformed state to init so the count/enabled reflect the real failure.
- **Test de non-régression** : Add to static/ergopti_plus/linux/tests/unit/meta/test_dynamic_hotstrings_manager.lua: inject a capturing logger stub via package.loaded['logger.shim'] (record warn/error calls), write a syntactically invalid TOML to a temp path, call dh.init({ trigger_char='\\', personal_info_path=tmp }), and assert that an error/warn was logged mentioning the malformed file. Red before (no log), green after.

### 🟡 MEDIUM — Malformed user tap_hold.toml silently falls back to shared defaults after logging that the user file is being used

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/kanata/manager.lua:104`, `static/ergopti_plus/linux/modules/kanata/manager.lua:152`, `static/ergopti_plus/linux/modules/kanata/manager.lua:157`
- **Problème** : _load_keys_from_toml() returns nil when TomlCodec.decode returns nil (malformed user TOML, lines 104-109). In _load_tap_hold_config, when the user's ~/.config/ergopti/tap_hold.toml exists, line 152 logs 'Loading tap-hold config from user file: …' (implying it will be applied) and line 153 parses it; if it is malformed, `keys` is nil, so line 157 silently falls through to the shared defaults.toml with NO warning that the user's file was unparseable and discarded. The user's custom tap-hold configuration is silently replaced by defaults; only if BOTH user and defaults fail does line 166-167 warn. So a broken personal kanata config produces a working-but-wrong keymap with no diagnostic.
- **Correctif** : In _load_keys_from_toml, distinguish 'io.open failed' (return nil quietly) from 'decode returned nil after a successful read' (Logger.error 'user tap_hold.toml malformed'). In _load_tap_hold_config, when _user_toml existed but yielded no keys, Logger.warn that the user file was present but ignored before falling back to defaults.
- **Test de non-régression** : Add to static/ergopti_plus/linux/tests/unit/meta/test_kanata_manager.lua: capturing logger stub, point the loader at a malformed user tap_hold.toml (via an injectable path or HOME override), invoke the config load, and assert an error/warn was logged about the malformed user file. Red before, green after.

### 🟡 MEDIUM — storage.set()/delete()/clear() return success even when the atomic disk write fails

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/adapters/storage.lua:116`, `static/ergopti_plus/linux/adapters/storage.lua:149`, `static/ergopti_plus/linux/adapters/storage.lua:191`
- **Problème** : _flush() (line 80) returns false and logs an ERROR when the atomic write throws, but it never re-throws. M.set()'s inner pcall (lines 118-121) only catches thrown errors and discards _flush()'s boolean return, so on a disk-full / read-only / bad-path write failure M.set() still returns true (line 126). Its documented contract is 'True on success, false on error' (line 115), so the return value lies. M.delete() (line 151) discards the pcall result entirely and always returns true; M.clear() (line 196) calls _flush() unchecked and always returns true. Callers that persist user intent — updater channel/interval (_persist), LLM model/enabled state in profiles.lua — get 'true' while the value only lives in memory and is silently lost on the next daemon restart.
- **Correctif** : Have the inner closure return _flush()'s result and surface it: `local ok, flushed = pcall(function() _cache[tostring(key)] = value; return _flush() end); if not ok then Logger.error(...); return false end; return flushed == true`. Apply the same to delete() and clear() so their boolean return reflects whether the flush actually persisted.
- **Test de non-régression** : Add to static/ergopti_plus/linux/tests/unit/meta/test_storage_adapter.lua: force _flush to fail (e.g. set XDG_CONFIG_HOME to a path whose parent is a regular file so mkdir/rename fail, or stub io.open to return nil for the .tmp file) and assert M.set('k','v') returns false. Red before (returns true), green after.

### ⚪ LOW — Keylogger SQLite writer swallows json.encode failures and stores '{}' with no log, silently corrupting stored event metadata/predictions

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/modules/keylogger/sqlite_writer.lua:263`, `static/ergopti_plus/macos/modules/keylogger/sqlite_writer.lua:264`
- **Problème** : `_sql_json` does `local ok, encoded = pcall(json.encode, v); if not ok then return '{}' end`. A JSON-encode failure (e.g. a prediction/metadata table containing a value hs.json cannot serialize) is swallowed with no Logger call; the row is written with an empty '{}' object. Downstream analytics (events_llm.predictions_json, events_system.metadata_json, typing events_json) then silently lose that data with no trace it ever failed — a swallowed-pcall violation of convention 5.3 in the data-integrity layer.
- **Correctif** : Log the failure before falling back: `if not ok then Logger.warn(LOG, "_sql_json: json.encode failed (%s) — storing empty object.", tostring(encoded)); return "'{}'" end`. Keep the safe fallback but make the loss visible so a recurring encode failure is diagnosable.
- **Test de non-régression** : macOS unit suite — new tests/unit/modules/keylogger/test_sqlite_writer_json_encode_failure.lua. Stub lib.logger with capture and stub hs.json.encode to raise for a sentinel value; call a builder through M.build_inserts with an event whose metadata contains that sentinel and assert a Logger.warn/error is captured (RED before fix: no log) while the returned SQL still contains a valid '{}' literal (fallback preserved).

### ⚪ LOW — menu_state.sync_state_to_modules restores saved preferences through dozens of bare pcalls that swallow every setter error with no log — a silently-partial config restore

**Driver** : macos  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/macos/ui/menu/menu_state.lua:60`, `static/ergopti_plus/macos/ui/menu/menu_state.lua:72`, `static/ergopti_plus/macos/ui/menu/menu_state.lua:80`, `static/ergopti_plus/macos/ui/menu/menu_state.lua:109`, `static/ergopti_plus/macos/ui/menu/menu_state.lua:116`
- **Problème** : The boot-time state restore fires ~30 setter calls wrapped as `pcall(keymap.set_terminator_enabled, ...)`, `pcall(keymap.add_custom_terminator, ...)`, `pcall(keymap.set_delay, ...)`, `pcall(gestures.set_action, ...)`, `pcall(hs.settings.set, ...)` etc., none of which capture or log the ok result. If any injected setter raises (e.g. a keymap API renamed/removed, a malformed persisted custom terminator), that specific saved preference is silently NOT applied and the user sees settings mysteriously revert with nothing in the log to explain it. Convention 5.3 requires at least a Logger.error on a swallowed pcall.
- **Correctif** : Wrap the per-item pcalls in a small helper that logs on failure, e.g. `local function try(label, fn, ...) local ok, err = pcall(fn, ...); if not ok then Logger.warn(LOG, "sync_state_to_modules: %s failed — %s", label, tostring(err)) end end`, and route the setter calls through it so a failed restore is visible per key instead of vanishing.
- **Test de non-régression** : macOS unit suite — new tests/unit/ui/menu/test_menu_state_sync_logs_setter_failure.lua. Build a keymap stub whose set_delay (or set_terminator_enabled) raises, pass it via deps to M.sync_state_to_modules with a state/saved table that triggers that setter, capture the logger, and assert a Logger.warn/error naming the failed setter is emitted (RED before fix: the pcall swallows it with zero logs).

### ⚪ LOW — predict() substitutes a hardcoded 'codellama' model, making the 'no model selected' guard dead code

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/llm/prediction_engine.lua:189`, `static/ergopti_plus/linux/modules/llm/prediction_engine.lua:195`
- **Problème** : Line 189: `local model = profiles and profiles.get_current_model() or "codellama"`. When profiles is loaded but no model is configured (get_current_model returns nil because Ollama has no model set), `model` becomes the hardcoded 'codellama'. The very next guard `if not model then Logger.warn('No model selected — run Ollama and refresh models.')` (lines 195-198) is therefore unreachable whenever profiles is present. A prediction request is dispatched to Ollama for a model that is likely not installed, and the user gets a silent no-op ('no response from Ollama') instead of the actionable 'no model selected' message. This is the hardcoded-behavioral-fallback anti-pattern (conventions 5.4) masking an unconfigured state.
- **Correctif** : Drop the `or "codellama"` fallback: `local model = profiles and profiles.get_current_model()`. The existing `if not model` guard then correctly surfaces the actionable warning and aborts before contacting Ollama.
- **Test de non-régression** : Add a linux prediction-engine test (e.g. static/ergopti_plus/linux/tests/unit/meta/test_prediction_engine_predict.lua) with a profiles stub whose get_current_model returns nil and an ollama stub recording chat() calls; call M.predict('ctx') and assert ollama.chat was NOT invoked and the 'no model' warning was logged. Red before (chat dispatched with codellama), green after.


## 3.4 i18n — textes en dur (objectif 21 langues)

### 🟠 HIGH — Model-power description is hardcoded French, then injected into a localized profile-suggestion dialog

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/ui/menu/menu_llm/model_switcher.lua:339`, `static/ergopti_plus/macos/ui/menu/menu_llm/model_switcher.lua:341`, `static/ergopti_plus/macos/ui/menu/menu_llm/model_switcher.lua:343`, `static/ergopti_plus/macos/ui/menu/menu_llm/model_switcher.lua:345`, `static/ergopti_plus/macos/ui/menu/menu_llm/model_switcher.lua:384`
- **Problème** : apply_recommended_prompt_profile() builds power_desc from bare French literals — "Profil de puissance détecté : complétion brute", "Puissance détectée (MoE) : %gB actifs / %gB total", "Puissance détectée : %gB", "Puissance détectée : inconnue". It is then substituted via string.format(i18n.get("menu.llm.profile_change_msg"), display_name, power_desc, ...) into the localized dialog whose fr value is "Modèle : %s\n%s\n\nPrompt actuel :..." (fr.json:1062, second %s = power_desc). So a German/Japanese/etc. user sees a translated template with an untranslated French power line embedded. Line 384 also falls back to a bare "Profil recommandé" dialog title even though an EXACT locale key already exists (menu.profiles.recommended_profile = "Profil recommandé"/"Recommended Profile"), while line 363 correctly uses i18n.get for the sibling title.
- **Correctif** : Add four locale keys (e.g. menu.llm.power_completion, menu.llm.power_moe, menu.llm.power_single, menu.llm.power_unknown) across all 21 _shared/data/locales/*.json and build power_desc via i18n.get/string.format instead of the French literals. Replace the line 384 fallback with i18n.get("menu.profiles.recommended_profile") (key already exists — no new value needed).
- **Test de non-régression** : Add macos/tests suite meta test (mirror tests/unit/ui/test_metrics_apps_default_category.lua's grep-source pattern): assert model_switcher.lua contains no bare "Puissance détectée"/"Profil de puissance"/"Profil recommandé" literals, and assert the new keys resolve non-empty for en and fr via lib.locale. Red before (literals present), green after (routed through i18n).

### 🟠 HIGH — Hardware-requirements warning block in the model-download dialog is entirely hardcoded French

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager.lua:292`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager.lua:294`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager.lua:301`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager.lua:303`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager.lua:305`
- **Problème** : The RAM/disk pre-flight checks push bare French strings into the warnings table — e.g. "⚠️ RAM : requis ~%.1f Go (%d Go disponible) — risque de lenteur", "❌ Disque : requis ~%.1f Go ... — espace insuffisant", "⚠️ Disque : ... — espace limité", plus the 🟢 OK variants. These are concatenated into msg (line 310) and shown to the user via dialog.block_alert at lines 323 and 334-336 during the model-download confirmation. The surrounding dialog title/buttons ARE localized (menu.llm.download_failed, menu.llm.hw_header, common.close/cancel), so only this body block leaks French to every non-French locale.
- **Correctif** : Introduce locale keys (e.g. menu.llm.hw_ram_warn / hw_ram_ok / hw_disk_insufficient / hw_disk_limited / hw_disk_ok) in all 21 locale files and format each warning line via string.format(i18n.get(key), req, avail). Keep the emoji in the value or prepend it in code consistently with the existing menu.karabiner status keys that embed emoji.
- **Test de non-régression** : macos meta test grepping models_manager.lua for the absence of bare French warning substrings ("requis ~", "espace insuffisant", "risque de lenteur", "espace limité") and asserting the new keys resolve for en+fr. Fails before (literals inline), passes after routing through i18n.

### 🟠 HIGH — Entire tray menu body is hardcoded French: ~40 submenu item titles bypass i18n while section titles use i18n_safe()

**Driver** : The tray menu (most visible UI surface) was built with i18n_safe() only for the top-level SECTION titles; every leaf/act  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/menu/menu_builder.lua:89`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:105`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:119-120`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:128`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:163-197`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:222-264`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:280`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:300-334`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:369-376`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:406-443`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:578-627`
- **Problème** : menu_builder.lua wraps only section titles in i18n_safe(key, fallback) (e.g. line 111 menu.hotstrings.title). Nearly all leaf items are raw French literals with no key: 'Recharger les hotstrings' (105), 'Activé ' toggles (128/222/360), 'Statistiques de session'/'WPM actuel'/'Stats par application'/'Suspendre'/'Réinitialiser la session' (163-197), '→ MAJUSCULES'/'→ minuscules'/'→ Title Case'/'Sélectionner le mot'/'Sélectionner la ligne'/'Coller sans formatage'/'Wrap symbols' (240-280), 'Générer le .kbd'/'Démarrer kanata'/'Arrêter kanata'/'Redémarrer kanata' (300-334), the gesture slot labels '← 3 doigts gauche' … 'Tap 4 doigts' (369-376), 'Lecture libinput: active/inactive'/'Réinitialiser les gestes'/'Ouvrir le dossier de config' (406-443), 'Télécharger et installer'/'Canal stable'/'Canal dev (préversions)'/'Vérifier toutes les'/'Ouvrir la page des releases' (578-627), plus disabled stubs '(config non disponible)'/'(aucun groupe chargé)'/'LLM non disponible' etc. Matching canonical locale keys already exist in _shared/data/locales for most of these: menu.gestures.swipe_3_left/tap_4/restore_defaults, menu.about.channel_main/channel_dev/install_update/open_releases_page/frequency.*, menu.global.reload/quit, menu.gestures.on/off. macOS renders the equivalent menu entirely through i18n.get(); Linux re-typed the strings.
- **Correctif** : Route every leaf title through i18n_safe(key, fallback) (or i18n.get) using the existing locale keys: line 105 -> a hotstrings reload key, 128/222/360 -> menu.<section>.on / menu.gestures.enabled, 163-197 -> menu.metrics.* keys, 240-280 -> menu.shortcuts.* / transform keys, gesture slot labels 369-376 -> menu.gestures.swipe_3_left … menu.gestures.tap_4 (already exist), 419 -> menu.gestures.restore_defaults, 443/516 -> menu.global.config_folder, 578-627 -> menu.about.install_update / channel_main / channel_dev / frequency.* / open_releases_page. Where no key exists yet (kanata submenu items, 'Recharger les hotstrings', 'WPM actuel', 'Lecture libinput'), add the key to all 21 _shared/data/locales/*.json first (fail-fast: keep the current French as the fr.json value), then read it. Do not leave French literals in source.
- **Test de non-régression** : Add tests/unit/meta/test_menu_builder_i18n.lua: stub package.loaded['lib.i18n'] with get(key)=>'§'..key (sentinel) and get_locale/list_locales/display_name stubs, call menu_builder.build({config=mock,...}), recursively walk every item.title, and assert NO title equals a known hardcoded French literal from the list above (e.g. 'Recharger les hotstrings', 'WPM actuel', 'Générer le .kbd', 'Réinitialiser la session', 'Canal stable'). Red now (literals present), green after each is routed through i18n. Registered automatically by tests/run.lua discovery under tests/unit/meta/.

### 🟠 HIGH — Gesture action labels re-typed in French in gestures/manager.lua — never routed through i18n despite canonical sg_actions/ax_actions locale keys

**Driver** : ACTION_LABELS is a full French copy of labels whose single source of truth is _shared/data/locales (sg_actions.*/ax_acti  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/gestures/manager.lua:142-183`, `static/ergopti_plus/linux/modules/gestures/manager.lua:282-285`, `static/ergopti_plus/linux/modules/menu/menu_builder.lua:381`
- **Problème** : ACTION_LABELS (142-183) hardcodes e.g. vol_up='🔊 Volume +', ws_prev='▢ ← Bureau précédent', lock_screen='🔒 Verrouiller', notification_center='🔔 Notifications', none='∅ Désactivé'. The comment on line 141 even says 'fallback when i18n is absent' but there is NO i18n path: get_action_label() (282-285) returns ACTION_LABELS[name] with no i18n lookup, and the file never requires lib.i18n. The canonical labels live in _shared/data/locales as sg_actions.vol_up ('🔊 + Volume +'), sg_actions.lock_screen, sg_actions.notification_center, ax_actions.*, etc. — 21 translated copies. The macOS driver (macos/modules/gestures/actions.lua:17,779-855) reads them via i18n.get('sg_actions.'..name). The Linux table drifts (e.g. vol_up text differs from the canonical) and is monolingual.
- **Correctif** : In get_action_label(), look up i18n.get('sg_actions.'..action_name) (and 'ax_actions.'..name for axis actions) first, keeping ACTION_LABELS only as an offline fallback — or delete ACTION_LABELS entirely and read the shared locale as macOS does. require('lib.i18n') at top of the module. Ensure the fallback text and the fr.json value stay identical.
- **Test de non-régression** : Extend tests/unit/meta/test_gestures_manager.lua: before load_module, stub package.loaded['lib.i18n'] so get('sg_actions.vol_up')='SENTINEL_VOL'; assert M.get_action_label('vol_up')=='SENTINEL_VOL' (red now: returns the hardcoded '🔊 Volume +'). Add a drift gate: for every key in ACTION_LABELS assert a matching sg_actions.<key> or ax_actions.<key> exists in _shared/data/locales/fr.json, so a new Linux-only action can never be added without a localizable key.

### 🟠 HIGH — Healthcheck and onboarding bridges hardcode locale='fr' in the payload sent to the WebKitGTK UI, forcing those dashboards to French

**Driver** : The web UIs (_shared/ui/healthcheck, _shared/ui/onboarding) localize themselves from the `locale`/`current_locale` field  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/ui/bridge_handlers/healthcheck_bridge.lua:84`, `static/ergopti_plus/linux/modules/ui/bridge_handlers/onboarding_bridge.lua:37`
- **Problème** : healthcheck_bridge.lua:84 returns `locale = "fr"` in _build_initial_payload; onboarding_bridge.lua:37 sets `local locale = "fr"` and returns it as current_locale (line 39-40). Neither file requires lib.i18n. The daemon persists and knows the real locale via lib.i18n.get_locale(), but it is never passed to the UI, so the healthcheck dashboard and the first-run onboarding wizard are locked to French.
- **Correctif** : In both bridges, require('lib.i18n') and set locale = i18n.get_locale() (pcall-guarded, default 'fr' only if the module truly fails to load). onboarding_bridge should also read the persisted locale rather than the string literal.
- **Test de non-régression** : In tests/unit/meta/test_ui_bridge_handlers.lua add cases: stub package.loaded['lib.i18n'] with get_locale()=>'de', call healthcheck_bridge.on_message('ready', state) and assert response.locale=='de'; call onboarding_bridge.on_message({step='init'}, state) and assert response.current_locale=='de'. Red now (both return 'fr'), green after wiring get_locale().

### 🟡 MEDIUM — Win+X color-picker MsgBox is hardcoded French while the identical gesture action is fully localized

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/modules/shortcuts/win.ahk:57`
- **Problème** : GetHexValue() (the Win+X "copy pixel colour" shortcut) shows Msgbox("La couleur sous le curseur est " HexColor "`nElle a été sauvegardée dans le presse-papiers : " A_Clipboard) — a fully hardcoded French dialog with no title. The functionally identical gesture path already routes through the locale system at modules/gestures/actions.ahk:461: MsgBox(Format(t("shortcuts.color_picker_result"), HexColor, A_Clipboard), t("shortcuts.color_picker_title")). The keys shortcuts.color_picker_result (with {1}/{2} placeholders) and shortcuts.color_picker_title already exist in all 21 locale files (verified fr/en/de). So the two parallel implementations of the same feature diverged: the gesture is translated, the keyboard shortcut is stuck in French for the other 20 languages, and the shortcut version also drops the dialog title entirely.
- **Correctif** : Replace win.ahk:57 with the exact call already used by the gesture: MsgBox(Format(t("shortcuts.color_picker_result"), HexColor, A_Clipboard), t("shortcuts.color_picker_title")). No new keys needed — reuse the existing shortcuts.color_picker_* keys, giving both paths a single source of truth for the wording.
- **Test de non-régression** : Add a meta source-scan test in windows/tests/meta/ (registered via run_all.ahk) modelled on test_ui_style_llm_tray_i18n.ahk: Src := _DriverSourceNoComments(); Assert(!InStr(Src, "La couleur sous le curseur est"), 'win.ahk color picker must use t("shortcuts.color_picker_result")') and Assert(InStr(_DriverFuncBody("GetHexValue"), 't("shortcuts.color_picker_result")') > 0). Red before the fix (literal present), green after.

### 🟡 MEDIUM — LLM model-type labels "Complétion"/"Chat" hardcoded in the tray model menu despite existing 21-locale keys

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/menu/menu_llm/menu_models.ahk:282`, `static/ergopti_plus/windows/ui/menu/menu_llm/menu_models.ahk:283`, `static/ergopti_plus/windows/ui/menu/menu_llm/menu_models.ahk:342`
- **Problème** : The model-row title builder and the per-model "specs" submenu hardcode the model type in French: line 282-283 type_str := ... ? " [📝 Complétion]" : " [💬 Chat]" and line 342 type_label_text := (type_val == "completion") ? "📝 Complétion" : "💬 Chat". Every other label in this file is localized via t(). The keys model_browser.type_completion and model_browser.type_chat already exist in all 21 locales (fr "Complétion"/"Chat", en "Completion"/"Chat", de "Vervollständigung", ja "補完"/"チャット", …) and the shared model-browser webview uses them at _shared/ui/model_browser/script.js:188. Result: the WebView model table shows the correctly translated type while the tray menu row shows French — an in-driver cross-surface inconsistency. (Secondary: the same row builder hardcodes the units "…B params, ~" Ceil(ram_gb) " Go RAM" at menu_models.ahk:287/289 — "Go" is the French GB abbreviation; no key exists yet for that compact-row spec string.)
- **Correctif** : Replace the three literals with the existing keys, preserving the emoji prefix: " [📝 " . t("model_browser.type_completion") . "]" / " [💬 " . t("model_browser.type_chat") . "]" (lines 282-283) and "📝 " . t("model_browser.type_completion") / "💬 " . t("model_browser.type_chat") (line 342). For the RAM/params units, add a Format-style key (e.g. menu.llm.model_row_specs = "({1}B params, ~{2} GB RAM)") to all 21 locales and Format() it instead of concatenating "Go RAM".
- **Test de non-régression** : Add a meta source-scan test: Src := _DriverSourceNoComments(); Assert(!InStr(Src, "📝 Complétion") && !InStr(Src, "💬 Chat"), 'menu_models.ahk must not hardcode French model-type labels') and Assert(InStr(Src, 't("model_browser.type_completion")') > 0 && InStr(Src, 't("model_browser.type_chat")') > 0). Fails on the current tree, passes after routing through t().

### 🟡 MEDIUM — Ollama install-flow strings bypass t() (one has an existing key the current guard test misses; one has no key)

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/modules/llm/ollama_deps_checker.ahk:318`, `static/ergopti_plus/windows/modules/llm/ollama_deps_checker.ahk:312`
- **Problème** : Two install-flow strings do not go through the locale system. (a) Line 318: TrayTip("Ergopti — IA", t("llm.deps.browser_install_tip"), 0x1) hardcodes the tray title even though key llm.deps.tray_title = "Ergopti — IA" exists in all 21 locales and its sibling ui/menu/menu_llm/actions.ahk uses t("llm.deps.tray_title") at lines 62/67/77. The existing guard test_ui_style_llm_tray_i18n.ahk:33 only asserts t("llm.deps.tray_title") appears somewhere in the driver source — actions.ahk satisfies it — so this hardcoded copy in ollama_deps_checker.ahk slips through. (b) Line 312: LLM_Deps_Fail("Impossible d'ouvrir la page de téléchargement Ollama.", on_failed) hardcodes a French failure message; the other LLM_Deps_Fail call at line 367 uses t("llm.deps.fail_timeout"). No matching key exists for the browser-open failure. Both surface to non-French users in French.
- **Correctif** : Line 318 → t("llm.deps.tray_title") for the title. Line 312 → add a new key (e.g. llm.deps.fail_open_browser) to all 21 _shared/data/locales/*.json and call LLM_Deps_Fail(t("llm.deps.fail_open_browser"), on_failed). Then tighten test_ui_style_llm_tray_i18n.ahk so a hardcoded title can never recur.
- **Test de non-régression** : Strengthen (or add alongside) the meta guard: Assert(!InStr(_DriverSourceNoComments(), 'TrayTip("Ergopti — IA"'), 'no driver file may hardcode the Ergopti — IA tray title — use t("llm.deps.tray_title")') and Assert(!InStr(Src, "Impossible d'ouvrir la page de téléchargement Ollama"), 'ollama browser-open failure must use t("llm.deps.fail_open_browser")'). Red now (both literals present), green after.

### 🟡 MEDIUM — Model-type labels "Complétion"/"Chat" hardcoded in tray menu while the web UI localizes the same concept

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/ui/menu/menu_llm/init.lua:497`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_selector.lua:389`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_selector.lua:446`
- **Problème** : Three native menu sites build the model-type badge as (info.type == "completion") and " [📝 Complétion]" or " [💬 Chat]" (and "📝 Complétion"/"💬 Chat" at models_selector:446), embedding these titles directly in menu item strings. The identical concept is already localized: keys model_browser.type_completion ("Complétion"/"Completion") and model_browser.type_chat ("Chat") exist in all locales and are consumed by the shared web UI at _shared/ui/model_browser/script.js:188. So the model browser is translated but the tray menu shows French to all 21 locales — an SSoT drift plus i18n gap.
- **Correctif** : Reuse the existing keys: type_str = (info.type == "completion") and (" [📝 " .. i18n.get("model_browser.type_completion") .. "]") or (" [💬 " .. i18n.get("model_browser.type_chat") .. "]") at all three sites (emoji prepended in code, label from i18n). No new locale values required.
- **Test de non-régression** : macos meta test asserting menu_llm/init.lua and menu_llm/models_selector.lua contain no bare "Complétion"/"Chat" string literals (only i18n.get("model_browser.type_*")). Red now, green after the refactor; locks the tray menu to the same source the web UI uses.

### 🟡 MEDIUM — App-classification chooser placeholder hardcoded French while sibling placeholders use i18n

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/ui/metrics_apps/init.lua:241`
- **Problème** : chooser:placeholderText("Choisir une application à classer…") is a bare French literal shown as the search-field placeholder of the app-category chooser. The same file already routes two other chooser placeholders through i18n — line 213 i18n.get("metrics_apps.rename_chooser_placeholder") and line 218 i18n.get("metrics_apps.chooser_placeholder") — so this one line is an inconsistent outlier that renders French in every non-French locale.
- **Correctif** : Add key metrics_apps.classify_chooser_placeholder to all 21 locale files and call chooser:placeholderText(i18n.get("metrics_apps.classify_chooser_placeholder")).
- **Test de non-régression** : macos meta test grepping metrics_apps/init.lua for absence of the bare "Choisir une application" literal and asserting the new key resolves for en+fr (same pattern already used by tests/unit/ui/test_metrics_apps_default_category.lua for the "Général" literal).

### 🟡 MEDIUM — Download-stall notification body is hardcoded French

**Driver** : macos  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua:333`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua:334`
- **Problème** : The stall watchdog sets reason to bare French — "Aucun progrès détecté depuis 2 minutes à 99 %. Blocage probable." or "Aucun progrès détecté depuis 5 minutes. Abandon." — and passes it as the body of notifications.notify(i18n.get("mlx.download_stalled"), reason, "warning") at line 335. The notification TITLE is localized but the body is French for all locales.
- **Correctif** : Add locale keys (e.g. mlx.download_stalled_99pct and mlx.download_stalled_generic) to all 21 files and set reason = i18n.get(...). Note the two matching keys are user-facing bodies; the script-protocol string "Terminé !" at line 386 is an internal parse token emitted by the generated script and is NOT user-facing (leave it).
- **Test de non-régression** : macos meta test grepping models_manager_mlx_download.lua for absence of "Aucun progrès détecté" literals and asserting the new keys resolve for en+fr.

### 🟡 MEDIUM — Updater tray menu labels hardcoded French in get_menu_label() despite existing menu.about.update_* locale keys

**Driver** : get_menu_label() feeds the 'Check for updates' tray item text (menu_builder.lua:558). It returns French literals for eve  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/updater/manager.lua:714-733`
- **Problème** : get_menu_label() returns 'Vérification en cours…' (716), 'Téléchargement en cours…' (719), 'Installation en cours…' (722), 'Mettre à jour → '..tag (727), 'Rechercher les mises à jour (dev)' (730), 'Rechercher les mises à jour' (732). Matching keys exist: menu.about.update_checking, update_downloading, update_installing, update_now, check_for_updates, channel_dev. The module does not require lib.i18n.
- **Correctif** : require('lib.i18n') and return i18n.get('menu.about.update_checking') etc., composing the tag into menu.about.update_now (which should carry a %s/placeholder). Keep the French text only as the fr.json value.
- **Test de non-régression** : In tests/unit/meta/test_updater_manager.lua stub lib.i18n so get('menu.about.update_checking')='SENTINEL_CHK', set _state='checking' (via the module's state setter/callback), assert get_menu_label()=='SENTINEL_CHK'. Red now (returns the French literal), green after routing.

### 🟡 MEDIUM — WebKitGTK window title bars hardcoded in English in webview_manager._app_title, bypassing existing *.window_title locale keys

**Driver** : Every managed webview window ('Ergopti — <title>') gets its title from a hardcoded English lookup table, so the OS windo  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/linux/modules/ui/webview_manager.lua:366-386`, `static/ergopti_plus/linux/modules/ui/webview_manager.lua:416`
- **Problème** : _app_title() maps app_name -> English literal ('Diagnostic', 'Setup Wizard', 'Hotstring Editor', 'Model Browser', 'Metrics — Apps', 'Download', 'Paths Editor', 'Personal Info', 'Token Settings', …) and line 416 uses it for the GTK window title. Locale keys already exist for these windows: hs_config.window_title, editor.hotstrings.window_title, editor.personal_info.window_title, model_browser.window_title, metrics_apps.window_title, download_window.window_title, changelog_window.window_title, token_prompt.window_title, menu.paths.window_title. None are consulted.
- **Correctif** : Map each app_name to its window_title locale key and resolve via lib.i18n.get(); fall back to the humanized app_name only when no key is registered. Keep the English text as the en.json value, not a source literal.
- **Test de non-régression** : Add tests/unit/meta/test_webview_window_titles.lua: for the app_name->key mapping, assert each referenced *.window_title key resolves to a non-key string in _shared/data/locales/fr.json (drift gate), and stub lib.i18n to confirm _app_title routes through i18n.get for a known app (e.g. 'healthcheck' -> sentinel). Red now (returns hardcoded 'Diagnostic'), green after wiring.

### ⚪ LOW — Keyboard-shortcut slot menu labels hardcode French "Espace"/"Entrée"

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/lib/config_io.ahk:542`
- **Problème** : _FormatSlotLabel() builds the tray labels for user-assignable keyboard-shortcut slots from static _KeyNames := Map("space", "Espace", "enter", "Entrée", "period", ".", "comma", ",", "sc029", "²"). It is rendered into menu items at config_io.ahk:581 (RegisterMenuItem(GMenu, _FormatSlotLabel(Slot) . " : " . ActionLabel, …)), so e.g. a Ctrl+Space slot shows "Ctrl + Espace : …" in French regardless of locale. Key ui_typing.key_enter ("Entrée"/"Enter") already exists in all locales; there is no key yet for Space.
- **Correctif** : Build the key names from the locale: read t("ui_typing.key_enter") for enter, and add a new ui_typing.key_space key across the 21 locales for space, then map through t() in _FormatSlotLabel (keep ".", ",", "²" as symbols — those are locale-neutral).
- **Test de non-régression** : Meta source-scan test: Body := _DriverFuncBody("_FormatSlotLabel"); Assert(!InStr(Body, '"Espace"') && !InStr(Body, '"Entrée"'), '_FormatSlotLabel must not hardcode French key names — route Space/Enter through t()'). Red before, green after.

### ⚪ LOW — Magic-key editor dialog hardcodes "→ Echap" (also an un-accented typo)

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/editors.ahk:16`
- **Problème** : MagicKeyEditor() adds GuiToShow.Add("Text", "w300", t("button.cancel") . " → Echap"). The Escape-key hint " → Echap" is a hardcoded French literal spliced onto an otherwise-localized string, so non-French users see a stray French token. It is also mis-spelled ("Echap" without the accent) versus the canonical locale value "Échap". Key ui_typing.key_esc = "Échap"/"Esc" already exists in all locales.
- **Correctif** : Use t("button.cancel") . " → " . t("ui_typing.key_esc"). Removes the hardcoded French and the typo in one move.
- **Test de non-régression** : Meta source-scan test: Assert(!InStr(_DriverSourceNoComments(), " → Echap"), 'editors.ahk magic-key dialog must build the Escape hint via t("ui_typing.key_esc")'). Red before the fix, green after.

### ⚪ LOW — Dead global MenuHotstrings hardcodes "⚡ Hotstrings", duplicating the locale value it should read

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/tray_menu.ahk:40`
- **Problème** : global MenuHotstrings := "⚡ Hotstrings" hardcodes a menu title that already lives in the locale system as menu.hotstrings.title = "⚡ Hotstrings" (fr.json:777) — the live hotstrings submenu title is actually built via t("menu.hotstrings.title") at ui/menu/menu_init.ahk:135. The MenuHotstrings global has no other reference in the driver (only its definition), so it is simultaneously dead code and a single-source-of-truth violation: if it were ever rendered it would show French on every locale. Its siblings on lines 41/45/46 already use t().
- **Correctif** : Delete the unused global. If a variable is genuinely wanted, initialise it from the canonical source: global MenuHotstrings := t("menu.hotstrings.title").
- **Test de non-régression** : Meta source-scan test: Assert(!InStr(_DriverSourceNoComments(), 'MenuHotstrings := "⚡ Hotstrings"'), 'tray_menu.ahk must not hardcode the hotstrings menu title — it lives in menu.hotstrings.title'). Red now, green after removal/rewire.

### ⚪ LOW — LLM tooltip "Génération en cours…" spinner has a hardcoded French fallback

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/tooltip/llm.ahk:182`, `static/ergopti_plus/windows/ui/tooltip/llm.ahk:647`, `static/ergopti_plus/windows/ui/tooltip/llm.ahk:728`
- **Problème** : The generating-spinner label is built as (IsSet(t)) ? t("llm.generating") : "⏳ Génération en cours…" at three sites. The primary path correctly uses key llm.generating (present in all locales), but the IsSet(t) fallback hardcodes French, so any locale would get French text if t were ever unavailable at that point. The fallback is defensive (t is defined at runtime), which is why this is low, but a hardcoded French UI fallback contradicts the localize-everything goal and would mask a real locale-load failure with French rather than surfacing it.
- **Correctif** : Since t() is always defined in the running driver, call t("llm.generating") directly (drop the IsSet(t) ternary). If a fallback is retained for standalone/test loading, make it English (developer-facing default) rather than French, e.g. "⏳ Generating…".
- **Test de non-régression** : Meta source-scan test on tooltip/llm.ahk: assert the count of loading-label assignments that reference t("llm.generating") equals the number of loading-label sites, and Assert(!InStr(Src, ': "⏳ Génération en cours…"'), 'llm.ahk must not carry a hardcoded French generating-spinner fallback'). Red before, green after.

### ⚪ LOW — French "Inconnu" fallbacks leak into model name/type display

**Driver** : macos  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/macos/ui/menu/menu_llm/models_selector.lua:382`, `static/ergopti_plus/macos/ui/menu/menu_llm/models_selector.lua:445`
- **Problème** : m_name = m.name or m.repo or "Inconnu" (line 382) and m_type = m.type or info.type or "Inconnu" (line 445) fall back to the bare French word "Inconnu" for display. When a model entry lacks a name/type, non-French users see "Inconnu" in the tray menu title and type-spec line. Low severity because it only appears on malformed/incomplete model metadata.
- **Correctif** : Add a common.unknown locale key (or reuse an existing one if present) across all 21 files and replace the "Inconnu" fallbacks with i18n.get("common.unknown").
- **Test de non-régression** : macos meta test asserting models_selector.lua contains no bare "Inconnu" literal and that common.unknown resolves for en+fr.

### ⚪ LOW — Daemon startup/fallback UI strings hardcoded French (fallback tray menu, keyboard-hook error, CLI help)

**Driver** : Several user-facing daemon strings outside the main menu path are hardcoded French: the degraded fallback tray menu, the  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/linux/ergopti_hotstrings.lua:480`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:562-563`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:348`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:221-232`
- **Problème** : Line 480 print('Erreur : impossible de démarrer le hook clavier.') and 348 print('Erreur : aucun périphérique clavier détecté...') are French terminal errors; lines 562-563 build a fallback tray menu with title 'Ergopti '..layout and 'Quitter' (French, duplicating menu.global.quit); lines 221-232 emit the --help usage entirely in French. The fallback 'Quitter' item should reuse the same locale key as the real Quit item.
- **Correctif** : Route the fallback tray items through i18n.get (menu.global.quit for 'Quitter'). For the two fatal-error prints, decide policy: if they are user-facing GUI-less errors, localize via i18n.get with a startup key; if treated as developer/terminal diagnostics, convert to English Logger.error to comply with 'logs are English'. CLI --help is borderline terminal text; at minimum make 'Quitter' single-sourced. (Lowest priority: CLI help localization.)
- **Test de non-régression** : In tests/unit/meta covering the fallback menu path, stub lib.i18n so get('menu.global.quit')='SENTINEL_QUIT' and assert the fallback tray menu's quit item title == 'SENTINEL_QUIT' rather than 'Quitter'. Red now, green after single-sourcing the quit label.

### ⚪ LOW — Tray menu is built before i18n.init() loads the persisted locale, so the first render uses the fr default even for the wired section titles

**Driver** : Ordering bug: menu_builder.build() runs and setMenu() is called before i18n_mod.init() applies the user's saved locale,   ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/linux/ergopti_hotstrings.lua:558-559`, `static/ergopti_plus/linux/ergopti_hotstrings.lua:573-577`
- **Problème** : menu_items = menu_builder.build(...) and tray_menu.setMenu(menu_items) execute at 558-559, but i18n.init() (which calls _load_persisted_locale() and locale_mod.set_locale) only runs at 573-577. locale/core defaults to 'fr' (shared/lua/locale/core.lua:79), so a user whose stored locale is e.g. 'de' sees French section titles until the menu is rebuilt (e.g. an updater callback). i18n should be initialized before the menu is first built.
- **Correctif** : Move the i18n init block (573-577) ahead of the tray/menu build block (starting ~485), so the persisted locale is active when menu_builder.build() first resolves keys.
- **Test de non-régression** : Add a daemon-CLI/smoke assertion (tests/unit/meta/test_daemon_cli.lua style) that the i18n initialization step is sequenced before the first menu build — e.g. instrument the startup to record the order of i18n.init vs menu_builder.build and assert i18n.init ran first. Red now (menu built first), green after reordering.


## 3.5 Qualité & couverture des tests

### 🟠 HIGH — ~50 registered tests are no-op placeholders that pass unconditionally while advertising behavioral guarantees (false green)

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/tests/unit/test_timer_scheduler.ahk:278`, `static/ergopti_plus/windows/tests/unit/test_timer_scheduler.ahk:285`, `static/ergopti_plus/windows/tests/unit/test_timer_scheduler.ahk:292`, `static/ergopti_plus/windows/tests/unit/test_hotstrings_full.ahk:36`, `static/ergopti_plus/windows/tests/unit/test_hotstrings_full.ahk:43`, `static/ergopti_plus/windows/tests/unit/test_hotstrings_config.ahk:412`, `static/ergopti_plus/windows/tests/unit/test_hotstring_engine.ahk:322`, `static/ergopti_plus/windows/tests/unit/test_llm_profiles.ahk:40`, `static/ergopti_plus/windows/tests/unit/test_llm_prediction_engine.ahk:180`, `static/ergopti_plus/windows/tests/unit/test_adapter_compliance_new.ahk:63`, `static/ergopti_plus/windows/tests/unit/test_adapter_compliance_new.ahk:70`, `static/ergopti_plus/windows/tests/unit/test_domain_expander.ahk:35`, `static/ergopti_plus/windows/tests/unit/test_domain_expander.ahk:41`, `static/ergopti_plus/windows/tests/meta/test_processentry32w_size.ahk:47`, `static/ergopti_plus/windows/tests/meta/test_processentry32w_size.ahk:50`, `static/ergopti_plus/windows/tests/unit/test_logger.ahk:423-496 (9 healthcheck tests)`, `static/ergopti_plus/windows/tests/unit/test_logger_contract.ahk:54`, `static/ergopti_plus/windows/tests/unit/test_keylogger_reader.ahk:46`, `static/ergopti_plus/windows/tests/unit/test_personal_toml_editor.ahk:55`, `static/ergopti_plus/windows/tests/unit/test_tap_hold_loader.ahk:261`
- **Problème** : Roughly 50 calls to Test() across ~16 files register a case whose entire callback body is a single tautological assertion — AssertTrue(true, "..."), Assert(true, "..."), a bare AssertTrue(1), or AssertEqual(568, 568) (test_processentry32w_size.ahk:47). They invoke zero production code, so they PASS even if the named invariant is completely violated. Yet the test names and messages promise concrete behavior: "TimerScheduler every(): must be silent under pause", "Hotstrings full: per-section delay precedence", "Domain expander: pause must silence every expansion path", "Healthcheck: keylogger summary must be accurate under pause". This directly defeats the goal that green tests prove correctness — the suite reports coverage it does not have, and these lines can never point at a fault because they can never fail. The maintainer already diagnosed and fixed six identical placeholders in test_shortcuts.ahk (see the comment at test_shortcuts.ahk:498-506: "used to be bare AssertTrue(true, ...) placeholders that exercised zero production code -- they would have passed even if every dispatcher ignored A_IsSuspended entirely"), so the anti-pattern is known and the fix template exists. Critically, many offenders sit in modules that ARE loaded and behaviorally tested elsewhere in the same file: test_timer_scheduler.ahk exercises TimerEvery/exception-isolation with real assertions immediately above the three no-ops, and hotstring section>group delay precedence is really tested by test_hotstrings_config.ahk + the shared config_resolve corpus — so these are not 'headless-impossible', just unwritten. Two of them (test_domain_expander.ahk:35,41) are additionally malformed: the Test() registrations are nested inside the _DE_Add() helper body (opens at line 30, closes at line 47), so they only register when _DE_Add is invoked and re-register on every call.
- **Correctif** : For offenders in loaded modules, replace the placeholder with the real behavioral check the name promises: e.g. TimerScheduler under-pause -> Suspend(1); register TimerEvery(1,()=>fired:=true); pump; assert !fired; Suspend(0). High-volume/leak -> register+cancel 200 timers and assert the scheduler's handle table returns to its baseline size. Section-delay precedence -> LoadHotstringsToml a snippet with section+group+default delays and assert the accessor returns the section value. For claims that genuinely need a live message pump / OS focus, convert to a comment-stripped source-scan guard via _DriverFuncBody()/_DriverDirConcat() exactly as test_shortcuts.ahk now does (assert the dispatch body contains the A_IsSuspended gate), or delete the test outright rather than leave a false-green. Move the two test_domain_expander.ahk Test() calls out of _DE_Add to file scope. Delete the tautological second test in test_processentry32w_size.ahk (the sibling source-scan test already guards PE32_SIZE=568).
- **Test de non-régression** : Add meta/test_no_noop_placeholder_assertions.ahk: iterate every test_*.ahk, and for each Test("name", Fn) locate Fn's body; fail (listing name + file:line) when the body's only assertions are literal-true/self-equal (AssertTrue(true|1), Assert(true|1), AssertEqual(L,L) with identical literal args) and the body contains no other Assert with a non-literal argument. Seed it with a tiny explicit allowlist for the honest conditional-skip branches, and ratchet the allowlist toward empty — mirroring the existing meta/test_ahk_os_purity_ratchet.ahk. It fails today on the ~50 offenders and passes once each is made real, scanned, or removed.

### 🟠 HIGH — HealthCheck diagnostic subsystem (ui/healthcheck/core.ahk) has no behavioral test; its 9 'under pause' tests are no-ops and RecordWarn/RecordError is only literal-source-scanned

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/healthcheck/core.ahk:73 (HealthCheck_RecordError)`, `static/ergopti_plus/windows/ui/healthcheck/core.ahk:81 (HealthCheck_RecordWarn)`, `static/ergopti_plus/windows/ui/healthcheck/core.ahk:105 (HealthCheck_Run)`, `static/ergopti_plus/windows/tests/unit/test_logger.ahk:432-438 (asserts nothing; intended assertion left as a comment on line 436)`, `static/ergopti_plus/windows/tests/meta/test_healthcheck_recordwarn_called.ahk:14-15`, `static/ergopti_plus/windows/tests/run_all.ahk (includes ui/healthcheck/helpers.ahk but not core.ahk)`
- **Problème** : HealthCheck_Run() (the snapshot orchestrator surfaced to users for support), plus the HealthCheck_RecordError/RecordWarn counters, live in ui/healthcheck/core.ahk, which run_all.ahk never #Includes — so none of it is callable in the suite. The 9 'Healthcheck: ... under pause' tests in test_logger.ahk are therefore all AssertTrue(true) no-ops; test_logger.ahk:436 even spells out the intended assertion in a comment ("assert Snapshot['logs']['errors_today'] contains the path") and then asserts a literal true. The only guard on the counters is test_healthcheck_recordwarn_called.ahk, which greps the concatenated lib source for the exact call expressions "HealthCheck_RecordWarn()" and "HealthCheck_RecordError(Body)" — it verifies neither that the counters increment nor that HealthCheck_Run assembles a valid snapshot, and it is brittly coupled to call syntax (adding an argument to RecordWarn silently breaks it). The counter functions are pure integer accumulators and HealthCheck_Run reads adapters that are already loaded; core.ahk's header states functions/globals are hoisted and load-order-independent, and the WebView2 window is only built on demand — so the subsystem is unit-testable, it is simply not wired in.
- **Correctif** : Add #Include ../ui/healthcheck/core.ahk to run_all.ahk (guard the WebView2 window builder behind its existing on-demand call path so load stays headless-safe). Replace the 9 no-op tests with real assertions in a dedicated unit/test_healthcheck_core.ahk: LoggerWarn/LoggerError then assert the warn/err counters increment by exactly one; HealthCheck_Run() returns a Map carrying the documented keys (pause_state.is_paused, logs.errors_today path, keylogger summary) and reflects is_paused=true under a simulated suspend; a collector whose backing module is absent degrades to "unknown"/"n/a" via pcall instead of throwing. If a hard load-time dependency truly blocks including core.ahk, at minimum delete the 9 placeholder tests (they manufacture false coverage) and upgrade test_healthcheck_recordwarn_called.ahk to a behavioral counter-increment check.
- **Test de non-régression** : unit/test_healthcheck_core.ahk asserting: (1) RecordWarn()/RecordError() each bump their counter by one and RecordError stores the last message; (2) HealthCheck_Run() returns a Map with pause_state.is_paused == true under simulated suspend and a non-empty logs.errors_today path after an error is emitted; (3) HealthCheck_Run() does not throw when a collector's module globals are unset. These replace the no-ops and would fail today (functions unresolved) until core.ahk is wired in.

### 🟠 HIGH — lib/i18n — the 21-language backbone — is never behaviorally tested (always stubbed)

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/lib/i18n.lua:91`, `static/ergopti_plus/macos/lib/i18n.lua:119`, `static/ergopti_plus/macos/lib/i18n.lua:161`, `static/ergopti_plus/macos/lib/i18n.lua:241`, `static/ergopti_plus/macos/tests/helpers/init.lua:191`, `static/ergopti_plus/macos/init.lua:154`
- **Problème** : lib/i18n.lua (299 LoC) is the boot-wired translation facade for the project's explicit 21-language goal: detect_system_locale() maps hs.host.locale.current() (e.g. "fr_FR", "en_GB", "zh_Hans_CN") to a supported code with an "en" fallback; is_known() is the gate over the ~25 LOCALES entries; get() falls back to the raw key when a string is missing; set_locale()/persist_locale() reject unknown codes; get_sorted_locales() must keep non-Latin script names at the tail. NONE of this is exercised: tests/helpers/init.lua:191 injects a trivial stub ({get=function(k) return k end,...}) into package.loaded["lib.i18n"] for EVERY test, so the real module's branching logic is never loaded or asserted. lib/locale (the lower-level JSON resolver) is tested (test_locale.lua) but i18n is not. A regression in detect_system_locale (e.g. mis-slicing the prefix so "en_GB"->"en" breaks, or a country-only locale is accepted) or in is_known ships silently — it only manifests as wrong-language menus on a user's Mac.
- **Correctif** : Add a dedicated behavioral test for the real lib/i18n. Note the shadowing trap: load_with_stubs() sets package.loaded["lib.i18n"] to the stub at helpers/init.lua:191 BEFORE its final require, so requiring "lib.i18n" through it returns the stub. The test must instead build the hs stub, then set package.loaded["lib.i18n"]=nil and require("lib.i18n") directly (stubbing hs.host.locale.current, hs.settings, hs.timer, and lib.locale).
- **Test de non-régression** : New tests/unit/lib/test_i18n.lua in the macOS unit suite asserting: detect_system_locale returns "fr" for "fr_FR", "en" for "en_GB", "en" for an unknown "xx_YY", and "en" when hs.host.locale is absent; is_known accepts every LOCALES code and rejects "xx"; get(key) returns the raw key when the injected locale_mod.get yields nil/""; set_locale(unknown) writes nothing to hs.settings and schedules no reload; get_sorted_locales() is alphabetical (case-insensitive) with non-Latin names ordered after Latin ones.

### 🟠 HIGH — api_mlx_fetch dispatch/retry logic is untested — its only test asserts the functions exist

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/modules/llm/api_mlx_fetch.lua:174`, `static/ergopti_plus/macos/modules/llm/api_mlx_fetch.lua:151`, `static/ergopti_plus/macos/modules/llm/api_mlx_fetch.lua:47`, `static/ergopti_plus/macos/tests/unit/modules/llm/test_api_mlx.lua:35`
- **Problème** : api_mlx_fetch.lua owns the MLX prediction fan-out: fetch_sequential (retry policy via RETRY_FAILED_PREDICTION/max_attempts, per-variant one-shot retry on failure, dedup insertion, and mid-flight cancellation when request_id_provider() changes), fetch_parallel which deliberately redirects to fetch_sequential for stability, and the require_ctx guard that must invoke on_fail when called before init(). The ONLY test touching this surface (test_api_mlx.lua:35-37) does helpers.assert_eq(type(ApiMlx.fetch_batch),"function") — pure existence checks. A grep of the suite shows zero behavioral drive of fetch_sequential/fetch_batch. A regression (retry loop off-by-one, cancellation not honored, dedup dropping valid predictions, or fetch_parallel silently going truly-parallel again) degrades predictions with no failing test.
- **Correctif** : Test the dispatch behavior with an injected fake inference layer. Call M.init({post_and_parse=fake, post_and_parse_streaming=fake, dedup_enabled=true}) where fake records its args and synchronously invokes the success/fail callbacks per a scripted plan, plus a stubbed adapters.timer_scheduler whose after() runs immediately.
- **Test de non-régression** : New tests/unit/modules/llm/test_api_mlx_fetch.lua asserting: (a) a variant that fails once then succeeds triggers exactly one retry then advances; (b) fetch_sequential stops after requested_predictions successes; (c) on_fail fires when all attempts yield zero results; (d) a request_id_provider that returns a changed id aborts do_next with no further post_fn calls; (e) fetch_parallel issues the same sequential call pattern as fetch_sequential (never concurrent); (f) fetch_batch/fetch_sequential called before init() invoke on_fail and do not throw.

### 🟠 HIGH — test_input_reader_decode tests nothing — the evdev binary decoder has zero real coverage

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/unit/meta/test_input_reader_decode.lua:26`, `static/ergopti_plus/linux/tests/unit/meta/test_input_reader_decode.lua:45`, `static/ergopti_plus/linux/modules/hotstrings/input_reader.lua:192`, `static/ergopti_plus/linux/modules/hotstrings/input_reader.lua:218`, `static/ergopti_plus/linux/modules/hotstrings/input_reader.lua:264`
- **Problème** : The file is named test_input_reader_decode and its header (lines 3-9) promises coverage of 'The evdev struct parser (parse_event, decode_u16_le, decode_s32_le) ... pure functions testable on any OS.' It covers none of it. The decode_u16_le case ends with `helpers.assert_true(true)  -- structure test` (line 26). The 'parse_event decodes a well-formed 24-byte input_event' case (lines 29-53) painstakingly builds a synthetic input_event byte buffer for KEY_A-down, then never feeds it to parse_event — it only asserts `type(reader)=="table"` and that start/stop are functions; the `data` buffer is dead. Everything the daemon relies on to turn raw kernel bytes into characters — little-endian decode, the 24-byte struct offsets (OFFSET_TYPE/CODE/VALUE), EV_KEY filtering, shift tracking, key-repeat(value=2)/keyup(value=0) suppression, and BACKSPACE/ENTER/TAB routing to on_control — is exercised nowhere. start() is only run against /dev/null (immediate EOF) and a nonexistent device, so the read loop body never runs. A regression in endianness, an offset, or the value!=KEY_DOWN filter (which would fire hotstrings twice on held keys) passes green. (resolve_char IS covered in test_keycode_single_source.lua; the binary struct layer is not.)
- **Correctif** : Expose the decoder and a pump seam analogous to keyboard_hook's existing `_test_inject_and_pump`: add M._parse_event(data) (delegating to the local parse_event) and M._test_feed_event(reader, data) that runs one loop iteration against a caller-supplied 24-byte buffer instead of io.read. Then assert real decode behavior.
- **Test de non-régression** : In tests/unit/meta/test_input_reader_decode.lua (run by `luajit tests/run.lua`): feed a synthetic 24-byte input_event {type=1,code=30(KEY_A),value=1} and assert on_char receives 'a' on qwerty, 'A' after a code-42 shift-down, 'q' on azerty; assert value=2 (repeat) and value=0 (up) emit nothing; assert codes 14/28/15 route to on_control('backspace'/'enter'/'tab'); assert M._parse_event on a 23-byte string returns nil (no crash); assert decode_s32_le on 0xFF,0xFF,0xFF,0xFF == -1 (sign handling).

### 🟠 HIGH — Injector (critical OS output path) has only 'does not crash' tests; command composition unverified despite header claiming otherwise

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/unit/meta/test_injector_commands.lua:23`, `static/ergopti_plus/linux/tests/unit/meta/test_injector_commands.lua:5`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:77`, `static/ergopti_plus/linux/modules/hotstrings/injector.lua:98`
- **Problème** : injector.inject is THE output path of the whole hotstring feature (erase N chars, then type the replacement via ydotool). Every test in test_injector_commands.lua asserts only `pcall(...)` success. The header comment (lines 5-6) explicitly claims 'these tests verify the command strings are well-formed' — but nothing verifies any command string. There is no assertion that inject(3,text) emits exactly three `14:1 14:0` down/up pairs (send_backspaces, injector.lua:77-92), nor that single quotes in the replacement are escaped to '\'' before reaching `ydotool type` (send_text, injector.lua:98-110). A regression that miscounts backspaces (deleting the wrong number of characters) or drops the escaping passes every test.
- **Correctif** : injector composes commands through os.execute (via shell_run). In the test, stub the global os.execute to record the command strings before helpers.load_module, then assert exact composition.
- **Test de non-régression** : tests/unit/meta/test_injector_commands.lua: replace os.execute with a capturing stub; inject(3,'hi') → a 'ydotool key' command containing exactly three '14:1 14:0' pairs and no more; inject(2,"it's") → a 'ydotool type' command whose payload is `'it'\''s'` (single quote neutralized); inject(0,'x') emits no 'ydotool key' command at all.

### 🟠 HIGH — Privacy-critical secure_field_detector.isSecureApp has zero tests

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/adapters/secure_field_detector.lua:41`, `static/ergopti_plus/linux/adapters/secure_field_detector.lua:145`
- **Problème** : isSecureApp(appId) is a pure, OS-independent function that gates whether keystrokes may be logged in credential managers (1Password, Bitwarden, KeePassXC, etc. — SECURE_APP_IDS, lines 41-52). It has no test — no file requires adapters.secure_field_detector, and the port-presence test does not cover it either. A regression that drops an entry, breaks the `:lower()` normalization (line 147), or narrows the match silently starts leaking keystrokes in a password manager. The keylogger already ships a 'coverage must never narrow' privacy lock (test_keylogger.lua:107) and its own comment warns that delegating to an exact-match secure_field_detector 'would silently stop matching these and leak keystrokes' — yet that detector itself is unguarded.
- **Correctif** : Add tests/unit/meta/test_secure_field_detector.lua with an explicit must-cover privacy list and case-insensitivity assertions, mirroring the keylogger lock.
- **Test de non-régression** : Assert isSecureApp returns true for every key in SECURE_APP_IDS plus case variants ('BITWARDEN','KeePassXC'), and false for 'firefox'/''/nil; drive an explicit must_match list (1password,bitwarden,keepassxc,lastpass,dashlane,gnome-keyring-3,seahorse,gnome-authenticator,authenticator,yubikey-manager) so coverage can never narrow; assert isSecureField() defaults to false with no D-Bus session.

### 🟠 HIGH — Shared hotstring_engine (Linux's real production matcher) is never replayed against the golden hotstrings corpus — UTF-8 backspace-count and word-boundary vectors bypass it entirely

**Driver** : cross-cutting / linux (shared _shared/lua/hotstring_engine)  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/_shared/lua/hotstring_engine/init.lua:88-105 (utf8_codepoints)`, `static/ergopti_plus/_shared/lua/hotstring_engine/init.lua:111-119 (tail_codepoints)`, `static/ergopti_plus/linux/modules/hotstrings/engine.lua:35 (production consumer: require("hotstring_engine"))`, `static/ergopti_plus/linux/tests/unit/meta/test_shared_hotstring_engine.lua (hand-written, ASCII-only)`, `static/ergopti_plus/linux/tests/unit/meta/test_corpus_cross_driver.lua:113-128 (hotstrings corpus loaded but only id/description structure checked, comment claims engine 'is loaded and tested' elsewhere)`, `static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json:197-255 (utf8_trigger_two/three_codepoints, word_boundary_after_newline/tab vectors)`
- **Problème** : The shared engine is production code on exactly one driver — Linux (linux/modules/hotstrings/engine.lua re-exports it). macOS replays the golden corpus hotstrings/vectors.json through its OWN registry (test_corpus_hotstrings.lua) and Windows through its OWN AHK engine (test_corpus_hotstrings.ahk), but the shared engine — the actual Linux matcher — is never fed the corpus. The Linux corpus consumer (test_corpus_cross_driver.lua §2) only asserts each vector has an id + description; it explicitly does NOT run vectors through the engine. The only functional test (test_shared_hotstring_engine.lua) is hand-written and ASCII-only (btw/the/afaik). Consequently the corpus's UTF-8 vectors (trigger 'cé' expects backspace_count=2 not 4; 'àèù' expects 3 not 6) and the newline/tab word-boundary vectors never exercise utf8_codepoints()/tail_codepoints() — the exact codepoint-vs-byte logic those vectors were written to pin. A regression that made utf8_codepoints return byte counts would silently break Linux hotstring expansion for every accented trigger while all three test suites stay green.
- **Correctif** : Add a Linux corpus consumer that replays the golden corpus through the shared engine (auto-discovered by tests/run.lua's find of test_*.lua): for every vector in hotstrings/vectors.json build engine.new(), load_mappings({{trigger, replacement, is_word, is_case_sensitive}}), feed each codepoint of vector.buffer via on_char (passing {terminator_consumed=vector.terminator_consumed} on the final char), then assert result~=nil == expected.matched, result.replacement == expected.replacement, and result.backspace_count == expected.backspace_count. This makes the shared engine's UTF-8 handling a first-class cross-driver gate rather than a structural checkbox.
- **Test de non-régression** : New file static/ergopti_plus/linux/tests/unit/meta/test_corpus_hotstring_engine.lua that replays every hotstrings/vectors.json vector through require('hotstring_engine'). Red-before: temporarily make utf8_codepoints treat every byte as one codepoint and the 'cé'/'àèù' vectors fail with backspace_count 4/6 != expected 2/3. Optionally add a presence gate in run-js-suite.cjs (mirroring test-toml-coercion-parity.cjs) asserting the Linux consumer file exists and opens hotstrings/vectors.json, so the replay can never be quietly deleted.

### 🟠 HIGH — Word-boundary character class is an ungated cross-driver invariant — the three is_word predicates genuinely disagree and no corpus vector exposes it

**Driver** : cross-driver (linux shared engine / macOS expander / windows AHK engine)  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/_shared/lua/hotstring_engine/init.lua:77-82 (is_word_char: %w_ OR any non-ASCII byte counts as a word char)`, `static/ergopti_plus/macos/modules/keymap/expander.lua:191-206 (word_boundary_blocks: blocks only on text_utils.is_letter_char or '@')`, `static/ergopti_plus/_shared/lua/text_utils/init.lua:413 (is_letter_char)`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_match.ahk:371-376 (allows only if preceding char is in HSE_WORD_TERMINATORS whitelist)`, `static/ergopti_plus/windows/lib/hotstrings/hotstring_engine_main.ahk:76 (HSE_WORD_TERMINATORS = space/tab/cr/lf/.,;:?! + apostrophes)`, `static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json:33-96,227-255 (word-boundary vectors: only letter 'o', space, '.', newline, tab as preceding chars)`
- **Problème** : The corpus's word-boundary vectors only ever put a preceding char that all three engines happen to agree on (letter, space, ASCII '.', newline, tab). But the three implementations classify the boundary char with three incompatible models: (1) shared engine = blacklist — a preceding char blocks the match if it is %w_ OR ANY non-ASCII byte; (2) macOS = blocks only if the preceding char is a letter (is_letter_char) or '@'; (3) AHK = whitelist — allows only if the preceding char is in HSE_WORD_TERMINATORS. Traced divergences that no vector covers: preceding em-dash '—' (or any non-ASCII punctuation / guillemet / U+00A0 nbsp) → Linux(shared) blocks, AHK blocks, macOS EXPANDS; preceding '@' → shared EXPANDS, AHK rejects, macOS rejects. So an is_word trigger typed after a French em-dash or after '@' expands on one driver and not the others, and the cross-driver corpus that claims 'every vector must pass in both drivers without modification' can never catch it because the divergent inputs are absent.
- **Correctif** : Reconcile the three predicates to one documented word-boundary definition (pick the canonical set — e.g. adopt the shared is_word_char semantics as the port contract, mirror it in macOS word_boundary_blocks and the AHK whitelist), then pin it with corpus vectors. The corpus vectors are the gate that forces the reconciliation: until the three impls agree, at least one consumer stays red.
- **Test de non-régression** : Extend static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json with boundary-edge vectors (is_word trigger 'the' preceded by: an em-dash '—', a non-breaking space U+00A0, an '@', a digit '5', an accented letter 'é'), each with a single agreed expected.matched. The existing macOS test_corpus_hotstrings.lua and AHK test_corpus_hotstrings.ahk plus the new Linux shared-engine consumer (finding 1) all replay them; because the impls currently disagree, the suite is red-before and only goes green once the predicate is unified. This encodes the root cause (an unpinned boundary character class), not the symptom.

### 🟡 MEDIUM — Privacy-critical keylogger vectors SEC-007/008 are skipped on Windows with no Windows-side equivalent — the buffer-flush-on-password-focus redaction is unverified

**Driver** : windows  ·  **Confiance** : medium

- **Où** : `static/ergopti_plus/windows/tests/meta/test_corpus_security_keylogger.ahk:111-120`, `static/ergopti_plus/macos/tests/unit/modules/keylogger/test_keylogger_privacy.lua (exercises SEC-007/008)`, `static/ergopti_plus/_shared/tests/corpus/security/keylogger_no_persist_vectors.json`
- **Problème** : In the AHK security-corpus consumer, SEC-007 (keystrokes in a normal, non-secure field ARE logged) and SEC-008 (the in-flight keystroke buffer is flushed/redacted when focus moves into a password field) are dispatched to _SkipLive() which asserts AssertTrue(true, "requires a live keylogger session"). The macOS twin test_keylogger_privacy.lua DOES exercise SEC-007/008, but that validates the Hammerspoon keylogger, a completely separate implementation — it gives zero assurance about the AHK keylogger. So on Windows the corpus's core privacy guarantee (buffer redaction on entering a secure field) has neither a behavioral nor a source-scan guard tied to the corpus vector, even though the class/style password check (SEC-009) proves the redaction *decision* can be exercised headlessly via a pure helper. This is a real dimension-5 gap: a skipped test with the stated justification 'live session required' that is in fact partially testable and is NOT covered by any cross-platform equivalent that exercises the same code. (Coordinate with the password-app privacy coverage lock added earlier this session; if that already exercises the flush, narrow this to wiring SEC-007/008 onto it.)
- **Correctif** : Extract the buffer redaction/flush decision the keylogger performs on a secure-field focus change into a pure, side-effect-free helper (mirroring _KL_ClassAndStyleIsPassword used for SEC-009) that takes the prior buffer + the new field's secure flag and returns the buffer to persist. Have the SEC-007/008 corpus branches call it and assert: normal field -> keystrokes retained; secure field focus -> in-flight buffer cleared before any persist. Replace the two AssertTrue(true) skips with these real consumers.
- **Test de non-régression** : In meta/test_corpus_security_keylogger.ahk, the SEC-007 branch asserts the redaction helper retains buffered chars for a non-secure field, and SEC-008 asserts it returns an empty/redacted buffer when the newly focused field is secure — both failing before the helper exists and green after, replacing the current _SkipLive no-ops.

### 🟡 MEDIUM — lib/personal_shortcuts has no test although the parallel lib/personal_hotstrings does

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/lib/personal_shortcuts.lua:102`, `static/ergopti_plus/macos/lib/personal_shortcuts.lua:126`, `static/ergopti_plus/macos/ui/menu/init.lua:984`, `static/ergopti_plus/macos/tests/unit/lib/test_personal_hotstrings.lua:1`
- **Problème** : lib/personal_shortcuts.lua is loaded at boot via ui/menu/init.lua:984 (pcall(require,"lib.personal_shortcuts") then ps.load()). Its sibling lib/personal_hotstrings.lua has a thorough load-contract test (test_personal_hotstrings.lua) written precisely because 'the Lua suite never loads init.lua, so a missing require or load-order regression would only surface as a boot failure on the maintainer's Mac.' The identical rationale applies to personal_shortcuts, but it has zero coverage. Its real, testable logic — ensure_file() creating the starter template idempotently, and load() wrapping dofile in pcall so a broken user file logs an error but never blocks boot — is unguarded. A regression (e.g. dropping the pcall, or ensure_file overwriting an existing user file) would silently corrupt or fail user setups.
- **Correctif** : Add a load-contract test mirroring test_personal_hotstrings, using tests/scratch_test_dir (already gitkept) as the target dir and stubbing ui.menu.menu_paths.get to point PersonalShortcutsLuaPath there, plus a no-op hs.execute/hs.timer stub.
- **Test de non-régression** : New tests/unit/lib/test_personal_shortcuts.lua asserting: ensure_file() creates the template on first call and, when the file already exists, does NOT overwrite it (write a sentinel, call again, sentinel survives); load() on a syntactically-invalid file returns without throwing (pcall isolation — driver keeps booting) and logs an error; load() on a valid file executes it (observe a global side effect it sets); get_path() returns the resolved path.

### 🟡 MEDIUM — metrics_collector — a whole pure-Lua metrics module — has zero behavioral coverage

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/keylogger/metrics_collector.lua:160`, `static/ergopti_plus/linux/modules/keylogger/metrics_collector.lua:202`, `static/ergopti_plus/linux/tests/unit/meta/test_daemon_smoke.lua:114`
- **Problème** : metrics_collector is pure Lua and, per its own docstring, 'only needs the caller to provide a millisecond timestamp so it can be unit-tested without a real clock.' Yet its only test is daemon_smoke asserting `type(mc.init)=='function'` (test_daemon_smoke.lua:114-121). on_keydown accumulation, get_session_stats (words = floor(keystrokes/5), duration = last-first timestamp), get_wpm, get_ngrams ranking, reset_session, and the require_state guard are all unverified. A regression in the words-per-word divisor, the duration math, or ngram ranking is uncaught.
- **Correctif** : Add tests/unit/meta/test_metrics_collector.lua driving the pure API with synthetic timestamps.
- **Test de non-régression** : init({}); feed 10 on_keydown with strictly increasing timestamps → get_session_stats().keystrokes==10, words==2, duration_ms==(last-first); feed 'a','a','a' → get_ngrams(1)[1] == {gram='aa',count=2}; reset_session() zeroes keystrokes; calling get_session_stats() before init returns the zeroed table (guard fires, no crash).

### 🟡 MEDIUM — port_adapter_presence checks only 9 of 20 port adapters and only file existence — stale vs contracts.json SSoT

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/unit/meta/test_port_adapter_presence.lua:34`, `static/ergopti_plus/linux/tests/unit/meta/test_port_adapter_presence.lua:53`, `static/ergopti_plus/_shared/core/ports/contracts.json:5`
- **Problème** : EXPECTED_ADAPTERS hardcodes 9 file names (lines 34-44) and the test only checks each file opens (lines 53-76). But the generated SSoT contracts.json declares port_count: 20, and linux/adapters/ contains 20 port adapters. So 11 port adapters could be deleted and this test stays green, and five adapters (key_state, network_info, process_lifecycle, secure_field_detector, window_manager) have no test whatsoever and are not flagged. It also never verifies an adapter honours its contract (exports the required methods) — a file with the right name but no methods passes.
- **Correctif** : Drive the test from contracts.json (the generated SSoT): iterate ports, map PascalCase→snake_case filename, assert each file exists, and assert the local expected count == contracts.json port_count so a new port fails until an adapter lands. Ideally also require() each adapter and assert it exports the contract methods (accounting for the AL_/KS_ export prefixes).
- **Test de non-régression** : tests/unit/meta/test_port_adapter_presence.lua: parse contracts.json, assert #ports==20, assert every mapped adapter file opens, and add a drift gate `assert(EXPECTED_COUNT == contracts.port_count)` so adding a 21st port spec without a Linux adapter turns the suite red.

### 🟡 MEDIUM — 'Shell safety' / 'shell injection' tests assert only no-crash, leaving escaping and mode-routing unguarded

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/unit/meta/test_notifier_commands.lua:84`, `static/ergopti_plus/linux/adapters/notifier.lua:63`, `static/ergopti_plus/linux/tests/unit/meta/test_text_sender_adapter.lua:88`, `static/ergopti_plus/linux/tests/unit/meta/test_app_launcher_adapter.lua:63`
- **Problème** : Sections titled 'shell safety' / 'shell injection' assert only `pcall(...)` success. os.execute/io.popen never crash on unescaped input — they execute it — so these tests pass whether or not escaping exists. The notifier single-quote escaping (notifier.lua:63-64) and text_sender escaping are therefore completely unguarded; deleting them is a silent regression AND a real command-injection hole. Their failure messages ('send with shell chars does not crash') also point at nothing actionable. Relatedly, text_sender's 'send large payload triggers clipboard mode in auto' (test_text_sender_adapter.lua:88-95) asserts nothing about the mode actually chosen — the name promises behavior the test never checks.
- **Correctif** : Capture the composed command (stub os.execute and io.popen) and assert the dangerous input is neutralized rather than merely non-crashing; for text_sender assert the >1000-char auto payload takes the xclip/xdotool clipboard branch and a short one takes the ydotool-type branch.
- **Test de non-régression** : notifier.send("x'; rm -rf /", {body='y'}) → captured command contains the escaped `'\''` sequence and no bare `; rm`; text_sender.send(string.rep('x',1500),{mode='auto'}) → captured command is the `xclip -selection clipboard` + `xdotool key ctrl+v` path, while send('hi',{mode='auto'}) → the `ydotool type` path.

### 🟡 MEDIUM — crypto sha256 correctness assertions accept empty string unconditionally — the known-answer check is a no-op

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/unit/meta/test_crypto_adapter.lua:35`, `static/ergopti_plus/linux/tests/unit/meta/test_crypto_adapter.lua:53`
- **Problème** : Every correctness assertion is of the form `digest == "" or digest == <known hash>` (lines 39, 58). Because '' is always accepted, a sha256 that silently returns '' for all inputs passes every test — even on the Linux CI runner where openssl is present. The single real correctness check (empty-string vector) can therefore never fail, and there is no deterministic fallback when openssl is absent (the whole correctness dimension is silently skipped in this environment).
- **Correctif** : Probe openssl once (io.popen('openssl version')). When present, assert the EXACT known digest and reject '' (drop the `or ""` escape hatch). When absent, skip explicitly with a logged 'skipped: openssl unavailable' rather than a silent pass.
- **Test de non-régression** : When openssl is available: assert sha256('') == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 exactly and sha256('abc') == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad exactly (no '' accepted), and #digest == 64.

### 🟡 MEDIUM — E2E backspace-count assertion accepts two values, so the corpus cannot lock Linux behavior

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/e2e/run_e2e.lua:237`
- **Problème** : The shared corpus carries an exact expected backspace_count per vector, but the harness accepts either the trigger codepoint count OR count+1 (lines 239-240: `result.backspace_count == cp_count or == cp_count + 1`). The Linux engine does not consume the terminator, so its correct value is a single number; accepting both means a regression where the Linux engine starts (or stops) consuming the terminator passes green. This runs in CI (the e2e-linux job runs `luajit tests/e2e/run_e2e.lua`), so it is a live blind spot, not dead code.
- **Correctif** : Assert the single Linux-correct backspace count (trigger codepoints, with terminator consumption defined explicitly for Linux), or add a backspace_count_linux field to vectors.json and assert against it exactly.
- **Test de non-régression** : In run_e2e.lua, for a plain vector (trigger 'btw', terminator ' ') assert result.backspace_count == 3 exactly (never '3 or 4'); add a hardcoded scenario proving the terminator is NOT part of the deletion on Linux.

### 🟡 MEDIUM — device_finder keyboard-selection logic is untested (only 'is a function')

**Driver** : linux  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/modules/hotstrings/device_finder.lua:156`, `static/ergopti_plus/linux/modules/hotstrings/device_finder.lua:67`, `static/ergopti_plus/linux/tests/unit/meta/test_daemon_smoke.lua:105`
- **Problème** : find_keyboard has real branching logic — EV_KEY bit filtering (`ev_mask & 0x2`), preferring a keyboard-named device over a generic EV_KEY fallback (so a Power Button never wins), and extracting /dev/input/eventN from the Handlers list — but its only test asserts `type(df.find_keyboard)=='function'` (daemon_smoke). On non-Linux, find_keyboard returns nil (the /proc file is absent), so none of the selection logic ever executes. A regression using the wrong bitmask or selecting the first EV_KEY device (a power button) is uncaught.
- **Correctif** : Refactor parse_proc_devices/find_keyboard to accept an injectable raw /proc content string (or path), or expose the pure selection helper, so the logic can be unit-tested with a fixture on any OS.
- **Test de non-régression** : Add tests/unit/meta/test_device_finder.lua feeding a synthetic /proc/bus/input/devices fixture containing a mouse (no EV_KEY bit), a 'Power Button' (EV_KEY, no keyboard name), and 'AT Translated Set 2 keyboard' (EV=120013, Handlers 'kbd event3'); assert the selected path is /dev/input/event3 (name preference beats the power button) and that the EV_KEY-less device is skipped.

### 🟡 MEDIUM — menu/labels fmt_count and log_level_emoji have no cross-driver parity gate against the AHK hand-maintained copies — and the single-source test's docstring falsely claims they are pinned

**Driver** : cross-driver (shared menu/labels ↔ windows AHK copies)  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/_shared/lua/menu/labels.lua:40-43 (log_level_emoji), :58-66 (fmt_count)`, `static/ergopti_plus/windows/lib/menu_helpers.ahk:199 (FmtCount — hand-maintained copy)`, `static/ergopti_plus/windows/ui/menu/menu_rebuild.ahk:129-135 (_LogLevelEmoji — hand-maintained copy)`, `tools/test/test-menu-labels-single-source.cjs:16-19 (docstring claims AHK copies 'are pinned by separate drift gates (section-decoration-parity + the AHK test suite)')`, `tools/test/test-section-decoration-parity.cjs (pins ONLY decorate_section, not fmt_count/emoji)`
- **Problème** : menu/labels.lua's three formatters must stay identical across all three drivers (the module docstring says so). decorate_section is pinned cross-driver by test-section-decoration-parity.cjs, but fmt_count and log_level_emoji are not pinned anywhere: test-menu-labels-single-source.cjs only checks the shared file exports them and that macOS require()s them; it never checks the AHK FmtCount grouping or _LogLevelEmoji map values. There is no AHK test (windows/tests has zero references to FmtCount or LogLevelEmoji) and no JS parity gate. The single-source test's own docstring asserts these copies are 'pinned by separate drift gates', which is false — section-decoration-parity covers only decorate_section and the AHK suite covers neither. If a maintainer changes the shared fmt_count (e.g. to comma separators or fixes rounding) or the emoji map, the AHK tray silently renders differently with a green CI, and the misleading comment actively discourages anyone from adding the missing gate.
- **Correctif** : Add a cross-driver parity gate (registered in run-js-suite.cjs) that pins golden outputs of both formatters across the shared source and the AHK copies: fmt_count/FmtCount for a fixed vector set (0→'0', 1000→'1 000', 1234567→'1 234 567') and log_level_emoji/_LogLevelEmoji for DEBUG→🐛, INFO→ℹ️, WARNING→⚠️, ERROR→❌, unknown→📝. Parse the emoji return literals out of menu_rebuild.ahk and the shared map, and either statically pin the AHK FmtCount grouping or run it. Then correct the false docstring in test-menu-labels-single-source.cjs.
- **Test de non-régression** : New tools/test/test-menu-count-emoji-parity.cjs added to CHECKS in tools/test/run-js-suite.cjs: asserts the shared labels.lua fmt_count vectors and emoji map equal the values extracted from windows/lib/menu_helpers.ahk (FmtCount) and windows/ui/menu/menu_rebuild.ahk (_LogLevelEmoji). Red-before: change the shared WARNING emoji or the fmt_count separator without touching the AHK copy and the gate fails, naming the drifted function and the two files.

### ⚪ LOW — Source-scan behavioral guards coupled to exact source literals / carrying dead branches — brittle and occasionally false-green

**Driver** : windows  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/tests/meta/test_space_tap_dispatch.ahk:11-13`, `static/ergopti_plus/windows/tests/meta/test_space_tap_dispatch.ahk:18-20`, `static/ergopti_plus/windows/tests/meta/test_healthcheck_recordwarn_called.ahk:14-15`, `static/ergopti_plus/windows/tests/meta/test_processentry32w_size.ahk:29-35`
- **Problème** : Because 135 of 232 production files are never loaded, a large class of behavioral invariants is guarded only by comment-stripped source scans that match exact string literals — e.g. test_space_tap_dispatch.ahk asserts the presence of the literal TextPressKey("Space" and Critical("On"), and test_healthcheck_recordwarn_called.ahk asserts the literal HealthCheck_Run call expressions. These break on legitimate refactors (renaming a local, passing an argument, switching to a wrapper) that preserve behavior, and pass on subtly broken code that keeps the token. test_space_tap_dispatch.ahk:12-13 also contains a dead no-op branch — `if !CritOnIdx: CritOnIdx := InStr(Body, 'Critical("On")')` re-runs the identical InStr it just ran, a copy-paste artifact that does nothing. This is an accepted architectural tradeoff (documented honestly in COVERAGE.md), so severity is low, but it is worth a periodic pass to promote the highest-value scans to real behavioral tests as more modules become loadable, and to remove the dead branch.
- **Correctif** : Delete the dead duplicate InStr branch in test_space_tap_dispatch.ahk:12-13. Where the target function is (or can be made) loadable, prefer a behavioral assertion over a literal scan. Where a scan must remain, match on a stable anchor (function name + relative order of two effects) rather than a full argument-bearing call string, so behavior-preserving refactors do not red the suite.
- **Test de non-régression** : No dedicated regression test warranted for the dead-branch cleanup (pure test-code hygiene). For the literal-coupling risk, the finding-1 meta ratchet plus the existing include-integrity meta test are the appropriate guardrails; when a scanned function is promoted to a behavioral test, its new assertion is the regression guard.

### ⚪ LOW — Section-banner alignment meta-test is a no-op — it never fails on misalignment despite zero current drift

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/tests/meta/test_section_headers.lua:69`, `static/ergopti_plus/macos/tests/meta/test_section_headers.lua:44`
- **Problème** : The project mandates exact banner alignment (7 '=' each side, border lines matching title length) as a hard rule in copilot-instructions.md. The test that ostensibly guards it counts misalignments as warnings but its only assertion is helpers.assert_true(total_files > 0) — it can never fail on an actual misaligned banner. I replicated its check across all 189 lib/modules/ui/adapters files: there are currently 0 alignment warnings, so the codebase fully complies and the gate could hard-fail for free. As written it provides false confidence: a future misaligned banner passes CI silently. It also only measures the title line's own length, not the 4 surrounding border '=' lines (which the rule also constrains), and ignores the 5-'=' subsection form entirely.
- **Correctif** : Since drift is currently zero, change the assertion to helpers.assert_true(total_warns == 0, <message listing offending file:line>). Extend check_file to also verify the two top and two bottom border lines equal the title-line length, and to validate the '===== X.Y) ... =====' subsection form. Keep a documented allowlist only if a legitimately-exempt file appears.
- **Test de non-régression** : Harden test_section_headers.lua itself: add an inline self-check feeding check_file a known-misaligned banner string and asserting it returns >0 (so the detector cannot silently stop detecting), then assert the real scan yields total_warns == 0.

### ⚪ LOW — COVERAGE.md is stale and now actively misleading about what the suite covers

**Driver** : macos  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/macos/tests/COVERAGE.md:41`, `static/ergopti_plus/macos/tests/COVERAGE.md:66`, `static/ergopti_plus/macos/tests/COVERAGE.md:91`
- **Problème** : COVERAGE.md bills itself as 'a honest account of what the test suite covers.' It claims '~430 test cases across ~33 unit-test files' and lists modules.keylogger.* as deferred with 'keylogger: 0% covered'. In reality there are 435 test_*.lua files, of which 37 are under tests/**/keylogger with deep behavioral coverage (aggregation walkers, rotation, sqlite reader/writer, privacy, kc_bridge, F-MED-27 focus_first_key, etc.). The doc also lists gestures.engine, ui.*, and llm.prediction_engine as uncovered though each now has multiple test files. A coverage map that both under-reports covered modules and mis-states the file count undermines the mission's goal ('if all tests pass, the driver is provably correct') by hiding which surfaces are actually unguarded (e.g. lib/i18n and api_mlx_fetch above) behind noise.
- **Correctif** : Regenerate the tables from the real tree (or drop the hand-maintained per-module counts entirely in favor of a generated summary). Move keylogger/gestures/ui/prediction_engine out of the 'deferred' section, and correct the totals to match `find tests -name 'test_*.lua'`.
- **Test de non-régression** : Add a meta test (tests/meta or tools/test) asserting COVERAGE.md self-consistency: the file count it claims is within a small tolerance of the actual test_*.lua count, and no module the doc labels '0% covered' / 'deferred' has any matching test file on disk — so the doc cannot silently drift back into dishonesty.

### ⚪ LOW — Linux TOML fuzz gate is an always-pass no-op — the shared codec's ok/error contract is asserted only on macOS, and the Linux comment claims coverage it does not provide

**Driver** : linux (shared toml_codec)  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/linux/tests/unit/meta/test_corpus_cross_driver.lua:308-324 (fuzz: assert_true(true, 'crashes=...'), 'this assertion always passes')`, `static/ergopti_plus/macos/tests/unit/meta/test_corpus_toml_fuzz.lua:132-164 (real ok/error contract, macOS-only)`, `static/ergopti_plus/_shared/tests/corpus/toml/fuzz_corpus.json (expect: ok|error per vector)`
- **Problème** : The Linux driver parses all production TOML through the shared toml_codec.decode (kanata/dynamic_hotstrings/gestures managers). The macOS fuzz consumer asserts the full contract — expect=ok returns a table, expect=error returns nil/raises. The Linux consumer loads the same corpus but only pcall-wraps decode and then asserts assert_true(true), explicitly reporting the crash count 'for visibility without failing the test'. So the corpus's expect flag is never checked on Linux: a codec regression that made an expect=error input decode to a bogus table (rather than nil) would pass on Linux. Coverage currently survives only because the codec is shared and macOS asserts it — but the Linux file's comment ('the shared hotstring engine is loaded and tested', and the fuzz always-pass) creates false confidence that Linux gates its own parser.
- **Correctif** : Replace the always-pass fuzz assertion with the same ok/error contract macOS uses: for each fuzz vector, pcall(codec.decode, input); assert (not ok or result==nil) for expect=error and (ok and type(result)=='table') for expect=ok, with a message naming the vector id. Fix the §2 hotstrings comment so it does not imply corpus replay that does not happen here.
- **Test de non-régression** : In test_corpus_cross_driver.lua §7, assert the ok/error contract per fuzz vector instead of assert_true(true). Red-before: make codec.decode return {} instead of nil for FUZZ-008 (unclosed string) and the Linux gate fails naming the vector; green-after with the codec correct. This makes the shared codec's failure contract enforced on the driver that actually ships it, not only on macOS.


## 3.6 SSoT (duplication cross-driver)

### 🟠 HIGH — WPM "manual" and "AI" pill colors have already drifted between macOS and Windows

**Driver** : macos + windows (WPM widget)  ·  **Confiance** : high  ·  **Vérifié (adversarial)** : `confirmed`

- **Où** : `static/ergopti_plus/macos/ui/wpm/shared.lua:30`, `static/ergopti_plus/macos/ui/wpm/shared.lua:33`, `static/ergopti_plus/_shared/modules/wpm_widget/constants.toml:79`, `static/ergopti_plus/_shared/modules/wpm_widget/constants.toml:83`, `static/ergopti_plus/windows/ui/wpm/wpm_display.ahk:491`, `static/ergopti_plus/windows/ui/wpm/wpm_display.ahk:500`, `static/ergopti_plus/macos/ui/wpm/wpm_widget.lua:144`
- **Problème** : The shared constants.toml is the documented single source for the widget's source-state colors: its header explicitly maps `bg_manual = "#0055cc"` -> `WPMShared.COLOR_FALLBACK.manual` and `bg_ai = "#7a30b0"` -> `WPMShared.COLOR_FALLBACK.llm` (constants.toml:77-83). Windows honors this: WPMWidget_CategoryBgColor returns `WPMWidgetConst.COLOR_BG_MANUAL` (#0055cc, read from the TOML) for plain typing and `COLOR_BG_AI` (#7a30b0) for AI keystrokes (wpm_display.ahk:500,491). macOS ignores the TOML for these two states: shared.lua hardcodes `COLOR_FALLBACK = { manual = "#007aff", llm = "#af52de" }` and resolve_source_hex returns those for the "manual" and "llm" sources. Result: the manual-typing pill is #0055cc on Windows but #007aff on macOS, and the AI pill is #7a30b0 vs #af52de — a live, visible cross-driver drift for the single most common widget state (plain typing). It is also internally inconsistent on macOS: wpm_widget.lua:144 loads `color_bg_manual` (#0055cc) from the TOML but only uses it as a darken fallback, never as the manual pill color. No gate covers this pair.
- **Correctif** : Delete the hardcoded COLOR_FALLBACK hex literals in shared.lua and source manual/llm from the shared TOML (read bg_manual/bg_ai via the same loader wpm_widget.lua already uses, or expose them on CONFIG and pass them into WPMShared). Both drivers then resolve the identical #0055cc/#7a30b0 for those states.
- **Test de non-régression** : Add tools/test/test-wpm-source-colors-single-source.cjs (register in run-js-suite.cjs CHECKS): parse _shared/modules/wpm_widget/constants.toml for bg_manual/bg_ai, assert macos/ui/wpm/shared.lua contains no hardcoded manual/llm hex literal and that the resolved macOS values equal the TOML, and that windows COLOR_BG_MANUAL/COLOR_BG_AI trace to the same keys. It fails today (#007aff != #0055cc, #af52de != #7a30b0) and passes once macOS reads from the TOML.

### 🟡 MEDIUM — AHK WPM loader re-types every shared TOML constant as an inline fallback literal (SSoT + fail-fast asymmetry vs macOS)

**Driver** : windows (WPM widget), duplicating _shared values  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/wpm/wpm_config.ahk:38`, `static/ergopti_plus/windows/ui/wpm/wpm_config.ahk:49`, `static/ergopti_plus/windows/ui/wpm/wpm_config.ahk:66`, `static/ergopti_plus/windows/ui/wpm/wpm_config.ahk:70`, `static/ergopti_plus/macos/ui/wpm/wpm_widget.lua:127`
- **Problème** : WPMWidget_LoadSharedConst reads the shared TOML but passes a hardcoded default as the 3rd IniCacheGet arg for every key — width "80", height "68", height_number "44", height_gap "4", height_unit "20", number_font_size "20", unit_font_size "8", unit_strip_darken_factor "0.40", bg_manual "#0055cc", bg_ai "#7a30b0", bg_idle "#1a1a2e", text_active "#ffffff", text_idle "#555577", widget_hsl_l "0.40", widget_hsl_s "1.00", alpha_active "220", alpha_idle "140" — plus wpm_widget_idle_hide_ms "3000" / wpm_color_hold_ms "1000" and an explicit `:= 3000`/`:= 1000` in the timings else-branch (lines 66-71). Every one of these re-duplicates the canonical constants.toml / timings/constants.toml value inline. This violates conventions 5.2 and 5.4 and is asymmetric with the macOS loader, which is strictly fail-fast (wpm_widget.lua:127-131 states "No literal fallbacks below" and is enforced by test_wpm_shared_constants). If a TOML key is renamed/removed, macOS surfaces nil loudly while AHK silently serves the stale hardcoded value.
- **Correctif** : Replace the IniCacheGet-with-default calls with fail-fast reads (the _UiStyleRequire pattern already used by the sibling tooltip loader lib/ui_style.ahk, which ExitApps on a missing key) and drop the `:= 3000`/`:= 1000` timing re-types so the shared TOML is the only source.
- **Test de non-régression** : Add tools/test/test-wpm-no-fallback-literals.cjs (or an AHK meta test under windows/tests): assert wpm_config.ahk contains no numeric/hex default 3rd-argument for the shared [compact]/[colors]/[transparency] keys and no re-typed timing literal, mirroring test-no-fallback-literals.cjs. Red today, green after the fail-fast conversion.

### 🟡 MEDIUM — WPM HSL color-normalization/darken algorithm re-implemented per driver with no shared canonical and no cross-driver vectors

**Driver** : macos + windows (WPM widget)  ·  **Confiance** : high

- **Où** : `static/ergopti_plus/windows/ui/wpm/wpm_display.ahk:302`, `static/ergopti_plus/windows/ui/wpm/wpm_display.ahk:783`, `static/ergopti_plus/macos/ui/wpm/wpm_widget.lua:242`, `static/ergopti_plus/macos/ui/wpm/wpm_widget.lua:293`, `static/ergopti_plus/_shared/modules/tooltip/tint.js:255`
- **Problème** : The widget re-projects any accent hex onto the fixed widget HSL target (widget_hsl_l=0.40, widget_hsl_s=1.00) and darkens the unit strip. This is implemented twice: AHK `_WPMWidget_NormaliseHex` / `_WPMWidget_DarkenHex` (wpm_display.ahk:302,783) and macOS `_wpm_normalise_hex` / `_wpm_darken_hex` (wpm_widget.lua:242,293). The two hand-ported hue-extraction/HSL-reconstruction/rounding routines can silently diverge (rounding, achromatic edge cases). This is exactly the pattern the tooltip tint solves the right way — a canonical _shared/modules/tooltip/tint.js plus tintTestVectors() that gate BOTH drivers (windows test_tooltip_tint_contract.ahk + macOS test_tooltip_shared_style.lua). The WPM color math has neither a shared canonical nor any cross-driver parity vectors; test_wpm_compact_color_validation.ahk only checks a hex-regex guard, not output parity.
- **Correctif** : Extract the WPM hue-normalize + darken into a shared canonical (a new _shared/modules/wpm_widget/color.js, or reuse tint.js's extractHue/hslToRgb) and publish a wpmColorTestVectors() corpus of accent->expected-hex pairs, mirroring the tint contract. Each driver keeps its native implementation but is validated against the shared vectors.
- **Test de non-régression** : Add tools/test/test-wpm-color-parity.cjs plus a JSON vector corpus under _shared/tests/corpus/wpm/ consumed by both suites; the macOS and AHK WPM test files assert `_wpm_normalise_hex`/`_WPMWidget_NormaliseHex` reproduce every corpus expected_hex within +/-1 per channel (same tolerance as the tint gate). Any future divergence in either port fails CI.


## 3.7 Structure & parité des dossiers

### 🟠 HIGH — linux driver has no shell_runner adapter — the only driver that scatters raw os.execute/io.popen instead of routing through the port/adapter boundary

**Driver** : linux (outlier)  ·  **Confiance** : high

- **Où** : `windows/adapters/shell_runner.ahk:1-27 (adapter + explicit SYMMETRY NOTE)`, `macos/adapters/shell_runner.lua:1-55 (exec/spawn adapter)`, `linux/adapters/ (NO shell_runner.lua present)`, `linux/adapters/process_lifecycle.lua:70,80,89`, `linux/modules/kanata/manager.lua:330,351,374,393`, `linux/modules/shortcuts/manager.lua:153,164,174,178`, `linux/modules/hotstrings/injector.lua:70,118`, `linux/modules/keylogger/sqlite_writer.lua:65,103,169`, `linux/modules/llm/api_ollama.lua:129`, `linux/modules/menu/menu_builder.lua:631,655`
- **Problème** : windows/adapters/shell_runner.ahk and macos/adapters/shell_runner.lua both wrap OS process spawning behind an identical exec()/spawn() adapter surface — windows/adapters/shell_runner.ahk:22-27 even carries a 'SYMMETRY NOTE' declaring the contract intentionally mirrors the macOS adapter so modules can be ported unchanged. The linux driver, whose primitives are ENTIRELY shell CLIs (xdotool, xclip, kanata, sqlite3, curl, xdg-open), ships no shell_runner adapter at all (verified: no shell/exec/runner/subprocess module exists under linux/). Instead raw os.execute/io.popen calls are scattered across at least 12 modules and even inside adapters/process_lifecycle.lua, bypassing the hexagonal port/adapter boundary the other two drivers enforce. This is the single clearest missing-adapter asymmetry: an adapter present in 2 of 3 drivers, absent in the 3rd, and absent precisely in the driver that most depends on shell execution. It also means shell-quoting/error-handling logic (the GC-pin, xpcall-around-callback, and quoting fixes baked into the win/mac adapters) is duplicated ad hoc at every linux call site with no shared hardening.
- **Correctif** : Add linux/adapters/shell_runner.lua exposing the same exec(cmd)->stdout and spawn(exe,args,on_done,on_chunk)->handle{start,terminate} surface as macos/adapters/shell_runner.lua, implemented over io.popen/os.execute plus the daemon event loop for async. Route the scattered os.execute/io.popen calls in the linux modules listed above through it. Separately, promote ShellRunner to a real port: none of shell_runner/json_codec/toml_cache/event_loop has a spec in _shared/core/ports/, so the adapter set is ungated — add _shared/core/ports/ShellRunner.spec.js (or an explicit allow-list) so the concept is contract-anchored across drivers.
- **Test de non-régression** : Two tests. (1) linux/tests/unit/meta/test_shell_runner_adapter_present.lua: require('adapters.shell_runner') and assert it exposes exec + spawn (mirrors macos/tests/unit/adapters/test_shell_runner_*.lua and windows/tests/unit/test_adapter_compliance_new.ahk) — red today (file absent), green after the adapter lands. (2) A cross-driver drift gate in tools/test/*.cjs registered in run-js-suite.cjs: diff the adapter basenames of windows/adapters, macos/adapters, linux/adapters against a documented allow-list of platform-only adapters (event_loop, json_codec, toml_cache) and fail if any other adapter (e.g. shell_runner) is present in some drivers but missing in another.

### 🟡 MEDIUM — Cross-cutting infrastructure (crash_reporter, updater, menu) filed under modules/ on linux but under lib/ and ui/ on windows+macos

**Driver** : linux (outlier)  ·  **Confiance** : high

- **Où** : `windows/lib/crash_reporter.ahk`, `macos/lib/crash_reporter.lua`, `linux/modules/diagnostics/crash_reporter.lua`, `windows/lib/updater.ahk (+ windows/lib/updater/)`, `macos/lib/updater.lua`, `linux/modules/updater/manager.lua`, `windows/ui/menu/ + windows/lib/menu_dispatcher.ahk`, `macos/ui/menu/ + macos/lib/manifest_menu.lua`, `linux/modules/menu/menu_builder.lua`
- **Problème** : The top-level directory taxonomy is inconsistent across drivers, and linux is the consistent outlier. crash_reporter lives in lib/ on windows and macos but in a linux-only modules/diagnostics/ folder. The updater lives in lib/ (lib/updater.ahk, lib/updater.lua) on windows+macos but in modules/updater/manager.lua on linux. The menu lives in ui/menu/ (+ lib/ helpers) on windows+macos but in modules/menu/menu_builder.lua on linux. lib/ is meant for cross-cutting infrastructure/utilities and ui/ for presentation, while modules/ is meant for feature domains; linux collapses infra and presentation concerns into modules/. A developer or agent navigating the repo cannot predict where a given concept lives without knowing which driver they are in, and linux carries a modules/diagnostics/ subfolder that has no peer in the other two drivers.
- **Correctif** : Relocate linux infra to match the established lib/ taxonomy: linux/modules/diagnostics/crash_reporter.lua -> linux/lib/crash_reporter.lua; linux/modules/updater/manager.lua -> linux/lib/updater.lua (or lib/updater/); keep menu presentation glue under linux/ui/ to match windows/macos ui/menu/. Where a linux behavior genuinely differs (webview-driven menu), leave a thin ui/ entry that delegates, rather than housing the whole concept under modules/.
- **Test de non-régression** : A cross-driver structure gate in tools/test/*.cjs (registered in run-js-suite.cjs) that asserts a canonical set of infra concepts {crash_reporter, updater} resolves to the same top-level bucket (lib/) in all three drivers, and fails if any driver files one of them under modules/. Red today for crash_reporter+updater on linux, green after relocation.

### 🟡 MEDIUM — Lua module entry-point filename convention diverges between the two Lua drivers: macos uses <module>/init.lua, linux uses <module>/manager.lua

**Driver** : linux (outlier vs the idiomatic init.lua)  ·  **Confiance** : high

- **Où** : `macos/modules/gestures/init.lua`, `macos/modules/dynamic_hotstrings/init.lua`, `macos/modules/keymap/init.lua`, `macos/modules/llm/init.lua`, `macos/modules/shortcuts/init.lua`, `linux/modules/gestures/manager.lua`, `linux/modules/dynamic_hotstrings/manager.lua`, `linux/modules/kanata/manager.lua`, `linux/modules/shortcuts/manager.lua`, `linux/modules/updater/manager.lua`, `linux/modules/ui/webview_manager.lua`
- **Problème** : The same concept — a stateful module's public entry point — has two different canonical filenames across the two Lua drivers. macOS consistently names it <module>/init.lua; linux consistently names it <module>/manager.lua. There is no language reason for the split (both are Lua). init.lua is the idiomatic choice: Lua's require('module') auto-resolves module/init.lua, and every shared package under _shared/lua/ already uses it (e.g. _shared/lua/hotstring_engine/init.lua, _shared/lua/toml_codec/init.lua). This makes linux the outlier and means code being ported between the two Lua drivers cannot rely on a predictable module path, and require('modules.gestures') behaves differently per driver.
- **Correctif** : Standardize linux stateful module entry points on init.lua (rename manager.lua -> init.lua for gestures, dynamic_hotstrings, kanata, shortcuts, updater, and ui/webview_manager.lua -> ui/init.lua) so both Lua drivers and _shared/lua share one convention, then update the require() sites.
- **Test de non-régression** : linux/tests/unit/meta/test_module_entry_convention.lua that enumerates each stateful folder under linux/modules/ and asserts an init.lua exists (mirroring the macOS convention). Red today (folders expose manager.lua, not init.lua), green after the rename; locks the convention so a future manager.lua cannot silently reintroduce the split.

### ⚪ LOW — tap_holds (plural) is a naming outlier — every other occurrence of the concept, including within the same windows driver, is singular tap_hold

**Driver** : windows (outlier)  ·  **Confiance** : high

- **Où** : `windows/modules/tap_holds/ (plural)`, `windows/lib/tap_hold/ (singular)`, `_shared/lua/tap_hold/`, `_shared/tap_hold/`, `_shared/tests/corpus/tap_hold/`, `macos/tests/unit/meta/test_corpus_tap_hold.lua`
- **Problème** : windows/modules/tap_holds/ is the only place in the entire tree that pluralizes the concept. The canonical name is singular tap_hold everywhere else: windows/lib/tap_hold/, _shared/lua/tap_hold/, _shared/tap_hold/, _shared/tests/corpus/tap_hold/, and the macOS corpus test. The inconsistency exists even inside the windows driver itself (modules/tap_holds vs lib/tap_hold), so a path built from the singular form silently misses the module dir.
- **Correctif** : Rename windows/modules/tap_holds/ -> windows/modules/tap_hold/ (and its #Include sites, entry file windows/modules/tap_holds.ahk -> tap_hold.ahk) so the module dir matches windows/lib/tap_hold and the shared singular convention.
- **Test de non-régression** : windows/tests/meta/test_tap_hold_naming.ahk asserting no path segment 'tap_holds' (plural) exists under windows/ and that windows/modules/tap_hold/ resolves — red today, green after the rename. Keeps the singular name locked against reintroduction.



---

## 4. Travaux déjà scopés cette nuit (à exécuter avec toi — non faits car risque visuel/hardware)

### 4.1 Migration webview Windows → `WebViewHost` (le `P0-A.2` du TODO)
**État réel constaté** : la classe `WebViewHost` existe déjà (`windows/lib/webview_utils.ahk:122-259`)
et lit `_shared/ui/apps.manifest.json` (géométrie + vhost, lazy-cached). **Mais aucun consommateur
ne l'instancie** (`grep WebViewHost(` → 0). Les ~14 fenêtres codent encore leur géométrie en dur via
`g.Show("wNNN hNNN")`, gate-vérifiée contre le manifest par `test-webview-geometry-single-source.cjs`.

**Sites en dur repérés** (à router via `WebViewHost` / manifest) :
- `windows/ui/changelog/init.ahk:133` `g.Show("w860 h580")`
- `windows/ui/model_browser/init.ahk:388` `g.Show("w900 h580")`
- `windows/ui/onboarding/webview.ahk:142` `g.Show("w480 h560 Center")`
- `windows/ui/paths_editor/init.ahk:87` `g.Show("w720 h300 Center")`
- `windows/ui/personal_info_editor/init.ahk:85` `g.Show("w560 h680 Center")`
- `windows/ui/personal_toml_editor_webview.ahk:109` `g.Show("w960 h640 Center")`
- + les autres apps du manifest (healthcheck, hotstrings_config_window, action_picker, metrics_typing,
  metrics_apps, prompt_editor, token_prompt, download_window) — `grep -rn 'g.Show("w[0-9]' windows/ui windows/modules`.

**Correctif** : chaque consommateur lit `{w,h,min_w,min_h}` depuis `WebViewHost(appId)` au lieu du littéral.
**Test** : garde AHK vérifiant que chaque module webview appelle `WebViewHost` et ne contient plus de
littéral `w<NNN> h<NNN>` ; le gate `test-webview-geometry-single-source.cjs` peut alors passer de
"littéraux == manifest" à "aucun littéral (dérivé)". **Risque** : le rendu (taille/position réelle) n'est
pas vérifiable sans reload visuel — à faire écran sous les yeux.

### 4.2 Câblage runtime des timings keylogger (suite du drift gate `a900d89a0`)
`TimingsGet` n'a **aucun consommateur prod** aujourd'hui. Câbler `CONTEXT_TTL_MS`/`PARK_CHECK_MS`/
`TOPO_TICK_MS` pour qu'ils lisent le registre = 1re intégration `TimingsGet` → à valider au boot réel
(ordre de chargement des `static` de classe AHK). À faire avec toi.

### 4.3 Vérification daemon-only sur vraie machine Linux
Sous luajit (pas lua5.4), matériel réel : evdev, ydotool/uinput, D-Bus, WebKitGTK, SNI, smoke daemon
complet (evdev → expansion). Non exécutable ici.

---

## 5. Décisions mainteneur — ACTÉES (2026-07-10)

Les 4 arbitrages ci-dessous sont **fermés**. Exécute selon ; ne les rouvre pas.

1. **Fix des races Linux (`race:linux#66`/`#67`)** — ✅ **Grab clavier par défaut.** Le daemon passe
   intercepteur (EVIOCGRAB ; socle déjà à moitié câblé `keyboard_hook.lua:129`) : il possède le flux de
   sortie et ré-injecte les frappes normales. Changement de comportement **assumé** — c'est la vraie
   correction. L'agent implémente le grab + ré-injection **et** un **test déterministe** reproduisant
   l'interleaving dans un harnais simulé (source evdev factice + injecteur factice, assertion sur
   l'ordre de sortie, sans hardware). La **validation hardware finale** reste §4.3 (différée).
2. **i18n (§3.4)** — 🔵 **Réservé Opus.** Le mainteneur fait lui-même les traductions 21 langues.
   L'agent exécutant **ne route pas** les textes en dur et **ne touche pas** aux locales. Lot Opus.
3. **Structure (§3.7)** — 🔵 **Réservé Opus, tout d'un coup.** shell_runner + renommages manager→init
   + relocalisation `crash_reporter`/`updater` sous `lib/`. Fait par Opus, **pas** l'agent exécutant.
4. **Items non vérifiables sans machine/écran** — ⏸️ **Différés :** webview (§4.1), câblage timings
   (§4.2), hardware Linux (§4.3), et **macOS `race:macos#63`** (le fix + son test sont **préparés mais
   NON activés** tant que le mainteneur n'a pas confirmé empiriquement quel `eventSourceUnixProcessID`
   portent les échos `keyStrokes()` — le vérificateur adversarial l'exige avant tout changement).

**Décisions déjà closes (nuit précédente)** : retrait du fallback kanata (fait `f8df076a1`), source
d'horloge daemon (fait `27c478ed3` / `418073847` / `366fa15fb`), délégation password-apps (**refusée à
raison** — elle *réduirait* la couverture privacy — couverture verrouillée `2d5c614f1`).

---

## 6. Comment on avance — checklist + protocole de suivi

**Protocole (agent exécutant).** À chaque item terminé : remplace `[ ]` par `[x]` et **annote la
ligne** avec le SHA court du commit + le nom du/des test(s) ajouté(s). Ex :

```
[x] Bloc 1 — grab clavier Linux — a1b2c3d — test_keyboard_grab_ordering.lua
```

Un item = un commit. Item bloqué ou volontairement sauté : `[~]` + la raison en une ligne. C'est ce
qui permet la relecture commit par commit — ne mets **jamais** l'ID de finding (`#66`) dans le
commit lui-même (§0.2), seulement ici dans le MD.

**Lots 🟢 — agent exécutant :**

- [x] **Bloc 1 — Races** 🟢 : grab clavier Linux (#66/#67, décision §5.1) → gates timing Windows
      (#60/#61) → medium races (#64/#65/#68). *Test déterministe reproduisant l interleaving.*
      (macOS #63 = ⏸️ différé, §5.4.)
  - [x] #60 timing gate — 9c05564d5 — test_fire_log_defer_after_suppress.ahk
  - [x] #61 suppress-release bounded — 8355def21 — test_hse_suppress_release_bounded.ahk
  - [x] #64 no-op expansion passthrough (macOS) — 675dba108 — test_noop_expansion_passthrough.lua
  - [x] #66/#67 grab+inject Linux — bfe42749a — test_injector_race.lua
  - [x] #68 shift one-shot Linux — e5b2fe2b2 — test_keyboard_hook_shift.lua
  - [ ] #65 ignored-window deferred buffer snapshot (macOS, low)
- [x] **Bloc 2 — Perf frappe** 🟢 : sortir les sous-process/IO bloquants du thread d entrée
      (#75 Linux, #72 macOS, #69 Windows, #76 Linux) — cache event-driven du focus, injection
      non bloquante.
  - [x] #69 Windows privacy filter off-thread — ec7d1ad47 — test_metrics_focus_off_thread.ahk
  - [x] #72 macOS persistent today.log handle — 405c8b3a6 — rotation unit tests (couvert existant)
  - [x] #75 Linux cache app_id via process_lifecycle — ebe97ed94 — test_on_char_focus_no_subprocess.lua
  - [ ] #73 macOS update_preview early-out guard (medium)
  - [ ] #74 Linux injector non-blocking sleep (medium)
  - [ ] #76-#78 low (HookDispatcher Clone, HSE star-match alloc, engine buffer double-concat)
- [x] **Bloc 4 — Fail-fast** 🟢 : #9 (macOS, prioritaire : config Karabiner corrompue = reset
      silencieux de toute la config utilisateur) puis les autres échecs silencieux (#10-#17).
  - [x] #9 CRITICAL macOS Karabiner corrupt config — 43165c992 — test_config_corrupt_toml.lua
  - [x] #10 Windows metrics DB build failure — 50d87c983 — test_klr_builddatabase_failure_logged.ahk
  - [x] #11 Windows personal-TOML save failure — 50d87c983 — test_personal_toml_write_failure_logged.ahk
  - [x] #12 macOS onboarding guard abort — 4bb62943 — test_init_onboarding_require_failure_logged.lua (source-scan)
  - [x] #14 Linux malformed personal_info.toml — 73c5af42a — test_dynamic_hotstrings_manager.lua
  - [x] #15 Linux malformed tap_hold.toml — 73c5af42a — test_kanata_manager.lua
  - [x] #17 Linux prediction engine dead codellama guard — 73c5af42a — test_prediction_engine_predict.lua
  - [~] #13 Linux updater install_update() error swallowing — LOW, requires test seams (os.execute injection)
  - [~] #16 Linux storage.set()/delete() return-value lies — LOW, requires test seams
  - [~] #18 macOS keylogger json.encode swallow — LOW, requires hs.json stub
  - [~] #19 macOS menu_state sync pcall swallow — LOW, requires keymap stub injection
- [x] **Bloc 5 — Tests** 🟢 : remplacer les no-op (#38/#39), rejouer le moteur partagé contre le
      corpus (#56/#57), couvrir secure_field_detector (#49). *(Le test du backbone i18n #42
      part avec le lot i18n 🔵 pour ne pas croiser les locales.)*
  - [x] #38 Windows 9 no-op healthcheck tests → real assertions — 2631bde53 — test_healthcheck_core.ahk
  - [x] #39 macOS lib/i18n.lua behavioral test — 50a66e764 — test_i18n.lua (27 test cases, 7 describe blocks)
  - [ ] #56 rejouer moteur hotstring partagé contre le corpus
  - [ ] #57 rejouer moteur hotstring Windows contre le corpus
  - [x] #49 couvrir secure_field_detector — caf45b2fa — test_secure_field_detector.lua (macOS 20 tests + Linux 27 tests)
- [ ] **Bloc 6b — SSoT couleurs WPM** 🟢 : #4/#5/#6 (couleurs déjà driftées mac/win →
      canonique _shared + gate cross-driver).

**Lots 🔵 — Opus (relecteur). NE PAS exécuter (§0.1, §5.2, §5.3) :**

- [ ] **Bloc 3 — i18n** 🔵 : menu tray Linux (`#31`/`#32`/`#34`/`#35`), bridges `locale='fr'` (`#33`),
      littéraux Windows/macOS (`#18`–`#30`), backbone i18n testé (`#42`). Routage + traductions 21
      langues + clés manquantes dans les 21 JSON. **Opus.**
- [ ] **Bloc 6a — Structure** 🔵 : `shell_runner` Linux (`#0`), manager→init (`#2`), taxonomie `lib/`
      (`#1`), `tap_holds`→`tap_hold` (`#3`). **Opus.**

**Lots ⏸️ — différés (écran/machine, §5.4) :**

- [ ] **Bloc 7** ⏸️ : migration webview (§4.1), câblage timings (§4.2), vérif hardware Linux (§4.3),
      macOS `#63` (fix préparé, non activé sans confirmation PID).
