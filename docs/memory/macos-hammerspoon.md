<!-- docs/memory/macos-hammerspoon.md -->

# macOS and Hammerspoon memory

## Lua and test isolation

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

### project-hs-input-source-single-owner

`hs.keycodes.inputSourceChanged` is a setter, so one broker owns it and
multiplexes subscribers.

### project-macos-script-control-tap-lifecycle

The keycode-based script-control event tap survives layout changes and pause.
Do not restart it through shortcut lifecycle or regenerate Karabiner state on a
pause-driven layout switch.

### project-hs-karabiner-exact-lease-isolation

Ergopti owns only token-scoped Karabiner rules and variables. It never owns
Karabiner's shared UI, daemon, grabber, or VirtualHID processes.

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
