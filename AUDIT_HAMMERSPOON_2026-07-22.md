# Adversarial audit — Hammerspoon macOS driver — 2026-07-22

**Scope:** `static/ergopti_plus/macos/` (+ the `_shared/lua` code the driver
consumes) at `HEAD cb274d210` (branch `dev`). Suite baseline: **3368 / 0 green**
(`cd static/ergopti_plus/macos && lua tests/run.lua`), reproduced locally before
and unchanged by this pass (this audit ships no code, only findings).

**Method.** 18 read-only finder zones ran in parallel (the hardest — boot,
keymap hot path, tooltip↔engine parity, LLM races, fix-archaeology — on Fable 5;
the rest on Opus), each fed the foot-gun catalog, the already-refuted list from
the 2026-07-20/21 passes, and the evidence rule. Every finding was then put
through **two independent verification lenses** (a code lens that re-derives the
claim from source, and a memory/convention lens that checks it against
`PROJECT_MEMORY` and the test suite); one refutation kills a finding. Zones that
still produced confirmed findings on a second pass are flagged **not dry**. A
completeness critic then named the blind spots (§8).

**Provenance.** There are **no Hammerspoon runtime logs on this machine**
(`<config_dir>/hammerspoon/` has no `logs/` dir; the logs under
`<config_dir>/autohotkey/logs/` belong to the *other* driver). Every latency or
cost figure here is therefore **deduced from reading the code**, never measured —
per `[[project_audit_evidence_must_be_reproducible]]`. The one exception labelled
*measured* is the `shell_quote` byte reproduction (§H1), which is pure Lua string
semantics and was run in `lua` on this box.

**Author verification.** Every HIGH finding below was re-opened at its cited
`file:line` and re-derived by hand before inclusion — I did not launder the
sub-agents' output. Where I confirmed a claim independently, the finding says so.

---

## 1. Executive summary

| Severity | Confirmed (deduped) | Notes |
| --- | --- | --- |
| **High** | **11** | 2 are silent PII/secret leaks; 1 re-opens the shell-injection the last audit closed; 3 are fresh regressions from 2026-07-21 fixes |
| Medium | 16 | mostly missed-sibling class-[F] and async ownership races |
| Low | 33 | (38 raw − 5 that fold into a High/Medium) |
| **Refuted** | 8 | held to the same proof bar as findings; §6 |

**What this pass did that the prior four did not.** The 2026-07-21 rounds
explicitly left `lib/toml`, `lib/i18n`, the input adapters, `ui/menu_llm`,
`ui/download_window`, `ui/healthcheck`, `ui/metrics_*`, and **`init.lua`'s boot
order / shutdown callback** unswept
(`[[project_hs_audit_2026_07_21]]`: "loop-until-dry n'a PAS été atteint"). This
pass swept all of them, plus the ~45 fix commits landed 2026-07-20→22 for
class-[F] collateral. The three most valuable results came from exactly those
never-swept areas: the `menu_llm` `check_task` GC gap, the `api_remote` cleartext
API-key log, and the `preferences.load` corrupt-config overwrite.

**Fragile zones, ranked.** (1) `modules/keymap/llm_bridge.lua` + the tooltip
preview path — nine G5 divergences between what the tooltip shows and what the
engine will emit, the exact class round 4 thought it had closed by unifying
`would_fire`. (2) The `_shared` shell-quoting / terminator code — one broken
helper and one un-mirrored fix silently corrupt every apostrophe-bearing path and
every French-punctuation terminator. (3) `menu_llm` window-ownership + `hs.task`
lifecycle — three separate "close/clobber a window another operation owns" races.

**Honest verdict.** This is a very well-defended driver: ~3368 tests already
guard hundreds of these classes, and the dominant residual bug shape is once again
**the one missed sibling site** (`[[project_ahk_invariant_incomplete_application]]`
applies verbatim), not a new class. But the audit is **not complete**: 8 of 18
zones did not reach loop-until-dry (§9), and ~25 non-test modules (~6,900 lines)
never received a coverage verdict at all (§8) — including the keylogger
cross-device export path, which directly undercuts the PII guarantees in §H5/§H9.
Treat "no finding" for those files as "not looked at", not "clean".

---

## 2. HIGH findings

Each carries: guarantee violated · `file:line` · repro · root cause · why it is
silent · the test that should have caught it · proposed fix · regression test.

### [x] H1 — Canonical `shell_quote` emits `'''` instead of the POSIX `'\''` — re-opens shell injection and corrupts every apostrophe-bearing path
**G1 · class F · `_shared/lua/text_utils/init.lua:519` (+ `macos/lib/logger.lua:325`, `macos/modules/karabiner/init.lua:545`) · confidence: high · provenance: measured**

- **Repro (measured, `lua` on this box):** `shell_quote("a'b")` returns
  `'a'''b'` — bytes `27 61 27 27 27 62 27`, **no backslash (byte 92)**. `/bin/sh`
  collapses that to `ab`. `shell_quote("a'$(id)'b")` returns `'a'''$(id)'''b'`,
  placing `$(id)` in an **unquoted command-substitution context**. Driver repro: a
  config dir or username containing an apostrophe (`/Users/O'Brien/…`) → the
  boot-path `mkdir -p` at `logger.lua:325` targets the wrong directory, and all 41
  sites routed through `text_utils.shell_quote` mis-quote.
- **Root cause:** inside a Lua double-quoted literal, `\'` is the escape for a
  bare single quote, so the source `"'\''"` is the 3-byte string `'''`, not the
  4-byte close-escape-reopen idiom `'\''` (which the source must spell `"'\\''"`).
  The docstring at `:508-515` *describes* the correct POSIX idiom; the code does
  not implement it. Exactly **three** sites carry the one-backslash spelling; the
  other ~70 sites repo-wide correctly write `"'\\''"` (the sibling
  `karabiner/generator.lua:385` is correct, proving intent).
- **Why silent:** default paths contain no apostrophe, so every nominal boot
  behaves. This is **collateral of `69fa0a069`** ("POSIX-quote every path… guard
  the class"), which routed 41 sites through this helper; its guard test
  `test_shell_quoting_not_lua_q.lua` only bans `%q` and never asserts
  `shell_quote`'s actual output.
- **Fix:** change the replacement to `"'\\''"` at all three sites.
- **Regression test:** behavioural byte-exact assertion —
  `shell_quote("a'b") == "'a'\\''b'"` **and** the result contains byte 92; plus a
  whole-tree meta-test that scans driver `.lua` for a `gsub` replacement quoting a
  quote with exactly one backslash byte (count byte 92 on the source line — never
  a Lua-escape string compare, which would itself be fooled).
- *Note:* the LOW row `logger.lua:325` is **this same bug**, site 2.

### [x] H2 — Interceptor error-latch binds a nil global (local-after-closure) — one throwing interceptor kills the whole keystroke pipeline
**G2 · class F · `modules/keymap/init.lua:715` (decl at `:1101`) · confidence: high · provenance: measured (repro'd the extracted shape in `lua`)**

- **Repro:** register an interceptor that throws (what `dynamic_hotstrings`
  rules or `personal_info` do when buggy), then type any key. Line 715
  `if not _interceptor_error_logged[idx]` indexes a **nil global** and raises;
  `onKeyDownRaw` aborts before steps 4+, so no Escape/Backspace handling, no
  buffer tracking, and no expansions run — on **every** keystroke while the
  interceptor keeps throwing.
- **Root cause:** `local _interceptor_error_logged = {}` is declared at line 1101,
  textually **after** `local function onKeyDownRaw` (line 625) which reads it at
  715-716. In Lua a local's scope starts after its declaration, so the closure
  binds the never-assigned global `_G._interceptor_error_logged` (nil). This is
  the exact trap in `[[project_lua_closure_before_local_nil_global]]`, shipped by
  fix **`227aec26d`** (2026-07-21) — the fix meant to *report* a throwing
  interceptor instead crashes the handler, turning a partial feature loss into a
  total keymap outage.
- **Why silent:** the outer `pcall(onKeyDownRaw, e)` at `:963` catches it and logs
  the misdirecting generic `"Keyboard interception failure"` (`:973`) — never the
  intended `"Interceptor #N raised"` (`:717`), so the log points at the tap, not
  the interceptor. Fires only when an interceptor actually throws — the exact
  condition the fix exists for. The guard test
  `test_interceptor_failure_visible.lua` is a presence-grep of the latch lines and
  never checks declaration order.
- **Fix:** move `local _interceptor_error_logged = {}` above `onKeyDownRaw`
  (next to the `_tc_*` module locals, ~`:462`).
- **Regression test:** source-index assertion (the repo's canonical shape for
  this class) — `src:find("local _interceptor_error_logged") <
  src:find("local function onKeyDownRaw")`. Fails at HEAD, passes after the move.

### [x] H3 — MLX requirements-check `hs.task` (`check_task`) is never GC-pinned — startup and every MLX model switch can silently stall
**G3 · class C · `ui/menu/menu_llm/models_manager_mlx.lua:273` · confidence: high · provenance: deduced (GC-timing) · found independently by 3 zones**

- **Repro:** MLX backend, LLM enabled → switch to any MLX model, or reload HS.
  `obj.check_requirements` creates `local check_task = hs.task.new("/bin/bash", cb,
  …)` (`:273`), starts it at `:322`, then returns. The task is held only by that
  local, which goes out of scope on return while the ~1-3 s python import probe is
  still running. A GC cycle in that window collects the task → Hammerspoon
  SIGTERMs the subprocess → the completion callback (`:274-318`) never fires.
- **Root cause:** the task is neither pinned into a GC root before `:start()` nor
  released in its callback. Its sibling `delete_task` (`:343-359`) does **both**
  (pin at `:358`, release at `:345`) — `check_task` follows neither half. The
  hammerspoon-driver skill names this exact site as a live example.
- **Why silent:** GC-death of an `hs.task` throws and logs nothing. Neither the
  success branch (`do_check`) nor the failure branch's `on_cancel` runs — and
  `on_cancel` is what releases the prediction lock that `model_switcher`/
  `startup_controller` set (`model_switcher.lua:408-448`), so predictions stay
  **silently locked** with no `START`-without-`SUCCESS` trail; recovery needs a
  full HS reload.
- **Why the suite is green:** `test_gc_retention.lua` is **file-granular** —
  `delete_task`'s pin greenlights the whole file (this is itself finding M16 /
  the LOW `test_gc_retention.lua:46`). This is class-[F] collateral of
  `71f0c0ec3` ("pin EVERY hs.task + whole-class check"): the widened guard is
  per-*file*, not per-*call-site*.
- **Fix:** forward-declare `check_task`, pin `M._active_tasks[check_task] = true`
  before `:start()`, and release `if check_task then M._active_tasks[check_task]
  = nil end` as the callback's first line.
- **Regression test:** per-call-site source test (parallel to
  `test_models_manager_mlx_task_forward_declared`): between each `hs.task.new`
  index and its `:start()` index there must be an `M._active_tasks[<handle>]` pin,
  and the callback body must release it. This encodes the per-site invariant the
  file-granular guard structurally cannot.

### [x] H4 — Gemini API key written in cleartext to the on-disk log on every prediction
**G2 · class E (secret leak) · `modules/llm/api_remote.lua:638` (url built `:309`) · confidence: high · provenance: deduced**

- **Repro:** configure a Gemini-format API entry (token stored via Keychain),
  backend `api`, type until one prediction dispatches, then
  `grep 'key=' <config>/logs/ErgoptiPlus_*.log` — the full URL
  `…/models/<model>:generateContent?key=<cleartext token>` is on disk (also
  mirrored into `ErgoptiPlus_llm.log`).
- **Root cause:** `build_url` (`:306-309`) embeds the decrypted token in the query
  string for `format=="gemini"`; `post_and_parse` logs the finished URL verbatim
  at `:638` (`Logger.debug(LOG, "[%s] #%d POST -> %s …", model, req_id, url, …)`).
  Default log level is **DEBUG** (`init.lua:103`), retention 14 days. This defeats
  the `api_token_crypto` invariant "the cleartext never lands on disk"
  (`modules/llm/init.lua:333`). `warmup` (`:503`) and `check_availability` (`:553`)
  build the same `?key=` URL but never log it — so `:638` is the **sole** leak.
- **Why silent:** it is a successful path — nothing fails. The leak hides in a
  routine debug line, in a log file the project actively tells users to consult
  and share for support.
- **Fix:** redact before logging — `url:gsub("key=[^&]*", "key=REDACTED")` (or log
  base+path only). Centralise a redact helper for future URL log lines.
- **Regression test:** `Logger.set_sink` capture — Gemini entry with token
  `"SECRET123"`, stub http client, call `post_and_parse` (and warmup); assert **no**
  captured line contains `SECRET123`. Encodes the invariant, not the phrasing.

### [x] H5 — Private hotstring / personal-info PII persists to `today.log` via `notify_synthetic`
**G2 · class E (PII leak) · `modules/keymap/expander.lua:117` · confidence: high · provenance: deduced**

- **Repro:** enable Metrics (keylogger), put an IBAN/SSN/phone in
  `personal_info.toml`, fire a private (`is_private`) expansion. Inspect
  `<config>/metrics/by_device/<id>/today.log` and `events_typing`: the full secret
  appears verbatim in the row's `rich_text` and in `events_json` per-char `r`
  values, and cross-device export replicates it.
- **Root cause:** `perform_text_replacement` calls
  `keylogger.notify_synthetic(logical_text, …)` **unconditionally** (`:117-124`,
  gated only on `deletes>0 or logical_text~=""`), *before* the `is_private` branch
  at `:374`/`:528`. That branch only skips `keylogger.log_hotstring` and the DEBUG
  line — it never suppresses the third sink. `notify_synthetic` →
  `append_virtual` (`keylogger/init.lua:952-961`) inserts each replacement
  codepoint into `buffer_events` (`meta.r=char`) and `rich_chunks`, which
  `flush_buffer` → `sqlite_writer` persist as `rich_text` / `events_json`.
  `buffer_text` stays clean, which is exactly why the `.text`-based privacy tests
  miss it. The comment at `expander.lua:367-373` even acknowledges the PII
  sensitivity — but guards only two of the three sinks.
- **Why silent:** it is the normal synthetic-tracking route, no error path. The
  dedicated `test_prefix_expansion_never_logs_pii.lua` stubs
  `notify_synthetic = function() end` (`:52`), so the real sink is never
  exercised; SEC-007 asserts on `.text` only.
- **Fix:** propagate `is_private` through `perform_text_replacement` to
  `notify_synthetic` and add a *private* mode that still arms the discard-queue
  markers for the physical echoes (so the key echoes are suppressed, not recorded
  as human text) but records a **redacted placeholder** into
  `buffer_events`/`rich_chunks`. **Do not** simply skip `notify_synthetic` — that
  would let the physical echoes fall through `handle_key` and be logged as human
  keystrokes in `buffer_text`, a *worse* leak.
- **Regression test:** drive the **real** `keylogger.notify_synthetic` + `flush_buffer`
  for a private expansion carrying a sentinel SSN, then assert the sentinel is in
  neither `rich_text` nor the `events_json` `r`-values; and separately assert a
  **non**-private expansion's content **does** appear (no blanket muting).

### [x] H6 — Stale-callback wrapper `sync_refs` resurrects dead prediction state after `reset()` — next Tab/Enter types an invisible stale completion
**G5/G3 · class C · `modules/llm/prediction_engine.lua:744` · confidence: high · provenance: deduced**

- **Repro:** backend `api` (or streaming off), `num_predictions=3`. Type; variant
  1 renders (`visible=true`). Press Escape → `reset()` bumps the fetch counter but
  the non-streaming HTTP is not cancelled. Variant 2 lands seconds later: the
  StreamingHandler discards it as stale, **but the wrapper still runs `sync_refs()`**
  → `predictions_visible=true`, `pending=stale pool`, no tooltip. Press Tab:
  `handle_llm_keys` gates only on `engine.is_visible()` (`llm_bridge.lua:815`) →
  `apply_prediction(1)` deletes chars and types the old completion.
- **Root cause:** `on_success`/`on_fail`/`on_partial` (`:743-755`) call
  `on_success_cb(...)` then `sync_refs()` **unconditionally** — no fetch-id guard.
  When the StreamingHandler callback self-discards on the stale-id guard, the refs
  still hold variant 1's populated values, and `sync_refs` (`:712-715`) copies
  them back into module state, undoing `reset()`'s `pending={}`/`visible=false`.
- **Why silent:** the handler-level guard logs `"Stale LLM callback ignored"` and
  looks correct; the clobber happens one level up in a 2-line wrapper with no
  logging. Nothing changes on screen at clobber time — corruption surfaces only at
  the next Tab/Enter, and any other keystroke heals it (via
  `update_preview → reset_predictions`), so it reads as a one-off ghost insertion.
  `test_streaming_handler_stale.lua` pins exactly the handler-level guarantee the
  wrapper defeats.
- **Fix:** make the wrappers staleness-aware — capture `my_fetch_id` and skip
  `sync_refs()` when `fetch_request_counter ~= my_fetch_id` (the same guard the
  handler uses).
- **Regression test:** load the real `prediction_engine` with a `core_llm` stub
  capturing the fetch callbacks; `perform_check`; invoke `on_success` (visible);
  `M.reset()`; invoke the now-stale `on_success` again; assert `M.is_visible()==false`
  and `#M.get_predictions()==0`. Fails before, passes after.

### [x] H7 — A corrupt `config.toml` is indistinguishable from an absent one — boot silently factory-resets and overwrites the user's config
**G2 · class A · `ui/menu/preferences.lua:414` → `ui/menu/init.lua:542` → `ui/menu/menu_state.lua:337` · confidence: high · provenance: deduced**

- **Repro:** make `config.toml` unparseable (a typo in the expert `[script]`/
  `[features]` layer, a git merge-conflict marker, or a cloud-sync torn write — the
  file lives in a synced dir), then reload HS. `Preferences.load` `pcall(decode)`
  fails → returns `{}` → `config_absent = next(saved)==nil = true` (`init.lua:542`)
  → boot factory-resets every group/section (`:544-560`) and
  `sync_state_to_modules` ends with `if config_absent then save_prefs() end`
  (`menu_state.lua:337`) → the corrupt file is **overwritten** with defaults. All
  user preferences permanently destroyed, no warning, no backup (the `.bak` path in
  `preferences.save` is gated `package.config:sub(1,1)=="\\"` — Windows only — so
  on macOS no backup is retained).
- **Root cause:** `M.load` (`:406-417`) collapses *missing*, *unreadable*, and
  *decode-failure* into one silent `{}` with no `Logger` call; the downstream
  `config_absent` flag then treats *corrupt* as *fresh install*.
- **Decisive corroboration:** the karabiner loader already fixed **this exact
  class** — `test_config_corrupt_toml.lua`'s docstring describes the identical
  "absent vs corrupt both → nil → persisted over the recoverable file, permanently
  destroying config" bug. `Preferences.load` is the parallel loader that never got
  that fix.
- **Fix:** return a second value from `Preferences.load` distinguishing *absent*
  from *corrupt* (and `Logger.error` on decode failure); on corrupt, keep
  `saved={}` for the session but set `config_absent=false` so the reset/save path
  never runs, and write a `.corrupt` backup before any later save.
- **Regression test:** `Preferences.load` on an invalid-TOML temp file must signal
  corruption (not plain `{}`); behavioural test on `sync_state_to_modules`
  asserting `save_prefs` is **not** called when the config was corrupt.

### [x] H8 — `reset_all_defaults` re-saves the current config before reload — factory reset keeps every config-backed toggle
**G2 · class F · `ui/menu/init.lua:524` · confidence: high · provenance: deduced**

- **Repro:** disable some hotstring groups, raise `expansion_delay`, change
  `trigger_char`, toggle preview flags, change LLM temperature. Click
  « Réinitialiser les valeurs par défaut ». After the reload every one of those is
  **unchanged**, yet the notification says « défauts réinitialisés ». Only the
  separately-wiped stores (karabiner tap/holds, hs.settings shortcuts, LLM API
  entries) actually reset.
- **Root cause:** `reset_all_defaults` (`:515-527`) removes both config files then
  immediately calls `save_prefs()` (`:524`), which rewrites `config.toml` from the
  still-current in-memory `state` (`restore_factory_bindings` resets only bindings,
  never the feature toggles in `state`). On reload the config is now **non-empty**
  → `config_absent=false` (`:542`) → the factory-seed branch is skipped and
  `merge_saved_data` re-hydrates the user's toggles. `git show fa6568f16` confirms
  the pre-existing reset was delete-config-then-reload (correctly taking the
  `config_absent` seed path); that commit *added* the `save_prefs()` intending only
  to also clear bindings — the `save_prefs()` is the unintended regression.
- **Why silent:** `notify.defaults_reset` fires unconditionally and the reload
  succeeds, so every signal reports success; toggles simply reappear at their old
  values after the ~0.25 s reload, reading as "the reset didn't take".
- **Fix:** drop the `save_prefs()` call (let the `config_absent` reload seed
  defaults, persist reset bindings via their own stores as already done), **or**
  reset the in-memory `state` back to `DEFAULT_STATE` before `save_prefs()`.
- **Regression test:** inject spies for `os.remove`/`save_prefs`/`hs.reload` and a
  `state` carrying a non-default toggle; run `reset_all_defaults`; assert the config
  that would load next boot is treated as absent, or that the persisted flat state
  equals factory `DEFAULT_STATE` for hotstrings/`expansion_delay`/`trigger_char`.

### [x] H9 — `resync_context` reads `app:title()` not `app:name()` — a vault whose title differs is not re-suppressed on resume (PII leak)
**G2 · class F · `modules/keylogger/context_tracker.lua:522` · confidence: medium (nil-title case not measurable here) · provenance: deduced**

- **Repro (hypothesis on the nil/differ case):** pause while frontmost = TextEdit,
  switch to a password manager whose `app:title()` is nil or ≠ its display name
  while `app:name()` is `"1Password"`, resume. `resync_context` (`:522-523`) gets
  `app_name=nil` (or non-matching) → either returns false (nothing re-syncs) or
  feeds `title()` to `SecureFieldDetector.isSecureApp`, which exact-matches
  **display names** (`secure_field_detector.lua:151-155`) and misses. Type in the
  vault → `is_secure_field` stays stale-false → keystrokes are logged and
  mis-attributed to the previous app.
- **Root cause:** the sibling resume helper `capture_frontmost_app` (`:359`) uses
  `app:name()` with an explicit comment (`:356-358`) that `title()` "is absent for
  some application instances" and `name()` is "the stable display-name API" — and
  the rest of the pipeline is name-based. `resync_context` regressed to
  `app:title()` at `:522` — the classic missed sibling.
- **Why silent:** on a nil title it returns false; `M.resync_context` only logs on
  `pcall` *throw*, never on a false return. On a non-matching title `isSecureApp`
  silently returns false and logging continues.
- **Fix:** resolve via `app:name()` (pcall + non-empty guard) exactly as
  `capture_frontmost_app:359` does.
- **Regression test:** resume-resync test whose frontmost-app double returns
  `title=function() return nil end` but `name=function() return "1Password" end`;
  assert `resync_context()` returns true and sets `is_secure_field == true`. (The
  existing `test_context_resync_on_resume.lua` double defines `title` to return the
  exact vault name and no `name`, so it is structurally blind to both cases.)

### [x] H10 — French typographic punctuation never terminator-expands — `is_terminator` ignores the last codepoint of NNBSP-prefixed events
**G2/G5 · class B · `_shared/lua/keymap/terminators.lua:115` · confidence: medium (deduced; needs a real-Mac repro) · provenance: deduced**

- **Repro:** a non-auto mapping (e.g. `autocorrection.toml` `agé→âgé`,
  `auto_expand=false`). Type `age` then Ergopti `?`: the Karabiner layout emits one
  event `chars = NNBSP.."?"` (the macOS layout emits `:`→NBSP, `;`/`!`/`?`→NNBSP,
  per `[[project_shifted_comma_case_variants]]`). `is_terminator` probes only the
  whole string and its **first** codepoint; NNBSP is default-disabled, so the gate
  is false (`init.lua:518`) and the terminator branch never runs — the correction
  silently does not fire, while the tooltip still advertised the `↵` row (G5).
- **Root cause (re-derived from real files):** `is_terminator` (`:115-122`) checks
  `_chars_set[chars]` and `first_codepoint(chars)` — never the **last** codepoint.
  `terminators_catalogue.lua:16-17` mark `nbsp`/`nnbsp` `default_enabled=false`
  while `:29-31` mark `?`/`!`/`:` `default_enabled=true` — so for `NNBSP.."?"` both
  lookups miss and the enabled `?` (the tail) is never tested. The **auto** path
  got the tail-codepoint fix (`init.lua:526-529`, "only the last codepoint keys the
  bucket"); the terminator gate at `:518` still passes raw `chars`. Split delivery
  fails too: `run_trigger_checks` buckets on `prev_char=NNBSP`
  (`mappings_for_tail(NNBSP)` is empty), so `try_terminator_expand`'s own NNBSP-strip
  branch (`expander.lua:414-427`) is unreachable.
- **Impact:** `autocorrection` — the flagship feature — is entirely non-auto
  French accent corrections that fire **only** on a terminator; four of the enabled
  default terminators (`? ! : ;`, canonical French sentence punctuation) arrive
  NBSP/NNBSP-prefixed. `,` `.` space tab enter `★` are unaffected (no prefix).
- **Fix:** in `is_terminator`/`terminator_is_consumed`, also probe the last
  codepoint when the leading codepoint is NBSP/NNBSP (or strip a leading NBSP/NNBSP
  before probing); in `run_trigger_checks` derive `prev_char` after stripping a
  trailing NBSP/NNBSP so the split-event shape reaches the existing terminator
  machinery.
- **Regression test:** assert `Registry.is_terminator(NNBSP.."?")` and
  `(NBSP..":")` are true with default enables; drive `try_expand` with buffer
  `age`, mapping `agé` non-auto, `chars=NNBSP.."?"`, and assert it fires and
  re-types `NNBSP.."?"`. (`test_terminators.lua:69` pins the *first*-codepoint
  dead-key probe, which a last-codepoint probe preserves; nothing covers NNBSP+punct.)

### [x] H11 — Accept-time overlap solver swallows the user's just-typed word; the tooltip showed it as an append (shown ≠ inserted)
**G5 · class G · `_shared/lua/keymap/utils.lua:220` · confidence: high · provenance: measured (probe against the real module)**

- **Repro:** buffer `"j'aime la"` (word complete, no trailing space). The LLM
  returns NEXT_WORDS `"lavande est magnifique"`; the parser yields `deletes=0`,
  `to_type=" lavande est magnifique"` (leading space = "new word"), and the tooltip
  renders it as **appended** ghost text. Accept via Tab →
  `resolve_prediction_overlap` returns `(2, "lavande est magnifique")` → the screen
  becomes `"j'aime lavande est magnifique"` — the typed `"la"` is deleted. (Also
  `"I like the"` + `" theatre…"` → `"I like theatre…"`.)
- **Root cause:** `resolve_prediction_overlap` (`:160-222`) strips the prediction's
  leading whitespace at `:176` — discarding the parser's explicit "new word starts
  here" signal — then runs a word-boundary-blind sliding window (`:212-218`) that
  matches buffer suffix `"la"` against prediction prefix `"la"` (`best_overlap=2`),
  and at `:220-222` sets `deletes=best_overlap`. Any prediction whose first word
  extends the user's completed last word (`la→lavande`, `de→demain`, `the→theatre`)
  is reinterpreted as a mid-word continuation. `tooltip_llm.build_line` renders the
  parser chunks/nw **without** the solver, so shown ≠ inserted.
- **Why silent:** no error — the solver logs a trace, `apply_prediction` logs
  SUCCESS, and the corrupted sentence reads like a model mistake, so the user
  blames the LLM.
- **Fix:** skip the sliding-window conversion when `pred_to_type` begins with
  whitespace/NBSP/NNBSP (`orig_starts_with_space` is already computed) — a leading
  space is the parser's declaration that the completion starts a new word. The
  space-less `"Je tex"`+`"texte"` dedupe path (pinned at `test_utils.lua:159-164`)
  stays intact.
- **Regression test:** `resolve_prediction_overlap("j'aime la", 0, " lavande est
  magnifique")` must return `deletes=0` and keep `"la"` on the simulated screen;
  assert the pinned `"Je tex"`+`"texte"` case still converts to delete+retype.

---

## 3. MEDIUM findings

Compact but actionable — `guarantee/class · file:line · one-line repro → fix`.
Full repro/root-cause per item is in the workflow journal; every one carries a
concrete repro and a proposed regression test.

| # | G/cls | Location | Defect → fix |
| --- | --- | --- | --- |
| M1 [x] | G1/E | `macos/init.lua:781` | `hs.shutdownCallback` is installed as the **last** boot phase, though its body is fully defensive and every local it needs exists by `:238`. A reload whose new boot throws between `:280` and `:781` leaves KE remapping the keyboard with **zero** teardown on the next quit. → Move the assignment to just after the config-dependent requires; source-index guard. |
| M2 [x] | G3/E | `macos/lib/file_watchers.lua:184` | When the config root holds any non-excluded `.toml` (the real tree does: `wrap_symbols.toml`), `hotstrings_dir` = config root and the recursive `hs.pathwatcher` watches `hammerspoon/config.toml`; every `save_prefs` (any menu toggle) self-triggers a full reload 0.5 s later. → Suppression hook bumped by `save_prefs`, or exclude `config.toml`. Related to H1's wrap_symbols trigger. |
| [x] M3 | G1/F | `macos/modules/keymap/layout_install.lua:275` | `69fa0a069` fixed `install_user` + both `rm` preludes but left `install_system`'s privileged `shell_cmd` on raw `'%s'`-in-single-quotes and `path_exists` on `%q` — an apostrophe in a relocated bundle path breaks the admin-shell install. Missed sibling of H1. → `text_utils.shell_quote` + AppleScript-level escape; widen the meta guard to a window scan. |
| M4 | G2/F | `macos/modules/keymap/expander.lua:491` | `617dc3a62`'s paste-ordering fence is local to `emit_tokens`; the terminator re-type in `try_terminator_expand` posts synchronously and **overtakes** a deferred second paste segment. → Expose the final `order_delay` and route the terminator re-type through the same fence. |
| M5 | G4/D | `macos/ui/tooltip/renderer.lua:571` | `tooltip.show_stacked` runs **synchronously inside the HID callback**: `resolve_anchor` does cross-process AX IPC + 2 eventtap create/destroy per preview keystroke. A beach-balling front app can time the tap out (→ G1). `tooltip_llm` already defers its renders for exactly this. → `hs.timer.doAfter(0, …)` the render; benchmark first. |
| M6 [x] | G5/G | `macos/ui/tooltip/tooltip_llm.lua:169` | The LLM tooltip's idle auto-dismiss timer fires `M.hide` but never `on_cancel`, so `engine.predictions_visible` stays true. First Tab/Enter afterwards types the **stale** prediction. → Fire the cancel contract from the idle timer like the mouse watcher does. |
| M7 [x] | G1/E | `macos/ui/tooltip/tooltip_hotstring.lua:145` | The per-render dismissal watcher (newest tap, head-inserted) runs **before** the persistent Escape trap and returns `false`, so Escape leaks to the app on every dismissal after the first show (Raycast open). → Add `KEYCODE_ESCAPE` to both dismissal watchers' ignored lists so the trap owns Escape. |
| [x] M8 | G2/A | `macos/modules/llm/api_remote.lua:253` | `get_active_entry` caches `entry.token = decrypt(...)` **unconditionally**; decrypt's failure sentinel is `""` (indistinguishable from a value). A locked/denied Keychain caches `""`, and the next `persist_api_entries` writes it back — **permanently destroying** the stored token. → Cache only on non-empty result (both here and the prewarm sibling). |
| M9 [x] | G2/A | `macos/modules/llm/api_remote.lua:643` | The bare-`pcall`-swallow shape the prior pass reported at one site exists in the other backends' `pcall(on_success)` too — a throw aborts silently, spinner cleaned only by the watchdog, nothing logged. → Shared `ApiCommon.protected_call` (xpcall + `Logger.error` + traceback). |
| M10 [x] | G2/F | `macos/modules/gestures/engine.lua:687` | `6033debde`'s confirmed finger-drop demotion resets `maxFingers` but not `peakN`; the peak-override (`cb8ca21d3`) then re-promotes the abandoned higher count at commit — the two fresh fixes fight. → Reset `peakN`/`peakNFirstSeen`/`peakNLastSeen` in the demotion branch. |
| M11 [x] | G2/F | `macos/ui/menu/menu_shortcuts.lua:483` | The script-control picker stores the `open_url`/`search_web` parameter under key `keyname` (`backspace`) but dispatch reads `"script__"..keyname` — so a configured AltGr+Backspace link **no-ops**. → Pass `"script__"..keyname` to `prompt_action_parameter`. |
| M12 [x] | G1/F | `macos/ui/menu/builder.lua:522` | The pause-gate `476bf2ecb` added to the Shortcuts master toggle was **not** applied to its sibling global « Tout activer » — clicking it during pause re-binds shortcut hotkeys live, breaking « pause = tout éteint ». → Gate the global-actions items like every other pause-sensitive item. |
| [x] M13 | G3/F | `macos/ui/download_window/init.lua:591` | `f239b252d` gave the shared window a `_session` identity and guarded **one** deferred-hide site; `M.complete`/`M.set_error`'s own 4 s auto-hide timers ignore `_session` and close a **newer** operation's window. → Capture `sid=_session` before arming; hide only if unchanged. |
| [x] M14 | G3/F | `macos/modules/llm/ollama_deps_checker.lua:222` | The deps-checker samples the session guard at bootstrap-**completion** time, not when it claimed the window, so its completion mutates/closes a `download_window` **another** operation owns. → Capture the session token at show/claim time and pass it to every write/hide. |
| M15 [x] | G3/C | `macos/modules/karabiner/watchers.lua:312` | `14ffd4488` made `terminate()` a live delayed event, but `read_layout_async`'s completion mutates shared `_layout_poll_handle`/`_pending`/`_watchdog` with **no identity check** — a terminated read's late `on_done` clobbers the **next** read's handle and cancels its watchdog. → Generation-aware completions. |
| M16 [x] | G3/C | `macos/tests/unit/meta/test_gc_retention.lua:46` | The `hs.task` GC guard is **file-granular** — one pin or one `waitUntilExit` anywhere greenlights every `hs.task.new` in the file (this is precisely why H3 shipped green). → Iterate each `hs.task.new` site and require a pin within its lexical window. |

*(M5 was also independently raised by the perf-g4 zone; M15 also by archaeo-recent;
the `check_task` medium rows from archaeo-prev/async-sweep are the same bug as H3.)*

---

## 4. LOW findings

33 distinct (5 of the 38 raw rows fold into a High/Medium: `logger.lua:325`→H1;
the three `llm_bridge.lua:501` rows are one bug; `script_control.lua:210` appears
twice). All confirmed via two lenses; each carries a repro + fix in the journal.

| G/cls | Location | Defect |
| --- | --- | --- |
| G2/F | `macos/lib/file_watchers.lua:153` | Git-operation reload-hold probes only `base_dir` — a `git pull` in the **config** repo (personal hotstrings tree) is unguarded. |
| G1/C | `macos/lib/file_watchers.lua:164` | The git/settle gate is evaluated at **schedule** time, not fire time — the `ui_restore` deferral window can still reload mid-pull. |
| G3/E | `macos/adapters/toml_cache.lua:191` | `toml_cache` writes `.lua` snapshots **inside** the watched `base_dir` — a runtime store fires a spurious full reload. |
| G3/C | `macos/modules/keymap/init.lua:704` | Synthetic Tab/Return echoes are consumed by `handle_llm_keys` as prediction-accept while predictions are visible → LLM text injected mid-expansion. |
| G4/D | `macos/modules/keymap/utils.lua:435` | `is_ignored_window` runs synchronous AX probes inside the keyDown tap on every cache miss and every 5 s TTL expiry. |
| G2/F | `macos/modules/keymap/input_sources.lua:708` | `upgrade_active_list` parses `<n>/<n>` but AppleScript returns a list (`1, /, 2`) → successful layout upgrades reported as failures. |
| G5/G | `macos/modules/keymap/llm_bridge.lua:501` | `would_fire`'s no-op returns a truthy 2nd value → the preview builds a **nil-text** row that crashes `render_stacked` and silently kills the whole preview stack. |
| G5/G | `macos/modules/keymap/llm_bridge.lua:524` | Stacked star rows label the validation key with a hard-coded `★` instead of `CoreState.magic_key` — wrong after the user customises the magic key. |
| G5/C | `macos/modules/keymap/llm_bridge.lua:345` | Preview offers rows during the rescan-suppression window in which the engine is hard-blocked; the trigger is then lost forever. |
| G5/G | `macos/modules/keymap/llm_bridge.lua:566` | Preview tooltip lifetime uses a coarse 3-way delay key while the engine gate uses the per-mapping precedence chain — they can diverge. |
| G5/F | `macos/modules/keymap/llm_bridge.lua:225` | Preview-toggle setters call dequeue-guarded `tooltip.hide()` → a stale preview survives the settings change (missed sibling). |
| G2/C | `macos/modules/llm/api_mlx_fetch.lua:238` | A superseded MLX request's un-cancelled 8 s timeout fires `on_fail` → an unguarded retry cancels the **live** request's transport. |
| G3/E | `macos/modules/shortcuts/script_control.lua:210` | Ollama warmup is not parked during pause: `pause_all` misses `api_ollama.stop_warmup`; `set_llm_model`/`set_active_profile` lack pause guards. |
| [x] G2/F | `macos/modules/llm/mlx_deps_checker.lua:538` | The MLX deps-checker fast-path hide is not session-owner-guarded → closes another operation's progress window (sibling of `f239b252d`). |
| G1/A | `macos/modules/llm/api_ollama.lua:429` | Non-streaming response path swallows callback throws under bare `pcall` — "green but no prediction", zero log evidence. |
| G3/C | `macos/modules/llm/api_mlx.lua:653` | MLX warmup POST timeout never bumps `_warmup_gen` and the response cancels the newer timeout's pre-guard → warmup POSTs pile up. |
| G1/A | `macos/modules/llm/prediction_engine.lua:989` | The canonical inactivity debounce timer is built at **require** time, before `install_runtime_error_capture` → its callback is permanently unguarded. |
| G3/C | `macos/modules/gestures/actions.lua:491` | `search_web` snapshots/restores the clipboard with no in-flight guard — the stale-snapshot class `7bf0cc3cd` fixed, left unguarded here. |
| G2/A | `macos/adapters/http_client.lua:126` | Completion callbacks run under bare `pcall` with no `Logger.error` (`:98/:126/:155/:178`) — a throw in the LLM response handler vanishes. Recorded-open, still true; the callers currently backstop it (see §6). |
| G2/E | `macos/adapters/text_sender.lua:112` | A throw between `Clipboard.write` and arming the restore timer permanently clobbers the clipboard. |
| G2/B | `macos/ui/menu/menu_state.lua:95` | Dead branch references an undefined global `enabled_ct` → custom-terminator enabled-state restore is a permanent no-op. |
| G1/B | `macos/ui/download_window/init.lua:127` | The `terminal` bridge builds `osascript` with double-quote-only escaping — a single quote in a path/model breaks it. |
| G1/B | `macos/ui/onboarding/init.lua:504` | `pickConfigDir` builds the AppleScript folder-picker seed with double-quote-only escaping (backslash unescaped). |
| G2/F | `macos/modules/gestures/engine.lua:626` | The sustained-peak override accepts two momentary spikes separated by a dip as a held peak. |
| G3/F | `macos/modules/shortcuts/script_control.lua:210` | `pause_all` stops MLX warmup but not Ollama's — the exact sibling `df063a2fa` fixed on the disable path. |
| G2/F | `macos/modules/shortcuts/actions/text.lua:202` | `do_transform`'s in-flight flag is released only by a 2 s timer → legit repeat transforms dropped; long selections re-open the race. |
| G4/F | `macos/modules/gestures/actions.lua:204` | `d40baf8dd`'s `space_wrap` check runs `hs.spaces` require + `allSpaces` + `focusedSpace` synchronously in the gesture frame callback. |
| G1/A | `macos/modules/llm/api_ollama.lua:165` | A config-derived log path is interpolated into `/bin/sh` with `string.format('%q')` at two sites the shell-quoting guard cannot see. |
| G4/D | `macos/lib/logger.lua:634` | Default log level is DEBUG, so the per-keystroke hot path does synchronous line-flushed file I/O (`fh:flush`) inside the eventtap. |
| G4/D | `macos/init.lua:403` | Boot spawns two synchronous subprocesses (`uname`, `sw_vers`) via `backend_detector.effective_backend()` before `keymap.start()`, uncached. |
| G4/D | `macos/modules/keymap/init.lua:708` | The interceptor contract makes each interceptor re-fetch `keyCode`/`flags`/`chars` from the event, duplicating ObjC accessors already fetched. |
| G4/D | `macos/modules/keymap/llm_bridge.lua:436` | `update_preview` builds `star_buf` unconditionally before the star-bucket check; `onKeyDownRaw` reads the wall clock twice per keystroke. |
| G3/F | `macos/tests/unit/meta/test_gc_retention.lua:84` | The `lfs` walk scans only `{adapters,lib,modules,ui}`, skipping root `init.lua`; only the shell fallback scans all → coverage depends on which path runs. |

---

## 5. PROJECT_MEMORY watch-list status

Every macOS-relevant entry was re-verified against current source, located by
symbol. All are **fix-in-place** except two doc-drifts (below); no watch-list
entry has regressed at its **documented** site. The regressions this audit found
(H2, H3) are the *same classes* recurring at **new** sites, which is exactly the
dominant failure shape (`[[project_ahk_invariant_incomplete_application]]`).

**Doc-drifted (fix intact, entry prose now stale — update the memory):**
- `[[project_hs_partial_fixes_and_false_green_tests]]` — **all three cited partial
  fixes are now complete.** (1) Deferred log purge: `logger.lua:399-463
  _purge_old_logs` is subprocess-free (`os.remove` + `hs.fs.attributes`) and purges
  the `errors_` sink via a dedicated pattern (`:441`); `test_logger_deferred_purge.lua`
  now asserts `#exec_log == 0`. (2) Crash-report modal: `crash_reporter.lua:311-325`
  uses non-blocking `Notifications.notify`; `test_crash_reporter_no_modal.lua` bans
  `blockAlert`. (3) MLX warmup gate: `prediction_engine.set_llm_enabled(false)`
  (`:206-228`) now calls `WarmupController.stop()` + `api_mlx.stop_warmup()` +
  `api_ollama.stop_warmup()`. The entry should be rewritten to "resolved; the
  assert-the-guarantee lesson stands."
- `[[project_tooltip_shared_style]]` — the stacked-panel **mechanism** prose is
  stale: `renderer.lua:386-415 _build_stacked_elements` now uses a per-row
  background + corner-cap (4-slot block per row, `_row_corner_plan` at `:424`), not
  the "one rounded panel" the entry describes. Both **invariants still hold** —
  macOS reads the `_hs` alphas (`ui/tooltip/config.lua:294,298`) and there is
  deliberately no `action="clip"` (`renderer.lua:373-384`). Update the prose; the
  guarantee is intact.

**Class regressed at a NEW site (documented site still fixed):**
- `[[project_lua_closure_before_local_nil_global]]` — the documented site
  (`api_ollama.lua:571-575`) is fix-in-place, but the **class regressed** at
  `keymap/init.lua:715` via `227aec26d` (**H2**).
- The `hs.task` GC-pin widening (`71f0c0ec3`) is fix-in-place, but its guard is
  **file-granular**, so `check_task` (**H3**) ships unpinned and green (**M16**).

**Class found at an un-migrated sibling:**
- Shell-quoting (`69fa0a069`) — the canonical helper itself is broken (**H1**);
  `install_system`/`path_exists` (M3), `api_ollama.lua:165`, `download_window:127`,
  `onboarding:504` are un-migrated siblings.
- Window-ownership session guard (`f239b252d`/`65e747a8b`) — M13, M14,
  `mlx_deps_checker.lua:538` are un-guarded deferred-hide siblings.
- Pause-gating (`476bf2ecb`) — global « Tout activer » (M12) and Ollama warmup
  (`script_control.lua:210`) are un-gated siblings.

**Open item confirmed still open:**
- `[[project_hs_audit_open_labels_are_stale]]`'s one concrete flag —
  `adapters/http_client.lua:126` invokes the completion callback under a bare
  `pcall` with no `Logger.error` — is **still true** (LOW row; the throw is silent,
  though callers currently backstop it, §6).

**Fix-in-place (all spot-verified this pass):**
`[[project_hs_sentinel_key_misfire]]`, `[[project_hs_purity_ratchet_counts_comments]]`
(`LUA_HS_BASELINE=969`/`LUA_IO_OS_BASELINE=77`, read live),
`[[errors_only_log_sink]]`, `[[project_hs_audit_round4_2026_07_21]]` (`would_fire`
still the single matcher; `star_validated`; `not mapping.auto`),
`[[project_hotstring_delay_architecture]]`, `[[project_hotstring_engine_internals]]`,
`[[project_hs_perf_profilers_and_case_conform]]` (profilers wired; `CACHE_VERSION=2`;
Escape trap lazy; menubar `_menu_dirty`), `[[project_hs_script_quit_kills_karabiner]]`
(+ reload guard), `[[project_hs_onboarding_config_schema]]`,
`[[project_keymap_architecture]]` (DEFAULT_STATE single-source),
`[[project_hs_synthetic_injection_choke_point]]`, `[[project_suspend_pause_invariant]]`,
`[[project_macos_llm_runtime_enable_gate]]`, `[[project_macos_eventtap_no_blocking]]`,
`[[project_macos_script_control_tap_lifecycle]]`,
`[[project_shifted_comma_case_variants]]` (macOS `UPPER_TRIGGERS`),
`[[project_hs_timer_callback_errors_invisible]]` (capture at `init.lua:198`;
surviving gaps are the pre-`:198` timer `prediction_engine.lua:989` (LOW) and
eventtaps/http by design), `[[project_profile_label_placeholder_convention]]`,
`[[project_hs_adapter_contract_violations]]` (all 4 facts),
`[[project_lua_nil_and_expr_is_nil]]`, `[[project_shared_tree_layout]]`,
`[[project_macos_initlua_no_compile_coverage]]`, `[[project_hs_fs_dir_drops_state]]`,
`[[project_healthcheck_stale_api]]`, `[[project_macos_split_module_stub_reload]]`,
`[[project_macos_reload_during_git_pull]]` (`ca8e70c11`; residual gaps are the two
LOW `file_watchers` rows), `[[project_init_json_decode_of_toml]]`,
`[[project_macos_startup_winfilter_cost]]`, `[[project_macos_lib_namespace_shims]]`,
`[[project_locale_parity_test]]`, `[[project_metrics_ui_live_foreground_contract]]`,
`[[project_gestures_reversal_detection]]`, `[[project_gestures_startup_design]]`.

**Not-verifiable read-only:** `[[project_touchdevice_dormancy_is_kernel]]` — the
code respects the kernel gate (`gestures/init.lua:191` recreates on wake), but the
kernel-gate assertion itself needs a live Mac.

**Newly noted (not previously recorded):** `modules/llm/init.lua`'s setters
(`set_runtime_llm_enabled`/`set_active_profile`/`set_backend`) breach rule 5.5
(setters-must-log) — see §8.

---

## 6. Refuted claims (held to the finding's proof bar)

Eight candidate findings were **refuted** with cited counter-evidence. Do not
re-raise without new evidence.

1. **Menu config/theme watchers not stopped at shutdown** — code fact true, but
   the failure is unreachable: HS runs `shutdownCallback` and all watcher
   callbacks on one main thread with no event-loop pump during teardown, and
   `hs.reload` destroys the dying state's timers/watchers atomically. Cosmetic
   hygiene nit at most.
2. **`run_osascript_isolated`/`enable_and_select_source` block the runloop** —
   true that they use synchronous `hs.execute`, but these are **user-initiated
   menu-click handlers**, which `[[project_updater_nonblocking_http]]` explicitly
   keeps synchronous; the one eventtap-hot-path caller was already deferred. The
   proposed fix (route through "async `shell_runner`") rests on a false premise —
   `shell_runner.exec` is synchronous.
3. **`perform_text_replacement` rewrites the buffer when `emit_action` threw**
   (raised twice) — the divergence branch is real code but **unreachable**: no
   production caller makes `emit_action` raise (static repls are well-formed; LLM
   completions flow through `emit_text` whose utf8 ops are pcall-guarded and whose
   `keyStrokes`/pasteboard calls return status, not raise).
   `test_expander_notify_synthetic_pcall.lua` pins `buffer_action`-runs as
   intended.
4. **Ignored-window early-exit makes every `is_ignored` path dead code** —
   structurally accurate but violates no honored contract (the public API means
   "full bypass", which the early-exit honors); the only ever-ignored window is the
   HS console. Already adjudicated refuted by the round-2 pass.
5. **`stop_input_source_watcher` never terminates the in-flight read** — real
   asymmetry, but the only route is `M.kill` on genuine quit, after which the VM is
   torn down; the fast `defaults read` self-releases its pin. Fully absorbed.
6. **`f58441165` missed the shortcut-flush sibling** — the shortcut flush is
   structurally identical to the mouse/scroll flushes (early-return, not a
   typing-buffer event); the inter-word gap is preserved as the next buffer's
   `pause_before_ms`. Deliberate design, not a defect.
7. **`http_client` bare-pcall swallow is a live silent-failure** — the adapter
   does discard the error, **but** every real caller (`api_ollama:429`,
   `api_remote:643`, `api_mlx_inference`) wraps its own body in a pcall with
   `Logger.error` on each malformed-body branch, so the described mode cannot
   occur silently today. Kept as the LOW defense-in-depth row, downgraded from the
   medium G2 claim.
8. *(The critic's own "phantom file" claim — that `terminators_catalogue.lua`
   doesn't exist — was itself refuted: the file is real, and line 23 confirms
   `★ consume=true`. A reminder that the verifier is a hypothesis too.)*

---

## 7. Performance (G4) — all deduced, none measured

No Hammerspoon runtime logs exist on this machine, so **every figure is deduced
from the code**; treat each as a suspicion to bench with the `perf-profiling`
skill, not a measurement. Rejected-and-not-re-proposed: tooltip window reuse,
moving the LLM Escape trap to init, `hs.window.filter` at boot/first-keystroke,
versioned generated caches, weakening the purity ratchet, end-char queue caps.

- **`renderer.lua:571` (M5, MEDIUM)** — the tooltip preview does cross-process AX
  IPC + 2 eventtap create/destroy **synchronously in the HID callback** on every
  preview-show keystroke. This is both a latency exposure and, on a slow AX app, a
  tap-timeout (G1) risk. Defer the render like `tooltip_llm` already does.
- **`logger.lua:634` (LOW)** — default level DEBUG means the per-keystroke path
  does synchronous line-flushed file I/O (`fh:flush`) inside the eventtap. Consider
  raising the default to INFO or buffering flushes.
- **`init.lua:403` (LOW)** — boot spawns two synchronous subprocesses (`uname`,
  `sw_vers`) before `keymap.start()`; cache `effective_backend()`.
- **`keymap/init.lua:708` (LOW)** — the interceptor contract re-fetches
  `keyCode`/`flags`/`chars` per interceptor, duplicating ObjC accessors already
  read; pass the fetched values in.
- **`llm_bridge.lua:436` (LOW)** — `update_preview` builds `star_buf`
  unconditionally before the star-bucket check; `onKeyDownRaw` reads the wall clock
  twice per keystroke.
- **`utils.lua:435` (LOW)** — `is_ignored_window` runs synchronous AX probes in the
  keyDown tap on every cache miss / 5 s TTL expiry.

**Un-benched exposures the perf pass named but did not measure** (single
non-iterated pass; keystroke-path only): `hs.pasteboard.readAllData` in the paste
branch of the keyDown tap; the gesture frame callback; the mouse-tap path
(`system_mouse`); the keylogger aggregator ingest path. None has a G4 verdict.

---

## 8. Coverage register

**Zones audited and their loop-until-dry status** (§9 expands this):

| Zone | Model | Dry? | Confirmed |
| --- | --- | --- | --- |
| boot-shutdown | Fable 5 | **not dry** (R2 found 3) | 8 |
| keymap-hotpath | Fable 5 | **not dry** (R2 found 4) | 9 |
| tooltip-parity | Fable 5 | **not dry** (R2 found 4) | 9 |
| llm-races | Fable 5 | **not dry** (R2 found 5) | 10 |
| karabiner | Opus | dry at pass 2 | 1 |
| gestures-shortcuts | Opus | **not dry** (R2 found 1) | 3 |
| keylogger-dynhs | Opus | **not dry** (R2 found 1) | 2 |
| adapters | Opus | dry at pass 2 | 2 |
| lib | Opus | dry at pass 2 | 1 |
| ui-menu | Opus | **not dry** (R2 found 1) | 3 |
| ui-menu-llm | Opus | dry at pass 2 | 1 |
| ui-windows | Opus | **not dry** (R2 found 1) | 3 |
| archaeo-recent / archaeo-prev | Fable 5 | single pass by design | 9 |
| async-sweep | Opus | dry at pass 2 | 2 |
| pause-matrix | Opus | dry at pass 2 | 0 (+1 hypothesis) |
| perf-g4 | Opus | single pass by design | 5 |
| test-quality | Opus | single pass by design | 2 |

**Coverage GAPS the completeness critic verified (silence ≠ covered):**

- **~25 non-test modules (~6,900 lines) received no coverage verdict at all** —
  never opened. Largest: `_generated/features_manifest.lua` (714),
  `modules/llm/init.lua` (706), `ui/menu/menu_metrics.lua` (674),
  `ui/menu/menu_hotstrings_custom.lua` (601), `modules/keylogger/aggregator/events.lua`
  (501), `ui/menu/menu_llm/models_manager.lua` (494 dispatcher),
  `lib/manifest_menu.lua` (439), `modules/keylogger/export.lua` (401),
  `modules/shortcuts/actions/system_mouse.lua` (374),
  `modules/keylogger/rotation.lua`, `aggregator/core.lua`, `lib/layout.lua`,
  the `ui/wpm/*` menubar, `lib/timings.lua`, `dynamic_hotstrings/init.lua`, the
  `touchdevice` vendor code. **Prioritise the four >490-line files and the
  keylogger write/export path before declaring the driver audited.**
- **`modules/llm/init.lua`** — the LLM state owner the whole llm-races zone reasons
  about — was never given a verdict, and on inspection **breaches rule 5.5**
  (`set_runtime_llm_enabled`/`set_active_profile`/`set_backend` don't log their new
  value). This is the exact class the audit polices elsewhere.
- **The keylogger cross-device export/sync path** (`export.lua`, `rotation.lua`,
  `aggregator/{events,core,state}.lua`) was never read. The PII invariant §H5/§H9
  care about stops at the expander choke point; the layer that actually moves
  keystroke data across devices into SQLite and the LLM bridge is **unchecked** for
  the same guarantee or for SQL handling of untrusted foreign-device files.
- **Adapters cleared largely by grep, not by reading**: 8 un-read
  (`app_launcher`, `crypto`, `mouse_control`, `network_info`, `notifier`,
  `tray_menu`, `window_info`, `window_manager`). `mouse_control` + the never-read
  `system_mouse.lua` leave the synthetic-mouse/click-race surface without a deep
  verdict.
- **Explicitly deferred cells:** `ui_builder.lua` (the shared webview factory
  behind every UI window — focus timers, asset inlining), the 3-site teardown
  parity re-derivation (pause-matrix ran out of budget), and
  `features_manifest.lua` consumer-parity/staleness.
- **Cross-cutting sweeps the method implies but did not run to completion:** a
  rule-5.5 setter-logging sweep (would have caught `llm/init.lua`), a rule-4.4
  French-log-string sweep, the raw-gsub-replacement escaping sweep, and an
  exhaustive eventtap synchronous call-graph sweep (async-sweep's was partial).
- **Inference not confirmed against a real Mac** (keep medium-confidence until
  verified): the launcher SIGTERM-vs-`shutdownCallback` 4th quit sibling; the
  `input_sources` AppleScript list-rendering (LOW `:708`); the LLM tooltip
  join-space + accent-normalising overlap; the pause-matrix "double Karabiner
  regenerate on resume" hypothesis. H9 and H10 are also deduced and want a real-Mac
  repro.

---

## 9. Loop-until-dry status — the debt

**8 of 18 zones did not reach dry** (a second full finder pass still produced
confirmed findings): boot-shutdown, keymap-hotpath, tooltip-parity, llm-races,
gestures-shortcuts, keylogger-dynhs, ui-menu, ui-windows. Per
`[[project_hs_audit_2026_07_21]]` ("les trois zones ainsi marquées ont produit 18
findings confirmés à la passe suivante"), a **not-dry** mark is a promise that a
third pass would find more — especially in `llm_bridge.lua`/tooltip (G5) and the
LLM race surface. The four zones marked "single pass by design" (the two
archaeology zones, perf-g4, test-quality) never ran a round 2 and are dry only in
the trivial sense.

**Recommended next actions, in order:** (1) fix H1 and H4/H5 first — a re-opened
injection and two silent leaks; (2) fix the three fresh regressions H2/H3/H8 while
their commits are recent; (3) run a targeted pass over the ~25 never-opened
modules, starting with the keylogger export path and `llm/init.lua`; (4) take
`llm_bridge.lua`/tooltip-parity and llm-races to a genuine third pass; (5) verify
the real-Mac-dependent findings (H9, H10, the launcher SIGTERM) on hardware.

Every fix must ship with the regression test named in its finding, encoding the
**root cause** behaviourally (a presence-grep is a false green — H2 and H3 both
hid behind exactly that), per `[[feedback_regression_tests]]`.
