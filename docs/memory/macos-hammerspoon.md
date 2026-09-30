<!-- docs/memory/macos-hammerspoon.md -->

# macOS and Hammerspoon memory

### published-startup-needs-real-dependencies

The launcher alert `Embedded Hammerspoon stopped unexpectedly with exit code 0`
can hide a Lua startup failure; inspect the managed Lua error log as well as
`~/Library/Logs/ergopti_plus/launcher.log`. The published v0.0.0-dev.126 archive
reproduced this on macOS in run `34865561172`: `log_transport` required LuaSocket,
but Hammerspoon 1.1.1 does not ship it. Injecting `bootstrap_socket_factory` in
unit fixtures cannot verify that distribution dependency. Test the extracted
archive with the real launcher and runtime, require completed onboarding or UI
startup, and keep watching both processes after the first log appears. The old
smoke test stopped at log creation and missed the subsequent abort; keeping an
`open -W` helper alive did not establish startup readiness.

### project-packaged-launch-gate-user-states

Three packaged-app launch failures escaped a green CI because every smoke
test started from a pristine runner: an arm64-only launcher, a legacy
`ConfigDirPath = "~/..."` in paths.toml (dev.108 to dev.117), and a
`hammerspoon/logs` folder that is a symbolic link (users version their config
in Git). The last one was an `O_NOFOLLOW` open of the final component in the
native log sink; Hammerspoon reports exit code 0 even after Lua `os.exit(1)`,
so the launcher could only say "stopped unexpectedly with exit code 0".
The `launch` job of `.github/workflows/ci-macos.yml` now runs
`tools/diagnostics/macos_launch_gate.py` on the archive that `package-macos`
built in the same run, installed over those user states. A run that does not
publish uses the `ci` profile on macos-15; a release run uses the `release`
profile on macos-15 and macos-15-intel, against the archive that ships. Either
way a failed launch fails the macOS lane, and `Release` needs that lane.
The launcher XCTest runs in `package-macos` before the app build and appends to
the real `~/Library/Logs/ErgoptiPlus/launcher.log`, while
`macos-release-launch.py` refuses to judge a launch over an existing launcher
log; that job therefore removes `~/Library/Logs/ErgoptiPlus` before building.
Any new step that runs launcher code on a runner that later launches the
packaged app must leave that folder absent as well.
Add a scenario to `SCENARIOS` there for every new launch failure that depends
on existing user state: `--print-matrix` derives both profiles from it, and
only `RELEASE_ONLY_SCENARIOS` stay out of the `ci` profile. Hosted runners
cannot grant Accessibility without interactive approval, so healthy scenarios
omit config.toml and complete at the first-run wizard; post-onboarding success
and the menu Quit row remain outside the gate. v0.0.0-dev.128 passed them all
and still vanished for a user with config.toml: the untrusted packaged runtime
(its own identity, never asked because onboarding was skipped) died at the
first eventtap, and the launcher took the exit status 0 after logger readiness
for a Quit. Never infer a clean exit from Hammerspoon's status: every fatal Lua
path writes `adapters/boot_fatal.lua`'s report, which the launcher turns into
a modal alert. `configured_symlink` now requires that named refusal, and
`plain_open` launches without `open -n`. Logs left the configuration folder
(2026-09): `symlink_logs` keeps a legacy linked `hammerspoon/logs` that must
stay untouched, `symlink_logs_dir` points LogsDirPath through a link and checks
the picked folder keeps its permissions, and `dangling_logs` is a LogsDirPath
link to nothing that must be refused by name. To see where a boot stopped, read
`~/Library/Logs/ergopti_plus/ErgoptiPlus_boot.log` (the default logs folder, beside
launcher.log; it was the shared `/tmp` root until 2026-09): every `Boot.stage`/`Boot.mark` pair is appended
there synchronously by `adapters/boot_journal.lua` (and to launcher.log until
the native logger commits); the last START without SUCCESS is the stage. Log folders are resolved once with
realpath and opened with `O_NOFOLLOW_ANY` (`OwnedLogDirectory.swift`); never
reintroduce a final-component-only no-follow check on a user folder.
A package built without `SPARKLE_PUBLIC_KEY` (empty `SUPublicEDKey`) opens a
Sparkle updater error at launch; while it is up, the launcher's blocks
dispatched to the main queue from its worker and exit-monitor queues did not
run in CI, so logger readiness, refusals and even child death went unobserved
(run 35661113100: the keyless package red, the keyed one green). Every package
the gate judges must embed the public key.

### project-macos-bundle-payload-is-declared

`Contents/Resources/static` holds only what
`tools/build/macos-bundle-manifest.json` declares, staged from tracked files by
`tools/build/macos-bundle-payload.cjs`, whose `stage` command refuses a local
build while an untracked, non-ignored file the payload would ship exists (git
add or ignore it first); `test-macos-bundle-payload.cjs` scans
the staged Lua, shell, JavaScript and HTML for every path they read. A file
whose name is joined at run time (the logos, the onboarding preview, the MLX
`pyproject.toml`/`uv.lock`) is invisible to that scan: add its reader to
`CURATED_READS`, never a `cp` into the static root. Karabiner-Elements is not
vendored: `platform/remap/onboarding.lua` downloads the pinned DMG, and the
49 MB installer the app carried until v0.0.0-dev.146 had no reader. Do not
strip `docs.json`/`lua.json` from the embedded Hammerspoon: `_coresetup.lua`
requires `hs.doc` at startup, which registers both files. Ollama is not
bundled either (the guard rejects `Tools/Ollama` in the build script).

### project-macos-ai-runtimes-install-on-selection

Neither AI runtime ships in the app or downloads at boot, on AI enable with
another backend, or after an update: only `install_for_selection()` of
`ollama_deps_checker`/`mlx_deps_checker` grants a download, its sole caller is
`ui/menu/menu_llm/runtime_install_offer.lua`, and any other check settles
`missing` without a task. An installed runtime is reused by stat alone
(Ollama: `ollama_binary.resolve()`; MLX: venv `bin/python` plus
`.last_sync_hash`), so a new `uv.lock` in an update never re-syncs the venv.
When the MLX import probe then fails on an installed venv,
`mlx_deps_checker.invalidate_runtime()` removes only `.last_sync_hash`: the
runtime reads as not installed and the next MLX selection runs the script's
full staged rebuild. Never re-sync from the probe itself.
The Ollama installer publishes the whole release archive (CLI plus the
ggml/MLX libraries it loads from its own folder, as in
`Ollama.app/Contents/Resources`) into the folder
`ollama_binary.managed_install_dir()` names; never copy the lone binary. Add a
new runtime trigger through the router, and extend
`test_ai_runtime_selection_install.lua` (`ai-runtime-*`).

## Native HID element qualification

### project-hs-hid-and-host-clock-units

HID timestamps are raw Mach ticks, while Hammerspoon 1.1.1 converts
`mach_absolute_time()` to integer nanoseconds using `mach_timebase_info` in
[its timer binding](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/timer/libtimer.m).
Query the native rational scale; never assume ticks equal nanoseconds or infer
the scale from architecture. Keep unsigned timestamp strings exact through
conversion, including multiplication intermediates. The repository scheduler
can offset samples after clock regressions or fallback transitions, so its
monotonic timeline is not the raw host clock domain. Matching clock domains
does not establish historical app/privacy context: app and AX callbacks record
observation time and may lag the underlying focus change.
Separate device queues can deliver older timestamps after newer ones. A committed
global stream sequence is not a timestamp watermark for discarding context
history. Retain the observations or retire capture explicitly on exhaustion;
never resolve a missing interval using the current application.

### project-hs-hid-array-leaf-public-count

Do not infer public HID getter results from kernel field names alone.
Apple's kernel converts array key children to one-bit, logical 0..1 leaves,
but retains the original report count in `rawReportCount`.
`IOHIDElementGetReportCount` returns that original count, so requiring a public
count of one rejects valid array-backed keys. Check `IOHIDElementIsArray`
alongside input type, relative flag, report size, logical bounds and usage.
See the pinned [public getter](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/hid.subproj/IOHIDElement.c)
and [kernel array conversion](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDElementPrivate.cpp).
The queue also includes array handlers with usage `UINT32_MAX` and inactive
keyboard error indicators. Preserve them as auxiliary records; an inactive
error is not a key press or evidence of lost coverage. Active errors must still
invalidate capture. A descriptor-qualified stream remains distinct from proven
device coverage and production consumer ownership.

## Lua and test isolation

### project-hs-unit-tests-echo-i18n-keys

`helpers.load_with_stubs` injects an `infra.i18n` stub whose `get` returns the
key, and a module captures that table when it loads. Comparing a label with
`i18n.get(key)` then compares two echoed keys. A test that must see real
translations points the captured stub's `get`/`format` at `infra.locale`
for its duration and restores them.

### project-lua-closure-before-local-nil-global

A closure only captures locals declared before its definition. A later `local`
with the same name leaves the closure bound to a nil global, and async wrappers
can hide the resulting error.

### project-lua-nil-and-expr-is-nil

Lua's `x and y or fallback` is not a nil-coalescing operator when `y` may be
false. Use an explicit nil check for booleans.

### project-hs-suite-order-contamination

Hammerspoon modules persist in `package.loaded`. Tests must restore globals and
reload stateful subjects, and each file must pass both alone and in the suite.
Fixtures using `helpers.load_with_stubs` need `helpers.with_stub_scope` around
construction and callback work: module-only restoration misses native aliases
and the loader's prefix sweeps. Its journal covers loader writes, not automatic
`require` publications; explicitly own real transitive consumers as well.
`with_fresh_modules` clears each named cache entry before the callback and
restores its exact nil/false/table value on exit. Reload native consumers that
captured `hs` at require time; use `rawequal` for identity checks to avoid
cyclic-table diagnostic expansion.

### project-the-macos-logger-ring-is-per-process

The shared logger core is process-global in tests. Reset or snapshot its ring
when assertions depend on prior records.

### project-hs-stateful-native-test-doubles

Native doubles must preserve independently observable state and failure modes.
A permissive stub can make teardown, iterator, and ownership tests false-green.

### project-hs-fs-dir-drops-state

`hs.fs.dir` returns iterator and state. Production and doubles must preserve both
values or directory scans can silently stop.

### project-lua-zero-byte-file-probe

On POSIX Lua, `file:read(0)` returns nil without an error at EOF for an empty
regular file; a directory returns nil with an error. Test doubles must inspect
both returns instead of treating nil as proof of a directory.

### project-macos-split-module-stub-reload

When extracting a stateful module, add it to every `load_with_stubs` reload list.
Otherwise tests inherit state from previous files.

### project-hs-purity-ratchet-counts-comments

The `hs.*` purity ratchet counts raw substrings, including comments and strings.
Avoid mentioning new `hs.` tokens in guarded modules unless intentionally
updating the baseline.

### project-macos-initlua-no-compile-coverage

A harness that only copies `init.lua` does not parse it. Keep a dedicated Lua
syntax gate for entry files outside the normal require graph.

## Native lifecycle contracts

### project-hs-native-result-contracts

A successful `pcall` only means no Lua exception occurred. Interpret each native
API's actual return contract, including false/nil operational refusal.

### project-hs-json-native-test-conversions

The shared pure-Lua JSON decoder is not an exact `hs.json` test double for
nulls or empty tables. Native LuaSkin converts `NSNull` to nil, appends array
items at the current Lua length plus one (compacting null entries), and converts
an empty Lua table back to an NSArray. Model these boundaries explicitly when
testing native JSON consumers; do not infer native crashes or object/array
identity from the shared codec. The conversion owner is
[LuaSkin Skin.m](https://github.com/Hammerspoon/hammerspoon/blob/master/LuaSkin/LuaSkin/Skin.m),
used by the native JSON extension.

### project-hs-native-task-lifecycle-contract

Task construction, start, callback, timeout, and teardown are distinct failure
boundaries. Central lifecycle adapters own all of them.

### project-hs-process-lifecycle-transaction

Publish a watcher or process only after activation commits. A teardown refusal
leaves cleanup debt whose callbacks must already be inert.

### project-hs-timer-commit-contract

Timer callers consume both handle and committed status. Retain a live but
uncommitted candidate as cleanup debt rather than losing ownership.

### project-hs-timer-callback-errors-invisible

Errors thrown from timer callbacks can vanish behind framework dispatch. Wrap at
the ownership boundary and log the original traceback.

### project-hs-http-timeout-before-dispatch

An async request is dispatchable only after its timeout capability commits.
Dispatch-first races can leave requests with no owned terminal path.

### project-hs-ordered-startup-transaction

Required input owners commit in startup order and roll back in reverse order.
Boot success is published only after the complete chain commits.

### project-hs-adapter-contract-violations

Adapters translate native semantics into explicit project contracts. Do not let
callers depend on undocumented raw `hs.*` truthiness or callback behavior.

### project-hs-pathwatcher-start-hides-native-refusal

`hs.pathwatcher:start()` returns the watcher object and hides the underlying
`FSEventStreamStart` Boolean. Lua tests can prove the exposed startup transaction
and rollback contract, but an actual native start refusal requires a macOS
binding-level or fault-injection test.

## Keyboard and OS integration

### project-hs-synthetic-injection-choke-point

Every synthetic keyboard event goes through one adapter with an exact provenance
tag and destination transaction. PID, timing, and text equality are not identity.

### project-hs-native-eventtap-disable-recovery

Hammerspoon consumes CoreGraphics tap-disable notifications in native code and
re-enables the tap before Lua callbacks run. Lua handlers or disable counters are
unreachable false fixes. Keep the keymap, keylogger, and script-control watchdogs
that poll native enabled state and restart persistent taps.

### project-hs-sentinel-key-misfire

F13/F14/F15 can be physical macOS keys. Karabiner sentinels must also require the
owned AltGr state; never trigger script control from the bare keycode.

### project-hs-control-sentinel-single-owner

A Karabiner signal key that only Hammerspoon should see is application input
unless a tap deletes it: the pass-through F20 layer sentinel replaced a selected
QSpace file name whenever the navigation layer was held. Quartz tap order
follows start order and taps restart, so "a swallow tap that runs last" cannot
be guaranteed. The keymap keyDown/keyUp taps (installed for the whole process,
PAUSE included) delete such keycodes through
`modules/keymap/control_sentinels.lua`, before ignored-window pass-through;
every other tap passes them through untouched, and consumers subscribe with
`set_listener`. Do not claim in `EventProvenance.classify_with_fence`: an extra
keycode read there breaks the per-tap read budgets pinned by the tooltip and
ignored-window tests. The generator emits F20 only inside the ACTIVE lease
graph, so a paused or revoked driver never produces it.

### project-hs-screen-capture-needs-own-grant

`/usr/sbin/screencapture` launched by the packaged runtime is attributed to
`com.ergoptiplus.app.hammerspoon`, so a Screen Recording grant held by a stock
Hammerspoon never applies; macOS lists the runtime as "Hammerspoon" and applies
a new grant only after a restart. Without it the selector still appears, then
the capture fails or omits every window. Every capture entry point goes
through `modules/shortcuts/actions/screen_capture_flow.lua`: check
`adapters/screen_capture.lua` before launch, capture into an owned file (never
`-c`, which leaves nothing to verify), then read the image back from the
pasteboard before announcing success. screencapture's own help says Control
held during an interactive capture sends it to the clipboard; Ctrl+H is still
held when the selector opens, so an advanced pasteboard change count with an
image also counts as a copy.

### project-macos-grants-follow-the-designated-requirement

TCC and Login Items store a grant against the signature's designated
requirement. An ad hoc signature's requirement is the cdhash, new on every
build, so no grant survives an update whatever `--identifier` says. A stable
self-signed certificate (`tools/build/create_macos_signing_identity.sh`, secrets
`MACOS_SIGNING_CERTIFICATE_BASE64` / `_PASSWORD`) makes it identifier +
certificate hash. Action: sign every object through `sign_code` in
`build_macos_app.sh`, never replace the certificate casually (each new one
costs every user one re-grant), and read the requirement the release log
prints before blaming the driver for a lost grant.

### project-hs-input-source-single-owner

`hs.keycodes.inputSourceChanged` is a setter, so one broker owns it and
multiplexes subscribers.

### project-macos-script-control-tap-lifecycle

The keycode-based script-control event tap survives layout changes and pause.
Do not restart it through shortcut lifecycle or regenerate Karabiner state on a
pause-driven layout switch.

### project-hs-shortcut-preference-is-not-the-binding

Named shortcuts in `modules/shortcuts/bindings.lua` have two axes:
`is_enabled`/`list_shortcuts().enabled` is the user preference (not in
`_disabled_set`), `is_bound`/`.bound` the live native hotkey. Pause, Shortcuts
OFF, stop and the layout-rebind fence release every hotkey but never the
preference, and `Preferences.snapshot` persists only the preference to
`[shortcuts.keys]`. Reading the binding as the preference wrote every key false
on each save made behind the fence (Disable All saves exactly there). Behind the
fence `enable` records the preference and binds nothing; the next start/resume
binds it. The boot and Disable All syncs replay saved keys in that window. Test
doubles must keep both axes and the admission fence
(`tests/support/shortcut_bindings_fixture.lua`).

### project-hs-boot-sync-never-saves-runtime-refusals

`MenuState.sync_state_to_modules` never persists and isolates failures per
feature: a refused lifecycle whose posture can be read back demotes only that
state flag, in memory (`report.demotions`), and `ui/menu/session_demotions.lua`
makes every save keep the config.toml value until a committed save carries a
user change of that key (`settle` runs on commit, never while building the
view, because a refused write rolls the key back to its demoted posture) or
Enable/Disable All publishes explicit values. That transaction detaches the
demotions for its candidate save and re-adopts them in its inverse; a global
writer that saves without that pairing writes demoted values over config.toml
when it is reversed. The old all-or-nothing sync restored every
default after one refusal (Gestures, Metrics, AI OFF with config.toml ON) and
the next toggle wrote them over the file; a save from inside the sync also ran
before the boot transaction was seeded and failed. Only an unprovable posture
(`report.unsettled`) or a raised sync rolls the whole state back. Keep new
refusal paths in memory; never call `save_prefs` from the sync. The menu's sync
wrapper also records the demotions of every rollback sync (`restoring`), which
re-applies what config.toml holds; a candidate sync never records. A rolled-back
session over a present file, and one whose config.toml could not be decoded,
holds only defaults: its save transaction is read-only (refuse, roll back, ERROR).

### project-hs-shortcut-owners-are-parent-scoped

The shortcut layer's text, mouse, app-navigation and pixel owners keep one
admission scope per action parent: "shortcut_bindings" when no parent is named
(bindings.lua and keyboard slots), "gestures" for gesture dispatch. A gesture
action passes `current_action_parent()` and its owner must be listed in
`scoped_action_children()` of `modules/gestures/actions.lua`; a global owner
there would let one feature's PAUSE settle or fence the other's work.
Keep-awake is the deliberate exception: one machine session that stops at the
first physical input.

### project-hs-fork-admission-in-both-launch-modes

Opening ordinary Hammerspoon with a Git checkout is a supported launch path;
users must not need to build or start ErgoptiPlus.app to obtain its native
remapping dependencies. App and repository onboarding must install and select
the same pinned owned runtime (`project-hs-owned-remap-runtime`), from the same
root-owned location, whichever way Ergopti was started. An installed or running
official Karabiner-Elements is a coexistence case, not proof of runtime
readiness: verify the owned peers by designated requirement and the live stream
capability, leave the user's `~/.config/karabiner` untouched, and include a
preinstalled-official case in native acceptance. The current bundle-bound lease
helper does not yet satisfy this bootstrap requirement.

### project-hs-karabiner-exact-lease-isolation

In shared mode, the production path until the owned runtime ships, Ergopti owns
only token-scoped Karabiner rules and variables and never owns, quits, unloads
or restarts Karabiner-Elements' UI, daemon, grabber, console user server or
VirtualHID processes. `tests/meta/test_karabiner_stock_process_isolation.lua`
enforces this; keep it strict until WP6 of the
[HS-274 plan](../handovers/2026-09-29-overnight/hs274-delivery-plan.md) lands
the owned runtime together with the exact code it must allow. ADR 011 then
permits two things only: controlling the Ergopti-labelled runtime peers, and
quitting stock Karabiner through the default-on « close other Karabiner
instances » option while the owned runtime runs. Any other control of stock
`/Library/Application Support/org.pqrs/Karabiner-Elements` processes remains a
bug.

### project-hs-owned-remap-runtime

[ADR 011](../../static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md)
(maintainer, 2026-09-29) replaces the Karabiner-Elements application with an
Ergopti-owned background runtime: the unmodified pqrs VirtualHIDDevice plus a
self-signed headless 3-product fork of Karabiner-Elements 16.3.0 carrying the
HS-274 stream. It runs only while Tap-Hold is on; metrics-only users keep the
Quartz event tap, exact when nothing is remapped. Mechanisms future work must
keep: the console user server takes its configuration from `$XDG_CONFIG_HOME`,
so Ergopti owns a complete `karabiner.json` without a source patch; the daemon
ungrabs when its console-user peer closes, so the owner must start that peer
with the owner-PID watch WP4 adds; root binaries run only from a root-owned
`/Library/Application Support/ErgoptiPlus/…` copy, never from the
user-writable app bundle; upstream `same_team_id` trusts every peer of an
unsigned daemon, so the fork must pin the Ergopti certificate leaf before it is
distributed. A selected stream never falls back to Quartz or the ledger when it
is lost: it records a gap. Never ship the 10-product « complete candidate » or
keep the Updater, which can replace the fork with official binaries.

### project-hs-karabiner-switch-precedes-lease-and-guardian

`[karabiner] integration_enabled` in `config_karabiner.toml` is read before
any token, lease worker, or guardian registration, at boot and on toggle. Never
read the older `[karabiner] enabled`: builds before 2026-09-22 wrote `false`
there on first launch without asking. The launcher never registers the guardian
LaunchAgent; the Lua lease controller's first guardian observation of a
lifecycle does (`--register-remap-guardian`), so nothing is registered while
the switch is off. Nothing unregisters it either: a guardian registered while
on stays in Login Items after the switch is turned off, until uninstall.
Turning it off removes only marked rules by byte-span surgery proven by decoded
equality; never re-serialize `karabiner.json`, which would rewrite personal
rules.

### project-hs-guardian-approval-has-one-native-poller

A guardian held for Background Items approval keeps every rule inert. Its first
`requires_approval` answer reaches `guardian_notice`, which offers the boot's
presenter (`platform.remap.set_approval_presenter`, wired in `init.lua`) before
its banner: `ui/permission_dialog/login_items_guide.lua` opens the dialog's
`login_items` steps once per launch, focused and never floating. The guide polls
only the in-memory `guardian_state()`; the remap readiness wait stays the one
native poller and the one path that deploys the retained regeneration on
`ready`. Do not add a second status probe or deploy path for the dialog.

### project-hs-kc-ledger-process-lifecycle

The Karabiner physical-key ledger keeps draining when metrics are disabled.
Only process shutdown tears it down.

### project-macos-reload-during-git-pull

Auto-reload watchers must debounce and hold reload while any bulk writer is
rewriting the tree, including Git, cloud sync, and rsync.

### project-macos-startup-winfilter-cost

Never construct `hs.window.filter` on boot or first-key paths. Its native setup
cost is observable typing latency.

### project-touchdevice-dormancy-is-kernel

macOS touch-device readiness is gated by the kernel until first physical touch.
Do not add repeated user-space probes that cannot change readiness.

### project-karabiner-unlisted-held-modifier-blocks-the-rule

Karabiner matches a rule only when every held modifier is mandatory or optional
in its `from.modifiers`; `to_if_alone` then goes out with the modifiers held at
key-down. Action: the modifier-type tap-hold keys and CapsLock accept
`optional: ["any"]`, so their taps combine with held modifiers; Escape, Tab,
Space, Return and Backspace accept only `caps_lock`, so a held modifier leaves
them native (Cmd+Tab, Shift+Tab) as on Windows and Linux.

### project-hs-f17-actions-are-told-apart-by-modifiers

`alt_tab_windows`, `alt_tab_apps`, `alt_tab_monitor` and `cycle_windows_in_app`
share F17 and differ only by modifiers, bound as exact-match Hammerspoon
hotkeys. A modifier held while one is tapped is added to its trigger, which
then runs another action or none. Action: mark any new action of that kind
`exact_modifiers` in `platform/remap/data/actions.json`; the generator's
`exact_modifier_manipulators` then splits every rule sending it into one
manipulator per held hand flag plus a last `mandatory: ["any"]`, so Caps Lock
is claimed only under two held flags, and `test_generator_typed_output.lua`
replays the whole class.

### project-karabiner-v16-rule-semantics

Read from the pinned v16.0.0 source (`src/share/manipulator`) and modelled in
`tests/support/karabiner_model.lua`. A mandatory `any` claims every pressed
flag, Caps Lock too while the lock is on, and lifts it around `to`,
`to_if_alone` and `to_after_key_up`, one press per flag, so a flag two keys
hold stays down and a claimed Caps Lock is toggled for macOS. The lifted flags
come back right after `to` only when its unfiltered last entry is not a
modifier key, yet only the last posted entry stays held: end a modifier hold
with a never-posted entry (`vk_none` under `expression_if "0"`), never an
ordinary event. A physical key reaches the output only after every
manipulator passed it, so a chord's own keys are never among the flags it
tests: never list them as mandatory. A chord takes both key_downs, so it must
restore the held state of the key pressed first itself (`held_key_state`: its
held variable and layer), with one manipulator per press order (`strict`,
`strict_inverse`) when either key may go first. That state is cleared by
`simultaneous_options.to_after_key_up` only once both keys are up, so
releasing the first key early leaves it on until the other is up. Only one
`to` entry stays down: a modifier action keeps it; after one of the eight
modifier keys a plain-key action goes out once and the key's held key keeps
it (`key_up_when: "all"`); after any other key the action keeps it and
repeats, the key's held modifier returns with its next press, and its
hold-then-tap rules carry a manipulator without their mandatory modifiers.
`from.modifiers` accepts and consumes `fn` like any other flag. A modifier
held before a key never cancels its `to_if_alone`, but any later key_down
does, so a key or combo with a tap and no hold sends its tap as `to`. Action:
prove a generator rule change through the model, extending the model from the
source.

### project-sparkle-consent-is-plist-owned

Sparkle 2.9 reads `SUAllowsAutomaticUpdates` from Info.plist only, and
`automaticallyDownloadsUpdates` is that flag and `SUAutomaticallyUpdate`: one
tick of the standard window's checkbox made every later check download
silently. Action: keep the flag false in the bundle, prove
`UpdateConsentPolicy` on the live updater before `start()`, and present updates
through `CatalogUpdateUserDriver`; the standard driver is English-only.

### project-sparkle-installer-progress-is-outside-the-user-driver

One Sparkle 2.9.2 window escapes `CatalogUpdateUserDriver`: after "Install
and restart" quits the launcher, the Autoupdate installer asks its progress
agent (`Updater.app`, id `org.sparkle-project.Sparkle.Updater`, shared by every
Sparkle app) to show "Updating ErgoptiPlus", "Installing update…" and "Cancel
Update" once the final swap takes over 0.7 s (`SUDisplayProgressTimeDelay` in
`Autoupdate/AppInstaller.m`). `SPUUIBasedUpdateDriver.m` passes
`displayingUserInterface:YES` for every user choice; only the automatic driver,
which the consent policy forbids, passes NO, and no Info.plist key or delegate
method changes it. `ShowInstallerProgress.m` loads the strings from the host's
embedded Sparkle.framework inside the agent process, so they follow the macOS
system languages among Sparkle's localizations (no `hi`, Norwegian only as
`nb`/`nn`), never the driver's choice; a per-app `AppleLanguages` on that
shared id would change every Sparkle app. "Install when ErgoptiPlus quits"
sends no resume message, so no window appears, but nothing relaunches either.
Action: do not re-investigate a configuration fix; only a patched Sparkle
build or an owned relaunch helper can remove the window.

### project-hs-gestures-runtime-follows-feature

The gestures native runtime (touch watchers, primer eventtap, discovery and
30 s health-check timer, wake watcher) exists only while Gestures is ON:
`modules/gestures/init.lua` `enable_all()` acquires it through `start()` and
`disable_all()` releases it. Boot never calls `gestures.start()`; the menu's
preference sync does it. Before 2026-09, boot started it unconditionally and OFF
only cleared a flag, so the taps and "Health-check tick" lines kept running with
Gestures off; such a line now proves Gestures was ON. Test doubles:
`tests/support/gesture_runtime_fixture.lua`.

## Clipboard, files, and privacy

### project-hs-clipboard-transaction-ownership

Clipboard borrowers snapshot all types before mutation and keep ownership until
exact restoration commits. Failed restoration remains cleanup debt.

### project-hs-wrap-selection-clipboard-ownership

A wrap-selection key is consumed only after paste and full clipboard restoration
are both owned; partial success must not lose the user's clipboard.

### project-hs-keylogger-append-commit

A non-throwing file-write refusal retains the exact detached snapshot and FIFO
head for retry. Do not acknowledge data before append commits.

### project-macos-absence-needs-lstat-proof

`io.open` returning ENOENT does not prove a path is absent: dangling symlinks and
missing parents require the filesystem transaction adapter and `lstat` semantics.

### project-hs-ignored-window-pass-through

Ignored/private applications bypass all Ergopti text features, including repeat,
preview, logging, and expansion.

### project-macos-eventtap-no-blocking

Event-tap callbacks perform only bounded in-memory work. `doAfter(0)` leaves the
callback but is not a thread hop; shell, filesystem, and log sinks need an owned
asynchronous worker and completion protocol.

### project-hs-quit-never-blocks

Controlled quit/reload teardown runs on the Hammerspoon main thread, so a
synchronous shell-out there (`hs.execute(cmd, true)` is a login and interactive
shell with no timeout) freezes the app as "not responding", and no timer can
fire to rescue it. Teardown steps dispatch absolute-binary `ShellRunner.spawn`
tasks and never wait. The keylogger process-exit stop skips the final ingest,
and the MLX shutdown skips the listener proof when this Lua generation owns no
server. User quits go through `TerminationCoordinator.request_user_exit`. It
arms `user_quit_deadline_ms` before the lease fence, so a stuck async stage or a
failed fence force-exits with status 70 and logs the pending stage.
`tests/meta/test_quit_teardown_never_blocks.lua` scans every teardown step's
callee. Map each new step receiver there.

### project-swift-sdk-posix-imports

Swift SDK imports can shadow libc functions with same-named structures and can
remove private Foundation accessors. Keep BSD `flock` behind the explicit C shim
and build owned `posix_spawn` environments from `ProcessInfo.environment`.
Cross-process descriptor tests use a debug-only role of the real launcher,
started through `Process`/`posix_spawn`; Swift 6.3 marks imported `fork`
unavailable, and binding that symbol in XCTest can interpose the test runner.
Keep every XCTest-visible shared constant out of executable `main.swift`: its
globals are not initialized when Swift 6.3 loads the executable module into
XCTest. Put them in a normal source file even when bootstrap is their main user.

### project-macos-llm-runtime-enable-gate

Restored profile/model state never authorizes model loading. Only the live LLM
enable gate may trigger warmup side effects.

### project-hs-canonical-lua-module-identity

Require stateful facades under their canonical names: `modules.llm`,
`ui.tooltip`, and `ui.metrics_typing`, without `.init`. Lua caches by module
name, so aliases execute the same file with independent runtime state even
when low-level modules are shared. Parser/profile consumers require the LLM
core lazily to avoid import cycles; endpoint defaults inspect its canonical
loaded key. Generic test helpers must not conceal duplication with alternate
keys, and fixture scopes must own the canonical key actually used by consumers.

### project-hs-download-presentation-epochs

A native WebView owner and its current operation are distinct identities.
Retiring a native window fences its callbacks, but reusing it also requires an
operation epoch on frontend actions and producer progress/completion updates.
The shared frontend opts into tagged actions through the fourth `setKind`
argument; three-argument Windows/Linux callers retain their string protocol.

### project-hs-terminator-stop-settlement

The paste settle interval starts at observed replacement dispatch, not at its
nominal schedule. Teardown cannot force that fence open. Logical replay
activation also precedes native settlement: keep exact reservation ownership
and context revocation until completion, and refuse an early engine stop before
mutating listeners, taps, or lifecycle state.

### project-hs-diagnostic-sink-reentrancy

Logging is an external callback boundary, not a memory-only operation. Retire
the exact diagnostic owner before emitting its terminal message, and recheck
request authority after a sink can reset or dispatch a successor. A diagnostic
watermark must never replace the engine's actual callback authority.

### project-hs-physical-accounting-needs-producer-ownership

A managed output keycode is not proof of a synthetic physical credit: a real
none/none Space can share code 49 with remapped Escape while producing no
physical ledger entry. Global suppression loses real input. Require exact
output ownership or complete physical coverage during normal remapping before
deduplicating. EventViewer raw capture disables remapping, a first
`from.any`/`to.from_event` rule blocks later rules, and datagram delivery alone
provides neither coverage nor provenance. Consult the
[HS-274 evidence and rejected paths](../audits/hammerspoon/2026_09_09/discoveries.md)
before repeating acquisition experiments or using historical TODOs.
`modules/keylogger/physical_accounting_mode.lua` is the one owner of the
answer: the event tap (keyDown `kc`, flagsChanged modifier events) and the
ledger credit only under the legacy source; a selected stream makes both
silent, and a stream without an admitted complete capture is a gap, not a
fallback. Gate any new physical writer on it, and keep
`test_hs274_duplicate_count.lua` and `test_hs274_physical_collision.lua` green:
they pin the legacy double count and fail for either the `and nil or` idiom or
global suppression.

### project-hs-webview-nil-error-sentinel

Hammerspoon 1.1.1 calls `NSError_toLua` unconditionally after JavaScript
evaluation; the helper builds a table even for a nil NSError. Objective-C nil
messaging yields code zero and no other fields, so successful execution supplies
exactly `{code = 0}` despite the documented nil-error contract. A non-nil guard
therefore reports successful UI delivery as failure. Use
`adapters/webview_result.lua`; retain errors with any additional field or a
metatable, including real code-zero errors with a domain. Model both nil and
the native sentinel in callback fixtures. The pinned implementation is in
[libwebview.m](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/webview/libwebview.m),
`webview_evaluateJavaScript` and `NSError_toLua`.

### project-hs-development-runtime-registers-stock-peers

Launching custom Karabiner core/console paths does not isolate their IPC peers:
both startup paths invoke installed service-manager apps, and registration can
undo a launchctl disable. Use the owned disposable registration scope and native
executable inventories in `tools/diagnostics/hs274-remap.py`; do not remove IPC
authentication or infer cleanup from sudo leader PIDs alone. Native macOS reports
launchd state as `disabled`, while sudo may report a non-executable file as
`command not found`; retain raw replies and use the verified exec-refusal probe.
The [producer contract](../audits/hammerspoon/2026_09_09/producer-contract.md)
records the isolated runtime evidence and the pre-normalization capture boundary.

The upstream agent also launches the installed Core-Service bundle directly with
`permission-check`, independently of those registration helpers. Run 34868282852
retained that exact command after successful overlap input; its isolation verdict
correctly failed. The disposable suspension scope must therefore block execution
of the installed Core-Service as well and restore its exact identity/mode afterward.
Keep development binaries and the signed virtual HID provider executable; never
allow an unexpected PID merely because a later arguments snapshot looks harmless.

### project-hs-native-quartz-proof-boundary

For reusable Hammerspoon admission fixtures, retained screenshots, artifact
identity and the distinction between Windows doubles and native virtual-HID
proof, consult the [native continuation record](../audits/hammerspoon/2026_09_09/native-hammerspoon.md).

When a correctly selected, validly signed Hammerspoon copy remains absent from
Accessibility, inspect TCC bundle resolution before repeating UI automation.
The native error `failed to find an Application URL for bundle ID` was observed
even though Launch Services had launched the copied application. Successful
launch and signature verification alone therefore do not prove resolution for
TCC enumeration. Preserve scoped native messages and distinguish this symptom
from a proven registration fix; the continuation record retains the receipt.

Native context fixtures must use an external target process. Observing the
consumer's own WebView returned AX `Messaging failed` despite true Accessibility
trust and a matching foreground PID. The separate Cocoa target passed exact AX
field/window checks and all four privacy transitions through the same consumer
modules. Reuse `tools/diagnostics/hs274-context-target.swift` and its owned
controller; target command acknowledgements are not substitutes for independent
AX observations. Native acceptance and its remaining coverage limits are in the
[external target receipt](../audits/hammerspoon/2026_09_09/native-hammerspoon.md#external-target-acceptance-on-native-macos).

A hosted macOS runner can execute real Quartz taps without proving physical
keyboard or Karabiner provenance. Native original/copy marker preservation
does not imply binary serialization preservation; decoded user data was zero
across four source variants in the recorded experiment. Root also does not
grant the entitlement needed by an ordinary IOHIDUserDevice acquisition probe.
Installing the signed Karabiner provider is a separate boundary: its Manager
can wait indefinitely for approval or exit zero pending reboot. Check actual
system-extension state. Normal authentication with an owned temporary CI
administrator reached `[activated enabled]`, which persisted after account
removal. Keep capability failures distinct from production regressions and consult the
[native receipts](../audits/hammerspoon/2026_09_09/discoveries.md#real-macos-github-actions-evidence)
before repeating an installation or acquisition attempt.

### project-hs-native-approval-ui-observations

The hosted image's existing osascript permissions can navigate the verified
Karabiner notification and Driver Extensions sheet. System Events terminology
can shadow report variable names (`rows` caused AppleEvent error -10000), and
unrelated sidebar nodes can fail coercion during whole-window enumeration.
Scope the read to the verified provider group. A successful AXPress on the
provider checkbox still left native state waiting for approval in the recorded
experiment; independently verify state after UI actions. Consult the
[approval UI evidence](../audits/hammerspoon/2026_09_09/discoveries.md#normal-approval-interface-observation)
before treating a scripting error as a permission denial or a click as approval.

### project-hs-sampled-element-state-boundary

`hs274-key-state.hpp` is a per-device/cookie state primitive, not a physical-credit
counter. The experimental source initializes it from the typed native inventory
and updates it before global readiness and lease-storage checks. Otherwise a
press during preparation would leave the eventual initial state stale. The
source still publishes unchanged raw observations rather than treating an
element-state result as an instruction to delete them. Its ordered-clock contract
rejects backwards or equal-time conflicting events and events newer than the
reported sampled state but no later than the query start. A transition during
the query interval can follow the actual read; do not suppress it merely because
it precedes query completion. An opening timestamp does not prove an atomic
native queue cutover; that boundary still needs native validation. Reuse
`hs274-key-state-test.cpp` and the two native cookie fixtures for that work;
do not infer aliases or merge distinct cookies solely from a shared usage.

Selected native monitors include consumer-only interfaces. Carry the explicit
keyboard property through attachment; require a qualified nonempty inventory for
keyboards and successful empty keyboard enumeration for consumer-only interfaces.
Unexpected keyboard input on the latter invalidates capture instead of inventing
unobserved initial state. Monitor readiness and `key_down` do not constitute an
atomic kernel snapshot or an initial-state handoff to the consumer.

### project-hs-paged-initial-state-handoff

The experimental source now freezes per-element observation frontiers at a
dispatcher-owned `mach_absolute_time` boundary and starts raw lease storage
before transferring the baseline. Preserve explicit device markers, including
empty consumer-only interfaces. Pages are bounded because the native IPC limit
is 32 KiB; do not serialize all 64 interfaces into the opening frame.

`baseline_ack` names the exact pending row cursor independently of raw sequence
acknowledgements. Every page and the final completion check use the controller's
shared session identity and sticky loss verdict. Overflow or topology loss must
invalidate even an already frozen snapshot. The last page is acknowledged once;
`baseline_ready` has no second downstream receipt. Raw pulling starts only after
the final page acknowledgement. Keep these rules aligned across source, CLI,
Python fixture reader and Lua transport.

Lua delivery requires the descriptor and completed baseline before any credit.
It updates delayed pre-opening observations for state only, preserves inherited
releases, and credits fresh rising edges after opening. Contradictory clocks,
unknown identities and a changed observation exactly at opening retire delivery.
Privacy-excluded observations still advance key state. Same-usage cookies remain
distinct; this does not prove how hardware aliases should map to physical credits.
Python can replay historical receipts without a baseline, but that offline
decoder does not authorize their admission by the live Lua consumer.

Portable tests cover this handoff; the earlier native build and acceptance runs
predate it. Build a matching producer before testing the changed consumer. A held
native probe without Hammerspoon cannot validate held-state consumer handoff.
Normal production startup and exclusive physical accounting remain unintegrated.

### project-hs-native-remapping-fixture-boundary

Native HID inventories identify elements by cookie within a device, not by
usage alone. The pinned upstream `iokit_hid_value` wrapper drops that cookie;
read it from the corresponding `IOHIDValueRef` before losing native identity.
Do not infer a cookie from usage when replaying historical receipts that lack
it. Cookie retention alone does not reconcile queued events with sampled state.
Replay `tools/diagnostics/fixtures/hs274-native-cookie-capture.json` through
`hs274_stream_test.py` to check actual native wire/raw equality and the Escape
and Space identities against their retained inventory elements.
The companion `hs274-native-cookie-held.json` retains an initially held Space
and its later release/press/release with the same cookie. Its baseline replay
does not exercise a lease or Hammerspoon consumer; use it as state input evidence.
The signed provider exposes the same modifier usages as scalar
bits and array leaves with distinct cookies; both observations must remain
available. A usage-range bound also truncated this descriptor. Keep diagnostic
capacity explicit and distinguish per-element readability from atomic held state
or physical-press ownership. Exact samples are retained in the
[inventory refusal](../audits/hammerspoon/2026_09_09/hs274-inventory-refusal.json).

For native inventory regressions, reuse the four snapshots in
`tools/diagnostics/fixtures/hs274-native-inventories.json` through
`hs274-stream-inventory-test.cpp` and `hs274_inventory_test.py`. They cover a
released fixture and a fixture with Space initially held, preserving all scalar
and array leaves. Run the replays or query individual cookies instead of loading
the complete corpus into context. Enumeration/readability is distinct from
synchronizing queued events at lease opening; the
[native acceptance](../audits/hammerspoon/2026_09_09/native-hammerspoon.md#complete-fixture-inventory-acceptance)
records that boundary.

For initial held-key acquisition, replay
`tools/diagnostics/fixtures/hs274-native-held-baseline.json` through
`BaselineTests.test_retained_native_kernel_baseline_preserves_inherited_and_fresh_space`
in `hs274_stream_test.py` before scheduling another native experiment. The
controlled held Space was acquired using the explicit kernel source; forced
reads returned failure statuses despite non-null cached pointers. Preserve those
refusals. This receipt covers two usages and a later fresh Space pair, not a
complete keyboard inventory or an atomic snapshot across all elements.

The signed provider's keyboard can be renamed through ordinary IOKit product
metadata after verifying an empty identifier baseline and a unique owned
device. Karabiner then recognizes it as an input; restore and read back the
metadata after the scoped observation. Numeric vendor/product IDs alone do
not bypass Karabiner's manufacturer/product-name classification.

On the recorded hosted image, direct Core-Service execution had IOHID-listen
and accessibility permissions, while Launch Services invocation did not.
Use its own permission-check receipt for the actual invocation context.
Real remapping of fixture Escape to Space and passthrough Space produced the
same observed Quartz source fields; only Escape appeared in the physical
ledger. Virtual-output sender identity therefore cannot resolve that collision.
The reusable native fixture and exact receipts are routed through the
[investigation report](../audits/hammerspoon/2026_09_09/discoveries.md).
This validates a virtual fixture, not physical keyboard hardware.
