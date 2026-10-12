<!-- docs/handovers/2026-10-11-groups-247/README.md -->

# Groups 2, 4 and 7 continuation

Branch: `codex/groups-247-completion`, based on `origin/dev` at
`8d6e3a1198a16645e41b7d4bf0f56a013be6072a`. The final handover commit identifies
this delivery; obtain its exact source with `git rev-parse HEAD` after checking
out the branch. `origin/main` was reviewed before implementation. Its provider
publication and Transformers security corrections were selectively reused;
its release, final integration and performance changes were not overwritten.

## Implemented software

- Hotstrings: retained timing prompts reread current intent; menu publication
  uses revision-scoped runtime and preference owners, retains inverse debt and
  checks live pause. Personal editor writes preserve unowned TOML metadata,
  inline fields, comments and hidden descendants or refuse an unsafe edit.
  Windows additional-file controls use semantic metadata paths. The existing
  Windows custom-terminator consumer/editor was not reimplemented.
- AI: Windows production now uses the existing per-user file/runtime owners,
  native architecture, separate install/start/model consent, source-bound enable
  acknowledgement and exact managed process/origin across consumers. Process
  creation identity prevents borrowing a reused PID. macOS provider/model
  selection requires acknowledgement; discovery, warmup, readiness and model
  loadability use the configured origin, and Quit retires only its owned Ollama.
  Install errors retain bounded streamed diagnostics. Linux menu choices require
  durable acknowledgements, and non-chat keys are added without changing the
  prediction selection. API allocation also excludes same-second IDs persisted
  by an earlier process. Windows already rejects duplicate entry candidates.
  The patched Transformers dependency is pinned.
- Windows input: the production C arbiter distinguishes physical, injected and
  replay modifiers; captured route recipes survive layout changes and partial
  FIFO acknowledgement. Portable execution uses actual production C with a
  strict Win32 boundary shim. Canonical UTF-16 output plans retain exact partial
  acknowledgements and authenticated FIFO custody; incomplete native handler
  cohorts remain disabled. Native receiving, send-measurement and window/DPI
  supervisors produce fresh receipts and retain cleanup failures.

## Evidence classes

Container executions cover portable production logic, actual Linux private
writers, controlled Lua collaborators, independently authored corpora, source
checks and sanitizer execution. They establish neither native Windows/macOS
service/input execution nor physical device acceptance.

AHK and Windows PowerShell changes, native DLL generation, real Hammerspoon
service consumers, installed app receiving and platform trust/network behavior
require native execution. `NATIVE_PRODUCTION_QUALIFIED=False` is unchanged.
The Windows DLL/manifest remains stale pending the official MSVC generator;
no Linux stamp or synthetic binary was substituted.

Actual callback order requires native observation; a synthetic VM run can
observe its injected-event contract but cannot replace physical capture evidence.
Physical typing, simultaneous input, real display clarity and transitions,
trackpad gestures and user-installed applications require the corresponding
hardware or user environment. Ordinary process/file/TCP/GUI/UIA cases can run
in a native VM; VM software results and device results must be recorded separately.

## Reproduction and remaining execution

Use Node 22.22.2, Python 3.13.5, Ruff 0.15.8, frozen npm/uv dependencies, Lua
5.4.7 for macOS portable tests and the repository Linux LuaJIT ABI. The cloud
setup draft installs these tools; it requires saving/publishing in environment
settings before it applies to future tasks. The current container additionally
has real LuaFileSystem/libuv modules for both Lua ABIs. In this container, source
`.rtk/cloud-tools.sh` first. Its default C module path targets Lua 5.4; Linux
LuaJIT commands and the mixed-runtime JavaScript gate explicitly select
`LUA_CPATH_5_1`; Lua 5.4 still reads its version-specific `LUA_CPATH_5_4`. Preserve inherited `HOME`.
Use a fresh writable `XDG_CONFIG_HOME` for Linux fixtures that keep the real
storage owner. For macOS portable tests, set `ERGOPTI_PATHS_FILE` to a private
TOML file with absolute writable `ConfigDirPath` and `LogsDirPath` directories.
These environment settings are supported production path seams, without
changing assertions. Run suites sequentially:

```sh
source .rtk/cloud-tools.sh
export LUA_CPATH="$LUA_CPATH_5_1"
export ERGOPTI_NATIVE_LUA_CPATH="$LUA_CPATH_5_1"
TASK_LINUX_CONFIG="$(mktemp -d /tmp/ergopti-linux-config.XXXXXX)"
export XDG_CONFIG_HOME="$TASK_LINUX_CONFIG"
unset ERGOPTI_PATHS_FILE
npm run format:check
npm run test:ahk-encoding
PYTHONDONTWRITEBYTECODE=1 npm run test:js
TASK_MAC_ROOT="$(mktemp -d /tmp/ergopti-macos-config.XXXXXX)"
mkdir "$TASK_MAC_ROOT/config" "$TASK_MAC_ROOT/logs"
printf 'ConfigDirPath = "%s/config"\nLogsDirPath = "%s/logs"\n' \
  "$TASK_MAC_ROOT" "$TASK_MAC_ROOT" > "$TASK_MAC_ROOT/paths.toml"
export ERGOPTI_PATHS_FILE="$TASK_MAC_ROOT/paths.toml"
npm run test:hs
npm run test:hs:e2e
unset ERGOPTI_PATHS_FILE
XDG_CONFIG_HOME="$(mktemp -d /tmp/ergopti-linux-unit.XXXXXX)" npm run test:linux
XDG_CONFIG_HOME="$(mktemp -d /tmp/ergopti-linux-e2e.XXXXXX)" npm run test:linux:e2e
XDG_CONFIG_HOME="$(mktemp -d /tmp/ergopti-linux-http.XXXXXX)" npm run test:linux:http-stream
npm run test:windows-nav-portable
npm run test:windows-replay-route-core
node tools/test/run-windows-replay-route-core.cjs --sanitize
npm run test:windows-terminal-output-plan
node tools/test/run-windows-terminal-output-plan.cjs --sanitize
```

Native preconditions, commands, selected counts and expected output:

- [Hotstrings](group2-native-execution.md).
- [Windows managed AI](group4-windows-execution.md).
- [macOS managed AI](group4-macos-execution.md).
- [Windows input, rendering and metrics](group7-native-execution.md).

Release generation, installed-artifact qualification, integration and CI/test
optimization retain their publication owner's responsibility. No workflow or
publication policy was changed. All relevant TODO items remain open where
native, physical or explicitly identified production input cohorts are missing.

## Container results and limits

The macOS full-suite checkpoint executed 1,574 modules: **18,641 passed,
20 failed, exit 1**. Ten failures exposed missing scanner custody in two fixtures;
the subsequent atomic repair retains every original assertion and passes the
strengthened **17/0** selection. Nine failures come from deliberately mocked
HOME/path matrices inheriting the exported bootstrap path override. With that
override unset, current and genuine original resolver/tests both pass **14/0**;
the genuine originals reproduce all nine failures with the override set. The
remaining logger fixture failure reproduces on genuine original and current
logger owners under retained print-tee/read-only-fallback conditions (**2/1**
each); tee-free controls pass **3/0** each. The original full red receipt is
retained and is not replaced by focused green results. No logger or path-matrix
optimization was made in the other agent's area.

The separate final macOS portable E2E gate passes **101 passed, zero failed**,
with **one explicit driver-specific skip**, exit 0. These Linux-host executions
do not qualify Hammerspoon on Darwin, the managed service or either device ABI.

The final Linux unit/meta gate executes **521 modules, 13,294 passed, zero
failed, exit 0**, using the real pinned LuaJIT and native dependencies with a
fresh writable XDG configuration directory. The previous read-only-default
storage refusals are not hidden or exempted; the supported path seam permits
the actual writers to acknowledge their publications.

The separate Linux E2E gate passes **193/193**, zero skips, with **6/0**
real native digest-owner child checks. The actual libuv/curl HTTP gate passes
**262 checks** and its native local authentication/discovery lane passes
**48 checks**; all related process/pipe/server/event-loop owners settle. Each
command exits 0 and uses its own fresh writable XDG directory. Tools are Node
22.22.2, LuaJIT 2.1.1737090214, Python 3.13.5 and curl 8.14.1.

The Windows production C shim executes **43/43** cases, with one native editor
case explicitly unexecuted (44 authored registrations). The independent event
core passes **8/8**, canonical output matrices **7/7**, and trace matrices
**6/6**, including ASan/UBSan. Receiving protocol controls pass **21/21**; trace
protocol controls pass **2 positive plus 46 negative fixtures**. These are
portable logic/protocol checks and grant no Windows service, callback or
physical qualification. AHK source syntax (1,885 files), BOM/LF (1,905 files),
strict conventions (1,863 AHK/3,338 Lua/429 TOML) and pinned format checks pass.
The generated architecture and all 61 declared outputs from 31 generators are
in sync; targeted drift controls preserve exact prior edits.

## Coordination with publication and test migration

The publication session owns v1.0.1 on main and subsequent Common/Windows/macOS/
Linux suite reorganization. Main was refreshed and reviewed at
`bd198a6eae6f8ac01b0101312409547d62c1a936`; no workflow, test optimization or
TOML comment-scan performance patch was copied over. The changed test/runner
inventory is recorded in [test ownership](test-ownership.md). No moves are planned here.
Keep explicit Lua fixture ledgers, native process/FIFO identity, and state/order
dependencies intact when agreeing the later integration/migration table.

The initial complete JavaScript checkpoint at `ab25a893` had **412/420 passed,
8 failed, exit 1**. Three were the generated architecture diagram and cascading
drift checks; one was the new managed timer missing from both inventories;
one exposed four AHK loop captures. Separate atomic corrections retain the
original 139 custody assertions and twelve native cases; the unchanged loop
scanner passes with its zero baseline. Callback evidence additionally records
VK/SC only where the native callback supplies them, and distinguishes registered
fixture attribution from event identity (46 protocol and 13 source controls).

The remaining initial JavaScript failures were environmental: five ignored
Python caches created an apparent physical platform-directory asymmetry;
`xmllint` was absent; and protected `.git` markers at `/tmp` and `/workspace`
correctly made the uninstall sandbox refuse a checkout ancestor. Exact cache
cleanup, bytecode suppression and signed Debian XML tooling address the first
two without test changes. The unchanged uninstall regression passes in its own
private `/var/tmp` workspace, with scoped tool approval. Never remove protected
markers or weaken uninstall ownership checks to obtain a green result.

The reusable cloud setup was replayed successfully with Node 22.22.2, Python
3.13.5, Ruff 0.15.8 and both native Lua ABIs. Its saved configuration draft
includes pinned XML tooling and remains pending review/publish in environment
settings; fresh-task restoration has not been independently qualified.

The final complete JavaScript gate at functional SHA
`92cbad33907ae4ce7e32494f8990f35e81eba983` passes **420/420 checks, zero failed,
exit 0**. It uses the pinned runtimes, actual XML validator, fresh XDG storage,
no macOS path override, bytecode suppression and a private approved `/var/tmp`
workspace. The earlier 412/420 red checkpoint is retained separately; no
assertions, scanner baselines or independent corpus were weakened.

Selected container proof logs remain under `/tmp`: `groups247-js-full-final.log`
(first red) and `groups247-js-full-verified.log` (final green),
`groups247-linux-full-writable-final.log`, `groups247-linux-e2e-writable-final.log`,
`groups247-linux-http-stream-final.log`, `groups247-hs-final-supported.log`,
`groups247-hs-e2e-final-supported.log` and `groups247-macos-final/` control
receipts. These temporary paths are not fresh-task restoration promises; the
committed commands and bounded results above are the durable handover.
