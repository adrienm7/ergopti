<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-24 (see the handover section below). Latest stable: [v1.0.6](https://github.com/adrienm7/ergopti/releases/tag/v1.0.6)
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

## Handover of 2026-10-24: where we stand and how to continue

Written at the end of a long multi-agent session. Read this first, then the item you pick.

**State of the repository.** About 140 local commits on `dev` are NOT pushed (the last push to `origin/dev` was
7099eb93ef). Pushing `dev` needs the maintainer's explicit go-ahead in the current conversation (AGENTS.md); a push
cuts a release unless the run is cancelled, so cancel the CI run of each push (`gh run cancel`). No release was cut and
`main` was not touched. Before the first push: integrate the shared JSON (see "Integration checklist"), run
`node tools/lint/lint-conventions.js`, the three AHK boot checks and the targeted gates of the items you touched.

**What was done in this session (details in `git log` and in the items).** Keystats rename (keylogger gone); issue #101
fixes (ATS key for an http PAC, direct route when the PAC lookup names no route, named lookup stages, no retry of a
refused route, lease line cap, Ollama 412 upgrade request); WinHTTP transport (item 62); per-layer layout composer on the
three OS; hotstring expansion delay defined once and aligned (shared corpus `time_gate_vectors.json`, definition in
`docs/memory/text-input-and-config.md`); chaining pinned by tests (buffer continuity, `test_hotstring_chaining.ahk`);
Space tap-hold press tick; HS-274 owned Karabiner runtime (dormant, hidden `[karabiner] runtime = "owned"`); one-click
Debug field checks on all OS; evidence log API that is never collapsed (`LoggerEvidence`, `Logger.evidence`); redaction
rules and the opt-in redacted day log; AV-surface gate and the false-positive submission pack; CI tooling (rerun verdict,
Flatpak cache and retry, remap-runtime workflow, slowest-test summary); performance work (below); cross-OS parity audit
(PAR entries). Hosted validation on throwaway `tmp/ci-validate-*` branches is logged in
[ci-validation-2026-10-24.md](ci-validation-2026-10-24.md).

**Performance state per OS (measure before optimising; every driver now has permanent counters).**

- Windows: boot to ready 13.6 s to about 8.4 s, tray menu stage 2.6 s to 1.2 s, focus cache event driven. Next: remaining
  registry compares (about 28 write-admission callers), `Hook.KeyDown` attribution (sampled subscriber timings are in;
  read the next live log), `Tooltip.Build` 7.6 ms and `Present` 10.6 ms, layout registration (about 1 s of `Hotkey()`
  calls), the 2 s script parse (9.7 MB include graph, no safe lever found), typst/emoji hotstring sections (about 460 ms).
- Linux: idle loop 99.99 % of a core to 1.5 %, X11 focus without forks, TOML about 2x faster. Next: 315 eagerly loaded
  modules (about 500 ms), five `find` forks in the hotstring loader, log rotation forks in `logger_sink.lua`, validate
  idle CPU and the libxcb focus path on a real desktop.
- macOS: instrumentation only (`infra/phase_stats.lua`, menu per row, boot sub-stages, hold attribution). Next: read the
  Mac log lines listed in "Mac field test" and optimise the dominant phases (menu rebuild 113-247 ms, boot stages,
  preview 21-29 ms per key, preferences writes of 300 operations, ingest tick 1.0-1.5 s).

**Maintainer decisions taken (do not re-ask).** Hotstring chaining is buffer continuity and already works; it is pinned
by tests, never break it. Shared complex-key multiplier on all three OS (PAR-7). Layout pause/resume implemented on
Windows and Linux (PAR-19). Tap-hold and key-combination defaults identical on all OS except real role differences,
each with a stated reason (PAR-17). Linux reload through a TTL-bound pending-record protocol shared by the three OS.
Preview switches default ON everywhere, notifications aligned on macOS, WPM defaults off (coordinator choices, ask for
review). libXi dependency declined (Xi packet retired). Items 46/47/48 retired except the macOS Ollama termination debt
(120). Optional redacted day log allowed; config-directory names masked in logs. Item 131 is a read-only login-items
check, no removal. No token-reuse rearm (ADR 012). Expansion delay with end char: from the last typed letter to the
expander (`★` or the end character).

**Decisions still pending for the maintainer.** `docs/questions-for-maintainer.md` (check it for anything new). Open at the end of the session: delimiters as config leaves on Windows (PAR-8), user-settable base delay (PAR-6), the Linux autocompletion delay row (PAR-21), `hotstrings.dynamic.enabled` on Windows (PAR-24: the master exists there as `category_enabled.dynamichotstrings`, a reason key says so), the content-Gui pool of the Windows prediction tooltip.

**Remaining work, in the order to take it.**

1. Integrate and push (see checklist), then run the FULL suites once on the final tree: `node tools/test/verify-change.cjs`
   (about an hour with parallel agents idle) and the full AHK suite (about 90 minutes, single threaded, nothing else
   running: `run_all.ahk` is `#SingleInstance Force`, concurrent runs silently kill each other). Fix only reds caused by
   our changes (hosts reds: Node 22.16 vs pinned 22.22.2, Unicode 16, no pwsh, no lfs, `build:linux`, Windows file staging).
   Known red to chase first: live check `reload-click-joins` ("second click not logged as joined") failed at the end of the
   session after it passed at 1254dd7bd7; the joined-click log line comes from `menu_dispatcher.ahk`; suspects: the
   driver_control pending-record work (d682fa6995) or the perf commits; run
   `node tools/maintainer/windows-live-checks.cjs --only reload-click-joins` with no other AutoHotkey process, bisect with
   `git archive` exports (no worktree).
2. Hosted CI on the final source: `gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all` (only after every
   piece passed alone; macOS runners are expensive). Then the CI receipts section.
3. The cross-OS parity entries `PAR-1` to `PAR-85` below: unfinished ones are those not marked done; centralisation and
   constants (PAR-65 to PAR-85) were not started: one declaration in `_shared` per constant, delay, colour, label;
   hexagonal architecture (rules and ports in `_shared`, OS code only in adapters); each with a single-source gate.
4. Performance items above, on each OS; then re-measure with the permanent counters and keep the numbers in the commits.
5. Items that need devices or the maintainer: see "Mac field test", "Windows PC field test", SignPath application,
   Microsoft/vendor submissions, tester retests, the maintainer checks sections.

**Mac field test (after a release or a local build of this tree).** Debug menu, one click each, then Copy report and
send the log lines `Field check result:`: Test Karabiner lease, Test owned Karabiner runtime (dormant check), Test
network (PAC, proxy, download), Test key accounting (30 s while typing), login items and agents, toolchain (timer,
Shortcuts, Homebrew, Karabiner signature), Test the composed layout. Also bring back after an hour of normal use:
`Phase summary [family]` (keymap, preview, menu, menu_item, toml, process, boot_sub, hotstring_load, runtime, hotpath),
`Menu tree rebuilt ... Slowest:`, `Boot stage requires:`, `Boot sub-stage:`, `Common hotstring load:`, every
`held the main thread ... Phases inside the hold:`, `Slow ingest tick`, `Slow preferences save`,
`Lease token decision=`, `written in N ms`, `Memory snapshot`. Confirm on the Mac: an http company PAC works (issue
#101), `pr` + Space style triggers, the ISO/ANSI selector (Automatic/ISO/ANSI) with a physical keyboard, the
menu-triggered redeploy.

**Windows PC field test.** Reload the driver from the working tree only when the tree parses (the three boot checks);
then run `node tools/maintainer/windows-live-checks.cjs` with NO other AutoHotkey process running (SendInput falls back
to SendEvent when another script has a keyboard hook, and the real-key checks refuse to run next to another driver);
Debug > Record keyboard hook order (expect the native owner first again after the reassertion) and Measure SendEvent vs
SendInput on a quiet machine; the manual lists in [windows-maintainer-checks.md](tooling/windows-maintainer-checks.md).

**Integration checklist (shared files other agents leave uncommitted, because the pre-commit hook rejects a partially
staged `.json`).** `static/ergopti_plus/_shared/data/locales/*.json` (21 files), `_shared/modules/menu/menu_manifest.json`
(regenerate with `npm run build:domain`; `codegen-unicode-case` fails on this host, ignore that step),
`_shared/modules/diagnostics/schema.json`, `_shared/modules/features/manifest.toml`, `_shared/ui/layout_manager/strings.json`,
`windows/tests/run_all.ahk` (includes for tests whose files already exist: capsword state, composer check, new live
tests), `package.json` (npm aliases such as `test:remap-runtime-manifest`, `test:neutral-installation`), the test suite
registries under `tools/test/features/*/suite.json` (renumber clashing ids), `docs/memory/*.md` entries listed by the
agents. After integrating: `python tools/locale/check_locales.py`, `node tools/test/test-menu-manifest.cjs`,
`test-approved-menu-labels.cjs`, `test-diagnostic-ui-integrity.cjs`, `npm run test:ci-pipeline-wiring`. Reseal the
updater original source after any change to a pinned file:
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write` (only when `run_all.ahk` is clean).

**Hazards learned.** One lint violation in anyone's new file blocks every commit (the hook lints the whole repo):
run the lint after every save. A half-saved `.ahk` file breaks the maintainer's live driver (reloads come from the
working tree): edit a copy and move it in when it parses. Committing through a temporary index leaves the real index
stale: run `git status` before a plain commit and reset only your own paths. `wsl --shutdown` kills other agents' WSL
jobs and clears `/tmp`: do not run it while others work. Never type backslashes through bash heredocs or python text
mode (use the Write/Edit tools). Test the Windows pieces for real on the maintainer's PC (everything Windows can be run
here); macOS and Linux behaviour that needs hardware goes through the Debug field checks and the maintainer's logs.

## Big item 1: Windows corporate networks and trust (items 62, 132)

- [ ] **62. WinHTTP transport for the managed remote downloads.** [CODE] Done (1d15b51e66, 7c001b2456
      and the following commits): managed requests, updater artifact download and Ollama archive
      download use WinHTTP (`vendor/ergopti_winhttp_transport.ps1`, worker
      `ergopti_managed_http_worker.ps1`); `curl.exe` stays only for loopback Ollama. Proven on this PC
      against owned loopback services with real SSPI NTLM and Negotiate proxies, CONNECT, untrusted
      TLS, bounds, deadlines and PAC failover. Left: the native CA cases (a click on the Windows
      security warning or an elevated LocalMachine scope), enterprise acceptance behind a real
      proxy/PAC (Kerberos, TLS inspection, revocation) through Debug > diagnostics (`github_api`,
      `proxy_pac`), and item 36 (external trusted binding).
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
      Done: no hidden PowerShell clipboard stage, own version resource, English metadata, tar.exe
      extraction, the keylogger naming gone (keystats rename; the gate forbids `keylog` in the script
      and the bundle), string-surface ceilings and a per-build record with the exe SHA-256 in CI
      (e2c9dfb79d), the submission pack
      [windows-exe-false-positive-submission-pack.md](todo-agents/windows-exe-false-positive-submission-pack.md).
      Left (maintainer): signing (132), VirusTotal lookup, Microsoft and vendor submissions, the
      tester's block page and retry (T1-T4); decide whether the `WH_KEYBOARD_LL` probe in
      `input_probe.ahk` stays in the release exe. Playbook:
      [handoff](todo-agents/windows-exe-flagged-by-proxy.md).

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
- [ ] **Per-layer layout composer.** [CODE] Done on the three OS (docs/layout-composer.md): shared
      model, page, 21 locales, Windows host, macOS and Linux install paths, tests, one-click Debug
      "Test the composed layout". Left: typing the composed layout on a real keyboard on each OS.

## Wave 2: mid-size work

In progress (agent), October 22:

- [ ] **Windows config policy (items 33, 42) and the TOML parse cost.** [CODE] Per sub-item in
      [config-policy-33-42.md](todo-agents/config-policy-33-42.md); 33: Windows keyboard binding
      publication from its real input owner, macOS Hotstrings category authority, Linux retired
      API-provider reader, macOS Karabiner obsolete-leaf intent, Windows retired cleanup
      projections; 42: explicit `--config FILE.toml` watcher admission, Windows full-save comment
      preservation. Parse cost: every document-mode write parses source, expected model and final
      candidate, and every start pays two builds after ready; reuse one parse per transaction
      before adding any cache. **In progress (agent).**

Not started:

- [ ] **Ollama redirect policy and Go compile (decision 5).** [CODE] [CI] Code done (cda1e10c5e): an
      unresolved download host is left to the proxy or the native worker; private, loopback,
      link-local and CGNAT addresses and names resolving to them stay refused; the build recipe
      patches upstream `ValidateRedirectTarget`. The hosted Go cell (`go vet`, `go test` through
      `build-macos-managed-ollama.py`) passed on a throwaway branch (run 40021624397, see
      [ci-validation-2026-10-24.md](ci-validation-2026-10-24.md)). Left: the same cell on the final
      source before a release.
- [x] **54/81. Last three native Windows menu rows.** Done in 02b63912f1 (local): census Windows
      0, macOS 0, Linux 0. The default-section, file and folder submenus are renderer template
      children (`MenuRenderer_TemplateChild` reserves, `MenuRenderer_FillTemplateChild` fills,
      `MenuRenderer_RepaintTemplateChild` repaints only a child the renderer still publishes); a
      kept callback after a rebuild is now refused before any write. Left: manual check 17
      (installed menus, default choice after restart); the shared-tree census is red on Linux only
      while `linux/ui/menu/rebuild_owner.lua:39` (another agent's uncommitted edit) is in flight.
- [ ] **Ergopti-started Ollama behind a PAC proxy.** [CODE] Linux done (89d22d782c, fake-lookup
      tests). macOS in code (launcher role `--managed-proxy-route`, 06addb2e3f; per-origin route
      plan 1fd254d92e and 749e00c4c8); Swift compiled and tested on the hosted macOS cell. Windows
      is covered by the WinHTTP transport (62). Left: a real-PAC pull on the maintainer's Mac (Debug >
      Test network), the Ollama blob host inventory check, a `route_plan` step in the network check.
- [x] **Menu clicks during a reload.** Done (b0fb0f585b, c280aa4eaf, 8c4314524a, d8f6fbf1d2): a click
      is held during a reload and replayed with its intended state; a Reload click during a reload
      JOINS it (Linux and macOS; Windows in the standing-checks agent's work, see PAR entries); Linux
      reports a refused `load_all` truthfully; the ordered-pair test runs in 8 s.
- [ ] **AppImage self-contained.** [CODE] `.zsync` and update information are done (10c016e51f,
      6fb83014e3). Left: validate on hosted CI; bundle the C library and loader (or build on an older
      base) and prove it on the distro matrix (musl cannot run glibc binaries: say so), keeping the
      tray closure.
- [x] **Linux `copy_selected_path` in a file manager.** Done (8edb31edba, d2a7bc9c5b, 3027faffd3: the
      AT-SPI active frame names the application under Wayland). Left: confirm the AT-SPI query on a
      real GNOME or KDE Wayland desktop. Unicode IDNs and a zoned IPv6 are searched, not opened.
- [ ] **Linux X11 window list.** [CODE] `getAll()` is covered by the Openbox receipts (962a25a973);
      confirm in the first hosted run. Flatpak: wmctrl is only a documented host program.

## Cross-OS parity, centralisation and constants (audit of 2026-10-24)

Maintainer rule: the same behaviour on Windows, macOS and Linux wherever possible, unless there is a
good reason stated in the menu reason text; everything that can be common lives in `_shared`
(hexagonal architecture: rules and ports in `_shared`, OS code only in adapters); every constant,
delay, colour and label has one declaration. Source: [audit](audits/2026-10-24-cross-os-parity.md)
(row ids `H1`, `R3`, ... refer to it); entries are `PAR-1` to `PAR-85`, stable ids. Rows tagged I in the
audit come from grep counts: confirm them before starting. Done and verified: about 35 entries (see git log); the list below is what remains. Decisions taken: PAR-7 shared multiplier, PAR-17 identical defaults with stated exceptions, PAR-19 implement on Windows and Linux.

### A. Behaviour that differs without a good reason (fix first)

- [ ] **PAR-6. Make the base expansion delay user-settable on all three.** [CODE] One declaration now
      (manifest default of `hotstrings.expansion_delay`, 31372616f5) but only macOS reads a user-set value;
      Windows and Linux ignore one written in `config.toml` (their delay is per section in the « Délais &
      couleurs » window). Question in `questions-for-maintainer.md`.
- [ ] **PAR-8. Word delimiters in config leaves on Windows.** [CODE] Blocked on a design answer
      (`questions-for-maintainer.md`): write the built-in states through the live config writer (no
      reload per click), drop the override-file strings and the per-character consume opt-in on built-ins,
      keep custom delimiters as records. About 230 references in 17 files and 40 AHK tests. Also: macOS and
      Linux ignore the delimiters a user adds when deciding a repeat; only Windows honours them.
- [ ] **PAR-12. Token streaming reason.** [CODE] Reason text rewritten in 21 locales (the display exists on
      Windows but is not validated there). Left: rename the key `token_streaming_transport_missing` (it is
      misleading) in manifest and locales, or enable the row on Windows after a live Ollama check.
- [ ] **PAR-14. Check-only fallback when the GitHub API is blocked: Windows.** [CODE] Linux and shared
      pieces done (28bdd5a5d9, vectors `check_only_vectors.json` and `list_cache_vectors.json`). Windows
      needs the Atom fallback in `core.ahk` plus an AHK feed parser, then a reseal of the sealed updater
      sources (only when `run_all.ahk` has no foreign hunk).
- [ ] **PAR-15. Tap-hold thresholds.** [CODE] Done: exact per-key thresholds pinned, one one-shot timeout
      (macOS read 3000 against 2000 ms), Linux holds the key's own side. Left: decide whether macOS keeps one
      global 250 ms or gets per-key values (the id vocabularies must be reconciled first).
- [ ] **PAR-19. Pause and resume of the layout, implement on Windows and Linux (decided).** [CODE]
      Plan: move the three `layout.*` rows (`pause_switch_enabled`, `on_pause`, `on_resume`) and the two
      menu frames from hs to all platforms; correct the `on_pause`/`on_resume` type (macOS stores layout id
      strings, the manifest says boolean); one shared target policy (enabled and a non-empty string; macOS
      `switch_target` in `menu_keyboard_layout.lua`); Windows: hook a layout step into
      `Ergopti_OnSuspendEnter`, the resume path and quit in `windows/infra/lifecycle.ahk` through
      `_LifecycleRunRequiredStep`, switching with `WM_INPUTLANGCHANGEREQUEST` and a picker listing the
      installed layouts; Linux: an adapter with a fakeable port (gsettings `current` on GNOME, `setxkbmap`
      on X11) driven from `script_actions.on_pause_change` and quit; shared policy vectors replayed by the
      three drivers. Strings already exist in 21 locales.

### B. Missing features on one OS

- [ ] **PAR-21. Linux LLM parity batch.** [CODE] Done: per-app trigger disabling (5b66b7e761), min/max
      words rows already existed. Left: model delete (the Linux HTTP transport has no DELETE), warmup (needs
      the engine's runtime-owner lifecycle), reset on navigation (needs an LLM context buffer: design
      decision), the AI-acceptance and autocompletion delay rows (the meaning of the autocompletion delay
      needs a decision).
- [ ] **PAR-22. LLM telemetry on Linux.** [CODE] Done: generation, suggested, dismissed, accepted rows in
      `events_llm` and Ollama token counts (928aeffd43). Left: remote-provider tokens and cost (port the
      macOS response classifier and `model_prices`).
- [ ] **PAR-30. Sign the Windows and Linux update assets.** [CODE] [CI] Done: ECDSA P-256 detached signatures
      over a record of asset name, size and SHA-256, signer and reference verifier
      (`tools/build/update-asset-signature.cjs`), Linux verifies with OpenSSL, Windows with CNG, shared
      vectors, CI signs the Windows exe and publishes the `.sig`. Left: call the verification in the Linux
      manager's transfer flow and the Windows `release_install`/`self_update` path (enforcement `"off"` until
      the maintainer provisions the key: five steps in `docs/tooling/update-signing.md`), then flip it to
      `"required"`.
- [ ] **PAR-34. Mouse metrics, event families and app-category store on Linux and macOS.** [CODE] Linux
      writes 4 event tables of 15; the `mouse` column exists with no capture; app categories live in
      three stores. Capture mouse, write window/system/session tables, one category store. Audit S2,
      S4, S8.

### C. UI-only gaps, reasons and docs

- [ ] **PAR-37. Platform reasons for two-platform restrictions.** [CODE] The single-platform ratchet went from 88
      to 1 (the last one is PAR-40). 98 entries restricted to two platforms (mostly menu frames and
      boundaries) still have no reason: extend `test-platform-restrictions-explained` to them. The 13 new
      reason texts and the nav-layer ones are drafts in 20 locales: native review wanted.
- [ ] **PAR-40. Unify user LLM profile storage.** [CODE] Reverted attempt, steps: move
      `linux/modules/llm/profile_registry_codec.lua` to `_shared/lua/llm/` and repoint the Linux requires and
      the 7 Linux tests; in `macos/infra/preferences.lua` move `llm_user_profiles` from the nested map to the
      scalar map with the codec (encode on write, decode on read and in `known_profile_ids`);
      `macos/ui/menu/llm_scope.lua` reads the registry from `llm.user_profiles`; `manifest.toml`:
      `features.llm.user_profiles` for all platforms, delete the macOS-only
      `features.llm.profiles.user_profiles`; fix `config.schema.json` and `hs_config.example.toml`; update
      `test_llm_scope_contract`, `test_preferences_existing_key_spellings`, `test_unused_keys_cleanup` and
      the nested-array round trip; ratchet baseline to 0. Needs a macOS run.
- [ ] **PAR-41. One shortcut data model.** [CODE] Design note written
      (`docs/design/one-shortcut-model.md`, 4ca41ed2e9): one action slot per chord with neutral role-based ids,
      no migration, eight steps; step 1 is the inventory of the Windows legacy boolean list. Large.
- [ ] **PAR-43. Duplicated per-OS prompt strings.** [CODE] Done for `max_words`, `temperature` and the port
      dialogs (fb1aa4d934). Left: the two row captions (`ollama_port_label`, `mlx_port_label`: the caption
      machinery takes one argument) and `menu.settings.delay_prompt` against `menu.llm.debounce_prompt`
      (different accepted input).
- [ ] **PAR-44. Reset error texts on macOS and Linux.** [CODE] Windows `ReloadWithDefaultConfig`
      (`windows/infra/config_io.ahk`) has the typed failure points acquire, commit, reload_refused, rollback.
      macOS has a journaled reset (`ui/menu/global_actions_transaction.lua`): surface its failures with
      `dialog.reset_defaults.reason.*` instead of `dialog.bulk_toggle.save_failed`. Linux: find the reset
      or restore entry points (grep `save_failed` in `linux/ui/menu/menu_builder.lua`), make them
      transactional with the same typed points, tests. Where an OS has no reset, say so in the reason text.
- [ ] **PAR-45. Notifications: one behaviour for toggles and refusals.** [CODE] Add `NotifyFeature(label, enabled)`
      on Windows (wrapping `NotifierSend`) and Linux (`adapters/notifier.lua`) and call it from the
      equivalents of the macOS handlers (hotstring group and section toggles, personal info, preview bubbles,
      word expander prefixes, shortcuts master and individual, gestures master; macOS call sites in
      `ui/menu/menu_hotstrings*.lua`, `menu_shortcuts.lua`, `menu_gestures.lua`, `builder.lua`); add a
      quit-refusal path on Windows and Linux firing `notify.quit_refused` (macOS: `macos/ui/menu/init.lua`
      around the `quit` command). The `notify.*` strings exist in 21 locales.
- [ ] **PAR-48. Review values equal to English in each locale.** [CODE] 263-385 per locale and about 30 in
      `fr` (`sg_actions.sticky_*`, `shortcuts.altgr*`). Triage through the i18n skill. Audit I3.
- [ ] **PAR-52. Release notes on macOS and Linux update windows.** [CODE] Only the Windows update prompt opens
      `_shared/ui/release_notes`. Embed the shared pane in the shared `update_check` page with the host
      seeding the release body (macOS Sparkle's prompt shows no notes; the Linux page has no notes pane).

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
- [ ] **macOS input follow-ups (swallowed keys).** [CODE] Done: late keys pass through (ed2d9fe65c),
      AXValue read once per burst (34765cde7c), no error window for a lease failure that recovered
      within 60 s (fcf4af85dc), `key_*` counters in the diagnostics (6f2daed2e5). Lease token reuse
      was analysed and refused (ADR 012): a reused token could never reach READY because the
      revocation tombstone is monotone; reuse needs a native acknowledged rearm, decided NOT to
      build for now. The next Mac log carries `Lease token decision=` and `written in N ms`: if the
      write is short, keep it; if long, shrink the 743 KB file instead.
- [ ] **Linux correction parity remainders.** [CODE] Done (06bbbe5985): Backspace pops the word, erased
      n-grams get `e`, synthetic output chains. Left: erased and synthetic vectors in the shared corpus
      (needs the AHK and macOS replayers); Windows word separators are wider than Linux's three.
- [ ] **Windows updater -File workers: real update check.** [PHYS] Install a build with 5d6beccf83
      by hand, then update from it to the next release: the exe is replaced and restarts, the
      three scripts are in `%LOCALAPPDATA%\Ergopti\vendor\`, the PowerShell command line shows
      `-File ...ergopti_updater_staging.ps1` and no `-EncodedCommand`.
- [ ] **Config policy remainders (33, 42).** [CODE] Done: macOS category authority (80c18d9cc2),
      explicit `--config` watcher topology (3dd420292d), `api_entries` retired rows (c03762d27b),
      parse cost (e525cd6615). Left: the physical keyboard slot parameters
      (`keyboard__win_SC03A__x`), the Windows `api_entries.json` per-row warning, the bare-root and
      unknown-`[[x]]` cleanup offers, a reseal of the updater original source after e525cd6615
      once `run_all.ahk` is clean, and the Linux reload as a daemon restart (the control protocol
      needs a pending record that can name an unknowable successor pid; recommended: a TTL-bound
      pending record completed by the successor).
- [ ] **Linux CI installs packages inside short test steps.** [CI] 18 steps moved and skipped when the
      suite is deferred (c52cb916a7, 285d3363a1). Left: `Qualify three actual XI2 property cookies`
      and `The whole daemon, live` (their text is pinned), the 35-minute and 18-minute steps, the
      other jobs, and hosted validation.
- [ ] **macOS "Quit did not end both processes within 10 s".** [CI] Cause found: the Quit AppleEvent
      timed out while the launcher log had been silent since startup (run 39850037912); the gate now
      names the surviving process and keeps the failing attempt's evidence for 7 days
      (b2b5bb149b, bf05488dfb). Read `launch-gate-failed-*` if it recurs.
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
- [ ] **62 (macOS and Linux).** [CODE] Packaged paths resolve every request and redirect natively;
      the environment fallback now resolves each origin of the client inventory and refuses two
      different relays (1fd254d92e, 749e00c4c8). Left: confirm the Ollama blob host on the Mac,
      the Go twin `_shared/go/route_plan` in a CI cell, a Linux wrapper test.
- [ ] **CI duration** ([target](memory/workflow-and-verification.md)). Flatpak runtime cache and a
      bounded retry are in (07a601c97e plus the retry commit); confirm on a hosted run (target under
      5 min). Windows Integration still adds 4-5 min on the critical path; the macOS lane (about 58
      min) must stay within the five-runner budget.
- [ ] **CI structure.** [CODE] Slowest-test summary and `tools/ci/run-timing.cjs` shipped
      (e1aa4a5f48, cab1170446). Left: a per-step elapsed summary inside the CI run itself.
- [ ] **Test parity across the drivers.** [CODE] Done: Windows CapsWord behaviour tests, dynamic
      hotstrings, macOS audit-named tests renamed, neutral-installation gate. Left: Windows replay of
      the shared HTTP-redirect, timer-ceiling and key-chord corpora (needs a decision to build those
      policies on Windows), conversion of Windows source assertions to behaviour (audit item 14).
- [ ] **5.** [CODE] Linux layout and number-row scope participants composed with the real runtime
      producers; Linux/macOS numeric-owned Script aliases need an explicit snapshot contract.
- [ ] **116. Guided third-party validation report.** [PHYS-M] macOS `field_check_toolchain` landed
      (timer, Shortcuts, Homebrew, Karabiner signature); needs a run on a real Mac. Package
      provenance beyond the signature check is open.
- [ ] **139. Personal identities in logs.** [CODE] Done: email, URL-credential, foreign-profile
      rules (5ef12e8a2a) and config-directory name masking (20e845692b); opt-in redacted day log
      attachment (1c6f891ed3, item 138). Left: emitter-side pack labels (the TomlLoader SUCCESS line
      prints the pack label; check the macOS and Linux loaders), write-time masking in the three
      loggers, historical logs on disk stay unmasked (the collector masks at export), GitHub field
      editability after a form reload needs a real draft.
- [ ] **142 gaps.** [CODE] Windows: a Reload click during a pending reload now follows the join rule
      (standing-checks agent); no hash-check requirement identified for the Windows client. Linux:
      the reload is in process; see "Config policy remainders" for the protocol decision.
- [ ] **13/35.** [CODE] Enrol the complete guardian acceptance collector in main CI.
- [ ] **93. Linux ordered pairs.** [CODE] XI2 property cookies proven on Xvfb in WSL; the saved Xi
      packet is retired (libXi as a package dependency declined by the maintainer). Physical input
      and the XKB/XI2 server-state join need a real kernel and desktop.
- [ ] **97/98.** [CODE] Native physical-position capture and all-owner collision admission; Linux
      identity needs the MediaStore device contract. The star setting migration is dropped (no
      users, no legacy migration).
- [ ] **106.** [PHYS-M] Genuine Apple Shortcuts invocation with bounded cancellation; only the
      refusal-in-time probe exists (in 116).
- [ ] **107.** [CODE] macOS forced output, Linux input+XI2+writer join.
- [ ] **108.** [CODE] Item 97's collision/source/modifier/output joins.
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible
      Variables/KeyHistory snapshot.
- [ ] **120 (formerly 46/47/48).** [CODE] Broad Ollama process termination on macOS stays debt (the
      other clauses of 46/47/48 were stale or by design; their context was lost and the maintainer
      retired them).
- [ ] **L115.** [CODE] Provider error envelope guard: not reproducible under WSL LuaJIT (6 of 6
      runs pass); leave it or close it.
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

- [ ] **Win+S open target** (ec1c4105d9): automated checks cover the target resolution; by hand only
      what leaves the driver: a browser, the mail client, Regedit with its prompt, Settings, a web
      search (steps in [windows-maintainer-checks.md](tooling/windows-maintainer-checks.md)).
- [ ] **Backspace word start**: the engine-buffer cases are automated; by hand only Windows Terminal
      with Claude Code, Notepad Ctrl+Backspace, the browser Ctrl+L, and AltGr+Backspace on an
      AZERTY-style AltGr and a Kana layout.
- [ ] **Tap-hold and key-combination pickers**: automated except the native pair popup itself.
- [ ] **Versions tabs**: automated except the Retry button.

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
11. **CapsWord auto-off**: delays, the eight default delimiters, each pointer kind, the LAlt then
    CapsLock trigger.
12. **AI off (#97)**: no local server sweep, no AI hotkeys, a refused AI hotkey leaves the driver
    running. Item 143: time the AI toggle behind an unfinished startup (3.05 s on the smoke).
13. **Prediction chord (item 112)**: in Notepad each slot's modifier+digit inserts that prediction
    and its correction form; the shortcut column is right-aligned and muted.
14. **Item 114**: observe the resident process during a prediction-key (1-5) or AltGr+Enter stall
    and collect the Notepad stale-admission diagnostics before changing anything.
15. **Items 30, 46-48, 54/81, 63, 73, 88, 96-98, 107, 108, 125, 138**: physical magic key under
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
