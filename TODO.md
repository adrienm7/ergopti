<!-- TODO.md -->

# TODO

Known, scoped, not done. Everything here was verified against the code on
2026-07-21 — items that turned out to be already delivered were dropped rather
than carried forward.

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

- [ ] **ke-prime-force-claims-and-kills-unowned-bridge** — PARTLY DONE (the read-only status probe no longer claims ownership, and the poll timeout no longer disowns a bridge we launched. STILL OPEN: mark_hs_owned_bridge() at the top of prime_ke_for_session claims a bridge before any launch, the two force-path re-marks, and the un-gated KILL_FAST_CMD. Left open deliberately: moving the mark into launch_headless_once() changes quit-time teardown for the force path, and a previous attempt in this area was reverted for exactly that kind of unverifiable side effect. It needs a real driver to confirm, not a unit test.) — (karabiner) — prime_ke_for_session marks HS ownership unconditionally and fires KILL_FAST_CMD with no is_hs_owned_bridge gate
  - `static/ergopti_plus/macos/modules/karabiner/ke_lifecycle.lua:773-774 (mark_hs_owned_bridge before any launch) and :921-922 (un-gated pkill); consumers: ui/menu/menu_karabiner.lua:899-905 and :870-883; modules/karabiner/init.lua:571-586; gate that later trusts the marker: modules/karabiner/init.lua:886-896`
  - **Cause:** Ownership is asserted at the START of the prime cycle rather than at the moment HS actually launches the bridge (launch_headless_once(), ke_lifecycle.lua:779-787). And KILL_FAST_CMD at :922 is the one kill in the module with no is_hs_owned_bridge() gate — set_enabled(false) (karabiner/init.lua:200-209) and M.kill() (:886-896) both have one. The non-forced paths are correct: a running user bridge short-circuits at :752-757 BEFORE mark_hs_owned_bridge(), which is exactly why the gap only shows on force=true.
  - **Fix:** (1) Gate ke_lifecycle.lua:922 on `M.is_hs_owned_bridge()` (log and skip otherwise), mirroring karabiner/init.lua:200-209. (2) Move mark_hs_owned_bridge() out of :774 and into launch_headless_once() on the branch where hs.execute(KE_PRIME_HEADLESS_CMD) actually ran, so the marker only ever means "HS spawned this bridge". The three existing success sites (:800, :894, :913) already re-call it, so the happy path is unaffected.
  - **Test:** Extend tests/unit/modules/karabiner/test_ke_lifecycle.lua: stub hs.execute so is_ipc_bridge_running() reports a live bridge and is_cli_roundtrip_ready() reports failure, ensure no owner marker exists, call KE.prime_ke_for_session(function() end, true), then assert (a) `helpers.assert_eq(KE.is_hs_owned_bridge(), false, "a forced prime must not claim ownership of a bridge HS did not start")` and (b) the recorded hs.execute command list contains no KILL_FAST_CMD. Both fail today.
- [ ] **eventtap-does-ax-and-tis-work-once-per-word** (keylogger) — handle_key performs a cross-process AX window-title read and a Carbon TIS layout query on the first keystroke of every word, inside the eventtap callback
  - `static/ergopti_plus/macos/modules/keylogger/init.lua:617-626; static/ergopti_plus/macos/modules/keylogger/init.lua:531; static/ergopti_plus/macos/modules/keylogger/init.lua:537`
  - **Cause:** The context snapshot was written as a direct query instead of a read of already-cached state. CoreState.active_app_name / active_app_bundle are maintained by context_tracker.app_watcher_cb (context_tracker.lua:472-476) on every activation, and the focused window title is already tracked in context_tracker's `_last_win_title` (:407). Nothing in handle_key consults either. hs.window title reads go through AXUIElementCopyAttributeValue, which blocks on the target process; macOS answers a slow tap with kCGEventTapDisabledByTimeout, which turns a lag problem into a dead keylogger tap (the watchdog at init.lua:1424-1432 would restart it 5 s later, losing everything typed in between). The driver al
  - **Fix:** Replace the per-word snapshot with cached reads: `CoreState.session_app_name = CoreState.active_app_name or "Unknown"`, `CoreState.session_win_title = <title cached by context_tracker.update_private_status>`, and cache the layout in a module local refreshed by the existing layout-change watcher rather than calling hs.keycodes.currentLayout() inline. At :531/:537 use CoreState.active_app_name instead of frontmostApplication():title(). If a live read is genuinely wanted, take it in an hs.timer.doAfter(0, ...) that writes into CoreState for the NEXT buffer.
  - **Test:** New tests/meta/test_keylogger_tap_defers_blocking_context.lua, modelled on tests/meta/test_pause_path_defers_blocking_work.lua's function_slice helper: slice `local function handle_key` out of modules/keylogger/init.lua and assert the slice contains none of ":mainWindow()", "hs.keycodes.currentLayout(", "hs.application.frontmostApplication(" outside an `hs.timer.doAfter(0,` wrapper. Fails today on all three; passes once the snapshot reads CoreState. Pair it with a behavioural case in the test_ke
- [ ] **perform-paste-clipboard-io-inside-eventtap** (keymap-core) — perform_paste() reads and rewrites the whole pasteboard synchronously inside the keyDown eventtap callback
  - `static/ergopti_plus/macos/modules/keymap/utils.lua:157-182 (perform_paste; :167 hs.pasteboard.readAllData()`
  - **Cause:** The expander's design note (expander.lua:14-16) justifies running expansions inline because "CGEventPost() is non-blocking, so keyStroke() calls return immediately". That is true of the key posts but not of the clipboard transaction that precedes them. perform_paste performs unbounded cross-process I/O whose cost is proportional to the SIZE OF THE USER'S CLIPBOARD — a quantity the driver neither controls nor bounds — on the hottest path in the driver.
  - **Fix:** Defer the clipboard transaction one tick with the driver's own idiom: wrap the save / setContents / Cmd+V body of perform_paste in hs.timer.doAfter(0, function() ... end) so it leaves the eventtap callback (the same DEFER_TOKEN pattern pinned by tests/meta/test_pause_path_defers_blocking_work.lua:47). _paste_ops_pending must stay incremented synchronously at utils.lua:258/:328 so take_paste_ops() still arms expected_synthetic_pastes before perform_text_replacement returns, and emit_text must keep returning a non-zero order_delay so the terminator fence still applies. Stronger fix: keep an off-tap clipboard snapshot refreshed by an hs.pasteboard changeCount poll / watcher, so readAllData neve
  - **Test:** New tests/meta/test_paste_defers_clipboard_io.lua, modelled on tests/meta/test_pause_path_defers_blocking_work.lua: slice `local function perform_paste` out of modules/keymap/utils.lua (bounded by the next top-level declaration) and assert, for each of "hs.pasteboard.readAllData()" and "hs.pasteboard.setContents(", that a "hs.timer.doAfter(0," token appears earlier in the slice — with the message naming the tap-disable consequence. Fails today (neither call is wrapped); passes after the deferral
- [ ] **mlx-discovery-restart-storm** (llm-backends) — A failed MLX discovery cycle restarts itself on the very next run-loop tick with the backoff reset — a per-tick curl+HTTP storm on the main thread
  - `static/ergopti_plus/macos/modules/llm/api_mlx_discovery.lua:271-289`
  - **Cause:** finish_discovery(false) (api_mlx_discovery.lua:271-289) clears the `_endpoint_probe_in_flight` mutex and then synchronously fires every queued callback. Each queued callback is `function() M.warmup(model_name, profile) end` (api_mlx.lua:549). M.warmup re-tests `ApiMlxDiscovery.is_discovered()`, which is still false on the failure path, and calls `ApiMlxDiscovery.discover()` again inline with no cooldown (api_mlx.lua:544-551). discover() then arms `poll_timer = TimerScheduler.after(0, do_poll)` (:484) and re-initialises BOTH pacing variables of the new cycle: `poll_delay_sec = DISCOVERY_POLL_INITIAL_SEC` (:386) and `started_at = TimerScheduler.now()` (:269). The exponential backoff and the DI
  - **Fix:** Add inter-cycle pacing owned by api_mlx_discovery. Record `_last_cycle_finished_at = TimerScheduler.now()` inside finish_discovery(), and in M.discover() refuse to arm a new probe cycle while `now - _last_cycle_finished_at < DISCOVERY_RETRY_COOLDOWN_SEC` — instead schedule the cycle through `TimerScheduler.after(remaining, ...)` so the caller's on_done is still honoured, just later. Equivalently (and less invasively) change api_mlx.lua:549 so the warmup callback re-enters through `TimerScheduler.after(DISCOVERY_RETRY_COOLDOWN_SEC, function() M.warmup(model_name, profile) end)` rather than calling discover() inline. The cooldown constant must come from lib.timings, not a literal. IMPORTANT: d
  - **Test:** New file tests/unit/llm/test_api_mlx_discovery_restart_cooldown.lua. Stub adapters.timer_scheduler so `after(delay, fn)` only RECORDS {delay, fn} (never runs it) and `now()` returns a controllable clock; stub adapters.shell_runner so `spawn()` returns a handle whose `start()` increments `spawn_count` and synchronously invokes on_done(0, '{"data":[]}'); stub adapters.http_client's `new().post` to call back synchronously with `{status = 404, body = ""}`. Then call `ApiMlxDiscovery.discover(functio
- [ ] **UML-3** (ui-menu-llm) — The boot 'backup' check dispatches a duplicate force_mlx_check while the primary is still in flight — two stacked hardware dialogs and two downloads of the same model on first run
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:275 and :279-307`
  - **Cause:** The F-MED-32 fix guards the *resolution* of the two chains (each success re-checks the generation) but not their *dispatch*. There is no 'primary already dispatched and not yet resolved' flag, so the backup, whose stated purpose is 'in case the primary callback chain was skipped', fires whenever the primary is merely slow — which is the normal case for a model that must be downloaded or a server that takes 60 s to load weights.
  - **Fix:** Track dispatch, not just resolution: set a `_primary_in_flight = true` immediately before `check_fn(...)` (cleared in both of its callbacks) and have the 3 s backup return early when it is set, in addition to the existing generation check. That preserves the backup's real purpose (the primary chain never dispatched at all) while removing the duplicate.
  - **Test:** Add a case to tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua asserting `#captured_checks == 1` after `fire_all_timers` when the primary's callbacks have not yet been invoked. Note this INVERTS the current `assert_eq(#captured_checks, 2, …)` used as setup in the existing cases, so those three cases must be re-plumbed to fire the primary's dispatch explicitly rather than relying on the duplicate — do not delete them.
- [ ] **BS-1** (boot-shutdown) — The menu's config pathwatcher — a SECOND recursive watcher on the same base_dir — has neither the TOML-cache exclusion nor the self-written-file exclusion that init.lua so carefully passes to lib/file_watchers
  - `ui/menu/menu_watchers.lua:110-138 (reload_config filter)`
  - **Cause:** Two recursive pathwatchers cover base_dir: lib/file_watchers' project_watcher and ui/menu/menu_watchers' configWatcher. init.lua computes TOML_CACHE_DIR once (line 214) precisely so 'the writer and the watcher cannot drift apart again' and threads it plus the self-written paths into lib/file_watchers.start (863-877). menu.start() arms the second watcher with only (base_dir, on_reload, get_suppress_until, ui_restore) — no ignored_dirs, no self_written_files. The exclusion was applied to one of the two watchers on the same tree.
  - **Fix:** Thread the same context into MenuWatchers.start_config_watcher: pass ignored_dirs (init.lua's TOML_CACHE_DIR) and self_written_files (menu_paths ConfigTomlPath + KarabinerConfigPath) down from menu.start, and apply the exact is_runtime_artefact / is_self_written predicates from lib/file_watchers.lua:110-134 inside reload_config. Better still: delete the duplicate watcher entirely and let lib/file_watchers own base_dir — it already watches the same tree with a strictly stronger filter, a boot-suppress window, the adaptive settle, multi-repo git gating and fire-time re-checking.
  - **Test:** New tests/unit/ui/menu/test_menu_watchers_runtime_artefacts.lua, mirroring section 3 of tests/unit/lib/test_file_watchers_reload_gate_coverage.lua: stub hs.pathwatcher/hs.timer, arm start_config_watcher on /fake/driver/, fire '/fake/driver/cache/toml_hotstrings/x_1.lua', assert no debounce timer was armed and reloads()==0; then fire '/fake/driver/modules/keymap/init.lua' and assert exactly one reload, so an exclusion that swallows the whole tree also fails.
- [ ] **BS-4** (boot-shutdown) — file_watchers arms one FSEvents stream per directory AND per .toml file in the personal tree — all redundant with the recursive parent watchers, all created synchronously after the typing eventtap is already armed
  - `lib/file_watchers.lua:291-338 (watch_personal_hotstrings_dir: one hs.pathwatcher per directory at :309-317 AND one per .toml at :327-331) and :368-377 (one more per .toml in hotstrings_dir); armed from init.lua:852-877`
  - **Cause:** The per-file and per-sub-directory watchers are documented as 'a safety net for in-place edits that directory watchers may miss' (file_watchers.lua:367) — but hs.pathwatcher is already recursive and already reports individual file paths, so the parent watcher covers every one of them. The redundancy also defeats the module's own hygiene: the sub-directory watcher (:309-315) filters only `^/tmp/`, and the per-file watcher (:327-329) filters nothing at all — neither applies is_self_written or is_runtime_artefact, unlike dir_watcher and project_watcher.
  - **Fix:** Delete the recursion entirely and arm ONE recursive hs.pathwatcher on the personal-hotstrings root, routing it through the same extension + is_self_written + is_runtime_artefact filter dir_watcher uses (file_watchers.lua:272-281). Likewise drop the per-file loop at :368-377, which duplicates dir_watcher on the same directory. Cost goes from 2+D+N+M streams to 3, the boot walk (fs_dir.entries plus one hs.fs.attributes per entry) disappears, and every changed path gets the strong filter instead of the weak one. If the safety net is genuinely needed on some macOS version, arm it lazily from a doAfter(0) tick after boot rather than inline at init.lua:852.
  - **Test:** Extend tests/unit/lib/test_file_watchers.lua: with hs.fs.attributes reporting a personal tree of one directory containing three .toml files, assert #_G.script_watchers stays at a small constant (3) rather than growing with the file count — encoding 'watcher count must not scale with the corpus'. The existing stub already counts armed watchers, so the assertion drops straight in.
- [ ] **karabiner-stale-layout-actions-on-resume** (karabiner) — Layout rebuild re-resolves every logical_char action BEFORE the pause guard, and regenerate() never re-resolves — so resume deploys a KE config built for the pause layout
  - `static/ergopti_plus/macos/modules/karabiner/init.lua:759-777 (reload at 761-762`
  - **Cause:** The refresh of the layout-dependent action table and the consumer of that table live on different code paths. The refresh (init.lua:761-762) sits on a path that then refuses to act (the pause guard is 11 lines BELOW it), and the consumer M.regenerate() -> Generator.build_karabiner_json(_state, M.AVAILABLE_ACTIONS, …) never refreshes. Secondary: mutating M.AVAILABLE_ACTIONS while paused is itself a « pause = tout éteint » violation — a paused script rebuilds 673 action tables and writes 548 DEBUG log lines.
  - **Fix:** Hoist the `shortcuts.is_paused()` block (init.lua:773-777) ABOVE the Config.load_available_actions() call at init.lua:761-762. That makes the paused branch mutate nothing, so M.AVAILABLE_ACTIONS keeps its pre-pause (Ergopti) resolution, which is exactly what the resume redeploy needs. Optional hardening: have M.resume() arm the regenerate on LAYOUT_TIS_SETTLE_SEC instead of doAfter(0), so the TIS keycode map has settled after the resume-layout switch.
  - **Test:** New tests/unit/modules/karabiner/test_layout_rebuild_no_reload_while_paused.lua, built on the existing load_karabiner(paused) harness in test_regenerate_pause_guard.lua: additionally stub modules.karabiner.config so load_available_actions increments a counter, capture the on_change callback that karabiner/init passes to Watchers.start_input_source_watcher (and the doAfter callback it arms), drive them with shortcuts.is_paused() == true, then assert `helpers.assert_eq(reloads.count, 0, "a paused 
- [ ] **karabiner-actions-rebuilt-673-per-layout-change** (karabiner) — load_available_actions() re-decodes modifier_chords.json and rebuilds 673 action tables + 548 DEBUG log lines on every layout change
  - `static/ergopti_plus/macos/modules/karabiner/config.lua:89-130 (append_shared_modifier_chords)`
  - **Cause:** The layout-dependent part of an action is only its karabiner_to[1].key_code. The whole catalogue (file read, JSON decode, 600 table constructions, 673 label concatenations) is rebuilt to refresh that one field, and the per-action debug line was written for a handful of hand-authored actions before the 600-entry shared chord matrix was appended in front of it.
  - **Fix:** Memoise the decoded modifier_chords.json and the generated chord skeleton at module scope; on a layout change only re-run the key_code_for_char resolution over the entries that carry logical_char, mutating karabiner_to[1].key_code in place. Replace the 548 per-action Logger.debug calls with one aggregate `Logger.debug(LOG, "Resolved %d layout-dependent action(s) for the current layout.", n)`.
  - **Test:** New tests/unit/modules/karabiner/test_load_actions_memoises_chords.lua: stub the JSON loader to count how many times the shared modifier_chords.json path is opened, call Config.load_available_actions twice, then `helpers.assert_eq(chord_reads, 1, "the shared modifier-chord catalogue must be decoded once per session")`. Fails today (2), passes after memoisation.
- [ ] **classify-trigger-hot-call-site-still-scans** (keymap-core) — 5a6055f18 memoised classify_trigger and converted the COLD call site; the HOT one it was written for still reaches the scan
  - **Status:** the memo, its invalidation on every corpus mutation, and the disable_group leak are all done. What is left is routing the remaining hot call site through the memo. Re-derive which site that is before acting — the original entry named a query string that a later pass showed to be wrong.
- [ ] **LIBCORE-5** (lib-core) — app_picker.discover_apps() runs a blocking `find` subprocess plus one Info.plist read and one icon rasterisation per installed app on the main run loop, reached only through hs.timer.doAfter — which is not a thread hop
  - `static/ergopti_plus/macos/lib/app_picker.lua:34-73 — `pcall(hs.execute`
  - **Cause:** Both call sites use `hs.timer.doAfter` as if it moved the work off the thread. It does not — PROJECT_MEMORY project-hs-partial-fixes-and-false-green-tests states it verbatim ("doAfter(0) is not a thread hop"), and the same lesson is the reason ShellRunner/spawn exists and the reason network_info.lua (adapters/network_info.lua:18-25) explicitly refuses a synchronous hs.execute for its ping probe. app_picker predates that policy and was never migrated. Secondary, same file: M.build_menu:101-231 loads and resizes one icon per ALREADY-EXCLUDED app on every menu-tree rebuild (its own comment at 223-224 notes it runs twice per rebuild), so the icon cost is paid on every updateMenu(), not only when
  - **Fix:** Give discover_apps a callback and route the enumeration through `adapters.shell_runner.spawn` (async, GC-pinned in M._active_tasks) instead of `hs.execute`; populate the chooser from the completion callback. Resolve bundle IDs and icons lazily — hs.chooser renders rows on demand, so the per-app infoForBundlePath/imageFromAppBundle loop can be replaced by a memoised per-bundle lookup, and the results cached for the process lifetime (the installed-app set does not change between two clicks of the same menu). For build_menu, memoise `imageFromAppBundle(bundleID)` in a module-level table so a menu rebuild re-uses the images instead of re-rasterising them.
  - **Test:** New `tests/unit/lib/test_app_picker_no_blocking_exec.lua`: stub `hs.execute` with a spy and assert `#exec_calls == 0` after calling M.discover_apps (asserting absence of the harmful operation, per the project's own rule for this class), plus a behaviour case proving the async path still yields the full choice list through its callback. Add a second case pinning the icon memo: call build_menu twice with the same excluded list and assert `hs.image.imageFromAppBundle` was invoked once per distinct 
- [ ] **mlx-never-load-failed-when-discovery-never-succeeds** (llm-backends) — The MLX give-up backstop never starts its clock when discovery never succeeds — a server that never answers leaves the status dot orange forever and grows the pending-callback queue without bound
  - `static/ergopti_plus/macos/modules/llm/api_mlx.lua:544-564 (the discovery short-circuit returns before `_warmup_started_at` is ever stamped); static/ergopti_plus/macos/modules/llm/api_mlx_discovery.lua:271-289`
  - **Cause:** `_warmup_started_at` and the `warmup_elapsed >= WARMUP_GIVE_UP_SEC` check sit AFTER the `if not ApiMlxDiscovery.is_discovered() then … return end` short-circuit (api_mlx.lua:544-564). That placement is deliberate and pinned (see existing_test_checked) so a slow weight load is not falsely failed — but it means the give-up budget measures post-discovery warmup time ONLY. A permanent discovery failure is on no clock at all, and no other counter bounds it: the launcher's fast path (ui/menu/menu_llm/models_manager_mlx_server.lua:520-541) calls mark_load_failed only when it recognises a Python traceback in the server's stdout, which never happens if the server was never ours or never started.
  - **Fix:** Bound discovery on its own clock. Stamp `_discovery_first_attempt_at` on the first discover() of a (server, model) identity — cleared by reset() — and in api_mlx.warmup's discovery branch, before calling discover(), check that elapsed discovery time against a DISCOVERY_GIVE_UP_SEC budget read from lib.timings; on exceed call `M.mark_load_failed(model_name, true)` once and return. Also clear the budget in reset_endpoints() alongside `_warmup_started_at`. Do NOT fix this by moving the `_warmup_started_at` stamp above the short-circuit: tests/unit/llm/test_api_mlx_warmup_giveup_after_discovery.lua asserts that exact source ordering and such a change would regress it.
  - **Test:** New file tests/unit/llm/test_api_mlx_giveup_when_discovery_never_succeeds.lua. Capture notifications by installing a lib.notifications stub BEFORE the fresh `require("modules.llm.api_mlx")` (the exact technique used by tests/unit/modules/llm/test_api_mlx_load_failure.lua). Stub adapters.timer_scheduler with a controllable `now()`; stub modules.llm.api_mlx_discovery with `is_discovered = function() return false end` and `discover = function(cb) if cb then cb() end end` (a discovery that always fa
- [ ] **UIMENU-7** (ui-menu) — Every pause toggle rebuilds the menubar icon TWICE (disk read + PNG decode + off-screen canvas render) synchronously inside the script-control eventtap callback
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:646-647 (pause listener) together with :881-882 (updateMenu's own first statement); body at :172-246`
  - **Cause:** `update_icon` is not a cheap setter: per invocation it does an `io.open` probe for logo_simple_disabled.png, an uncached `hs.image.imageFromPath` (file read + PNG decode), a full `hs.canvas.new` → `imageFromCanvas()` → `delete()` off-screen render round-trip to the window server, plus `setIcon`/`setTitle`. None of it is memoised — the same two PNGs are re-decoded on every call — and the pause listener duplicates the call that updateMenu already makes. Current cost: 2 × (1 file stat + 1 file open + 1 PNG decode + 1 canvas alloc/render/free + 2 menubar setters) on the eventtap-synchronous path; target: 0 on that path in the common case (icon unchanged), 1 when the variant/pause state actually 
  - **Fix:** Two zero-risk steps. (1) Delete the bare `update_icon()` at ui/menu/init.lua:646 — `updateMenu()` on the next line already calls it under pcall, so the second call is pure waste (same for the theme watcher at :1030-1033). (2) Memoise the rendered icon per (variant, paused) pair in a module-level table so the file read, PNG decode and canvas render happen at most four times per session instead of on every pause toggle, theme change and state refresh; keep the `setIcon` call itself, which is cheap. Optionally wrap the whole icon refresh in `hs.timer.doAfter(0, …)` from the pause listener so the tap callback returns immediately — but the deduplication and cache are the load-bearing part.
  - **Test:** tests/unit/ui/menu/test_pause_icon_render_once.lua: stub hs.image.imageFromPath and hs.canvas.new with counters, start the menu, invoke the registered on_pause_change callback once, and assert imageFromPath was called at most once (not twice); invoke it a second time with the same pause state and assert the counter did not grow (cache hit). Pairs with tests/unit/ui/menu/test_pause_checked_state.lua, which already covers the correctness half of the pause listener.
- [ ] **UML-6** (ui-menu-llm) — After a reload, the reattached download shows a per-file percentage as the overall progress and never a total or ETA
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua:624-643`
  - **Cause:** The reattach path was written as a stripped-down copy of `process_stream` (:346-409) but dropped the two pieces that make the number meaningful: the persistent `_bytes_done`/`_bytes_total` upvalues and the `estimated_bytes_total` lookup from `m.hardware_requirements.mlx.download_gb` in the preset tree. The session JSON carries `repo` and `model`, so the estimate is recoverable — it just is not recomputed.
  - **Fix:** Hoist `_bytes_done`/`_bytes_total`/`_current_pct` to upvalues of `reattach_download`, seed `_bytes_total` from the preset `download_gb` for `session.model` (the same lookup as :118-133), and compute the percentage from `_bytes_done / _bytes_total` exactly as `process_stream` does instead of regexing a tqdm bar. Drop the unused `_current_pct` local.
  - **Test:** New case in a tests/unit/ui/menu/menu_llm/test_mlx_reattach_progress.lua: feed `process_stream_reattached` two successive chunks `__BYTES__:1000000000` then `__BYTES__:2000000000` with a preset whose `download_gb = 4`, capture `download_window.update`'s arguments and assert the reported percentage increases monotonically and that `bytes_total > 0`. Fails today (0 and 0).
