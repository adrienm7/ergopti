<!-- TODO.md -->

# TODO

Known, scoped, not done. Everything here was verified against the code on
2026-07-21 — items that turned out to be already delivered were dropped rather
than carried forward.

## Simplification plan — remaining blockers (branch `simplification`)

[`docs/PLAN_SIMPLIFICATION.md`](docs/PLAN_SIMPLIFICATION.md) is the full audit and
plan; [`docs/ERGOPTI_PLUS.md`](docs/ERGOPTI_PLUS.md) documents how the system works
today. Lot 0 and 5 of the 12 blockers are done on that branch. What remains, in
the plan's own priority order:

| # | Blocker | Why it is next | Note before starting |
| --- | --- | --- | --- |
| **B5** | Linux writes every typed character, in plaintext, into a world-readable `/tmp` file on every keylogger flush (`linux/modules/keylogger/sqlite_writer.lua:96-112`, `:127-139`) | privacy, and the temp name is derived from `tmpnam(3)` then mutated, so it is not the reserved file — a symlink/TOCTOU target | the fix is to stop shelling the SQL through a file; the `sqlite3` CLI accepts a script on stdin |
| **B4** | Linux keylogger is always on, in plaintext, with no off switch and no private-browsing/system-auth filter | privacy | ⚠ **do NOT simply wire `adapters/secure_field_detector.lua`** — the comment at `modules/keylogger/keylogger.lua:90-98` explains that its exact `WM_CLASS` match on a shorter list would *narrow* coverage and leak `gpg`/`ssh-agent`/`polkit`/`sudo`. The fix is additive |
| **B3** | The generated kanata config is unloadable: the generator emits 7 of the 12 aliases the template defines, leaving `@copy`, `@paste`, `@rollx`, `@deadtrema` dangling | Linux remap is broken outright | `test:kanata-defalias-parity` never runs the generator against the template — extend it, then fix the generator |
| **B6** | The macOS "Chiffrement" menu item is a complete no-op whose backend is ten empty stubs, and `docs/security/keylogger_privacy.md:93` tells users to enable it | a false security claim in the docs | needs a decision: implement or delete the feature *and* the doc sentence together |
| **B9** | `llm_context_length` has no effect on the Windows automatic path (the `context_window_chars` fix was never ported into the AHK generator) | user-visible setting that does nothing | add a corpus vector with `context_window_chars` set — none of the 12 existing vectors does, which is why the corpus cannot catch it |
| **B10** | Opposite secure-field defaults for LLM predictions (macOS hardcodes `true` and never reads the shared value; Windows sends context from password fields) | security posture | **maintainer decision required** on which default wins (D9 in the plan) |

Also carried over from the audit, not blockers:

- The Lua half of `lint-conventions.js` scans macOS only: Linux (142 files) and
  `_shared/lua` (32) are never checked for headers, banners or section spacing.
- `_shared/core` (33 port specs) and `_shared/modules` (3 scripts) are outside
  `audit-file-headers.cjs`. The specs use a repo-relative header where everything
  else under `_shared/` uses the BASE-relative form; unifying them is a 36-file
  rewrite touching files other meta-tests grep, so it needs its own commit.
- `windows/tests/COVERAGE.md` and `macos/tests/COVERAGE.md` are hand-maintained
  inventories that are already stale (one claims "~1 230+ assertions across ~34
  unit-test files" against a measured 143 unit + 686 meta files). `docs/TESTING.md`
  already states the right principle: the inventory of checks is the run itself.

Working rules: no behaviour change without a regression test, never weaken a
test to make a change pass, and run the gates that cover what you touched —
`node ./tools/test/verify-change.cjs` derives them (see the `verify-change`
skill). Read [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) before starting:
several neighbouring ideas were tried and rejected with reasons.

---

## 1. A real user-facing bug

### Linux: the daemon never grabs the keyboard — this is the root cause of `abcd` → `acd`

`static/ergopti_plus/linux/adapters/keyboard_hook.lua:65` defaults `_intercept`
to false, and `:396` only flips it when the caller passes `intercept = true` —
which `ergopti_hotstrings.lua` does not. In observe mode the daemon runs
`libinput debug-events`, which never takes `EVIOCGRAB`, so **every physical
keystroke reaches the application in real time regardless of what the daemon is
doing**. During the erase-then-type window of an expansion (~90 ms for six
characters via ydotool) physical keys interleave with the backspaces and the
synthetic text, and the result on screen is corrupted non-deterministically.

Consequence worth knowing before touching it: the plumbing added for this
(`keyboard_hook.get_mode()`, the injector's internal queue) is **dead code in
observe mode** — `inject()` blocks the thread, so the queue path is never
reached.

Flipping the default is not enough on its own. Intercept mode makes the daemon
the sole path to the application, so it must re-emit **every** event — modifiers,
control keys, key-repeat, releases — in order and without loss, or the keyboard
becomes unusable. Verify with a deterministic harness (fake evdev source, fake
injector) proving lossless raw-event pass-through, then on real evdev + ydotool.

---

## 2. Tests that certify nothing

This is the highest-leverage cluster in the file, because a false green is worse
than a missing test: it actively deters anyone from writing the real one. The
repo has documented this failure mode three times already.

### ~50 registered AHK tests are tautological placeholders

They assert `AssertTrue(true, …)` while promising concrete guarantees
("TimerScheduler every(): must be silent under pause"), and invoke no production
code at all. Verified still present: `windows/tests/unit/test_domain_expander.ahk`,
where the two `Test()` calls are additionally declared *inside* the body of
`_DE_Add()`, so they only register if that function is called.

The gate is already delivered: `tools/test/find-false-greens.cjs` runs inside
`npm run test:js` and ratchets four classes (tautology, vacuous-absence,
dead-test, pcall-only) at a combined baseline of 549 — it only turns down. What
remains is burning the baseline down by replacing the placeholders with real
assertions, starting with the ones whose `Test()` calls are declared inside a
function body and therefore only register if that function is called.

### macOS: no ratchet against the closure-binds-nil-global pattern

The recommendation was made in the 2026-06-19 audit and never delivered (no
`*local_task*` test exists). This is the only bug class documented as having
recurred **three** times — `api_ollama os.remove`, the F10 download fix, then
F-CRIT-2, which left self-update completely dead. In Lua the scope of `local x`
starts *after* the full statement, so the closure on the right-hand side captures
the nil global, and `t[nil] = v` raises "table index is nil" — swallowed by
`hs.task`'s internal pcall and invisible in the file logger. Every site is fixed
today, so the guard goes green immediately: it is a pure ratchet against the
fourth recurrence. Slug: `project_lua_closure_before_local_nil_global`.

---

## 3. Correctness and completeness

### Karabiner: a corrupted config is still overwritten by the next setter

The read path now refuses to silently reset a corrupted user file, but the write
path was never given the same treatment: the next setter overwrites it anyway,
which is where the data is actually lost.

### i18n: ~15-19 user-facing surfaces are still hardcoded

Verified one by one, all still present, across all three drivers — macOS model
switcher and models manager ("Puissance détectée", the RAM/disk block), the
metrics app picker, Linux menu leaf titles and gesture action labels, Linux GTK
window titles, Windows LLM model menu, deps checker, `config_io.ahk:692`
("Espace"/"Entrée"), and the tooltip's French fallbacks. The stated goal is 21
languages. Note for planning: the update-related keys the earlier plan claimed
were missing **do exist** (`_shared/data/locales/fr.json:607-610` plus
`check_for_updates`, `channel_*`, `install_update`, `open_releases_page`), so
routing the Linux updater menu needs no new translation.

### Linux: the `shell_runner` adapter is missing

The only adapter present in two drivers out of three.

---

## 4. Performance — instrumentation first

The 2026-07-21 campaign shipped the levers it could prove. What is left is mostly
**unmeasured**, and silence reads as "optimal".

**Prerequisite, before any further tooltip work:** sub-segment
`_TooltipPresentStack` (`windows/ui/tooltip/helpers.ahk`). Since the UIA fix,
`Tooltip.Present` is the dominant offender (102 of 194 slow lines on the first
post-fix day, ~12.9 ms mean) and has **no surviving lever** — every candidate was
rejected in verification or forbidden by PROJECT_MEMORY. It aggregates six
sub-steps with no attribution, so anything proposed before this exists is
speculation.

Then, in value order: `LLM.FeedChar` (prime suspect for the ~600 slow `OnChar`
events with no matching slow `HSE.FeedChar`); `RemapEmit`, the first stage of
every keystroke, with no segment at all; the keylogger fan-out and
`Hook.KeyDown`, which close the per-keystroke budget; exit counters for
`_TooltipResolvePosition` plus a total render counter, without which the
slow-render ratio is incalculable; five retroactive boot marks before
`BootProfile_Begin`; and for idle, `UIA.SelectionPoll`, `Metrics.FocusRefresh`
(a `WinGetTitle` on a Not Responding window blocks 20×/s with no trace) and
`KL.Ingest` — plus a meta-test inventorying every `SetTimer` under 1000 ms
against a whitelist, so a fast poller cannot reappear silently.

### Follow-ups found while implementing

- **Five independent decodes of the same manifest at boot (~200 ms).** The four
  `_MM_*` loaders in `lib/menu_manifest.ahk` each keep their own cache, and
  `_MR_MANIFEST_CACHE` is a fifth — all decoding the same 12.5 KB file, benched
  at 44 ms per decode. Consolidating them behind `_MR_GetManifestRoot()` follows
  the per-item fix already shipped, but touches five sites and four caches:
  separate commit, and only after measuring the shipped fix in isolation.
- **Dead Ollama WinHTTP path.** `LLM_OllamaCancelAsync` has no production
  callers and `_LLM_Ollama_PollRequest` is never armed; both carry an
  `entry.Has("http")` branch that cannot be true, since the only creation site
  writes no `"http"` key. curl is the live transport. Remove under §5.6.
- **Magic numbers around the LLM health probe**: the 3 s throttle is inline and
  the 10 s interval is duplicated between `menu_llm/init.ahk` and
  `menu_llm/actions.ahk`. Name them next to `LLM_HEALTH_PROBE_IDLE_MAX_MS`.
- **Regex per keylogger event.** `MF_ShouldFilter` runs 7 `RegExMatch` over the
  window title on every logged event when `private_browsing` is on — the only
  real per-event regex site, never instructed. Either memoize per focus-cache
  generation (the title only changes on refresh, 50 ms TTL) or discard it
  explicitly with the measurement that justifies it.

---

## 5. Audits

Prompts live in [`docs/prompts/`](docs/prompts/) — work from the prompt, not from
a summary. **`audit_mise_en_commun_et_simplification.md` has never been run**: it
covers pushing everything non-platform-specific into `_shared/` and reducing mass
(are the `_generated/` trees still earning their committed size, can `_shared/`
be flattened, god-files, orphan tooling). One correction to apply when running
it: it says to confront your conclusions against `docs/REFACTOR_PLAN.md`, which
no longer exists — that plan was consolidated and then deleted when its cycle
completed. `PROJECT_MEMORY.md` is now the only canonical memory.

`perf_ahk.md` ran on 2026-07-21 (fixes shipped, leftovers in §4). The `bugs_*`
prompts have run repeatedly; outcomes are in PROJECT_MEMORY. `perf_hs.md` and
`refactor.md` — check PROJECT_MEMORY before running; the refactor cycle the
latter belongs to was declared complete.

Also pending from the doc triage: rewrite `docs/STATE_TRANSITION_MATRIX.md`
against the current PowerShell-worker architecture (the two dangerous
prescriptions are fixed, but the surrounding symbol names are still stale), and
refresh the "It bundles:" list in `docs/TESTING.md`, which names four checks
where `run-js-suite.cjs` now declares about sixty.

### AHK adversarial audit, 2026-07-29 — closed

The 13-lens adversarial pass confirmed 96 defects (each survived an independent
refute-by-default verifier) and refuted 8 more. **All 96 are now fixed and
committed**, each with a regression test encoding its root cause, so the list
itself has been removed rather than left here reading as outstanding work.

Two notes worth keeping:

- The last three to land were `ADP-05` (the clipboard bail-out that could not
  prove ownership returned without restoring, leaving the injected payload —
  possibly a password — for the next Ctrl+V), `G5-D` (synthetic key presses now
  declare their buffer effect at the send funnel instead of at 3 of ~40 call
  sites) and `G5-C` (extension packs are enumerated once and shared by the
  engine and the preview index, so a pack can no longer expand without ever
  being previewable).
- The audit list was itself badly stale before this cleanup: it claimed 91 open
  findings when all but three had already shipped. A finding list that outlives
  its fixes reads as a backlog and gets re-worked. Prune it as each fix lands.

---

## 6. Decided — do not re-raise

Evidence in `docs/PROJECT_MEMORY.md`.

- **Moving the KE ownership mark into `launch_headless_once()`** (the last leg of
  `ke-prime-force-claims-and-kills-unowned-bridge`): everything else in that finding
  shipped — the read-only status probe no longer claims the bridge, the poll timeout
  no longer disowns one we launched, and the settle path's pkill is ownership-gated
  like every other kill in the driver.
  What is left is moving `mark_hs_owned_bridge()` from the top of
  `prime_ke_for_session` into the branch where a headless launch actually ran, plus
  the two force-path re-marks. It stays undone deliberately. Ownership is what
  authorises the quit-time bootout, so narrowing it narrows teardown too: a force
  prime that finds a live, responsive bridge would stop claiming it and would
  therefore stop tearing it down at quit — which may be right, or may reopen the
  post-quit-remapping class recorded in PROJECT_MEMORY. The two readings cannot be
  separated by a unit test, and a previous attempt in this exact area was reverted
  for precisely that kind of unverifiable side effect. It needs one session on a real
  machine: force-prime with a foreign bridge alive, quit, and check whether the
  keyboard is still remapped.
- **Moving the clipboard transaction off the keystroke tap** (raised as
  `perform-paste-clipboard-io-inside-eventtap`): the deferral was tried and reverted
  because it breaks the paste-ordering contract pinned by
  `tests/unit/modules/keymap/test_emit_tokens_multi_paste.lua`. The two remaining
  candidates turn out to be already done, which closes the item.
  One round trip per EXPANSION rather than per token: already the case. The
  expensive `hs.pasteboard.readAllData()` runs only on the branch where no restore
  is pending (`keymap/utils.lua` `perform_paste`); every later paste in the same
  expansion cancels the pending restore and KEEPS the captured original, precisely
  so it does not re-read and capture its own payload.
  Moving the RESTORE off the hot path: also already the case — it runs from the
  `CLIPBOARD_RESTORE_SEC` timer, and its throw-path restore landed in 21c4a0208.
  What is left inside the tap is one `setContents` plus the Cmd+V, which IS the
  paste, and one `readAllData` per expansion. Neither can move without breaking the
  ordering the pinned test exists to protect.
- **Re-seeding the delay baseline at every remaining flush site** (raised as
  `shortcut-and-mouse-flush-skip-baseline-reseed`): the three keystroke-path sites
  were real and 17286ec2e fixed them. Widening it to the rest of the tree is
  refuted on its stated consequence AND on the semantics.
  The claim was that a zeroed baseline makes the next keystroke record a
  zero-millisecond gap and be "recognised as synthetic". It is not: synthetic is
  carried by the explicit `meta.s` flag (`aggregator/events.lua:101`), never
  inferred from a delay. The real effect is the one the code's own comment states —
  the inter-word gap vanishes from the timing data — which is why only the
  keystroke-path sites needed it.
  And `last_time == 0` is a deliberate sentinel: `init.lua:631` reads
  `last_time > 0 and (now - last_time) or 0`, i.e. "no previous keystroke in this
  buffer". Every remaining flush site is a boundary where that is the correct
  answer — session end after an idle timeout, the midnight day rollover, native
  autocorrect, and the stop/teardown paths. Re-seeding there would invent a typing
  interval across a gap that was not typing.
- **A resolve memo bypassed on the dynamic-hotstring preview path** (raised as
  `resolve-not-memoised-on-preview-path`): refuted by reading the file.
  `_shared/lua/dynamic_hotstrings/init.lua` holds exactly one state table,
  `local _rules = {}` — there is no cache anywhere in it. `match_buffer` calls
  `pcall(rule.resolver)` unconditionally on every suffix hit and `M.preview` is a
  three-line delegation to that same function, so there is no memo for the preview
  to bypass. The defect shape needs two divergent resolution paths and there is
  one: `rules_engine.lua`'s interceptor and its preview provider both call the
  identical `SharedEngine.match_buffer`.
- **Per-tail cap on the end-char match loop**: five synchronised sites where
  missing one silently shortens the bound — a hotstring that stops firing — for a
  sub-microsecond gain four orders of magnitude below the profiler threshold.
  The same mechanism on the hotter STAR loop was already refuted.
- **Tooltip window reuse**, **chunking the emoji registration**, **timing tricks
  around the WebView2 cold start**: tried, reverted, or rejected with blockers.
- **Reconciling the three word-boundary predicates**: the AHK/Hammerspoon
  divergence is deliberate — do not fix without a concrete user need.
- **Descending-index iteration in `HookDispatcher`**: rejected in the code
  itself; it underflows and skips a subscriber that unsubscribes itself.
- **Idle-gating the keylogger network ticks** and the AV WMI scan: cost accepted
  explicitly — in-process, and they only emit on a state change.
- **Removing the 75 ms tooltip render debounce** as "pure added latency on every
  preview" (raised as `G4B-02`): refuted by the fix to `G4B-01`. The preview must
  land after `TOOLTIP_UIA_IDLE_REQUIRED_MS` of physical idle for stage 2 of the
  position cascade to be reachable, and `_PREFIX_RENDER_DEBOUNCE_MS` (150) plus
  `TOOLTIP_RENDER_DEBOUNCE_MS` (75) is exactly what clears the 200 ms gate, with
  25 ms of margin. Dropping the 75 ms puts the render back under the gate and
  silently disables the position cache. The relationship is pinned by
  `tests/meta/test_tooltip_debounce_is_load_bearing.ahk`.

## Other

### Donne moi ton avis sur mon projet. pas besoin d’aller lire des fichers ou autre, utilise ta mémoire et dis moi ce que tu en penses

Avec plaisir — avis franc, pas de flatterie.

#### Ce qui m'a réellement impressionné

La rigueur d'ingénierie est très au-dessus de la norme — pas seulement pour un projet solo, au-dessus de beaucoup d'équipes professionnelles. 3 377 tests Lua, 3 386 tests AHK, 1 146 Linux, des gates JS, des tests de parité cross-driver, des méta-tests qui testent les tests (la chasse aux faux-verts, les ratchets qui comptent même les commentaires…). La règle « chaque bug corrigé = un test de régression qui encode la cause racine » est appliquée pour de vrai — je l'ai vécue aujourd'hui : mon propre test m'a attrapé sur CI Linux quelques heures après que je l'ai écrit. C'est exactement le but, et presque personne ne tient cette discipline.

L'architecture _shared/ est la bonne réponse au bon problème. Trois drivers sur trois OS, ça dérive toujours. Ici, la source unique + les tests de parité rendent la dérive structurellement difficile. Le travail sur l'ordre des langues aujourd'hui s'est inséré dans un pattern déjà établi — signe d'une architecture saine.

PROJECT_MEMORY.md est une idée brillante. Une mémoire institutionnelle in-repo, partagée entre humains et agents, avec les leçons chèrement acquises. La plupart des projets perdent ce savoir à chaque contributeur ou session qui part. C'est le workflow augmenté par IA fait intelligemment.

Le produit est réellement singulier. Espanso fait les snippetspayant, personne ne combine hotstrings + IA 100 % locale +tap-holds + gestes + métriques, gratuit, sur trois OS. Le positionnement vie privée est un vrai différenciateur au moment où tout le monde envoie sa
frappe dans le cloud.

#### Ce qui me préoccupe — honnêtement

Le goulot n'est plus le code, c'est la distribution. 14 étoileent d'ingénierie, c'est un ratio effort/adoption extrême. Leproduit mérite 100× son audience actuelle. La page refaite et l'anglais sont des pas dans le bon sens, mais il faut aller chercher les gens : Hacker News
(l'angle « IA locale qui complète ta frappe » est taillé pour)mmunautés Bépo/Ergo-L. C'est inconfortable comparé à écrire ducode — c'est pourtant là qu'est le levier maintenant.

La friction d'installation tue des conversions. Le xattr macOS (app non notarisée) et l'exe Windows probablement flaggé SmartScreen éliminent les
utilisateurs non techniques — précisément ceux à qui les hotstice. Signer/notariser est à mon avis le meilleur euro investidu projet.

Le driver Linux est un risque d'inventaire. « Complet sur le papier, jamais exécuté en conditions réelles » — 16 000 lignes qui dorment. Je ne mettrais
plus une heure dedans avant d'avoir 2-3 testeurs réels ; sinon.

La méticulosité a un coût. Les 335 réglages, l'alignement des les conventions extrêmement strictes… c'est aussi ce qui rendle code survivable en solo, donc je ne dis pas d'arrêter — mais chaque heure de ratchet est une heure qui n'atteint pas un utilisateur. L'équilibre actuel
penche très fort côté interne.

Un conseil stratégique : Ergopti+ est le produit qui a un marcssion qui a une niche. Le découplage est déjà fait (« marchesur toute disposition ») — assume-le jusqu'au bout dans le discours. Et un jour, ose un v1.0 : v0.0.0-dev.87 raconte « pas fini » à des gens à qui tu
demandes de confier leur frappe.

#### En une phrase

C'est un projet d'artisan — rare, cohérent, construit pour dur n'est pas technique : c'est que personne ne le découvre. Lecode est prêt pour dix fois plus d'utilisateurs ; la prochaine bataille se gagne hors du repo.

### Aurais-tu des idées de features encore à ajouter ?

Oui, plusieurs — et je les classe par effet de levier : le projet a déjà des infrastructures (métriques SQLite, pont LLM, index de préfixes, catalogue
partagé) qui rendent certaines features quasi « gratuites » aljets entiers ailleurs.

#### Les évidences à fort levier

1. Le coach de frappe — ta feature signature possible. Les métmots et n-grammes les plus tapés. Croise-les avec le moteur dehotstrings : « Tu as tapé “cordialement” 47 fois ce mois-ci → créer cor★ ? » en un clic depuis le menu. Et l'inverse : quand l'utilisateur tape en entier
un mot qui a déjà une hotstring, un petit rappel « pex★ existee personne n'a les données ET le moteur dans le même produit.C'est la boucle qui rend la suite plus utile chaque semaine.

2. IA sur sélection. Tu as déjà le modèle local, les profils de prompt, et des actions de sélection (casse, etc.). Ajoute : corriger / reformuler /
traduire / résumer la sélection via un geste ou tap-hold. C'esud — très visible en démo, et ~80 % de la plomberie existedéjà.

3. Importeurs Espanso / TextExpander / aText. Faible effort, gros levier d'adoption : les gens ne migrent pas s'ils doivent retaper 200 snippets. «
Importez vos snippets en un clic » lève la barrière n°1 au swi

4. Sync locale multi-machines. Toi-même tu jongles Windows/macmieux : un dossier de config surveillé, synchronisable pariCloud/Syncthing/Dropbox — sans serveur, fidèle à la philosophie. Les hotstrings perso qui suivent l'utilisateur partout, c'est de la rétention pure.

#### Le cœur du métier à approfondir

5. Variables et formulaires dans les snippets — {date}, {clipboard}, position du curseur après expansion, champs à remplir. C'est LA feature la plus
demandée des expandeurs (si pas déjà couverte par tes hotstrinant).

6. Profils par application. La détection d'app existe déjà (testrings/réglages par contexte — l'expansion ;; en éditeur decode mais pas dans le terminal — c'est la feature « power user » qui fidélise.

7. Packs communautaires de hotstrings. Un dépôt de packs TOML (médecine, droit, dev, LaTeX…) installables depuis le menu. Techniquement trivial vu ton
format ; stratégiquement malin : chaque pack est une porte d'e

#### Le pari plus ambitieux

8. Dictée locale (whisper.cpp / MLX-Whisper). Gros morceau, maaux et de catalogue de modèles se généralise directement, et «dictée 100 % locale » s'insère parfaitement dans le positionnement vie privée — c'est un marché en pleine explosion, avec très peu d'offres locales
sérieuses.

#### Ce que je ne ferais pas

Palette de commandes/launcher (Raycast/Alfred ont gagné), gestmplet (encombré, faible différenciation), et toutinvestissement Linux supplémentaire avant d'avoir des testeurs réels.

#### Conclusion

Si je devais en choisir trois : le coach (1) — différenciationIA sur sélection (2) — démo spectaculaire, plomberie existante; les importeurs (3) — parce que ton vrai problème est l'adoption, et c'est la feature qui la débloque. Et je le redis en une ligne : une feature de plus convertira toujours moins qu'une app notarisée/signée et un po



## Hammerspoon audit 2026-07-29 — findings still open

The audit report was retired once its findings were adjudicated: 111 candidates,
92 confirmed, 17 refuted, 2 hypotheses. Everything at CRITICAL and HIGH severity
shipped, along with roughly half the rest — each with a regression test proven red
before the fix and green after.

These 36 did not ship. They are carried here verbatim so nothing was lost with the
file: location, root cause, proposed fix and proposed test. Two caveats that the
pass itself established, and that apply to every line below:

- **They are leads, not work orders.** Roughly one in six audit findings on this
  repo turns out to be false, stale, or already fixed once someone opens the
  file. Three were refuted that way while working through this list — including
  one whose "obvious" guard would have broken first-run Karabiner priming, and
  one where the code's own call-site comment explained why the thing called dead
  is a deliberate safety net.
- **Two were attempted and deliberately reverted**, because a test that must not
  be weakened said the fix was wrong: deferring the clipboard transaction off the
  keystroke tap breaks the paste serialisation contract, and gating the LLM
  startup backup check on an in-flight marker defeats the backup's entire purpose.
  Both need a different approach, not a retry of the same one.


### Verifier corrections — read these before touching the findings they name

A second adversarial pass (28 agents, each re-deriving the artefacts and each
finding then handed to a refuter told to kill it) confirmed 17 of the open items
and refuted 4. Every confirmed one came back with its proposed fix amended. The
three amendments that will otherwise cost a reverted commit:

- **UML-3** — do NOT gate the 3 s backup check on a dispatch flag.
  `tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua`
  asserts `#captured_checks == 2` in THREE places, under the proposed test's own
  setup: the naive fix turns them red and the proposed test is their negation.
  The real defect is that `_startup_check_generation` is an OUTCOME guard asked an
  IN-FLIGHT question — on the MLX path a terminal outcome is 60-90 s away, so at
  t=3 s the generation always still matches and the backup always double-dispatches.
  Fix the SINK instead: promote readiness in `models_manager_mlx_server.lua` from a
  per-invocation local to module state plus a waiter list, so a duplicate check
  joins the in-flight one instead of starting a second. That is below the seam the
  pinned test stubs, so it stays green.
- **perform-paste-clipboard-io-inside-eventtap** — deferring the paste was already
  tried and reverted; it breaks the ordering contract pinned by
  `test_emit_tokens_multi_paste.lua`. Evaluate instead: one pasteboard round trip
  per EXPANSION rather than per token, or moving only the RESTORE off the hot path.
  Do not re-propose the deferral.
- **ADAPT-4** is two claims and only one survives. 4a ("CACHE_VERSION never
  validated") is REFUTED: `adapters/toml_cache.lua` validates it as the first
  clause of its invalidation guard, and a snapshot from an older version is
  rejected. What remains is the 512-byte fingerprint window, which covers the
  `[_meta]` header and none of the entries — so do not close the item with 4a.

Refuted outright and not to be re-raised: `adapt-4b` as stated,
`karabiner-delay-dialogs-never-open-newline-in-applescript` (the mechanics
reproduce but the AppleScript grammar model behind the conclusion is wrong),
`dynhs-preview-resolve-memo-bypass`, and `UIW-6`.

### MEDIUM

