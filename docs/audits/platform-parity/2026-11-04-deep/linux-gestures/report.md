# Deep audit: Linux × touchpad gestures

Audited commit: **89b0b774c8c960c7ad458ac3cb98d5c97598e518**. Date: 2026-11-04 UTC. Scope: actual evdev source, decoding/recognition, slot selection, configuration, action dispatch/parameters/confirmation and pause/reload/device loss/desktop overlap. No repository files changed. Prior hotstrings and LLM reports are preserved separately.

Two new actionable issues were confirmed at source/model boundaries. No real touchpad, input capture, uinput injection, native desktop, shell action or display server was driven by the audit probe. All action output in the probe goes through a recording emitter. “Kernel-filtered” below means the repository's existing executable Linux input-core model, not a real kernel/device run.

## Confirmed findings

### LG-001 — Linux advertises and accepts three horizontal-axis slots that its recognizer cannot produce

Severity: **medium**. Confidence: **high**. Guarantees: G1 truthful configuration, G2 missing feature output.

`swipe_3_horiz`, `swipe_4_horiz`, and `swipe_5_horiz` are declared as Linux features and appear as editable gesture bindings. A user can assign an ordinary runnable action to them; the hardware-reachability helper says they are reachable on a five-finger pad. No actual Linux gesture can select those slots. A horizontal swipe selects only `swipe_N_left` or `swipe_N_right`.

Exact evidence, paths relative to `static/ergopti_plus/`:

- `_shared/modules/features/manifest.toml:3287`, `:3344`, `:3401` declare the three horizontal aggregators for `hs,linux`.
- `_shared/modules/actions/actions.toml:105` declares the axis-slot names; `:116` explicitly documents that **only macOS dispatches an axis**, while Linux emits finished direction swipes. Thus the native capability difference is already documented; the false Linux surface/declaration is the new defect, rather than an invented requirement to implement continuous gestures everywhere.
- `linux/modules/gestures/manager.lua:291` copies every axis slot into `DEFAULT_GESTURES`; `:1235` (`M.set_action`) accepts and publishes a valid action for it.
- `linux/ui/menu/menu_gestures.lua:114` enumerates every `DEFAULT_GESTURES` key and presents a normal assignment menu at `:167`–`:180`. Its only hardware gate is finger-count reachability.
- `linux/modules/gestures/slot_report.lua:25` (`slot_is_reachable`) checks the digit count and does not distinguish missing axis recognition.
- `linux/modules/gestures/mt_decoder.lua:268` classifies only named directions; completed events at `:435` carry a direction/tap.
- `linux/modules/gestures/manager.lua:1918` (`_slot_for_gesture`) produces `tap_N` or `swipe_N_<direction>`. `M.dispatch_gesture :1952` never checks a horizontal aggregator or an axis fallback.
- Generated `docs/feature-inventory.md:55` consequently reports `gestures.swipe_3_horiz` as declared on macOS/Linux. The generator faithfully copies a false declaration; the source and runtime contract must be corrected, not the generated page alone.

Reproduction: the real manager accepts `tab_next` on each axis slot; the real decoder processes a completed horizontal gesture using the repository's existing event fixture. It emits `right`; dispatch returns false because the corresponding directional slot is unbound. A control binding on `swipe_3_right` dispatches and reaches the recording emitter once. Exact output:

```text
AXIS swipe_3_horiz assign=tab_next reachable=true decoded=right fired=false
AXIS swipe_4_horiz assign=tab_next reachable=true decoded=right fired=false
AXIS swipe_5_horiz assign=tab_next reachable=true decoded=right fired=false
DIRECTION_CONTROL emissions=1
```

Silent failure: the user can configure a binding successfully but it never fires. No unreachable-slot warning is produced on sufficient-finger hardware.

Regression test: enumerate every advertised Linux gesture slot and prove a real recognizer/dispatcher route exists, with explicit unsupported slots/reasons rather than assigning availability from the shared key-space. Include a horizontal gesture with only the aggregator bound, plus directional positive controls. Mark these three axis bindings unavailable on Linux unless an intentional supported recognizer route is added; preserve the explicit left/right alternatives in the website matrix.

### LG-002 — Clearing MT coordinate registers on contact lift drops valid subsequent gestures

Severity: **medium**. Confidence: **high** for the source/model defect; **native device behavior unverified**. Guarantees: G1 protocol robustness, G2 missing gesture output.

Two consecutive valid horizontal swipes on the same slot rows need not repeat their Y coordinates in the evdev stream. The Linux input core retains absolute MT axis values per slot and suppresses unchanged values, including across a tracking-ID release/new contact. The decoder erases those stored coordinates on release and at every gesture completion. It then requires both X and Y before including a contact in its centroid. A second horizontal swipe at unchanged Y can therefore disappear entirely. Vertical motion can suffer the symmetric unchanged-X case.

Root cause and exact evidence:

- `linux/modules/gestures/mt_decoder.lua:295` (`decoder:feed`) updates the tracking ID, then at `:299` clears both `slot.x` and `slot.y` when the contact ends.
- `mt_decoder.lua:220` (`reset`) discards the whole `_slots` map and resets the current slot register to zero at `:221`–`:222`.
- Completion calls that reset at `mt_decoder.lua:413` before returning its gesture. Protocol registers and per-gesture accumulation are incorrectly given the same lifetime.
- `mt_decoder.lua:241` (`centroid`) admits a contact only if its ID and **both** coordinates exist (`:244`). With no Y report after the reset, movement never starts tracking a usable centroid.
- `linux/tests/support/input_core_emulation.lua:42`–`:55` is the repository's existing kernel model: axes are retained per slot, unchanged values are dropped, and there is no coordinate reset when `ABS_MT_TRACKING_ID` changes. The source header explicitly describes this filtering as the Linux input-core contract. The new probe reuses that exact constructor, rather than inventing its own different filter.
- The production manager creates one decoder at `manager.lua:2055` and retains it through successive gestures in `M.pump :2070`. This is precisely the persistent lifetime reproduced by the probe.

Reproduction and refutation control: send two identical three-finger horizontal swipes through the existing input-core model into one real decoder. The first swipe supplies three initial Y values and produces one gesture. The second supplies **zero** Y values and produces zero gestures. Repeat the experiment with the second gesture shifted down by 10 device units: the second now supplies three Y values and produces one gesture. Exact output:

```text
KERNEL_FILTERED_REPEAT second_y_offset=0 repetition=1 y_reports=3 gestures=1
KERNEL_FILTERED_REPEAT second_y_offset=0 repetition=2 y_reports=0 gestures=0
KERNEL_FILTERED_REPEAT second_y_offset=10 repetition=1 y_reports=3 gestures=1
KERNEL_FILTERED_REPEAT second_y_offset=10 repetition=2 y_reports=3 gestures=1
```

The changed-Y positive control rules out a generally invalid second gesture, a disabled manager, an unstable finger count, or a permanent decoder failure. Fresh contact identity does not imply a full coordinate snapshot: type-B ABS MT slot state is stateful, and the kernel filtering layer can suppress unchanged coordinates. The model evidence is strong for the protocol join, but no claim is made about frequency on real pads, sensor jitter or a particular firmware. A raw fixture that repeats unchanged X/Y fields bypasses the condition and stays green.

Silent failure: no gesture is returned and no warning identifies missing protocol registers. The binding itself remains enabled and valid.

Regression test: preserve one real decoder over multiple gestures passed through the existing input-core model; cover unchanged Y, unchanged X, stationary taps, reused slots, nonzero current-slot register, and a changed-coordinate control. Separate persistent kernel slot/axis registers from gesture accumulators. Initial startup and `SYN_DROPPED` require their own state-recovery policy; retaining known registers during an ordinary lift is not permission to trust state after a queue loss.

## Two-pass coverage and refutations

Pass 1 followed the production pipeline from device selection and the daemon pump through decoding, slot lookup and actions. Pass 2 tested false availability and successive-gesture protocol ownership, examined alternate menu/axis paths, challenged tap and lifecycle hypotheses, and ran focused existing tests. This is bounded module coverage, not proof that every hardware, compositor or timing interleaving is exhausted.

| Surface                     | Evidence/check                                                                                                 | Result                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Actual source               | `touchpad_finder` reads device capabilities; manager opens `evdev_reader.TOUCHPAD` without a grab              | Source traced; the obsolete libinput-scraping comment is not treated as implementation |
| Device selection            | Capability bitmap, MT slots, pointer/buttonpad properties, semi-MT flag, maximum finger count, ranking         | 14 finder cases passed; no real device discovery/open                                  |
| Kernel packet decoding      | evdev reader input-event boundary, SYN frames, persistent MT selection register                                | Source traced and decoder tests passed                                                 |
| Finger count                | Peak held over stable frames, late joins refused, six-or-more unknown count not treated as lift                | 38 decoder cases passed                                                                |
| Motion and direction        | Shared Manhattan threshold/diagonal sectors; Y downward; only peak contacts travel                             | 69 cross-driver direction cases passed                                                 |
| Taps/rests                  | Shared tap maximum and kernel timestamp use                                                                    | Existing cases passed; out-and-back semantic question retained below                   |
| Repeated gestures           | Stateful input-core filter + same real decoder, unchanged-axis and changed-Y control                           | New LG-002 reproduced                                                                  |
| Lost queue                  | `SYN_DROPPED` resets and drops through next `SYN_REPORT`                                                       | Existing decoder cases passed; native state-requery behavior not established           |
| Slot identity               | Shared slot-space, manager name construction, three axis declarations                                          | New LG-001 reproduced                                                                  |
| Hardware reachability       | Count-based `slot_report` and disabled menu reasons                                                            | 8 cases passed; recognizer capability is missing from that gate (LG-001)               |
| Config and durable mutation | Canonical `[gestures]`, legacy read routing, source/identity guards, staged binding/parameter writes           | 10 transaction + 96 parameter-binding cases passed                                     |
| Enable transaction          | Reader-open ACK before enabled publication, rollback on persistence/native refusal                             | 6 enable cases passed                                                                  |
| Binding parameters          | Shared action catalogue, exact `<binding>__<action>` identity and validation before provider handler           | Source traced and parameter cases passed                                               |
| Basic action dispatch       | Generated combo map, retained combo emitter, explicit X11 fallback certification                               | Probe uses recording emitter; no actual output emitted                                 |
| Action confirmation         | Catalogue confirm flag, command targets captured before confirmation, question before command                  | 21 system-action cases passed against recorded shell/stub tools                        |
| Session/tool restrictions   | Action picker checks declared tool/X11/workspace/AI requirements and reasons                                   | Source traced; no compositor availability promised                                     |
| Workspace behavior          | X11/KWin/sway/Hyprland; plain-vs-wrap shared policy; bounded tool commands/fallback                            | 14 workspace cases passed against scripted sessions                                    |
| Pause                       | Physical gesture dispatch admits only script-control actions while paused; pump releases synthetic click holds | Source traced and click-retirement cases passed                                        |
| Disable / stop / reload     | Reader close ACK; pending close debt retained; decoder dropped on confirmed retirement                         | 10 close-ACK + 27 click-retirement cases passed                                        |
| Device loss / hotplug       | Fatal/closed drain stops reader and explicitly asks for re-enable; no automatic redetection loop               | Source traced, observed limitation documented below                                    |
| Desktop/system overlap      | Unshared grab, default-none policy, conflict groups/status/dismissal and explicit settings opening             | 37 conflict cases passed; no portable query of real compositor policy claimed          |
| Existing single-source gate | `test-gesture-slots-single-source.cjs`                                                                         | Passed; establishes common **names**, not Linux recognizer reachability                |

Refutations / unpromoted hypotheses:

- **“Linux only supports libinput's small gesture set” is false.** The actual code reads MT evdev records itself and can decode counts/taps up to five when hardware reports them. No external libinput process feeds the current production manager.
- **“Linux supports all 39 declared slots because the name gate passes” is false.** The three axis slots have no native feed (LG-001). There are 36 discrete declared single slots before per-device restrictions; declaration alone does not prove any is live on a particular pad.
- **No blanket “Wayland has no gesture actions.”** Generated uinput chords sit below the compositor; application-window manipulation is session restricted, while KWin/sway/Hyprland have selected workspace interfaces. GNOME Wayland does not supply the same wrap/query interface.
- **Wide out-and-back movement currently becomes a tap when net displacement returns to zero.** The probe prints `EXPLORATORY_NET_TRAVEL tap=true`. This is real decoder behavior, but the canonical product contract for a returned-to-origin gesture was not established; macOS also reasons about residual displacement/live firing. It is not promoted to a confirmed defect without a settled tap-vs-excursion rule.
- **Stationary contact frame count is a real hardware/protocol constraint.** Stable-frame admission cannot assume unchanged packets are delivered; the repository already has an explicit still-tap input-core test. That known issue is not newly counted. LG-002 is separate: it loses the unchanged coordinate register even when the second moving gesture supplies sufficient changing frames.
- **No unmeasured latency finding.** Several actions call bounded external tools and the reader pumps with the keyboard, but no measured stall is asserted.
- **Dispatch-test seam warning.** `tests/unit/modules/gestures/engine/test_gesture_dispatch.lua:47` assigns `_test_execute`, but production manager has no reference to that field. The file's stated recording-executor assumption does not establish isolation; it was not run here because actual gesture actions such as lock_screen could be reached. This is a coverage limitation/test review target, not a separately claimed user-facing parity bug.

## Intentional differences, current constraints and OS equivalents

| Difference                              | Classification / actual basis                                                                                                                       | User-visible effect and equivalent                                                                                                                                                                                                                                                                                                                                                                                        |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux ships no default gesture bindings | **Explicit maintainer decision**, `manager.lua:243`–`:256`, dated 2026-08-05; no touchpad grab because it would take the cursor from the compositor | Fresh Linux install leaves gestures unbound to avoid duplicate desktop actions. Windows/macOS have their native recommended sets; matching defaults would violate the Linux decision.                                                                                                                                                                                                                                     |
| Shared touches / compositor overlap     | **Native constraint and explicit architecture**, manager header and conflict UI                                                                     | Linux desktop scrolling/swipes can run alongside the configured action. Conflict status says unknown/potential overlap rather than claiming clean isolation. macOS uses its native gesture/scroll conflict machinery; Windows routes Precision Touchpad shortcuts configured for the driver.                                                                                                                              |
| Recognition vocabulary                  | **Explicit implementation/native constraint**, shared action catalogue comment `actions.toml:116`                                                   | Windows receives ten Precision Touchpad hotkey slots (three/four-finger taps and cardinal swipes). Linux decodes discrete two-through-five-finger taps/eight-direction swipes if the pad reports them. macOS has continuous axis input as well. Three Linux axis declarations are erroneous (LG-001), not evidence of support.                                                                                            |
| Modes and sensitivity/steps             | **Explicit platform restriction**, manifest `:353`–`:361`, `gestures.modes`/`sensitivities` macOS only                                              | macOS supports x1/incremental modes and distance-based repeats. Linux fires one completed discrete gesture on lift; no incremental repeats or configurable macOS step grid. Windows also operates discrete Precision Touchpad events.                                                                                                                                                                                     |
| Gesture timing and raw units            | **Current implementation constraint; no specific maintainer decision proved**                                                                       | Linux uses device-unit threshold 120 (`mt_decoder.lua:111`) and production `Decoder.new()` receives no per-device resolution (`manager.lua:2055`). The comment claiming an adapter scales it is not backed by that path. Physical distance therefore varies with device resolution. macOS's native geometry/configuration differs. Not promoted into a new behavioral defect without a canonical calibration requirement. |
| Hardware finger count and semi-MT       | **Hardware constraint**, finder capability bits and `slot_report`                                                                                   | A pad reporting only three fingers cannot fire four/five-finger slots; menu greys them with a reason. Semi-MT is identified rather than rejected; full per-contact geometry is not guaranteed. Other OSes likewise depend on native device capabilities, not merely the catalogue.                                                                                                                                        |
| Hotplug / failed reader recovery        | **Observed implementation policy**, manager `pump :2082` logs “re-enable gestures to retry”; no explicit maintainer rationale found                 | Unplug/fatal read stops recognition; plugging back in does not automatically restart it. A user re-enables/restarts the reader. Do not describe this as equivalent automatic native hotplug recovery on the other OSes; that equivalence was not executed here.                                                                                                                                                           |
| Pause exception                         | **Explicit deliberate behavior**, manager `:1971`                                                                                                   | While paused, script-control gesture actions can still resume/control Ergopti; other gesture actions are held back. The reader remains alive. This is purposeful, not a missing pause guard.                                                                                                                                                                                                                              |
| Window/workspace actions                | **Session/compositor constraint**, catalogue requirements, workspace_switcher header                                                                | X11 supports wmctrl; supported Wayland desktops have specific interfaces. GNOME Wayland wrapping cannot query the edge, so wrap picker is disabled and plain fallback is explicit. Windows/macOS native workspace/window operations are separate equivalents, not proof of one universal Linux API.                                                                                                                       |
| Confirmation and tools                  | **Explicit action metadata and native integration choices**                                                                                         | Linux uses its own confirmation dialog and shell/native tools, captures window targets before asking, and checks parameter validity. Windows/macOS use their native action owners; no promise that tool installation, permissions or desktop integration match on every host.                                                                                                                                             |

Documentation caution: `docs/memory/linux-web-release.md:38` says the decoder refuses a scrolling pair as a swipe. Current `mt_decoder.lua:419` merely records the two-finger scroll end, then can return its direction at `:435`; bindings can therefore fire alongside desktop scrolling. The default-none/conflict warnings match that reality. Treat the older blanket refusal statement as stale, not an intentional absence of two-finger swipe recognition.

## Verification and boundaries

`python docs/audits/platform-parity/2026-11-04-deep/linux-gestures/run-tests.py`: **355 passed, 0 failed**, 13 focused existing modules. Per-module counts and captured logs are in `test-results.json` / adjacent `.log` files. Executed with real Lua 5.4.8 and the supplied lfs/luv modules; scenario boundaries remain scripted.

`node tools/test/test-gesture-slots-single-source.cjs`: passed. Its wording correctly establishes shared slot-space names; it cannot establish that each Linux slot has an input producer.

`probe.lua`: both confirmed defects and their positive controls pass as specified. Uses the real manager/decoder, real generated catalogue, an unchanged existing event-fixture constructor, and the unchanged existing input-core-model constructor. No fake executor seam that production does not read is relied upon; actual action output is replaced at the retained combo-emitter boundary.

Reproduce with:

```sh
PATH=/workspace/scratch/parity-toolchain/bin:$PATH \
LD_LIBRARY_PATH=/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu \
LUA_CPATH='/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;' \
/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua \
docs/audits/platform-parity/2026-11-04-deep/linux-gestures/probe.lua
```

No selected existing test module failed. Hardware `run_touchpad_capability` / `run_gesture_roundtrip` were not run, nor were a real device reader, compositor, uinput, action confirmation GUI or native Windows/macOS driver. Full suite/LuaJIT coverage and actual hardware frequency remain unavailable; the findings do not silently convert model evidence into a native desktop claim.
