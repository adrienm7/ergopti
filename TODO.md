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

Two pieces of work: replace them with real assertions, and add a gate that fails
on a `Test()` whose body cannot fail — otherwise they come back.

### The Linux evdev decoder has no real coverage

`linux/tests/unit/meta/test_input_reader_decode.lua:26` is `assert_true(true)`;
lines 29-53 build a 24-byte `input_event` buffer for KEY_A and then **never feed
it to `parse_event`** — the `data` variable is dead. Everything that turns raw
kernel bytes into characters is untested: little-endian decode, struct offsets,
`EV_KEY` filtering, shift tracking, key-repeat suppression (`value=2`), keyup
(`value=0`), BACKSPACE/ENTER/TAB routing. A regression on the `value != KEY_DOWN`
filter would fire hotstrings twice on a held key and stay green.

### The Linux injector — the product's output path — only asserts "does not crash"

`linux/tests/unit/meta/test_injector_commands.lua:23-60` wraps every assertion in
`pcall`, while its own header claims it "verifies the command strings are
well-formed". Nothing checks that `inject(3, txt)` emits exactly three `14:1
14:0` pairs, nor that single quotes are escaped before `ydotool type`. A
miscounted backspace deletes the wrong number of characters; a lost escape is a
shell-injection hole. Both pass today.

### The Linux "shell safety" tests are the same shape

`test_notifier_commands.lua:84-103` and `test_text_sender_adapter.lua:50-57`
assert only that nothing crashes — but `os.execute` / `io.popen` never crash on
unescaped input, they **execute** it. Removing the escaping is a silent
regression and a real command-injection hole, and these tests pass either way.

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

### macOS: pin `check_task` in the GC root

`macos/ui/menu/menu_llm/models_manager_mlx.lua:273` and `:321-322` — the last
production `hs.task.new` still started without a GC pin, while the GC root
`M._active_tasks` already exists at line 21 of the same file and is used
correctly by `delete_task`. If the collector takes it first, Hammerspoon sends
SIGTERM, the callback never runs, and neither `do_check()` nor `on_cancel()`
fires: the MLX prerequisite check hangs with no log. Same failure already
observed on Ollama. Three-line fix, and the sibling in the same file shows the
shape.

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

---

## 6. Decided — do not re-raise

Evidence in `docs/PROJECT_MEMORY.md`.

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
