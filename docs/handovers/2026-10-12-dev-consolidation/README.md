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
