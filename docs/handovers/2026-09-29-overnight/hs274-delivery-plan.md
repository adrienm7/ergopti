<!-- docs/handovers/2026-09-29-overnight/hs274-delivery-plan.md -->

# HS-274 delivery plan: exact physical-key accounting with an Ergopti-owned background Karabiner runtime

Base: `origin/dev` at `c3005e0b`, read-only. The local clone is shallow. The historical HS-274 branches are gone from origin.

**Claims I re-checked in this pass**

- **Double count is still live.** `static/ergopti_plus/macos/modules/keylogger/init.lua:817` still reads `kc = KcBridge.is_ke_managed_output_kc(keycode) and nil or keycode`. That expression always returns `keycode`, so every remapped tap is credited twice.
- **Ledger emission sites.** They are only at `generator.lua:877,883,930,931`, and the none/none rule has none (`:862`).
- **Default config collides.** The shipped `[hs_tap_hold]` defaults sends `caps_lock` tap to `return` and `left_command` tap to `backspace`, while physical Return and Backspace are none/none (`_shared/tap_hold/defaults.toml:219,224,229,230`). HS-274 therefore hits every default user, not only the Escape/Space fixture.
- **Security flaw in the upstream daemon (checked at 9312593e).**
  - `codesign_manager::same_team_id` returns `true` whenever the daemon itself has no verified Team ID.
  - The daemon socket is chowned to the console user with mode 0600 (`receiver.hpp:59-86`).
  - So a self-signed or ad hoc fork would let any process running as the console user open `hs274_capture`. That is a raw keystroke stream that bypasses Input Monitoring.
  - Reader 2 said "any local user". The correct scope is "any process of the console user". It must still be fixed before anything is distributed.
- **Ergopti can own the config without a source patch.** The console user server sends `start_device_grabber` with `user_core_configuration_file_path` taken from `get_user_configuration_directory()`, which honours `$XDG_CONFIG_HOME` (`receiver.hpp:264-271`, `core_service_daemon_client.hpp:219-223`, `constants.hpp:119-140`).
- **Built-in fail-safe.** When the console-user-server peer closes, the daemon stops the grabber. It re-grabs only if a system core configuration exists (`receiver.hpp:201-206`). If Ergopti owns that peer, its death returns the keyboard to native input.
- **Paths that must be patched.**
  - Upstream hard-codes its sockets under `/Library/Application Support/org.pqrs/tmp` (`constants.hpp:50-91`; `sun_path` is limited to 103 bytes).
  - `register_core_agents()` hard-codes the stock ServiceManager apps (`services_utility.hpp:9-10,53`).
  - Both must change for a headless install that can coexist with a user's own Karabiner-Elements.
- **kanata has no raw key stream.** Its TCP `ServerMessage` offers `LayerChange`, `MessagePush`, `HoldActivated`, `TapActivated` and similar, but no raw key event (jtroo/kanata `tcp_protocol/src/lib.rs`, main). kanata ≥1.13 needs root plus VirtualHIDDevice v8.0.0, and a hand-installed LaunchDaemon for the VirtualHIDDevice daemon (`docs/setup-macos.md`). kanata is LGPL-3.0.
- **Expired artifacts and an unexplained failure.**
  - Run 34783474637 (the pinned producer) now has 0 artifacts.
  - Run 34883676362 (OS autorepeat) failed at step 23, "Observe actual Escape and Space remapping". The job log sends everything to files, so the cause is only in artifact 10364596082 (retained until 2026-12-13).
- **Sibling branch overlap (not in dev).** `integration-2` (149 commits) and `wip/f2-karabiner-touchpad(-fix)` touch the same files: `platform/remap/{init,generator,config}.lua`, `RemapLeaseGuardian.swift`, `build_macos_app.sh`, the READMEs and memory.
  - `integration-2` adds `[karabiner] integration_enabled`, registers the guardian only while that switch is on, and stops vendoring the Karabiner-Elements installer.
  - Every work package below must start after `integration-2` lands, or be rebased onto it. Do not touch those worktrees.

---

## 1. Current state

1. **Production (Karabiner install).** Onboarding downloads, checksums and installs the official Karabiner-Elements 16.0.0 app, including its UI, system extension and root grabber (`onboarding.lua:83,194,916`). ErgoptiPlus merges token-scoped rules into the user's shared `~/.config/karabiner/karabiner.json` (`remap/init.lua:4198-4201`).
2. **Production (guardian).** The Ergopti item that can appear in Réglages Système › Général › Ouverture is the `com.ergoptiplus.remap-guardian` LaunchAgent (SMAppService). While it is `requires_approval` or `unavailable`, every ErgoptiPlus rule stays inert (`guardian_notice.lua:15-18`).
3. **Production (physical source).** Physical keys come from a `shell_command` in each tap/hold manipulator that appends to `metrics/karabiner_kc.log`, drained by `kc_bridge`.
   - This ledger does not cover none/none passthrough, combos, the nav layer or sentinels.
   - It checks privacy and pause when the ledger is drained, not when the key was pressed.
   - The log file is never compacted.
4. **Production bug.** HS-274 still reproduces at `c3005e0`: `docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua` exits 1, and `physical-collision.lua` exits 0.
5. **Dormant.** The aggregator's `physical_press` ingest (`aggregator/events.lua:418`, `aggregator/physical.lua`) exists, but nothing in production emits it.
6. **Prototype.** The Lua consumer library `physical_{wire,transport,delivery,baseline,clock,context}.lua` has green portable tests, but no production module requires it.
7. **Prototype.** The fork producer patch set for Karabiner-Elements 16.3.0 (`hs274_raw_patch.py`, `hs274_stream_patch.py`, `hs274-stream-*.hpp`) provides an authenticated pull/ack stream with device and cookie identity. It still declares only `coverage: fixture_only` and carries fixture-only code.
8. **Diagnostic only (native evidence).** About 12 hosted macOS-15 runs on a _virtual_ HID fixture proved the collision fix end to end through real Hammerspoon (run 34877932993 was the last green one). Two things were never proven: the standalone VirtualHIDDevice v8.5.0 together with a headless core under launchd, and real hardware.
9. **Diagnostic only (packaging).** The "complete fork candidate" rebuilds all 10 Karabiner-Elements products, including `Karabiner-Elements.app`, EventViewer and the Updater, and installs them over the official app. This contradicts the 2026-09-29 decision.
10. **Broken CI gates.** The hs274 workflows refuse dev and main, always end red because of permanent capability probes, and point at expired artifacts. The mainline CI runs no HS-274 replay test. Memory, the READMEs and a meta test still _forbid_ Ergopti from owning any Karabiner process.

---

## 2. Definition of done

These points come from `report.md:73-92`, `producer-contract.md:92-107`, `native-hammerspoon.md:254-258` and memory `project-hs-physical-accounting-needs-producer-ownership`.

1. **One authoritative source.** While a capture is admitted, physical credits come only from the producer stream. Quartz `keyDown` and `flagsChanged` credit no `kc`, `modifier_press` or `modifier_hold`.
   - The duplicate-count proof fails before the fix and passes after it.
   - The physical-collision proof stays green.
   - Logical text and non-synthetic classification are unchanged.
2. **Complete, ordered delivery with the real remapper active.** This covers:
   - remapped keys, passthrough keys and mixed none/action slots;
   - all 8 modifier sides, combos and the nav layer;
   - the OS autorepeat policy (not credited as presses);
   - ignored or disabled devices, multiple keyboards, hotplug, and the initial held state.
3. **Robust delivery.** The consumer handles partial reads, consumer exceptions, sequence gaps, stale incarnations, pause, privacy and disabled-app boundaries with late delivery, sleep/wake, teardown and successor leases. Unsupported coverage is reported explicitly, never as a false success.
4. **Measured cost.** Latency, CPU and RSS are measured in paired and reversed runs, with and without the stream. Queues are bounded and the input callback never blocks.
5. **Production consumer.** The real Hammerspoon consumer runs through the _production_ module, not `tools/diagnostics`, with normal startup and stop ownership.
6. **Correct key identity.** HID usage is converted to kVK with the keyboard type taken into account (the ISO swap).
7. **Distributable runtime, as decided on 2026-09-29.**
   - No Karabiner-Elements.app and no settings UI, EventViewer, Updater or MultitouchExtension.
   - Only the headless pieces run, as background processes owned by Ergopti, with the configuration owned by Ergopti.
   - The runtime is signed, pinned and reproducible.
   - There is a defined upgrade, uninstall and coexistence behaviour.
8. **Cleanup.** The ledger and the dead classifier are retired, and memory and specs are rewritten.

**What cannot be done, or needs outside approval or hardware**

- **Apple entitlements.** Ergopti cannot ship its own DriverKit extension or virtual HID device: Apple entitlements plus a Developer ID are required, and even root is refused as "not entitled". Only the unmodified, pqrs-notarized Karabiner-DriverKit-VirtualHIDDevice can be used. Its hidden `/Applications/.Karabiner-VirtualHIDDevice-Manager.app`, its notification and its Driver Extensions entry keep pqrs branding. This is unavoidable.
- **User approval on every Mac.** The system extension approval, the Input Monitoring and Accessibility grants for the owned core, and one admin password per install or root-binary update cannot be automated on a user's Mac. The CI trick (a temporary admin plus a verified Quartz click) works only on disposable runners.
- **No notarization.** Without an Apple Developer ID, the runtime cannot be notarized. `SMAppService.daemon` may refuse the self-signed app, as the agent path already anticipates (`RemapLeaseGuardian.swift:1973`). The fallback is an admin-prompt `launchctl bootstrap system`. Login Items will then show an item from an unidentified developer.
- **Real hardware only.** These need a real Mac: the Apple internal keyboard's fn/globe key, ISO vs ANSI, Bluetooth, two keyboards used simultaneously, and true autorepeat. Hosted runners only prove a renamed virtual fixture.
- **"Exact" has limits.** Counts are exact only inside an admitted capture. Before approval, during stream loss, or while a user's own Karabiner-Elements holds the keyboards, counts are recorded as explicit gaps and never reconstructed.

---

## 3. Work packages

Where each package is verified:

- **[L]**: provable in this Linux container, with `lua5.4`, `node`, `python3` and `g++`/`clang++`, then in mainline CI.
- **[H]**: needs a hosted macOS `workflow_dispatch` run.
- **[M]**: needs a real Mac.

Effort is in focused agent-days, including CI iteration.

### WP0: Decision record and invariant realignment [L]

- **Goal:** make the 2026-09-29 decision binding in routed context before any code changes, so implementers are not blocked by memory that says the opposite.
- **Files:**
  - `docs/memory/macos-hammerspoon.md`, through the `project-memory` skill: rewrite `project-hs-karabiner-exact-lease-isolation` and `project-hs-fork-admission-in-both-launch-modes`, and add `project-hs-owned-remap-runtime`.
  - `static/ergopti_plus/macos/platform/remap/README.md` and `launcher/README.md`, for the dual mode: shared (legacy) and owned.
  - The macOS section of `docs/ERGOPTI_PLUS.md`.
  - Leave the handover `PRODUCT_SPECIFICATION.txt` untouched; it is a snapshot. Rule R3 still applies to a user's _own_ Karabiner.
- **Depends on:** `integration-2` having landed.
- **Verify:** `node tools/test/verify-change.cjs`, which runs `lint:conventions:strict` and `test:doc-paths`.
- **Effort:** 0.5 day. **Risk:** none. Do not loosen `test_karabiner_stock_process_isolation.lua` here; that happens in WP6 together with the code it must allow.

### WP1: Exclusive-accounting policy and executable HS-274 regressions [L]

- **Goal:** replace the `and nil or` idiom with an explicit policy module, and turn the two audit proofs into suite tests.
- **Files:**
  - New `modules/keylogger/physical_accounting_mode.lua`, which answers "does Quartz credit `kc` now?". It returns `ledger` in the default mode, and `none` only while a complete-coverage capture is admitted.
  - `keylogger/init.lua:817` and the `flagsChanged` `modifier_press`/`modifier_hold` sites.
  - New `tests/unit/modules/keylogger/test_hs274_duplicate_count.lua` and `test_hs274_physical_collision.lua`, ported from `docs/audits/hammerspoon/2026_09_08/proofs/`. They drive the real `init.lua` keyDown path, not the stubbed classifier.
- **Depends on:** WP0.
- **Verify:**
  - `npm run test:hs`. The stream-mode duplicate test passes, and the collision test keeps physical Space at 1.
  - Ledger mode pins today's behaviour, with the documented HS-274 double count explicitly asserted.
  - A mutation that restores `and nil or keycode` in stream mode must fail.
- **Effort:** 1 day. **Risk:** low. Default behaviour is byte-identical; only an unused branch is added.

### WP2: HID usage in the shared registry and a key-identity policy [L]

- **Goal:** attribute credits exactly on real keyboards.
- **Files:**
  - `_shared/data/keycodes/physical_keys.json`: add a `hid_usage` field (page 7) to every key.
  - The registry owner and generator, then regenerate.
  - `tools/test/test-physical-keys-registry.cjs`.
  - `physical_delivery.lua:101-105`: replace "retire the whole capture on the first unmapped usage" with an explicit uncounted-usage tally reported in coverage.
  - Per-device keyboard type in `physical_baseline.lua` rows.
  - An explicit policy for the fn/globe key (Apple vendor top-case page) and the consumer page.
- **Depends on:** WP0.
- **Verify:**
  - `npm run test:js` checks that the mapping is total and unique, and that ISO 0x35/0x64 are correct.
  - `npm run test:hs` runs ISO and ANSI delivery tests.
- **Effort:** 1.5 days. **Risk:** low, because it is dormant.

### WP3: Production consumer owner, persistence and context [L]

- **Goal:** a production capture owner to replace `tools/diagnostics/hs274-hammerspoon.lua`, kept dormant behind a flag.
- **Files:**
  - New `modules/keylogger/physical_capture.lua` with:
    - a single init owner and paired lifecycle logs;
    - an entry in the controlled-termination list next to `keylogger` in `init.lua`;
    - asynchronous startup: clock, then prepare, status and open;
    - a bounded restart policy after `lost` or `interrupted`;
    - an explicit `unavailable(reason)` state;
    - admission of only the new complete-coverage value, and refusal of `fixture_only`.
  - Before starting the CLI, check the executable's identity asynchronously with `codesign --verify -R=<Ergopti leaf requirement>`.
  - Persist credits through `LogManager.log_system_event` as `physical_press`, and add a new `physical_release` whose `hold_ms` comes from HID timestamps. Add a matching aggregator `kc_hold` branch.
  - Production context owner, replacing `tools/diagnostics/hs274-context.lua`. It:
    - reads the real CoreState filters and `disabled_apps`;
    - records enable, pause and filter changes, and wake and wall-clock changes;
    - prunes its history through periodic lease rotation.
- **Depends on:** WP1, WP2.
- **Verify:** `npm run test:hs`, with native doubles, covering:
  - startup ordering, and stop requested during spawn;
  - successor fencing, and restart after `lost/interrupted`;
  - late-delivered pause, privacy and disabled-app intervals, and sleep/wake with a stubbed timebase;
  - an emit → append_log → SQLite → rebuild replay round trip that yields the same `kc_ngram` and `kc_hold`;
  - a `hold_ms` test that fails if delivery time is used instead of HID time.
- **Effort:** 5 days. **Risk:** low while `physical_source = "ledger"`. A boot test shows that nothing is required or spawned when the flag is off.

### WP4: Headless runtime fork patch set [L for Python and portable C++; H for the build]

- **Goal:** turn the 16.3.0 (9312593e) producer into a background runtime Ergopti can own. It contains only `Karabiner-Core-Service` (daemon and agent modes), `Karabiner-Console-User-Server` and `karabiner_cli`.
- **Files:** new `tools/build/remap_runtime_patch.py`, in the same exact-anchor style as `hs274_raw_patch.py`, plus tests. It covers:
  - **Namespace relocation:** the tmp and rootonly directories, the sockets (checked against the 103-byte limit), logs, system config directory, bundle ids, display names and machine-id file, under `/Library/Application Support/ErgoptiPlus/…`.
  - **No stock-app calls:** remove `register_core_agents`/`unregister_core_agents` and the stock ServiceManager paths, and point the agent's `permission-check` at its own bundle.
  - **Peer authorization:** replace `same_team_id` "unsigned → true" with a designated-requirement check pinned to the Ergopti certificate leaf. It must fail closed for both `hs274_capture` and `set_variables`.
  - **Owner watch:** a `--owner-pid` option on the console user server that exits when that pid exits (kqueue `NOTE_EXIT`).
  - **Diagnostics out of release builds:** move the fixture-only code (`HS274 CI Keyboard`, the finite mirror, the shutdown dump) behind a diagnostic build flag.
  - **Real coverage:** a complete-coverage value, advertised only when the inventory proves every keyboard and consumer interface is ready.
- **Depends on:** WP0.
- **Verify:**
  - [L] `python3` anchor tests, which must refuse any upstream drift.
  - [L] `g++ -std=c++17` for `hs274-raw-capture-test.cpp` and `hs274-stream-session-test.cpp`, which need no vendor headers, plus a new portable test of the authorization predicate.
  - [H] `hs274-producer-build.yml` dispatched from a feature branch with `raw_capture=true`, `stream_capture=true`, `complete_package=false`, and a new `headless_runtime=true`.
- **Effort:** 6-8 days. **Risk:** none to production, which is untouched. The real risk is fork maintenance: every upstream bump means re-anchoring about 9 or more files.

### WP5: Reproducible, durable runtime artifact [H]

- **Goal:** replace the 7-day ad hoc artifacts with a signed, pinned release asset.
- **Files:**
  - New `.github/workflows/remap-runtime-build.yml`, derived from `hs274-producer-build.yml`: dispatch-only, signed with the stable self-signed identity, publishing a GitHub release asset with its SHA-256.
  - New `static/ergopti_plus/macos/vendor/remap-runtime/manifest.json`, pinning:
    - the runtime tarball;
    - the pqrs VirtualHIDDevice v8.5.0 pkg (sha `d73d6d94…`, team G43BCU2T37, matching submodule `bdfcb459`).
  - Repin `hs274-native.yml:123-135` to the new asset.
  - Retire the `complete_package` and `install_candidate` paths through the `retire-artifact` skill, keeping the verification helpers. Stop using `karabiner_candidate.py`'s 10-product list.
- **Depends on:** WP4.
- **Verify:**
  - [H] `codesign -d -r-` on every binary shows the Ergopti leaf requirement.
  - [H] A fresh `hs274-native` dispatch fetches the asset and passes the checksum step.
  - [L] Python tests pin exactly 3 products and no `/Applications` payload.
- **Effort:** 2-3 days. **Risk:** none to production.

### WP6: Install, activation, launchd ownership, uninstall and coexistence detection [L for Lua and state machine; H for native]

- **Goal:** one admin prompt that installs the pqrs VirtualHIDDevice pkg and the runtime, then an explicit owner.
- **Install step, in a single hash-verified script:**
  - Check the pkg signature with `pkgutil --check-signature`.
  - Copy the runtime to root-owned `/Library/Application Support/ErgoptiPlus/Runtime`. Root binaries must never run from the user-writable app bundle, which would be a privilege-escalation path.
  - Remove quarantine only after the codesign requirement check passes.
  - Write LaunchDaemons `com.ergoptiplus.runtime.vhid` (running the pqrs-signed daemon binary) and `com.ergoptiplus.runtime.core`. The daemon stays idle until a console peer connects.
- **User-side processes:** the console user server and core agent are started by the owner with `XDG_CONFIG_HOME` set and `--owner-pid`. They are never RunAtLoad.
- **Activation:** call the hidden manager's `activate`, then poll `systemextensionsctl` for `[activated enabled]` without trusting its exit code.
- **Files:**
  - New `platform/remap/runtime_owner.lua`.
  - `onboarding.lua`: a health check per runtime mode, so owned mode no longer requires `/Applications/Karabiner-Elements.app`.
  - `ke_paths.lua` becomes runtime-selected.
  - `UninstallWorker.swift`.
  - `RemapLeaseWorker.swift:62`: accept the owned CLI path for the selected runtime only.
  - The rewritten `tests/meta/test_karabiner_stock_process_isolation.lua` and `tests/support/karabiner_isolation/syntax.lua`. They allow exactly the Ergopti-labelled runtime and still reject any control of stock `/Library/Application Support/org.pqrs/Karabiner-Elements` processes.
- **Coexistence:** if official Karabiner-Elements is installed or running, or another VirtualHIDDevice version is active, the owned mode reports an explicit, named `unavailable` state and Ergopti stays in shared mode. Final policy is Q1 in section 6.
- **Depends on:** WP5.
- **Verify:**
  - [L] `npm run test:hs` for the onboarding state machine: absent, installed-pending, waiting-approval, enabled, foreign Karabiner installed, foreign Karabiner running.
  - [H] XCTest in `ci-macos.yml`.
  - [H] `hs274-native` with a new `owned_runtime=true` and a `coexistence` input of `none`, `ke_idle` or `ke_running`. It asserts:
    - `/Applications` has no `Karabiner-Elements.app`;
    - only Ergopti launchd labels are loaded;
    - the user's `~/.config/karabiner` hash is unchanged;
    - install → uninstall leaves no Ergopti jobs;
    - the SMAppService daemon status is read with a per-run identity from `create_macos_signing_identity.sh`.
- **Effort:** 5-6 days. **Risk:** medium, confined to the opt-in mode. Shared mode keeps its code path, and a test pins shared-mode onboarding.

### WP7: Configuration owned by Ergopti, and re-verified semantics [L, then H]

- **Goal:** in owned mode, the generator writes a _complete_ `karabiner.json` under `~/Library/Application Support/ErgoptiPlus/karabiner/`.
  - No merge into `~/.config`, no personal-rule surgery, no `open_gui`.
  - `ke_variables` and the lease use the owned CLI.
  - The ledger `shell_command`s are still emitted until WP10, because the owned console server runs them.
- **Also:** diff upstream `src/share/manipulator` between v16.0.0 and 9312593e, and update `tests/support/karabiner_model.lua`. Memory's v16 rule semantics were read from 16.0.0.
- **Files:** `platform/remap/{init,generator,ke_variables,ke_lifecycle,ke_paths}.lua`, `tests/support/karabiner_model.lua`.
- **Depends on:** WP6.
- **Verify:**
  - [L] Generator golden output for shared mode is byte-identical to before.
  - [L] Owned mode writes only to the owned path.
  - [H] The remap fixture loads the generator's _real_ output on the owned runtime and checks tap-hold, combo and nav-layer outputs.
- **Effort:** 3-4 days. **Risk:** medium, in owned mode only.

### WP8: Native acceptance that can turn green, and cost measurement [H]

- **Goal:** a real gate for the delivered feature.
- **Changes:**
  - Split the permanently red Quartz serialization and Launch Services probes into their own non-gating job.
  - Allow dispatch on integration refs.
  - First diagnose run 34883676362 from artifact 10364596082, then re-run `repeat_fixture=true`.
  - New scenarios:
    - `production_consumer=true`, which runs the WP3 module instead of the diagnostics harness;
    - `two_keyboards=true`, using the runner's own Virtual USB Keyboard plus the fixture;
    - hotplug in the middle of a lease;
    - an ISO descriptor, if the provider accepts one;
    - upgrade N → N+1 with the same identity, checking TCC and designated-requirement persistence.
  - Run the matrix on `macos-15`, `macos-15-intel` and `macos-26`.
  - Measure cost with and without the stream, paired and reversed, following the `perf-profiling` skill, and file it under `docs/audits/performance/hammerspoon/<date>/`.
  - Run the Python and portable C++ replay tests in mainline `ci.yml` on Ubuntu.
- **Depends on:** WP3, WP7.
- **Verify:**
  - The job goes green.
  - Deleting one credit in the consumer turns it red.
  - The production aggregator records `{53:1, 49:1}` for the Escape→Space fixture plus a passthrough Space.
- **Effort:** 5-7 days, dominated by runs of about 4 minutes each. **Risk:** none to production.

### WP9: Real-Mac acceptance [M]

- **Goal:** sign off a hardware checklist.
  - Clean install; system extension approval once; Input Monitoring and Accessibility; entries in Login Items/Ouverture.
  - Apple internal keyboard including fn/globe; an ISO or ANSI external keyboard; Bluetooth; two keyboards at once.
  - A real autorepeat hold; sleep/wake; Hammerspoon reload and crash, where the keyboard must return to native input; uninstall.
  - The coexistence behaviour with the maintainer's own Karabiner-Elements, if any.
- **Depends on:** WP8. **Effort:** 1-2 days of maintainer time. **Risk:** done on an opt-in machine.

### WP10: Enable and retire [L, then H]

- **Goal:** follow the rollout in section 5, then remove the old path.
  - Remove the ledger `shell_command`s (`generator.lua:877,883,930-931`; the swallower keeps an empty `to`).
  - Remove `kc_bridge`'s always-on init, the managed-output classifier, and its 11 lease clear sites in `remap/init.lua`.
  - Keep legacy detection at `generator.lua:2521-2530`.
  - Migrate `karabiner_kc.log`.
  - Retire memory `project-hs-kc-ledger-process-lifecycle`.
  - Stop offering the Karabiner-Elements DMG to new installs.
  - Add a dashboard note on the semantic change: physical presses rather than outputs, with no autorepeat.
- **Depends on:** WP9 and Q4 in section 6.
- **Verify:**
  - A generator test finds no `karabiner_kc.log` in new output.
  - The legacy-migration tests stay green.
  - A boot test shows that no path watcher is armed.
- **Effort:** 2-3 days. **Risk:** medium, so it lands only after the stream has been the default for one release.

**Order:** WP0 → (WP1 ∥ WP2 ∥ WP4) → WP3 and WP5 → WP6 → WP7 → WP8 → WP9 → WP10. WP0-WP4 can be implemented and proven here and in CI. **Total:** about 32-42 agent-days plus maintainer hardware time.

---

## 4. What must not be done

| Rejected path                                                                                                                                 | Why                                                                                                                                                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Global suppression of managed output keycodes (the one-line fix to `init.lua:817`)                                                            | It loses real Space, Return and Backspace, which the shipped defaults make collide. It passed 9,528 tests and was still harmful.                                               |
| Attributing origin by timing, order, PID, `user_data`, field 87, sender identity or counters                                                  | Real runs produced identical fields for remapped Escape and physical Space.                                                                                                    |
| EventViewer capture; a leading `from.any`/`to.from_event` rule or a trailing one; `send_user_command` datagrams; a shell command on every key | Each one either disables remapping, misses consumed events, or lacks identity, coverage and an acknowledgement. The per-key shell command also adds an unmeasured typing cost. |
| A passive parallel IOHID observer, or forcing Karabiner's Quartz fallback                                                                     | Seizure invalidates other clients, and the fallback loses per-device state.                                                                                                    |
| Ergopti's own DriverKit extension or `IOHIDUserDevice`                                                                                        | It needs Apple entitlements and is refused even as root.                                                                                                                       |
| Shipping the 10-product "complete candidate", installing over the user's Karabiner-Elements, or keeping the Karabiner-Elements UI or Updater  | Contradicts the 2026-09-29 decision and R3. The Updater could also replace the fork with official binaries.                                                                    |
| Removing IPC authentication, mixing fork and stock peers, or relying on `same_team_id` in a self-signed fork                                  | Stock clients reject the fork daemon. Unsigned-means-trusted opens a keystroke stream to any process of the console user.                                                      |
| A silent fallback to Quartz `meta.kc` when the stream is lost, or mixing ledger and stream credits                                            | It brings HS-274 back and hides the coverage loss. Record explicit gap records instead.                                                                                        |
| Running root runtime binaries from inside `/Applications/ErgoptiPlus.app`                                                                     | That location is user-writable, so it becomes a local privilege escalation.                                                                                                    |
| Reusing the Linux kanata generator or owner                                                                                                   | They were deleted on 2026-09-24, produced an unloadable config, and memory forbids reintroducing an external remapper.                                                         |
| AXPress, keeping the requester alive, or longer polling to approve the extension                                                              | Each was tested and left the extension waiting. Only the disposable-runner admin plus click worked.                                                                            |
| Treating the virtual fixture as hardware proof, or reading the always-red hs274 conclusion or one green step as acceptance                    | Receipts keep `physical_keyboard_validated=false`, and the permanently failing probes hide real regressions.                                                                   |

---

## 5. Recommended architecture and rollout

**Recommendation: a custom headless Karabiner core owned by Ergopti.** It is the pqrs-signed standalone VirtualHIDDevice v8.5.0, unmodified, plus an Ergopti-built and Ergopti-signed 3-product fork of Karabiner-Elements 16.3.0 with the HS-274 stream.

| Criterion                     | Headless Karabiner fork                                                                                                                    | kanata on VirtualHIDDevice                                                                                                                                                                                                                                                                                  |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Physical-accounting exactness | The stream already exists, with device, cookie, HID timestamp, baseline and gap semantics. About 12 native runs were green.                | kanata sees raw keys but does not export them: its TCP protocol has no key event. You would need a kanata (Rust) fork, or a `push-msg` on every key, which changes key behaviour and is unproven inside tap-hold. Cookie and device provenance would be lost.                                               |
| Reuse                         | Generator (3029 lines), `karabiner_model.lua`, lease and variables IPC, F17/F20 sentinels, the Lua consumer and the fixtures are all kept. | None. The Linux kanata code is deleted. Tap-hold, the 35 `simultaneous` uses, exact-modifier splits, held-modifier semantics and the lease variables would all have to be rewritten and re-proven. The N×N modifier-combo matrix is documented as something kanata cannot express (`ERGOPTI_PLUS.md:1009`). |
| Effort                        | About 32-42 days in total.                                                                                                                 | About 50-70 days, plus a fork.                                                                                                                                                                                                                                                                              |
| Approvals and operations      | Root, Input Monitoring, extension approval, one admin prompt.                                                                              | The same: root, Input Monitoring plus Accessibility, the extension, a hand-written VirtualHIDDevice LaunchDaemon, and a VirtualHIDDevice major-version pin (v8.0.0 for kanata ≥1.13).                                                                                                                       |
| Risk                          | Upstream rebase cadence.                                                                                                                   | Behaviour changes on every key for every user, and a remapper already retired on Linux for brittleness.                                                                                                                                                                                                     |
| Advantage                     | Proven path.                                                                                                                               | Headless by design, and a smaller fork.                                                                                                                                                                                                                                                                     |

An in-house root seize-and-post helper, like the Linux in-daemon engine, is the largest effort of all and is not recommended now.

The fork also gives a fail-safe that kanata does not: if the console-user-server peer dies, the daemon ungrabs (`receiver.hpp:201-206`). With `--owner-pid`, an Ergopti crash therefore returns the keyboard to native input with no guardian heartbeat.

**Flags and rollout.** Every flag defaults to today's behaviour and uses key names that no old build ever wrote (lesson from `c628a35f`).

- `config_karabiner.toml`: `[karabiner] runtime = "shared" | "owned"`, default `shared`. This keeps today's official 16.0.0 install, the shared `karabiner.json` and the lease guardian.
- The metrics manifest, via `npm run build:manifest`: `[metrics] physical_source = "ledger" | "stream"`, default `ledger`.
  - `stream` requires `runtime = "owned"` and an admitted complete coverage; otherwise the state is explicitly `unavailable`.
  - While it is `stream`, the generator stops emitting ledger events and Quartz credits no `kc`. Losing the stream produces gap records and a bounded restart, never a mixture with the ledger.

**Stages:**

- **S0:** all code dormant. CI proves shared-mode generator output and boot are byte-identical.
- **S1:** `runtime = owned` on the maintainer's Mac with the ledger still on. The owned console server runs the same shell commands.
- **S2:** `physical_source = stream` opt-in.
- **S3:** `owned` plus `stream` become the default for new installs without a foreign Karabiner-Elements. Existing users are offered migration, with an uninstall of the Karabiner-Elements that Ergopti installed, and only with consent.
- **S4:** after one release, WP10 retires the ledger. Retiring shared mode is a separate decision.

---

## 6. Questions for the maintainer

1. **Coexistence.** When a user already has their own Karabiner-Elements installed or running, which should Ergopti do: (a) keep that user on shared mode, so owned mode reports "unavailable: your Karabiner-Elements is active" (recommended); (b) require them to uninstall it; or (c) take over with explicit consent? The same question applies to VirtualHIDDevice version skew, since only one version can be active system-wide.
2. **Branding and Apple Developer ID.** Is the residual pqrs VirtualHIDDevice branding acceptable (hidden manager app, notification, Driver Extensions entry)? Would you get an Apple Developer ID? It would allow notarization and `SMAppService.daemon`, and remove the Gatekeeper and "unidentified developer" friction.
3. **Fork ownership.** Will you own a fork of Karabiner-Elements 16.3.0 (9312593e) and its re-anchoring on each upstream bump? Owned mode's generator semantics would then move from 16.0.0 to 16.3.0, while shared mode stays on 16.0.0 until it is retired.
4. **Metrics semantics.** Should the heatmap become physical-only once `stream` is on: no autorepeat, and nav-layer letters rather than arrows, with a note on history? Should metrics-only users with remapping off still run the owned core just to capture?
5. **Hardware and scope.** Which real Mac and keyboards are available for WP9 (Apple internal with fn/globe, ISO or ANSI external, Bluetooth, two at once)? Should the fn/globe and media (consumer) keys be counted or explicitly left uncounted?
