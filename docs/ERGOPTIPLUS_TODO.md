<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-23. Latest stable: [v1.0.6](https://github.com/adrienm7/ergopti/releases/tag/v1.0.6)
(tag 950979d19c, 2026-10-23). **Next step: issue #101 follow-ups on the Mac (Backlog).** Open work only: a finished item is removed, its lessons go to
[docs/memory](memory/README.md), and the history stays in Git
(`git log -p -- docs/ERGOPTIPLUS_TODO.md`). Item numbers are stable and never reused. Open
questions are in [questions-for-maintainer.md](questions-for-maintainer.md); per-work handoff files
are in [`docs/todo-agents/`](todo-agents/).

Tags: **[CODE]** software to write or adopt; **[CI]** only a hosted or native CI run qualifies it;
**[PHYS-W]**, **[PHYS-M]**, **[PHYS-L]** needs a real Windows PC, Mac or Linux machine.

**Generic caveat, stated once.** Unless an item says otherwise, native macOS and Linux qualification
and every physical-device acceptance remain OPEN and their qualification flags stay false; portable
tests, containers and software-supplied events are never physical evidence. The maintainer has a
Windows PC (physical tests on request) and a work Mac (reproduce on CI first, then at most one short
command); there is no Linux machine.

**Rules for every agent.** dev and main stay linear (rebase or cherry-pick, never `git merge`); a
release is a push to `main` carrying a `Release-As: X.Y.Z` trailer; Codex agents push to dev, so
fetch and rebase first, and preflight on `tmp/preflight-dev` with
`gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all`; a hook failure caused by someone
else's dirty file is waited out or bypassed with a private index plus compare-and-swap `update-ref`
running the hooks, never with `--no-verify`; never weaken a test; quality over speed. Run the pinned
ruff 0.15.8 and Prettier before every commit. After touching
a sealed Windows updater source, reseal with
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`. Procedures:
[COORDINATOR-MEMORY](todo-agents/COORDINATOR-MEMORY.md).

## Big item 1: Windows corporate networks and trust (items 62, 132)

- [ ] **62. WinHTTP transport for the managed remote downloads (decision of October 21).** [CODE]
      Microsoft's `System32\curl.exe` 8.21.0 (Windows image 20261018) no longer lists NTLM, so the
      managed transport refuses an NTLM-only company proxy on an up-to-date Windows
      ([memory](memory/windows-ahk.md#project-windows-system32-curl-has-no-ntlm)). Decided: use the
      Windows system HTTP stack (WinHTTP, through `WinHttp.WinHttpRequest.5.1` or equivalent), which
      follows the system proxy/PAC and does NTLM/Negotiate with the user's session, instead of
      shipping an extra binary (no new hash for scanners to flag). Replace the System32-curl
      dependency of the managed remote transport; until then the three NTLM cases stay NOT EXECUTED
      on images whose curl has no NTLM (f2cad38252, 90c42fbaa9). Also open: the WinHTTP route
      vector shape, the updater route/trust classification, the Job/child cleanup ack, and the
      PowerShell 5 fetch (`Source44`) exception with no known cause.
- [ ] **132. SignPath Foundation signing.** [CODE] Apply, integrate Windows signing, then delete
      `.github/ci/stable_windows_signing_exception.json`. Before applying, check the current
      conditions on signpath.org/foundation (open-source license, public repository, build and
      signing from CI with a maintainer approval per signing request, a published code-signing
      policy and privacy statement, a reputable project; the keystats-like metrics module and the
      hooks need a clear explanation). Decided 2026-10-22: apply now. Done: SignPath wired in
      `ci-windows.yml`, off until configured (61fb29d64d); README code signing policy and privacy
      (c6db589c76). Left (maintainer): apply, then set the variables and secrets; eligibility table,
      form answers and switch-on steps in the
      [handoff](todo-agents/signpath-foundation-application.md).
- [ ] **`ErgoptiPlus.exe` flagged by a corporate proxy (Netskope, Airbus tester).** [CODE] [PHYS-W]
      'ERR00: "ErgoptiPlus.exe" a peut-etre ete infecte par un virus' on v1.0.4; v1.0.0 and v1.0.3
      pass, so it is a threat-engine verdict on the new bytes or hash. Done: no hidden PowerShell
      clipboard stage (6d9eae1f94), own version resource (1965c2ffac), English metadata
      (965ff7569b), all in v1.0.5. v1.0.5 then passed once and was blocked two hours later: its
      content holds nothing v1.0.2 lacks, so the verdict is a sandbox and reputation one on a new
      unsigned hash. Done on dev: first launch extracts with tar.exe, no hidden PowerShell
      (3d2c78d7b7); build gate over the compiled exe (745f07fa51). Left: signing (132), the
      Microsoft false-positive submission (text and hashes in the handoff), the tester's retry,
      and the "keystats" naming (about 1 070 shipped strings) as a cross-driver rename to
      `keystats` (maintainer, October 22; one word, code, config keys and logs; queued until the
      parallel agents finish). Analysis,
      playbook and download matrix: [handoff](todo-agents/windows-exe-flagged-by-proxy.md).

## Big item 2: macOS Karabiner input reliability (items 31, 117, 140)

- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY
      timeouts since dev.155. The lease budgets are ordered so a slow CLI keeps the lease, every
      exit 73 names its cause, each deploy decision is one INFO line (recovery deploys wait for a
      typing pause; an unchanged `karabiner.json` is never republished), and the lookup that froze
      the main thread 13 s is gone (0292ec401d, e57f4cce77). Issue #100: on-time deadlines fired
      while the Ergopti menu was open, because `hs.task` streaming output is read only in the
      default run loop mode; an on-time deadline now waits for a `/bin/cat` echo before judging the
      worker (25411ee080, after v1.0.5). Reproduce on the Mac with these log lines; the only
      workaround is Configuration > Ergopti uses Karabiner > Off. Recovery deploys (28 of 33 on
      2026-10-19) cannot be reduced without fewer lease failures. Leftovers:
      [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md).
- [ ] **Dropped letters on macOS.** [PHYS-M] Unproven. Every consumed and never delivered key is
      reported ("typed key(s) swallowed", decisions only, never the key). Mac action: Debug > Report
      a bug right when a letter disappears, then compare with lease failures or Karabiner deploys.
- [ ] **31. HS-274 exact physical key accounting with an owned Karabiner runtime.** [CODE] Work
      packages WP3-WP10 (production consumer, headless producer v2, reproducible runtime, launchd
      ownership, owned configuration, native and real-Mac acceptance, enable and retire); media keys
      without a macOS keycode; VirtualHIDDevice incompatibility blocks owned mode with an
      explanation. Plan: [ADR 011](../static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md).
      Estimate 30-40 agent-days plus hardware time. The owned runtime stays dormant at default
      startup.
      Status 2026-10-24: WP3 largely done and dormant; WP6 Lua owner (`runtime_owner.lua`,
      `runtime_vhid.lua`, read-only ports) and WP7 owned deploy done, dormant behind the hidden
      `[karabiner] runtime = "owned"`; one-click Debug field checks shipped (lease, owned runtime
      dormancy, network, 30 s key accounting). Left: WP5 artifact manifest (hosted macOS run), a
      closer for another running Karabiner, the production capture owner, the Swift lease worker's
      owned CLI path, who starts the Console (Lua or `InstalledPhysicalSourceBridge`: duplicates
      otherwise), `UninstallWorker.swift`, the karabiner_model diff 16.0.0 to 9312593e, WP8-WP10.
      Next: the maintainer sends the `Field check result:` log lines from the Mac.

## Big item 3: Windows input-hook architecture (items 49, 91, 50)

- [ ] **49. Keyboard-hook order.** [PHYS-W] [CODE] AutoHotkey removes and reinstalls its low-level
      hook around SendInput, so hook order is undefined. Record the real order before and after a
      SendInput rehook; audit terminal capture against KLE, dead-key, digit, profile, tap-hold,
      combination and script-shortcut consumers (down, repeat, up, owner change while held, pause,
      reload); finish event-specific capture and replay and modifier ownership (source pin,
      authenticated event stream, non-hook handler conversion, chained/repeat semantics). Regenerate
      the DLL and manifest only through the official MSVC generator; check the patches in
      `docs/handovers/2026-10-12-dev-consolidation/` against the tree first.
      Measured on the maintainer's PC (Debug > Record keyboard hook order, 2026-10-24): before a
      SendInput the test hook is first; after it the AutoHotkey hook is first, so SendInput does
      reinstall the AutoHotkey hook in front of any hook installed earlier. SendEvent does not
      (item 50: hotstring output already uses SendInput at level 0, so it is exposed to this rehook). Consumers that rely on their own hook staying ahead of AutoHotkey's (the
      native nav owner DLL, item 91) lose that position at the first SendInput of the other paths.
      Consumer audit:
      [windows-input-hooks-items-49-50.md](todo-agents/windows-input-hooks-items-49-50.md). Left:
      decide per remaining SendInput consumer (text sender, HSE dispatch) whether it can avoid
      SendInput or make the consumer order-independent (single-hook/RawInput source, needs an MSVC
      DLL and manifest); the terminal-capture hardware list; the `SetWindowsHookExW` string in the
      exe for antivirus (the AV-surface gate allows it).
- [ ] **91. Simultaneous and first-key hold arbitration.** [CODE] Integrate with the
      single-hook/RawInput source (needs a genuine MSVC DLL and manifest pair); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **50. SendEvent against SendInput.** [PHYS-W] `SendMode("Event")` is set, yet the hotstring
      send/dispatch, text sender and config I/O still call SendInput. Measure expansions, pastes and
      predictions (latency, lost or interleaved keys) before choosing.
      Measured on the maintainer's PC (8 repetitions per scenario, all exact, 0 lost, 0 interleaved in
      both modes): expansion median 50.6 ms (SendInput) vs 136.8 ms (SendEvent), prediction 56.1 vs
      191.0 ms, paste 3.6 vs 3.8 ms, a concurrent key during the send 201 vs 282 ms. \*\*Finding
      (2026-10-24, real engine on the maintainer's PC): hotstring expansion already used SendInput
      (`HSE_DispatchMatch`); there are no native `Hotstring()` registrations left, so a hotstring's
      output is final on every driver and does not trigger another hotstring (the comment on
      `SendMode("Event")` described the retired native engine; `SendMode` now only affects `Send`,
      `Click`, `MouseMove`). One real bug fixed (0c85debc93): the Space tap-hold completed a trigger
      from its level-2 thread, and with another AutoHotkey hook SendInput fell back to SendEvent, so
      the burst re-entered the watcher and cascaded (final text `foo qbar qzz` instead of
      `foo qzy `); all engine output now goes at level 0. Open question (docs/questions-for-maintainer.md):
      deliberate hotstring-to-hotstring cascading would be a new feature on all drivers (124 of 2786
      shared replacements end with their own trigger, 131 with another trigger). Suspected separate
      defect: `_SpaceTap` emits its space with `TextPressKey("Space", "")`, which the buffer treats as
      an edit and resets both buffers, so an end-character trigger cannot complete from the Space
      tap-hold; check on the PC with the Space tap-hold on. Left: wire
      `test_hotstring_output_is_final.ahk` into `run_all.ahk`.
- [ ] **Per-layer layout composer.** [CODE] Decided 2026-10-22: the per-row number-row switches do
      not cover the October 13 request. Not started. Spec: split the layout into four layers (base,
      Shift, AltGr, Shift+AltGr), each with a dropdown that takes that layer from any layout (for
      example base QWERTY, Shift AZERTY, AltGr Ergopti, Shift+AltGr Ergo-L); add a shortcuts layer
      where the user says what a key gives under each held modifier (Ctrl+A when Ctrl is held,
      Win+A with Win, and so on); let the user tune each layer key by key, up to their own complete
      keylayout. Windows, macOS and Linux, from one shared declaration (the layout registry is
      `.keylayout`).

## Wave 2: mid-size work

In progress (agent), October 22:

- [ ] **Linux `[BS]x` pairs and correction n-grams (decision of October 21).** Align Linux on
      Windows and macOS, which push `x[BS]` and `yx[BS]` for every Backspace; update the test that
      pins the opposite and the shared corpus. Also L124 (a NUL histogram key merged by
      `json_group_object`), never checked on Windows. **In progress (agent).**
- [ ] **One path-separator owner, shared Lua and Linux.** [CODE] macOS is converted and guarded
      (b4711585e0, `test_posix_path_separator_owner.lua`). Left: about 25 shared and 8 Linux
      `[/\\]` sites
      (`rg -n '\[\^?(/\\\\|\\\\/)' static/ergopti_plus/_shared/lua static/ergopti_plus/linux --glob '!**/tests/**'`);
      keep the genuine Windows-path parsers (`program_parameter.lua`, `diagnostics/redact.lua`) and
      Linux `normalize_native_separators` (it runs before the shared root is known). With it, L105:
      the Linux injector's no-FFI `luv.sleep` and `os.execute sleep` fallbacks do not check the 2^53
      ms ceiling (d5c520ce94). **In progress (agent).**
- [ ] **Windows config policy (items 33, 42) and the TOML parse cost.** [CODE] Per sub-item in
      [config-policy-33-42.md](todo-agents/config-policy-33-42.md); 33: Windows keyboard binding
      publication from its real input owner, macOS Hotstrings category authority, Linux retired
      API-provider reader, macOS Karabiner obsolete-leaf intent, Windows retired cleanup
      projections; 42: explicit `--config FILE.toml` watcher admission, Windows full-save comment
      preservation. Parse cost: every document-mode write parses source, expected model and final
      candidate, and every start pays two builds after ready; reuse one parse per transaction
      before adding any cache. **In progress (agent).**
- [ ] **macOS Hammerspoon coexistence (decision 10).** Never kill the user's Hammerspoon; the
      launcher-owned instance gets its own config dir and single-instance guard; a second Ergopti
      instance is refused or recovered cleanly and its timers stop before its fatal dialog (the
      2026-10-21 log shows one aborting while its KC poll kept writing the shared log); a stale
      Ergopti-owned instance is replaced. With it: the at-rest cipher puts its plaintext in the
      `sh -c` argv. **In progress (agent).**
- [ ] **HS-274 orphan tools (decision 9).** `tools/diagnostics/hs274_*_test.py`,
      `hs274-native.swift`, `karabiner_candidate_install.py` lost their workflows: delete them if
      useless, or run them in a CI lane. **In progress (agent).**
- [ ] **macOS typing dashboard with a partial SQLite history (decided 2026-10-22).** [CODE] Show
      the partial counts, never cached, with an "incomplete history" mention (dev's choice before
      the Codex integration f0fb919379, which refuses the history instead); check that Windows and
      Linux behave the same. **In progress (agent).**
- [ ] **Versions window with a feed-only list (macOS, decided 2026-10-22).** [CODE] When the API
      gives no list, a click on the channel's newest release is handed to Sparkle (a page phase and
      21 locale strings); older releases stay refused with the warning. **In progress (agent).**
- [ ] **Tap-hold hold rows open the shared picker on Windows and Linux (decided 2026-10-22).**
      [CODE] Replace the seven-option « Hold → … » submenu (and a pair's hold: submenu on Windows,
      list dialog on Linux) with the shared action picker listing holdable actions only, as on
      macOS ([handoff](todo-agents/macos-tap-hold-action-picker.md)). **In progress (agent).**

Not started:

- [ ] **Ollama redirect policy and Go compile (decision 5).** [CODE] [CI] When a proxy or the
      native worker carries the request, an unresolved download host is left to it; literal
      private, loopback, link-local and CGNAT addresses stay refused, as do names that resolve
      locally to them. Patch the upstream `ValidateRedirectTarget` call in the macOS build recipe
      and reverse the assertion in `address_policy_test.go`. Every driver pins Ollama 0.40.4
      (662ed3714b, `OLLAMA_NO_CLOUD=1` b06c421923), but its Go side was never compiled: validate in
      the macOS Managed Ollama CI cells on a `tmp/*` branch.
- [x] **54/81. Last three native Windows menu rows.** Done in 02b63912f1 (local): census Windows
      0, macOS 0, Linux 0. The default-section, file and folder submenus are renderer template
      children (`MenuRenderer_TemplateChild` reserves, `MenuRenderer_FillTemplateChild` fills,
      `MenuRenderer_RepaintTemplateChild` repaints only a child the renderer still publishes); a
      kept callback after a rebuild is now refused before any write. Left: manual check 17
      (installed menus, default choice after restart); the shared-tree census is red on Linux only
      while `linux/ui/menu/rebuild_owner.lua:39` (another agent's uncommitted edit) is in flight.
- [ ] **Ergopti-started Ollama behind a PAC proxy.** [CODE] Resolve the PAC through the system for
      the model registry host (macOS CFNetwork `CFNetworkExecuteProxyAutoConfigurationURL` /
      SystemConfiguration; Windows WinHTTP auto-proxy; the Linux equivalent) and pass the resulting
      `HTTPS_PROXY` to the managed Ollama, instead of refusing the pull. A user-started daemon
      (Ollama.app, Homebrew, PATH) is covered by 2353a72eed. The maintainer's Mac uses a corporate
      PAC URL with Auto Proxy Discovery off and every static proxy (HTTP, HTTPS, SOCKS) off, so the
      PAC is the only proxy source: there is no static fallback to use.
- [x] **Menu clicks during a reload on macOS and Linux.** Done (b0fb0f585b, c280aa4eaf,
      8c4314524a, local): macOS holds a click during a reload, hands it to the new instance and
      replays it with the intended state; a stale menu resolves on a fresh tree. Linux replays a
      click on a retired row on the republished menu, and a hotstring reload rebuilds the tray.
      Shared intent rule `_shared/lua/menu/click_intent.lua`. Left:
  - [ ] Linux `perform_reload` logs "Hotstrings reloaded" and the local command answers
        `completed` although `load_all` refused (second value false, e.g.
        `personal-source-pending`).
  - [ ] [DECISION] A click on Reload during a reload is replayed in the new instance, so a second
        reload runs (Windows probably too, unchecked): should that row join the reload in flight?
  - [ ] Linux `actual Linux ordered-pair translations` (`test_key_combinations_menu.lua`) stops
        the runner without a result, already on HEAD.
- [ ] **AppImage self-contained, with update information.** [CODE] Build with
      `appimagetool -u gh-releases-zsync|adrienm7|ergopti|latest|ErgoptiPlus-*x86_64.AppImage.zsync`
      and publish the `.zsync` through the release assembly, receipts and verifier; bundle the C
      library and loader (or build on an older base) and prove it on the distro matrix (musl cannot
      run glibc binaries: say so), keeping the tray closure. Polish: with no keyboard device the
      notice still names input groups.
- [x] **Linux `copy_selected_path` in a file manager.** Done (8edb31edba, xclip sentinel
      d2a7bc9c5b, local): in a known file manager the action copies the selected paths. Left:
  - [ ] GNOME and KDE on Wayland do not name the foreground application, so the action there
        always opens the PRIMARY selection; identify the app through the AT-SPI active frame.
        Known limits elsewhere: Unicode IDNs and a zoned IPv6 are searched, not opened.
- [ ] **Linux X11 window list not proven on a real WM.** [CODE] `getAll()` (one `wmctrl -lp` plus
      `/proc/<pid>/comm`, fcb0168fb5) is covered by unit tests only (the WSLg WM publishes no
      `_NET_CLIENT_LIST`): add it to the Openbox e2e, and add wmctrl to the RPM and Flatpak
      dependencies.

## Cross-OS parity, centralisation and constants (audit of 2026-10-24)

Maintainer rule: the same behaviour on Windows, macOS and Linux wherever possible, unless there is a
good reason stated in the menu reason text; everything that can be common lives in `_shared`
(hexagonal architecture: rules and ports in `_shared`, OS code only in adapters); every constant,
delay, colour and label has one declaration. Source: [audit](audits/2026-10-24-cross-os-parity.md)
(row ids `H1`, `R3`, ... refer to it); entries are `PAR-1` to `PAR-85`, stable ids. Rows tagged I in the
audit come from grep counts: confirm them before starting. Decisions waiting for the maintainer: PAR-7
(macOS-only complex-key multiplier), PAR-17 (tap-hold defaults per OS).

### A. Behaviour that differs without a good reason (fix first)

- [ ] **PAR-1. Linux repeat key doubles at a word start and repeats spaces.** [CODE] Windows
      (`hotstring_match.ahk:505-520`) and macOS (`expander.lua:1053-1067`) need a non-boundary
      predecessor; Linux (`repeat_key.lua:202-225`) doubles any previous codepoint. Align Linux on
      the two that agree and add the shared repeat-key vectors (P2) first so the bug fails. Audit H1.
- [ ] **PAR-2. Shared repeat-key and idle-reset vectors.** [CODE] `hotstrings/vectors.json` has 45 vectors
      and none on the repeat key; `idle_resets_word` has no vectors either. Add
      `_shared/tests/corpus/hotstrings/repeat_key_vectors.json` and idle/word-reset vectors, replayed
      by the three E2E harnesses. Audit H2, H11.
- [ ] **PAR-3. One metrics master-switch key.** [CODE] Windows reads `metrics.metrics_enabled`
      (`config_io.ahk:1490`), macOS and Linux `metrics.enabled`; the latter is declared but unread on
      Windows. Move Windows to `metrics.enabled`, no migration (no users), delete the old key and its
      readers. Audit C1, S1.
- [ ] **PAR-4. One name set and one default for the WPM readouts.** [CODE] Three vocabularies
      (`wpm_widget_*`, `float_*`, `wpm_menubar_*` against `menubar_*`), defaults true on macOS and
      false on Windows/Linux, a dead Windows key `metrics_wpm_menubar_colors`, and three position
      stores. Pick one set, one default and one position store; add a single-source test. Audit C2,
      C3, S3.
- [ ] **PAR-5. Manifest `platforms` must match what each driver reads.** [CODE] `llm.trigger.disabled_apps`
      is declared hs only but Windows writes it; `llm.navigation.nav_modifiers` is declared
      hs+linux but Windows reads it; `mod_combos` is marked linux-only but macOS has it. Fix the
      declarations and add a gate that fails when a driver reads a manifest key declared for other
      platforms (extend `test-menu-manifest-keys-have-readers.cjs`). Audit C5, T1.
- [ ] **PAR-6. One base expansion-delay key.** [CODE] Windows and Linux use `[delays] default_sec`, macOS
      `hotstrings.expansion_delay`; the 750 ms value is "kept in sync" by comment only. One key and a
      single-source test in `test-defaults-single-source.cjs`. Audit H5, C7.
- [ ] **PAR-7. Decide and align the complex-key window multiplier.** [CODE] macOS doubles the expansion
      window after Shift/Alt keys (`keymap/init.lua:139,1862`); Windows and Linux do not, although the
      Ergopti layout is Shift/AltGr-heavy. Port it with vectors, or write the reason in the memory
      topic and the menu text. Question for the maintainer. Audit H3.
- [ ] **PAR-8. Word delimiters in config leaves on Windows.** [CODE] macOS and Linux store
      `terminator_states`/`terminators` as config leaves; Windows keeps a delimiter string in the
      override file. Move Windows onto the leaves and read one catalogue for the separator set (the
      Windows set is wider than Linux's three). Add terminator vectors. Audit H7, H8.
- [ ] **PAR-9. Linux sends `think:false` on Ollama requests.** [CODE] Windows and macOS disable thinking
      (`ollama_payload.ahk:88-123`, `api_ollama.lua:1432`); Linux only strips `<think>` text
      afterwards (`api_ollama.lua:234-250`), wasting tokens and latency on thinking models. Mirror
      the payload and add a request-shape test. Audit A1.
- [ ] **PAR-10. Linux package installs must not be offered updates.** [CODE] The background check and the
      prompt offer an update that `manager.lua:1501-1506` then refuses with an ERROR (which can open
      the error window). Apply the existing "a build that cannot update is greyed" rule to
      `installation_kind()` package installs in the check and the prompt. Audit U2.
- [ ] **PAR-11. Windows uninstall removes its Startup shortcut.** [CODE] `uninstall.ahk` never touches
      `A_Startup`; macOS and Linux remove their login item. Remove it, then add a test that fails
      while the shortcut is left behind. Audit U6.
- [ ] **PAR-12. Token-streaming reason contradicts the code.** [CODE] The row says Windows cannot show
      suggestions token by token but `ollama_streaming.ahk` and `prediction_exec.ahk:578` stream.
      Enable the row on Windows, or fix the reason in 21 locales. Audit M9, A19.
- [ ] **PAR-13. Persist the update ETag and release list on Linux.** [CODE] Windows and macOS keep them
      across restarts, Linux starts with a full request each time, which spends the 60 requests per
      hour quota. Persist through the Storage port with a vector. Audit U3.
- [ ] **PAR-14. Check-only fallback when the GitHub API is blocked.** [CODE] macOS falls back to the
      public Atom feed; Windows and Linux do not. Add the fallback for the update check (installs keep
      needing API digests) with a vector. Audit U4.
- [ ] **PAR-15. Hold threshold, one-shot timeout and hold-side parity.** [CODE] Fix the stale "ONE
      global" header of `tap_hold/defaults.toml` and `test-tap-hold-threshold-parity` (range only),
      pin exact values, make the one-shot timeout one value (Windows/Linux 2000 ms, macOS 3000 ms), and
      let Linux honour the right-ctrl hold side. Audit T4, T8, T10.
- [ ] **PAR-16. Tap-hold defaults merge per key on every driver.** [CODE] Linux's user `tap_hold.toml`
      replaces defaults wholesale, Windows merges per key, macOS has no user file. Merge per key on
      Linux, state the macOS reason in the SCHEMA row. Audit T5, C19.
- [ ] **PAR-17. Maintainer decision: shipped tap-hold and key-combination defaults.** [CODE] caps_lock,
      left_ctrl, tab and right_ctrl defaults differ by OS ("defaults are deliberate"), and macOS
      recommends one key-combination pair against three on Windows/Linux. Record the decision, then
      align or document in the manifest `reason_key`. Audit T2, T6.
- [ ] **PAR-18. Debounce default 500 / 200 / 500 ms.** [CODE] macOS uses 200 ms with no stated reason.
      Align or declare `default_per_platform` with a `reason_key`; extend
      `test-defaults-single-source.cjs`. Audit A8, C10.
- [ ] **PAR-19. Pause and resume switching of the layout.** [CODE] Only macOS has
      `pause_switch_enabled`, `on_pause`, `on_resume`; the manifest gives no reason. Either implement
      on Windows (emulation stop on suspend) and Linux (XKB group switch), or add the `reason_key`.
      Audit L7, C14.

### B. Missing features on one OS

- [ ] **PAR-20. Linux per-app metrics exclusion, and one key name.** [CODE] Windows
      `metrics_disabled_apps`, macOS `metrics.disabled_apps`, Linux none (the reason
      `metrics_extras_are_not_on_linux` only restates the gap). Rename to one key, implement on
      Linux through `focus_guard.lua`. Audit C4, S1.
- [ ] **PAR-21. Linux LLM parity batch.** [CODE] Add per-app trigger disabling (`llm.trigger.disabled_apps`),
      model delete, hardware/RAM ranking, warmup, min/max words and reset-on-navigation rows, and the
      AI-acceptance and autocompletion delay rows. Split into one commit per capability. Audit A4-A7,
      H10.
- [ ] **PAR-22. LLM telemetry on Linux.** [CODE] Write `events_llm` rows (generation, accepted,
      dismissed, tokens, cost) so the LLM dashboard tab is populated; today only counters exist
      (`keystats.lua:373-376`). Add a corpus replay. Audit A16.
- [ ] **PAR-23. Per-app LLM profile overrides on macOS and Linux.** [CODE] Only Windows has
      `llm.app_profile_overrides`. Port the rule to a shared module and the rows to the other two, or
      add the `reason_key`. Audit A3.
- [ ] **PAR-24. Windows preview-switch parity.** [CODE] macOS and Linux have the four `preview_*` switches; Windows has none for its own tooltip and `dynamic.enabled` is absent.
      Add the toggles and replace the descriptive-only reason. Audit H9, C8.
- [ ] **PAR-25. Linux magic-key editor.** [CODE] Linux reads the key from configuration only. Add the
      dialog (reuse the macOS/Windows editor contract) and drop `no_magic_key_editor_on_linux`. Audit
      H13, M11.
- [ ] **PAR-26. Linux keyboard-slot binding and personal shortcuts file.** [CODE] Stated gaps
      (`no_keyboard_slot_binding_on_linux`, `no_personal_shortcuts_file_on_linux`) with no scheduled
      work. Design the Linux surface or keep the reasons and say so in the docs. Audit M11.
- [ ] **PAR-27. Linux logger sub-files and a pre-config log.** [CODE] `sub_files.toml` has no Linux
      platform value; route hotstrings, llm and keystats, declare the pre-sink fatal record, and align
      the Windows/macOS topic sets. Audit G1, G2, G4.
- [ ] **PAR-28. Windows and Linux network field check.** [CODE] macOS has `field_check_network` (system
      proxy, PAC, HEAD through the managed transport); company-proxy failures are exactly what
      `AGENTS.md` warns about. Add the Debug row on the other two, per the field-test pattern in
      `AGENT_RULES`. Audit D3, D2.
- [ ] **PAR-29. Windows hook-health and Linux `running_apps` snapshot fields.** [CODE] The diagnostic
      schema has key-accounting for macOS and kanata/kernel fields for Linux but nothing for the
      Windows hook, and `running_apps` is missing on Linux. Add them with schema and parity-test
      updates. Audit D5.
- [ ] **PAR-30. Sign the Windows and Linux update assets.** [CODE] [CI] Only macOS verifies a signature
      (Sparkle EdDSA); Windows trusts the API digest, Linux a `.sha256` asset. Publish detached
      signatures and verify them in both updaters. Audit U1.
- [ ] **PAR-31. Linux layout install on pure Xorg.** [CODE] [PHYS-L] The converter writes
      `~/.config/xkb`, which Xorg ignores. Detect the session and install through the documented
      path or refuse with a clear message; surface Compose conflicts in the result. Audit L3, L4.
- [ ] **PAR-32. macOS and Linux nav-layer repeat count, pointer and wheel bindings.** [CODE] Reasons say
      "for now" (repeat count) or unsupported (pointer, wheel on Linux). Schedule or drop. Audit T12.
- [ ] **PAR-33. List one-shot Shift in the Linux picker and unify `sticky_*`.** [CODE] The Linux engine
      implements it (`tap_hold_engine.lua:105-110`) but the picker does not offer it; macOS names it
      `sticky_shift`. Audit T9.
- [ ] **PAR-34. Mouse metrics, event families and app-category store on Linux and macOS.** [CODE] Linux
      writes 4 event tables of 15; the `mouse` column exists with no capture; app categories live in
      three stores. Capture mouse, write window/system/session tables, one category store. Audit S2,
      S4, S8.
- [ ] **PAR-35. Windows decision on the `accented_letters` shortcut features.** [CODE] ahk-only without
      a feature reason. Keep with a `reason_key`, or move to a layout variant everywhere. Audit M12,
      L10.
- [ ] **PAR-36. Decide gesture modes and sensitivities beyond macOS.** [CODE] 70 macOS-only entries and
      the Windows-only absence of 2- and 5-finger slots have no reason. Add `reason_key` or implement.
      Audit M13, C11.

### C. UI-only gaps, reasons and docs

- [ ] **PAR-37. Give every genuine platform restriction a `reason_key`.** [CODE] 228 of about 380
      manifest entries are restricted and 14 carry a reason; 288 menu rows lack one (most are frames).
      Add a gate that requires `reason_key` on every feature entry and every non-frame row whose
      platforms are not all three, with a baseline lowered to zero. Audit headline 1.
- [ ] **PAR-38. Rewrite stale `platform_reason` texts.** [CODE] `llm_configuration_surface_is_not_on_linux`
      (Linux has the profile/trigger/display/navigation rows), `kanata` wording in two texts, and
      the `token_streaming` text (P12). One wording for the Linux engine. 21 locales. Audit M7, M8.
- [ ] **PAR-39. Regenerate `config.schema.json` metrics from the manifest.** [CODE] The schema requires
      `enabled`, lists dead keys and sets `additionalProperties:true`, so it validates nothing. Generate
      it and drop the permissive flag. Audit C15.
- [ ] **PAR-40. Unify user LLM profile storage.** [CODE] Windows/Linux `llm.user_profiles` (string),
      macOS `llm.profiles.user_profiles` (array). One schema. Audit C9.
- [ ] **PAR-41. One shortcut data model.** [CODE] Three models (16 legacy booleans, `keyboard.*` slots,
      `shortcuts.keys.*`) and OS-named ids. Move to action slots with neutral ids. Large; plan first.
      Audit C12, C13.
- [ ] **PAR-42. Retire the macOS `[features]` override layer.** [CODE] `config_overrides.lua` and the
      `loglevel` alias contradict the no-back-compat rule. Delete with tests. Audit C16.
- [ ] **PAR-43. Unify duplicated per-OS prompt strings.** [CODE] `menu.llm.*_prompt` against
      `menu.settings.*_prompt`, `ollama_port_*` against `mlx_port_*`. One key set, 21 locales. Audit I5.
- [ ] **PAR-44. Windows-specific reset error texts everywhere.** [CODE] Only Windows has
      `dialog.reset_defaults.{rollback,commit,acquire,reload_refused}`. Use them on macOS and Linux.
      Audit C20.
- [ ] **PAR-45. Notifications: one behaviour for toggles and refusals.** [CODE] `notify_feature` and
      `quit_refused` fire on macOS only. Decide and align. Audit N1, N2.
- [ ] **PAR-46. Route hard-coded visible text through i18n.** [CODE] Windows `TrayTip` (6 sites), French
      literals on macOS (`models_manager_mlx_hf.lua:1137`, `models_manager_mlx_download.lua:1402,1438`,
      `profiles.lua:211`, `personal_info_editor/init.lua:39-45`), Linux `SPECIAL_KEYS`, shared UI
      titles. Add the gate (P62). Audit N7, I6-I8, K6.
- [ ] **PAR-47. Extend `audit-translations.cjs` to Linux and `_shared`, both directions, unused keys.**
      [CODE] It scans Windows and macOS only. Add Linux, shared Lua/JS and an unused-key mode with a
      baseline; then delete the confirmed orphan keys (`apps.cloner.*`, `apps.encryptor.*`). Audit I2,
      I4, K7.
- [ ] **PAR-48. Review values equal to English in each locale.** [CODE] 263-385 per locale and about 30 in
      `fr` (`sg_actions.sticky_*`, `shortcuts.altgr*`). Triage through the i18n skill. Audit I3.
- [ ] **PAR-49. Fix stale docs.** [CODE] `SCHEMA.md`, `logger/SPEC.md` section 10-11 and `logger/README.md`,
      `windows/README.md`, `linux/modules/README.md` (updater is 5 files), tooltip README (macOS and
      Linux), `windows/modules/keystats/README.md:7`, memory notes "Linux has none yet" and "ONE
      global". Audit C19, G7, U13, S12, T2, T4.
- [ ] **PAR-50. Metrics suspend and reset-session rows on all three.** [CODE] Linux-only today with a
      weak reason. Offer on Windows and macOS. Audit S5, M10.
- [ ] **PAR-51. Uninstall failure dialog on Linux without zenity.** [CODE] KDE hosts get only stderr.
      Fall back to kdialog, then stderr plus notify-send. Audit U7.
- [ ] **PAR-52. Release-notes page on macOS and Linux.** [CODE] Confirm macOS opens
      `_shared/ui/release_notes`; wire it if not. Audit U5.

### D. Instrumentation and diagnostics

- [ ] **PAR-53. Bring HotPath-style slow-segment logging to macOS and Linux.** [CODE] Windows declares
      31 segments, macOS 2, Linux spans exist but only time at DEBUG. Always time on Linux, add the
      inventory test for both Lua drivers, then cover the typing path. Audit P1, P2, P6.
- [ ] **PAR-54. PhaseStats and child-process timing on Windows and Linux; CPU in boot profile on macOS and
      Linux.** [CODE] Mirror macOS `process.*` phases. Audit P3-P5.
- [ ] **PAR-55. Crash reports: one content, one cap, one notice.** [CODE] macOS content and notice wins;
      Linux caps at 20, Windows no cap. Share the format and retention policy with vectors. Audit D6,
      R31.
- [ ] **PAR-56. Log-volume metrics on all three drivers.** [CODE] Nothing counts lines per level or
      dropped/collapsed lines. Add counters to the evidence record. Audit G6.
- [ ] **PAR-57. Retention read from timings on Windows.** [CODE] `logger.ahk:112` is a literal 14. Read
      `Timings` and extend `test-logger-scalars-single-source.cjs`. Audit G5.

### E. Tests and corpora

- [ ] **PAR-58. Windows consumer for the shared Lua contracts.** [CODE] 105 contracts (about 940 cases)
      run on macOS and Linux, none on Windows. Convert the highest-value ones (`config_scope_*`,
      `toml_*`, `menu_*`) to JSON vectors and replay from one AHK consumer per family. Audit test
      item 11, section 14.
- [ ] **PAR-59. Corpus replay gaps.** [CODE] `http/get_redirect_vectors.json` (Windows, macOS),
      `native_presentations/original_captions.json` (Windows), `config_outdated/file_warning_vectors.json`
      (macOS, Linux), `route_plan_vectors.json` (Linux, Windows), `document_lease_contract` and
      `download_document_contract` (macOS). Audit R35, C21, section 14.
- [ ] **PAR-60. Hotstring `family_samples.json` plus chaining, synthetic-output and erase vectors.** [CODE]
      Two or three expansions per manifest family, replayed by the three E2E harnesses. Audit H15,
      test item 13.
- [ ] **PAR-61. Tap-versus-hold decision corpus.** [CODE] `tap_hold/vectors.json` pins accessors only; add
      decision vectors (tap, hold, roll, one-shot) replayed by the three engines. Audit T15.
- [ ] **PAR-62. Contract tests for shared modules no test requires by name.** [CODE] `layouts.composer`,
      `hotstrings.personal_model`, `keystats.text_migration_runner`, `menu.click_intent`,
      `llm.config_guard` and five more. Check corpus coverage first. Audit R36.
- [ ] **PAR-63. Remaining 2026-10-18 test items.** [CODE] Windows dynamic hotstrings, Linux personal-info
      editor, Linux model records and downloads, keystats corpus on Linux, toggle-level gaps
      (`preview_autocorrect_enabled`, `direct_access_digits`, `reset_on_nav`, `rolls.left_arrow`,
      `french_magickey.text_expansion`, `chatgpt_url`), Windows root runners and the
      `test-driver-tree-parity.cjs:19` exclusion. Audit section 14.
- [ ] **PAR-64. Installed-record and layout corpora on Windows.** [CODE] Windows replays 1 of 4 files.
      Replay extensions, preservation and updates. Audit L6.

### F. Centralisation and hexagonal architecture (value order)

- [ ] **PAR-65. Extract the LLM request plan to `_shared/lua/llm/request_plan`.** [CODE] Prediction
      orchestration is 3007 / 3927 / 2108 lines in three drivers and only prompt, parser, rewrite and
      tone are shared. Pure state machine with HttpClient, TimerScheduler and TooltipRenderer ports and
      a request-transcript corpus. Phase it: debounce and batching first. Audit R1.
- [ ] **PAR-66. Move the menu frame builders to `_shared/lua/menu/frames`.** [CODE] Six identical bodies
      in macOS `menu_*` and Linux `menu_builder.lua` (5648 lines); frames from a state snapshot,
      replayed by `corpus/menus`. Audit R2.
- [ ] **PAR-67. Shared keystats query catalogue and walker.** [CODE] About 85/73/66 SQL statements and
      three walkers; named queries in `data/db/queries.sql` with codegen, walker in
      `_shared/lua/keystats/walker.lua`, AHK replays `aggregation_vectors.json`. Audit R3.
- [ ] **PAR-68. Hotstring override parser into `_shared` on `toml_codec`.** [CODE] macOS hand-rolls 190
      lines that Linux does in 25. Vectors for `[__global__]` passthrough. Audit R4.
- [ ] **PAR-69. Shared ownership protocols.** [CODE] `scope_owner.lua` (5 methods copied 6 times,
      `S`/`L`), `storage_owned.lua` (104 identical windows), shared `error_dialog/core.lua`, and
      `owned_timer` for the dependency checkers. Do these four as small commits. Audit R5-R7, R14.
- [ ] **PAR-70. Factory per macOS/Linux infra shim.** [CODE] `native_presentation`, `manifest_reader`,
      `manifest_menu`, `timings`, `text_cipher`, `text_migration`, `config_backup`, `locale`,
      `user_code` take `{platform}` and live in `_shared/lua`. Audit R15, R28, R32.
- [ ] **PAR-71. Finish the route-plan rollout and make `proxy_policy.json` the codegen source.** [CODE]
      `route_plan.lua` has no production consumer on Windows or Linux; policies are hand-typed in Lua,
      Python, Go and generated Swift. Audit R12, C21.
- [ ] **PAR-72. Shared registries and catalogues.** [CODE] `layout_registry` state machine into
      `layouts/registry.lua`; `shortcuts/catalogue.lua`; shared gesture `direction.lua` with boundary
      vectors; `llm/temperature.lua` with vectors; healthcheck report core; `llm/agent_learning_store`.
      One commit each. Audit R8, R9, R13, R20, R21.
- [ ] **PAR-73. Collapse generated per-driver artifacts and tap-hold timeout duplicates.** [CODE]
      macOS/Linux `features_manifest.lua` (67% common), `action_catalogue.lua` (81%),
      `config_template.toml` (90%); `[hs_timeouts]` repeated per key in `defaults.toml`. Audit R22,
      R24.
- [ ] **PAR-74. Config-key and command-id constants by codegen.** [CODE] Generate constants from
      `config.schema.json` and `menu_manifest.json` for AHK, Lua and JS; lint raw literals such as
      `private_filter_enabled`. Audit R10.
- [ ] **PAR-75. Shared Lua helper modules and a redefinition lint.** [CODE] `table_util`, `path_util`,
      `shell_quote`, URL-encode, trim (54 inline patterns); lint forbids redefinition. Audit R16, K10.
- [ ] **PAR-76. Long refactors, plan before starting.** [CODE] Generate the AHK config-migration op table
      from `migrations.toml` (R17); extract menu row-ordering rules to data (R18); pure hotstring
      injection plan (R26); FileSystem port spec for lease/atomic write (R33); canonical `.keylayout`
      parser (R23); Windows updater `check_session`/`rate_limit` vectors (R25).
- [ ] **PAR-77. Remove platform branches from shared UI JS.** [CODE] `healthcheck/script.js:57`,
      `layout_manager/script.js:116`, `onboarding/script.js:396,713`, `program_parameter.js:59-66`;
      the host passes capability flags and one `program_parameter` source. Audit R19.

### G. Constants, delays, colours, labels (value order)

- [ ] **PAR-78. Timing registry liveness and duplicate-name gate.** [CODE] 41 of 145 keys have no reader,
      111 constant names are defined in more than one file (38 with different values). Add
      `tools/test/test-timings-registry-liveness.cjs` and a duplicate check in
      `test-keystats-timings-single-source.cjs`; prune or wire the unread keys. Audit K2, K1.
- [ ] **PAR-79. Replace repeated timer literals with registry keys.** [CODE] `STALE_TEMP_MS` x5,
      gesture poll `-100` x6, safety flush `-2000` x3, `DEFAULT_TIMEOUT_MS = 30000` x4,
      `LONG_SESSION_THRESHOLD_MS` x3 JS, `TAP_WATCHDOG_INTERVAL_SEC` 5 against 2, `PUMP_INTERVAL_SEC`,
      Swift `usleep` literals. Gate: no numeric literal in `SetTimer/Sleep/doAfter/setTimeout`
      with a baseline, hosted in `test-fast-timer-inventory.cjs`. Audit K1.
- [ ] **PAR-80. `[limits]` section for byte caps.** [CODE] `MAX_OUTPUT_BYTES` 65536 in 3 files and
      similar in 6; gate in the registry test. Audit K3.
- [ ] **PAR-81. Theme tokens and palette codegen.** [CODE] 810 hex literals, 19 `--accent` declarations,
      the hotstring palette typed in three drivers, byte-identical `macos/ui/download_window/style.css`
      against `_shared`. Create `_shared/ui/theme.css` and a native-theme TOML; codegen the palette and
      retire `test-color-presets-parity.cjs`; lint "hex literal outside theme" with a baseline in
      `lint-conventions.js`. Audit K5.
- [ ] **PAR-82. Hard-coded UI string gate.** [CODE] New `tools/test/test-no-hardcoded-ui-strings.cjs`
      (TrayTip, MsgBox, alert, title literals fail unless allowlisted; reuse
      `tools/lint/audit-gui-titles.cjs`), including the Linux `install.sh` echo table. Audit K6, I9.
- [ ] **PAR-83. Identifiers and hosts in one file.** [CODE] `_shared/data/identifiers.json` via codegen
      for `ErgoptiPlus.ahk/.exe/.app`, bundle ids, service names, GitHub/Ollama/HuggingFace hosts;
      extend `test-repo-url-single-source.cjs` to hosts and ids. Add the `ollama_install.sh` port to
      `test-ollama-port-single-source.cjs`. Audit K9, K4.
- [ ] **PAR-84. Closed enums for reasons, phases and log tags.** [CODE] About 189 `reason`, 56 `phase`
      and 62 `[TAG]` literals plus the evidence-record field names (not censused: do that first).
      Extend `codegen-contracts-json.cjs`; gate in `test-logger-scalars-single-source.cjs`. Audit K11.
- [ ] **PAR-85. Tooltip dequeue and ring constants.** [CODE] `dequeue.js` 0.2/0.05 against `dequeue.lua`
      0/0, `RING_SIZE` 64 against 32, "mirrored" comment at `tooltip/constants.toml:398`. Single-source
      test in the tooltip family. Audit K2.

## Backlog (one line each)

Added October 22 (from the agents' reports; details in their commits):

- [ ] **macOS swallowed-keys check on v1.0.6.** [PHYS-M] The fixes (03a2c2fa4b, d026f3e024,
      a414e83fb7, 19fa9fa872, 89cbcae90b, 9b500a9e8c, c21e920d7e, bb6fcc2cc2) shipped in v1.0.6;
      they need a Mac day of typing with the `key_event_health` counters; handoff in
      [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md).
- [ ] **Keystats rename leftovers.** [CODE] The rename is done (180a53e4de, 1 283 files, 579 paths). Left:
      the comment in `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` (a compiled
      script: recompile on a Mac); declare each persisted name once and make tests read it instead
      of pinning spellings, so the next rename is cheap.
- [ ] **Issue #101: Mac follow-ups.** [PHYS-M] Fixed, to confirm on the Mac with the next release:
      ATS key so the URLSession can fetch an `http://` company PAC (c0c29cd8ab); direct route when the
      PAC lookup names no route (719c7fcd76); no retry of a refused route (ace928dc1c); the lookup now
      names its failing step (363a63f79d: `native_proxy_budget`, `native_pac_download`, ...); lease
      line cap judged per line (5deb892d58); Ollama 412 upgrade request shown (08aaeaf3c2);
      diagnostics PAC probe on the three OS (f798aae1f9); one-click Debug checks (lease, owned
      runtime, network, 30 s key accounting). Left: (1) read the Mac's next log lines `Slow ingest
tick`, `Slow preferences save` and `Field check result:` to name the dominant main-thread
      phase before slicing it; (2) an explicit proxy override field; (3) local server probes (oMLX,
      Jan) all answer "Network request failed"; (4) `keymap/utils.lua` ignored-window TTL probe
      (1 s): bound it only after measuring the AX call time (secure-field cache); (5) rebuild the
      inverse oracle of `macos_native_http_receiving_facts_test` (red since 719c7fcd76), compile the
      Swift on macOS CI, add Go table cases for the new stages; (6) the network check's digest step
      is skipped (HEAD only).
- [ ] **macOS input follow-ups (swallowed keys).** [CODE] Done: late keys pass through in tap*keys,
      script_control and modifier_injector (ed2d9fe65c); AXValue read once per typing burst
      (34765cde7c); no error window for a lease failure that recovered within 60 s (fcf4af85dc);
      `key*\*` counters in the Markdown diagnostics (6f2daed2e5). Left: reuse the lease token on
      recovery so the 743 KB karabiner.json is not rewritten each time (needs the token ledger
      redesigned and checked on a Mac).
- [ ] **Linux correction parity remainders.** [CODE] Done (06bbbe5985): Backspace pops the word, erased
      n-grams get `e`, synthetic output chains. Left: erased and synthetic vectors in the shared corpus
      (needs the AHK and macOS replayers); Windows word separators are wider than Linux's three.
- [ ] **Windows typing dashboard partial history remainders.** [CODE] Done for Typing (0010418934,
      reader NUL keys a6a4274a8d); left: the mention on the Apps dashboard and the Edge fallback
      (no WebView2), which does not open on an incomplete read.
- [ ] **Windows updater -File workers: real update check.** [PHYS] Install a build with 5d6beccf83
      by hand, then update from it to the next release: the exe is replaced and restarts, the
      three scripts are in `%LOCALAPPDATA%\Ergopti\vendor\`, the PowerShell command line shows
      `-File ...ergopti_updater_staging.ps1` and no `-EncodedCommand`.
- [ ] **Config policy remainders (33, 42).** [CODE] 33: macOS Hotstrings category authority and
      Windows `api_entries` per-row validation; 42: the `--config FILE.toml` watcher (needs a
      Linux host). Parse cost: the schema journal still parses the candidate on its own; profile
      the tokenizer.
- [ ] **Linux AI off remainders.** [CODE] The menu switch-off does not stop an app-started
      `ollama serve` nor a running model download, as pause does (the agent auto mode and bound
      `llm_*` chords are a maintainer question).
- [ ] **HS-274 vendor-header C++ tests.** [CI] stream-protocol, -inventory, -source, -clock,
      key-state, baseline-v2 and accept-test need the Karabiner-Elements 9312593e vendor headers:
      run them in the future `remap-runtime-build.yml`. The portable tests run in js-0453
      (17d2f1a7fd). The `hs274_persistence_test.py` cases are dead (their fixture moved into
      `test_physical_history_persistence.lua`): repair or retire them.
- [ ] **Linux CI installs packages inside short test steps.** [CI] 25 Linux steps still run apt
      inside a test step with a short timeout (a649f2930a moved the network-ai one out; f1b5c7f684
      fails a stalled mirror within 30 s; 409d0faac7 moved the window-switch one); move the
      installs to their own steps (about twenty left).
- [ ] **CI partial rerun refused by the site verdict.** [CI] `gh run rerun --failed` makes the site
      verdict fail with "Build receipt differs from selected writer attempt", so only full runs
      can be retried today; admit a rerun attempt of the writer.
- [ ] **macOS "Quit did not end both processes within 10 s".** [CI] Seen once in the October 23
      CI, passed on rerun; find the cause (green run 39889203911 at e0dd6629e4).
- [ ] **History hygiene of October 22.** Commits with another agent's message, already on dev:
      c6db589c76 (macOS cipher argv fix under a README subject), 90da28c725 (config snapshot test
      under a CI subject), 18ca214ead (also deletes ten handoff files), 6d9c659 ("applied for now"
      instead of "apply now"). Keep, or rewrite dev once with a lease: maintainer's call.
- [ ] **Signing and antivirus: maintainer actions.** Apply to SignPath at signpath.org/apply (the
      HubSpot form does not load in an automated browser; answers in
      [signpath-foundation-application.md](todo-agents/signpath-foundation-application.md)), submit
      the Defender false positive, and ask the tester for the exact block page.

- [ ] **36. Windows updater production coupling.** [CODE] The "original23" collector stays inactive
      (`docs/handovers/2026-10-12-group6-ci/INACTIVE-ORIGINAL23-SOURCE.md`) until enrolled.
- [ ] **62 (macOS and Linux).** [CODE] macOS full request-URL PAC/WPAD, fallback and redirects for
      uv, HTTPX/HF/Xet and outgoing Ollama Go; `-1202`/SSL-9813 after a trust add and the 15 s
      trust-removal timeout; forward the Ollama daemon log directory (output goes to `/dev/null`).
- [ ] **115. Portable JS suite on the Windows host.** Install the pinned Node 22.22.2 and `pwsh`,
      rerun, fix only a red that survives.
- [ ] **CI duration** ([target](memory/workflow-and-verification.md)). Validate the parallel
      `package-flatpak` job (6310b316bf: green, install cells start after Build, release-like run
      lists the `.flatpak`), then build the Linux packages per format in parallel. Windows
      Integration adds 4-5 min on the critical path (three lots); the macOS lane (about 58 min) must
      stay within the five-runner budget.
- [ ] **CI structure.** [CODE] Elapsed time per step, suite and test with a slowest-test summary;
      live Windows unit-log progress.
- [ ] **Test parity across the drivers.** [CODE] Continue the
      [parity audit](audits/2026-10-18-test-parity-audit.md): Windows dynamic hotstrings, verbatim
      duplicate Lua test files, absence ratchets, one tidy `tests/` tree.
- [ ] **Neutral installation.** [CODE] Check that the shipped defaults enable no layout emulation,
      system layout change or number-row inversion on the three drivers.
- [ ] **5.** [CODE] Linux layout and number-row scope participants composed with the real runtime
      producers; Linux/macOS numeric-owned Script aliases need an explicit snapshot contract.
- [ ] **102.** [CODE] A refused personal file's row caption shows its raw entry count as if active.
- [ ] **116. Guided third-party validation report.** [CODE] Isolated timer/Karabiner/Shortcuts/Brew
      checks and package provenance.
- [ ] **131.** [CODE] macOS `SMAppService` cannot expose the registered bundle URL; legacy
      ownership unqualified.
- [ ] **138.** [CODE] Three native daily-log collectors (a 64 KiB / 50-entry tail is not a day);
      GitHub field editability.
- [ ] **139. Personal identities in logs.** [CODE] Free-form text not proven safe; historical logs
      unchanged; attachment URL revocation unestablished.
- [ ] **141.** [CODE] AI submenus (servers, API entries, profiles) under a newer configuration get
      the same greyed cause as the other rows; recheck the retained callbacks.
- [ ] **142 gaps.** [CODE] Windows refuses "busy" during a pending reload instead of queueing;
      Linux reloads hotstrings in process; the Windows client does not hash-check the driver.
- [ ] **13/35.** [CODE] Enrol the complete guardian acceptance collector in main CI.
- [ ] **93. Linux ordered pairs.** [CODE] Saved Xi runtime/staging packet, `libxi-dev`, XKB/XI2
      server state join.
- [ ] **97/98.** [CODE] Native physical-position capture, all-owner collision admission, star
      setting migration; Linux identity needs the MediaStore device contract.
- [ ] **106.** [CODE] Genuine Apple Shortcuts invocation with bounded cancellation.
- [ ] **107.** [CODE] macOS forced output, Linux input+XI2+writer join.
- [ ] **108.** [CODE] Item 97's collision/source/modifier/output joins.
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible
      Variables/KeyHistory snapshot.
- [ ] **113.** [CODE] Sales-page placeholder rows; regenerate GIFs
      (`npm run gifs -- personal-hotstrings screen-time ai-predictions`).
- [ ] **46/47/48.** [CODE] Windows managed AI private UI assembly not adopted (rejects the default
      `localhost` URL); 17 baseline FFI failures in the Lua 5.4 authenticated private-file fixture;
      broad Ollama process termination on macOS (120) stays debt.
- [ ] **macOS `ui/changelog` `asyncGet` follows redirects.** [CODE]
- [ ] **L115.** [CODE] Provider error envelope guard: the fixture prints the swallowed traceback
      (1f103733aa); cause unknown.
- Optional, not planned: XKB angle-name gaps and raw-input grammar (L118-L120); concurrent JSON
  backup replacement (L52, L60); ALSA fallback (L63); multi-group XKB recovery (L100); a real
  `Comments` exe field through a version `.res` resource.

## Maintainer checks

Record the commit, OS build, scale, layout and emulation state; report pass, fail or not executed
per line. Use a disposable profile (`paths.toml` pointing at a scratch folder) for anything that
writes configuration. Reload the driver from the working tree for dev-only fixes.

### After v1.0.5 (actions)

- [ ] Post `/retest` on AppImage/appimage.github.io#10422 from **PowerShell** (Git Bash rewrites
      it): `gh pr comment 10422 -R AppImage/appimage.github.io --body '/retest'`; read the bot's
      screenshot (status window and tray menu, 98d41e630b) and warnings.
- [ ] Airbus tester (Netskope): retry the `ErgoptiPlus.exe` download and report T1-T4
      ([matrix](todo-agents/windows-exe-flagged-by-proxy.md)).
- [ ] Give the v1.0.5 SHA-256 to VirusTotal; submit it to Microsoft Defender as a false positive if
      flagged.
- [ ] Number-row testers (October 13 and Discord): retest with their exact setup (native layout,
      emulation and row switches, CapsLock, outputs in the three modes); fix only a confirmed
      discrepancy. Key-combination testers (October 15): confirm c89d74eb, else ask for
      `[KeyCombinations] Pair`, `AHK drop detected` and `Menu command refused` lines.
      Priority-100 tester: confirm uppercase output (cf29c35e5f).

### Windows PC

Fixes of October 22 (dev, after v1.0.5):

- [ ] **Win+S open target** (ec1c4105d9, open-target): select `192.168.1.1`, `localhost:3000`,
      `example.com`, `ada@example.com`, `https://example.com/page.`, an existing file and folder
      path (with spaces, quoted or not), `~/Documents`, `%APPDATA%`, a missing path (notice, no
      search), `HKEY_CURRENT_USER\Control Panel\Desktop` and `HKCU:\Software` (Regedit),
      `ms-settings:display`, `notes.txt` (asks for a full path), `bonjour le monde` (web search).
- [ ] **Backspace word start**: Windows Terminal with Claude Code, Enter on an empty prompt, `ab`,
      two Backspaces, `c` offers « c’est »; Backspace past the empty prompt then `C★`, `J★`, `Ct★`;
      `ab`, 5 s pause, two Backspaces, `c★` expands; `ab`, one Backspace, `c★` does nothing; Notepad
      Ctrl+Backspace then `c★`; browser Ctrl+L, Backspace, `c★`; AltGr+Backspace on an
      AZERTY-style AltGr and a Kana layout acts as Backspace.
- [ ] **Tap delay row** (0d5bd45a59): Tap-Hold > a key > "Tap delay: N ms" is a plain row whose
      click opens the input box with N; OK saves and reloads.
- [ ] **Keyboard group restore and clear** (c80bd4dcf2): Shortcuts > a modifier group > « Tout
      effacer », then « Restaurer les valeurs conseillées »; only that group changes.
- [ ] **Tap-hold and key-combination pickers**: a key's and a pair's « Tap → … » open the shared
      picker; « Hold → … » opens it with holdable actions once the Wave 2 item lands.
- [ ] **Versions tabs** (fb78c66d1f): switching channel tabs repaints at once, no spinner; Retry
      still fetches.
- [ ] **Window titles** (df0b4776c7, a22b920373): the unused-settings window and the API endpoint
      dialog show the brand once.
- [ ] **Private-browsing metrics filter** (fb877dbd51, af404db937): click it during startup and
      while a configuration change applies; it toggles once, no error window.

Standing checks:

1. **Seven-page wizard** (item 7): fresh, existing and moved folder; every page, Cancel, Finish then
   restart, rerun; No against recommended choices; WebView rendering and persistence; the layout
   step's controls never reload the UI.
2. **Clear and Restore** (item 5): per category and global, then restart; unknown and outdated keys
   preserved; personal hotstrings unchanged by Restore; exact backups; an external write refused.
3. **Number row and key combinations**: on AZERTY, US QWERTY and Ergopti, each ordering and
   edge-key choice, each row emulation switch, an inert choice ticked, greyed and suffixed « — non
   appliqué », the ² key; a pair assignment saved and reloaded.
4. **Installed build**: install, start, Diagnostics cold and reopened (UIA/render probes, cold
   WebView), Quit during a keystats flush, File/Exit and Windows shutdown with exit code 0;
   uninstall greyed on a source run. Item 101: capture the watcher/debt state if `watchers=0`
   recurs.
5. **Item 51 matrix**: arrows and both Shift+Tab over a multi-slot prediction move the marker once
   and wrap (also after reload, with `nav_modifiers = ctrl`, with a tap-hold Tab); footer "⇧G + Tab
   ou ↑/←"; bubbles and delayed expansions with emulation off and on; no "eeee"; one clipboard-log
   row per Ctrl+V; AltGr+Entrée/Suppr/Retour arrière/Échap script actions; AI menu; « Revenir à
   cette version » keeps a backup.
6. **Items 19, 49, 50**: tooltips near screen edges on Windows 10 and 11 at several DPI scales; hook
   order around a SendInput rehook; the send-mode measurement.
7. **Hotstrings** (items 34, 37, 102, 104, 105, 129): follow
   [GROUP2-WINDOWS-TODO](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md); with no
   Ergopti layout installed the shipped pack, suffix rules and magic-key repeat appear once;
   `update` never proposes `date`.
8. **Layout switching** (item 38): AZERTY with emulation to native Ergopti and back keeps AltGr
   usable without a reload, also on an AZERTY-style AltGr (LCtrl+RAlt) and a Kana layout.
9. **Touchpad registry** (item 13): values restored after OFF and removal; kept after a refusal.
10. **Managed network** (item 62): the twelve steps of the
    [Group 6 Windows handover](handovers/2026-10-04-group6-windows/README.md) behind a company
    proxy.
11. **Menu-click replay**: tray toggles clicked during a slow startup that requests a reload all
    apply in the successor, with no error toast.
12. **CapsWord auto-off**: delays, the eight default delimiters, each pointer kind, the LAlt then
    CapsLock trigger.
13. **AI off (#97)**: no local server sweep, no AI hotkeys, a refused AI hotkey leaves the driver
    running. Item 143: time the AI toggle behind an unfinished startup (3.05 s on the smoke).
14. **Prediction chord (item 112)**: in Notepad each slot's modifier+digit inserts that prediction
    and its correction form; the shortcut column is right-aligned and muted.
15. **Local reload command (item 142)**: `tools/control/request_driver_reload.ps1` idle, paused and
    during a reload ("busy"); one driver afterwards.
16. **Item 114**: observe the resident process during a prediction-key (1-5) or AltGr+Enter stall
    and collect the Notepad stale-admission diagnostics before changing anything.
17. **Items 30, 46-48, 54/81, 63, 73, 88, 96-98, 107, 108, 125, 138**: physical magic key under
    emulation; a real local model (chat, download, consent, pause/resume/shutdown, HTTPS behind the
    system proxy); installed menus (captions, unavailable reasons, state after restart);
    brightness up/down and refusal without a backlight; physical-key labels after a locale change;
    prediction tooltip typography; emulation picker precedence and dead-state output; chosen
    physical positions and arbitrary outputs including dead keys; number-row and magic-key
    shortcut delivery; free-text translation dialog; diagnostic export copy, write, reveal and
    browser.

### Mac

- [ ] **Issue #100 retest** (after v1.0.5: 2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and
      a PAC proxy, enabling the AI downloads the model; with the Ergopti menu held open, no lease
      timeout.
- [ ] **Issue #99**: `memory_pressure | tail -1` during lease errors; oMLX listed (DEBUG
      line `Local server 'omlx' probe answered ...`, else
      `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models` and
      `lsof -nP -iTCP -sTCP:LISTEN | grep -i omlx`); `Ollama bootstrap failed (exit=137)` with an
      external Ollama; which login item starts the second Hammerspoon; declining the download
      opens no error window. Details:
      [issue99-ai-startup-updater.md](todo-agents/issue99-ai-startup-updater.md).
- [ ] **Fixes of October 21-22**: tap and hold pickers (steps in
      [macos-tap-hold-action-picker.md](todo-agents/macos-tap-hold-action-picker.md)); tap delay
      row opens the AppleScript dialog, « Use global delay (…) » right below; Shortcuts group
      restore/clear; Ctrl+S open target (as on Windows, registry keys answer « Windows only »);
      Backspace word start (Terminal Return, `ab`, three Backspaces, `c★`; TextEdit
      Option+Backspace; Safari Cmd+L).
- [ ] **Item 38**: no "Lease-bound input startup failed" or spurious "Layout poll detected change";
      Right Option + Return/Delete/Backspace/Escape run script actions; no Python or Rosetta notice;
      MLX behind a proxy; Versions rollback.
- [ ] **Installed app**: 7 (Cocoa Finish, folder disagreement, native restart), 116 page, 120
      provider menu, 122 Diagnostics focus, 123 shared export, 127 VS Code bridge retirement, 13/35
      guardian registration and retirement on both architectures, 24 Login Items, 43 « Retirer les
      anciennes règles » on an upgrade, 44 CapsWord pointer cancellation, 126 trackpad gestures,
      111 two displays, 30 magic key on ISO and ANSI, 46-48 and 88 a real local model and the
      tooltip typography, issue 94 (tap-hold menu refusal, symbol-wrap clipboard, ISO/ANSI captured
      once), 119/130/136 MLX PAC download, code 74, Homebrew live upgrade.
- [ ] **Shell and file edge cases**: `pipefail` and `printf %b` under bash 3.2, the native HTTPS
      downgrade refusal, `hs.fs.attributes` on a FIFO, the read-only dashboard with a hot journal.

### Linux (no machine available)

Wizard (7) on Wayland, physical input, installed-daemon restart; real kernel capture (93); magic
key grab, injection and hotplug (30); tap delay row (zenity/kdialog), group restore/clear, open
target, Backspace word start (GNOME Terminal Enter, `ab`, three Backspaces, `c★`; gedit
Ctrl+Backspace; Firefox Ctrl+L).

## CI final acceptance receipts

Qualification-only items: each closes on a named green hosted or native run, recorded here. They are
not open software work.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E,
      packaging, installation, launch) with exact receipts.
- [ ] **36.** macOS Package job: Sparkle install/refusal/retry/relaunch, both Brew positives,
      full-policy denial, Brew archive scenarios (the deny-removal AppleEvent positive needs a Mac);
      Linux Flatpak/AppImage installation and PAC/session/TLS delivery.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
- [ ] **63, 71.** Brightness joined source; retired Metrics-window shortcuts across a three-OS full
      save and installed upgrade.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package;
      the 140-rule corpus is never regenerated from production); dynamic hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native Linux/macOS delimiter transactions; macOS packaging with both
      extension TOML files; Windows native cases and Fedora/Alpine ShellRunner fixtures; Linux E2E.
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification; native Linux export
      write/close refusal; provider published before model loading (macOS).
- [ ] **30.** Linux tests of the physical magic-key notice (407db5fd50).
- [ ] **Carbon and daemon-report Swift.** Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation failures on Intel and Apple silicon.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a fresh
      non-empty analysis.
- [ ] **Native Windows TLS fixture.** Seven `native_tls` cases fail since Git 2.56 moved the SDK to
      ucrt64; the trust install stays at `before_add`. Cause not proved.
- [ ] **Full Windows AHK suite.** Never completed green locally (about 90 min single-threaded);
      shard it, never raise `_SUITE_MAX_TIMEOUT_MS`.
- [ ] **Intermittent fixtures.** Close each after it stays green, root-cause a relapse from the
      logged attempt: Linux window switch, cffi-lua clone, desktop-webview AI focus, Windows
      `config` group (managed-network budget, artifact curl relay), macOS Go
      `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` (failed once on macOS 26).

## Decided, do not re-raise

- **Delta updates (item 22)**: withdrawn by the maintainer; full signed downloads stay below 20 MB.
  Reconsider only if release size or measured repeated-download cost grows
  ([rationale](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md#delta-updates-decision)).
- **Report a bug has no review screen**: the report is reviewable on GitHub (October 21).
- **Not defects after native review**: L48, L83 and the release-notes CR handling on Windows; L30,
  L85, L88 and L18 on macOS.
- **Configuration file style (October 20)**: `config.toml` keeps the 5/3 blank-line style everywhere
  (templates and the Windows writer); `windows/_generated/config_template.toml` changes only
  through `npm run build:manifest`; the release list and its ETag persist across restarts.
- **Credentialed redirects** are not followed, by design (L42).
- **Unsigned stable Windows releases** are authorised until SignPath signing is integrated (item
  132).
- **The AHK suite watchdog** is not raised to make a run finish; shard the suite instead.
- **Obsolete configuration scalars** are preserved until explicit cleanup; ordinary saves refuse a
  colliding subtree (ADR-009).
- **Unicode general categories and graphemes** are out of scope for the metrics character classes
  (L137); there is no Lua 5.4 AT-SPI backend, the FFI needs LuaJIT (L67).
- **A stored layout or number-row choice is never rewritten** by a layout change: where it cannot
  apply it stays ticked, greyed and suffixed « — non appliqué », and applies again by itself.
- **Moving the Karabiner lease token out of the rule text** is impossible: Karabiner compares
  variables only to fixed values. Fewer recovery deploys need fewer lease failures first.
- **Do not deduplicate the macOS Swift launcher XCTest classes between E2E and Build.** The managed
  native E2E cells run the SDK, logger and daily-log cohorts on macOS 15 (Apple silicon and Intel);
  Build's full Swift run repeats them on macOS 26 (`macos-latest`). Skipping them in Build saves
  about 42 s of 364 s of test time (measured 2026-10-20, run 39388400901) and nothing on the
  critical path, and drops their only macOS 26 coverage. Job, lot and step names state each cell's
  macOS version, read from `HOSTS` in `tools/ci/macos-stage-roles.cjs`.
- **Windows unit shards are grouped by test category, not by duration.** A new test file with no
  category fails a gate; a minute more of wall time buys a CI whose red job says what broke.
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.
