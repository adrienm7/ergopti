<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-03. Latest release: v0.0.0-dev.155 (c9e4c64ab); `dev` is
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

The current session requires one atomic commit per fix or feature, updating this
checklist in the same commit. Push each commit immediately to `dev`, then cancel
every CI run triggered by that exact push to avoid releases. Run the full CI
through `workflow_dispatch` on a temporary `codex/ci-*` branch: a non-dev ref runs
the CI profile and publishes nothing. Use its Windows and macOS runners for
native behavior and parity regression tests. Preserve unrelated changes, stage
exact paths, never force-push `dev`/`main`, and delete only the temporary CI
branches this session created after their evidence is recorded.

The Windows regression backlog (former item 72) is closed: non-release CI
run [36916568697](https://github.com/adrienm7/ergopti/actions/runs/36916568697)
at `e5da10fbc` passed native unit tests, engine E2E, packaging, install/launch
and the Windows verdict. The full run passed, including the shared core,
both Lua suites and all macOS/Linux installation variants.
The next menu migrations add shared behavioral vectors to these native lanes.

The configuration no-op slice passes the shared fixtures and native Windows
tests in run 36925266946. Its three changed-file macOS fixture cases exposed
a simulated metadata copy that depended on the runner's umask; the fixture now
carries the real source metadata through that copy and passes under umask 022.
The production permission checks remain strict; repeat the non-release CI.
The rewrite wiring gate now follows the erasing-record contract introduced by
the concurrent local commits: both corrections and rewrites must identify the
deleted suffix and original span. Negative source mutations cover either guard
being removed; the registered native parser tests cover actual admission.

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

Automatic startup placement is complete: non-release run 37039552367 at
`506931224` passed every Windows/macOS/Linux unit, E2E, package, installation
and launch gate, with Release / Publish skipped. All three native menus draw
startup immediately above Uninstall from the shared declaration. Item 110 is
removed after this full checkpoint.

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
  keep the user's own (user data, as the delimiter submenu does). macOS now
  shares that policy, resets the file, runtime and next-save states, and keeps
  its exact inverse on refusal.
  Windows now restoresshipped word and consumed delimiter defaults through one
  shared AHK policy, preserving personal strings in the tray restore and both
  admitted Hotstrings scopes. Independent cross-driver vectors preserve
  Unicode, duplicates, disabled consume-only markers and unknown personal
  states; the existing journal retains exact inverse recovery on refusal. The
  eight unchanged source files retain their prior full portable qualification;
  the two rebased include files passed the selected encoding gate on the
  current integration. Windows native unit/E2E, packaging and installation
  validation remains pending. Recommended-delay native verification and
  editable handwritten [[hotstrings.terminators]] support remain open under
  item 34.
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
  Non-release checkpoint
  [37033032620](https://github.com/adrienm7/ergopti/actions/runs/37033032620)
  at `6275cac35` passes the complete Windows/macOS/Linux pipeline, including
  native units, E2E, packaging, installation and launch; Release / Publish is
  skipped. Personal-menu fixtures now release their owned submenu trees before
  AHK interpreter teardown. The five targeted owner/lifecycle cases require a
  clean native exit, while foreign detached dispatcher registrations stay live.
  Both asynchronous launchers retain their process handle, join before reading
  ExitCode and refuse a missing receipt. Strict execution identities and timings
  remain blocking. Hosted diagnostics use stdout through PowerShell, and native
  timing probes consume the runtime actually selected by CI.
  The isolated LLM runners now own separate canonical result paths and strict
  manifests so their small suites cannot replace the main suite's later
  annotation. This receipt-isolation follow-up awaits its full native CI.
  CI reporting now emits one bounded aggregate notice with every ordinary
  failure, alongside unchanged error annotations and strict native statuses.
  Checkpoint 37056318950 had 17 failures but GitHub retained only ten error
  annotations. An actual CLI regression fails against the previous reporter;
  68 assertions now cover all causes, escaping, bounded oversized details and
  unchanged streamed output/counts/JSON/exit status. Full native CI remains
  pending for this evidence-only follow-up.
  Both real detached-worker probes now capture exact owned launch/exit and
  stdout/stderr receipts before a script window exists. Missing readiness and
  cleanup retain the original failure together; the shell control and every
  icon/title/priority assertion remain blocking. Checkpoint 37061649827 lacked
  the worker parser output; the next native run must qualify its cause.

  Concurrent Windows performance commits are integrated without replacing the
  pending editor, model or remap slices. The committed delay policy and its
  independent vectors remain intact. This merge retains the original native
  failure assertions and requires a new complete non-release checkpoint.

Packaged macOS window observations now bind exact live application PIDs
before reading properties. After an acknowledged Quit, they attest process
absence without opening a global Accessibility query. Refused UI inspection
remains explicitly unavailable and cannot qualify window behavior; the five
application criteria, native timer assertions and primary/cleanup errors
remain strict. Fifty Python regressions pass; native CI remains pending.

A refused live Linux update retains the same sanitized HTTP response and
underlying child/owner verdict before fixture cleanup. The probe preserves
transport arguments, callback returns and failure status; unavailable
headers are reported explicitly rather than inferred to be a rate limit.
Registered CLI regressions, Linux units and portable E2E pass; the actual
updater response and complete native checkpoint remain pending.

Checkpoint [37087943283](https://github.com/adrienm7/ergopti/actions/runs/37087943283) qualifies the second sample of the exact installed Hammerspoon server, while the clean-launch AppleScript observation still exceeds its unchanged ten-second budget. Failure logs now preserve bounded thread identities, native queue names and call ancestry, explicitly mark omitted ancestry, and redact private source locations. Main-thread Lua frames and background semaphore waits remain separate observations; neither loaded images nor flattened frames establish TCC causality. Sixty-one registered portable Python regressions and the selected format/JS gate qualify the diagnostic change. The new native context output, the actual timeout cause and all 18 timer measurements still require a non-release macOS checkpoint. Exact PID/executable and native Process/Path identity checks remain strict.

The Windows live-expansion fixture now owns its foreground-focus probe and
restores the exact prior port. Actual deferred observers still reject absent
or changed focused controls and re-arm only for a stable verified target.
Checkpoint 37085309234 exposed a host-dependent re-arm failure; its exact
native guard branch was not emitted. All original expansion and transport
assertions remain, with native Windows requalification pending.

## Maintainer requests added on 2026-09-29 (see the overnight handoff)

Checkpoint 37046411788 at `ea6b21bed` passes all three OSes, including
7,726 Windows unit cases, E2E, packages, installation and launch; release is
skipped. It validates the GUI title policy and navigation case preservation
after native captions were captured through explicit UTF-8 receipts.

The native deferred-logger fixture now takes its immediate observation
inside a bounded Critical region and restores the exact prior state.
The unchanged causal assertion distinguishes inline delivery from a timer
interrupting the observation; an isolated actual-production probe requires
the same assertion to fail under a private inline mutation. Native Windows
qualification remains pending.

The verification planner now selects native AHK parsing/unit/E2E gates for
every shared AHK source, including pure shared policies. Independent planner
regressions fail against the missing selection and retain platform-specific
deferral behavior; changing only a portable AHK policy cannot bypass its
native qualification.

The Windows migration owner now renders explicit deltas from physical TOML
records instead of rebuilding unrelated content. Shared independent byte
corpora cover comments, empty headers and occupied inline namespaces;
physical ownership guards refuse multiline/array-of-table parser inventions
before both planning and boot classification. A schema version forged inside
a multiline string cannot bypass the guard. Current bytes, receipts and
unknown user data remain protected; native Windows qualification is pending.

Native macOS launch diagnostics now sample the exact owned AppleScript child
before timeout retirement and require its actual exit. Timer observations
keep the same ten-second script deadline and all eighteen checks; bounded
diagnostic sampling does not turn timeout into success. Collected native
frames are included in annotations without assigning an unproven cause.
System Events collection failure cannot replace the primary failure or
prevent result.json publication; primary and cleanup errors remain distinct.
Forty-five diagnostic regressions pass, including a real blocked child that
is sampled before termination and reaped. Native cause and qualification
remain pending in the next macOS install/launch run.

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

- [~] **33.** Config policy for the files other than config.toml (the former
  item 25): Published in the second 2026-09-30 release for the files the review
  listed; see `docs/memory/text-input-and-config.md`. Still open everywhere:
  sites 76 (no catalogue of parameter bindings), macOS 14/93 and order overrides
  (no "catalogue published" signal), 16/91 (expert `[script]`/`[features]`
  layer), 18 (dynamic model list), 19, 24, 26, 28, a Karabiner key bound to a
  plain string (saves refused with a generic ERROR), Linux layers.toml refused
  as a whole still stops the daemon, Windows sites 32, 34, 36, 37-60 and its
  whole-file installed.json refusal, and the macOS boot-time unread-entries
  scan cost (36-56 ms on the
  main thread). Two maintainer decisions are pending: config_migrate's
  fail-closed guard for invalid stamps (site 108) and a migrations.toml
  exception for key removals handled by the cleanup (site 112).

  Windows tap_hold.toml now reports each obsolete entry once per exact file,
  rendered path and reason during the process, through the shared warning
  owner. Repeated real reads retain valid bindings and preserve unknown
  scalars, arrays and inline tables byte-for-byte. Known-field ERROR/refusal
  behavior is unchanged. An independent twelve-observation corpus runs on
  all three drivers; portable unit/E2E checks pass. Logger callbacks retain
  their caller's Critical state and reentry observes the claimed report.
  Native Windows and complete three-OS acceptance remain pending.

- [~] **34.** Match the Windows recommended hotstring delays to the shared
  manifest, and make hand-written `[[hotstrings.terminators]]` lists editable.
  The shared AHK override policy now writes an explicit recommended delay only
  when inherited source metadata differs; clear restores that inheritance.
  Independent delay vectors run through Lua and native AHK contracts, keeping
  personal/unknown parameters and transactional refusal recovery intact.
  Both Lua drivers share shipped-delimiter restoration; macOS applies it to
  file/runtime/next-save state and restores its snapshot on refusal.
  Windows native units, engine E2E, packaging and installation passed in
  validation run 37084553184. The overall run remains unsuccessful because of
  the macOS clean-launch gate. Editing hand-written array-of-table delimiters
  remains unfinished.

The measured-delay native fixture now isolates the real corpus metadata
cache from the earlier resolution-cascade double and restores the exact
prior cache identity. Its original inherited 1.0-second, recommended
0.5-second, resolver and refusal-recovery assertions remain intact and passed
in the native Windows qualification above.

- [~] **35.** Unregister the remap guardian LaunchAgent when key remapping
  is turned OFF or its rules are removed. The same owned transaction now joins
  STOPPED, exact native unregistration and the persisted OFF/rule removal.
  Refusal retains the prior preference and a fresh READY recovery; unsettled
  registration tasks block retirement instead of hiding process debt. Native
  acknowledgement proves the exact launcher identity, empty durable lease,
  absent legacy job and ServiceManagement registration status. The hosted
  signed-helper acceptance lane also checks wrong-inode refusal, successful
  unregistration and idempotence, retaining primary and cleanup errors.
  Focused registered macOS tests pass 315 cases and the diagnostic judge passes
  six regressions. Complete native Swift, helper registration and three-OS
  qualification remain pending.

Signed-helper acceptance run 37081066757 passed actual native registration,
unregistration and idempotence without a release. The replacement fixture
now acknowledges both weak runtime retirement and actual singleton-lock
release within its existing two-second bound. A retained native ACK callback
must continue to block replacement until it truly exits; every generation
and transport assertion remains intact. Native XCTest requalification and
the complete three-OS checkpoint remain pending.

- [ ] **36.** Packaging remainder (the former item 21): macOS release archive as
      `.tar.xz` (verify Sparkle, the Homebrew cask and CI install first).
- [ ] **37.** Item 23 decisions: whether « Hotstrings Ergopti » should appear
      only when the layout is really installed (today: always, shipped copy), and
      whether to move French `suffixes_a` and the magickey `replace` section into
      the Ergopti extension. The common distance rules are handled by item 103;
      the French distance category remains independent.
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
      and keeps the previous one. Windows still needs a physical-device
      reproduction check of the previously reported AZERTY + AHK Ergopti+
      emulation to native Ergopti layout switch and its reverse: AltGr stays
      usable without a manual reload, including same-window changes and
      switches during held/deferred input ownership. Existing foreground,
      polling and deferred-owner regressions passed complete non-release
      checkpoints 36931498806 and 36940286440. This consolidates former item 99
      under hardware acceptance; it does not establish physical acceptance or
      a new runtime fault from the supplied unpublished snapshot.
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

The packaged macOS launch matrix now contains a Karabiner configuration scenario. It uses the real Hammerspoon JSON runtime and production build, merge and conditional atomic-file owners for eight default/recommended and switch vectors in a runner-owned private destination, preserves foreign profiles and personal rules, proves independent codec trees, and restores exact original bytes. It acquires no remap lease and installs no driver. The selected local gates pass 353 JS checks and 13,074 portable macOS cases, including five registered publication/restoration lifecycle regressions; 65 Python judges pass. Actual signed native execution remains pending and the existing scripting transport deadline is blocking, so TODO40 stays partial until that proof is green.

- [~] **41.** Remaining direct `hs.json.decode` calls (ratchet
  `tests/meta/test_json_decode_through_codec.lua`, no calls outside the adapter).
  Locale, manifest menus, personal hotstrings, keylogger
  aggregation, keymap priority and both shortcut readers now decode through
  `adapters/json_codec.lua`, which returns a tree. A menu regression preserves
  independent equal arrays, rows and nested options after mutation; it failed
  before the migration. The single-reader guard recognizes codec bindings
  and detects competing readers in one directory without lowering its limits.
  The remaining 14 calls in 12 files now use the codec as well: caret ingest,
  gesture catalogues, AI defaults/catalogues, MLX configuration/readiness/session
  handoffs, changelog responses and UI geometry. Callers check the decode error
  tuple and preserve their previous refusal or required-file failure behaviour.
  Caret and model-catalogue regressions preserve independent equal objects and
  nested arrays after mutation, including the native decoder's original graph.
  The direct-call baseline now contains only the adapter's own implementation.
  The complete three-OS pipeline, including packaging and installation,
  passed checkpoint 37033032620 at `6275cac35` with release skipped.
  The settings stub now snapshots valid acyclic values on write and returns
  independent graphs per read, retaining native equal-child aliasing within a
  read. Its clear receipt matches native true/false; set remains void. Direct
  snapshot regressions failed before the fix, and a real learning/debounce
  regression prevents unflushed updates from appearing persisted. Focused
  cases passed, and the settings slice passed the complete three-OS pipeline
  in non-release run 37039329959 at `ea5d64ef6`. The delayed timer now keeps a configured default separately from
  one-start overrides, provides native running/nextTrigger and chainable
  setDelay receipts, and retains callback rearming. Five direct contract cases
  failed before the fix and now pass; a real SyntheticInput listener retry
  regression failed with one delivery before passing with two. Generic doAfter
  semantics stay separate. The stub slice passed complete three-OS
  checkpoint 37046598989 at `051504e0a`, including packages and installation,
  with release skipped.
  The packaged clean macOS launch now qualifies these contracts in its real
  signed Hammerspoon process through a temporarily owned scripting preference.
  Strict receipts require 18 measured observations, runtime identity, nonce,
  self-rearm deliveries and acknowledged preference restoration; aggregate
  evidence refuses missing or partial proofs. Local probe judges passed their
  red/green regressions; actual native execution is not yet qualified. Run 37046757566 exposed
  a clean-launch scripting timeout and a refused physical preference restore;
  no incomplete proof is accepted.
  Audit other hs stubs for remaining divergences from native behaviour.
  The probe now restores an initially absent scripting preference with an
  acknowledged targeted deletion and exact physical readback, preserving
  unrelated runtime changes. Observation and cleanup refusals retain both
  causes; 14 focused and 40 aggregate Python cases passed after the new cases
  first reproduced merged-import and masked-error failures. The 18 native
  measurements remain mandatory; the real control channel still needs CI.
  The pasteboard stub now retains isolated UTI-to-bytes snapshots, returns
  nil for absent text and keeps clearContents void. Four direct cases and the
  actual SyntheticInput consumer first exposed missing payload publication;
  they now pass, including exact text at Cmd+V and later text/RTF/PNG recovery.
  The complete pipeline remains pending for this stub slice.
  The shared Hammerspoon canvas stub now copies frame values at construction,
  assignment and reading, matching the pinned native 1.1.1 NSRect API. Actual
  GraphicsRenderer callback observations are asserted outside its production
  pcall; four original alias failures precede five focused passing cases.
  The complete macOS unit gate passes 12903 cases on the isolated candidate;
  native three-OS qualification remains pending.

- [~] **42.** config.toml batch writer follow-ups (`toml-batch-existing-key`):
  an old build's scalar where a table is now expected (`magickey = true` under
  `[hotstrings.modules]`, `groups = "x"`) still makes a menu save fail with «
  the batch cannot address the destination without ambiguous TOML keys » —
  maintainer decision: may an ordinary save overwrite a value flagged outdated?
  Hand-written dotted keys (`a.b = 1`) are read by the shared decoder as one key
  named "a.b", so the app ignores them.
  Linux now delegates whole custom-delimiter lists to the shared TOML writer,
  including `[[hotstrings.terminators]]` and quoted table-array headers. The
  obsolete local refusal and its unsupported-format warning are removed.
  Regressions cover additions, removals, sparse states, restart, unknown and
  unusable records, nested fields, comments and byte-stable no-op writes; a
  malformed destination and superseded source remain refused. An installed-
  driver E2E scenario saves the list and verifies it at the next real daemon
  start; that scenario failed against the original owner before passing with
  the fix. Local gates passed (349 JS, 4607 Linux unit and 143 Linux E2E
  checks). Full three-OS checkpoint 37033032620 at `6275cac35` passed unit,
  E2E, packaging and installation gates with release skipped. The scalar
  migration decision and dotted-key reader remain open.
- [~] **43.** A Mac upgraded from a pre-lease release could not deploy (dev.149:
  « Merge aborted: 25 ambiguous legacy ErgoptiPlus rules … matches the
  historical CapsWord anchor »): its karabiner.json keeps an untagged historical
  block the merge cannot prove. The refused deploy now offers « Retirer les
  anciennes règles » (listed, confirmed, backed up next to karabiner.json), also
  from a Tap-Hold menu row while the rules are pending
  (`karabiner-legacy-cleanup`); untested on a real Mac. Still to do: find why
  the proof fails from the backed-up file.
- [~] **44.** CapsWord is no longer cancelled by the pointer when Karabiner
  activated it (AltGr + CapsLock): the watcher probed the variable with
  `karabiner_cli --get-variable`, an option karabiner_cli has never had (exit
  2), so it only ever worked for a CapsWord this driver activated; since dev.150
  it stops probing after that refusal (`capsword-probe-unsupported`). Give the
  activation a way to tell Hammerspoon (for example a sentinel key the
  activation rule emits, like the script-control ones) so every CapsWord is
  cancelled.
  macOS generated remaps now publish owned Caps Word activation/clear signals
  consumed by one shared policy and the existing sentinel port. Layout-only
  watchers do not acquire that owner; real gesture startup acquires it lazily.
  Refused native variable writes recover only the same revision/token state.
  Independent old graph generation explains every intended preset digest
  change; application-visible typed output retains its existing assertions.
  Registered macOS tests pass 12908 cases, and private eager-acquisition and
  consumer-refusal mutations are rejected. Native macOS qualification and
  manual hardware acceptance remain pending.
- [ ] **46. (partial)** Local-model presence and download offers now share one
      policy on Windows, macOS and Linux. Agent and screen-reading requests
      distinguish an absent model from an unavailable or malformed model list;
      a model removed after listing is reported through the same owned offer.
      Linux streaming HTTP keeps real status and complete bounded error-body
      receipts, and consent resumes only after modal input ownership is restored.
      Complete the three-OS native CI, packaging and installation validations
      before removing this item. Cloud loopback transport and scripted owner
      regressions do not qualify physical desktop input.
      The Windows native run 37088969640 exposed two contract regressions:
      deferred preflight now declares one-shot/cancel timer semantics, and each
      reserved curl slot declares its transitory tags-owner fields before
      acquisition. Timer delivery/cancellation and the real dispatcher have
      added regressions; the repaired native Windows gate remains pending.
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
      drivers still build (baseline: Windows 122, macOS 204, Linux 127, each
      site listed in tools/test/native-menu-rows-baseline.json); migrate them to
      zero. Each OS-limited row declares `unavailable = "hide"` (not
      applicable) or `"grey"` (not yet ported, with its reason); classify the
      existing rows during the migration (proposal in the menu-first-group
      report: most hide; greyed: Linux edit_shortcuts, Linux key
      combinations, Linux metrics shortcut rows, Windows preview_bubbles).
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

## Maintainer requests on 2026-10-01

Every request the maintainer makes is written here first and removed once it
is committed; one request is one commit with its regression test.

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
- [ ] **73.** Follow-ups of the tray rows the Windows separator bug hid
      (`submenu-read-as-separator-2026-10-01`, fixed): the three families of «
      Combinaisons de touches » are back and read their raw `group_label`
      (« AltGrLAlt », « AltGrCapsLock », « LAltCapsLock ») where a translated
      name is expected; and find which action left the three French hotstring
      categories off in the maintainer's config.toml on 2026-09-30 (a
      restore, a clear or the wizard), since « ct★ » did nothing only because
      `category_enabled.french_magickey` was false.
- [ ] **81.** The maintainer asks to treat item 54 now (every menu row is
      declared in the shared manifest, none built in a driver's folder):
      Windows 122, macOS 204 and Linux 127 rows are still built by the
      drivers (`tools/test/native-menu-rows-baseline.json`). Read on
      2026-10-01, the sites are of four kinds, and three of them need the
      manifest to say more than it can today:
      (a) rows a `dynamic` entry leaves to the driver (Windows `register`,
      `append` and `add`: the WPM widget rows of Metrics, the AI menus):
      convert each to `check` or `command` with its predicate, as the
      conversions of 2026-08-07 did; the rows that tick themselves on the
      live menu need a rebuild after the click instead;
      (b) fixed-key rows inside the result of a `list` provider (the
      disable, tap and hold rows under each Tap-Hold key, the rows under a
      gesture slot, a hotstring file or an AI profile): the manifest needs a
      declared child template for a list parent, read by the three
      renderers;
      (c) separators a provider inserts between its own rows (155 of the 459
      sites): they follow (b), as part of the template;
      (d) the tray root bootstrap (Windows `tray_bootstrap.ahk`,
      `menu_init.ahk`).
      Metrics widget rows are now shared `check` declarations on all three
      drivers. Native getters retain stored colors/graph checks while disabled;
      Windows commands rebuild through the normal tray owner after durable
      acknowledgement. One golden fixture covers all 16 state combinations
      in each native menu suite; command regressions fence refused writes and
      ensure a refused Linux stop never starts the widget instead. Native CI
      run 36920222032 passed the new widget behaviors but exposed an API-family
      census that counted Menu( inside domain-helper names. The counter now
      recognizes complete native tokens (including whitespace calls); a source
      fixture covers every family, helper suffixes and comments without raising
      any baseline. Native run 36922684126 now passes Windows unit, engine E2E,
      packaging and installation, as well as the macOS and Linux test lanes.
      Order: finish other computed Metrics rows, then the template of (b)
      on Tap-Holds (the smallest menu that has one), then Gestures and
      Shortcuts, Hotstrings (Windows 35, macOS 59 sites), the AI menus
      (Windows 41, macOS about 70), and Linux `menu_builder.lua` (123) along
      each. One commit per menu, the baseline lowered in the same commit.
      The update rows greyed on a local version (2026-10-01) were added as
      provider rows and join the About slice.
- [~] **88.** AI prediction tooltip style (`llm-line-style`): the line rule
  is now `_shared/lua/tooltip/llm_line.lua`, read by macOS and Linux and
  ported by Windows, pinned by
  `_shared/tests/corpus/tooltip/llm_line_vectors.json`. Seen on a real
  Windows 11 on 2026-10-01 (grey typed, green corrected, orange next,
  indentation 0, +2, -1 and -3). Remaining: look at the Linux GTK panel
  and the macOS canvas on real machines (the suites cover the rows, not
  the pixels). Windows now retains the shared suppression/emphasis receipt
  through parsing and prediction execution, paints corrected/next segments in
  the declared weight and measures each actual font before placing the panel.
  Its native GDI cache owns separate family/height/weight identities and
  preserves deletion debt. Shared corpus assertions now require the Windows
  bold result; native HFONT/Text-control regressions cover real font weights,
  widths and painted geometry. Focused portable checks passed; full integration
  and native Windows CI remain pending. The Mac/Linux visual acceptance remains
  under this item.
  Native checkpoint 37069995600 exposed missing typography initialization in
  the headless Windows paint fixture. It now reads the canonical font family
  and size, asserts valid values and restores the prior aliases in finally.
  Actual WM_GETFONT bold/regular weights, geometry, control counts and GDI
  retirement assertions remain unchanged; native Windows confirmation is
  pending.
- [~] **91.** Windows: « Combinaisons de touches » as on macOS. Done on
  2026-10-02: every ordered pair of the keys of `[tap_hold.catalog]`
  (key 1 then key 2 is not key 2 then key 1), each with « hold 1 + tap
  2 » and « hold 1 + hold 2 », listed by hand; the three former families
  are the recommended pairs (`infra/key_combinations.ahk`). The shared
  group now offers recommended/clear commands on Windows and macOS. Its
  native owners preserve unrelated shortcuts and recover rejected reloads;
  clear keeps the combination switch. Every Windows pair shows its action
  directly, including an explicit disabled label, before opening the picker.
  Restoring imports the three historical shared recommendations (AltGr +
  left Alt: previous word; AltGr + CapsLock: next word; left Alt + CapsLock:
  CapsWord). Linux still needs the combination engine tracked by item 93.
  The Windows bulk owner now limits action-parameter cleanup to known
  catalogue pairs, preserving future pair parameters as well as their
  slots. Both existing native preservation assertions remain intact.
  The menu fix passed full three-OS checkpoint
  [37008038530](https://github.com/adrienm7/ergopti/actions/runs/37008038530)
  at `b92d9dec8`: unit tests, E2E, packaging and installation, with release
  publication skipped. Remaining:
  (a) the chord slot (both keys within the simultaneity delay), with its
  symmetry, its delay and « copy tap to chord »: the first key of a chord
  must wait for the second, while every Windows tap-hold owner takes its
  hold at key-down; (b) on a standard AltGr layout a pair that ends on
  AltGr loses to the `~SC01D & ~SC138` combination that reads AltGr's
  fake LCtrl, and a pair that ends on LCtrl fires on that fake LCtrl; (c)
  a real-keyboard check of the order rule (a key held alone, then joined
  by another, must not fire the pair), which rests on AutoHotkey
  recording a key's physical state after its criteria have answered.
- [ ] **93.** Linux: the key combinations of item 91. The tap-hold engine
      binds no combination (`platform/remap/tap_hold_engine.lua` only cancels
      taps when a second tap-hold key goes down) and the Shortcuts menu draws
      no `key_combinations` group. Port the pair model of item 91 (same pair
      ids, slots and config sections as Windows), decide the chord inside
      `M:process` / `M:tick`, and widen the manifest group to `linux`.
      `caps_word` and `one_shot_shift` are `ahk`-only catalogue actions
      today. Left out of the 2026-10-01 session on purpose (the maintainer:
      « fais seulement pour Windows »).

- [ ] **96.** Remove the separate Ergopti+ AltGr-adjustments option from the
      Layout menu. Selecting the Ergopti+ keylayout in the emulation picker must
      suffice. Verify that the layout supplies every intended change, retire
      redundant feature gates and settings through their migration owner, and
      add native regressions for the selected layout without an extra switch.

- [ ] **97.** Replace the fixed accent/direct-symbol shortcut submenu with
      user-owned entries, empty by default and offering "+ Add". Let a user on
      any keyboard layout choose an action from the shared catalogue or enter
      a character, then assign a physical key or modifier chord. Include é, à,
      è, ç, ù, circumflex/diaeresis dead keys and arbitrary punctuation (comma,
      period, colon, etc.). Ergopti emulation/keylayouts already supply their
      symbol mappings, so do not duplicate them as default shortcuts. Share the
      entry model, picker and persistence contract across drivers; test capture,
      custom Unicode output, dead-key composition, neutral defaults and refusal
      behavior through automated native and parity suites.

- [ ] **98.** Replace the fixed "make J the star key" setting with a physical
      key and output chosen by the user: any keyboard position and arbitrary
      character, including choosing no star at all. Integrate with item 97's
      shared user-owned shortcut model rather than another fixed-layout switch.
- [ ] **101.** Investigate the supplied Windows diagnostic's retained keylogger
      shutdown debt (watchers=0). Keep privacy filtering fail-closed;
      distinguish measured stalls from causes before changing tooltip/hook code.

The navigation-editor checkpoint (run 36928152648) passes all 72 Chromium/WebKit
rendering scenarios, Windows unit/engine/installation and macOS unit/E2E/all
installation variants. Linux unit passes, but its real accessibility-bus probe
exceeded the five-minute step timeout; Linux packaging/installation did not run.
Keep that failure separate from the passing browser and native results.
The next non-release run 36931498806 passes the complete Windows, macOS and Linux
pipeline, including the previously timed-out accessibility-bus probe and every
installation variant. It also proves the diagnostics correction: the rich page
is attempted below the old RAM cutoff, warm browsers bypass the cold-start
heuristic, and actual browser failures retain schema-ordered native controls.
Windows unit tests create those controls and verify sections, separate logs and
resize; the original three JS guards failed before the correction.

The macOS typing-rollover slice resolves the shared canonical key list through
its backend aliases. Native taps cancel pending holds on the next press; a long
hold activates at the configured threshold, preserving prior physical modifiers.
An inactive hold cannot clear another owner's navigation layer. Thirty-five
actual generated-graph timer replays cover taps, holds, cancellation, key release,
per-key timing, cleanup and inactive/revoked generation authority. Saved timer
outputs carry live mode and tombstone conditions, while historical fingerprints
retain the pre-timer immediate-hold graph (a deliberate mutation is rejected).
The shared alias/refusal contract runs on both Lua
runtimes for all three backend columns. Karabiner's lack of release-order rules
means a very fast chord on these typing keys becomes a tap, as requested.
Non-release run 36935089945 at `be5a40fee` passes the complete three-OS pipeline,
including all installation variants. Its temporary branch has been removed.

The metrics privacy filter now reads "Ignore system authentication" in
all 21 locales. The existing setting and system-authentication exclusion
behavior stay with their current owners; only the label is shortened.

The supplied diagnostic's three unsupported-bound-file warnings were obsolete:
Windows already routes repeat corrections, rolls and SFB reduction through the
real TOML loader. Successful discovery no longer raises those warnings or the
diagnostic warning count. The portable source guard fails on the original claim
and rejects its reintroduction; the registered native regression captures enabled
warning output and verifies all 83 shipped source entries remain readable.
That native case passes non-release run 36935760620 at `21de5dcea`: the complete
three-OS pipeline, including every installation variant, is green. Its temporary
branch has been removed; the run also covers the 21-locale privacy label.

The order-dependent macOS terminator failure is resolved by the production-root
module isolation already committed in `612000595`. Two additional regressions
poison the shared terminator module and catalogue cache slots with boolean true,
reproduce a real require failure, then run the actual purge and reload the real
catalogue while preserving test infrastructure. The full macOS suite and the
reported LLM tooltip case pass checkpoint 36957664162 at `68a8f1462`; these new
exact-boolean regressions also pass the focused runner.

- [~] **102.** Simplify each Hotstrings category submenu to two commands,
  "Enable all" and "Disable all", replacing the duplicate category and
  whole-section activation controls. Declare the structure once in the
  shared manifest and translate its labels into all 21 locales. Apply the
  effective category/section changes through their persistence owners;
  retain unrelated choices and fence refused writes/runtime publication.
  Replay the same full-enable/full-disable behavior on every driver.
  The macOS lifecycle helper now rejects the preference owner's returned
  refusal as well as a thrown publication error. Three regressions first
  showed false acknowledgements after false/nil/throwing writer results;
  they replay the real save/rollback owner, preserved choices and runtime,
  withheld cache updates and the visible failure notice. Void UI-only
  callbacks remain valid. Category bulk operations now share one Lua
  planner and a Windows port with a 17-vector common corpus. Both commands
  explicitly set the category and its actionable sections, preserving the
  independent engine master and legacy Layout remapping. Linux commits
  through its existing canonical-choice owner; macOS includes persistence
  acknowledgement inside the registry/settings rollback; Windows uses its
  existing lifecycle-fenced reload journal. Native-owner cases cover real
  settings/source bytes, unrelated choices and immediate/late publication
  or writer refusal. The full native-owner checkpoint 36954011552 at
  `7ad954b22` is green on all three OSes, including Windows unit/E2E,
  packages and installation. Standard and language-category submenus now
  consume `hotstring_category_menu`: two explicit commands, optional source
  file, separator and native section data. Both commands remain available
  behind a closed category or paused engine. Two new label keys have all
  21 translations; source and native-menu tests reject duplicate switches,
  inverted intent and duplicate rendering. macOS save-refusal tests retain
  category state and withhold a success refresh; Windows native menu clicks
  replay the real reload journal. Linux treats only exact true as an
  acknowledgement and surfaces one localized, keyboard-released error dialog
  on false/nil/throw; eight native-menu cases cover both requested postures.
  The category-menu checkpoint 36957664162 at `68a8f1462` is green on all
  three OSes, including native Windows menu callbacks, packages and installs.
  This checkpoint precedes the following extension-file owner changes.
  Windows extension-file submenus now consume the same shared commands as
  their existing macOS/Linux category views. Their owner rediscovers the
  extension under the configuration lease and commits the group plus every
  section as one sparse batch. Two common vectors preserve colon namespaces
  and Unicode section names; native cases retain the engine master, sibling
  categories, private source and package contents across immediate/late
  refusal, and reject unknown or uninstalled content before writing.
  Personal menus now use the shared explicit commands on macOS and for the
  primary Windows personal file; Linux's existing personal category rendering
  is covered by four parity cases. macOS commits all selected personal/custom
  gates and sections together, restoring prior and absent gates after a refused
  canonical save without starting capture. Individual personal file submenus
  select only their own group. Windows uses the conditional reload journal,
  reads personal section inventory afresh under the lease, preserves native
  repaint references and restores exact configuration bytes after immediate or
  late replacement refusal. The native CI owner cases passed in run
  37016239316; its two remaining Windows failures exposed a direct native call
  and a default-menu freshness guard. Rendering now reads item counts through
  the tray adapter and keeps an explicit fresh default path, with native
  regressions proving independent default menus and refusal of populated targets.
  Full three-OS checkpoint 37033032620 at `6275cac35` passed native unit,
  E2E, packaging, installation and launch gates with release skipped, after
  correcting owned submenu teardown in the Windows fixtures.
  Windows Dynamic now renders the shared explicit commands and journals the
  seven canonical family choices, rediscovered under the lease. Its scope owns
  no extra category gate and preserves the Hotstrings master and pause. Native
  cases cover both targets, immediate/late refusal, exact recovery, unknown
  neighbours and concurrent ownership; full CI remains pending for this slice.
  Additional Windows personal-file views still need an identity and gate owner
  shared by the live engine and previews. macOS's personal-info placeholder
  still needs admission
  to its otherwise shared dynamic scope.
  The Windows discovery boundary now filters its mixed legacy tray map to
  the Hotstrings namespace before requesting any feature metadata; a native
  case excludes Layout, Gestures and Shortcuts from both discovery and selection.
  Runs 37046976773 and 37047412149 exposed missing boot-owned globals in
  headless Dynamic fixtures. They now consume the actual tray declarations,
  validate their manifest families and restore previously set or unset state.
  All ten native cases retain their ownership, pause and refusal assertions;
  production still uses its curated boot order. The corrected native CI is
  pending. Shared dynamic row ordering remains a separate follow-up.
  Linux Dynamic now consumes the same explicit command pair and shared bulk
  planner. Its existing transaction commits the declared dynamic master and
  seven manifest families as one conditional cohort under both real leases,
  with exact backup, runtime acknowledgement and retained inverse on refusal.
  Scoped adoption validates only owned leaves; unrelated outdated previews,
  global master, pause, overrides, personal sources and unknown neighbours stay
  preserved. The old menu failed eight meaningful cases; 57 affected cases
  pass locally. Full three-OS validation remains pending for this slice.
  Native checkpoint 37052939737 then exposed a missing label-module include
  in the headless runner. It now loads the actual pure manifest descriptions
  owner, and the Dynamic fixture rejects its absence before menu construction.
  The eight transaction assertions remain unchanged; native validation remains
  pending for this additional harness correction.
  Checkpoint 37056318950 exposed the next omitted boot dependency: dynamic
  counting reads the personal-information map. The fixture now derives that
  map from the real entrypoint and owns a fresh count cache, restoring both
  assigned or unassigned globals afterwards. All transaction assertions remain
  unchanged; actual AHK execution awaits the next native checkpoint.
  Checkpoint 37060216766 reached the transaction assertions and exposed
  stale text-cache reuse by the pending-reload fixture. Its detached candidate
  now reads an exact owned copy through the real config reader, matching a
  replacement interpreter while preserving this process's cached authority.
  The original posture/backup/refusal assertions stay intact; an additional
  assertion proves the pending live text cache still contains the old source.

- [~] **104.** Split common autocorrections into meaningful selectable sections.
  An independent pre-split corpus now freezes all 140 rules, flags, metadata,
  delays, common priority and historical order. The shared editorial catalogue
  classifies 34 names, 95 abbreviations and 11 technical terms outside runtime
  category discovery. Actual reader/registry/cache regressions compare the
  complete legacy corpus on every driver; native Windows CI remains pending.
  No source, section ID, label or activation choice changes in this slice.
  The runtime split still needs conditional fan-out migration of config.toml
  choices and the independent hotstrings_overrides.toml timing/presentation
  overrides, preserved global order, 21-locale names and per-section E2E.
  Never regenerate these historical expectations from the split source.
  The Windows value-clone owner now preserves Map comparison modes and
  independently owns typed TOML Boolean wrappers. Four registered native
  regressions cover distinct quoted keys, nested mutation in both directions,
  typed render/readback and an isolated generic clone without the TOML class.
  Native Windows proof remains pending; unsupported opaque objects keep their
  previous identity contract.
  The native clone probe now sets Map.CaseSense while the fixture map is
  empty, before inserting values; AHK forbids changing that setting afterwards.
  Checkpoint 37056318950 demonstrated the fixture setup error. Production
  cloning and all independence/case-sensitivity assertions remain unchanged.
  Checkpoint 37061649827 additionally exposed the redundant global class
  declaration through the unchanged native namespace audit. Read-only class
  references already resolve the global constant, so the clone owner now
  keeps its IsSet guard without redeclaring TOML_Bool. The absent-class probe
  and every typed-copy assertion remain intact; native validation is pending.
  Shared Lua, Windows and the JS reference now specify `copy_if_absent`:
  copy an existing source into an unoccupied destination, retaining the source
  and every explicit destination, including false and occupied ancestor or
  descendant namespaces. Copies independently own supported collections and
  preserve source records. Three independent fixtures and five registry
  defects cover ordering, repeated/no-op copies and strict shape validation;
  the original engine failed five new cases. Focused JS, macOS 40/40 and Linux
  LuaJIT 37/37 passed; full/native Windows validation remains pending.
  Schema version remains 8 and no runtime subsection split is introduced.
  The Windows registry now owns every registration sequence identity;
  transported builder or caller metadata cannot replace it. The independent
  140-rule corpus exposed the second sequence allocator in native CI; its
  historical order assertions remain intact. Four registered native cases
  cover prebuilt metadata, mixed factories, override attempts and group
  isolation. The corresponding Lua registries retain their existing single
  sequence owners. Checkpoint 37061649827 then exposed a distinct Windows
  admission bug: an earlier case-conform rule wins mixed input it subsequently
  refuses, hiding an executable exact-case entry. STAR and END matchers now
  consult the existing pure conform policy before arbitration, matching the
  shared Lua engine. Regressions cover both insertion orders, actual priorities
  and sequences, valid case forms, exact mixed fallback and no-op masking,
  without invoking callbacks during matching. The original circumflex matrix
  and independent historical corpora remain intact; native validation is pending.

- [ ] **105.** Let users define programmable dynamic hotstrings on Windows,
      macOS and Linux, separately from the ordinary hotstrings editor. Provide
      a documented user-code entry point under "Dynamic hotstrings", examples
      and a callback API that lets users compute any replacement/action rather
      than limiting them to the editor's fields. Share the trigger, callback,
      enable/disable and lifecycle contracts; isolate native implementations.
      Preserve user source files, report load/execution errors visibly, and
      cover real callback execution, live enable/disable, cancellation and
      suspended/privacy-filtered input with automated cross-driver tests.

- [ ] **106.** Expand the shared gesture/keyboard action catalogue for user
      automation. Discover and offer Apple Shortcuts on macOS; inventory and
      expose available Windows/Linux equivalents, installed automation tools,
      shell/PowerShell scripts, launchers and application actions. Verify each
      provider's real invocation contract and availability rather than listing
      unimplemented actions. Let every driver assign a user script, Python file
      or other executable with explicit parameters. Use the same parameter model,
      picker and persistence for gestures, keyboard shortcuts and other action
      consumers; keep discovery and execution in platform adapters, with
      translated reasons for unavailable OS-specific actions. Test real fixture
      scripts, paths/arguments with spaces and Unicode, process-start refusal,
      execution errors, lifecycle/cancellation and cross-consumer parity.

- [~] **107.** Make the number-row policy explicit: native behavior, digits
  directly or symbols directly, with an acknowledged migration of the old
  Windows Boolean and preserved unrelated settings. The current Boolean now
  resolves actual desired KLE base descriptors before falling back to native
  HKL probing. Already-direct Ergo-L over AZERTY retains Shift symbols; an
  emulated swap emits through the existing KLE owner rather than flattening
  actions/dead states to text. Inspection preserves Caps and pending state.
  Independent ten-key vectors and captured registered criteria/callbacks cover
  actual AZERTY/QWERTY HKLs, base/category/navigation changes, AltGr, Caps
  descriptors and dead-key composition; native CI remains pending.
  Remaining: the three-choice shared policy, persistent migration, translated
  choices and corresponding owners on supported macOS/Linux paths, with genuine
  platform limits documented. No enum or schema change occurs in this slice.
- [~] **108.** Make the default hotstring-editor shortcut follow the effective
  physical key that directly types the selected magic character: Ctrl on
  macOS, Win/Super on Windows and Linux. The shared conditional policy now
  represents this as one ordinary editable slot. Missing values select the
  default; explicit none and existing personal physical-chord assignments win.
  The slot follows direct sources for star, `ù`, `;` and other admitted magic
  characters on any layout, and refuses missing, ambiguous, dead or modified
  sources. Native binding owners retain their pause, inhibition, generation
  and publication fences. Its editable row and unavailable reasons are
  translated in all 21 locales.
  Windows resolves neutral physical keys from the acknowledged layout and
  native HKL. macOS probes the exact active TIS Unicode layout through its
  signed native launcher, then retargets through its existing registrar.
  Linux owns an X11 keymap/group probe and verifies source/device identity;
  Wayland source ownership remains unavailable, with an explicit translated
  reason and the editor still reachable from the menu.
  Fresh configuration omits neutral ordinary shortcut rows on all drivers;
  an explicit user none is retained by the acknowledged shared writer.
  A closed schema-v9 migration transfers representable macOS legacy editor
  shortcuts only to published assignable chord slots, preserves occupied or
  unknown destinations and refuses ambiguous sources without publishing.
  Historical saved Win+D/editor choices remain; the old fixed magic hook and
  Win+D recommendation are retired.
  Legacy macOS built-ins retain their existing native factories and publish
  physical claims through their exact lifecycle; late claims suspend only the
  conflicting conditional owner, with acknowledged compensation and cleanup
  debt. A revoked owner cannot be restored after a refused deletion.
  Focused local regressions cover native source admission, collision/none
  precedence, configuration publication/refusal, scope restoration, migration
  parity and independent corpora. Complete local integration passed the selected JS, macOS/Linux unit
  and E2E gates. Native three-OS CI, packaging, installation and launch
  remain pending. Native macOS/Windows
  layout delivery and genuine Wayland seats are not qualified by Linux-host
  stubs or the Xvfb source probe.

The Windows physical catalogue now uses the existing entry-point \_SharedDir owner when called without an injected root. The previous undefined SharedDir stopped legacy Win shortcut registration before the suite or application could start. A direct zero-argument catalogue and actual legacy-registration regression checks independent physical identities and exact callback/root preservation; existing native lifecycle assertions and warning policy stay intact. Encoding and strict conventions pass locally, while native Windows unit, compile and E2E qualification remain pending.

Native CI run 37085780111 exposed a macOS launcher compile failure before
source-probe tests could run: Swift imports Carbon's UniCharCount as Int.
The translator now uses that imported type; its exact selected-source,
direct-output and dead-key contracts are unchanged. Native rebuild and the
existing real US/French Carbon tests remain pending.

Native CI run 37087943283 exposed six Windows contextual fixture failures. The repair preserves absent global state, uses the actual registrar spelling, separates shifted Digit8 refusal from the direct numpad source, counts the contextual group without an Add row, and keeps the declared editor default behind its closed master. The private native probe retains strict warnings in a local scope. The complete selected local gates pass 353 JS checks; native Windows revalidation remains pending.

- [~] **109.** Give every application window the same "ErgoptiPlus — Title"
  format. GUI/WebView titles now use one prefix/separator policy in
  `_shared/ui/apps.manifest.json`, with generated Lua/AHK composers; an empty
  prefix removes branding. All captioned Windows GUI factories, including the
  navigation-layer editor and keyboard-layout manager, and live retitles use
  that owner. Shared app metadata selects brandless translated keys; Linux
  native captions use them across every supported app and all 21 locales.
  Native caption/retitle and private generated-policy regressions cover the
  hosts; the CLI regression failed against the original translated raw-Gui
  bypass before passing with its stronger audit. Complete three-OS
  checkpoint 37046411788 at `ea6b21bed` passed unit/E2E, packaging, installation
  and launch with release skipped. Its private native-policy probes now write the actual Gui caption to
  UTF-8 receipts and use ASCII stdout acknowledgements; runs 37040137327 and
  37040369275 exposed ANSI decoding in the previous test transport. Native exit,
  stderr and the independent expected-caption assertions remain strict.
  Swift updater panels now use a generated composer from that same policy,
  bare captions in all 21 locales and live retitling of the retained progress
  panel. Actual AppKit tests and seven private generated/compiled policy cases
  cover empty, custom, quoted, interpolation-looking and Unicode prefixes;
  native Swift CI remains pending. The private environment receipt now reads
  each variable in its own native `printenv` invocation: Apple BSD `printenv`
  accepts one name, so the previous GNU-style two-name call omitted `PATH`.
  Both exact values, unchanged parent environment, child exit and empty stderr
  remain asserted. The official Apple command reproduces the old mismatch;
  complete macOS XCTest qualification remains pending. Captionless overlays retain their separate
  native presentation owner.
  Ninety-one post-bootstrap Windows message/input calls now compose actual
  native captions through one delegate; bodies, options, defaults and results
  retain their native semantics. Bare startup/uninstall captions have all 21
  translations. The production-wide owner audit has 43 mutation cases and
  exactly seven bounded bootstrap exclusions; focus, no-confirm and fixable
  error audits recognize the delegate with independent regressions. Five
  generated-policy native probes cover real captions/bodies, timeout, password,
  default-button and cancellation receipts. Focused JS checks passed after the
  old audit accepted a caption bypass; actual AHK and full CI remain pending.
  The macOS Package lane now prepares the repository-pinned Node before
  Swift tests and retains their exact PTY transcript. A strict reporter preserves
  both native and capture failures, requires complete non-vacuous XCTest
  receipts, and annotates actual errors with an uploaded failure transcript.
  Private verification passed formatting and all 350 JS checks, including the
  actual reporter and pipeline wiring. Checkpoint 37059479394 exposed the
  exact private Swift probe failure: forced crash backtracing is unsupported
  for executable capabilities classified as privileged by the runtime. Each
  private child now receives the supported enable=no option, preserving its
  inherited environment and parent XCTest setting. An actual printenv child
  asserts this boundary; all seven exact caption/exit/empty-stderr checks stay
  intact. Native macOS qualification remains pending.
  Native checkpoint 37056318950 exposed two premature newline escapes in the
  child AHK probe source. The producer now retains the child escape, preserving
  every actual caption/body/options/timeout/cancellation assertion. Checkpoint
  37060216766 then exposed a fixture local named Edit shadowing AHK's built-in
  class under #Warn All. It now uses InputControlHwnd; warnings and exact
  receipt assertions remain enabled. Production dialog code is unchanged;
  the corrected probe awaits native Windows CI.
  Remaining native caption paths include file pickers, notifications and
  genuine Linux dialog title APIs.
  Non-release checkpoint 36949562328 at `5b4d9e8a3` passes the complete
  Windows/macOS/Linux pipeline, including package and installation lanes. It
  validates the shared "Ergopti+" extension name in the actual tray providers,
  Windows four-finger tap's monitor-local Alt+Tab recommendation and invocation,
  all thirteen pending-dead-state reset cases and the consuming arrow hooks.
  The Windows menu-name fixture owns neutral category collections and restores
  assigned or unassigned globals. The arrow fixture derives scan codes from the
  shared registry, retaining its action, criterion, consumption and order checks.
  The native checkpoint also passes CI's real formatting check. Its temporary
  branch is removed after validation.

Scoped verification now executes the actual Prettier/Ruff `format:check`
before suites, using the formatter owner's extension inventory. A regression
rejects the formerly missing command, and a simulated formatter refusal makes
the CLI fail. Checkpoint 36947209412 exposed three formatting misses that are
corrected. The real formatting check, all 349 JS checks and both XKB Python
suites pass locally; formatter self-tests alone cannot validate source files.

The shared Shortcuts declaration separates modifier-shortcut groups from key
combinations. Linux currently omits the combinations group, so the same boundary
separates its modifier shortcuts from script controls. Existing renderer tests
exercise all manifest menus with empty-edge and doubled-separator provider probes
on the three drivers; the renderer retains one separator between visible rows.

The Windows Layout menu now has one disabled "Emulated layout: none/name" status
before "Manage layouts…". A disabled category cannot claim a stored choice is
active; Ergopti, Ergopti+, registry names and an absent catalogue entry stay
distinct. Selection is owned by the shared manager, and the obsolete second
built-in selector is removed. macOS and Linux's existing picker selects native
OS input sources, so it retains that platform implementation. Both status forms
are translated into all 21 locales. Eight registered native cases cover status
data and the actual Win32 disabled row, with management remaining usable;
the original Windows row was clickable and did not name its current emulation.
Non-release run 36937408564 at `56efa2bd8` passed these cases and the full
Windows/macOS/Linux test, package and installation lanes.

The supplied diagnostic also proves released-SC138 dispatch on Kana. Its hotkey
criterion accepted the Kana family without querying the physical key; the later
callback rejected the output after the suffix had been captured. Eligibility now
requires physical SC138 on Kana, preserving the unconditional first-press anchor,
and still requires physical RAlt on other families. Seven new registered cases
exercise the pressed/released queries of all three families and the actual native
query on a released host key. Existing hold-owner cases explicitly model a held
key and retain their non-AltGr rejection assertions. This AHK prefix-latch repair
does not establish the cause of item 99's exact layout-switch report; Linux and
macOS do not use AutoHotkey's custom-combination latch. Non-release run
36938644227 passed the seven new cases, but caught two older fixtures that
assumed Kana alone meant a held key, and one additional direct platform call.
The gate now uses the existing KeyState port, with an injectable query shared
by captured criteria. The old fixtures explicitly model held/released presses,
retain their slot/emulation assertions and restore the query after each case.
The script plan now also rejects assigned chords on a modeled released key;
the actual emulation criterion rejects the released magic-key suffix.
Non-release run 36940286440 at `64edbf898` passed the complete shared,
Windows/macOS/Linux unit and E2E suites, packaging and installation lanes,
including this correction and the maintainer's four new commits. No release
was published.

The registry emulation's dead-key resets now use the scan-code identities of
all 13 cancel/navigation keys. The shared physical-key registry independently
pins the captured names; thirteen native cases drive the actual registered
criteria and callbacks on Ergo-L, Ergopti and Ergopti+, covering pending/idle,
disabled layout and active navigation ownership. The precedence guard on Linux
and Windows now resolves the bounded literal-array/prefix-loop form, with a
fixture that rejects the pre-fix names and leaves unknown expressions unjudged.
Before the production change, the Linux guard failed on five shadowed reset
names (Backspace, Escape, Enter, Tab and Delete). macOS/Linux use installed OS
layouts for dead-key handling and have no corresponding AHK registration.
The four prediction-navigation arrow hotkeys now share those scan-code
identities too; their existing ownership, hook-order and step assertions remain
intact. Non-release runs 36941345120 and 36944695471 caught incorrect new
fixture seeds for Ergopti+: plain SC01B types j, Shift+SC01B types underscore,
and Shift+AltGr+SC01B starts diaeresis. The five seeds now live in the shared
keystroke corpus, replayed by the Windows reset cases and independently checked
against the Linux conversion's actual dead-state triggers, including custom
Ergo-L triggers. The portable regression rejected the old underscore seed;
all five conversion/keystroke tests pass after correction. Thirteen native
cases refused the wrong seed. Checkpoint 36947209412 passes all thirteen
corrected cases and identifies the remaining old failure: the tooltip hotkey
fixture still expected name-based arrow declarations. It now derives physical
identities independently from the shared registry while retaining every
consuming-hook, action, criterion and ordering assertion. Its native rerun passes checkpoint 36949562328;
the production identity repair remains unchanged.

Windows and macOS now render each key-combination pair from the shared
`key_combination_pair_menu` declaration. Native providers supply their supported
slots; Clear is disabled for an unassigned pair on both drivers. A macOS
regression first rejected the old native assembly when the real declaration's
order changed, then passed after migration. All five focused menu tests, 12,801
Lua tests, selected E2E scenarios and 349 JS checks pass; the menu parity ratchet
now requires 17 shared-rendered macOS menus. Two Windows cases inspect the actual
menu's disabled flag in native CI. Item 91's remaining engine issues stay open.

Native AppleScript dialogs and numeric tap/hold prompts now compose their
captions through the shared owner before escaping; five existing bare keys
retain all 21 translations and their bodies/buttons/defaults/focus semantics.
Independent regressions reject both original Mac bypasses. The seven
pre-bootstrap Windows modals now use the same hoisted native-dialog delegate;
no entry include order changes or duplicated product prefixes are needed.
The title audit has zero bootstrap exclusions and rejects all seven original
consumers; 46 independent mutation cases pass. Native probes invoke the
actual delegates before their includes and preserve caption/body/options/
cancellation checks. Actual Windows and AppleScript GUI qualification remains
pending.

Native dialog tests snapshot caption, body, buttons and password properties
before file I/O can pump messages and retire a timed dialog. Delayed
persistence must observe actual retirement while retaining every original
caption, body and result assertion. The independent expiry mutation must
fail; native Windows qualification remains pending.

Checkpoint 37085309234 showed that the capture callback prevented its
interrupted modal loop from acknowledging window retirement. The fixture
now returns that callback, waits for the actual Timeout result, then persists
its complete snapshot. The retired-window receipt and exact expired-read
rejection remain strict. Native Windows requalification is pending.
Native Windows file-picker captions now pass through the same shared title
composer; option flags, root/default paths, filters and native return shapes
are preserved. Independent audit mutations and actual five-policy dialog
probes retain strict result and exact process-retirement assertions. Native
FileSelect and folder-picker qualification remain pending Windows CI.
Folder chrome now uses one scoped SHBrowseForFolderW caption owner; the
native explanatory prompt, option flags, initial/root selection and empty
String cancellation remain independent of the shared title policy. Exact
callback cookies, HWND leases and PIDL/COM retirement receipts preserve
partial-acquisition and refusal ownership. Five actual generated-policy
folder probes and independent native-port refusal cases retain their strict
assertions; portable checks do not qualify this new native ABI at runtime.

## Time estimate

Order-of-magnitude estimate: 40–70 agent-days for the current remaining
product and verification scope. Item 31 alone records 30–40 agent-days plus
real-Mac acceptance. Parallel work can reduce elapsed implementation time;
shared integration, native CI and genuine hardware acceptance still constrain
completion. This is a budget range, not a fixed delivery date.

## Current local evidence

Portable specifications, pending changes, branch accounting and verification
results are in [the handoff package](handovers/2026-09-28-ergoptiplus/README.md).
Read its `VERIFICATION.md` and `VERIFICATION.json` for composite gate results.
Paths under `D:/ewt/` in those files are historical; that directory no longer
exists.
