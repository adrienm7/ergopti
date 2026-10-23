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
      Status 2026-10-24: Debug > Record keyboard hook order (`windows/infra/input_probe.ahk`) and the
      terminal-capture consumer audit in
      [windows-input-hooks-items-49-50.md](todo-agents/windows-input-hooks-items-49-50.md) are in;
      left: the maintainer's run (`rehook=yes` needs the driver as the only AutoHotkey hook), the
      terminal-capture hardware list, and the MSVC-dependent native work. Decide whether the
      `SetWindowsHookExW` string in the exe is acceptable for antivirus (the AV-surface gate allows it).
- [ ] **91. Simultaneous and first-key hold arbitration.** [CODE] Integrate with the
      single-hook/RawInput source (needs a genuine MSVC DLL and manifest pair); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **50. SendEvent against SendInput.** [PHYS-W] `SendMode("Event")` is set, yet the hotstring
      send/dispatch, text sender and config I/O still call SendInput. Measure expansions, pastes and
      predictions (latency, lost or interleaved keys) before choosing.
      Status 2026-10-24: Debug > Measure SendEvent vs SendInput is in; first measurement here: all
      repetitions exact, expansion 152 ms (SendInput) vs 262 ms (SendEvent), prediction 198 vs 386 ms,
      paste 16 vs 9 ms. Left: the run on the maintainer's PC with the driver as the only hook, and the
      interleave test against a second process.

## Big item 4: layout composed from layers, all three OS (October 13 request)

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
