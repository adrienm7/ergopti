# Audit Hammerspoon (macOS) — robustness, races & silent failures — 2026-06-19

> Adversarial audit of the **Hammerspoon / macOS** driver of Ergopti+
> (`static/ergopti_plus/macos/` + shared Lua `static/ergopti_plus/_shared/lua/`).
> Goal: prove that **no user action, in any driver state**
> (normal / suspend / pause / layout-switch / reload / quit / LLM cold-start /
> first-launch) can raise an unhandled Lua error, drop a required output, race, or
> introduce perceptible lag — and where it can, give the **root cause + fix + a
> regression test that encodes the root cause**.
>
> **Method.** A multi-agent workflow (84 agents) ran four phases: (1) watch-list
> verification of the prior 37-bug audit + the `docs/PROJECT_MEMORY.md` foot-guns,
> (2) module-by-module + end-to-end fresh hunting across the bug-class catalog
> A–E, (3) **adversarial verification** of every candidate (refute-by-default, the
> verifier re-reads the cited code itself), (4) a completeness critic driving a
> targeted follow-up round. **46 candidates → 27 confirmed, 3 contested, 16
> refuted.** Each confirmed finding below was additionally re-read by hand for this
> report. No source file was modified by this audit — this document is the
> deliverable (the four headline findings have ready-to-apply fixes + tests).

---

## 0. Executive summary

The prior 37-bug audit landed well: **the synthetic-injection choke point was
built** (`keymap.inject_dynamic` → `expander.perform_text_replacement`), and
A1–A7, CLIP, B1, C1–C5, D1–D4, E1–E3, F1, G1–G2, H2–H5 plus the
`PROJECT_MEMORY` foot-guns are **fixed-in-place** (see §4). The `triggerabcd`
text-corruption class is closed on every live injector.

The remaining risk has shifted to **peripheral surfaces the prior audit never
reached**: the menubar/update/UI layer, boot-time blocking I/O, the WPM widget,
`hs.settings` integrity, and one destructive keyboard-event misfire. The two
critical findings are both **user-facing and reachable today**:

| Sev | Count | Headline |
|---|---|---|
| **Critical** | 2 | Physical F13/F14/F15 keypress fires pause/reload/**quit** with no modifier guard (`SC-F13`); self-update install callback aborts on line 1 via a closure-binds-nil-global `task` — update permanently dead (`SU-1`) |
| **High** | 6 | Phone/SSN/IBAN prefixes never register at boot; MLX stream has no idle/hard bound → frozen forever + blocked backend; genuine Cmd+Q uses a respawn-prone KE kill; N synchronous Keychain shell-outs block boot before the tap exists; crash reporter is unreachable dead code; a wrong-typed `hs.settings` modifier value silently blanks the AI submenu |
| **Medium** | 7 | paste-counter omitted from the stuck-reset guard; kc_bridge reader still truncates lossy; `notify_synthetic` un-gated + queue not cleared on first enable; LLM-after-hotstring chain armed ~24 h when preview off; gesture-enable flag conflated with pause; WPM widget keeps polling under pause; `script_quit` leaks the MLX server + orphans |
| **Low** | 5 | C6 synth-queue poison only time-mitigated; LLM warmup hits backend under pause; layout-settle magic number; 2 s synchronous `defaults read` poll; WPM position read not type-guarded |
| **Info / latent** | 3 | LLM `apply_prediction` still open-codes the injection bookkeeping; text/gesture injectors bypass the trackers (safe only by accident of which keys they emit); pause-invariant test asserts only the boolean |
| **Contested** | 2 | keylogger ingest id-gap (duplicate-rows claim refuted); update restore-rename hardening |

**Most fragile zones (ranked):** (1) `ui/menu/menu_about.lua` self-update install
path; (2) `modules/shortcuts/script_control.lua` sentinel dispatch; (3) the
`hs.settings` → menu-builder read paths (`ui/menu/menu_llm/*`, `ui/wpm/*`); (4)
LLM streaming lifecycle (`api_mlx.lua`); (5) boot-time blocking I/O
(`modules/llm/init.lua`, `modules/karabiner/watchers.lua`).

**Honest verdict:** the *typing engine* is hardened — the corruption/desync class
the prior audit chased is genuinely closed and well-tested. The driver is **not**
yet blindé at its edges: a single physical function key can quit it, the
self-update feature is dead-on-arrival, and several surfaces crash silently on a
corrupt setting because errors thrown inside `hs.task`/`hs.timer`/`hs.eventtap`
callbacks never reach the file logger (bug-class [A]). Fixing the 2 criticals and
6 highs would close every reachable G1/G2 hole found.

A recurring structural theme: **the closure-binds-nil-global foot-gun
(`project_lua_closure_before_local_nil_global`) recurred verbatim in a new place**
(`SU-1`), and the **errors-swallowed-to-Console mechanism**
(`project_hs_timer_callback_errors_invisible`) is why 9 of the confirmed findings
are silent. These two classes deserve a permanent meta-test (see §6.4).

---

## 1. Critical findings

### F-CRIT-1 — Physical F13/F14/F15 keypress fires `script_pause` / `script_reload` / `script_quit` with no modifier guard

- **Severity:** Critical · **Confidence:** confirmed (read by hand) · **Guarantees:** G1, G2
- **Files:** [script_control.lua:263-301](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L263-L301), [keycodes/init.lua:37-51](static/ergopti_plus/_shared/lua/keycodes/init.lua#L37-L51), [generator.lua](static/ergopti_plus/macos/modules/karabiner/generator.lua), [keymap/init.lua:576-601](static/ergopti_plus/macos/modules/keymap/init.lua#L576-L601)
- **Repro (initial state → actions):** Any keyboard with physical F13/F14/F15 keys (Apple full-size extended keyboard, most TKL/full-size mechanical boards). Driver running, normal state. Press **F15** once → `script_quit` fires: Hammerspoon exits via `os.exit(0)` **and** tears down Karabiner-Elements, leaving the keyboard un-remapped and the driver gone. F14 → `hs.reload()`. F13 → pause toggle. No modifier required; the event is consumed (`return true`).
- **Root cause + why silent:** `handle_key` checks the three sentinel keycodes **first and unconditionally** ([script_control.lua:268-282](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L268-L282), each `return true`); the `is_right_cmd_only(e)` modifier guard is only consulted on the *fallback* branch at [line 285](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L285). The sentinels are the **real macOS physical keycodes** — `F13_KARABINER_RETURN = 105`, `F14_KARABINER_BACKSPACE = 107`, `F15_KARABINER_ESCAPE = 113` ([keycodes/init.lua:40/45/51](static/ergopti_plus/_shared/lua/keycodes/init.lua#L40-L51)). The design assumes these codes only ever arrive as Karabiner rule *outputs* (`right_command+key → f13`), but **no KE rule intercepts an incoming physical f13/f14/f15 press**, and the keymap tap explicitly fast-exits (`return false`, pass-through) on 105/107/113 ([keymap/init.lua:576-601](static/ergopti_plus/macos/modules/keymap/init.lua#L576-L601)) — so a real F-key press reaches `script_control` intact and matches the unconditional branch. **Silent:** no error is raised; the wrong action simply fires and the event is consumed. The dispatch is even logged as a normal "Alt+Escape" activation, masquerading as an intentional shortcut.
- **Proposed fix:** Gate the sentinel branch on a sentinel *context*, not just the keycode. Minimal safe change: move the `if not is_right_cmd_only(e) then return false end` filter **above** the sentinel checks so a bare physical F13/F14/F15 (no right-hand modifier flag set by KE) is passed through instead of dispatched. Stronger: also verify the event carries the KE-set held-modifier flag / is not a hardware-origin press (`eventSourceStateID`). Add named constants distinguishing physical-vs-sentinel.
- **Regression test (root cause, behavioral):** `tests/unit/modules/shortcuts/test_script_control.lua` — drive the tap callback captured by the `hs` stub (or expose `handle_key`). Feed a fabricated keyDown with `getKeyCode()==113` (F15) and `getFlags()=={}` (no cmd); spy `GestActions.execute_single`/`hs.reload`/`os.exit`. Assert the action is **not** dispatched and the event passes through (`return false`). A second case with `code==113` **and** right-command-only flags must still dispatch. Fails today (bare F15 quits).

### F-CRIT-2 — Self-update install callback aborts on its first line (closure binds nil-global `task`) — update permanently dead

- **Severity:** Critical · **Confidence:** confirmed (read by hand + verified Lua semantics) · **Guarantees:** G1, G2
- **Files:** [menu_about.lua:208-262](static/ergopti_plus/macos/ui/menu/menu_about.lua#L208-L262)
- **Repro:** Bundled build, a newer GitHub release exists. Menubar → About/Update → "Update now". `one_click_update` downloads the zip (the F10-fixed leg works), then `replace_and_reload` launches `local task = hs.task.new("/usr/bin/unzip", function(exit_code,_,stderr) M._active_tasks[task] = nil … end, …)`. unzip succeeds, HS invokes the callback, and its **very first statement** `M._active_tasks[task] = nil` ([menu_about.lua:209](static/ergopti_plus/macos/ui/menu/menu_about.lua#L209)) raises `table index is nil`. No install step runs. The `.app` is never replaced (non-destructive), but `Updater._update_state` stays `"installing"` forever, the menu item is stuck disabled at "Installing…", and one-click update is dead for the session.
- **Root cause + why silent:** In Lua the scope of `local task` begins **after** the full `local task = …` statement; the function literal on the RHS is compiled where `task` is not yet visible, so the closure binds the **nil global** `_G.task`, not the local. Writing a nil key (`t[nil] = …`) always raises `table index is nil`. This is the **identical class** as the documented `project_lua_closure_before_local_nil_global` foot-gun (the api_ollama `os.remove(tmp_path)` bug) and the F10 `download_to_file` fix — recurring here in the still-unfixed install callback. The inline comment even *wrongly* asserts "task captured by closure". **Silent:** Hammerspoon runs `hs.task` completion callbacks inside its own `pcall` and reports raised errors only to the **HS Console — never `lib.logger` / the on-disk log** (`project_hs_timer_callback_errors_invisible`). The error fires on line 1, so not even a `START`-without-`SUCCESS` pair appears; the only persistent symptom is a menu item stuck at "Installing…".
- **Proposed fix:** Forward-declare the handle so the closure captures a real upvalue:
  ```lua
  local unzip_task
  unzip_task = hs.task.new("/usr/bin/unzip", function(exit_code, _, stderr)
      if unzip_task then M._active_tasks[unzip_task] = nil end
      …
  end, { "-o", zip_path, "-d", tmp_dir })
  M._active_tasks[unzip_task] = true
  unzip_task:start()
  ```
  Guard the clear with `if unzip_task then` so a nil key can never be written. Additionally wrap the callback body in a `pcall` that, on failure, logs `Logger.error` and resets `Updater.set_update_state("idle")` + `update_menu_fn()` so any future raise can never leave the state machine stuck (fail-fast).
- **Regression test (root cause):** `tests/unit/ui/test_menu_about_install_task_capture.lua` — `load_with_stubs` overriding `hs.task.new` to capture `(cmd, callback, args)` and return a fake task; stub `hs.fs.attributes(new_app)`→truthy, `os.rename`→true, download→200. Drive into the install leg, then **invoke the captured callback with `(0,"","")`** and `assert_true` it returns without raising and `Updater.get_update_state()` has left `"installing"`. Add a source-level guard mirroring the F10 test: assert the regex `local%s+%w+%s*=%s*hs%.task%.new` does **not** appear (the task local must be forward-declared above, captured as an upvalue). Fails before, passes after — and can never silently regress.

---

## 2. High findings

### F-HIGH-1 — Phone/SSN/IBAN prefix auto-expansions never register on a default boot

- **Severity:** High · **Confidence:** confirmed · **Guarantee:** G2
- **Files:** [dynamic_hotstrings/init.lua](static/ergopti_plus/macos/modules/dynamic_hotstrings/init.lua) (M.start order), [rules_engine.lua:148-149/247/258/299-303](static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua#L148-L149), [registry.lua:1060-1106](static/ergopti_plus/macos/modules/keymap/registry.lua#L1060-L1106), [menu_state.lua:279-281](static/ergopti_plus/macos/ui/menu/menu_state.lua#L279-L281)
- **Repro:** Fresh install, default state (personal info + `dynamichotstrings` group enabled). Set `phone_number=0612345678`. Boot. Type `0612` (a registered phone prefix). **Expected:** auto-expands to the full number. **Actual:** nothing; the menu shows `phoneprefixes`/`ssnprefixes`/`ibanprefixes` count = 0. The `@`-tag personal info and date suffix rules still work (they are interceptor-based), making the partial failure easy to overlook.
- **Root cause + why silent:** `dynamic_hotstrings.M.start()` calls `RulesEngine.inject_data()` **before** `RulesEngine.start()`. `inject_data` → `register_prefix_entries`, which guards `if not _km … then return` — but `_km` is still `nil` (assigned only inside `RulesEngine.start`). So that registration is a silent no-op. `RulesEngine.start` then only stores `register_prefix_entries` as a `post_load_hook` and **never calls it directly**. The hook is invoked only by `Registry.enable_group`, but `register_lua_group` already sets `enabled=true`, and `enable_group` early-returns when already enabled (the documented ~2 s round-trip perf no-op, [menu_state.lua:279-281](static/ergopti_plus/macos/ui/menu/menu_state.lua#L279-L281)). Both paths to `register_prefix_entries` are no-ops → prefixes never register. **Silent:** two legitimate-looking early returns, no `WARN`/`ERROR`, no `START`/`SUCCESS` pair to leave an orphaned log line; no test covers prefix registration.
- **Proposed fix:** In `rules_engine.M.start()`, after `_km = keymap_module` and `register_lua_group(...)`, call `register_prefix_entries()` directly (it reads the `_personal_data` that `inject_data` already set). Keep the `post_load_hook` for the disable/re-enable cycle. Add a fail-fast `WARN` in `register_prefix_entries` when `_km` is nil but `_personal_data` is present, so the silent path becomes visible.
- **Regression test:** `tests/unit/modules/dynamic_hotstrings/test_prefix_registration_at_start.lua` — fake `_km` recording `add`/`register_lua_group`/`set_post_load_hook`, `is_section_enabled`→true. Drive the production boot order: `inject_data({phone_number="0612345678"}, "*")` then `start(fake_km)` **without** `enable_group`. Assert `fake_km.add` was called with trigger `"0612"` (+ the `+33`/4-digit variants). Encodes the root cause: registration must not depend on the hook firing. Fails today.

### F-HIGH-2 — MLX streaming has no `--max-time` and the idle watchdog is cancelled after the first token → frozen forever + blocked backend

- **Severity:** High · **Confidence:** confirmed · **Guarantees:** G1, G2, G3
- **Files:** [api_mlx.lua:1441-1592](static/ergopti_plus/macos/modules/llm/api_mlx.lua#L1441-L1592), [streaming_handler.lua:444-456](static/ergopti_plus/macos/modules/llm/streaming_handler.lua#L444-L456)
- **Repro:** `backend=mlx`, `llm_streaming=true` (default). A prediction request spawns `curl` with only `--connect-timeout`, **no `--max-time`** ([api_mlx.lua:1565-1571](static/ergopti_plus/macos/modules/llm/api_mlx.lua#L1565-L1571)). The MLX server emits one SSE delta then stalls (known mlx-lm GPU-stream hiccup during hot-swap / reasoning-model deadlock). `on_chunk` fires once and, being the first chunk, **cancels `_active_stream_timeout`** (the only hard bound, [api_mlx.lua:1441-1447](static/ergopti_plus/macos/modules/llm/api_mlx.lua#L1441-L1447)) and never re-arms it. `curl` now blocks indefinitely; `on_done` never runs, `_active_stream_task` is never cleared, the curl process leaks. Because the MLX server is single-request, the held-open socket **blocks every subsequent prediction** until `hs.reload`.
- **Root cause + why silent:** Asymmetry between backends — Ollama bounds curl with `--max-time STREAM_MAX_TIME_SEC` ([api_ollama.lua:638](static/ergopti_plus/macos/modules/llm/api_ollama.lua#L638)) so curl always exits and `on_done`→`on_fail` fires; MLX relies *solely* on the in-process watchdog, which is connect-phase only (cancelled on first chunk, never replaced by an idle/total bound). **Silent:** `on_done` never executes → no log, no `on_fail`, no `WARN`. The `streaming_handler` watchdog (12 s) only repaints the tooltip with partial results and emits a benign "Timeout partiel" WARNING — it does **not** terminate the task or call `on_fail`, masking the leaked curl + blocked backend.
- **Proposed fix:** (1) Mirror Ollama: add `"--max-time", tostring(STREAM_HARD_TIMEOUT_SEC)` to the MLX curl argv (a named ceiling). (2) Convert `_active_stream_timeout` into an **idle** watchdog: instead of permanently cancelling on the first chunk, **re-arm** it (cancel + `TimerScheduler.after(STREAM_HARD_TIMEOUT_SEC, …)`) inside `on_chunk` after each token, and in its callback terminate the task + call `on_fail`. Keep the generation guard.
- **Regression test:** `tests/unit/modules/llm/test_mlx_stream_idle_timeout.lua` — stub `ShellRunner.spawn` to record argv + capture `on_done`/`on_chunk`; stub `TimerScheduler.after`. Assert (a) the curl argv contains `--max-time` (fails today); (b) after one `on_chunk(token)` a fresh hard-timeout timer is re-armed (fails today — it is cancelled, not re-armed); (c) firing that timer terminates `_active_stream_task` and calls `on_fail` exactly once.

### F-HIGH-3 — Genuine Cmd+Q quit tears KE down with the respawn-prone `KILL_FAST_CMD` and ignores `is_hs_owned_bridge`

- **Severity:** High · **Confidence:** confirmed · **Guarantee:** G1
- **Files:** [init.lua:963-973](static/ergopti_plus/macos/init.lua#L963-L973), [ke_lifecycle.lua:67-104](static/ergopti_plus/macos/modules/karabiner/ke_lifecycle.lua#L67-L104), [karabiner/init.lua:764-777](static/ergopti_plus/macos/modules/karabiner/init.lua#L764-L777)
- **Repro:** KE enabled (HS owns the bridge). Quit HS normally (Cmd+Q / menubar Quit). `hs.shutdownCallback` with `is_reloading()==false` runs **only** `hs.execute(KILL_FAST_CMD)` ([init.lua:969](static/ergopti_plus/macos/init.lua#L969)). `KILL_FAST_CMD` is a bare `pkill` with **no `launchctl bootout`**, so launchd `KeepAlive` respawns the bridge ~1 s later and the keyboard stays remapped after HS exits. It also runs unconditionally (no `is_hs_owned_bridge()` check), so a **user-managed** KE is pkilled too.
- **Root cause + why silent:** The shutdown path inlines `KILL_FAST_CMD` (the lightweight *pre-deploy* kill) instead of `karabiner.kill()` (which does `launchctl bootout` first, respects ownership). Per `project_hs_script_quit_kills_karabiner`, a bare pkill is respawned by launchd — which is exactly why `script_quit` uses `karabiner.kill()`; the genuine-quit branch never got the same treatment. **Silent:** the bridge respawns after HS has exited (no logger/VM available); the callback logs success.
- **Proposed fix:** On the genuine-quit branch call `karabiner.kill()` (the `KILL_CMD` bootout path; respects `is_hs_owned_bridge`; synchronous). Leave the reload branch untouched. `karabiner` is a captured upvalue at [init.lua:218](static/ergopti_plus/macos/init.lua#L218).
- **Regression test:** `tests/unit/.../test_shutdown_quit_kills_karabiner_robustly.lua` — stub `is_reloading`→false, distinct `KILL_FAST_CMD`/`KILL_CMD` sentinels, `is_hs_owned_bridge`→true, spy `hs.execute`; assert `KILL_CMD` (bootout) is used, not `KILL_FAST_CMD`; with `is_hs_owned_bridge`→false assert no kill. Fails today.

### F-HIGH-4 — N synchronous Keychain shell-outs (and a possible modal unlock prompt) block the boot/require path before the keyboard tap exists

- **Severity:** High · **Confidence:** confirmed · **Guarantees:** G4, G1
- **Files:** [llm/init.lua:291-329](static/ergopti_plus/macos/modules/llm/init.lua#L291-L329), [api_token_crypto.lua:121-137](static/ergopti_plus/macos/modules/llm/api_token_crypto.lua#L121-L137), [init.lua:152](static/ergopti_plus/macos/init.lua#L152)
- **Repro:** User saved one or more remote API entries (tokens migrated to keychain refs `token = "keychain:<id>"`). Launch/reload HS. Boot's `require("modules.keymap")` transitively requires `modules.llm`, whose **top-level** `pcall(M.load_api_entries)` ([llm/init.lua:329](static/ergopti_plus/macos/modules/llm/init.lua#L329)) runs at require time and calls `TokenCrypto.decrypt(e.token)` for every entry — each a **blocking** `hs.execute("/usr/bin/security find-generic-password … -w")`. With N entries that is N synchronous subprocess spawns on the HS run loop, all finishing **before** `keymap.start()` ([init.lua:757](static/ergopti_plus/macos/init.lua#L757)) creates the eventtap. Worse: if the login Keychain is locked at boot, `security … -w` raises the **system Keychain unlock dialog**, and `hs.execute` does not return until the user types their password — freezing the whole run loop and delaying tap setup arbitrarily.
- **Root cause + why silent:** Token decryption is performed eagerly at module-require time. The comment justifying the top-level call ("hs.settings is synchronous and cheap, so we don't defer") accounts only for the settings read and overlooks that `load_api_entries` also decrypts via a blocking shell-out. **Silent:** it is latency, not an error (nothing logged); the call is wrapped in `pcall`, so even a throw is swallowed; a Keychain GUI stall is not an error at all (`hs.execute` simply does not return). Invisible with 0–1 entries during development.
- **Proposed fix:** Make decryption **lazy** — `load_api_entries` keeps the `"keychain:<id>"` reference in-memory and only resolves to cleartext on first actual use (inside `ApiRemote`, cached after first resolve). Remove the per-entry `decrypt` from the require-time loop. When decrypt finally runs, defer it off any eventtap callback (`hs.timer.doAfter(0)`) so a Keychain prompt can never trip `kCGEventTapDisabledByTimeout`. Update the misleading comment.
- **Regression test:** `tests/unit/llm/test_load_api_entries_no_keychain_shellout_on_require.lua` — stub `hs.settings` to return 3 `keychain:` entries; seed the exec stub. Require `modules.llm` via `load_with_stubs` and assert **zero** `security` shell-outs at require time. A second assertion drives a simulated first-use request and asserts the lookup happens *then*. Fails before (3 calls at require), passes after.

### F-HIGH-5 — Crash reporter is unreachable dead code: a real crash leaves no report on disk

- **Severity:** High · **Confidence:** confirmed · **Guarantees:** G2, G1
- **Files:** [init.lua:242-247](static/ergopti_plus/macos/init.lua#L242-L247), [crash_reporter.lua](static/ergopti_plus/macos/lib/crash_reporter.lua), [logger.lua:798-851](static/ergopti_plus/macos/lib/logger.lua#L798-L851)
- **Repro:** Driver running. Trigger any uncaught Lua error in a timer/eventtap/task callback (the exact class `crash_reporter.lua` promises to capture). Observe: **no** file under `crash_reports/`, **no** "crash report saved" dialog. Grep proof: `ergopti_report_crash` occurs exactly once in the whole macOS tree — its own definition ([init.lua:242](static/ergopti_plus/macos/init.lua#L242)); `crash_reporter.report`/`prompt_user` appear only inside that never-called function.
- **Root cause + why silent:** The global `_G.ergopti_report_crash` was defined as the entry point but **never wired to any error hook** (no `hs.crash` watcher, no MessagePort/console watcher, no `xpcall` forwarder, no menu item) — the init comment describes a watcher that was never implemented. The actual error capture (`logger.install_runtime_error_capture`) forwards uncaught errors **only to the file log**, never to `crash_reporter`. So `crash_reporter.lua` (~300 lines incl. the `lib-update-05` recursive-mkdir fix) is 100% dead. **Silent twice:** the handler is never invoked (nothing logs its absence), and even if it were, [init.lua:243](static/ergopti_plus/macos/init.lua#L243) wraps `report+prompt` in a bare `pcall` with no error branch — a crash-while-reporting also vanishes.
- **Proposed fix:** Either (a) wire it: in `logger._guard_timer_cb` and the `print()` tee, after logging the ERROR, `if type(_G.ergopti_report_crash)=="function" then pcall(_G.ergopti_report_crash, err, {driver="hammerspoon"}) end`, debounced by a named `CRASH_REPORT_MIN_INTERVAL_SEC` so an error storm cannot write hundreds of files; and replace the bare `pcall` at [init.lua:243](static/ergopti_plus/macos/init.lua#L243) with an error branch that `Logger.error`s; or (b) per copilot-instructions §5.6 (no unused fallback code), delete `crash_reporter.lua` + the orphan entry point if it is intentionally retired.
- **Regression test:** `tests/unit/lib/test_crash_reporter_wired.lua` (behavioral, encodes reachability) — install runtime capture, drive an `hs.timer.doAfter(0)` body that throws, assert `crash_reporter.save` (stubbed) was invoked and a path produced. Second assertion: stub `crash_reporter.report` to throw and assert a `Logger.error` is emitted (not swallowed). Fails today.

### F-HIGH-6 — A wrong-typed `hs.settings` modifier value crashes the menu builders via `table.concat`, silently blanking the AI submenu

- **Severity:** High · **Confidence:** confirmed (merges F2 confirmed + F1 contested — same root cause) · **Guarantees:** G1, G2
- **Files:** [menu_llm/init.lua:186-201/663-686](static/ergopti_plus/macos/ui/menu/menu_llm/init.lua#L186-L201), [menu_llm/settings_manager.lua:336-339](static/ergopti_plus/macos/ui/menu/menu_llm/settings_manager.lua#L336-L339), [config_overrides.lua:44-122](static/ergopti_plus/macos/lib/config_overrides.lua#L44-L122), [ui/menu/init.lua:562-585](static/ergopti_plus/macos/ui/menu/init.lua#L562-L585)
- **Repro:** A `hammerspoon/config.toml` containing `llm_nav_modifiers = "shift+cmd"` under `[script]` (a user-editable override — `config_overrides` accepts any bare key and can only coerce to bool/number/**string**, never an array) persists a **string** under the key the menu later reads. Open the menubar → AI submenu. `format_shortcut_title` (or `build_modifier_menu`) reads the value, the only guard is `== nil`, and reaches `table.concat(mods, "+")` — which raises `bad argument #1 to 'concat' (table expected, got string)`. (Verified Lua semantics: `#"shift+cmd"==9` so the `#mods==0` branch is skipped, `ipairs` over a string yields nothing, and `table.concat` on a string throws.)
- **Root cause + why silent:** The engine setter `prediction_engine.lua` was hardened (`type(mods)=="string" and {mods} or …`) — proving a string *can* legitimately reach this value — but the **menu-build consumers that read the same persisted key** were never given the equivalent guard, breaking the single-source-of-truth invariant between engine and UI. **Silent:** `menu_llm.create`/`build_item` runs inside `pcall` ([ui/menu/init.lua:562](static/ergopti_plus/macos/ui/menu/init.lua#L562)), error logged once at [line 581](static/ergopti_plus/macos/ui/menu/init.lua#L581) → the entire AI/LLM submenu silently fails to build and vanishes from the menubar, with no way to re-configure LLM from the UI.
- **Proposed fix:** Fail-closed to the canonical default at every read of these keys: `if type(nav_mods) ~= "table" then nav_mods = llm_mod.DEFAULT_STATE.llm_nav_modifiers end` (same for `val_mods` and the `build_modifier_menu` read at [settings_manager.lua:337](static/ergopti_plus/macos/ui/menu/menu_llm/settings_manager.lua#L337)), and harden `format_shortcut_title` to return a safe string when `type(mods) ~= "table"`. The default already flows from `DEFAULT_STATE` (no new default declared).
- **Regression test:** `tests/unit/ui/menu/test_menu_llm_bad_modifiers.lua` — seed `hs.settings.__store["llm_nav_modifiers"]="shift+cmd"` and `["llm_val_modifiers"]={123}`; call `menu_llm.create(deps)` under `pcall` and `assert_true` it succeeds and returns a non-empty menu (LLM submenu present). Also unit-test `format_shortcut_title`/`build_modifier_menu` directly with a string arg and assert a string return, not a throw. Fails today.

---

## 3. Medium findings

### F-MED-1 — `dt>0.5 s` stuck-synthetic reset ignores `expected_synthetic_pastes` → a stall before a 0-delete paste echo wipes the buffer + logs a phantom Cmd+V

- **Severity:** Medium · **Confidence:** confirmed · **Guarantees:** G2, G3 · **Relation:** same class as prior A6
- **Files:** [keymap/init.lua:614-707](static/ergopti_plus/macos/modules/keymap/init.lua#L614-L707), [llm_bridge.lua:691-718](static/ergopti_plus/macos/modules/keymap/llm_bridge.lua#L691-L718), [expander.lua:105-107](static/ergopti_plus/macos/modules/keymap/expander.lua#L105-L107)
- **Repro:** LLM enabled, cursor at a clean word boundary so an accepted prediction needs 0 deletions; accept a prediction past the 50-codepoint paste threshold (or any high-unicode expansion). `emit_text` takes the paste path: `emitted_str==""`, `expected_synthetic_pastes` incremented to 1 — the **sole** in-flight counter (deletes==0, chars==""). Now let the run loop stall (heavy load/GC) so the Cmd+V echo arrives with `dt>0.5`. The reset guard computes `events_in_flight = pending_deletes>0 or #pending_chars>0` ([init.lua:628](static/ergopti_plus/macos/modules/keymap/init.lua#L628)) — **false**, because pastes are not counted — and zeroes `expected_synthetic_pastes`. The Cmd+V echo then hits the Cmd/Ctrl branch, finds the counter 0, falls through to `CoreState.buffer=""` + `check_nav_reset()`, wiping the rebuilt buffer (breaking chaining) and recording a phantom Cmd+V shortcut.
- **Root cause + why silent:** The A6 fix added `events_in_flight` for `deletes`/`chars` but omitted the later-added third counter `expected_synthetic_pastes`. `last_synthetic_arm_time` *is* set on this path, so folding pastes into the predicate fully protects it. **Silent:** no error — `onKeyDownRaw` returns normally; pure state desync. The existing `test_synthetic_reset_guard.lua` helper models only deletes/chars, so it stays green while the bug is live.
- **Proposed fix:** `local pending_pastes = CoreState.expected_synthetic_pastes or 0; local events_in_flight = pending_deletes > 0 or #pending_chars > 0 or pending_pastes > 0`. Keep the `SYNTHETIC_STALE_SEC` escape hatch. No new magic number.
- **Regression test:** extend `tests/unit/modules/keymap/test_synthetic_reset_guard.lua` with a behavioral case driving the **real** `onKeyDownRaw`: seed `expected_synthetic_pastes=1`, deliver a Cmd+V keyDown with `dt>0.5`, assert (a) the counter decremented by the paste-echo branch and (b) `CoreState.buffer` unchanged. Also extend the formula helper to take `pending_pastes` and return false for `(dt=0.9, arm_age=1.5, 0 deletes, '', 1 paste)`.

### F-MED-2 — `kc_bridge.drain_log` still blind-truncates with `io.open("w")` → concurrent Karabiner key lines wiped (C7 residual)

- **Severity:** Medium · **Confidence:** confirmed · **Guarantees:** G2, G3 · **Relation:** C7 partially-fixed
- **Files:** [kc_bridge.lua:201-265](static/ergopti_plus/macos/modules/keylogger/kc_bridge.lua#L201-L265)
- **Repro:** KE appends physical kc lines on every key. `drain_log` reads to EOF, closes the handle ([kc_bridge.lua:247](static/ergopti_plus/macos/modules/keylogger/kc_bridge.lua#L247)), then because `_file_offset >= file_size` reopens in `"w"` mode ([line 260](static/ergopti_plus/macos/modules/keylogger/kc_bridge.lua#L260)), truncating the file. Any line KE appends in the **close→reopen-`w`** gap was never read and is destroyed; those physical keys vanish from the heatmap.
- **Root cause + why silent:** The "C7 fix" removed the size *re-query* but kept the destructive whole-file `"w"` truncate, which is inherently racy against an uncoordinated append-only writer. The guard `_file_offset >= file_size` only proves what existed at *open* time, not at *truncate* time. **Silent:** `drain_log` runs in `pcall`; a lost line is missing data, not an error. The existing test (`test_kc_bridge_truncation_toctou.lua`) only greps source and *requires* truncation to still happen, pinning the narrowed-but-present behavior.
- **Proposed fix:** Do not truncate from the reader. Let `karabiner_kc.log` grow and reset `_file_offset` only on writer rotation (the shrink-detection at [kc_bridge.lua:203-207](static/ergopti_plus/macos/modules/keylogger/kc_bridge.lua#L203-L207) already handles that), rotating from the KE-generator side if growth matters. If truncation must stay, re-stat immediately before the `"w"` open and skip it if the file grew.
- **Regression test:** turn `test_kc_bridge_truncation_toctou.lua` behavioral — a stub `io` that, on the `"w"` open, first appends a line `X`; drive a drain to EOF then a second drain; assert `X` is eventually drained (not wiped). Fails today.

### F-MED-3 — `notify_synthetic` lacks an `is_enabled` guard and `M.start` never clears `synth_queue` → stale queue poisons the first keystrokes after the keylogger is first enabled

- **Severity:** Medium · **Confidence:** confirmed · **Guarantee:** G2 · **Relation:** same class as C5
- **Files:** [keylogger/init.lua:419/1115-1147/1410-1440/1561](static/ergopti_plus/macos/modules/keylogger/init.lua#L1115-L1147), [expander.lua:110-112](static/ergopti_plus/macos/modules/keymap/expander.lua#L110-L112)
- **Repro:** keymap/hotstrings ON, keylogger OFF (a supported default — `keylogger_enabled=false`). Type a hotstring; `expander.perform_text_replacement` calls `keylogger.notify_synthetic` **unconditionally**. `notify_synthetic` has no `if not CoreState.is_enabled then return`, so it pushes into `synth_queue`/`recent_typing_eff`. `handle_key` returns at the disabled guard, so the `SYNTH_IDLE_DRAIN` self-heal never runs; the queue grows unbounded across a session. The user then enables the keylogger via the menu: `M.start()` sets `is_enabled=true` but does **not** clear `synth_queue` (unlike `M.stop`). The first real keystrokes match the stale head and are tagged synthetic → excluded from WPM/n-grams until a >500 ms gap drains them.
- **Root cause + why silent:** Two gaps — `notify_synthetic` mutates queue/WPM state while the feature is off (unlike sibling `log_hotstring`/`log_llm` which guard on `is_enabled`), and `M.start` does not reset the synthetic state the way `M.stop` does. **Silent:** while disabled there is no tap activity to log the growth; the corruption looks like normal warm-up noise on the first keystrokes after enabling.
- **Proposed fix:** Add `if not CoreState.is_enabled then return end` at the top of `notify_synthetic`. In `M.start`, after `is_enabled=true`, clear `synth_queue`/`recent_typing_eff`/`recent_typing_phys` exactly as `M.stop` does.
- **Regression test:** `tests/unit/modules/keylogger/test_notify_synthetic_disabled_guard.lua` — with `is_enabled=false`, `notify_synthetic("abc",…)` then assert `#synth_queue==0`; second case: force a non-empty queue, call `M.start(stub)`, assert it is empty after. Both fail today.

### F-MED-4 — "LLM after hotstring" chain timer is armed for ~24 h (never fires) when the hotstring preview is disabled

- **Severity:** Medium · **Confidence:** confirmed · **Guarantee:** G2
- **Files:** [llm_bridge.lua:528-571](static/ergopti_plus/macos/modules/keymap/llm_bridge.lua#L528-L571), [prediction_engine.lua:464-468](static/ergopti_plus/macos/modules/llm/prediction_engine.lua#L464-L468)
- **Repro:** Enable "LLM after hotstring" + the LLM engine, and disable the relevant hotstring preview (e.g. `set_preview_autocorrect_enabled(false)`, or a group whose `show_tooltip==false`). Type a buffer matching a hotstring so `update_preview` collects matches but every row is `enabled=false` → `min_timeout` stays nil → `tooltip_timeout = INFINITE_TOOLTIP_SEC` (86400). The chain branch runs unconditionally and calls `engine.start_timer(86400 + 0.05)`, which `start_inactivity_timer` arms with no clamp. The chained LLM prediction therefore **never appears**; each further matching keystroke re-arms the same 24 h timer.
- **Root cause + why silent:** `tooltip_timeout` is derived solely from `min_timeout` (populated only by enabled rows). The `INFINITE_TOOLTIP_SEC` sentinel is correct as "never auto-dismiss a *visible* tooltip" but wrong as the *LLM chain delay* when no tooltip is shown — the chain-arming block conflates the two. **Silent:** `start_timer` succeeds and logs only a DEBUG line; the timer is armed (just for 24 h), so no `START`-without-`SUCCESS` and no crash.
- **Proposed fix:** Gate the chain delay on whether a tooltip is actually shown: when `any_enabled` is false (or `min_timeout` is nil), arm with a short named delay (e.g. `HOTSTRING_CHAIN_OFFSET_SEC` / the standard debounce), not `INFINITE_TOOLTIP_SEC`. Compute the chain delay from `min_timeout`, not the infinite fallback.
- **Regression test:** `tests/unit/modules/keymap/test_llm_bridge_chain_delay.lua` — stub `engine.start_timer` to capture its delay, register one matching autocorrect mapping, disable the preview, enable LLM-after-hotstring, call `update_preview(matching_buffer)`; assert the captured delay is small (≤ a few seconds) and **not** ≥ `INFINITE_TOOLTIP_SEC`. Captures ~86400 today.

### F-MED-5 — Pause and the menu gesture-enable toggle share one `CoreState.enabled` flag → gestures run while paused / resume clobbers mid-pause intent

- **Severity:** Medium · **Confidence:** confirmed · **Guarantees:** G2, G1
- **Files:** [gestures/init.lua:158/467-468](static/ergopti_plus/macos/modules/gestures/init.lua#L467-L468), [script_control.lua:164-189](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L164-L189), [menu_gestures.lua:67-90](static/ergopti_plus/macos/ui/menu/menu_gestures.lua#L67-L90)
- **Repro:** Gestures enabled. Press AltGr+Enter to pause: `pause_all` snapshots `_gestures_were_enabled=true` and calls `disable_all` (`CoreState.enabled=false`). The menubar stays operable. **(a)** Toggle gestures ON in the menu → `enable_all()` sets `CoreState.enabled=true` and a 3-finger swipe now fires *while paused* (violates "pause = everything off"). **(b)** Or toggle gestures OFF during pause, then resume: `resume_all` sees the stale snapshot `_gestures_were_enabled=true` and re-enables gestures against the user's just-expressed intent, leaving `state.gestures(false)` desynced from `CoreState.enabled(true)`.
- **Root cause + why silent:** `CoreState.enabled` is overloaded as *both* the user feature flag (menu) *and* the pause-suspend flag (script_control); there is no separate axis, so a write from one subsystem clobbers the other and the engine's gate cannot distinguish "paused" from "feature off". The gestures master toggle's `fn` is live while paused (unlike the slot items and the hotstrings toggle, which guard on `ctx.paused`). **Silent:** no error; the engine honours whatever `CoreState.enabled` is. The pause-invariant test never injects gesture spies, so it cannot catch this.
- **Proposed fix:** Separate the axes: keep `CoreState.enabled` as the feature flag and add `CoreState.suspended` (default false); the engine fires only when `enabled and not suspended`. `script_control.pause_all/resume_all` set/clear `suspended` via new `gestures.suspend()/resume()` (not `enable_all/disable_all`), so menu toggles and pause never clobber each other and resume needs no snapshot.
- **Regression test:** `tests/unit/modules/gestures/test_init.lua` — `enable_all(); suspend()`; assert `is_enabled()` still true but the engine gate is closed (drive `process_frame` with a swipe → no action). While suspended, `disable_all(); resume()`; assert `is_enabled()==false` (mid-pause disable survived). Fails today.

### F-MED-6 — The WPM floating widget + menubar (and the widget's mouse eventtap) keep polling/rendering during pause

- **Severity:** Medium · **Confidence:** confirmed (merges SP-1 + WPM-PAUSE-01) · **Guarantees:** G2, G4
- **Files:** [script_control.lua:133-170](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L133-L170), [wpm_widget.lua:488-523](static/ergopti_plus/macos/ui/wpm/wpm_widget.lua#L488-L523), [wpm_menubar.lua:91-105](static/ergopti_plus/macos/ui/wpm/wpm_menubar.lua#L91-L105), [ui/menu/init.lua:603-616](static/ergopti_plus/macos/ui/menu/init.lua#L603-L616)
- **Repro:** Keylogger + floating WPM widget (and/or menubar WPM) enabled. Type so live WPM > 0, then AltGr+Enter to pause. The widget `_timer` (0.2 s), menubar `_timer` (0.5 s), and the widget mouse eventtap (every `mouseMoved`) keep firing; for the ~15 s rolling window the canvas keeps redrawing a decaying non-zero MPM. The widget self-hides ~5 s after the last keystroke (WPM decays to 0), so a casual observer thinks it stopped — but the timers/tap are still live, polling `keylogger.get_live_stats()` (table eviction + WPM math) and re-entering the Lua VM, while the user believes everything is paused.
- **Root cause + why silent:** `pause_all` quiesces keymap/LLM/tooltip/shortcuts/gestures/karabiner but never references the WPM UIs; they are started/stopped only by their feature flags, never by pause. **Silent:** timers/tap run successfully; the visible artifact (canvas) self-hides while the invisible artifact (timer + mouse tap) persists.
- **Proposed fix:** In the `set_on_pause_change` listener ([ui/menu/init.lua:603-616](static/ergopti_plus/macos/ui/menu/init.lua#L603-L616)), on pause call `WpmWidget.stop()` + `WpmMenubar.stop()`; on resume re-arm **exactly once**, honouring the persisted flags (mirror the `_gestures_were_enabled` snapshot pattern). Both `start()` are idempotent and `stop()` nils the timer/tap/canvas. Keep `pcall`-wrapped + lifecycle log pair.
- **Regression test:** `tests/unit/ui/wpm/test_wpm_pause_quiesce.lua` — stub `ui.wpm.wpm_widget`/`wpm_menubar` with `start`/`stop` call counters; drive the pause reactor with `is_paused=true` and assert both `stop` called once; resume with `keylogger_float_wpm=true` and assert `start` called once (no double-arm), with the flag false assert not started. Fails today (the listener never references the WPM modules).

### F-MED-7 — `script_quit` (rcmd+Escape) leaks the MLX server + orphan helper processes because `os.exit(0)` bypasses the shutdown teardown

- **Severity:** Medium · **Confidence:** confirmed · **Guarantees:** G1, G2 · **Relation:** same class as `project_hs_script_quit_kills_karabiner` (KE half fixed, MLX/orphan half not duplicated)
- **Files:** [gestures/actions.lua:575-602](static/ergopti_plus/macos/modules/gestures/actions.lua#L575-L602), [init.lua:937-1013](static/ergopti_plus/macos/init.lua#L984-L1003), [menu_llm/init.lua:155-157](static/ergopti_plus/macos/ui/menu/menu_llm/init.lua#L155-L157)
- **Repro:** LLM backend enabled (MLX on Apple Silicon — default), so `mlx_lm.server` + `ergopti_plus_expander`/`ergopti_plus_http_server` helpers run. Trigger `script_quit` (default rcmd+Escape). After HS exits, `pgrep -f mlx_lm` still returns a live server holding GPU memory + the MLX port; the helper orphans survive. The `hs.shutdownCallback` that kills them is never invoked because `os.exit(0)` terminates the Lua VM abruptly.
- **Root cause + why silent:** The `script_quit` closure manually reproduces only **two** of the shutdown teardown steps (`karabiner.kill()` + keylogger flush) before `os.exit(0)`. The only MLX-server kill (`stop_mlx_server()`) and orphan-helper pkills live in `hs.shutdownCallback` ([init.lua:984-1003](static/ergopti_plus/macos/init.lua#L984-L1003)), which `os.exit(0)` bypasses — and they were never duplicated into the handler. **Silent:** `os.exit(0)` exits with no error and no callback; the leak is observable only later via `pgrep`/Activity Monitor, and the boot logic tries to *adopt* a surviving MLX server (partially masking it as a "fast warm start").
- **Proposed fix:** Best: extract the shutdown teardown body into a named `teardown_for_quit()` helper (in `lib/`) gated by `reload_guard`, and call it from **both** `hs.shutdownCallback` and `script_quit` (single source of truth, can never drift). Minimal: in `script_quit`, before `os.exit`, add `pcall(function() require("ui.menu.menu_llm").stop_mlx_server() end)` + the two helper pkills + the MLX-port `lsof` kill.
- **Regression test:** extend `tests/unit/modules/gestures/test_script_quit_kills_karabiner.lua` — stub `package.loaded["ui.menu.menu_llm"]={ stop_mlx_server = spy }`, capture `hs.execute` args, neutralise `os.exit`/`doAfter`; run `script_quit` and assert `stop_mlx_server` called once and an `hs.execute` arg matched `ergopti_plus_expander` and one matched `ergopti_plus_http_server`. Fails today.

---

## 4. Low findings

### F-LOW-1 — C6 `synth_queue` poison after a privacy/secure/app-disabled suppression is only mitigated by the >500 ms idle drain, not by a context-change clear
- **Confidence:** confirmed (probable repro) · **G2** · Files: [keylogger/init.lua:432-436/552-606](static/ergopti_plus/macos/modules/keylogger/init.lua#L432-L436), [context_tracker.lua:85-106](static/ergopti_plus/macos/modules/keylogger/context_tracker.lua#L85-L106).
The privacy guards `return` before `synth_queue` consumption, leaving stale entries; nothing clears the queue on context change. A <500 ms return to a normal field mis-tags the first real keystroke as synthetic. **Fix:** clear `_state.synth_queue` in `context_tracker.app_watcher_cb` and `update_secure_field_state`. **Test:** `test_synth_queue_context_clear.lua` — queue 2 synthetic chars, enter a secure field, assert `synth_queue=={}`.

### F-LOW-2 — LLM warmup retry chain keeps hitting the backend during pause
- **Confidence:** confirmed · **G2** · Files: [warmup_controller.lua:119-149](static/ergopti_plus/macos/modules/llm/warmup_controller.lua#L119-L149), [prediction_engine.lua:808-811](static/ergopti_plus/macos/modules/llm/prediction_engine.lua#L808-L811), [script_control.lua:133-170](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L133-L170).
`try_warmup` aborts only on LLM-disabled/backend-ready/load-failed — gated on the feature toggle, which pause does not change. `pause_all` cancels predictions/streaming but never `WarmupController.stop()`, so warmup POSTs keep firing during pause (cold-start window). Async, so no G4 symptom — but a pause-invariant violation. **Fix:** `pause_all` calls `warmup_controller.stop()`; resume re-arms only if the gate is still on. **Test:** `test_warmup_stops_on_pause.lua`.

### F-LOW-3 — Layout-settle delay `0.5 s` is a hardcoded magic number, bypassing the `Timings` single-source registry
- **Confidence:** confirmed · **G4 / §5.1-5.2** · Files: [karabiner/init.lua:649-657](static/ergopti_plus/macos/modules/karabiner/init.lua#L649-L657), [_shared/modules/timings/constants.toml](static/ergopti_plus/_shared/modules/timings/constants.toml).
Every sibling timing in this hot path is `Timings.sec`-sourced; the load-bearing 0.5 s TIS-settle (absorbs the async `hs.keycodes.map` update — too short → wrong keycodes in `karabiner.json`) is the only inline literal. **Fix:** add `layout_tis_settle_ms = 500` to `[debounce]` and source it via `Timings.sec`. **Test:** assert no bare `doAfter(0.5` for the rebuild + the TOML key exists.

### F-LOW-4 — Synchronous `hs.execute("defaults read HIToolbox")` runs every 2 s on the main loop in the layout fallback poll
- **Confidence:** confirmed · **G4** · Files: [watchers.lua:198-204/253/261-268](static/ergopti_plus/macos/modules/karabiner/watchers.lua#L198-L204).
The `doEvery(2 s)` Sequoia fallback poll spawns a synchronous `defaults read` + plist parse on the main run loop for the whole session (and again per layout change). Not a tap callback (no `kCGEventTapDisabledByTimeout`), but steady-state main-loop cost that the boot-profiler work aimed to eliminate. **Fix:** convert to `hs.task.new` async (mirror `deactivate_capsword` at [watchers.lua:109](static/ergopti_plus/macos/modules/karabiner/watchers.lua#L109)), or gate the poll to only run when `inputSourceChanged` is known unreliable, or cache with a short TTL. **Test:** assert the poll tick reads via `hs.task` (async), not synchronous `hs.execute`.

### F-LOW-5 — WPM widget persisted position read (`_pos_x/_pos_y`) is guarded only by `not` → a string in the plist reaches arithmetic + `hs.canvas` geometry
- **Confidence:** confirmed (probable) · **G1** · Files: [wpm_widget.lua:194-195/320-341](static/ergopti_plus/macos/ui/wpm/wpm_widget.lua#L320-L341).
A tampered/half-written plist value (e.g. `pos_x="100"`) passes the `if not _pos_x` guard and reaches `_pos_x + compact_w - canvas_width` (string+number → throw) or flows into the canvas frame. The layout error fires in a timer/UI callback → swallowed to the HS Console. **Fix:** `local _pos_x = tonumber(hs.settings.get(_SETTINGS_X))` (and `_pos_y`) so a non-numeric value coerces to nil and the existing default-recompute fires. **Test:** seed `pos_x="oops"`, lay out under `pcall`, assert no throw and `_pos_x` numeric.

---

## 5. Informational / latent (no live symptom today)

- **F-INFO-1 — `apply_prediction` open-codes the synthetic-injection bookkeeping instead of routing through `perform_text_replacement`.** [llm_bridge.lua:691-738](static/ergopti_plus/macos/modules/keymap/llm_bridge.lua#L691-L738). The duplicated counter/keylogger/buffer protocol is currently *correct* (matches the A4/A5 fixes), so no live desync — but the prior audit's transverse recommendation #1 (a single `keymap.inject_replacement` choke point routing **all** injectors) is still partial: any future protocol change must be hand-mirrored here, and a missed mirror silently re-introduces the `triggerabcd` class on the LLM paste path. **Fix:** extract `keymap.inject_replacement(deletes, text, source_variant)` and route `apply_prediction` (and `rules_engine`/`personal_info`) through it. **Test:** `tests/meta/test_single_injection_point.lua` grep-invariant forbidding raw `keyStroke("delete")`/`keyStrokes(` outside the choke point.

- **F-INFO-2 — `text.lua` / `gestures/actions.lua` injectors bypass both synthetic trackers, safe today only by accident of which keys they emit.** [shortcuts/actions/text.lua:297-408](static/ergopti_plus/macos/modules/shortcuts/actions/text.lua#L297-L408), [gestures/actions.lua](static/ergopti_plus/macos/modules/gestures/actions.lua). `surround_with_parens`/`do_transform`/`paste_as_plain_text`/`wrap_selection` emit only Cmd/nav/paste keys (classified as buffer-reset or paste echo), never bare buffer characters — so no corruption. The invariant "every char-stream injector routes through the choke point" holds **by accident**, not by design. **Fix:** document the invariant in `PROJECT_MEMORY` (synthetic section); optionally route paste through `km_utils` for uniform counting. **Test:** `test_text_actions_emit_only_safe_keys.lua` asserting every emitted key is a modified combo / arrow / Cmd+V (no bare `keyStrokes` of buffer text without a preceding arm).

- **F-INFO-3 — The pause-invariant unit test validates only the `is_paused()` boolean, never real quiescence.** [test_script_control.lua:179-246](static/ergopti_plus/macos/tests/unit/modules/shortcuts/test_script_control.lua#L179-L246). The production G2 bug is fixed, but the test never calls `SC.start(...)` with spy modules, so a regression deleting the `pause_all()` call would keep the test green. **Fix/Test:** `SC.start(keymap_spy, shortcuts_spy, gestures_spy, karabiner_spy)` then assert `pause_processing`/`reset_predictions`/`disable_all`/`pause_bindings`/`karabiner.pause` were invoked after `pause_all()`, and the symmetric calls after `resume_all()`.

---

## 6. Performance (G4)

Real profilers read: [lib/hotpath_profiler.lua](static/ergopti_plus/macos/lib/hotpath_profiler.lua), [lib/boot_profiler.lua](static/ergopti_plus/macos/lib/boot_profiler.lua), [lib/perf.lua](static/ergopti_plus/macos/lib/perf.lua).

### 6.1 Blocking calls in the boot/main-loop path (new)
- **F-HIGH-4** — N synchronous Keychain `security` shell-outs (+ possible modal prompt) on the require path **before the eventtap is created**. The single worst latency finding; the modal-prompt variant can freeze the run loop indefinitely.
- **F-LOW-4** — synchronous `defaults read HIToolbox` every 2 s on the main loop (Sequoia layout fallback).
- **F-HIGH-2 (G4 facet)** — a stalled MLX stream leaves a leaked `curl` and blocks the single-request backend until reload.

### 6.2 No blocking call found inside an `hs.eventtap` callback
The keymap hot path (`onKeyDownRaw`, expander) runs `CGEventPost` (non-blocking) synchronously and defers nothing that blocks. `project_macos_eventtap_no_blocking` is **respected** on the live tap. The `script_quit`/`script_reload` actions run from the script-control tap but defer the heavy work via `hs.timer.doAfter`. No `osascript`/`hs.execute` was found on an eventtap-callback path. ✅

### 6.3 Boot deferrals stayed deferred
The two dominant boot costs from `project_hs_perf_profilers_and_case_conform` (group disable/enable ~2 s round-trip; synchronous log-purge ~0.6 s pipeline) remain deferred. The case-conform registration fast path and the menubar dirty-cache are not bypassed by any per-keystroke rescan. `vscode_bridge` AX requests retain the 200 ms TTL cache and no uncached AX request was found on the hot path. ✅ (The 2 s group round-trip being deferred is, ironically, the *enabling condition* for **F-HIGH-1**'s prefix-registration bug — the perf no-op means `enable_group` never fires the post-load hook.)

### 6.4 Two silent-failure mechanisms to lock down with a meta-test
Nine confirmed findings are silent because of two recurring classes the project already documents:
- **closure-binds-nil-global** (`project_lua_closure_before_local_nil_global`) — recurred verbatim in **F-CRIT-2**.
- **errors thrown in `hs.task`/`hs.timer`/`hs.eventtap` callbacks go only to the HS Console** (`project_hs_timer_callback_errors_invisible`) — the reason F-CRIT-2, F-HIGH-4, F-HIGH-5, F-HIGH-6, F-LOW-5 are invisible.

Recommend a `tests/meta/test_no_local_task_after_closure.lua` grep-invariant: for every `local <name> = hs.task.new(... function ... end ...)`, assert the same identifier is not indexed inside the callback (forces forward-declaration). This would have caught F-CRIT-2 and would catch the next recurrence.

---

## 7. Watch-list — prior audit + `PROJECT_MEMORY` foot-guns

**Verified against current source. Almost everything the prior 37-bug audit flagged is fixed-in-place; the corruption/desync class is genuinely closed.**

| Prior ID | Status | Evidence |
|---|---|---|
| A1 (rules_engine no suppress/counters) | **fixed-in-place** | routes through `inject_dynamic`→`perform_text_replacement` ([rules_engine.lua:95-103](static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua#L95-L103)); test `test_sync_injection.lua` |
| A2 (no `notify_synthetic`) | **fixed-in-place** | `perform_text_replacement` always notifies ([expander.lua:110-112](static/ergopti_plus/macos/modules/keymap/expander.lua#L110-L112)); variants `"dynamic"`/`"personal"` |
| A3 (deferred-injection interleaving) | **fixed-in-place** | rules_engine emits synchronously, releases `_is_injecting` immediately ([rules_engine.lua:128-130](static/ergopti_plus/macos/modules/dynamic_hotstrings/rules_engine.lua#L128-L130)) |
| A4 (paste path skips notify) | **fixed-in-place** | notifies even when `emitted_str==""` ([llm_bridge.lua:709-714](static/ergopti_plus/macos/modules/keymap/llm_bridge.lua#L709-L714)) |
| A5 (paste leaves chars empty) | **fixed-in-place** | dedicated `expected_synthetic_pastes` counter ([expander.lua:105-108](static/ergopti_plus/macos/modules/keymap/expander.lua#L105-L108)) — *but see F-MED-1* |
| A6 (dt>0.5 wipes in-flight) | **fixed-in-place** | `last_synthetic_arm_time` guard ([expander.lua:82-84](static/ergopti_plus/macos/modules/keymap/expander.lua#L82-L84)) — *but the paste counter was omitted: **F-MED-1*** |
| A7 (re-typed terminator untracked) | **fixed-in-place** | terminator appended to `s` ([expander.lua:415-430](static/ergopti_plus/macos/modules/keymap/expander.lua#L415-L430)) |
| CLIP (clipboard overwrite) | **fixed-in-place** | serialised `_paste_saved_original` ([utils.lua:77-79](static/ergopti_plus/macos/modules/keymap/utils.lua#L77-L79)); `adapters/text_sender.lua` still naive but dormant |
| B1 (disable_group stale buckets) | **fixed-in-place** | unconditional purge + `rebuild_tail_indexes()` ([registry.lua:1013-1037](static/ergopti_plus/macos/modules/keymap/registry.lua#L1013-L1037)) |
| C1 (keylogger logs under pause) | **fixed-in-place** | pause guard hoisted above all branches ([keylogger/init.lua:423-429](static/ergopti_plus/macos/modules/keylogger/init.lua#L423-L429)) — *test does not pin the position: §6/test-debt* |
| C2 (no tap watchdog) | **fixed-in-place** | 5 s watchdog re-arms a disabled tap — *no regression test (test-debt)* |
| C3 (midnight re-aggregation) | **fixed-in-place** | destructive offset reset removed ([rotation.lua:174-178](static/ergopti_plus/macos/modules/keylogger/rotation.lua#L174-L178)) — *no root-cause test (test-debt)* |
| C4 (data.sql before txn) | **fixed-in-place** | data.sql written only after COMMIT — *residual id-gap = contested KL-1; no test* |
| C5 (synth_queue no auto-reset) | **fixed-in-place** | idle drain + stop clear + fast-path pop ([keylogger/init.lua:552-606](static/ergopti_plus/macos/modules/keylogger/init.lua#L552-L606)) — *but F-MED-3 (no enable-time clear) + F-LOW-1 (C6)* |
| C6 (poison after suppression) | **same-class-elsewhere** | not cleared on context change → **F-LOW-1** (mitigated by C5 idle drain) |
| C7 (kc_bridge TOCTOU) | **partially-fixed** | re-query window closed, lossy `"w"` truncate remains → **F-MED-2** |
| D1 (Ollama stream no timeout) | **fixed-in-place** | `--connect-timeout 5` + `--max-time` ([api_ollama.lua:634-641](static/ergopti_plus/macos/modules/llm/api_ollama.lua#L634-L641)) — *MLX twin gap = F-HIGH-2* |
| D2 (F16 chain fast-exited) | **fixed-in-place** | keycode 106 removed from `FAST_EXIT_KEYCODES` ([keymap/init.lua:576-590](static/ergopti_plus/macos/modules/keymap/init.lua#L576-L590)) |
| D3 (reset leaves chain_pending) | **fixed-in-place** | `M.reset()` clears `chain_pending` + timer ([prediction_engine.lua:734-736](static/ergopti_plus/macos/modules/llm/prediction_engine.lua#L734-L736)) |
| D4 (stale success resets fail counter) | **fixed-in-place** | reset moved after the stale guard ([streaming_handler.lua:254-261](static/ergopti_plus/macos/modules/llm/streaming_handler.lua#L254-L261)) |
| E1/E2/E3 (tooltip lifecycle) | **fixed-in-place** | `hide_stacked` on transition, deferred preview, `stop_dequeue` before render; test `test_tooltip_lifecycle.lua` |
| F1 (show_tooltip pattern) | **fixed-in-place** | two `match()` calls instead of broken `(true|false)` alternation; test present |
| G1 (modifier+key actions dead) | **fixed-in-place** | `sg()` 3-arg binding fixed ([gestures/actions.lua:84-87](static/ergopti_plus/macos/modules/gestures/actions.lua#L84-L87)) — *no behavioral test (test-debt)* |
| G2 (public pause quiesces nothing) | **fixed-in-place** | `M.pause_all`→internal `pause_all()` ([script_control.lua:462-468](static/ergopti_plus/macos/modules/shortcuts/script_control.lua#L462-L468)) — *test only checks the boolean: F-INFO-3* |
| H2/H3/H4/H5 (port adapters) | **fixed-in-place + still DORMANT** | AX tree walk / `utf8.len` / modifier normalisation / existence-based tap teardown — not wired into the live macOS path; runtime impact nil |
| mem: F1-critical closure-nil (api_ollama) | **fixed-in-place** | `local tmp_path` (530) before `on_done` (579), documented; api_mlx/api_remote clean — *but the **class** recurred: F-CRIT-2* |
| mem: gesture peak framerate | **fixed-in-place** | `peak_elapsed >= PEAK_FINGERS_CONFIRM_MS` live; test `test_peak_override_regression.lua` |
| mem: gesture reversal detection | **fixed-in-place** | diag branch uses dx+dy; `hadLiveFire` sticky; tests present |
| mem: script-control tap lifecycle | **fixed-in-place** | `pause_bindings`/`resume_bindings`, watchdog, layout handler skips rebuild under pause; tests present |
| mem: suspend/pause invariant | **mostly fixed** | keymap/LLM/tooltip/gestures/shortcuts/keylogger quiesced — **WPM widget (F-MED-6) + LLM warmup (F-LOW-2) + gesture-flag conflation (F-MED-5) are the residual G2 holes** |
| mem: LLM runtime-enable gate | **fixed-in-place** | warmup gated on the runtime gate, not profile restoration |
| mem: script_quit kills KE | **fixed-in-place (KE half)** | `script_quit` calls `karabiner.kill()` — **MLX/orphan half not duplicated: F-MED-7**; **genuine-quit shutdown uses weak kill: F-HIGH-3** |
| mem: onboarding config schema | **not re-derived** | (out of this pass's confirmed set; no contradicting evidence found) |
| mem: touchdevice dormancy | **respected** | gesture startup uses the primer-as-wakeup design; no code assumes pre-touch activation |

### Test-debt (fixes are in place but the regression test does not encode the root cause — violates §5.9)
Per `feedback_regression_tests`, these currently-green fixes are **unprotected** against a silent revert and should get root-cause tests:
- **C1** — assert the `is_paused` guard's source offset is **before** the `flagsChanged` branch in `handle_key`.
- **C2** — drive a stub tap with a controllable `isEnabled` flag, fire the watchdog, assert restart.
- **C3** — `read_new_entries` with a changed date but non-shrunk file must **not** reset the offset.
- **C4** — stub a `db:exec` failure + capture `io.open` on `data.sql`; assert no write on rollback.
- **G1** — `execute_single("cmd_a")` posts exactly one keyStroke `key=="a"` mods `cmd` (one per family).
- **G2** — spy stubs assert `pause_all()` actually invokes `pause_processing`/`disable_all`/`pause_bindings`/`karabiner.pause` (= **F-INFO-3**).

---

## 8. Coverage register (module × guarantee)

`A` = audited-and-cleared (no finding), `F<n>` = finding raised, `—` = not in scope this pass.

| Module / area | G1 robustness | G2 output | G3 race | G4 lag |
|---|---|---|---|---|
| keymap/{init,expander,registry,state,utils,terminators} | A | F-MED-1 | F-MED-1 | A (synchronous-by-design, non-blocking) |
| keymap/llm_bridge | A | F-MED-4 | F-INFO-1 (latent) | A |
| dynamic_hotstrings/{rules_engine,personal_info,init} | A | **F-HIGH-1** | A | A |
| hotstrings_config | A | A | A | A |
| keylogger/{init,aggregator,context_tracker} | A | F-MED-3, F-LOW-1 | A | A |
| keylogger/{kc_bridge,sqlite_writer,log_manager,rotation} | A | F-MED-2, KL-1(contested) | F-MED-2 | A |
| llm/{api_mlx,streaming_handler} | **F-HIGH-2** | **F-HIGH-2** | **F-HIGH-2** | F-HIGH-2 |
| llm/{init,api_token_crypto} | F-HIGH-4 | A | A | **F-HIGH-4** |
| llm/{api_ollama,api_remote,prediction_engine,warmup_controller} | A | F-LOW-2 | A | A |
| gestures/{engine,actions,init,conflicts} | F-MED-5 | F-MED-5 | A | A |
| shortcuts/{script_control,bindings,kbd_shortcuts} | **F-CRIT-1** | F-INFO-3 | A | A |
| shortcuts/actions/{text,system,apps} | A | F-INFO-2 (latent) | F-INFO-2 | A |
| karabiner/{init,ke_lifecycle,watchers,generator,onboarding,config,defaults} | **F-HIGH-3** | A | A | F-LOW-3, F-LOW-4 |
| init.lua (boot, shutdown, reload/quit) | F-HIGH-3, F-MED-7 | F-HIGH-5 | A | F-HIGH-4 |
| ui/tooltip/* | A | A | A | A |
| ui/menu/menu_about (self-update) | **F-CRIT-2** | **F-CRIT-2** | A | A |
| ui/menu/menu_llm/* | F-HIGH-6 | F-HIGH-6 | A | A |
| ui/menu/* (click→callback dispatch) | A (per-item `pcall` absent but no live-crash repro: see refuted MENU-DISPATCH-*) | A | A | A |
| ui/wpm/* | F-LOW-5 | F-MED-6 | A | F-MED-6 |
| lib/{crash_reporter,logger} | F-HIGH-5 | F-HIGH-5 | A | A |
| lib/{healthcheck,updater,vscode_bridge,reload_guard,perf,timings} | A | A | A | A |
| adapters/{shell_runner,http_client,clipboard,timer_scheduler} | A | A | A | A |
| adapters/{keyboard_hook,key_state,secure_field_detector,text_sender} | A (DORMANT — not wired live) | A | A | A |

**Loop-until-dry note:** round 1 (8 module clusters + 3 end-to-end flows) produced 38 candidates; the completeness critic surfaced 8 under-probed areas (menu dispatch, Keychain boot, self-update install, WPM-under-pause, i18n missing-key, crash_reporter/healthcheck, layout hot path, `hs.settings` integrity); round 2 confirmed 7 more findings (incl. both criticals — `SU-1` and the WPM/Keychain highs were round-2 discoveries). No third round was run; the menu-dispatch and i18n surfaces went **dry** (refuted — see §9), and `hs.settings` integrity is the one area still worth a dedicated future pass (only two of its many consumers were probed).

---

## 9. Contested & refuted (honesty section)

### Contested (one verifier confirmed, one refuted — reported with the honest split)

- **KL-1 — keylogger ingest rollback advances `_next_event_id` → duplicate rows + doubled aggregation.** The low-level mechanism is real (`_alloc_event_id` mutates the module counter before the transaction; rollback restores neither it nor the persisted meta nor the file offset). **But the harmful consequence is refuted:** a failed batch is rolled back (never commits), so there are **no duplicate rows and no doubled aggregation** — only a **monotonic id gap** (cosmetic; can desync a peer replaying `data.sql`). **Net: LOW.** Worth the suggested snapshot/restore of `_next_event_id` on rollback for clean peer-replay, but not the HIGH the finder first rated. Files: [log_manager.lua:483-563](static/ergopti_plus/macos/modules/keylogger/log_manager.lua#L483-L563), [sqlite_writer.lua:246-250](static/ergopti_plus/macos/modules/keylogger/sqlite_writer.lua#L246-L250).

- **SU-2 — self-update restore-rename unchecked + misleading cross-volume comment.** Two real surface defects: [menu_about.lua:241](static/ergopti_plus/macos/ui/menu/menu_about.lua#L241) discards the restore `os.rename` return and then logs "restored backup" unconditionally; the [line 229](static/ergopti_plus/macos/ui/menu/menu_about.lua#L229) comment "Cross-volume falls back to copy" is false (Lua `os.rename` = `rename(2)`, returns EXDEV, no copy). **But the catastrophic outcome is refuted:** `backup_app = target..".bak"` is on the **same volume/dir** as `target`, so only the `new_app → target` rename is ever cross-volume; the restore is intra-volume and succeeds. **Net: LOW hardening** — check the restore result, fix the comment, and unzip into a tmp dir under `target`'s parent so the swap stays intra-volume.

### Refuted (raised then dropped on adversarial re-read — listed so "no finding" ≠ "not looked at")
- **INJCORE-2 / dynhs-nback-bytes / flow-inj-1** — `inject_dynamic` using `#rule.suffix` (bytes) as a codepoint count: refuted — dynamic suffixes in the live path are ASCII; multi-byte custom suffixes via `add_rule` are not a shipped configuration. (This was my own pre-audit suspicion — also refuted.)
- **dynhs-personal-info-replacing-drop** — `_replacing` 0.15 s window dropping a second `@`-expansion: refuted (the flag no longer gates emission; emission is synchronous).
- **LLM-2** — backend switch mid-stream leaking the old curl: refuted (`cancel_streaming` reaches the in-flight task).
- **LLMBT-2** — `set_timeout(INFINITE)` mutating shared idle-timeout when no tooltip shown: refuted.
- **ADAPT-1 / vscode_bridge AX drops tooltip frame** — refuted (guarded path).
- **FLS-2 / KLS-1** — layout poll racing a second `regenerate()` / double deploy on resume: refuted (no overlapping deploy demonstrated).
- **MENU-DISPATCH-001/002** — per-item menu `fn` errors swallowed / partial-toggle rollback: refuted/uncertain — no reachable crash repro found; the menu surface is, as designed, individually `pcall`'d at the orchestration boundary.
- **i18n-get-failclosed** — `i18n.get()` nil → `:gsub` crash: refuted (`get`/`locale.get` are already fail-closed).
- **updater-menu-label gsub-nil / builder-missing-key-label** — refuted (fallback-chain protected / cosmetic).
- **healthcheck-reopen race** — uncertain, not substantiated.
- **F3** — `prediction_engine` reads min/max words with `or` not `tonumber`: refuted (a stored string is normalised upstream).

---

## 10. Recommended order of work

1. **F-CRIT-1** (physical F-key misfire — destructive, trivial fix) and **F-CRIT-2** (self-update dead — closure-nil, trivial fix). Ship each with its regression test (red→green); these are surgical and low-risk.
2. **F-HIGH-1** (prefix registration — a default feature is silently dead) and **F-HIGH-6** (corrupt-setting blanks the AI submenu — fail-fast hardening).
3. **F-HIGH-2/3/4/5** (MLX stream bound, robust quit KE kill, lazy Keychain decrypt, wire/retire the crash reporter).
4. The §6.4 meta-test (`no_local_task_after_closure`) + the §7 test-debt items — pure additions that pass now and harden against silent reverts.
5. Mediums/lows as capacity allows; the contested items are LOW hardening.

Per the project conventions, each fix should land on a branch with its regression test and be **live-tested before merging to `dev`** (`feedback_test_before_merge`); banners via `npm run fix:banners`; no co-author trailers.

*No source file was modified by this audit.*
