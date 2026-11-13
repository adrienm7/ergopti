<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-11-13. Latest stable: [v1.0.9](https://github.com/adrienm7/ergopti/releases/tag/v1.0.9).
Conventions and tags: [workflow and verification memory](docs/memory/workflow-and-verification.md). Finished items are in Git
(`git show 932e70d583:TODO.md` is the long form before the 2026-11-12 cleanup).

This file lists features and fixes. The checks only real hardware can answer are in
[TODO-tests-macos.md](TODO-tests-macos.md), [TODO-tests-windows.md](TODO-tests-windows.md) and
[TODO-tests-linux.md](TODO-tests-linux.md).

## Resume here (2026-11-13 evening, read first)

Any agent can continue from this section alone: the maintainer answered every open question on 2026-11-13 and
wants the whole list done without them. Follow [AGENTS.md](AGENTS.md) and the skills it routes.

### How to work alone

- **Push rights.** `dev` may be pushed only when the maintainer's starting message in your conversation says so
  (the 2026-11-13 hand-off message does). Before each push: `git fetch origin dev && git rebase origin/dev`, then
  `git push origin HEAD:refs/heads/dev`. Never force-push, never a merge commit on `dev` (rebase branches, do not
  merge `dev` into them), never `main`, never a tag or release, never a `Dev-Prerelease: yes` trailer (a plain
  push to `dev` publishes nothing). No `Co-Authored-By` or `Claude-Session` trailers. Do not touch
  `remap-runtime-v16.3.0-ergopti.6`, `vendor/remap-runtime/manifest.json` or the ci-seed tags.
- **Before each commit:** `node tools/lint/format.cjs --check` (needs Ruff 0.15.8 first on `PATH`) and
  `node tools/lint/lint-conventions.js --fail-on-violations`; never bypass the pre-commit hook.
- **A change is done** when local gates pass and CI on the three OS (ci.yml, `os_lanes=all`, Windows allowed)
  shows only the reds listed below; then land it on `dev` in a small linear block.
- **New design questions:** pick the safest option that follows AGENTS.md, write « decided by the agent on
  <date>, to review by the maintainer » on the item, and keep going. Do not stop to wait.
- **Do not end a turn while work remains.** Wait for CI with a background poll and work on the next item meanwhile.
- **Never** rewrite the « To confirm on the Windows PC » section, never commit a non-anonymized field report, never
  cancel a CI run you did not start, never use `git stash`, `reset` or `clean` as shortcuts.
- Keep this section current at each landing (state, next item).

### Order of work

1. **Folder migration by OS (structure plan).** Plan: [docs/design/structure-plan.md](docs/design/structure-plan.md).
   Work branch `claude/ergopti-todo-structure-phase2-night` (linear on `dev`; the older `…-phase2` is frozen).
   Read its `docs/plans/structure-migration-resume.md` first: base commit, steps done with proofs, next command,
   traps, maintainer decisions. One step per commit with `tools/audit/structure/apply-step.cjs`. State at 21:00
   Paris (2026-11-13): S01 and S02 are on `dev` (landed 16:50, 42f8c1327, CI run 43430776650). S03–S05 proof 16
   (run 43481259457) failed and is being triaged. 33 steps remain; the approved shared module predicate handles
   the Lua module-prefix sweeps. Land in blocks of a few steps.
2. **The maintainer decisions of 2026-11-13 below** (section « Maintainer decisions of 2026-11-13, to implement »).
3. **« Remaining code work »**, then the feature sections, then « CI acceptance ». Items that need real hardware
   or a release stay for the maintainer; say so on the item and move on.

### Reds `dev` already has (2026-11-12 evening), the baseline a change is compared with

Windows Unit tests (meta, `desktop-ci-evidence`); Windows Build (AV-surface ceilings, item below); Linux E2E
desktop-webview, updater, platform-metrics, input-display; Common Shared ui (App Cloner generated literals); Common
Packaging and boot (Linux uninstall EX_UNAVAILABLE, Arch desktop entry); macOS release Darwin receiver. Known
flakes: macOS Intel Managed Ollama Go test `TestCancellationAndConcurrentClosePhysicallyRetirePeer` (passes on
rerun); a macOS cold-bootstrap job whose runner is lost (no log).

### Maintainer decisions of 2026-11-13, to implement

- [x] **One-shot modifiers (OSM-002 and beyond).** Timeout (decided 2026-11-13, replaces the 2026-11-06 refusal of
      0 and unlimited): `0` means « no time limit » on every OS. Today each OS asks the delay in a numeric box that
      accepts only a positive whole number (`TapHoldValidOneShotTimeoutMs`, Linux `valid_one_shot_timeout_ms`, the
      macOS `sticky_dialog` prompt): accept 0 there and in `config.toml`, say « 0 = no time limit » in the prompt
      and show « no time limit » in the menu label (`menu.tapholds.*`, 21 locales through the i18n skill); keep
      refusing negative or non-integer values. Any positive value stays valid, no other minimum (a fast typist
      presses the next key almost at once). Features: make sure every one-shot exists on Windows, macOS and Linux,
      single and combined: Shift, Ctrl, Alt, AltGr, Kana, Win/Cmd, and chords such as Ctrl+Shift or Win+Ctrl; a key
      can tap one modifier's one-shot and hold that modifier (AltGr key: one-shot AltGr on tap, AltGr on hold).
      Shared defaults, tests per OS.
      Claimed by worker A (branch `claude/ergopti-todo-oneshot`). Progress:
  - [x] Timeout `0` = no time limit on the three OS: one rule per OS, ready for the shared validation schema
        (`_shared/tap_hold/engine/one_shot_timeout.lua` for macOS and Linux at entry, load and engine boundary;
        `TapHoldValidOneShotTimeoutMs` and `TapHoldOneShotHookTimeoutOption` on Windows); prompt says
        « 0 = no time limit », menu label `menu.tapholds.sticky_no_limit` in 21 locales; negative and
        fractional values refused.
  - [x] Every one-shot on every OS: Linux runs the fifteen `sticky_*` actions in its tap-hold engine
        (`arm_sticky`), and `sticky_altgr` / `sticky_altgr_shift` exist on the three OS. One action covers AltGr
        and Kana: the layouts compile their Kana layers to the AltGr level, and Windows sends the layout's own
        AltGr key, Kana on a Kana-style layout (decided by the agent on 2026-11-13, to review by the maintainer).
  - [x] Tap = one-shot of a modifier, hold = that modifier: every OS takes a `sticky_*` action as a tap-hold tap
        (Right Ctrl already ships one-shot Shift + Shift); the AltGr pair is pinned by tests per OS. The shipped
        AltGr key keeps its Tab tap (decided by the agent on 2026-11-13, to review by the maintainer).
  - Hardware checks are in TODO-tests-windows.md, TODO-tests-macos.md and TODO-tests-linux.md.
- [ ] **One validation contract for every user-entered value (maintainer request 2026-11-13).** Every input box,
      editor field and `config.toml`/TOML key on Windows, macOS and Linux declares its type (integer, decimal,
      boolean, enum, string, path), minimum, maximum, whether decimals are allowed and any special value (such as
      the one-shot `0` = no limit), in one shared schema per setting (single source, read by the three drivers and
      the web pages). Check it at three places: (1) at entry, refusing with a localized message that names the
      allowed range; (2) at load of the saved configuration, reporting and logging a bad stored value and keeping
      the default, never silently; (3) at the consuming code's boundary, where the value reaches the engine (a
      setter, a timer, a Karabiner/ydotool/AHK call), so a value altered after load (a string instead of a number,
      NaN, out of range) fails fast with a log line instead of crashing. Start with an inventory of every prompt and
      key per OS, then regression tests per OS that feed a wrong type, a boundary and an out-of-range value at each
      of the three places.
- [ ] **Direct XKB and KLC compilers.** Replace the compiled `.keylayout` as the intermediate form for Linux and
      Windows: compile the Ergopti TOML source straight to XKB and to KLC, using each format's full capability
      (XKB levels 3 and 5 on any key and sided modifiers; KLC Kana/Roya/Loya bits), so sided-modifier layers are
      no longer dropped. What a format truly cannot express goes in the per-target omission report and is emulated
      by the driver. The existing layouts stay byte-for-byte regression fixtures.
- [ ] **Layout editor in its own window on the three OS.** Move the unified editor out of the layout manager
      window into a separate window (macOS, Linux and Windows), and give the Windows WebView2 host
      `source_open`/`source_save`/`source_editor` so Windows also replaces the old composer.
- [ ] **XKB and KLC downloads generated by the local host.** The app's editor page no longer sends the user to the
      site for these two files: the host generates them with the shared code, offline.
- [ ] **COSMIC focus: support `zcosmic_toplevel_info` v1 and v2+** (v2+ announces windows through
      ext-foreign-toplevel-list); choose by what the compositor offers, with tests for both.
- [ ] **GNOME layout switch through the Ergopti GNOME Shell extension** (the one planned for focused-app identity),
      instead of rewriting the `sources` list; keep a clear refusal when the extension is absent.
- [ ] **GTK 3 Compose:** enable IBus for Compose when no input method is active; never replace an active fcitx5;
      keep the inlined single-character rules as the safety net, and state the remaining limit in the menu.
- [ ] **UPD-2 on AHK confirmed:** manual checks, changelog/Versions windows, channel and interval settings and the
      update prompt run while paused, as on macOS and Linux; background checks keep their pause drop.
- Validated as they are: structured import keeps action/state names and modifier tokens; the editor page compiles
  and the host never recompiles; macOS ANSI swaps are declared per layout; Unicode names inlined in the app and
  lazy on the site; KMD-3 Linux `awake_ms`; MRT-004 `core.json` fence; resting-thumb bounds (tighten from the next
  Mac report); custom logs folder named `ergopti_plus` renamed to `Ergopti`; a superseded site deployment stays
  red; macOS marks a keyless API entry when its key is read; the navigation-owner DLL fingerprint derived by the
  migration (byte identity to confirm on the Windows PC, see TODO-tests-windows.md).
- **Hardware checks** are in [TODO-tests-macos.md](TODO-tests-macos.md),
  [TODO-tests-windows.md](TODO-tests-windows.md) and [TODO-tests-linux.md](TODO-tests-linux.md).

## Windows CI reliability (2026-11-07)

- [ ] **[MACOS] Issue #106, owned Karabiner runtime not admitted (Clem, dev.166, macOS 27.3; the maintainer's
      Mac too):** rules stay fail-closed. The misleading « lease auto-recovery exhausted » error is gone (the
      recovery stops while the runtime waits for admission), and the installer helper refusal now names its cause
      (`helper_signature_invalid`, `helper_signature`, `helper_code_hashes`). The helper of
      `remap-runtime-v16.3.0-ergopti.3` and the dev.166 launcher carry the same leaf (759d8aae…), so the leaf is not
      the cause. Next: the `remap.runtime_owner` lines (« unavailable: <reason> ») and `launcher.log` « owned runtime
      install: refused (…) » of a build with these fixes.
- [ ] **[RELEASE] Dev naming handoff:** everything is on `dev`. `v0.0.0-dev.169` is the bridge (ci.yml keeps the
      legacy core up to counter 169), then `v1.0.10-dev.170`; the next merge to `main` carries
      `Release-As: 1.0.10`. Delete the orphan draft `v0.0.0-dev.167` by hand (this session cannot delete releases).

## Layout generator from an Ergopti TOML source (maintainer request, 2026-11-06)

Large project: an Ergopti equivalent of [kalamine](https://github.com/OneDeadKey/kalamine), going further. Take
ideas from kalamine and KbdEdit, never their code: write every generator from the formats' own documentation, so
that no MIT notice has to ship.

Decided 2026-11-06: the source of truth is an Ergopti layout file in TOML, a superset of every target. A macOS
`.keylayout` cannot hold extra modifiers (Kana, Roya, Loya, a held key as a layer), lock layers other than Caps
Lock, physical key remapping, shortcuts that send another key than the typed character (Ctrl+A giving Ctrl+B),
KbdEdit's special functions and Windows flags, export settings, nor Ergopti's own features (tap-hold, emulated
layers). The `.keylayout` stays a first-class format: imported without loss and exported. No custom element goes
into an exported `.keylayout`, since macOS may refuse to load it.

- [ ] **The same UI inside ErgoptiPlus.** The editor page runs locally in the app's webview on Windows, macOS and
      Linux. It installs or emulates the result and switches to it from the menu.
      Progress (2026-11-11): macOS and Linux open the editor from the layout manager window and save its files through the host (`layouts/source_store.lua`, `layout_sources/` of the configuration folder). Windows: the WebView2 host needs `source_open`/`source_save` and `source_editor` in `windows/ui/layout_manager/init.ahk` as described in [layout-editor.md](docs/design/layout-editor.md#hosts); the page hides the button there meanwhile (decided by the coordinator on 2026-11-11 overnight, to review by the maintainer). « Install and use » sends the source and its compiled `.keylayout` through the composer host, which installs it as the composed layout and switches to it (macOS defers to the next login when it must). Linux, in a container (2026-11-11): `tests/hardware/run_layout_editor_webview.lua` opens the real layout manager window in WebKit2GTK under Xvfb, clicks « Editor », opens the Ergopti source, « Install and use », « Yes »; the composer host stores the source and the page's Linux emulation table, installs the composed layout, and the server's keymap read back after loading it types a/A, the Kana level on AltGr (<, œ), ê on the ISO key and $ on `TLDE` (CI step « Install a layout source from the editor in the daemon's WebView », desktop-webview shard). The installer refuses to write a desktop setting as root, so a root run checks that refusal and a user run checks the switch. Proven as a regular user on CI run 43105583384 (desktop-webview): installed and selected, the GNOME input sources start with the composed layout, 27/27. The same probe first runs « Emulate without installing »: nothing installed, `composed` becomes the emulated layout, and the daemon's emulation types a, ê and $ for KeyA, IntlBackslash and Backquote from the composer folder's copy. Entry point (2026-11-11, maintainer request): « Create or edit a layout… » in the Keyboard layout menu opens the editor directly (macOS, Linux; greyed on Windows with its reason); « New » starts blank or from QWERTY, AZERTY, Bépo, Ergo-L or Ergopti; « Install on the system » and « Emulate without installing » (`composer_emulate`: no system install, no admin; the emulation reads the composer folder's copy) each say what they do; the site page links ErgoptiPlus and its downloads and says the Windows DLL and installer come from `tools/kbd-dll.cjs`. Left: a native check of that install on a Mac and on a real Linux desktop (GNOME, KDE), the Windows host (`windows/ui/layout_manager/composer.ahk` accepts no source yet), and a Mac check of the native open panel the macOS host now shows for « Open » (`source_pick`).

- [ ] **Sign the generated Windows layout DLLs.** The four DLLs, the uninstaller and `<dll>-setup.exe` (SHA-256,
      RFC 3161 timestamp) once SignPath or the release PFX is on, as `docs/design/layout-windows-dll.md` « Signing » says.

- [ ] **Keyboard types JIS and ABNT.** Deferred on 2026-11-11: their keys (Yen, Ro, Henkan, Muhenkan, Kana, keypad
      comma) would enter `physical_keys.json`, which the Windows driver parses at boot; add them once that cost is measured.

- [ ] **Retire the composer and the navigation layer editor.** The Windows host takes a source since 2026-11-12: delete
      the composer section (`layout_composer/composer_page.js` and its markup), then retire `_shared/ui/layer_editor` and
      its three hosts once every driver reads the source's `nav` layer.

## Parity audit pause and resumption

The [coverage and remaining-work register](docs/platform-parity-audit.md#review-status-at-pause--november-5-2026)
records the focused campaigns already completed, broader reviews, exact limits
and the next module candidates. The audit is paused at the maintainer's request.

- [ ] **[CODE] Parity audit continuation:** on resumption, reconcile current source areas with the linked coverage register, then deepen tap-holds/chords/layers as one bounded module across Windows/macOS/Linux/shared before moving to another. Keep native receiving and implementation of existing finding IDs separate; do not restart completed focused campaigns without source drift or a new hypothesis.
      Progress (10 November 2026, [tap-hold campaign](docs/audits/platform-parity/2026-11-10-tap-holds/report.md)): census reconciled (375 areas, 12 new and 206 changed since the last pinned census, still to review outside tap-holds). Fixed on Linux/shared: LAlt's Tab tap with no hold is tap-only (THL-001), the Alt-Tab and RCtrl Tab taps keep their strict threshold (THL-002), a pair starts from the earliest held first key (THL-003), a pair's release tap respects the decided tap minimum (THL-004), chord defaults pinned across drivers (THS-001). Decisions pending: THD-1, THD-3, THD-4 (pair tap and the layer, layer-hold pair activity, macOS thumb Backspace under modifiers) and THD-2's lone window. Minimum tap (decided 2026-11-10): Linux complete; macOS needs a Karabiner mechanism qualified on a Mac (`to_if_alone` has no minimum); Windows is the maintainer's change. Left: the report's Linux and macOS remaining rows; native receiving unqualified. Next module after this one: hotstring cascade.
      Progress (12 November 2026, [tap-hold follow-up](docs/audits/platform-parity/2026-11-12-tap-holds-followup/report.md)): register reconciled with the 24 campaigns since the pause (381 areas). Drift since `637c017a` reviewed: fixed a single foreign chord action turning every Linux key combination off (TCL-003). Open for the shared tap-hold file series (`wt/taphold-landed`): TCL-001 (manifest rows still in `tap_hold.toml`), TCL-002 (action ids not translated between macOS and Linux), TCL-004 (Mac thumb-key ids, a decision), TCL-005 to 007; the two 2026-11-10 macOS rows are fixed in the generator, proven on the model (Left Command's one-shot Shift holds Shift and stands down under modifiers; a pair takes the first key held earliest), with field points `lalt_one_shot` and `pair_press_order`.
      macOS minimum tap (11 November 2026): done in the generator. Each release-judged tap, a pair's included, is gated on a lease-scoped variable a `to_delayed_action` raises after `tap_hold.tap_min_duration_ms` (Karabiner v16 evaluates a to-event's own conditions when it posts it); the rollover keys keep no minimum, as the Linux roll keys. Generator test `test_generator_tap_minimum.lua`, corpus vectors without their macOS divergence; native timing under « To confirm on the Mac ».
      Progress (11 November 2026, [hotstring cascade campaign](docs/audits/platform-parity/2026-11-11-hotstring-cascade/report.md)): census 377 areas (14 new, 212 changed since the pinned census); module taken: hotstring cascade and trigger arbitration. Fixed: macOS takes each cascade link from the typed matcher's winner (HCM-001 to 004), macOS undoes the magic-key repeat and a stripped-space expansion (HCM-005, 006), Linux restores the typed casing and reports a refused or private undo correctly (HCL-001 to 003), inventory rows for the macOS undo and the Linux repeat window (HCS-001). Decisions pending: HCD-1 (an expired best candidate: macOS falls to a lower rule), HCD-2 (bare `:`/`;` end a trigger on macOS only), HCD-3 to 5 (named personal tags, delay on `@` tags, uppercase one-letter tag; privacy). Left: macOS date delay, the `+33` short trigger on macOS/Windows, the Windows rows of the report; native receiving unqualified.
      Progress (12 November 2026, [hotstrings engine campaign](docs/audits/platform-parity/2026-11-12-hotstrings-engine/report.md)): drift since the cascade campaign and the sending path reviewed. Fixed: the Linux terminal erase is paced after each Backspace, as on Windows and macOS (HSE-001). Decided by the maintainer on 2026-11-12 and done: the short entry forms load everywhere (HSE-002), a no-break space counts as a space inside a trigger (HSE-003), a letter magic key follows the word's case on macOS as on Windows (HSE-004); Windows lines below.
      Continued (11 November 2026, branch `claude/ergopti-todo-parity-audit`): the two reports' Linux, macOS and docs rows. Linux: LAlt's Tab under RCtrl's one-shot Shift types Shift+Tab (THL-005), LAlt tapping Backspace on the layer is swallowed before a user binding (THL-006). macOS: the `+33` short trigger keeps every digit of a number stored without its zero, through one shared helper (HCM-007), the date hotstrings respect the dynamic family's delay (HCM-008). Windows, report only: the `+33` short trigger drops the first digit of such a number (`dynamic_hotstrings.ahk:199`). Left: the macOS one-shot rows of the tap-hold report (Karabiner generator), the Windows rows; native receiving unqualified.
      Progress (11 November 2026, [gestures campaign](docs/audits/platform-parity/2026-11-11-gestures/report.md)): module taken: gestures and touchpad event ownership. Fixed: an incremental diagonal is counted and reversed along its own axis on macOS and Linux (GSS-001), a moving swipe locks or counts only a decided axis outside the diagonal band (GSM-001, GSL-001; a drift with its diagonal unbound falls back to its dominant straight slot on macOS and Linux, a bound diagonal still wins inside the band: decided by the maintainer on 2026-11-11), Linux releases a gesture's click hold at the next key press (GSL-002). Decided by the maintainer on 2026-11-11: GSD-3 (a pair swipe decides from 3.0 mm, diagonal 5.0 mm, on Linux as on macOS, one value in the shared timings registry `[gestures]`; the slot's step stays the user's). Decided by the maintainer on 2026-11-11: GSD-2 (the Linux decoder's swipe minimum and pair-scroll travel are millimetres through the pad's resolution, 10 mm each from the shared timings registry). Decision pending: GSD-1 (macOS live x1 fires). Left: a physical mouse click releasing the Linux click hold (no pointer observer), native receiving unqualified.
      Progress (11 November 2026, [metrics campaign](docs/audits/platform-parity/2026-11-11-metrics/report.md)): module taken: metrics beyond the WPM widget. Fixed: the Linux ledger import admits text carrying a CR or a NUL (KML-001, a stuck device before), an imported Windows device's Wi-Fi changes on Linux and macOS (KML-002, KMM-003), no connectivity, topology or capture row under an excluded context on Linux and macOS (KML-003, KMM-002), an imported device's system rows on their own date on Linux (KML-004 part). macOS also arms right_option's no-hold one-shot Shift only on a quick release (tap-hold report). Decided by the maintainer on 2026-11-11: KMD-2 (non-typing rows are refused under an excluded app on every OS; verified on Linux and macOS, closed) and KMD-3 (Linux `awake_ms` is keep-awake time as on Windows and macOS; old Linux days cleared once and marked, decided by the coordinator on 2026-11-11, to review by the maintainer). KMD-1 (rows store `ts` in UTC and `utc_offset_min`, hours, night wakes and days use the recorded offset, an older Linux row the reader's current offset; Linux and macOS writers, migration, purge triggers and rebuilds done). Left: the Windows counterpart of KMD-1 (cache migration, UTC writers, `keystats_walker_events.ahk`; blocking for an existing Windows cache, see `docs/memory/maintainer-decisions.md`), native receiving unqualified.
      Progress (11 November 2026, [AI flows campaign](docs/audits/platform-parity/2026-11-11-ai-flows/report.md)): module taken: AI request-to-output flows. Fixed on Linux: a refused Backboard assistant creation (AIL-001) and a refused token exchange (AIS-001) are refused credentials, never retried; a failed streamed attempt's partial is withdrawn before its retry, which no longer streams (AIL-002). Decided by the maintainer on 2026-11-11: AID-1 (the macOS quick retry spends an attempt of `max_attempts`, two requests at most for one prediction at multiplier 2, as on Windows and Linux) and AID-2 (a token exchange answering 400 is a refused key, never retried, failing with the service's message; shared classifier and exchange reader, Windows mirror of both corpora left to the maintainer) and AID-3 (a model, key, provider or endpoint change retires the request in flight on macOS and Linux, as on Windows; shared `llm.request_settings`). Left: the macOS counterparts of AIS-001 and AIL-002 (source only, to replay first), native receiving unqualified.
      Progress (11 November 2026, [input/layout campaign](docs/audits/platform-parity/2026-11-11-input-layout/report.md)): module taken: remaining input/layout engine joins. Fixed: a moved macOS Cmd chord is released on its own key code (ILM-001), an emulated shortcut falls back to its character's US key under a non-Latin layout on Linux and macOS (ILL-003, ILM-002), an emulated Linux chord repeats while held (ILL-004). Fixed (order decided by the coordinator on 2026-11-11, to review by the maintainer): a bound shortcut slot and the prediction's digit run before the Linux layout emulation (ILL-001, ILL-002); open: the slot still matches the system layout's key, not the emulated letter. ILD-1 decided by the maintainer on 2026-11-11 (a two-modifier chord sends the logical key everywhere): macOS and Linux pinned, Windows counterpart in the report. ILD-2 decided by the maintainer on 2026-11-11 (Ctrl+AltGr sends Ctrl and the logical key, AltGr suspended, on every OS: Linux already, macOS done, shared vector, Windows counterpart below). Left: a tap-hold modifier's repeat over a passed key on Linux, native receiving unqualified.
      Progress (11 November 2026, [shortcuts campaign](docs/audits/platform-parity/2026-11-11-shortcuts/report.md)): census 377 areas (47 changed areas under modules campaigned since); module taken: keyboard shortcuts and text actions. Fixed on Linux: a held accented shortcut repeats like Windows (SCL-001), the accented shortcuts stand aside while a layout is emulated (SCL-002). SCD-1 decided by the maintainer on 2026-11-11 (no Linux keyboard slot runs through a pause; the shared paused actions list replaces the prefix test). SCD-2 and 3 settled with ILD-1 and ILD-2 (Ctrl+Alt+é sends Ctrl+Alt and the logical key; a Ctrl slot fires under AltGr, AltGr suspended; Linux already does both, Windows counterparts below). Next module: the updater. Left: macOS `bindings.lua` and Linux `key_combinations.lua` in depth, native receiving unqualified.
      Progress (11 November 2026, [updater campaign](docs/audits/platform-parity/2026-11-11-updater/report.md)): module taken: the updater, from the census. Fixed on Linux: a failed background check announces no release (UPL-001), the notification of a manual check without its window words each outcome (UPL-002), a release read from the public feed says it cannot be installed yet (UPL-003). UPD-1 decided by the maintainer on 2026-11-11 (a 200 that does not open a JSON array, and a Linux 304 with no usable cached page, are « no connection » with the feed fallback, through the shared `opens_release_array`; Linux and macOS done, Windows counterpart below). Windows, report only: UPW-005 (the signing policy compared case-insensitively). Left: the macOS manual check without its window, native receiving unqualified.
      Progress (12 November 2026, [network campaign](docs/audits/platform-parity/2026-11-12-network/report.md)): areas taken: proxies, trust, deadlines, downloads, request privacy. Fixed on Linux: a Negotiate company proxy is answered with the session's ticket (NET-002), the AppImage trusts openSUSE's CA bundle (NET-006), the unread download timeout copy is gone (NET-004); on Linux and macOS a local Ollama request gets the shared 180 s cold-load budget (NET-003). After review: the macOS remap downloads run behind the system network route (NET-001). Decided by the maintainer on 2026-11-12: the macOS no-token stream watchdog is removed, and the release archive has one shared budget (1,200 s absolute, 600 s idle) read on macOS and Linux, the Windows side listed below. Left: ExcludeSimpleHostnames on macOS (NET-005).
      Progress (12 November 2026, [layout manager campaign](docs/audits/platform-parity/2026-11-12-layout-manager/report.md)): module taken: the layout manager window's host on macOS and Linux. Fixed: the emulation reloads when the emulated layout is uninstalled, removed, updated or re-saved, the stored choice kept as decided by the maintainer on 2026-11-12 (LMH-001, 002; Windows line below); a paused driver admits only the page's ready signal (LMH-003); a layout shipping hotstrings reloads the driver (LMH-004); the Linux tray follows « Emulate without installing » (LMH-005); the last source reopens through a bounded UTF-8 read (LMH-006) and the store reads its export name and codes from the shared defaults (LMH-007). Native receiving unqualified.
      Progress (12 November 2026, [bundled apps campaign](docs/audits/platform-parity/2026-11-12-bundled-apps/report.md)): module taken: App Cloner and Encryptor on macOS and Linux. Fixed: a folder destination is refused instead of reported as decrypted (BAP-001), macOS browser clones get their own profile (BAP-002), cancelling one overwrite skips only that file on macOS (BAP-003), the Linux item to open is validated as on macOS (BAP-005), a second clone of a name gets its own Linux menu name (BAP-006), a refused write names its reason (BAP-007). Open: BAP-004 (VSCodium and Insiders settings, a catalogue change Windows reads too), BAP-008 (the Linux Encryptor's « Open with » registration); `main.scpt` to recompile on the Mac.
      Progress (12 November 2026, [layer editor campaign](docs/audits/platform-parity/2026-11-12-layer-editor/report.md)): module taken: the navigation layer editor host on macOS and Linux. Fixed: keys show the emulated layout's characters while one is emulated (LEH-001), the Linux page gets its answer when the folder moves during a save (LEH-002). Open: LEH-003 (a macOS regeneration failing after the window closed is only logged), a maintainer decision.
      Progress (12 November 2026, [webview hosts campaign](docs/audits/platform-parity/2026-11-12-webview-hosts/report.md)): module taken: the page window hosts. Fixed: the Linux hotstrings settings window no longer opens empty (WVH-001), the macOS editor windows are resizable (WVH-002), the native context menu stays closed outside text fields on macOS and Linux (WVH-003). Left: a macOS minimum window size, which hs.webview cannot set.
      Progress (12 November 2026, [AI flows follow-up](docs/audits/platform-parity/2026-11-12-ai-flows-followup/report.md)): drift since the AI-flows campaign and the selection actions reviewed. Fixed: the tone and translation actions refuse in an app excluded from the AI on Linux and macOS, as on Windows (AIX-001); the Linux key migration ends quietly when a save moved the keys (AIX-002) and a shutdown discards the keys an attempt stored (AIX-003). The campaign's leftover Linux retry row is parity with Windows. Native receiving unqualified.
      Progress (12 November 2026, [configuration follow-up](docs/audits/platform-parity/2026-11-12-config-followup/report.md)): the campaign's enum row and the cleanup of the same leaves. Fixed: an enum written in another case reads in its manifest spelling, as on Windows, in the Linux AI, hotstring, number-row and gesture readers and the shared emulation settings (CFX-001) and in the macOS preference loader (CFX-002); the Linux cleanup no longer offers saved swipe modes and steps for deletion (CFX-003). Left: the macOS preference hydration beyond `load` and `current_view`, NFD and NFC paths on macOS; native receiving unqualified.
      Progress (12 November 2026, [updater follow-up](docs/audits/platform-parity/2026-11-12-updater-followup/report.md)): the campaign's two uncompared rows. Fixed: a macOS manual check whose window cannot open runs and notifies its answer, through the shared `updater.check_notice` (UPX-001); the Linux bundle, checksum and signature are bound to the repository's download path for the release's tag, as on Windows and macOS (UPX-002). UPD-2 decided by the coordinator on 2026-11-12 from the maintainer's pause rule (a manual check runs during a pause, as on macOS and Linux; Windows line below). Native receiving unqualified.
      Progress (12 November 2026, [input/layout follow-up](docs/audits/platform-parity/2026-11-12-input-layout-followup/report.md)): the campaign's two open Linux rows. Fixed: a keyboard slot follows the emulated letter, as on Windows (ILX-001, through the shared `keylayout_emulation.chord_char`); a key passed under a tap-hold's held modifier repeats (ILX-002). Left: the macOS Carbon slots against the tap rewrite, to confirm on a Mac; native receiving unqualified.
      Progress (12 November 2026, [gestures follow-up](docs/audits/platform-parity/2026-11-12-gestures-followup/report.md)): the campaign's open Linux row. Fixed: a physical mouse click releases a gesture's click hold, as on Windows and macOS, a touchpad touch keeping it for the drag (GSX-001). Left: GSD-1, the modules not reviewed in depth; native receiving unqualified.
      Progress (12 November 2026, [notifications campaign](docs/audits/platform-parity/2026-11-12-notifications/report.md)): areas taken: notifications, their logs, levels and lifetime, tooltips and tray state. Fixed: a refused shortcut or gesture Quit is told on macOS and Linux (NUI-001); a refused macOS menu Reload is told (NUI-002); macOS logs a notice by its shape, never its text (NUI-004); one notification lifetime in the timings registry (NUI-006); Linux system action failures are error notices (NUI-007). After review: a notify-send that runs and fails is logged and kept in the log (NUI-003), a refused macOS source-change reload is told once per burst (NUI-005). Left: the macOS pause and resume notices, asked of the maintainer; make the Linux runner's notify-send sentinel count fatal (`tests/run.lua`) once the ~370 notices that still reach it through the real notifier have a `ShellRunner._set_async_runner` seam.
      Progress (12 November 2026, [lifecycle campaign](docs/audits/platform-parity/2026-11-12-lifecycle/report.md)): areas taken: reload, user Quit, signals and logout, wake, first run. Fixed on Linux: input that stops at run time exits non-zero so systemd restarts the daemon (LCY-001); a first run follows the session language, English fallback (LCY-002); a shortcut or gesture Quit takes the user Quit owner (LCY-003); a signal during an update's probation keeps the update (LCY-004); the degraded tray Quit takes the same owner. Left: native receiving unqualified.
      Progress (11 November 2026, [adapters campaign](docs/audits/platform-parity/2026-11-11-adapters/report.md)): areas taken: the Lua drivers' `adapters/` and `infra/` (clipboard, privacy, focus identity). Fixed on Linux: an X11 clipboard holding only an image is borrowed and restored whole (CBL-001). ADD-1 to 3 decided by the maintainer on 2026-11-11 (a password manager of the one shared list `_shared/data/secure_apps.json` is a secure field as a whole on macOS and Linux, Windows counterpart below; a borrowed unowned Linux clipboard goes back unowned, as on macOS; the Linux application identity is the WM class or app_id under X11 and Wayland, comm only as fallback, saved exclusion lists converted once). Left: configuration, lifecycle, notification and network adapters in depth, native receiving unqualified.
      Progress (11 November 2026, [configuration campaign](docs/audits/platform-parity/2026-11-11-config/report.md)): configuration, scopes and migration of the Lua drivers. Fixed: a `[script]` enum written in another case is adopted in its manifest spelling on macOS and Linux (CFS-001), a Linux setting edit removes its rollback copies once it commits (CFL-002), `storage.json` is private on the LuaJIT runtime (CFL-003). CFD-1 decided by the maintainer on 2026-11-11 (Linux stages are named per process, pid and start tick, and a dead process's stages are reaped at start; a foreign stage is still refused). Left: the case variants of the other enum readers, native receiving unqualified.
      Progress (11 November 2026, [macOS launcher campaign](docs/audits/platform-parity/2026-11-11-macos-launcher/report.md)): source reading only (no Swift toolchain here), nothing fixed. Findings for a Mac: MLC-001 (MJConfigFile seeded before the single-launcher lock, so a second launcher repoints the running runtime; the `.cjs` guard misses the top-level write), MLC-002 (a quit from outside skips the controlled exit and can report a runtime failure), MLC-003 (a second launch after boot shows nothing; product decision), MLC-004 (the leftover-runtime grace is a literal below the quit deadline), MLC-005 (exact-path check under App Translocation, to probe).
      Progress (12 November 2026, [start-at-login campaign](docs/audits/platform-parity/2026-11-12-start-at-login/report.md), branch `claude/ergopti-todo-parity-b`): census 381 areas (18 new, 220 changed since the pinned census); never-campaigned changed areas listed in the report (menus, i18n, editors, healthcheck, onboarding, Linux install). Fixed: macOS tells the Login Items approval step instead of the failure dialog (SAM-001) and logs a failed startup read (SAM-002); Linux logs a failed startup read and each refused change (SAL-001). The macOS memory note on ordinary Hammerspoon over a checkout corrected. SAD-1 decided by the maintainer on 2026-11-12 (B: start at login on a source run): Linux writes the checkout launcher's autostart entry and reports a stale one (warning, rewritten on enable); the macOS developer app resolves its own launcher (native `SMAppService` answer for an ad hoc bundle to confirm on a Mac). Stale-entry row reason decided by the coordinator on 2026-11-12 (none: the warning, and the next enable repairs the entry). Left: the developer-app login item under « To confirm on the Mac », native receiving unqualified.
      Progress (12 November 2026, [i18n run-time campaign](docs/audits/platform-parity/2026-11-12-i18n-runtime/report.md), branch `claude/ergopti-todo-parity-b`): areas taken: locale choice, lookup chain and miss reporting at run time. Fixed: macOS and Linux warn once for each raw key shown, probes go through `has()` (I18-001); macOS warns about a saved locale without a catalogue (I18-002) and takes its fallback from `locales.system_fallback` (I18-003). Left: native receiving unqualified.
      Progress (12 November 2026, [menus/tray campaign](docs/audits/platform-parity/2026-11-12-menus-tray/report.md), branch `claude/ergopti-todo-parity-b`): composition from the shared manifest, pause greying, rebuild after a menu change and after a change behind Ergopti's back: no finding. The Linux About build's two synchronous startup reads measured (about 10 ms each), not proposed. Left: the Lua counterparts of the asynchronous Windows rebuild triggers (user hotstring load, agent, updater) traced end to end, native rendering unqualified.
      Progress (12 November 2026, [onboarding campaign](docs/audits/platform-parity/2026-11-12-onboarding/report.md), branch `claude/ergopti-todo-parity-b`): the wizard's bridges, catalogue and answers. Fixed on macOS: the chosen language waits for Finish, as on Windows and Linux (OBM-001), and a missing or unshipped locale is refused instead of becoming English (OBM-002). Left: Linux host dialogs during the wizard keep the running language; native WebView receiving unqualified.
      Progress (12 November 2026, [diagnostics page campaign](docs/audits/platform-parity/2026-11-12-healthcheck/report.md), branch `claude/ergopti-todo-parity-b`): actions, pause, stale results: no finding (one shared validator and report owner, the collection a Windows capability). Left: native receiving unqualified.
      Progress (12 November 2026, [Linux install campaign](docs/audits/platform-parity/2026-11-12-linux-install/report.md), branch `claude/ergopti-todo-parity-b`): startup ownership, uninstall, configuration cleanup (download steps left to the other track). Fixed: a checkout's startup entry no longer takes the standalone installation's name, which blocked a later install (LIN-001). Left: a deleted checkout's entry stays until a checkout run rewrites it.
      Progress (12 November 2026, [editors campaign, first pass](docs/audits/platform-parity/2026-11-12-editors/report.md), branch `claude/ergopti-todo-parity-b`): page and bridge behaviour of the personal information, prompt, paths and hotstrings editors. Fixed on macOS: a refused personal information save is told (EDM-001). EDD-1 decided by the maintainer on 2026-11-12 (a pause stops typing, not configuration): macOS and Linux editors save while paused, the LMH-003 gate reverted, Windows counterpart below. Left: the macOS prompt editor's refused-save notice, the layer editor page, tooltips, WPM.
      Progress (12 November 2026, [pause, first and second pass](docs/audits/platform-parity/2026-11-12-pause/report.md), branch `claude/ergopti-todo-parity-b`): EDD-1 sharpened into a « real pause » (configuration and installs stay available, typing stays inert, a setting changed while paused applies on resume). Done on macOS and Linux: the physical shortcuts editor opens while paused; every menu's whole-scope restore and clear and the Configuration menu run while paused; the tray's feature rows stay live (`greyed_when_paused` is read by the AHK tray alone); Linux hotstring sections, keyboard groups, wrap choices and the pause layout switch work while paused (`edd1-paused-writes`). Left, see the report's last section: the macOS Shortcuts and both Gestures switches, Linux tap-hold edits, the programmable hotstrings switch, both AI menus, the personal editor and word expander rows (shared corpus), the macOS hotstrings submenus, the macOS magic key capture, and the audit that every typing feature (layout emulation first) is inert while paused.

## Dead-key composition parity follow-up

[Focused audit](docs/audits/platform-parity/2026-11-05-dead-keys/report.md), pinned source `f2c3ea43542c985fb20e5f0887976f1c02525341`: five new roots, [generated comparison](docs/audits/platform-parity/2026-11-05-dead-keys/capabilities.md). Evidence boundaries remain explicit; these are follow-ups, not implemented fixes.

- [ ] **Pause and a pending dead key (macOS, Linux).** A pending composition is native state there and Ergopti's pause
      does not cancel it (both Windows engines do); decide whether the pause must clear it, and how.

## Cross-platform feature inventory

- [ ] **Windows/Linux diagnostics:** add the manifest-derived unavailable-features explanation already collected and rendered on macOS. Evaluate authenticated fallback metadata for feed-only update installation; retain current refusal without authenticated assets (macOS uses signed Sparkle metadata for newest-channel updates). Progress: Linux and Windows now publish the section through one shared Lua collector and its AHK mirror (AHK test written, not run on Linux); the feed-only fallback evaluation remains. Decided 2026-11-06 (align on macOS): a feed-only list may install the channel's newest release only through authenticated metadata, otherwise the refusal stays. Windows/Linux design: download the asset under its conventional name, compute size and SHA-256 locally, rebuild the `asset_signing.json` record and verify `<asset>.sig` against the pinned key before installing. Blocked: `public_key_spki_base64` is empty and enforcement is `off`, so every such install would refuse today; build it once the key is provisioned (docs/tooling/update-signing.md).
      PC run 2026-11-11: the AHK mirror of the unavailable-features section (`test_healthcheck_core.ahk`, ui group) passed natively.
- [ ] **Windows/macOS/Linux:** qualify physical shortcut delivery and its editor; Windows has its host, its delivery refused. Decided by the maintainer on 2026-11-11: both Lua production getters (`keyboard_shortcuts.physical_delivery_available`, Linux and macOS) answer true, every source, collision and output-custody refusal kept; the Mac field report validates it. Before that, both answered false. Preserve the safety refusal until source/collision/output custody is qualified; see LIN-004 in the deep input audit. Windows token-by-token prediction display also remains unvalidated (`platform_reason.token_streaming_unvalidated_on_windows`). Progress (code, 6 November 2026): the refusal is now pinned on the real chain, not an injected answer: on Linux and macOS a test drives the production `keyboard_shortcuts.physical_delivery_available` (false), the real editor host and the shared menu port with the GUI ready, and the editor stays closed with no scope captured. The greyed editor row no longer says « Try reopening it »: it names the cause, `physical_shortcuts.delivery_unqualified` (21 locales, `disabled_reasons` on the row). Left: the Windows host, and the qualification itself, which needs real hardware (under "To confirm on Linux" and "To confirm on the Mac"); only then may a getter turn true. Done (2026-11-11): both getters true; the pinned tests now pin true and keep each refusal under an explicit false answer (`test_physical_delivery_available.lua` on both drivers, `test_physical_shortcuts_row_available.lua`, the scope fixtures); the Windows row reason (`physical_shortcuts.windows_unavailable`, 21 locales) said Windows had no host, neither the editor nor the delivery. Done (Windows host, decided by the maintainer on 2026-11-11): the WebView2 host of the shared page, its scope, the menu port and the key capture (`windows/ui/physical_shortcuts/`, `KHCapturePosition`); the production `PhysicalShortcutDeliveryAvailable` answers false, the row lost its Windows restriction and `windows_unavailable`, and greys with `delivery_unqualified` (`test_physical_shortcut_host.ahk` pins the real chain). Left on Windows (maintainer, real hardware), before the getter may turn true: (1) build the collision owner (the Linux `physical_collisions` counterpart: tap-hold keys, key combinations, script and keyboard slots, layer remaps) and pass it to `PhysicalShortcutsScope`, and a delivery owner that registers each bound slot's scan code with its exact modifiers and dispatches the action; (2) flip the getter in an isolated driver only, open the editor from the tray: the page shows positions by name (A, 1, Pavé num. 7), never `KeyA` or `SC01E`; (3) Capture a key with Ctrl, Shift, Win and none held, on an ISO and an ANSI board, with AZERTY and Ergopti layouts: the captured position is the physical key, AltGr is refused, a key sent by another program (SendInput) is not captured, and the key still types in the focused app; (4) save an action, then edit, move and remove it: config.toml gets one backup and one write each, the reload keeps it, and an external edit of config.toml between opening and saving shows « Configuration changed »; (5) press the bound key: the action runs once, the key's character is not typed, nothing runs while paused, after the driver quit, or for the same key sent synthetically; (6) bind a combination already owned by a tap-hold, a script shortcut or a key combination: the save is refused with `collision`; (7) close the window during a capture and while the picker is open: no capture survives, no draft is saved. Only then may the getter turn true.
- [ ] **Windows and Linux:** evaluate incremental touchpad gesture modes and step sizes; macOS tracks finger movement while the other drivers handle discrete gestures. Linux done (follow macOS, decision of 2026-11-06): `linux/modules/gestures/incremental_tracker.lua` fires an incremental slot's action while the fingers move, from the decoder's live travel (`mt_decoder` `live()`), with the step rule and reversal shared with macOS (`_shared/gestures/engine/incremental.lua`, `_shared/gestures/engine/sensitivity.lua`); travel is converted to millimetres with the touchpad's own resolution (EVIOCGABS, `touchpad_finder.read_resolution`), the unit of the macOS sensitivities, so the manifest's modes and steps (`gestures.modes`, `gestures.sensitivities`, now declared for `linux`) apply unchanged; a pad that reports no resolution fires once, as x1, said in the log. Modes and steps are read from and written to `[gestures.modes]` / `[gestures.sensitivities]` and offered in each swipe slot's submenu through the shared templates (`test_gesture_incremental.lua`). Windows done (code, decision of 2026-11-11): the driver owns a raw HID digitizer reader (`modules/gestures/raw_touchpad.ahk` over `adapters/raw_input.ahk`: RegisterRawInputDevices for usage page 0x0D usage 0x05 with RIDEV_INPUTSINK and RIDEV_DEVNOTIFY, the preparsed descriptor read with HidP_GetCaps/HidP_GetValueCaps, contact X/Y, identifier, tip and contact count read with HidP_GetUsageValue/HidP_GetUsages, parallel and hybrid reports assembled into frames by `modules/gestures/touchpad_hid.ahk`); travel is turned into millimetres with the descriptor's logical-to-physical scale (centimetre or inch units and the HID unit exponent), and `modules/gestures/incremental_tracker.ahk` fires an incremental slot while the fingers move through the AutoHotkey ports of the shared direction and step rules (`direction.ahk`, `incremental.ahk`, which replay `_shared/tests/corpus/gestures/incremental_steps.json` and `direction_vectors.json`; the rule numbers come from the timings registry's [gestures] keys). The 3- and 4-finger straight slots of `gestures.modes` / `gestures.sensitivities` are declared for `ahk` and offered through the shared swipe-slot template (`menu_gestures.ahk`); `platform_reason.gesture_modes_and_steps_need_finger_travel` is retired from the 21 locales, the other entries keep `platform_reason.windows_touchpad_slots_are_three_and_four_fingers`. Coexistence with the registry-mapped shortcut: a touch that stepped swallows its swipe's shortcut, before or after the lift (`[gestures] incremental_handoff_ms`), a touch that did not step lets it fire once (decision recorded in docs/memory/maintainer-decisions.md). A descriptor without a physical size fires once, as x1. Tests: `test_gesture_incremental_rule.ahk`, `test_touchpad_hid.ahk`, `test_raw_touchpad_owner.ahk`, `test_gesture_swipe_slot_menu.ahk`. Left: a real touchpad check on Linux (see "To confirm on Linux") and on Windows (see "To confirm on the Windows PC").
- [ ] **Linux Wayland:** focused-application identity on GNOME, KDE and COSMIC, from the findings above: an Ergopti GNOME Shell extension exposing the focused window's WM class, title and pid on the session bus (installed and enabled by the installer), a persistent KWin script calling back a session-bus name the daemon owns on `workspace.windowActivated`, and a native `zcosmic_toplevel_info_v1` client for COSMIC. Each needs its desktop to be qualified on real hardware. Code done for GNOME and KDE (10 November 2026): the GNOME Shell extension (`linux/desktop_focus/gnome/`, `focus@ergopti.fr`, GNOME 45 and later) and the KWin script (`linux/desktop_focus/kwin/`, Plasma 5 and 6) call `org.ergopti.Focus1.Activated(class, title, pid, id)` on the session-bus name `org.ergopti.Focus`, owned by a resident worker (`linux/adapters/compositor_focus_worker.lua`, libgio) that admits only the current owner of `org.gnome.Shell` or `org.kde.KWin`; the daemon reads its lines (`linux/adapters/compositor_focus.lua`) and `window_info` answers the 4×/s poll from memory, no fork, unknown before the first report, after a malformed one or once the worker exits. `install/compositor_focus.sh` installs and enables them for the running desktop (once: an update keeps a user's off switch; GNOME for the next login when the Shell refuses), run by install.sh and by launch.sh at every start (so .deb, .rpm and AppImage users get them too; Flatpak's private data folder cannot), removed by uninstall.sh. Tests: `test_compositor_focus.lua`, `test_compositor_focus_assets.lua`, `tools/test/test-linux-compositor-focus-install.cjs`, and the worker on a real dbus-daemon (`tests/hardware/run_compositor_focus_bus.lua`). Left: COSMIC (a `zcosmic_toplevel_info_v1` client means hand-built libwayland-client interface tables over FFI that nothing here can run against without cosmic-comp; it stays unknown), and the real-desktop check under « To confirm on Linux ». COSMIC code done (11 November 2026): `linux/adapters/cosmic_toplevel_worker.lua` binds `zcosmic_toplevel_info_v1` version 1 through libwayland-client with hand-built interface tables (the clipboard owner's pattern), commits each window on `done` and prints the single activated window as a focus record (app_id as class, no pid; none or two activated is a clear, `finished` ends the worker); `compositor_focus` starts it for `XDG_CURRENT_DESKTOP` COSMIC and `window_info` answers from memory as for GNOME and KDE (identity `cosmic::<id>`). Proved through the real libwayland-client against a LuaJIT protocol fake (`tests/hardware/run_cosmic_toplevel_fake.lua`, 7 receipts, run in the compositor-focus CI step) plus the tracker unit tests; version 1 (rather than v2 and later, which announce windows through ext-foreign-toplevel-list) decided by the coordinator on 2026-11-11 overnight, to review by the maintainer. Left: a real cosmic-comp run (it may only offer the later versions' announcement) under « To confirm on Linux ».

## Sequential WPM, wrap and personal-info parity follow-up

[November 5 sequential audit](docs/audits/platform-parity/2026-11-05-sequential/report.md) at `7aecd9a25b35efdcff68898919506dc2f6fd02d0`: four reviewers stayed on one module at a time, with independent root replays before advancing. [Generated capability and intentional-difference comparison](docs/audits/platform-parity/2026-11-05-sequential/capabilities.md). These are bounded source/actual-owner findings; Windows native execution and desktop receiving remain qualified. Findings below remain open; this campaign changes evidence and tracking, not production behavior.

### Policy, documentation and verification debt

- [ ] **[CI] Native keyboard-source fixture:** investigate selection-deadline/cleanup-unavailable refusals seen before and during this audit; the targeted retry passes, but that does not establish a repaired cause. Keep failed receipts and exact required cohorts.
      2026-11-11: the refusal of run 42014901978 (Intel macOS 15) follows one line no passing log shows,
      `CFMessagePortSendRequest FAILED(-1) to send to port com.apple.tsm.uiserver`: the service that applies the
      selection did not answer for about 11 s. 6736a355 brackets the cohort with a read-only snapshot of the text-input
      agents (launchd state, runs, last exit, crash reports, unified log) kept with its receipt, so the next refusal
      names the cause. The cohort passed 41/41 (Intel) and 40/40 (Apple silicon) over 2026-11-07..10 and again in
      [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137); the cause stays unproven until a
      refusal carries that snapshot.
      2026-11-12: scan of ci.yml runs 2026-11-07..12 (282 of 353 runs on dev, claude/_ and tmp/_): the cohort steps ran
      61 times on Intel and 62 on Apple silicon; 2 Intel refusals, [43013053161](https://github.com/adrienm7/ergopti/actions/runs/43013053161)
      (job 130500102196) and [43172671159](https://github.com/adrienm7/ergopti/actions/runs/43172671159) (tmp/ci-snapshot, job 131034291324),
      both after `CFMessagePortSendRequest FAILED(-1)` lines, as in 42014901978; none on Apple silicon. One macOS 26
      `KeyboardSourceProbeTests` refusal in the full launcher suite ([43108782369](https://github.com/adrienm7/ergopti/actions/runs/43108782369),
      job 130833096151) has no such line. Probes on hosted runners (temporary `probe-macos-tsm.yml`, removed in 3363b94e):
      `TextInputMenuAgent` owns `com.apple.tsm.uiserver`; stopping it prints the line (20 on macos-15, 31 on Intel), so
      does stopping `TextInputSwitcher` on Intel (12), not stopping SystemUIServer. But every perturbed cohort still passed
      12/12: agent stopped ([43189848716](https://github.com/adrienm7/ergopti/actions/runs/43189848716), job 131086084762), both stopped, either
      stopped or killed while the cohort selected ([43194666371](https://github.com/adrienm7/ergopti/actions/runs/43194666371), job 131102413569),
      and that fresh runner's unperturbed baseline printed four such lines and passed. So the unanswered server is a
      state the refusals share, not their cause; the cause is still unproven and no retry was added. 71a16621 (wording
      corrected in 4d2e7e55, 533e2762) writes `tsm-refusal.json` beside the number-row receipt and annotates the state
      (`tsm_uiserver_unanswered`, `fixture_refusal_unclassified` or `no_fixture_refusal`) with the agent snapshot; the
      verdict and the exact cohorts are unchanged (`tools/test/test-macos-tsm-refusal.cjs`). Next refusal: read its
      receipt and snapshot (did the agent's pid or run count change?) before trying another perturbation.
      2026-11-12 afternoon: the refusal now recurs on macOS 26 in the full launcher suite ("Run Swift launcher tests on
      macOS 26"), with no `tsm.uiserver` line in any of them: [43222724578](https://github.com/adrienm7/ergopti/actions/runs/43222724578) (job 131204789756) on
      `KeyboardCharacterMappingTests.testFreshKeyboardEventsFollowLayoutAndShiftFlags` at 13:26:12 UTC, then
      `KeyboardSourceProbeTests` (3), `NativeInputSourceSelectionTests` (4) and `NumberRowSourceProbeTests` (7)
      "unavailable"; [43228623723](https://github.com/adrienm7/ergopti/actions/runs/43228623723) (job 131226750544) on the number-row cohort's first selecting case
      (`testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI`, French) at 14:12:29, five seconds after
      `NativeInputSourceSelectionTests` passed, then six more "unavailable". With 43108782369 that is three macOS 26
      refusals without the line. The full-suite step carries no text-input snapshot or `tsm-refusal.json`, so the
      next step is to bracket it as the number-row step is.

## Native runtime, editor and diagnostics parity follow-up

[November 5 audit](docs/audits/platform-parity/2026-11-05-native-ui/report.md): nine bounded OS × module scopes at `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`; 15 qualified findings, including one shared frontend root affecting all three OSes. These are source/model/private native-port findings, not 15 native desktop reproductions. [Capability and intentional-difference comparison](docs/audits/platform-parity/2026-11-05-native-ui/capabilities.md). The canonical manifests exclude counterchecked LVB-002 and MRT-005.

### Qualification and policy follow-up

- [ ] **[NATIVE]** Exercise the retained runtime/editor/diagnostics receiving boundaries on Windows and macOS, and the Linux live GTK/session flows. Replay refused writes, native timer admission, stale epochs and physical cleanup; the private models do not certify these boundaries. Linux, partly (2026-11-11): a live installed session with an in-process WebView (the first-run onboarding window) now receives the reload request instead of crashing (44b2e10f, `tests/hardware/run_webkit_gc_signal.lua` in the desktop-webview CI shard); the runtime/editor/diagnostics flows themselves remain.

## Migration and update parity follow-up

Evidence: [six-scope recovery/lifecycle audit](docs/audits/platform-parity/2026-11-04-recovery/report.md). These 17 OS manifestations include shared causes; keep intentional platform policies and all current refusal guards.

### Linux

- [ ] **[PHYS-M]:** receive the recovery audit scenarios on isolated macOS: Darwin migration/permission/rename contracts, selected-profile restart adoption and Versions ARMED/refused-exit reconciliation. Linux physical ports do not close Hammerspoon/APFS qualification.

## End-to-end parity follow-up

Evidence: [12-scope flow review](docs/audits/platform-parity/2026-11-04-flows/report.md). These are OS/flow work items, not a claim of 26 unique causes or native acceptance. Preserve intentional policies and all current refusal guards.

### Linux

- [ ] **[PHYS-W] / [PHYS-M] / [PHYS-L]:** execute only the receiving scenarios named by each flow report on isolated native hosts. Source/recording-port tests do not close native focus, selection, keyring, application or device qualification. Linux, partly (2026-11-11, [receipts](docs/audits/linux-container-proofs/2026-11-11-recovery/README.md)): linux-clipboard X11 target negotiation (`run_clipboard_owner.lua x11`) and the AI selection read and replacement on a real accessibility server (`run_llm_selection_focus.py`, 31 cases) now run in the desktop-webview CI shard. The locked/unlocked keyring and its password prompt (linux-crypto) are received too: a real gnome-keyring and its prompter, answered and dismissed (`run_keyring_receipts.sh`, in CI); it found and fixed a dismissed prompt read as an absent key and a clear on a locked keyring read as done (a6fa8892). The linux-desktop trash and pointer mutations run for real too (`run_desktop_actions_live.sh`: empty_trash cancelled and confirmed on a real gio trash, center_mouse, overlapping toggle_dark_mode; in CI), which found and fixed an empty-trash reported done without GVfs (3da58645). Remaining Linux: a native terminal for LCP-004, chmod (make-executable from a file manager) and eject of a real device (linux-desktop), the case/wrap transforms inside a native editor field. The Wayland clipboard protocol is received too: the clipboard owner over data-control in headless sway (`run_clipboard_owner_wayland.sh`, in CI).
      PC run 2026-11-11: the Windows WCP/WCR/WCF/WDS regressions (`test_clipboard_paste_transaction_ownership.ahk`, `test_keystats_text_cipher.ahk`, `test_wpm_config_types.ahk`, `test_system_actions.ahk`) passed natively on the maintainer's PC, which is not an isolated host.
      Windows, received 2026-11-12 (`tools/test/run-windows-receiving-scenarios.ps1`, temp profile, hosted step « Receive the recovery and flow scenarios »): WCP-001 with two real windows and the real clipboard, a foreground change during the snapshot refusing before any clear or copy chord (the chord is the one recorded port, so nothing is typed), and its control delivering and restoring; WCR on the real DPAPI (round trip read back by an independent Windows PowerShell process; tampered, other-entropy and marker-shaped envelopes refused and never re-persisted) and the metrics cipher sealing marker-shaped typing with the real MachineGuid key; WCF-001 with the widget pair in the real Registry under a private key, read back by the boot loader, and a refused write keeping the previous pair; WDS-002 with the real Clear-RecycleBin failing natively after launch (scoped to an absent drive letter, so the user's bin is never emptied) reaching one error line, and a zero exit reported as done. 8 of 8 passed on the maintainer's PC; every scenario failed once with its owner broken (startup foreground and focus checks, envelope validation, marker skip, pair publication, worker exit observer). Remaining Windows: WCP-002 (the paste into a new foreground window needs real key emission) and a DPAPI blob of another Windows account (a second account).

## Deep OS × module follow-up

Audited source and immutable evidence: [18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md). These entries are implementation/validation work, not permission to remove deliberate safety checks or silently change explicit product contracts. Intentional differences and unresolved rationale are in the [provenance register](docs/audits/platform-parity/2026-11-04-deep/intentional-differences.md).

### Linux

- [ ] **Native acceptance:** run the unexecuted AHK/account-context/PnP and actual Mac/Linux device/provider scenarios from each module coverage register. Lua/PowerShell recording-port probes are not native desktop certification. Linux, partly (2026-11-11): the metrics privacy owner on a real GTK/AT-SPI desktop (`run_secure_focus_watch.py`, linux-metrics register) now runs in the desktop-webview CI shard, and the installed daemon grabs and re-emits a real uinput keyboard under systemd ([PHYS-L] proof). Remaining Linux: touchpad hotplug and SYN_DROPPED re-query (gestures), multi-field Tab settling and grapheme deletion in host editors (hotstrings), pointer metrics, live Wayland layout apply, desktop connectors and real mail/calendar (llm).
      PC run 2026-11-11: Windows ran the whole AHK suite natively (14 module groups, 20,286 tests) and `e2e/run_e2e.ahk` 90/90; the account-context and PnP scenarios remain.

## Carried over from the 1.0.9 requests (1-2 November)

Released as v1.0.9; these requests of 1-2 November are still open.

- [ ] **Slowness, every driver.** Windows boot 7 s, `menu.rebuild` 1.7 s: lazy submenus, single-toggle update, one
      registry proof, full save after ready, disk caches; a toggle must not rebuild 1000 rows.
      Resume here (branch `wip/windows-boot-time`): parse fixes, the smoke operation caps, keyboard before tray root
      and the queued early tray click are committed (keyboard registered at 4.5 s instead of 5.1 s on the smoke
      fixture). Done 11 November: the emoji and symbol sections (1,575 rows on the maintainer's config) register
      after ready in 25 ms Critical slices (`HSE_DeferRegistration`, `[hotstrings] deferred_registration_*`), their
      `Seq` block reserved at the boot position: the registry after the slices is the boot one, 4,242 specs in the
      same order (dumped from both boots), and `(hotstring-deferred-rank)` pins the tie-break, the slicing and the
      stop at a registry clear; the prefix catalogue reads the cache, complete before ready. The AI submenu is
      built at its first open (`MenuDeferOrBuild`, `(llm-menu-built-at-first-open)`), so neither the boot nor a
      toggle's full root rebuild draws its rows. Medians of 7 interleaved boots of the maintainer-config fixture
      (metrics off in the copy: a quarantined smoke is paused and keystats refuses a new ledger while paused, so
      that fixture aborts beside a resident driver), summed `process_cpu`: emoji deferral 9,828 → 9,047 ms
      (hotstrings stage 2,344 → 1,734 ms CPU); then lazy AI 8,609 → 8,391 ms (`menu row llm` 156 → 63 ms, `tray menu`
      719 → 563 ms). The deferred slices cost about 0.75 s of wall over 1.2 s after ready on a loaded machine.
      Next: script parse (lighter boot includes; AHK has no
      runtime include, so only a smaller graph or a worker helps) and layout (rejected disk cache: native hotkey
      registration); the remote AI catalogue (212 ms) can now be measured again with the AI root lazy. Measure each with interleaved base/candidate smoke-fixture boots (summed `process_cpu`). CI of
      the branch: run 41737399378 (first run 41732233161 found two branch regressions, fixed since; its PAC and
      action-picker WebView reds pass locally).
      Windows boot, 3 November. Real logs: 4.75 s at best, 7.8 s typical, 15 s and more
      under load; parse 1-1.7 s, layout 1.2 s, hotstrings 1.0 s, tray 1.0 s (AI submenu 0.75 s), pre-logger 1.2 s.
      Three boots waited 24 s, 26 s and 446 s on a tray opened during boot (`native_menu_wait`): input waits for the
      open menu. Done, measured on a smoke fixture made from the maintainer's config (median of 3 interleaved runs,
      process CPU 7.75 → 7.20 s, menu usable 6.6 → 5.5 s; realistic-hotstrings fixture: hotstrings stage 1.9 → 1.1 s):
      quoted TOML text lexed in native runs (personal file parse 463 → 165 ms), snapshot comparison without map
      copies, one boot snapshot read for the AI options (4 → 1), personal-file metadata decodes only `[_meta]`
      (468 → 29 ms for three 35 KB files). Gate: the startup smoke bounds the boot's counted operations
      (`BOOT_OPERATION_CEILINGS`). Left, deliberate or rejected: parse, layout and hotstring registration (about
      4.4 s) are needed at the first key; the remote AI catalogue (212 ms, rejected while the AI root was eager); the
      boot's 9-13 registry deep compares (every write compares).
      macOS, 6 November: the four script-chord slot rows open the shared action picker, as on Windows, instead of
      inlining the 840-action catalogue each: the Shortcuts submenu fell from 3,537 to 177 rows (unit harness:
      35.5 → 2.6 ms, 5.1 → 0.4 MB allocated per build; field rebuilds grew the heap 13-16 MB and the GC landed in
      this stage, 320-342 ms). The Windows AI submenu is lazy since 11 November; Linux done 10 November: the tray builds a submenu's GTK
      rows when a dbusmenu client opens it and updates a toggled row in place (native publication of the 1007-row
      tree 125 → 1.2 ms, a toggle 118 → 1.0 ms, RSS 137 → 122 MB, headless SNI host; the shared Lua tree build,
      about 78 ms, is unchanged); macOS `menu_keyboard_layout.sources`
      re-reads the bundle variants from disk per rebuild (57-415 ms spikes) and needs a proven cache contract;
      hs.menubar has no per-row update, so a macOS toggle still re-pushes the root, but since 11 November its Lua
      build is bounded: a refresh asked only by clicks in one branch (`ui/menu/refresh_scope.lua`, through the click
      gate's `around_click`) rebuilds that branch's module and reuses the rows the other menu modules built last
      (`ui/menu/branch_rows.lua`, a decorator over the menu modules, `builder.lua` unchanged). A pause flip, a request
      from outside a click, two branches, or a click in the layout, AI, agent, configuration, language, About,
      Hotstrings or Debug rows still rebuilds everything; Metrics, Shortcuts, Tap-Holds, Gestures and Apps may
      rebuild alone. Real-module tray harness (median of 15 builds, 1,531 rows): full tree 20.1 ms and 2.76 MB
      allocated, one branch 6.2-12.5 ms and 0.43-1.67 MB (gestures the largest); tests `(menu-branch-refresh)` in
      `test_tray_every_submenu_populated`, `test_menu_refresh_scope`, `(menu-click-scope)`. Not timed on a Mac (the
      next field report's `menu.rebuild` lines); the branch lists were decided by the coordinator on 2026-11-11
      overnight, to review by the maintainer.
      macOS, 6 November (wave 3): no cache: the build was repeating work with one answer. Both Keyboard Layouts
      scopes were listed up to four times per rebuild (input-source map, active version, bundles stage, version
      row) and the bundle's Info.plist and variant stats twice; one per-build snapshot now feeds every reader
      (2 listings, 1 plist read; `test_layout_bundle_external_refresh`, `test_input_sources_version_gt`). Not timed
      on a Mac: the next field report's `menu_keyboard_layout.sources` phase says whether the spikes are gone.
- [ ] **Before publishing.** Whole AHK suite on a quiet machine with no resident driver, `npm run test:ahk-tray-rows-read-as-text`,
      all live checks including `quit-over-a-log-flush`, JS, macOS and Linux suites, Windows field report with a driver.
      PC run 2026-11-11: the whole AHK suite ran natively on the maintainer's PC (20,286 tests, reds fixed or reported not executed except TakeNote different-folder) and `e2e/run_e2e.ahk` 90/90; the live checks were 21 pass / 7 fail.

## Remaining code work

- [ ] **Requalify the Windows key-combination and updater cohorts on the real PC after the structure
      migration.** Each structure step re-pins the immutable cohort receipts (rule C1, decided by the
      coordinator on 2026-11-12, to review by the maintainer); its commit body lists every old→new pin with the
      move that justifies it under « Requalification ». Run both cohorts natively on the Windows PC once the
      migration has landed, and confirm the re-pinned frames.
- [ ] **Windows AV-surface ceilings (found 2026-11-12).** The first Windows / Build of the current tree, run
      43291765266 (artifact `ergoptiplus-av-surface-43291765266-1`), exceeds four ceilings of
      `tools/ci/windows-exe-av-surface.json`: elevated_run 4/3, elevation_wording 4/3, injection_wording 13/11,
      key_state_polling 69/58. The excess is already on `dev` (Build was skipped on every earlier run), at most +2
      key_state_polling from ILD-2 `_KLE_RealCtrlHeld`. The maintainer sets the new ceilings; they guard the antivirus
      surface, so no agent raises them alone.
- [ ] **Linux hardware test still passes the removed pause argument (found 2026-11-12).**
      `linux/tests/hardware/run_simultaneous_configuration_real.lua` still passes `script.is_paused` to `Scope.edit`
      and `Scope.copy_taps_to_chords`, which take `expected_source` there since the EDD-1 pause-argument removal,
      so the pause function lands in `expected_source` and Linux E2E
      desktop-webview fails (« original publisher clears only the known third slot », line 252). Drop the argument,
      then confirm with that E2E job.
      Claimed by worker A: both calls now pass only `edit_source()`, and the paused copy is expected to succeed
      with identical bytes (EDD-1); `test_hardware_scope_calls_take_one_source.lua` guards the argument. Left:
      the Linux E2E desktop-webview proof.
- [ ] **Windows global restore and the preferences source (found 2026-11-12).** On macOS the remap save wrote
      `config.toml` without handing the bytes to the preferences, so « Restore recommended values » refused at the
      shortcuts participant (fixed in 3e209162 by `Preferences.replace_source`). Check whether the AHK global restore
      cohort has the same handoff gap now that `[tap_holds]` and `[mod_combos]` live in `config.toml`.
- [ ] **ci-acceptance-3 commits not yet on `dev` (2026-11-12).** On `claude/ergopti-todo-ci-acceptance-3`: the
      keyboard-source evidence (cf44fb4e, aef8ae05, da7cf001, 84e97e47: conflicts in `ci-macos.yml` and
      `test-macos-tsm-refusal.cjs` against the tap-hold series, rebase them), the TODO receipts 8886f2ba and
      ec54b45e, and the MLC-005 relocation rows (4ae1131a, faa1ade6, 13af8690, b74741e8, 14d21718, 365dae29),
      held until the macOS 26 Install-and-launch rows of run 43292636135 or a later one pass.
- [ ] **Windows compiled upgrade exit 1 (closed 2026-11-12 on its credible cause).** ed11665a is the credible cause,
      unproven: the upgrade step was never reached afterwards. Watch for a `startup-smoke: uncaught` line on the
      next failure of Windows Install and launch.

### Windows (the PC agent's)

State on 2026-11-01. Whole AHK suite at d85a24eb53: 17277/17288 in parallel, the other 11 (clipboard and focus contention
between workers) green alone. All live checks pass, typed by the harness.

- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the

- [ ] **UPD-2 on AHK (decided by the coordinator on 2026-11-12, after the maintainer's real pause).** A manual check,
      the changelog and Versions windows, the release links, the channel and interval settings and the update prompt
      should run while paused, as macOS `check_now` and Linux `check_for_updates`; background checks keep their pause
      drop. Tried on 2026-11-12 (ea031503, reverted in 79d1914b): `_Updater_RequestPolicy` allowed a manual request
      whatever the pause, the suspend boundary (`_Updater_SwapAsyncRequestsForBoundary`) kept in-flight manual records,
      the `_Updater_RefuseManualWhileSuspended` guards left the manual entry points, and `UpdateCheck_Perform` lost its
      `BornSuspended` parameter. Windows CI run 43285586086 then showed what else relies on the pause revoking manual
      work, to handle in the same change: `test_updater_transport_ownership.ahk` AHK-31 (a cancellation during owned
      preparation) and AHK-33 (a pause inside the download START must still reject the reservation: installs stay
      pause-sensitive, so `_Updater_TryReserveDownloadTransaction` and `_Updater_ManagedFailureOwnerIsCurrent` need the
      request's pause generation of their own), the native update-consent fixtures
      (`tests/fixtures/update_check_native_consent_body.ahk`, cases 1718-1720), `test_managed_terminal_failure.ahk:159`,
      and the F-25 class loop in `test_webview_bridge_suspend_guard.ahk` that requires every message handler to read
      `A_IsSuspended` (`_UpdateCheck_OnWebMessage`). Installs while paused stay a separate follow-up: the self-update
      transaction stops at a pause in four places, the `updater-self-update` suspend step
      (`_Updater_QuiesceSelfUpdateForSuspend`, `infra/lifecycle.ahk`), the staging monitor
      (`_Updater_CancelSelfUpdateForSuspend`), the staging completion (« Update staging completion discarded while
      suspended ») and the swap handshake (« the driver was suspended before the swap handshake completed »).
- [ ] **ILD-2, SCD-2 and SCD-3 on AHK (decided by the maintainer on 2026-11-11).** Ctrl+AltGr+key sends Ctrl and the
      logical key, AltGr suspended. `modules/keymap/keylayout/keylayout_emulation.ahk` `_KLE_OnAltGr`: with a Ctrl other
      than AltGr's own physically held, `_KLE_OnShortcut(Sc, "^")` (`"^+"` with Shift) instead of `_KLE_Emit`;
      `test_keylayout_emulation.ahk` `_KLT_OptionsDecide` routes `ctrl altgr` presses the same way, so the shared vector
      `ctrl_altgr_sends_ctrl_and_the_logical_key` replays. `modules/keymap/layout/accented_shortcuts.ahk`
      `AccentedShortcuts_Register`: add the `<^<!` and `<^<!+` prefixes (SCD-2, Ctrl+Alt+é sends Ctrl+Alt+C).
      `modules/shortcuts/utils.ahk` `AddShortcut` for a `^` slot: also `<^>!^` + scan code to the same callback, guarded by
      the physical Ctrl (SCD-3, a `ctrl_x` slot fires for Ctrl+AltGr+x). Tests beside each.
      ILD-2 and SCD-2 done 2026-11-12 (`claude/ergopti-todo-windows-ahk`, 7163ba50 and ee18e2d9: `_KLE_AltGrShortcutMods` with `_KLE_RealCtrlHeld`, the `<^<!` and `<^<!+` chords). Left: SCD-3. `AddShortcut` in `modules/shortcuts/utils.ahk` has no production caller, so the `<^>!^` registration belongs where the `ctrl_x` slots are really registered; find that registrar first, then add the hotkey guarded by `_KLE_RealCtrlHeld()` and test Ctrl+AltGr+x running the `ctrl_x` action.
- [ ] **EDD-1 on AHK (decided by the maintainer on 2026-11-12: a pause stops typing, not configuration).** Remove the
      `A_IsSuspended` page-message gates that drop or refuse a configuration write while suspended, in
      `ui/prompt_editor/init.ahk` (`_PromptEdWeb_OnWebMessage` and `_PromptEdWeb_Save`), `ui/paths_editor`,
      `ui/personal_info_editor`, `ui/personal_toml_editor_webview.ahk`, `ui/layer_editor`, `ui/layout_manager`
      (`_LayMgrWeb_*`), `ui/hotstrings_config_window`, `ui/action_picker`, `ui/model_browser` and
      `ui/physical_shortcuts`; keep `ready`'s handling. Test in each editor's suite: a save while suspended writes the
      file. Extended the same day into a « real pause »: also remove the Suspend gates on every configuration or
      install action, i.e. the tray rows the manifest marks `greyed_when_paused` (they stay live while suspended;
      `menu_init.ahk` is now the only reader of that key, so delete it from `menu.toml` together with the gates),
      each menu's whole-scope restore and clear and the Configuration menu's, opening the physical shortcuts
      editor, adding or deleting hotstrings, and installs (layouts, Ollama or MLX models, apps). Then confirm that
      nothing that acts on typing stays active under Suspend (hotstrings, layout emulation, tap-holds, layers and
      chords, shortcuts, gestures, AI predictions and their warmups and local server), with a regression for any
      that still acts, and that a setting changed while suspended applies on resume. Every executable
      `A_IsSuspended` read is listed by file and line, classified, in
      [the Windows inventory](docs/audits/platform-parity/2026-11-12-pause/windows-inventory.md): the writers
      (`infra/hotstrings/personal_toml_io.ahk` among them) refuse too, and the tray root rebuild is refused while
      suspended, which must change before the rows stop greying. See `docs/memory/maintainer-decisions.md`.
      Owned by the parity-b pass (decided by the coordinator on 2026-11-12): its Windows slice for personal hotstrings and personal info is 392ae998, and the remaining gates are listed in [the pause Windows inventory](docs/audits/platform-parity/2026-11-12-pause/windows-inventory.md) on `claude/ergopti-todo-parity-b`.
- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the
  keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left, the rest of the menu files need
  `test-menu-manifest` to stop pinning their spelling. PAR-79: the 28 literals left are inventory pollers and sleeps
  before the registry loads. PAR-83: the host in `ollama_managed_files.ps1`. Moving `tests/run_*.ahk` to
  `tests/runners/` is not worth it (455 `A_ScriptDir` uses, 1,908 includes).
- **Tests.** Source assertions left to convert to behaviour; `--reverse` on the `llm` group has 3 order-dependent reds.
  PC run 2026-11-11: `--reverse` on the `llm` group passes 2295/2295 after the order fixes. Count of `_Driver*` source
  reads in the Windows tests: 3,780 in 994 files (meta 3,000, unit 778), down from 3,796. The timer, LLM tray probe,
  keep-awake, scroll capture and password detector pause guards now run under a real `Suspend`. 80 meta files
  still read `A_IsSuspended` from source. Guards that would send keys, paste or move the cursor when broken (text
  sender, tap-hold, dead keys, `SimulateActivity`) need a seam first. The ROI half-life tick and the click
  handlers are guarded a second time downstream, so a behaviour test of their own guard could not fail.
- **Field report.** `field/win-2026-11-01-dev` ran with no driver; run it again with one.
- **Signing follow-ups.** Delete `.github/ci/stable_windows_signing_exception.json` once SignPath is configured; flip
  update enforcement to `required` after the `off` release. The relay exe and the vendor binaries are unsigned.
- **Older findings.** The seven "Remaining findings" of
  [the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md); item 36 updater production coupling (the
  first trusted PowerShell host acquisition); a408a29790 (the four longest AHK unit shards split) was never landed.
- **TakeNote and the Windows 11 tabbed Notepad.** The Store Notepad titles a window « Notes.txt – Bloc-notes » with
  an en dash; the matcher read only « - » and never found the window (fixed, `takenote-title-separator`). Left: by
  default it opens a second file as a tab of the open window, so a same-named note of another folder shares one
  window with the first, and the module, which binds one window to one path, waits for a window that never comes
  (`takenote-native-document-owner` mode different-folder fails on the PC, passes on the Server runner's classic
  Notepad). Tell the two tabs apart (UI Automation tab items) or select the right tab before typing.
- **Whole AHK suite on the PC (2026-11-10, `fix/windows-pc-2026-11-10`).** 20,286 run, 16 red: 2 token-exchange
  budgets and 1 shortcut path case (fixed), 2 TakeNote (above). The other 11 need what the CI runner installs
  and this PC does not have: the Kana layout (`one-shot-native-kana-*`, 2), a top row that types letters, while
  the PC's first layout is the custom `d001040c` (`layout-row-native-flags`, `layout-row-external-native-flags`,
  `layout-row-pending-dead-key`, 7), and file symlinks, which need Developer Mode (`unblock-selected-file-reparse`,
  2). Skip each with its reason when the prerequisite is absent instead of failing.
  PC run 2026-11-11: the token-exchange and shortcut path cases are fixed, the Kana one-shot cases pass (da5daad768), the layout-row and symlink cases report not executed with their reason (bb49219540); TakeNote different-folder stays (above).

- [ ] **Immediate-Backspace restoration after Notepad-paste and terminal expansions.** Those owners emit after the
      keystroke and keep no undo record, so a Backspace right after their expansion does not type the trigger back.

- [ ] **LogsDirPath under the old folder name.** `infra/legacy_folder_migration.ahk` renames a custom logs folder named
      like the old app folder to `Ergopti`, as macOS and Linux do since 2026-11-11 (shared `renamed` rule).

- [ ] **Hotstring header rows outlive their expiry** in the « both » stack of `llm.trigger.while_hotstring_tooltip`
      until the next render.

- [ ] **Restored API entry without a usable key.** DPAPI keeps the key inside the backup: check whether a restore under
      another user or machine yields an unusable key, and give it the « API key… » re-enter row as macOS and Linux do.

### macOS

- **Field report 2026-11-03 (`mac-2026-11-03_102716`), branch `fix/macos-field-2026-11-03`.** Done: ai_local no
  longer lists the owned endpoint without its binary (no ERROR); n-gram history merges paced (458 ms slice); the
  dashboard no longer resends an unchanged history each live update (250 ms holds, +73 MB heap per minute). Already on
  dev: blob Range redirect (e6942d05c2), diagnostics phase A (e76a5443f8), post-wake AX hold (1f2884f13c), owned
  Ollama Go test enrolment (627bfad0af). Done since: the hardware UUID keystats start needs is read by an ioreg child
  during the start delay (`modules/keystats/host_signature.lua`), no longer by `ioreg -d2` on the main thread (151 ms
  at boot+1 s); a later Metrics toggle still reads it synchronously when no prefetch ran. Karabiner regeneration stays
  synchronous (merge 170 ms, layout actions 230 ms cold: event_taps `runloop_late_ms` 294), no safe non-blocking
  design: the work is in-process Lua plus native calls (`hs.keycodes.map`, `hs.json`, the file write), which no child
  can do, and slicing it across run-loop turns would let layout, pause and lease events land between a build and the
  layout serial, lease token and epoch it was validated against. Measured on Linux Lua 5.4 under the stub harness
  (shipped recommended preset, 6 rounds): layout actions 1.1-1.8 ms, build 27-40 ms, merge 9-30 ms, encode 11-44 ms
  (258617 bytes); so the field 230 ms in `karabiner.layout_actions` is native, not the Lua loop. Next: split that
  phase on the Mac (`Layout.keyboard_form()` registry snapshot vs the 548 `hs.keycodes.map` lookups) before touching
  it. The menu Apps folder reader already uses `FsDir.try_entries_quiet`; the obsolete `find` follow-up is closed. Done 2026-11-11: `Config.resolve_layout_actions` times that phase's two halves apart (`karabiner.layout_actions.keyboard_form`, the registry snapshot, and `karabiner.layout_actions.key_codes`, the 548 lookups; regression in `test_actions_not_rebuilt_per_layout`), so the next Mac field report's phase lines and slow-callback attributions name the half to move. Left: read that report, then decide.
- **One folder name for Ergopti on the three OS.** The shared roots and boot migrations are already on dev. Check the maintainer's machines against `docs/tooling/one-folder-name-handoff.md`; remove the migration only once those checks pass. Rename the owned Karabiner runtime folder (`ErgoptiPlus`) in its next rebuild (item 31). Checked 2026-11-11: no code step is left here. The runtime folder rename is the maintainer's release step: it changes the compiled runtime, so it needs a rebuilt and republished pinned remap runtime (`vendor/remap-runtime/manifest.json`), which agents do not touch; removing the migration waits for the maintainer's machine checks.
- **31. Owned Karabiner runtime** ([ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md),
  [handoff](docs/tooling/next-release-handoff.md)). Status on 4 November, all on `dev`:
  - Done: the owned runtime is the default (`RUNTIME_DEFAULT = "owned"`, the two Configuration rows and
    `remap_switch.lua` gone). Runtime `16.3.0-ergopti.3` published (prerelease `remap-runtime-v16.3.0-ergopti.3`,
    downloaded back: sha256 `eced1bfd…dc4567`, 12351916 bytes) and pinned; its hosted sudo install acceptance passed on
    macos-15, macos-15-intel and macos-26 (Remap runtime build run 41895547018: files, Core and VirtualHIDDevice jobs
    loaded, pqrs' package installed in the same shell, stage retired). The install is offered once by itself (one
    confirmation, one administrator prompt), the driver approval pane opens and is watched, the Tap-Holds row retries;
    the field run and the collector (`--installed`) report every install fact.
  - Decided: field-tested on the CI-signed dev build, never the ad hoc developer app; no Developer ID for now (item
    below).
  - Next: the maintainer's WP9 pass (handoff checklist) once a signed dev build is authorized, then the shared-mode
    deletion. Checked 2026-11-11: both steps are the maintainer's (a signed dev build and a physical Mac); no code step precedes them. Done on 1 November: the per-OS feature requirements table (`docs/design/feature-requirements.md`) and
    the driver-only VirtualHIDDevice update offer (3ebab93a17).
- **Owned runtime with a Developer ID (maintainer: not now, 2026-11-04).** With the self-signed CI certificate the
  install takes one administrator prompt (the root Core and pqrs' daemon are LaunchDaemons bootstrapped by the
  helper), Login Items lists them as separate « unidentified developer » rows, and the driver approval names pqrs'
  extension. A Developer ID would allow: `SMAppService.daemon` for both jobs from `Contents/Library/LaunchDaemons`
  (no password, one « Ergopti » Login Items group; launchd kills SMAppService jobs of a bundle with no Team ID,
  `RemapLeaseGuardian.swift`), and an Ergopti-signed DriverKit extension in `Contents/Library/SystemExtensions`
  activated with `OSSystemExtensionRequest` (needs Apple's DriverKit HID entitlements for the team). The root Core
  keeps its own Input Monitoring row either way: launchd starts it, not Ergopti.
- **Owned runtimes.** The rows in state "to do" of `_shared/core/network/data/owned_runtimes.json` are all item 31 (shared
  Karabiner app, owned runtime, VirtualHIDDevice). The Swift-owned managed daemon under the proxy relay needs a short
  design note first (who launches the relay, how its refusal receipt reaches the Swift owner; Swift and Go). Done on 1
  November: App Cloner on the managed Python with pinned PyObjC 12.1 (managed-pyobjc.json, ensure-managed-pyobjc.sh
  under the native PTY guardian, consent offer from the Apps menu, stable link `native-bootstrap/app-cloner/python3`;
  existing clones keep /usr/bin/python3 until re-cloned). Checked 2026-11-11: the managed-daemon relay row stays blocked on that design note (who launches the relay, how its refusal receipt reaches the Swift owner), a maintainer decision; no code step is open before it.
- **Checks left to a program from the Mac session.** Done on 1 November: `field_tap_hold_thresholds` (9901da4d94;
  PAR-15 is confirmed by the next field run's result);
  the HTTPS downgrade refusal is already covered by `ManagedPACSourceTests` and `ManagedBootstrapDownloadTests`.

- [ ] **Owned runtime rebuild (macOS release step).** The next runtime build ships the MRT-004 « Réparer le service »
      helper role and the helper's one-hash report rule (`OwnedVirtualHIDDaemonReportStageOwner.admitImage`); rebuild it
      and update its manifest pin.

- [ ] **`events_typing.rich_text` in clear (AHK-005 / WM-002 left).** With metrics encryption on, Windows and Linux
      store it empty; macOS still writes the typed text to SQLite.

### All drivers

- [ ] **Structure plan (maintainer request 2026-11-11):** [docs/design/structure-plan.md](docs/design/structure-plan.md).
      In progress: see « Resume here » at the top (branch `claude/ergopti-todo-structure-phase2`).
      Rule A: every common value, text and logic in `_shared`. Rule B, decided by the maintainer on 2026-11-11:
      feature-first trees (`<feature>/{engine,adapters,ui,data,native}`, `core/`, `platform/`), the same on every
      driver and in `_shared`; file prefixes the folder repeats are renamed away (`keystats_walker.ahk` →
      `walker.ahk`); `remap` is named `keyboard`; tests stay in `tests/<kind>/` mirroring the feature tree.
      Start trigger: the go comes from the maintainer, as soon as the maintainer's AHK session has pushed its last
      feature commits; the coordinator then launches phase 2 at once, one step per commit with
      `tools/audit/structure/apply-step.cjs` (`--check-all` must be clean first).
- **Provider flags inferred, not read.** Checked against the docs on 1 November (90344262aa): Featherless and
  Qianfan confirmed. Rechecked on 10 November (7ae1147b): the Perplexity, `dashscope-intl` and Moonshot K2 watches
  are closed and guarded by `test-llm-provider-retirements.cjs`. Left, both only provable with a live key (the docs
  hosts are unreachable from cloud sessions and show no off example): SambaNova's `enable_thinking: false` (off is
  its default, docs show only `true`) and the Chutes Qwen `enable_thinking` field; a refusal is dropped and
  remembered either way.
- **Tooling found on the way (4 November).** The source seal now reads Git blobs without creating a temporary checkout. On the Windows PC these fail on a clean `dev` for
  environment reasons, so only CI proves them: `test-site-github-release` and the site deploy admission controls
  ("file changed before capture"), `test-keylayout-row-options` (different Lua keyboard ids),
  `test-linux-field-report-contract` (setup error), `test-menu-manifest` in a worktree (a `node_modules` junction
  copy fails with `EPERM`). Make each one pass locally or skip with a stated reason.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins
  of a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods` (macOS capture is item 31's).

- [ ] **Modifier-chord action labels from the key name table.** The action pickers still show raw or French chords
      (« Cmd + Option + Shift + Enter ») on every driver; the tests that pin this label family change with it.

### Linux (container proofs of 2026-11-10)

- [ ] **GNOME input source switch.** GNOME Shell 46 ignores runtime writes of `mru-sources` and `current`: on a
      `sources` change it keeps its in-memory MRU and activates its first entry, and a non-interactive activation
      writes no `mru-sources`. Done 2026-11-11 in `adapters/input_source_switch.lua`, decided by the coordinator on
      2026-11-11 overnight, to review by the maintainer: the switch writes `sources` as the target alone, waits
      `gnome_input_source_settle_ms`, writes the list back with the target first (as the installer already places an
      activated layout) and `mru-sources`; a failure after the first write puts the list back, coalesced writes end on
      no switch, never another layout. Left: the installer's `apply_gnome` (desktop_activation.py, W1 to W3) still
      writes the list with the layout first, which a running shell ignores; it needs the same sequence and a Python
      reader of the shared settle constant. 2026-11-11: the installer's live selection (`_gnome_select`, apply-wayland)
      now writes the slot alone first and waits the settle time the daemon passes (`--gnome-settle-ms` from the shared
      registry), and its XWayland read-back finds the layout by content in mutter's « (unnamed) » keymap (before, it
      looked only for the layout's name, which mutter never writes, so every GNOME apply ended `not_loaded`). Still
      `not_loaded` on GNOME 46 headless with both in place: one more cause is not found yet. Found 2026-11-11: GNOME
      Shell reads the user registry (`~/.config/xkb/rules/evdev.xml`) only when it starts, so an id registered after
      login is unknown to it and the slot alone switches the session to its `us` fallback. apply-wayland now compares
      the registry's date with the shell's start, registers both slots and answers `needs_relogin` without touching
      the setting; after the next login every build alternates live. [Proof](docs/audits/linux-container-proofs/2026-11-10-layouts/README.md).

### Linux performance (2026-11-11, branch `claude/ergopti-todo-linux-perf`)

Measured with `tools/bench/linux-session-bench.py` (real daemon, Xvfb session over the kernel model; report in
`docs/audits/performance/linux/2026_11_11/report.md`). Budgets and the reuse rules below were decided by the
coordinator on 2026-11-11, to review by the maintainer.

- [ ] macOS boot: `migrations.toml` (74 KB) is parsed and validated at every boot (about 30 ms of Lua 5.4); a
      generated, hash-checked Lua mirror would remove it (maintainer decision, numbers in the report).
- [ ] Windows counterparts (the maintainer's PC): the same `[Span]` TRACE/DONE pair and names in
      `infra/hotpath_profiler.ahk` for `hotstring.expand`, the tray submenu build and a layout switch; a
      millisecond-stamped kernel-to-output latency (`A_TickCount` against the hook's event time) as
      `input.latency`; a `load` phase before `BootProfiler` starts; the last interval summary at exit.

- [ ] Keystats boot: `open_db`'s own spawns (mkdir, schema checks), device registration and the open-walk read still
      cost about 30 ms of sqlite3 processes.

## CI acceptance

Each closes on a named green hosted or native run, recorded here.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E, packaging,
      installation, launch) with exact receipts; it also carries the first hosted run of: the Linux X11 window list
      (962a25a973), AppImage Build and `install-linux` rows (dce846a0bd), the Linux per-step installs (17e80f2882),
      "Qualify the installed managed Ollama route plan" (c0a50b5e41), the Linux private runtime in every package,
      and the run-timing summary (`run-timing.cjs --step-summary`; Flatpak under 5 min).
      Initial audit preflight [42099804561](https://github.com/adrienm7/ergopti/actions/runs/42099804561) failed Arch native server detection, shared UI browser installation and macOS stubbed replay. Follow-up [42108198520](https://github.com/adrienm7/ergopti/actions/runs/42108198520) at `4ca161c3e512eecc4c78499db0465139c9a71861` is green: 114 successful jobs, with only Release / Publish skipped; Arch integration, shared UI rendering and all OS verdicts passed. Later dead-key preflight [42121216727](https://github.com/adrienm7/ergopti/actions/runs/42121216727), at `04ebe1089bf387ccbfef43bbfd3b2f3e9b1cd6d9`, failed Common / Install and launch (Stable site) at Install production site browsers, followed by its mandatory verdicts. Requalify that browser installation and the final source checkpoint; no successful browser/render receipt follows from the failed step. Hosted results remain separate from physical dead-key receiving.
      2026-11-11 Linux and macOS lanes at `85f3dfee20` (Linux [43012051378](https://github.com/adrienm7/ergopti/actions/runs/43012051378), macOS [43012056158](https://github.com/adrienm7/ergopti/actions/runs/43012056158)): every Linux job is green (Unit, five distribution rows, Integration, five E2E shards, Build, all 20 Install-and-launch rows), including the installed managed Ollama route plan and its Go twin (network-ai, job 130500747601), the X11 cursor-display window switching step (input-display, job 130500747586), the AppImage Build and `install-linux` AppImage row and the per-distribution installs. The run-timing summary ran in Release / Verify (job 130525465817). Flatpak was 378 s cold (over 5 min): 986a3d5629 caches the flatpak-builder module state: cold 568 s, cache saved ([43105583384](https://github.com/adrienm7/ergopti/actions/runs/43105583384) attempt 2, job 130839886024), then warm 58 s with the module cache restored ([43126416939](https://github.com/adrienm7/ergopti/actions/runs/43126416939) at `7188928a48`, Linux Build job 130890961113); Flatpak under 5 min done. That run's Linux lane is green end to end (Linux Verdict job 130894504733). Both runs' Common lot "Distribution and updates" fails only on `test-windows-updater-original-source` (a90dce3444 changed `test_framework.ahk` without resealing: the maintainer's reseal), so Common and Release Verify are red. Still open: Windows, the final source.
- [ ] **macOS lane.** L32 and L42 Swift in the Build stage; the Issue #101
      Swift and Go cells; native qualification of the Hotstrings category boot publication and the obsolete-leaf
      setters; item 31's lane once its runtime build is green. Already green (run 41257389239): Launcher XCTest,
      Native XCTest (Intel), Build and all five Install-and-launch rows, guardian fixes included; macOS Unit,
      Integration and every E2E cell on run 41261068581.
      2026-11-11 run [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) at `6736a355`: macOS Unit, Integration, every E2E cell (Native XCTest Intel, Launcher
      XCTest macOS 26 with `Test Suite 'All tests' passed`, both Managed Ollama and Managed Ollama build cells = the
      Issue #101 Swift and Go cells, Lease silence, Tooltip canvas, Archive update controls) and Build are green. L42:
      the credentialed-redirect refusals (`testRealPACSourceRedirectsHaveFreshCredentialFreeOwners`,
      `testRedirectIsRefusedWithoutSecondConnection`) pass in the full suite; L32's `memory_footprint_mb` is a Lua
      field probe covered by the green Unit lots, not Swift. Still open: native Hotstrings category boot publication
      and obsolete-leaf setters need an installed driver on a real Mac (no hosted row types into them), and item 31's
      lane waits on its runtime build, which the pinned runtime rules keep out of scope tonight.
      Requalified 2026-11-11 at `85f3dfee20` in [43012056158](https://github.com/adrienm7/ergopti/actions/runs/43012056158): macOS Unit, Integration, all 12 E2E cells, Build (with the
      layout extension payload receipt) and all five Install-and-launch rows green; macOS Verdict job 130559010960 green.
- [ ] **Ollama Go cell** (cda1e10c5e) on the final source before a release (passed on run 40021624397).
      Green again on both architectures in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) (Managed Ollama and Managed Ollama build, Intel and Apple silicon);
      it closes only on the release candidate's own source, which tonight's no-release rule excludes.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
      A hosted runner runs the eight variants only against the ad hoc signed app of the "karabiner config"
      Install-and-launch row (`hs_native_bootstrap_probe.py`); the Developer ID signature exists only on a release
      build, which tonight's no-release rule forbids, so the signed run needs the next release candidate.
      Ad hoc receipt 2026-11-11: `macOS launch gate [karabiner_config] passed on arm64` in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) (job 130257482253),
      which requires all eight variants to build, merge and publish on the installed app.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package); dynamic
      hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native macOS delimiter transactions; macOS packaging with both extension TOML files;
      Windows native cases and Fedora/Alpine ShellRunner fixtures (Linux done in the start-up E2E).
      macOS packaging received 2026-11-11: 85f3dfee20 makes the macOS and Linux builds require every hotstring file the
      shipped extension manifest binds (`tools/build/check_layout_extension_payload.py`); the macOS Build of
      [43012056158](https://github.com/adrienm7/ergopti/actions/runs/43012056158) (job 130512589181) prints `magickeyreplace.toml ... sections=replace`, `suffixes_a.toml` and
      `PASS bound=6`, and the Linux Build of [43012051378](https://github.com/adrienm7/ergopti/actions/runs/43012051378) passes the same check. Fedora/Alpine ShellRunner fixtures
      received: the full Linux unit suite passes on Fedora's and Alpine's own LuaJIT in 43012051378 (jobs 130494409773, 130494409706) and their Integration rows too. Still open: native macOS delimiter transactions (typing into an
      installed driver on a real Mac) and the Windows native cases (maintainer; Windows counterpart of the payload check:
      run it from the Windows packaging against the registry `windows_bundle_manifest.json` ships).
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification on macOS and Windows; provider published before
      model loading on macOS (Linux done).
      macOS part on hosted CI: the macOS Unit lots (menu_llm, ui) that hold the composed-menu and provider-order tests
      are green in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137); a composed menu shown by an installed driver needs a real Mac. Windows part is the maintainer's.
- [ ] **First `main` push after 1.0.9.** CodeQL scans `main` only: the 32 alerts fixed on dev on 4 November
      (a3d69950e5..89b0b774c8) close only once that scan accepts the fixes.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a non-empty analysis.
- [ ] **Native Windows TLS fixture.** `X509Store.Add` on the CurrentUser root store blocks on the Windows security
      warning (`docs/memory/windows-ahk.md`), so these cases need a click; hosted lanes pass in LocalMachine scope.
- [ ] **Intermittent fixtures.** Close each after it stays green: Linux window switch, cffi-lua clone, desktop-webview
      AI focus, Windows `config` group, macOS Go `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`.
      Scan of ci.yml runs 2026-11-07..10 (macOS and Linux): the cursor-display window switch step passed 40/40;
      no cffi-lua clone retry or desktop-webview AI-focus failure appeared (the webview lane's 4 failures were a
      managed Python download, a 504 and an on-screen pill check); `TestIdleDeadlinePhysicallyRetiresPeer` and
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` never failed (Swift launcher step 37 passes,
      4 other failures). A new intermittent, `NativeAppClonerBundleOwnershipTests.testActualNativeCliLogLimits...`
      (runs 42438031643, 42480689370, `[Errno 1] Operation not permitted`), is fixed at its cause in bce01f27: XNU
      answers `killpg(group, 0)` with EPERM while the last members are unreaped zombies.
      New 2026-11-11: Install-and-launch `symlink_logs_dir` failed once in [42929436137](https://github.com/adrienm7/ergopti/actions/runs/42929436137) (job 130257482167) with "Quit did
      not end both processes within 10 s (the Quit AppleEvent was never answered)" while the same build quit in
      0.3–0.4 s in every other row. Its re-run (attempt 2, job 130295289361) passed and the macOS Verdict of
      42929436137 is green (job 130295941982); keep it listed until it stays green.
      Scan 2026-11-12 of ci.yml runs 2026-11-07..12 on dev, claude/_ and tmp/_ (282 of 353 runs listed, 71 runs of
      2026-11-07..10 and the second job pages of ten large runs not read; logs read for the A/B buckets and one sample
      per other failure group): `symlink_logs_dir` Quit timeout only once (job 130257482167 above); its failed-launch
      artifact (launch-gate-failed-ci-macos-15-symlink_logs_dir\_\_tilde_paths-attempt-1, with the launcher and
      Hammerspoon samples) could not be read from this session (artifact storage host refused by its network policy),
      so it stays unexplained. No failure of the window switch, cffi-lua clone, desktop-webview AI focus,
      `TestIdleDeadlinePhysicallyRetiresPeer` or `testBridgeHardDeath...` in the logs read; the sampled Linux install
      and webview failures were an APT mirror timeout (1200 s) and WIP tests. `NativeAppClonerBundleOwnershipTests`
      EPERM appears twice more, in [42940650392](https://github.com/adrienm7/ergopti/actions/runs/42940650392) and [42927169227](https://github.com/adrienm7/ergopti/actions/runs/42927169227), (2026-11-11, macOS 26); whether
      their sources hold its fix bce01f27 is not checked (that commit is not reachable from this clone). Nothing reproduced, so nothing was changed here; the keyboard-source refusals are under « [CI] Native
      keyboard-source fixture ».

## Maintainer decisions pending

None. The questions answered on 2026-11-13 (OSM-002, the coordinator's decisions of 2026-11-11 and 2026-11-12) are
under « Maintainer decisions of 2026-11-13, to implement » at the top.
