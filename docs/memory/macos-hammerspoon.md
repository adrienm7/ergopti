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

### project-launch-gate-native-features-without-consent

Hosted macOS runners attribute every AppleEvent from the job to the runner's
`hosted-compute-agent`, and its Automation consent dialog is never answered:
`osascript ... execute lua code` against the packaged runtime only ever timed
out after 10 s in `AESendMessage` (runs 37859679168, 37862861495, 37868449649),
and a later no-prompt send then returned -1712 because the earlier prompted
send had left the dialog open. The launch gate therefore never drives the
runtime through AppleEvents for a feature. The delayed-timer, Karabiner and
Script features run through `hs_native_bootstrap_probe.py`, which points
`MJConfigFile` at an owned startup file after the managed launch quits and
exchanges ready/admit/settled/feature files. The only AppleEvent check is the
first event the gate sends, a no-prompt send from
`native_appleevent_probe_sender.c` that must answer exactly -1744
(errAEEventWouldRequireUserConsent). Never send a prompting event to the
runtime before it. The Karabiner budget scales with its variant count because
Intel runners exceed the 10 s that arm64 meets. Each variant journals its
duration to `feature.json.progress`, so a timeout still reports how far it got.

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

### project-macos-python-is-chosen-by-its-slices

`/usr/bin/python3` is the xcode-select shim: it runs the python3 of the active
developer folder (DEVELOPER_DIR, `/var/db/xcode_select_link`, Xcode, then the
Command Line Tools), whatever processor that copy was built for. dev.155 ran it
at every boot for the input-source probe, and on an Apple silicon Mac migrated
from Intel macOS started it under Rosetta and posted "support for Intel-based
apps is ending … Python". Nothing at boot may run Python (the probe reads
`defaults read` through `infra/openstep_plist.lua`), and every helper takes
its interpreter from `adapters/python_interpreter.lua`, which reads Mach-O
slices without executing anything and refuses one without the native slice;
a refusal opens `ui/python_runtime_offer.lua`. Never start `python3` by a
fixed path or PATH, and never run an interpreter to ask its architecture.
Unit tests get the real resolver over a modelled Mac through
`helpers.load_with_stubs` (`HEALTHY_PYTHON`); the boot harness declares each
spawned executable's slices and fails on E2E_ROSETTA (`hardening-h-no-rosetta`).
The App Cloner's own scripts still run `python3` from PATH/`/usr/bin`.

### project-macos-download-children-read-the-system-network

A child of Hammerspoon has no relay variables, and uv, Python and Ollama's
Go client never read the macOS network settings; uv also trusts its bundled
Mozilla roots unless told otherwise, and `SSL_CERT_FILE` overrides every
store. The MLX installer exported `SSL_CERT_FILE=/etc/ssl/cert.pem`, so behind
a TLS-inspecting company relay uv and curl refused every download ("error
sending request for url"), and a company filter denying uv network access
("tcp connect error: Operation not permitted") read as a file permission.
Every macOS download child now sources `apply_system_network` from
`modules/llm/network-retry.sh` (the scripts directly, the Ollama service and
the MLX model download through `modules/llm/network_env.lua`): relay from
`scutil --proxy`, loopback always in NO_PROXY, `UV_SYSTEM_CERTS=1`, and never
a CA file. uv comes from its pinned PyPI wheel (`uv-release.sh`), and a native
Python 3.11–3.14 builds the venv without the managed interpreter download from
GitHub. Failures use the shared classes (certificate, proxy, host_blocked,
offline) and `network.failure.*` sentences with their actions. Never log the
word "proxy" in a normal line: the shared classifier matches it bare.

### project-managed-ollama-native-hooks-follow-the-pinned-source

`tools/build/build-macos-managed-ollama.py` patches exact upstream snippets,
gated by the SHA-256 preimages in `managed_ollama_runtime.json`; a release
bump changes them all. Ollama 0.40.4 (needed for `qwen3.5`) removed
`server/internal/client/ollama/registry.go`, moved `x/transfer` to
`transfer/` and gave blob downloads a checked dialer (`transfer/redirect.go`)
that refuses non-public addresses. The native worker and an explicit relay
never reach that dialer, so both transfer seams use
`nativehttp.WrapChecked`, which repeats the decision in `address_policy.go`;
`transfer/redirect.go` is a preimage so an upstream policy change stops the
build. For a bump, extract the tag tarball (`gh api
repos/ollama/ollama/tarball/vX`) into an empty scratch folder, recompute the
preimages, and run `python tools/test/macos_managed_ollama_source_test.py
--source <folder>`, which applies the real hooks without Go
(`test-ollama-release-pin-parity.cjs` refuses any retired pin). The managed
server must also never contact ollama.com: `managed_ollama_environment.json`
(`OLLAMA_NO_CLOUD=1`) is embedded in the Go package and applied by the
`RunServer` hook (`ApplyServeEnvironment`), passed by Windows to its launcher
with a digest, and appended by Linux to the serve child; only the server a
driver owns gets it (`test-managed-ollama-no-cloud.cjs`). Since 0.40.4,
`ollama create` against a loopback server first probes whether it shares the
server's blob store by writing a blob into the client's own `$HOME/.ollama`
models folder and removing only the blob, so the folder survives; a receiver
that runs the client in an empty home then fails its empty-store check with a
create stage that reads "unknown". Run such a client with
`OLLAMA_CREATE_REMOTE=1` (upload through the server API) and keep every
receiver failure code in its closed list.

### project-macos-ai-runtimes-install-on-selection

Neither AI runtime ships in the app or downloads at boot, on AI enable with
another backend, or after an update: only `install_for_selection()` of
`ollama_deps_checker`/`mlx_deps_checker` grants a download, its sole caller is
`ui/menu/menu_llm/runtime_install_offer.lua`, and any other check settles
`missing` without a task. An installed runtime is reused by stat alone
(Ollama: `ollama_binary.resolve()`; MLX: venv `bin/python` plus
`.last_sync_hash`), so a new `uv.lock` in an update never re-syncs the venv.
When the MLX import probe then fails on an installed venv,
`mlx_deps_checker.invalidate_runtime(cause)` flags it broken in memory first
(a refused `.last_sync_hash` removal once left it "installed", so re-selecting
MLX did nothing), then removes the fingerprint; the next MLX selection, or the
repair button, runs the script with `ERGOPTI_MLX_REPAIR=1`. Never re-sync from
the probe itself. The script publishes a venv, and exits 0, only after its
interpreter imported `MLX_IMPORT_PROBE` (keep it equal to the Lua probe of
`models_manager_mlx`); the repair removes only the venv it derives, never a
link or a folder without a Python environment. hs.task hands the streaming
callback everything it reads, so a failure's cause must be kept while it
streams (`mlx_bootstrap_diagnosis.new_tail`); the completion's own output was
empty and every MLX failure read "cause inconnue". Every failure goes to
`ui/menu/menu_llm/mlx_repair_offer.lua`, whose dialog names the cause and
carries the button (`mlx-bootstrap-*`). An absent runtime (the import probe,
or a click on the boot notice of `notify_if_missing`) opens the same offer
with kind `missing`: its install button runs `select_mlx()` without the repair
flag, and a failed install comes back with its cause and the repair button
(`mlx-runtime-missing-install`). Never post a runtime notice that names a menu
row instead of carrying the click that opens its fix: hardening-g scans
notifications as well as dialogs. The Ollama checker still builds its failure
tail from the completion alone.
The Ollama installer publishes the whole release archive (CLI plus the
ggml/MLX libraries it loads from its own folder, as in
`Ollama.app/Contents/Resources`) into the folder
`ollama_binary.managed_install_dir()` names; never copy the lone binary. Add a
new runtime trigger through the router, and extend
`test_ai_runtime_selection_install_*.lua` (`ai-runtime-*`).

### project-macos-local-model-defaults-are-never-pulled

The AI menu pulls only its own prediction model. A "local" agent System or
screen reading without `|model` names `default_models.local` of `agent.json`
or `vision.json`, which nothing downloads; Ollama 0.24 answers `/api/chat`
with 404 `{"error":"model 'X' not found"}` (or `model "X" not found, try
pulling it first`). `api_ollama.request_prebuilt` therefore posts a model only
after `/api/tags` listed it (exact name, implicit `:latest`), fails both cases
with `MODEL_MISSING` and the name, and `modules/llm/local_model_offer.lua`
names it with a Download button that the AI menu's installer
(`models_mgr.pull_ollama_model`) serves; the automatic mode notifies instead of
opening a modal. Route any new local-model consumer through that transport and
offer (`ai-agent-local-model`).

### project-macos-ai-off-is-inert

With the AI switch off nothing of the AI runs, as on Windows
(`LLM_Menu_ActivateRuntime`) and Linux. `startup_controller` logs the Windows
line ("Restored AI menu state activated with the AI off…") and returns before
the MLX download reattachment and the profile-shortcut restore;
`trigger_orchestrator.apply_llm_profile_shortcut` keeps a shortcut chosen while
off as a preference with no native hotkey; `models_manager_ollama` neither
pre-warms nor refreshes `ollama list` while `deps.state.llm_enabled` is false.
The switch commit (`commit_enabled` in `menu_llm/init.lua`) calls
`sync_ai_runtime`, which arms (`arm_shortcuts`, `startup_runtime.arm`) or
disarms them; a startup that turns the AI off releases the hotkeys through
`ctx.disarm_shortcuts`. Any new AI hotkey, probe, task or timer gates on the
switch and joins that pair; extend `test_ai_off_runtime_inert.lua`, whose
fakes count bindings, tasks and timers.

### project-macos-local-openai-servers-are-keyless-api-entries

Servers the user runs (oMLX, LM Studio, llama-server/LocalAI, Jan) come from
`_shared/modules/llm/local_servers.json`; `api_remote` registers them as
`openai`-format providers with `local_server = true`, outside `PROVIDER_ORDER`,
so a menu lists one only while `local_servers.lua`'s last sweep saw it answer.
A chosen model is the server's one API entry (`local-<id>`), the only entry
kind whose token may be `""`: `key_missing()` in `api_remote` and
`validate_api_entries` in `modules/llm/init.lua` must agree on that exception.
The engine menu gets its rows through `ctx.local_server_rows`, not a
`backend_panel` require, because the backend fixtures stub `modules.llm`
without `api_remote`. Extend `test_local_openai_backends_*.lua`.

### project-macos-unreachable-ai-backend-is-explained

dev.152 showed "Disabling LLM (requirements check failed)" (the error window)
and, in the diagnostics, "Network request failed" for a local AI. Three causes
hid behind that ERROR in `startup_controller`: a missing runtime, an Ollama that
never answered its start, and the API backend, because
`models_manager.check_requirements` sent every non-MLX backend, a local
OpenAI server included, to Ollama's check. The AI switch also published "AI
enabled" before that check and stayed on when Ollama never answered. Now the
API backend has no local requirement; every readiness failure that leaves
nothing at the endpoint cancels with `OllamaEndpoint.UNREACHABLE` (the step
as detail), without the generic notice when each waiter passes
`reports_unreachable`; the switch and the startup turn the AI off with a WARN
and call `unreachable_backend_offer.lua`. Its dialog (`dialog_util.choose`: an
AppleScript alert holds three buttons, more become a list) names Ollama and its
URL, then offers each answering local server first, start or install. The
neutral backend is MLX on Apple silicon only (W1); on Intel Ollama is the
platform default (see `project-macos-llm-runtime-enable-gate`). Either way the
backend is never replaced silently: a server is only ever a confirmed button.
Action: route a new local-backend
failure through that offer and keep unexplained ones ERROR
(`llm-requirements-error-kept`); extend `test_llm_enable_unreachable_local.lua`.

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

`hs.pasteboard.clearContents()` returns no Lua values in the pinned native
binding. Normalize a successful call at its consumer boundary; requiring a
boolean `true` rejects healthy clearing. `writeAllData()` still requires its
actual boolean acknowledgement. Preserve both thrown errors and false/nil
write refusals in tests and diagnostics.

### project-hs-json-native-test-conversions

The shared pure-Lua JSON decoder is not an exact `hs.json` test double for
nulls or empty tables. Native LuaSkin converts `NSNull` to nil, appends array
items at the current Lua length plus one (compacting null entries), and converts
an empty Lua table back to an NSArray. Model these boundaries explicitly when
testing native JSON consumers; do not infer native crashes or object/array
identity from the shared codec. The conversion owner is
[LuaSkin Skin.m](https://github.com/Hammerspoon/hammerspoon/blob/master/LuaSkin/LuaSkin/Skin.m),
used by the native JSON extension.

### project-hs-json-decode-shares-equal-values

`hs.json.decode` returns one Lua table for every array or object equal to one
met earlier in the same document: LuaSkin's `alreadySeenObjects` is an
`NSMutableDictionary`, so its lookup goes by `isEqual:`. Editing a decoded
value in place edits every equal one. dev.148 refused every Karabiner deploy
(« generated rule 1 manipulator 3 has inconsistent managed conditions »)
because CapsWord's 30 identical conditions lists were one table and each
manipulator's generation gate was appended to it. `adapters/json_codec.lua`
returns a tree; decode through it. The test stub shares equal values the same
way (`tests/unit/adapters/storage/test_json_codec_tree.lua`), and
`tests/meta/lua_safety/test_json_decode_through_codec.lua` ratchets the remaining direct
calls, which only read what they decode.

### project-hs-modal-dialog-parks-the-logger-pump

`hs.dialog.blockAlert`, `textPrompt`, `chooseFileOrFolder` and a synchronous
`hs.osascript` `display dialog` park the main run loop: timers stop, so the
native logger transport can neither resend nor read its ACK. Its stall
budget used wall time, so a user reading a dialog for thirty seconds made the
driver exit ("did not ACK retained sequence 128 within the 30000 ms stall
budget (3 sends)"). The budget now counts running pump time, a parked gap
counting at most `ack_retry_cap_ms` (`transport-parked-run-loop`). Any other
wall-clock watchdog that runs on hs.timer has the same exposure: the Karabiner
lease ACK timeout fenced the live lease ("timeout waiting for PONG 159") until
a timeout that fires late got one grace of running time to read the pipe
(`lease-parked-run-loop`).

### project-hs-task-output-is-read-in-default-mode-only

Hammerspoon 1.1.1 reads a streaming `hs.task` with `readInBackgroundAndNotify`
(`libtask.m`), whose notification runs in the default run loop mode only,
while `hs.timer` (`NSRunLoopCommonModes`) and the task's termination handler
(main dispatch queue) run in every mode. During an open menubar menu (event
tracking) or a modal panel, a deadline therefore fires on time while the
child's answer sits unread, and a completion can arrive before the last
streamed chunk, which `shell_runner` then drops: issue #100 lost seven leases
"0.00 s late" with no worker stderr at all. Never judge a streaming child
silent from a timer alone; prove a read turn with
`adapters/task_output_turn.lua` (a `/bin/cat` echo) first, as the lease ACK
deadlines do (`lease-output-turn`). Writing stdin works in every mode, so while
that probe is pending the lease writes keepalive PINGs (at the deadline, then
every heartbeat tick, never two within the outer's 2.5 s command budget: the
outer exits 74 on an overlapping PING) and consumes their PONGs without a
deadline; without them the worker's inner fenced itself after 17.5 s of an
open menu (`lease-output-keepalive`, pinned against the Swift budgets in
`test_native_lease_budget_parity.lua`). An answer read after a failure is
logged as late, not missing.

### project-hs-webview-becomes-key-only-with-text-entry

A Hammerspoon webview window becomes key only while it allows text entry
(`libwebview.m`: `canBecomeKeyWindow` returns `allowKeyboardEntry`, off by
default). A window that cannot become key does not activate the app when
clicked, so a window of the inactive Hammerspoon app stays behind the user's
windows however often it is clicked: the error window "never came to the
front". Every window allows text entry; the factory refuses
`allow_text_entry` and `tests/meta/runloop/test_windows_become_key.lua` forbids
turning it off (`windows-become-key`).

### project-capsword-json-is-a-frozen-anchor

`platform/remap/data/capsword.json` is the rule every released graph was built
from, so the legacy-graph proofs (`legacy_static_anchors.capsword`,
`legacy_release_fixtures`) read it whole. The deployed CapsWord rule is that
file minus the exits [shortcuts.caps_word] owns (Space, Enter, Tab, the
Ergopti "." and "," keys g and v, the two clicks): `platform/remap/watchers.lua`
ends CapsWord on the typed character and the checked pointer kind instead,
switching CapsLock off synchronously for a keystroke cause. Action: change
CapsWord exits in the generator's setting-exit filter or in the watcher, never
in capsword.json, and re-pin `TAP_HOLDS_ON_PINS` only after proving the rules
after the first one digest unchanged.

### project-karabiner-cli-reads-no-user-variables

`karabiner_cli` can set variables (`--set-variables`) but has no option to
read one: the CapsWord pointer probe called `--get-variable`, and cxxopts
answers any unknown option with exit status 2 ("error parsing options"). Its
real option list is in Karabiner-Elements `src/bin/cli/src/main.cpp`; check
it before passing a new flag. User variables are only visible in
EventViewer, not to the CLI. The probe is gone: a pointer event cancels only a
CapsWord the driver activated or saw through its Karabiner control signal
(`KeVariables.supersede_capsword_activation`); never reintroduce a variable read.

### project-hs-native-task-lifecycle-contract

Task construction, start, callback, timeout, and teardown are distinct failure
boundaries. Central lifecycle adapters own all of them.

### project-hs-process-lifecycle-transaction

Publish a watcher or process only after activation commits. A teardown refusal
leaves cleanup debt whose callbacks must already be inert.

Darwin `ps` exposes the command path through `comm`; it is not the executable
basename that Linux fixtures commonly supply. Use `ucomm` for existing Python
name guards in MLX cleanup, and keep the independent argument and PID/PGID
guards. Exercise the emitted shell with recorded signals, including paths
with spaces and non-Python executables under a directory named `python`.

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

### project-hs-physical-fence-pairs-key-ups

`SyntheticInput.claim_physical_fence` consumes a physical event that arrives
behind queued output and replays it after. A key-up is held back only while
its own key-down still waits unposted in that FIFO: holding the release of a
key whose press already reached the application kept it down for the length of
the expansion (the press-and-hold popup on a plain tap). A physical event whose
callback is `STALE_PHYSICAL_EVENT_MS` late (`adapters/event_clock.lua`
lateness: age minus the smallest age of the last 32 events, so a constant clock
offset cancels) is never consumed, replayed or answered: macOS stops waiting
for a tap that holds an event too long and delivers it without the tap, and a
copy would type it twice. The keymap passes such a key-down untouched and
restarts its buffer; the tap-key, script-control and modifier-injector taps pass
it too (`KeyEventHealth.passes_late_event`, threshold
`EventClock.STALE_PHYSICAL_EVENT_MS`), so no action runs on a key the
application already has. Action: a new fence, emission path or physical-key tap
must keep both rules
(`key-up-fence-pairing`, `stale-physical-event`).

### project-hs-key-taps-never-ask-accessibility

Every Accessibility call runs on the main thread with the event taps, and
macOS lets a call to a hung application wait six seconds. Boot sets one
process-wide messaging timeout (`AccessibilityPermission.bound_messaging_timeout`,
1 s, before the first input owner), and code reached from a key tap reads the
typing application from NSWorkspace (`hs.application.frontmostApplication`),
never `hs.window.focusedWindow()` (`text_sender.focusedAppIdentity`, called on
every deleting expansion and every Return, Cmd+A, Cmd+L). Action: no new AX read
inside a tap callback; an off-tap read relies on the timeout, not on luck.

### project-hs-key-event-health-counters

`infra/key_event_health.lua` counts per session what the keymap taps see:
key-ups without key-down, key-downs whose key-up was lost, keys stuck 3 s,
character keys held 500 ms or more (with autorepeats and the rule switch they
crossed: lease fence, karabiner.json reload, tap outage), late callbacks, stale
keys passed untouched and lease failures by kind. Every line carries the
session totals and no key code or character. Read those lines first in a
macOS report of swallowed keys or an unasked accent popup: a long hold of
macOS's own stamps with no late callback points upstream (Karabiner), a late
key-up points at the main thread. The same totals are the `key_*` counts of
the diagnostics report's input section (`collect_input`; schema, projection and
`healthcheck.field.key_*` labels). A Karabiner lease failure is also held by the
error window for `RECOVERY_GRACE_SEC` (`ui/error_dialog`) and dropped when the
lease controller reports a running (`active`) generation at its end: an ERROR
that the driver fixed by itself opens no window, it stays in the log.

### project-hs-native-eventtap-disable-recovery

Hammerspoon consumes CoreGraphics tap-disable notifications in native code and
re-enables the tap before Lua callbacks run. Lua handlers or disable counters are
unreachable false fixes. Keep the keymap, keystats, and script-control watchdogs
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
graph, so a paused or revoked driver never produces it. Its pair F19 marks the
layer's exit: inserted right before every `layer_active = 0` write, as F20
precedes the `= 1` one, never as the last `to` entry, which Karabiner holds
until the key is released and which then takes the place of the first key's
held modifiers after a chord. Watchers that ignore F20 by keycode (the tooltip
dismiss lists) must ignore F19 too.

### project-hs-layer-wheel-is-a-derived-owner

Karabiner takes no wheel input, so the navigation layer's wheel bindings
(layers.toml `WheelUp`/`WheelDown`/…, volume by default) run in Hammerspoon:
`NavLayer.wheel_slots` turns them into strokes, and
`system.bind_layer_wheel` consumes a turn only between the F20 and F19
sentinels, in a bound direction. The owner (`layer_wheel` in
`modules/shortcuts/bindings.lua`) is derived from layers.toml like `tap_keys`
from its assignments: no `[shortcuts.keys]` preference, nothing bound for a
layer without a wheel binding, and every layers.toml writer calls
`reconcile_layer_wheel` (a hand edit applies at the next start). It replaced the
Layer + Scroll shortcut, whose held F19 no generated rule emitted any more.

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

### project-macos-script-chords-are-karabiner-rules-per-slot

A sentinel cannot be given back: once Karabiner turned right Option + Return
into F13, the application never sees the chord. The generator therefore emits
a script chord's sentinel rule only for a slot that runs an action
(`platform/remap/script_chord_rules.lua`, the paused rules only for the
paused actions), reading the plan from `script_control.karabiner_chords` at
every build (`set_script_chords_source`); `script_control` asks for one
coalesced regeneration when the plan changes. The three historical rules stay
in the graph until the legacy capture, which must keep describing what older
releases deployed, then the current rules replace them. The Delete slot's
sentinel is F18, shared with keep-awake's own keystroke, which carries
Ergopti's provenance and never passes a sentinel check; its rule also reads
fn + Backspace and comes first. Action: never emit a sentinel rule for a slot
that runs nothing, and re-pin the generator graph tests for an intended change.

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
VirtualHID processes. `tests/meta/architecture/test_karabiner_stock_process_isolation.lua`
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
the switch is off. OFF and « Remove Ergopti from Karabiner » share the exact
retirement owner and invoke `--unregister-remap-guardian` after aggregate
STOPPED. The preference remains on until the exact child settles with
`unregistered\n`; a refused or partially completed native removal recovers a
fresh READY lease before releasing the previous enabled state. Already-off
removal keeps the preference off on refusal. Cancellation of registration
retains its raw task until `onSettled`, so an accepted pending SIGTERM cannot
register after an acknowledged OFF. New activation, observations and registration
are fenced while the retained unregister child owns its transition.

The native unregister role validates the launcher vnode before effects, waits
for durable record retirement, removes only an exact own legacy plist, checks
SMAppService status after unregistering and confirms singleton exit plus the
exact launchctl missing-service status 113. It never holds activation.lock while
calling unregister or bootout: the guardian itself needs that lock to drain.
The existing hosted `helper_registration` scenario exercises the actual signed
helper, wrong-inode refusal with the live job retained, removal and idempotent
removal. Its receipt keeps primary and cleanup failures and refuses unknown
launchctl statuses. Lua fixtures and the Python receipt judge do not substitute
for that native qualification.
Turning it off removes only marked rules by byte-span surgery proven by decoded
equality; never re-serialize `karabiner.json`, which would rewrite personal
rules.

### project-hs-layout-name-forms

One macOS layout has two names: `hs.keycodes.currentLayout()` returns its
localised name (`Ergopti+`, `Français`), `defaults read com.apple.HIToolbox
AppleSelectedInputSources` its KeyboardLayout Name (`Ergopti_v2_2_2_plus`,
`French`), quoted only when not purely alphanumeric. The remap input-source
watcher seeded its baseline with the first and compared the poll's second
with it. Every boot of an Ergopti layout therefore reported a layout change at
the first poll, 2 s after the remap init. When that change landed during the
boot's lease activation, it fenced the RESUME in flight, and dev.155 opened
the error window with « prepared lease RESUME failed: lease-stopping ». Its
parser also missed the bare form, so the poll never resolved ABC or French.
Compare a layout name only with a name of its own form
(`platform/remap/watchers.lua`). The E2E world boots that user on the
`ergopti_layout_slow_worker` machine. Windows compares HKL values and Linux
reads the keymap only at start and on the menu's switch, so neither driver
has this class.

### project-hs-lease-stop-supersedes-activation

An accepted `LeaseController` Stop answers the READY wait and the pause or
resume command it supersedes with `LeaseContract.STOPPED_BEFORE_READY` and
`COMMAND_SUPERSEDED_BY_STOP`. The remap coordinator fences its own activation
in flight on a layout change, a reload or a disable, and the Stop's requester
logs why. The superseded activation, and the Enable or Resume transaction it
ends, log at INFO (`LeaseContract.is_superseded_by_stop`); the activation
requests no second fence. Every other activation failure stays an ERROR. The
retained layout regeneration waits for STOPPED, then starts a fresh token.
The boot E2E machines `layout_switch_during_resume` and `reload_during_resume`
pin both paths. The lease controller state is per Lua VM: a previous
process's worker fences its own tokens on stdin EOF and cannot answer
« lease-stopping » to a new boot.

### project-hs-karabiner-legacy-conflicts-are-offered-for-removal

Untagged rules carrying a historical ErgoptiPlus signature
(`legacy_ergopti_signature_reasons`) that no released block proves make the
merge refuse every deploy; it must keep refusing, since such a rule may be
personal. The refusal is data (`merge_and_deploy_config`'s fourth return, kind
`legacy_conflicts`). The remap bridge keeps that set with the build's legacy
context and offers `ui.legacy_rules_cleanup` once per launch per set from a
zero-delay timer, since the refusal happens inside the lease transaction. The
Tap-Hold menu row reopens it while pending. `ManagedRuleRemoval.remove_legacy_rules`
removes exactly what `Generator.find_legacy_signature_conflicts` (the merge's
own classifier) reports: never give it a criterion of its own. It writes a
verified `karabiner.json.ergoptiplus-legacy-<time>-<n>.bak` first, then
publishes by byte surgery over the exact bytes it read. A merge refusal writes
nothing yet still goes through `contain_ambiguous_deploy_failure`, which fences
an ACTIVE generation; tests of a refused deploy start from a PREPARED lease.

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

Never construct `hs.window.filter` anywhere in the driver. Its first instantiation
enumerates every window of every app on the main thread: lazily built on the
first browser activation it still froze Hammerspoon for 4.8 s and 3.3 s and cost
the Karabiner lease (#95). Bind `app:newWatcher` and `win:newWatcher` to the one
application and window that matter, as the keystats browser watchers and the
keymap ignored-window watchers do.

### project-hs-application-get-scans-every-window

`hs.application.get(name)` is `find(name, false, true)`: when no running
application matches, it calls `hs.window.find(name)`, i.e.
`hs.window.allWindows()`, an Accessibility read of every window of every
application on the main thread with six seconds allowed per application.
The tell in a log is the console line "Some applications have alternate
names…", which `find()` prints (once per Lua state) just before that
fallback. The keystats's per-flush category lookup of a quit application
froze Hammerspoon 13.4 s and cost the Karabiner lease (#99). Resolve
applications through `adapters/running_application.lua` (exact name, bundle
identifier, PID); `tests/meta/runloop/test_app_lookup_never_scans_windows.lua`
admits no new direct `get`/`find` call. A timer callback that holds the main
thread over a second is now named by the runtime capture ("held the main
thread for N ms"): read that line first when taps restart or a lease fences.

### project-hs-hswindow-scans-every-window

`webview:hswindow()` and `hs.console.hswindow()` push the native window number
and call `hs.window.windowForID`, an alias of `hs.window.get`, i.e. `find()`
over `hs.window.allWindows()`: every window of every application, on the main
thread. Each webview open paid 2.8 s to 3.2 s on macOS 26 (#100), and the focus
retry repeated it. Resolve webview and console windows through
`adapters/own_window.lua`, which records that number with `windowForID`
swapped for the synchronous call and then matches it among this process's own
windows (by PID). `tests/meta/runloop/test_app_lookup_never_scans_windows.lua`
admits no other `hswindow()` caller and ratchets every global enumeration.

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

### project-hs-synthetic-cmd-tab-never-switches

A posted Cmd+Tab (`hs.eventtap.keyStroke`, a Tab event carrying only the
Command flag) does not switch applications: on the maintainer's Mac (2026-09)
one gesture did nothing and a quick second one left the switcher open. The
switcher follows the Command key's own press and release, which the posted
keystroke never sends; Karabiner's `cmd_tab` works because its virtual keyboard
presses and releases Command. Action: switch applications from Lua
(`modules/gestures/app_switch.lua`, window reads in
`adapters/window_manager.lua`), never by posting Cmd+Tab or Cmd+Shift+Tab.

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

### project-hs-click-drag-is-not-a-gesture

A click-drag text selection (one finger pressing the trackpad, another
sliding, or a drag after tap to click) reaches the touch frames as two or more
moving contacts. Until 2026-09 the engine fired the two-finger swipe action
(`arrow_up` in the recommended preset) or a three-finger tap mid-drag, and the
selection was lost. `modules/gestures/engine.lua` `process_frame` now hands
every frame from the first one with a button held
(`adapters/mouse_control.lua` `any_button_down`) to the last lift to the
pointer. Action: keep that guard ahead of any gesture state change, and never
subscribe a gesture tap to button or drag events.

## Clipboard, files, and privacy

### project-hs-clipboard-transaction-ownership

Clipboard borrowers snapshot all types before mutation and keep ownership until
exact restoration commits. Failed restoration remains cleanup debt.

### project-hs-wrap-selection-clipboard-ownership

A wrap-selection key is consumed only after paste and full clipboard restoration
are both owned; partial success must not lose the user's clipboard.

### project-hs-keystats-append-commit

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
tasks and never wait. The keystats process-exit stop skips the final ingest,
and the MLX shutdown skips the listener proof when this Lua generation owns no
server. User quits go through `TerminationCoordinator.request_user_exit`. It
arms `user_quit_deadline_ms` before the lease fence, so a stuck async stage or a
failed fence force-exits with status 70 and logs the pending stage.
`tests/meta/shutdown/test_quit_teardown_never_blocks.lua` scans every teardown step's
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
enable gate may trigger warmup side effects, the Ollama daemon included:
`modules/llm/init.lua` starts it from `set_backend` or auto-detection only
through `ollama_start_admitted()`, the gate on and `ollama_binary.resolve()`
finding an executable. `manifest_reader` resolves the default of
`llm.models.selected` through `backend_detector.auto_default()`, Ollama on
x86_64, so an Intel Mac restores Ollama from any config.toml without a selected
backend. Since Ollama stopped shipping, `set_backend` starting it with the AI
off logged "Ollama server executable resolution did not commit" at every Intel
boot (the error window); arm64 boots restore MLX and never showed it. A missing
Ollama with the AI on is the boot notice's and the unreachable offer's, never a
start. `tests/e2e/boot` boots every scenario on arm64 and x86_64 at once
(`world.ARCHITECTURES`); keep both, and extend
`test_backend_ollama_start_gate.lua` for a new daemon-start caller.

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
`modules/keystats/physical_accounting_mode.lua` is the one owner of the
answer: the event tap (keyDown `kc`, flagsChanged modifier events) and the
ledger credit only under the legacy source; a selected stream makes both
silent, and a stream without an admitted complete capture is a gap, not a
fallback. Gate any new physical writer on it, and keep
`test_hs274_duplicate_count_*.lua` and `test_hs274_physical_collision.lua` green:
they pin the legacy double count and fail for either the `and nil or` idiom or
global suppression.

### project-hs-metrics-paced-projection

The typing dashboard never reads `db.sqlite` from a WebView or poller
callback. Its projections run as `infra.paced_job` coroutines through the
optional pacer of `sqlite_reader`, which drains each statement before handing
out rows: the cache uses `journal_mode = DELETE`, so a reader statement held
across a pause would make the ingest COMMIT fail with `SQLITE_BUSY`. An
all-time `GROUP BY` sorts every row in its first step, so paced n-gram reads go
one day per statement. Past days are reused only while
`sqlite_reader.fingerprint` of their watermark is unchanged; `ngram_chars`
witnesses the bigram to heptagram tables, so any new writer of those tables
must also credit `ngram_chars` on the same day or join the fingerprint.

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

### project-hs-webview-close-rewraps-native-userdata

In packaged Hammerspoon 1.1.1, `deleteOnClose(true)` can recurse from
`windowWillClose` into `userdata_gc`: GC clears `udRef` before closing, and
`HSWebViewWindow_toLua` wraps the same native window again. A guard against GC
on the same consumed userdata does not prevent `C stack overflow`. Keep native
automatic GC disabled and use the factory's `ui/webview_close_owner.lua` to
retire user-closed windows outside their Cocoa notification. Check native
consumption separately from business close callbacks. These failures can appear
only in process `stderr` while `hs.console.getConsole()` is empty; qualify both
native output streams as well as the console and exact process retirement.
Disarming the parent does not disarm WebKit children: `allowNewWindows`
defaults to true, while `createWebViewWithConfiguration` allocates a child
with `deleteOnClose` true and copies the parent's `windowCallback`. An unowned
child can therefore notify its parent's owner and enter recursive GC. Factory
windows must commit `allowNewWindows(false)` before owner hooks or HTML;
rejecting a child in `policyCallback` happens after its native allocation.

The public `webview:delete()` wrapper normalizes an omitted delay to zero;
for a visible window it still schedules a fade. Its close notification precedes
native userdata consumption. Latch the exact request before calling delete and
never repeat an uncertain request while its metatable remains. Observe retirement
outside the notification, and release bridge callbacks only after userdata
consumption and the exact observation timer's stop acknowledgement. A callback
delivery alone does not prove that its timer retired.
Do not require another closing notification after an accepted delete: the
window may already be closed when native destruction runs. Start the owned
observation from the accepted request and retain it if delivery precedes
consumption, without issuing another delete. A failed native diagnostic must
preserve the individual measured retirement facts instead of reporting only a
timeout. Match exception classes as complete tokens so a startup source name
such as `SentryCrashMonitor_NSException` is not mistaken for a thrown exception.

WebView GC does not remove the shared user-content controller's script handlers
or release its Lua callback reference. A successful `setCallback(nil)` detaches
that callback; it does not prove controller userdata GC. Reusing a controller
requires an exact session lease: revoke its receiver before detaching, retain
failed detach as debt that blocks a successor, and check native `message.name`
and `message.webView` before reading the body. A body field cannot establish
which native window sent a message.

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

Since 2026-09-30 the Lua consumer admits only baseline version 2: each device row
declares `keyboard_type` (`ansi`, `iso` or `jis` for a device with keyboard-page
elements, `none` otherwise) and each key row its usage `page`, so fn/globe (Apple
vendor pages 0x00FF and 0xFF01) and Consumer-page keys are tracked like keyboard
keys (`physical_wire.lua` `KEY_PAGES`). The C++ pages writer, the native attach
path and the Python fixture reader still speak version 1, which the consumer
refuses: align all three in WP4 before any native run can admit a capture. A
press the key-identity policy cannot attribute is tallied in the receiver's
`uncounted()` coverage, never a reason to retire the capture.

### project-hs-physical-key-identity

The stream credits the macOS virtual keycode Quartz would have reported for the
same physical key, so history and the heatmap keep one identity:
`modules/keystats/physical_key_identity.lua` resolves through
`_generated/hid_key_identity.lua`, generated from the registry's `hs` and
`macos_iso.hs` and from `_shared/data/keycodes/hid_usages.json`
(`npm run codegen:hid-key-identity:hs`). Keep HID data out of
`physical_keys.json`: Windows parses the registry at boot whenever a
layers.toml exists, and only macOS needs it. A usage names a position by the
USB HID usage tables, so only 0x35 (left of 1) and 0x64 (left of Z) depend on
the device's keyboard type (the ISO swap). Further usages real keyboards send
for a known key are `aliases` there (Non-US # 0x32 is Backslash, kVK 42, as on
Linux), and keys no layer can bind (F13 to F20, PrintScreen/ScrollLock/Pause as
F13 to F15, keypad =, the JIS Yen, Ro, Eisu, Kana and keypad comma) are its
`unregistered` keys with the macOS keycode; add a usage there before it can
reach `uncounted()`. On a JIS device every JIS key resolves, but 0x35 and 0x64
stay uncounted with `unsupported_keyboard_type`: the registry has no JIS form
and what macOS reports for those two positions on JIS is unverified. That raw
usages follow
the standard positions on Apple ISO hardware, while Karabiner rules name the key
left of 1 `non_us_backslash` there, is an assumption: check it on the
maintainer's internal keyboard in WP9 by comparing the stream's usage with the
Quartz keycode. fn/globe resolves to `keycodes.FUNCTION` (63). Media keys the
registry lacks (play/pause, track skips, brightness) have no macOS virtual
keycode and are tallied uncounted; counting them, as the maintainer decided,
needs an identity chosen together with the event-tap path, which sees them as
system-defined events rather than keycodes.

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

### project-karabiner-saved-timer-authority

Karabiner's `to_if_held_down` runs from a saved manipulation and does not re-check
its original `from` conditions at the threshold. Put current generation-mode
and revocation conditions on the timed output events themselves, so a queued
hold cannot press a modifier after pause or shutdown. The v16.0.0 callback also
checks the unfiltered output's final key to decide whether to restore previously
held modifiers; retain the existing never-posted trailer for timed modifier
holds as well as immediate ones. Keep historical recognition graphs on their
original immediate-hold recipe rather than deriving them from modern timer rules.

## Packaging, AppleEvents, and native builds

### project-appleevent-status-codes

For AppleEvents to the embedded Hammerspoon, only -1744 (consent required) and
-1743 (consent denied) in `NSOSStatusErrorDomain` speak about consent; -10004 is
a privilege error, -600 a port discovery failure, and a signal 11 is a crash,
not a refusal. A hosted runner can never answer the Automation consent dialog,
so Brew, Shortcuts and launch AppleEvent acceptance needs a real Mac or an
explicit opt-in lane. In JXA, integer getters on `NSError` and `NSNumber` are
bridged as strings: compare them as strings.

### project-macos-native-build-grammar-traps

The Seatbelt sandbox network grammar accepts the host `localhost` or `*` only,
not `127.0.0.1:*`. Carbon `RunApplicationEventLoop` is 32-bit only: use
`ReceiveNextEvent` with `AEProcessEvent`. `codesign --display` prints the
designated requirement as a commented `# designated => ` record, so a parser
must accept the bare and the commented prefix. In Swift, an unparenthesised cast
in a `case` pattern parses as an as-pattern, `lipo -verify_arch` is greedy (put
the file first), and an Apple SSL server-policy leaf certificate needs the
serverAuth EKU. A native Ollama build needs an explicit macOS SDK and a writable
Go cache, and compiles to a fresh file before replacing the extracted CLI.

### project-macos-release-archive-preference

The macOS updater prefers the `.app.tar.xz` asset, accepts the ZIP only when the
preferred asset is absent, and refuses a malformed or ambiguous preferred
archive; appcast dates come from the explicit source revision, never the clock.
The Homebrew cask process matcher must treat the bundle's dot literally (it once
matched foreign names such as `ErgoptiPlusXapp`). Stable `ergoptiplus` and
`ergoptiplus@dev` are separate casks: switching is uninstall then install, and
the configuration is kept.

### project-macos-missing-acl-is-an-empty-acl

Apple's Libc returns NULL with ENOENT from `acl_get_fd_np` for a file that has
no extended ACL. Reading that as a refusal made every owned-runtime check fail
in milliseconds with "protection"; treat it as the empty ACL, and refuse only
other errors.

### project-macos-lua-tests-run-on-lua54

The Hammerspoon test harness needs Lua 5.4 (`table.pack`, native bitwise
operators); running the macOS tests under LuaJIT fails for reasons unrelated to
the code under test. The Mac version shown to users comes from the outer
launcher plist; the shared build stamp names the commit.

### project-karabiner-lease-exit-73-names-its-cause

Exit 73 is any supervision loss of the lease worker (inner silence fence,
private command deadline, guardian loss, socket error). Since 8d66fca660 the
worker writes its cause to stderr, which the lease controller logs as
`lease worker: lease lost …`, and reports every private round trip of 1 s or
more. The worker, guardian and Lua deadlines are pinned against each other by
`tests/meta/architecture/test_native_lease_budget_parity.lua`: change one only
with the others. Lua's READY deadline also covers two launches of the
launcher executable (outer, then inner), about 2 s each on a loaded Mac
(#99). When the driver fails a lease on an ACK deadline it logs the wait and
the timer's lateness (late means its own run loop was held), the outer
reports "Hammerspoon closed its input without STOP" with the last private
command, and the worker's exit is logged afterwards: an on-time deadline with
an unanswered command names a slow worker, an answered one a PING that never
left Hammerspoon. Configuration > Ergopti uses Karabiner > Off stays the
workaround that preserves personal Karabiner rules. Do not infer guardian
retirement from a signal, a missing handle or a hidden dialog.

### project-macos-writer-lease-is-advisory

The macOS configuration writer rechecks bytes under its canonical writer lease
before a conditional unlink, but the lease is advisory: an editor that does not
cooperate can still replace the path between compare and unlink. Its
capabilities are process-local, not a journal that survives a crash or VM exit.

### project-macos-embedded-runtime-starts-without-launcher

macOS can start the embedded `com.ergoptiplus.app.hammerspoon` by itself,
without the launcher's environment, beside the launcher's own child: issue
#99 (09:40:03, 1.0.4 update relaunch) and #100 (10:28:12, launcher PID 1051,
right after a reboot) both show two "session opened" banners in the same
millisecond, one with no `ERGOPTI_*` key and a config dir from the default
`~/.config/ergopti_plus`. No Ergopti code launches that bundle without the
environment, so treat session restore (loginwindow reopening every running
app, the nested one included) as the trigger until a launcher.log proves
otherwise. `infra/instance_admission.lua` therefore runs before any settings
write, timer or path resolution and quits such a stray runtime silently; a
stock Hammerspoon pointed at Ergopti is refused without `os.exit`, which would
quit the user's application. The launcher holds a per-user flock
(`LauncherInstanceOwnership.swift`): `LSMultipleInstancesProhibited` only
covers other user sessions, not `open -n`, a direct exec or a racing update
relaunch. A modal `hs.dialog.blockAlert` keeps the run loop turning, so any
producer armed at require time (the KC ledger bridge) must be stopped before a
fatal dialog.
