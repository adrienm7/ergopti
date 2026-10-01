<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-01. Latest release: v0.0.0-dev.155 (c9e4c64ab); `dev` is
ahead of it without a release (CI cancelled on purpose).
This checklist is the current handoff; older workflow task-status files are
historical evidence.
Item numbers are stable identifiers: a finished item is removed (its durable
facts go to docs/memory), and the numbers of the others never change.

## Delivery checkpoint

The overhaul is not finished. Eight reviewed integration commits ended at
`eaa06eeba`, followed by the published handoff and CI repairs. The macOS
cold-start errors were then fixed on `dev` (`d8d171fcd`, `56eeb70dc`,
`8ee659e17`) and CI published `v0.0.0-dev.144` on 2026-09-29. Two stricter
local macOS corrections followed on top of that release: gesture event-tap
acquisition deferred to explicit startup, and configuration consumers required
only after path initialization.

Work continues from a fresh clone on a Linux container. The Windows workstation
no longer holds any worktree, branch or external working directory: `D:/ewt`
was deleted after its useful content was committed here. The historical
workflow context (prompts, task status, feature map, analysis reports and
journal) is in the handoff package's `workflow-context-2026-09-24.zip`.

The user authorizes publishing `dev` and necessary CI repairs, forbids force
pushes to `dev`/`main`, and wants a cloneable GitHub handoff. Preserve
unrelated changes and stage exact paths. Every push to `dev` cuts a release,
so push rarely: run the full CI on a temporary `backup/*` branch through
`workflow_dispatch` (a non-dev ref runs the CI profile and publishes nothing),
and push `dev` only once that run is green. Temporary `backup/*` branches are
authorized and must be deleted after the final push.

**Overnight session of 2026-09-29 (supersedes the "one item at a time"
instruction: the maintainer asked for maximum parallelism).** Items 5 to 13
were implemented in parallel on `wip/*` branches, adversarially reviewed, fixed
on `wip/*-fix` branches and integrated in order on the local branch
`integration-2`, then `integration-3` after a container restart; the whole
batch was published to `dev` in one release on 2026-09-30.
The maintainer demos Ergopti on 2026-09-30 in the afternoon. Read
[the overnight handoff](handovers/2026-09-29-overnight/README.md) first: it
lists every branch, the in-flight fixes, the maintainer's decisions and the
exact release procedure.

## Already integrated functionality

The history on `dev` contains the following substantial parts of the overhaul.
These are software implementations; final hardware verification remains below.

- Shared scrollable configuration cleanup, offered as cleanup rather than a
  startup error; valid configurable gesture parameters remain owned settings.
- Shared title composition with one product prefix and regression coverage for
  the broader window-title family; configured action values replace placeholders.
- Bundled keyboard-layout catalogue and manager on three OSes, installation
  owners, Ergo-L support, and independent base/Shift versus AltGr emulation.
  Extension geometry and physical magic-key completion remain in L4.
- Manifest-driven menus, category masters and retained child choices;
  configuration schema/migration infrastructure; substantial neutral-state and
  transactional recommended/clear machinery. W1 is explicitly incomplete.
- Shared action catalogue, Unicode case/plain-paste/wrap actions and three
  configurable number-row edge keys.
- Shared navigation-layer data, generated driver projections and web editor.
- Logger repetition handling, log-directory ownership, larger centered debug
  consoles, diagnostics/error interfaces and issue-reporting improvements.
- Shared updater channels, release notes and automatic-check scheduling.
  The common update-result interface remains C4.

## Ordered TODO

- [~] **5.** Complete W1 neutral configuration and recommended/clear scopes.
  Finish macOS Hotstrings and TapHold, Linux Hotstrings and TapHold, then global
  composition. Keep unknown fields, verified backups, exact runtime
  acknowledgement, external-write conflict detection and retryable rollback.
  Recommended delay values must match effective runtime inheritance: deleting
  `autocorrection.caps` currently inherits 1.0 s while the manifest recommends
  0.5 s. Do not assume deletion implements the recommendation. Hotstrings: Linux
  categories, sections and scalar settings are canonical config.toml leaves,
  with a one-shot import of legacy storage.json choices; both Lua drivers have a
  two-file recommended/clear owner whose planner writes explicit delays where
  inheritance differs, bound Ergopti groups included. Published in the second
  2026-09-30 release: `hotstrings_menu` declares `scope_restore`/`scope_clear`
  beside the switch and all three drivers register them (Windows from
  `_HS_ScopeCommands`); macOS constructs its owner once per session and composes
  it into the global restore (skipped and named when its override file cannot be
  served), its transaction now reverting and releasing, and a scope's retained
  inverse is settled through the writer fence so the other categories' reverts
  and every later writer are admitted again; the macOS Hotstrings switch starts
  the typing engine « Clear » stopped. Linux word delimiters are config.toml
  leaves (`[hotstrings.terminator_states]`, `hotstrings.terminators`, the macOS
  paths) imported once from storage.json; a save writes only what the menu
  changed; both Linux modes return the shipped delimiters to their defaults and
  keep the user's own (user data, as the delimiter submenu does). Still open:
  the macOS scope leaves its delimiter states as they are (Windows resets its
  whole delimiter string), and the Windows rows are verified statically only.
- [~] **6.** Complete L4 extension layout geometry and physical magic-key
  behavior. Keep independent base/Shift, AltGr/ShiftAltGr and number-row
  emulation. The physical magic-key setting is item 30.
- [~] **7.** Complete W2: seven-page first-run opt-in wizard, per-category
  recommended choices, consistent WebView behavior and genuine translations in
  21 locales. The tap-holds page lists each engine's recommended keys from the
  shared tap-hold catalogue and imports only the checked ones through each
  driver's tap-hold writer: Windows renders them into the tap_hold.toml beside
  config.toml in the wizard's own transition, macOS goes through the remap
  owner's settings transaction (a file save before the bridge starts or for a
  moved folder), Linux through tap_hold_writer into the chosen folder, where
  macOS and Linux also switch the Tap-Holds on. A re-run reads the keys each
  folder already configures: the page opens at the switch in force, shows a key
  at its recommendation checked and one of the user's as kept, locks both, and
  every writer refuses to import over the latter and backs up the file it
  replaces. Published in the second 2026-09-30 release. Remaining: a real-device
  re-run of the wizard on each OS (Windows was verified by CI only), and Linux
  still applies its hotstring sections through hotstrings_config (storage.json)
  and leaves the trigger to its tray.
- [~] **13.** Complete F2: honor the Karabiner integration switch before leases
  and guardians; preserve personal rules; back up and restore Windows touchpad
  registry values through one owner. Remaining: turning the switch off or «
  Retirer Ergopti de Karabiner » does not unregister a guardian LaunchAgent
  registered while it was on (needs a headless unregister role in the launcher,
  verified on a Mac). Legend: `[x]` implemented, reviewed and integrated on
  `integration-2` (published only once `dev` is pushed); `[~]` integrated with
  the precise remainder recorded in the item or in the overnight handoff.
- [~] **16.** Publish final corrective commits, verify CI and release assets,
  and write the final report with completed scope, limitations and manual test
  results. Published twice on 2026-09-30 (v0.0.0-dev.147, then the morning's
  work with the Homebrew provenance fix). Local gates of the second tip: JS
  320/321 (only the root-sandbox install check), macOS Lua 12333/12333, Linux
  4367/4367, macOS E2E 67/67, Linux E2E 118/118, strict conventions, AHK
  encoding (1740 files), gen:check (40 outputs of 23 generators); full CI
  without release: run 36697666039 (CI #633). The maintainer's manual test
  results remain.

## Maintainer requests added on 2026-09-29 (see the overnight handoff)

- [~] **19.** Windows tooltip border hidden under its content and white corner
  pixels (pooled border z-order + ring drawn from the content region).
  Integrated; verify visually on Windows 10/11.
- [ ] **22.** Delta updates: macOS Sparkle deltas are ready on
      `wip/delta-updates` (mirrored as `backup/wip/delta-updates`, not integrated:
      its CI step only runs on real releases, so it needs a dry-run CI mode first),
      then Windows and Linux per ADR 010 with an automatic full-download fallback.
- [~] **23.** Ergopti-only hotstring groups (SFB reduction, rolls, repeat
  corrections) moved into the Ergopti extension, shown under « Hotstrings
  Ergopti ». Integrated. Open maintainer decisions: "installed" currently means
  "shipped with the app" (the submenu shows for every user); other
  Ergopti-looking groups (distancesreduction `qu`, `comma_j`,
  `comma_far_letters`, `ê` sections, French `suffixes_a`, magickey `replace`)
  were not moved.
- [~] **24.** macOS tap-hold outage: a not-ready remap guardian held every
  Karabiner regeneration forever and pinned the first bulk edit (Restore
  defaults), refusing later edits and Reload. Fixed, with a Tap-Hold menu row
  saying why tap-holds wait. Guardian approval UX: registration was already
  automatic; a requires_approval answer now opens numbered Login Items steps in
  the native permission dialog (once per launch, after the Accessibility dialog,
  closed automatically on approval; not while Tap-Holds are off, where the
  banner stays). Integrated; verify on a Mac.
- [~] **30.** Physical magic-key setting on all three OSes: one
  `hotstrings.magic_key_source` (a KeyboardEvent.code, `auto` by default),
  config schema v5 migrating every spelling of the Windows
  `magic_key_source_scan`, and a Layout menu row that captures the next physical
  key or lists the candidates. Published in the second 2026-09-30 release. A
  chosen key replaces only its plain press (Windows keeps the layout's
  Shift/AltGr/Ctrl/Win), the Windows capture reads the physical key state, Linux
  refuses a key it cannot type without the clipboard and cancels a pending
  Compose. Remaining: real-device checks on each OS (Windows capture under the
  emulation, macOS on ISO and ANSI boards where Backquote and IntlBackslash both
  answer, Linux grab and injection); Linux follow-ups: the Layout menu shows the
  row without the replace switch it depends on, holding the key types one ★
  where the others auto-repeat, choosing Backquote, Minus or Equal silently
  overrides a tap-key action, and tap-key presses leave the wrap-on-type window
  open.
- [~] **31.** HS-274 exact physical key accounting with an Ergopti-owned
  background Karabiner runtime (no Karabiner-Elements app). Plan, decisions and
  ADR 011 in the overnight handoff and `static/ergopti_plus/docs/adr/`. WP0-WP2
  are published (decision record, one accounting policy whose default `legacy`
  mode is byte-identical to dev.147, HID usages with aliases in
  `_shared/data/keycodes/hid_usages.json`, a key-identity policy). Remaining, in
  order: WP3 production consumer owner (plan section WP3 lists the review notes:
  settle held modifiers when the source changes, map a refused producer version
  to one unavailable WARNING), WP4 headless fork producer emitting baseline v2
  (the native harness refuses early until then), WP5 reproducible runtime
  artifact, WP6 install/launchd ownership and the default-on "close other
  Karabiner instances" option, WP7 owned configuration, WP8 native acceptance,
  WP9 real-Mac acceptance (internal keyboard: verify the ISO 0x35/0x64
  assumption and fn/globe), WP10 enable and retire. Open: an identity for media
  keys without a macOS keycode (play/pause, track skips, brightness), and a
  VirtualHIDDevice version-skew policy. About 30-40 agent-days plus maintainer
  hardware time.

## Remaining work after the 2026-09-30 releases

- [ ] **33.** Config policy for the files other than config.toml (the former
      item 25): Published in the second 2026-09-30 release for the files the review
      listed; see `docs/memory/text-input-and-config.md`. Still open everywhere:
      sites 76 (no catalogue of parameter bindings), macOS 14/93 and order overrides
      (no "catalogue published" signal), 16/91 (expert `[script]`/`[features]`
      layer), 18 (dynamic model list), 19, 24, 26, 28, a Karabiner key bound to a
      plain string (saves refused with a generic ERROR), Linux layers.toml refused
      as a whole still stops the daemon, Windows sites 32, 34, 36, 37-60 and its
      whole-file installed.json refusal, repeated Windows tap_hold unknown-field
      warnings, and the macOS boot-time unread-entries scan cost (36-56 ms on the
      main thread). Two maintainer decisions are pending: config_migrate's
      fail-closed guard for invalid stamps (site 108) and a migrations.toml
      exception for key removals handled by the cleanup (site 112).
- [ ] **34.** Item 5 follow-ups: the macOS Hotstrings scope leaves delimiter
      states as they are (Windows and Linux reset the shipped ones), check that the
      Windows « recommended » delays equal the manifest recommendation, and a
      hand-written `[[hotstrings.terminators]]` list is applied with a warning but
      cannot be edited from the menu.
- [ ] **35.** Item 13 remainder: unregister the remap guardian LaunchAgent when
      the Karabiner switch goes off or « Retirer Ergopti de Karabiner » runs
      (headless unregister role in the launcher, verified on a Mac).
- [ ] **36.** Packaging remainder (the former item 21): macOS release archive as
      `.tar.xz` (verify Sparkle, the Homebrew cask and CI install first).
- [ ] **37.** Item 23 decisions: whether « Hotstrings Ergopti » should appear
      only when the layout is really installed (today: always, shipped copy), and
      whether to move distancesreduction `qu`, `comma_j`, `comma_far_letters`, the
      `ê` sections, French `suffixes_a` and the magickey `replace` section into the
      Ergopti extension.
- [ ] **38.** Real-device checks the container cannot run: macOS tap-holds and
      the guardian's Login Items steps, the Homebrew install writing settings
      (provenance fix), Windows tooltip rendering on 10/11, every new menu row and
      the wizard re-run on the three OSes; on a Mac with an Ergopti layout,
      startup logs no « Lease-bound input startup failed » ERROR and no
      « Layout poll detected change » between the two names of one layout; every
      settings menu opens with its switch, « Restaurer les valeurs conseillées »
      and « Tout effacer » (no question asked), Configuration offers the global
      clear, and the macOS Gestures menu shows its conflicts row after them; the
      layer editor shows the input source legends and the wheel slots run volume
      only while the layer is held; Right Option + Return, Delete, Backspace and
      Escape run the script actions out of the box (Linux: AltGr); opening the
      app starts no Python and shows no Rosetta notice; the MLX install works
      behind a company proxy; a rollback from the Versions window swaps the app
      and keeps the previous one.
- [~] **39.** Repository hygiene: the maintainer deleted every temporary backup
  branch on 2026-09-30; agents must not create `backup/*` branches again. The
  finished agent worktrees under `.claude/worktrees/` can be removed; the
  uncommitted test edit left in the `wip/win-tooltip-border-fix` worktree
  (tooltip DPI radius) is the only unsaved change among them.
- [ ] **40.** The packaged-launch gate never builds a Karabiner configuration:
      the CI runners have no Karabiner-Elements, so dev.148 passed every launch
      scenario while every real Mac refused the deploy (« generated rule 1
      manipulator 3 has inconsistent managed conditions », fixed with
      `json-shared-tables`). Add a launch scenario that makes the app build and
      merge its Karabiner configuration in the real Hammerspoon runtime (into the
      runner's own `~/.config/karabiner/karabiner.json`) and fails on any ERROR,
      without needing the Karabiner driver.
- [ ] **41.** Remaining direct `hs.json.decode` calls (ratchet
      `tests/meta/test_json_decode_through_codec.lua`, 21 calls in 19 files): they
      only read what they decode today; move them to `adapters/json_codec.lua`,
      which returns a tree, and lower the baseline. Audit the other hs stubs for the
      same kind of divergence from the native behaviour.
- [ ] **42.** config.toml batch writer follow-ups (`toml-batch-existing-key`):
      an old build's scalar where a table is now expected (`magickey = true` under
      `[hotstrings.modules]`, `groups = "x"`) still makes a menu save fail with «
      the batch cannot address the destination without ambiguous TOML keys » —
      maintainer decision: may an ordinary save overwrite a value flagged outdated?
      Hand-written dotted keys (`a.b = 1`) are read by the shared decoder as one key
      named "a.b", so the app ignores them. Linux still refuses to save over a
      `[[hotstrings.terminators]]` list (`terminator_settings.lua`) although the
      writer now can.
- [~] **43.** A Mac upgraded from a pre-lease release could not deploy (dev.149:
  « Merge aborted: 25 ambiguous legacy ErgoptiPlus rules … matches the
  historical CapsWord anchor »): its karabiner.json keeps an untagged historical
  block the merge cannot prove. The refused deploy now offers « Retirer les
  anciennes règles » (listed, confirmed, backed up next to karabiner.json), also
  from a Tap-Hold menu row while the rules are pending
  (`karabiner-legacy-cleanup`); untested on a real Mac. Still to do: find why
  the proof fails from the backed-up file.
- [ ] **44.** CapsWord is no longer cancelled by the pointer when Karabiner
      activated it (AltGr + CapsLock): the watcher probed the variable with
      `karabiner_cli --get-variable`, an option karabiner_cli has never had (exit
      2), so it only ever worked for a CapsWord this driver activated; since dev.150
      it stops probing after that refusal (`capsword-probe-unsupported`). Give the
      activation a way to tell Hammerspoon (for example a sentinel key the
      activation rule emits, like the script-control ones) so every CapsWord is
      cancelled.
- [ ] **45.** v0.0.0-dev.150 was published without ErgoptiPlus-linux-noarch.rpm:
      `gh release create` listed the file and exited 0, but GitHub kept 12 of 13
      assets, and published releases are immutable. Create the release as a draft,
      verify every expected asset by name (re-upload a missing one), then publish;
      fail the job if one is still missing.
- [ ] **46.** The AI agent and screen reading on Windows and Linux still send a
      local model Ollama may not have pulled (default qwen2.5:7b, vision
      qwen2.5vl:3b) and report a bare HTTP 404; macOS now checks /api/tags, names
      the missing model and offers its download (`ai-agent-local-model`). Each
      driver needs its own model listing and a hook into its models manager; the
      seven locale keys are shared.
- [ ] **47.** Running local OpenAI-compatible servers (oMLX, LM Studio,
      llama-server/LocalAI, Jan; `_shared/modules/llm/local_servers.json`) are AI
      backends on macOS only (`local-openai-backends`). Windows and Linux need an
      asynchronous probe (WinHTTP, curl), keyless API entries (Linux
      `api_remote.lua` refuses an empty key) and menu rows; the Linux tray has no
      text input for an address or a key.
- [ ] **48.** Enabling the AI when Ollama does not answer is explained on macOS
      only: the AI stays off and one error names Ollama and its address, with a
      button per running local server, "Start Ollama" or "Install Ollama and the
      model" (`llm-enable-unreachable-local`,
      `ui/menu/menu_llm/unreachable_backend_offer.lua`). Linux `llm_toggle` turns
      the prediction engine on without any reachability check, and the Windows tray
      only adds an install row while the Ollama dependencies are missing; neither
      names the address nor offers a start or a running server. Their neutral
      backend is Ollama (`llm.models.selected` `default_per_platform`), so once item
      47 lands a server that answers is the natural first button there; the switch
      must still be confirmed (W1).
- [ ] **49.** Windows keyboard-hook order audit: AutoHotkey removes and
      reinstalls its own low-level keyboard hook around every SendInput (upstream
      `keyboard_mouse.cpp`, `SendEventArray`), so after the driver's first send its
      hook runs before the native arbiter's. Windows guarantees no order anyway: a
      program that hooks later runs first, and a hook that exceeds
      `LowLevelHooksTimeout` is dropped. The prediction navigation no longer depends
      on it (`llm-nav-cycle-windows`), but the paced expansion terminal capture
      still assumes the native hook runs first (the comment above
      `LLM_NavEventOwner_EnsureStarted()` in `ErgoptiPlus.ahk`). Audit every native
      arbiter route, make each one order-independent, and test both hook orders like
      `test_llm_nav_cycle_windows.ahk`. Needs a Windows machine.
- [ ] **50.** Measure SendEvent against SendInput on Windows. While the native
      arbiter's low-level hook is installed, SendInput is interruptible anyway,
      which is the only reason AutoHotkey removes its own hook, so SendInput now
      only costs the rehook of item 49. `ErgoptiPlus.ahk` sets `SendMode("Event")`,
      yet `hotstring_send.ahk`, `hotstring_dispatch.ahk`, `text_sender.ahk` and
      `config_io.ahk` still call SendInput. Measure long expansions, pastes and
      accepted predictions (latency, dropped or interleaved keys) before switching;
      not before the demo.
- [ ] **51.** Windows checks on a real machine for the 2026-09-30 evening fixes
      (AutoHotkey cannot run in the Linux sessions): the four arrows (↑/← back, ↓/→
      forward) and the left and right Shift+Tab over a multi-slot AI prediction move
      the marker once per press, wrap at both ends and never move the caret, also
      right after a reload, with `nav_modifiers` set to ctrl and with a tap-hold's
      Tab tapped under one Shift; the footer shows "⇧G + Tab ou ↑/←"; Tab then
      inserts the chosen slot; the hotstring bubbles and the delayed expansions work
      with the layout emulation off and on; an accepted prediction no longer types
      "eeee"; a Ctrl+V paste adds one row to the clipboard log with the emulation
      off and on; AltGr+Entrée, AltGr+Suppr, AltGr+Retour arrière and AltGr+Échap
      run their script action out of the box, and the « Raccourcis de gestion du
      script » switch makes them native again; opening the versions window
      repeatedly logs no error; the AI menu has no clear row, its Backend row
      reads « API 🌐 » (or Ollama, MLX), and adding an API entry asks no name
      and lists it as `provider/model`; the layer editor shows the emulated
      Ergopti legends and each action; « Revenir à cette version » rolls back
      with a backup; « Désinstaller » is greyed on a source run.

## Maintainer requests on the evening of 2026-09-30

Each item is removed once it is integrated and pushed; what must still be
checked on a real machine moves to item 51 (Windows) or its macOS twin.
Releases: push to `dev` without a release until every item below is
integrated, then publish one grouped release.

- [ ] **54.** Every menu is declared in the shared menu manifest, never in
      driver code. The ratchet `npm run test:native-menu-rows` counts the rows
      drivers still build (baseline: Windows 125, macOS 209, Linux 127, each
      site listed in tools/test/native-menu-rows-baseline.json); migrate them to
      zero. Each OS-limited row declares `unavailable = "hide"` (not
      applicable) or `"grey"` (not yet ported, with its reason); classify the
      existing rows during the migration (proposal in the menu-first-group
      report: most hide; greyed: Linux edit_shortcuts, Linux key
      combinations, Linux metrics shortcut rows, Windows preview_bubbles).
- [ ] **60.** Windows: the registry-layout emulation registers its dead-key
      resets by key name ("~" plus Enter, Escape, BackSpace, Tab), which the scan
      code declarations of the same keys shadow, so the resets never fire; the
      scan-code precedence gate misses names built by concatenation.
- [ ] **62.** Downloads on managed company networks, Windows and Linux:
      system trust store and system proxy for every download child (the Ollama
      installer and server for `ollama pull`, the updater and rollback, remote
      AI APIs), and the shared failure contract (certificate, proxy, host
      blocked, offline, disk, permission) whose dialogs name the cause in
      French with actions that can work. macOS is integrated (uv from a
      checksummed PyPI wheel, `UV_SYSTEM_CERTS`, the `scutil --proxy` relay,
      the `network.failure.*` keys). The Windows and Linux work stayed
      uncommitted in the local worktree of `fix/downloads-on-managed-networks`
      when the session stopped; redo it if that worktree is gone.
- [ ] **63.** Layer actions: add screen brightness up and down (asked as an
      example for the wheel slots), with its key, action and label on the three
      drivers and 21 locales.
- [ ] **64.** Greyed menu rows: the rollback work added `disabled_when` +
      `disabled_i18n` (Uninstall greyed on a source run) next to the menu
      work's `unavailable = "grey"`; render both through one greyed-row path
      and label format, with one schema rule for the reason key.

- [ ] **65.** macOS suite, order-dependent red: "(llm-tooltip-chords-consumed)
      types a digit beyond the predictions, or with no tooltip" fails only in
      the full `lua tests/run.lua` run ("attempt to index a boolean value" at
      `_shared/lua/keymap/terminators.lua:80`) and passes alone: a test that
      runs before it leaves a `package.loaded` slot set to `true`. Find it and
      restore the slot.

## Maintainer requests on 2026-10-01

Every request the maintainer makes is written here first and removed once it
is committed; one request is one commit with its regression test.

- [ ] **69.** Windows: no automatic search for updates every N hours is
      visible to the maintainer, who remembers it on macOS and does not know
      about Linux. The code exists on the three drivers (the shared schedule,
      `windows/modules/updater/schedule.ahk` and `self_update.ahk`, the Linux
      `modules/updater/manager.lua`, the About submenu's `about_updates` list
      with its channel and frequency rows). Found on 2026-10-01: the
      maintainer runs Windows from the repository, and for a local build
      `_MI_AboutUpdateRows` (`windows/ui/menu/menu_init.ahk`) returns after
      the version and the channel picker, so the « check for updates » row
      and the frequency submenu are not drawn at all, with no reason shown;
      an installed build draws both. To do: on a source run draw the two
      rows greyed with the source-run reason, as the Uninstall row is
      (`disabled_reason_key`), check what the macOS and Linux trays do for a
      source run, and compare the three row by row.
- [ ] **71.** Metrics windows: retire what is left of their dedicated
      shortcuts. The two menu rows that set them are gone on the three
      drivers (2026-10-01): a shortcut that opens a metrics window is assigned
      in the Gestures or the Shortcuts menu, to `open_metrics_typing` or
      `open_metrics_apps`, which the catalogue declares for every driver.
      What remains is the machinery behind the removed rows, which still
      binds a shortcut already stored: on Windows the manifest features
      `metrics.metrics_shortcut_typing` / `metrics_shortcut_apps`, their
      loading (`config_shortcuts.ahk`), saving (`config_io.ahk`), binding and
      prompt (`infra/metrics/metrics_shortcuts.ahk`, `MS_ApplyAll` at boot)
      and six test files; on macOS `metrics.shortcut` / `metrics.apps_shortcut`
      with `apply_metrics_shortcut` / `apply_apps_time_shortcut`
      (`ui/menu/init.lua`, `menu_state.lua`, `preferences.lua`) and their
      tests; the locale keys `menu.metrics.shortcut_*` and
      `metrics.shortcut_*`; and the second half of the Linux reason
      `platform_reason.metrics_extras_are_not_on_linux`, which still speaks
      of a shortcut.
- [ ] **72.** The Windows suite is red on `dev` before any of today's work
      (run on a real Windows 11 on 2026-10-01, 10 of 7 567 tests, the same on
      the tree of 3e6c45827):
      `menu_models.ahk:106` reads a local variable that was never assigned,
      which fails five AI menu tests (backend-row-selected-option twice,
      llm-menu-build-submenu, ai-menu-no-clear, category-toggle-checkbox) and
      very likely « restore-recommended-no-confirm: AI restores without a
      dialog »; `modules/updater/release_install.ahk` opens a LoggerStart it
      never closes (logger pairing); updater-consent-2026-09-25 counts four
      download starts for two allowed; the AHK-15 persistence census counts 26
      TOML writers for 25 audited; and AHK-901 no longer finds
      `DirDelete(RTrim(CaptureDir` in `ShellRunner_Exec`. Also, the
      hardening-c label count test walks into the local, git-ignored
      `_generated/personal_shortcuts.ahk`, so it fails on a machine whose user
      has personal shortcuts.
- [ ] **73.** Windows: the magic key's hotstrings do nothing. « ct★ » does
      not become « c'était » and no tooltip shows (reported on 2026-10-01,
      on the maintainer's machine run from the repository). Diagnosis so far,
      from that machine's files: « ct★ » is a French magic-key hotstring
      (`_shared/modules/hotstrings/french/magickey.toml`), and its config.toml
      holds `category_enabled.french_magickey = false`, already in the
      backups of 2026-09-30 18:06, while `magic_key`, `french_autocorrection`
      and `french_distancesreduction` are on; the boot log says « 3 forced
      off by a disabled category ». So the engine obeys the file. Still to
      settle with the maintainer: whether the Hotstrings › Français › magic
      key switch turns it back on from the tray, and which action left the
      three French categories off on 2026-09-30 (a restore, a clear or the
      wizard) when the maintainer expected them on.
- [ ] **74.** Windows: every start rewrites config.toml with 347 updates
      about three seconds after the driver is ready (15 to 30 ms, 2 360 ms on
      a loaded machine). A reload asked during that write now waits for it
      (`reload-during-config-write`); find why a start that changed nothing
      writes the whole file, and make it write only what changed.

## Time estimate

Budgetary estimate: 20–35 hours of effective work for all remaining product and
verification tasks, with uncertainty around native input and multi-file
transactions. The earlier six-hour estimate was too optimistic. The immediate
integration/handoff comes first; do not spend the remaining weekly quota on new
features while leaving uncommitted work or external-only specifications.

## Current local evidence

Portable specifications, pending changes, branch accounting and verification
results are in [the handoff package](handovers/2026-09-28-ergoptiplus/README.md).
Read its `VERIFICATION.md` and `VERIFICATION.json` for composite gate results.
Paths under `D:/ewt/` in those files are historical; that directory no longer
exists.
