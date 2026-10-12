<!-- docs/handovers/2026-10-12-dev-consolidation/README.md -->

# Dev consolidation and macOS issue 94

## Recoverable source

Continue from `origin/dev`, not a container-specific checkout. The maintainer
explicitly approved exceptional history merges: original groups 2/4/7 delivery
`97f4e08fff32c43933c09e3d0a7b83abde8b4c9e`, previous dev
`d98e4f1fe83bec44dd60756c38868c073752ac9a`, and published main
`63cf3d005d371edb4e4093a906da276ced487182` must all be ancestors of the final
handover commit. Use `git log` for its exact SHA; the handover does not depend
on a local recovery ref or temporary logs. Develop on dev. Advance main only
by fast-forward for a subsequently authorized release.

The existing [groups 2/4/7 handover](../2026-10-11-groups-247/README.md) retains
its historical receipts and native checklists. Its earlier macOS path-override
instructions describe that checkpoint, not a green full-suite environment:
independent HOME/bootstrap matrices must run without `ERGOPTI_PATHS_FILE` or a
source-adjacent `paths.toml`. Preserve the inherited HOME. Never change source
assertions to accommodate a cloud path configuration.

## Software changes and evidence boundaries

Issue [94](https://github.com/adrienm7/ergopti/issues/94) was retrieved. Its body
contains three attached diagnostic files but no further textual reproduction.
Their download host initially refused access. The coordinating session later
transferred all three complete sanitized files privately; gzip, JSON and each
file hash were verified before reading. No private diagnostics are committed.
The maintainer separately confirmed that tap-hold edits use the real menu and
the ISO inversion occurs during typing.

- Tap-hold: a live setter previously saved during a transitional/unavailable
  lease or accepted Stop, then regeneration refused. The preflight now refuses
  before persistence and uses the existing visible logger notification. Normal
  ACTIVE menu changes regenerate without reload; disabled/paused settings-only
  changes remain supported. Genuine original: 15 passed, 7 failed. Corrected:
  22 passed, zero failed. This demonstrates a matching software path; native
  receiving must determine whether it fully resolves the reported symptom.
- ISO: the generated keyboard forced ANSI while the shipped registered layout
  uses ISO Carbon conventions. Read one registry snapshot, capture its form
  once for logical actions and the virtual keyboard, and selectively replace
  only that field in an existing profile. Keep physical `from` and virtual
  `to` projections separate. Independent shipped XML/HID expectations exposed
  the wrong character with the original generator. Six focused modules pass
  136/136. The coordinator original lacks/accepts invalid form: 22 passed,
  4 failed; corrected 26/26. Fourteen coordinator/consumer module invocations
  pass 142/142 (these totals overlap; do not add them).
- Selection wrapping: real text and SyntheticInput owners previously restored
  the clipboard before queued Cmd+V completed. Keep clipboard custody through
  that producer's exact terminal completion and the canonical 150 ms grace.
  Pause retains cleanup at the fixed deadline; repeated cancellation cannot
  extend it or erase an accepted output. All ten new broker cases fail with
  the genuine original owner and pass with the correction. Seven focused
  modules pass 106/106, retaining the original assertions.

These are production Lua checks with explicit native collaborator doubles,
source contracts and independent corpora executed on Linux. They do not qualify
Hammerspoon/Quartz, Karabiner consumption, macOS application paste or devices.
No Windows/Linux platform mapping was globally swapped. Shared layout assets,
synthetic input contracts and canonical timing remain unchanged.

The history merge also preserves both historical test cohorts and the current
Windows TOML scanner fix. Windows AI enable custody uses the config-aware
writer/builder pair and encodes its already-BOM-bearing content exactly once.
No native AHK execution is implied by BOM, syntax or source checks.

## Native macOS receiving

Prerequisites: install/build this exact source on macOS; use the supported
launcher/Hammerspoon and authorized Karabiner driver, Accessibility and Input
Monitoring. Save personal configuration and Karabiner profile bytes before
beginning. Use a private user account/configuration where possible. Preserve
foreign rules, profiles, clipboard and externally owned services. Neither a
forced private flag nor a mocked receipt constitutes native receiving.

A native macOS VM can execute software/menu/file/lifecycle checks:

```sh
cd /path/to/ergopti
npm ci
npm run test:hs
npm run test:hs:e2e
hs -c 'return require("modules.keymap.layout").keyboard_form()'
hs -c 'local s=require("modules.keymap.layout_registry").snapshot(); return hs.json.encode({active=s.active,active_error=s.active_error})'
hs -c 'return hs.json.encode({code10=hs.keycodes.map[10],code50=hs.keycodes.map[50]})'
hs -c 'local f=assert(io.open(os.getenv("HOME").."/.config/karabiner/karabiner.json","rb")); local c=hs.json.decode(f:read("*a")); f:close(); for _,p in ipairs(c.profiles or {}) do if p.selected then return hs.json.encode(p.virtual_hid_keyboard) end end; error("no selected profile")'
```

The `hs` commands observe the already initialized production configuration;
they do not initialize it. A bundled runtime without the CLI can use its actual
Hammerspoon console for the same Lua expressions.

1. With remap ACTIVE, change Left Shift hold and tap through the ErgoptiPlus
   menu. Expect the new saved/getter values and actual Karabiner rules/behavior
   without reload or process restart. During a naturally occurring recovery,
   pause/resume, fence or Stop transition, expect a visible refusal, old exact
   config bytes and no candidate deployment. Retry when ACTIVE. Deliberate
   disabled/script-paused edits must save and deploy on normal enable/resume.
2. Select standard Ergopti. Expect registered form `iso`, no active error,
   selected virtual keyboard type `iso`, Carbon10 `$`, Carbon50 `ê`; personal
   country code/fields and other profiles remain identical. Repeat cold startup
   with localized Ergopti/Ergopti+ source names and switch to a registered ANSI
   layout; expect its corresponding virtual form after normal regeneration.
3. In TextEdit and an installed browser edit field, select ordinary text and
   type each configured wrapping symbol. Expect one pair around the selection,
   no insertion of the previous clipboard, and the original clipboard restored
   after completion. Repeat under queued synthetic output and a normal pause;
   cancellation before output must restore without a paste. Retain logs and
   actual application output. An app with unreadable selection must retain the
   existing pass-through policy rather than copying an entire line.

A **physical ISO keyboard** is required for the reported typing acceptance:
with standard Ergopti, a blank TextEdit document, modifiers released and normal
layer inactive, press the extra key left of Z and the key left of 1 separately.
Expect `ê`, then `$`, including after restart/source switching. Record real
Karabiner EventViewer usages 0x64 and 0x35 and virtual keyboard form; repeat
configured navigation-layer routes. A VM keyboard channel or Quartz injection
cannot qualify physical usages, real hooks or simultaneous device input.
No display/trackpad acceptance is required for these three fixes.

## Other groups and ownership

Follow the committed executable native checklists:

- [Hotstrings](../2026-10-11-groups-247/group2-native-execution.md).
- [Windows managed AI](../2026-10-11-groups-247/group4-windows-execution.md).
- [macOS managed AI](../2026-10-11-groups-247/group4-macos-execution.md).
- [Windows input and rendering](../2026-10-11-groups-247/group7-native-execution.md).

Windows process/files/TCP/GUI/UIA cases can run in a native VM. Physical hook
ordering, typing, keyboard modifiers, display/DPI clarity, trackpad gestures
and user-installed application behavior need their actual device/environment.
Item 49 still requires native contract observation followed by real software
handler/observer cohort migration. Its production cohort stays disabled and its
DLL/manifest stale until the official MSVC generator and native receiving.
`NATIVE_PRODUCTION_QUALIFIED=False` stays unchanged.

Existing-path tests have not been moved. The publication/test-optimization
owner retains `codex/ci-test-performance-20261012`, its nine feature inventories
and runner/workflow reorganization. Only historical main/dev workflow conflicts
are reconciled here, preserving both existing protocols. New macOS tests use
the existing Lua discovery runner; no new JS CHECKS entry is needed for them.
The historical groups CHECKS additions remain in the legacy runner for the
owner to enroll exactly once during later migration.

The final commit requests `[skip ci]` to avoid the maintainer's expensive push
run. This is neither a workflow-policy change nor native/hosted qualification.
No release is created by this handover; the published stable remains v1.0.1.

## Final container verification

This first checkpoint uses source `d59feeab4fae6a12b4d4970f0c70c43809800d46`.
The historical source ancestors and every original group commit are preserved.
The final SHA is the documentation commit published on dev; resolve it through
Git rather than relying on a container-local ref. Main remains unchanged.

Latest upstream `dev 33c4152a99836445387c8a0eac1166cf8918abed` is preserved by
merge `d734f24c70952fa89bfd848a503172103071d3c5`. The original and incoming test
cohorts remain complete: actual portable HTTP receiving facts pass 172/172,
archive acceptance 220/220 and the clock source controls 32/32. Homebrew and
managed Ollama protocol gates pass. Incoming Linux diagnostic boundary/flush/
window controls pass 10/10, 7/7 and 13/13. The Windows diagnostic source generator
updates only its 21 source hashes from that immutable merge; its 22/22 source
controls pass with the original independent cohort oracle unchanged. These are
portable controls, not native macOS/Windows receiving. No timeout or assertion
was relaxed while combining the cohorts.

| Gate                                     | Actual result                                                                                                         | Evidence boundary                                                                                                                                                         |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pinned macOS full Lua unit/meta runner   | 18,858 passed, 0 failed; 1,576 modules; exit 0                                                                        | Production Lua and explicit native doubles on Linux, including mandatory copied-application E2E corpus; no Darwin receiving                                               |
| Pinned Linux full LuaJIT units           | 13,413 passed, 1 failed; 521 modules; exit 1                                                                          | Obsolete optional-local-auth fixture premise, corrected in the next atomic test commit; this full run remains red                                                         |
| Corrected Linux authentication consumers | 68 passed and 2 passed; 0 failed                                                                                      | Original remote refusal assertions retained; actual request constructors; both new loopback cases fail against genuine pre-fix source                                     |
| Linux E2E                                | 193/193 plus 6 actual native file-digest controls; exit 0                                                             | Real production startup code and controlled input/application ports; no physical typing or GTK interaction                                                                |
| Linux curl/libuv receiving               | 262 streaming + 72 local API checks; exit 0                                                                           | Real loopback sockets, actual curl, production owners/private-file restart and physical process/handle retirement; controlled HTTP servers, not an installed oMLX product |
| Windows source controls                  | API causal/inverse controls, encoding (1,908 files), syntax (1,888 sources), registration and strict conventions pass | AutoHotkey native execution NOT_RUN                                                                                                                                       |
| Full JS and complete Linux rerun         | Pending for the next checkpoint                                                                                       | No full integration-green or hosted qualification claim                                                                                                                   |

The original failed macOS integration run remains distinct: 18,690 passed and
one mandatory E2E failure under a private adjacent bootstrap override. The file
was removed after terminal completion; no assertions were changed. The later
28 failures from missing layout-registry fixture ports were corrected without
removing their original assertions: five affected modules pass 96/96, including
independent shipped ANSI/ISO XML expectations. The full 18,858/0 receipt above
includes that correction. The earlier loaded Linux FIFO deadline failure passed
in isolation and did not recur in the first whole-unit run above; no native
budget was increased.

## Subsequent issue 94 software corrections

Separate atomic commits correct native scalar JSON delivery in typing metrics,
the paths editor, the action picker and MLX downloader helper publication.
The shared string quotation owner preserves exact UTF-8/control/injection bytes;
invalid encoding and stale recipients refuse. The UI cohorts pass 16/16, 29/29
and 42/42 on the composed source. All 19 new UI cases fail with original sources;
actual Node evaluates 15 emitted callback scripts with 20/20 checks. MLX trust
activation passes 20/20 and emitted Python trust receiving passes five independent
vectors. A move-resilient unique original declaration locates the actual producer;
the regression does not rely on a declaration introduced by the fix.

Startup settlement now waits for the original physical requirement retirement
and completes the retained failed cycle without requiring an unrelated Resume.
Its seven lifecycle cohorts pass 167/167; original source fails all three new
late-retirement cases. Prediction locks, refused cleanup debt, stale generations,
pause and observer cancellation remain guarded.

Replay from `static/ergopti_plus/macos` with pinned Lua 5.4.7:

```sh
lua tests/run.lua --only tests.unit.ui.test_metrics_typing_javascript_delivery
lua tests/run.lua --only tests.unit.ui.test_menu_paths_javascript_delivery
lua tests/run.lua --only tests.unit.ui.menu.test_program_provider_picker
lua tests/run.lua --only tests.unit.ui.menu.menu_llm.test_mlx_download_trust_activation
lua tests/run.lua --only tests.unit.ui.menu.menu_llm.test_startup_timer_scheduler_ownership
lua tests/run.lua --only tests.unit.ui.menu.menu_llm.test_models_manager_requirement_capabilities
```

These Lua commands use native boundary doubles even when invoked on a Mac.
Native receiving requires an active macOS GUI session, installed current driver
and Hammerspoon 1.1.1. Verify the native contract independently:

```sh
hs -c 'assert(not pcall(require("hs.json").encode,"scalar")); local v="é漢😀\r\n\t\"\\"; assert(require("hs.json").decode(require("json").quote(v))==v); return "native JSON round-trip passed"'
```

Then use the statistics filters/reset, paths Browse/cancel/reopen and an
unavailable action-picker provider. Expect exact delivery to the current page,
visible localized refusal, no request-reset encoding errors and no stale-page
delivery. Exercise MLX helper preparation and a failed requirements child that
retires late: expect no scalar encoding refusal, retained cleanup until the
child retires, then automatic failed-cycle finalization. These checks need a
native VM and GUI session; no physical keyboard, display or trackpad is required.
Native results remain NOT_RUN. Full integration suites are still pending.

## Configured local endpoint discovery

Two subsequent atomic changes add explicit configured local endpoint views and
retire logical model caches on exact entry/source identity changes across all
three drivers. The private credential/URL remains bound to the originating entry;
generic model replies never establish a product identity. Ordinary network errors,
authentication refusal, valid empty lists and actual native admission failure have
distinct truthful menu states. Native cancellation debt remains retained until
the same physical request acknowledges retirement. Entry order and unknown private
data survive publication/refusal/reload.

On the final composed source, the four Mac cohorts pass 20, 37, 117 and 18 cases
(192/192). Five Linux production cohorts pass 258/258, including independent
literal loopback/affinity vectors. The actual Linux fixture passes 136/136 with
real curl/libuv, scoped owned loopback servers, private JSON restart, exact model
selection, empty/protected/malformed responses, stale source refusal and complete
process/pipe/handle retirement. No installed oMLX product is used. Windows source
gates pass; 26 native Windows discovery/affinity/cache cases remain NOT_RUN.

Replay portable Mac cohorts from the macOS driver directory:

```sh
lua tests/run.lua --only tests.unit.modules.llm.test_local_server_configured_affinity
lua tests/run.lua --only tests.unit.modules.llm.test_local_openai_backends
lua tests/run.lua --only tests.unit.modules.llm.test_local_server_auth_policy
lua tests/run.lua --only tests.unit.adapters.test_http_client_timeout_transaction
```

Replay actual Linux receiving from the Linux driver directory:

```sh
LUA_CPATH="$LUA_CPATH_5_1" ERGOPTI_NATIVE_LUA_CPATH="$LUA_CPATH_5_1" luajit tests/hardware/run_local_api_auth.lua
```

For native Mac/Windows receiving, use an active GUI session and a real local
OpenAI-compatible server with a known model ID and explicitly captured base URL.
Add that generic entry without a key when the server is keyless, then search and
select its model. Expect the same entry ID/provider, no foreign-data loss and
actual chat to that URL. Test a nondefault port and `/v1` base path. Change URL,
provider and credentials under the same ID while a models reply is pending;
expect old rows/refused replies to be unusable, then a fresh probe. Stop the
server, return 401 and return an empty models list: expect down, needs-key and
reachable/no-models states respectively. Pause/cancel during a pending reply and
replace the private configuration: expect no stale publication or premature
retirement claim. These are native VM/server checks, not physical device tests.
The Windows native tests keep the original owning registration order; no test
files move and Root owns later inventory migration. Full integration suites are
still pending on this checkpoint.

## API addition and local receiving

API Add uses the real private source and durable writer. macOS configuration
cleanup can clear quarantine without granting inference permission; invalid
cleanup acknowledgements display an existing localized error. Explicit generic
loopback entries accept blank tokens and perform no unnecessary Keychain work;
remote generic blank tokens refuse. Linux OpenAI offers a custom URL field.
Windows retains originating source authority through every modal and the joint
WAL. All drivers retain generic provider, ID, name, foreign metadata and exact
credentials while discovering a matching declared endpoint. Canonical native
catalogue providers retain precedence; raw provider-only credential policy and
its independent vectors remain unchanged.

Focused macOS evidence: form 83/83, persistence 34/34, local backend 27/27,
authentication policy 111/111 and actual configured-affinity 6/6. These overlap
the full suite and must not be added to its total. Windows has 82 registered
API Add/readiness cases and eight canonical-affinity cases; they are authored,
not executed. Twelve of the 82 use injected HTTP replies and cannot qualify a
live server.

For Windows VM receiving, use pinned AutoHotkey 2.0.26 and Node 22.22.2, an
isolated TEMP/TMP directory and normal filesystem/DPAPI rights. Root owns the
separately confirmed fixed-TEMP fixture cleanup defect; receive that fix before
using an ordinary shared user TEMP. These focused commands require no physical
keyboard, display or pointing device:

```powershell
node tools/test/test-windows-api-add-production.cjs
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static\ergopti_plus\windows\tests\run_all.ahk --only windows-api-add-production
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static\ergopti_plus\windows\tests\run_all.ahk --only local-server-affinity
```

Expect 82 and eight actual cases, zero failures and fresh terminal receipts.
Require actual DPAPI roundtrip, exact refused WAL rollback, source drift refusal
and unchanged foreign fields; source scans alone do not meet those requirements.

On a native macOS VM, start a compatible server with an advertised model at
`http://127.0.0.1:8000/v1`. Add it using OpenAI and OpenAI-compatible separately,
with an empty key only when the server does not require one. Expect persisted
entries after restart, requests to that exact URL and visible errors for real
401/malformed-model replies. Cancel each field and induce a native pause/source
change during a dialog: expect no partial publication or successor overwrite.
Actual oMLX installation requires its supported native host. These checks need
native software and a reachable server, not physical input devices.

Reproduce available Linux protocol receiving from committed source:

```sh
source .rtk/cloud-tools.sh
export LUA_CPATH="$LUA_CPATH_5_1"
export ERGOPTI_NATIVE_LUA_CPATH="$LUA_CPATH_5_1"
npm run test:linux:e2e
npm run test:linux:http-stream
```

Use private XDG/TMP directories and the real pinned LuaJIT, lfs, luv and curl;
keep HOME intact. Expect the counts above on this checkpoint. A missing native
ABI/socket/process prerequisite is a refusal, not a mocked pass. Interactive
Zenity/GTK and real devices remain unrun here.

## Test-optimization coordination

### Terminal Mac receiving and preserved next native patch

The full portable Mac suite on `0cd3c15aa86bf116c87a3db2bc5660205b61ec11`
finished with 18,945 passes, six failures and 1,576 modules, exit 1. Three of
those failures are corrected by `dcf146842` and `b046f00ff`: the unchanged closure
guard passes 7/0 after distinct names remove a nested-local scanner false
positive, and the exact scope census includes 99 original plus eight explicitly
named scalar scenarios. Its two success/failure tests replay 214 complete
callbacks and pass 2/0. Actual root discovery/authentication owners pass 117/0
and 20/0; original discovery also passed, so this is not a native callback bug
claim. The three unreachable-backend offer fixture failures are still open.
The full suite has not been rerun after these two corrections. An incorrect
module filter was rejected with zero cases; that invocation is not evidence.
Fresh dev `2bfcf853c` was integrated at this terminal checkpoint, preserving G6.

[The pending modifier correction](pending-modifier-custody.patch) has SHA256
`7e5990669183cf953f31660e881f6bf62baf4026d2b5f68f2378954559d0bfcf`.
It is implemented and verified in a Linux scratch source, not applied to the
live C/vendor recipe. It changes exactly `terminal_output_plan.c`, `.h` and
`_test.c`. All 124 original assertions remain in order; 33 are added. Independent
vectors cover eight LR families, both axes, two source-origin combinations and
an unrelated held modifier: 64 cohorts, 320 target edges and 32 setup edges.
The 192 zero-output refusals retain closed cohort admission. Eight matrices pass
normally and with ASan/UBSan/LSan; the original and always-emit, missing-final-UP
and missing-right-Ctrl mutations fail. The independent review confirms exact
original-edge consumption and retained partial ACK debt. Remapped modifiers
still need their own qualified delivery/cleanup before production activation.

On the fresh Windows checkout, coordinate these three C paths and vendor with
Root, apply the patch and rebuild before committing changed live source:

```powershell
git apply --check docs/handovers/2026-10-12-dev-consolidation/pending-modifier-custody.patch
git apply docs/handovers/2026-10-12-dev-consolidation/pending-modifier-custody.patch
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
node tools/test/test-ahk-full-startup-smoke.cjs
```

Require canonical MSVC/SDK prerequisites, the new output matrix census of eight,
all original C/route/trace cases and exact new DLL/source fingerprints. The
preceding E4133 DLL cannot qualify these changed inputs. No backend selection,
hook-order assumption, production-cohort activation or physical proof is added.
Remove this pending patch only when its exact changes and matching native
artifact are durably integrated. Both transfer refs remain preserved until
fresh integration/PR/CI checks authorize their cleanup.

[Windows continuation prompt](windows-receiving-prompt.md) is ready for local
receiving. The one-click collector is on dev and absent from stable v1.0.1;
Root must publish its new release before installed-user receiving. Private
issue 94 logs and test transcripts stay outside Git. Do not upload their content.

### Received Windows software checkpoint

Receive only the 15 commits after `7184fbf58b` through `fca9d29769` from the
archived session, plus the exact seven-file `fae726662` increment. The latter is
an unqualified snapshot, not a native pass. The historical native receipts in
[Windows delivery](../2026-10-11-groups-247/windows-delivery.md) belong to that
session and source; they were not rerun on this Linux host. Existing stricter
main publication/admission assertions survive composition unchanged.

Received vendor commit `680bb62e3d0cba970f4db44015d0aeae19400629` contains the
real archived MSVC artifact, SHA256
`E4133FA294B78920D6A558CA284F0CCDB96807FA10D15DEC6E1CF046731C972A`, with exact
18-input source/recipe fingerprint
`28151596A8EE33BDF11D2BE1212455F3D77263871268B8844CC7DE15016C5E43`.
Container verification confirms both hashes and every input; it does not qualify
native loading/startup. Root owns subsequent Windows startup/build receiving.

Actual Linux-host C controls pass 43/43, route/output/trace matrices 8/7/6;
trace protocol has three positive and 54 negative controls. Source census retains
44 authored C cases and six inverse selections, forty exports and thirteen
withdrawals. AHK custody source controls retain five ABI bindings, twelve authored
cases and thirteen inverses. Bootstrap source controls and the Windows bundle
closure pass: 323 shipped files and 55 inverse selection controls. Encoding
verifies 1,910 AHK files, syntax scans 1,890 sources. Canonical diagnostic source
seal controls pass 22; architecture controls pass nine. These source counts are
not additional native executions.

Collector follow-ups pass 62 source/withdrawal controls and actual shared-page
VM behavior. Produced byte receipts exclude unproduced allowed names; same-stream
identity/hash verification refuses successors and hard links; primary failure
retains failed status and a verified ZIP. Native PowerShell/AHK remains UNRUN.
Post-READY model construction/start failure now uses the current menu operation,
with exact cleanup even after reentrant cancellation; its nine new AHK cases
remain UNRUN. No production qualification flag changes.

Windows VM prerequisites: pinned AutoHotkey 2.0.26 x64, Node 22.22.2, stock
Windows PowerShell 5.1/.NET, interactive desktop, private TEMP/TMP on NTFS and
the exact received DLL/manifest. These controlled owners need no physical input
device or Ollama installation:

```powershell
$env:ERGOPTI_AHK_RUNTIME = 'C:\path\to\AutoHotkey64.exe'
node tools/test/test-diagnostic-ui-integrity.cjs --native-collection
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static\ergopti_plus\windows\tests\run_all.ahk --only=groups247-collection
& $env:ERGOPTI_AHK_RUNTIME /ErrorStdOut=UTF-8 static\ergopti_plus\windows\tests\run_all.ahk --only=groups247-resident-observations
node tools/test/test-ahk-full-startup-smoke.cjs
```

Expect 30 stock worker controls, 13 collection cases, two resident cases, no
failures and fresh actual terminal receipts. Sharing retries retain deadlines;
malformed data refuses. Private source/input/control data must not enter a ZIP.
Fresh startup must resolve all twelve previously missing native exports. If a
native rebuild is needed, use `tools/build/build_windows_nav_owner.ps1
-UpdateTracked` on Windows with the canonical MSVC/SDK prerequisites; never
fabricate a manifest or substitute an adapter fallback.

Installed receiving remains separate: the publication owner must build a new
release from dev. On that exact release, open Diagnostics and select collection;
retain its ZIP and actual source/version/terminal status, close/reopen during
collection, cancel a run, and confirm the folder action. A clean VM without
developer tools must prove packaged operation. Guided keyboard/display steps
require the real device; skip/cancel never means PASS. Windows production output
cohort migration/emission and unavailable native collector providers are still
software work. Native macOS, oMLX, real ISO input and installed UI acceptance
remain distinct, executable tasks in the preceding handover.

### Linux startup discovery follow-up

Correction `508201914424fe1f28cd642f999d64c026a6ebc3` is based on fresh
`dev 6d1efd3d016c4e2f693d8fb49158534ac8e425c7`. Only the existing startup child,
owned HTTP fixture and local-discovery regression module change. The installed
startup fixture removes luv for its scripted clock; its declared catalogue
loopback requests now model ordinary connection refusal with owned retirement,
while unrelated HTTP requests retain their actual adapter and exact arguments.
Production infrastructure refusal, startup error assertions and the runner stay
unchanged. All 39 prior discovery assertions remain, with two additional cases.

The normal E2E entry, launched by the pinned Node runner, completes 193/193 plus
six native digest checks with actual subprocess status 0 in 90,114 ms. An earlier
invocation returned 1 despite its successful footer; it remains failed with an
unattributed exit discrepancy. The independent subprocess receipt names the
source SHA and status, rather than deriving success from footer text. Private
receipts remain outside Git. The preceding full Linux unit run on `ba41b79db`
completed 13,450/13,450 in 521 modules. Actual curl/libuv receiving on the composed
correction completed 262 streaming and 136 local API checks with exit 0.

Use the Linux commands above with the pinned native ABI. Expect 193 E2E cases,
six digest cases and zero exit status; retain stdout and the process status.
The controlled startup edge is software evidence, not a live network or input
device claim. No native Windows/macOS qualification is implied.

No existing-path tests were moved. The only new JS CHECKS entry in this follow-up
is `tools/test/test-windows-api-add-production.cjs`, alias
`test:windows-api-add-production`, committed in `b2bf6e473`. It belongs with AI
feature controls. Native `unit/test_llm_api_add_production.ahk` is included
immediately after `unit/test_local_server_private_publication.ahk`, because its
production-world fixture depends on that module's `_LSP_World`. Preserve that
include/dependency order and all 82 registrations. The new Mac affinity module
is discovered by the existing runner; the shared independent corpus is
`_shared/tests/corpus/llm/local_server_affinity.json`.

Root owns inventory/runner/workflow reorganization and the Windows
`unit/test_hotstrings_config.ahk` fixture isolation correction. This checkpoint
preserves the historical registrations in `run_all.ahk`, `test_framework.ahk`
and the legacy JS runner; it introduces no concurrent semantic migration.
The ongoing discovery, startup-settlement and scalar JSON fixes will be
published separately with their existing-path tests after this checkpoint.
