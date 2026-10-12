<!-- docs/handovers/2026-10-12-dev-consolidation/native-serializer-bridge-receiving.md -->

# Pending native retained-attempt serializer bridge

Base: `702db4560bcf9b974dcc5302213beffb7b83b104` **after applying only**
`pending-owned-win32-payload-serialization.patch` (SHA256
`c34435adcce905b74019fad3792f8b4a8ef6cdbda94ec8c1a78d640d808ee7ff`).
Neither clock nor modifier patches are applied to this independent projection.

Bridge patch: `native-serializer-bridge.patch`, SHA256
`2ff7f370089dec54ec58b6521af63c0f8dd347bf8317b252ded08a713da5ca10`.
Exact four pre/post hashes: `freeze-native-serializer-bridge-manifest.json`.
No root source, vendor, manifest, global admission flag, builder or runner changed.

## Fixed native/consumer contract

```c
int32_t __cdecl ErgoptiNav_SerializeTerminalOutputAttempt(
    uint64_t owner, const ErgoptiOutput_Key *key, uint64_t attempt,
    ErgoptiOutput_Win32Input *out_inputs, uint32_t capacity,
    uint32_t *out_count);
```

AHK DllCall: `UInt64 / Ptr / UInt64 / Ptr / UInt / Ptr -> Int`. Key24;
packets40 bytes each, one per logical unit; capacity/count are packets/UInt32.
The owner marker remains fixed by the pending pure serializer. The bridge
preflights writable output ranges against the **whole** native state, including
lock, raw FIFO and route fields, then authenticates the current FIFO head using
`NavCheckTerminalOutputLocked`. The pure serializer executes under that same
critical section against the retained immutable attempt. It copies caller-owned
data, never a borrowed pointer into custody. No new attempt, send, ACK, FIFO
consumption, backend choice or admission occurs. Refusal leaves outputs unchanged.

FAULTED/stop-pending custody may still copy its already retained exact suffix
for settlement; overflow and prior errors survive unchanged. It cannot acquire
new output admission. Raw release is BUSY, and stale/foreign heads/attempts refuse.
Only one public `.def`/header export is added: 40 becomes41, existing names/order
are exact and native ABI version3 is unchanged. The AHK required-export roster
and source/export-count controls need coordinated41st-name receiving. The old DLL
cannot load this new consumer contract or qualify the new source recipe.

## Executed evidence

GCC14.2.0, Node22.22.2, Linux/x64 actual production C:

- Existing registered custody case1/1 and unchanged full portable43/43 PASS;
  native census stays44, including the unexecuted native editor matrix.
- Additive helpers inside existing registered cases cover six literal texts,
  26 exact-prefix cohorts, all eight LR modifiers on VK/SCAN axes (32 edges),
  fixed marker/reserved bytes, external copy mutation, cancellation, typed identity
  refusal, aliases, capacity, current-head retirement, raw release reentry and a
  positively serialized final Unicode UP under FAULTED overflow debt.
- All original1,352 native assertion calls and complete test bytes are preserved
  after removing only added helpers/calls/fault block.102 calls are added.
- Full Address/Undefined/Leak sanitizers PASS for both registered custody/fault
  cases and the supplemental boundary harness, with checks unchanged.
- Pending pure serializer10/10 matrices remains PASS. Original missing bridge
  implementation gives link RED: API absence evidence only, no fabricated old
  runtime failure.
- Five actual cleanly compiled mutations are RED exit1: bypass current-head
  authentication; ignore attempt identity; early output write; omit bridge lock
  pair; release the lock before pure dispatch.

The durable `native-serializer-bridge-fault-harness.c` is **supplemental portable
source-inclusion evidence**, not a shipped/registered case or Windows result.
It calls the actual bridge after perturbing/restoring head sequence, retained
snapshot or release state under the owner lock. Whole-state aliases into
lock/routes/FIFO/count refuse. A macro wraps only the actual pure serializer call,
forwards to its unchanged implementation and uses a distinct real pthread
`pthread_mutex_trylock` to require EBUSY at dispatch. No sleeps/timing inference,
shipping observer or private admission setter is added. Omitted/early-release
bridge-lock mutants fail that causal check. The source and command below preserve
this proof independently of temporary logs.

## Source composition and receiving

Coordinate the pending serializer, this four-path bridge, the required41st AHK
export and packet consumer before native publication. The independent replay-core
output-span correction may be composed separately; its ABI is unchanged. Neither
that correction nor clock/modifier changes are claimed in these bridge receipts.
Retain their original receipts and rerun the affected composed gates. The
serializer-only planner census remains10; with the existing modifier test union
it becomes the expected11. Do not call that combined expectation an execution.

From the repository root, after reviewed source composition:

```sh
node tools/test/run-nav-event-owner-portable.cjs 'terminal output custody settles exact FIFO head (todo49-output-custody)'
node tools/test/run-nav-event-owner-portable.cjs 'terminal output custody preserves fault debt (todo49-output-custody)'
node tools/test/run-nav-event-owner-portable.cjs
node tools/test/run-windows-terminal-output-plan.cjs
```

Expected portable selected1/1 each, full43/43 and serializer-only10 matrices.
To reproduce the supplemental Linux proof, place its preserved source in this
handover directory and use the unchanged checked-in boundary:

```sh
cc -std=c11 -Wall -Wextra -Werror -UNDEBUG \
  -D_POSIX_C_SOURCE=200809L -D_WIN32=1 -DERGOPTI_NAV_TESTING=1 -pthread \
  -I tools/test/support/nav_event_owner_portable \
  -I static/ergopti_plus/windows/native/nav_event_owner \
  docs/handovers/2026-10-12-dev-consolidation/native-serializer-bridge-fault-harness.c \
  static/ergopti_plus/windows/native/nav_event_owner/replay_route_core.c \
  static/ergopti_plus/windows/native/nav_event_owner/terminal_output_plan.c \
  static/ergopti_plus/windows/native/nav_event_owner/hook_trace.c \
  tools/test/support/nav_event_owner_portable/runtime.c \
  -o /tmp/ergopti-serializer-bridge-fault
/tmp/ergopti-serializer-bridge-fault
```

For full sanitizers add `-fsanitize=address,undefined -fno-omit-frame-pointer`;
LeakSanitizer requires an execution environment without ptrace. Expected PASS
supplemental head/snapshot/release/whole-owner alias and cross-thread lock checks.
This command constructs/sends no real keyboard events and grants no Windows fact.

On a real Windows x64 MSVC/SDK host with pinned Node22.22.2, AHK2.0.26 x64,
stock PowerShell5.1 and an interactive desktop, receive the source union and use:

```powershell
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
if ($LASTEXITCODE -ne 0) { throw 'Native serializer bridge rebuild failed.' }
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
if ($LASTEXITCODE -ne 0) { throw 'Source-bound native provenance verification failed.' }
& .\static\ergopti_plus\windows\build\native\nav_event_owner\ergopti_nav_event_owner_test.exe
if ($LASTEXITCODE -ne 0) { throw 'Native retained-attempt receiving failed.' }
& .\static\ergopti_plus\windows\build\native\nav_event_owner\ergopti_terminal_output_plan_test.exe
if ($LASTEXITCODE -ne 0) { throw 'Native packet serializer receiving failed.' }
```

Expected unchanged44 native cases, all original route/trace cases, exact41 exports,
real SDK layout/flag pins and matching new DLL/source/recipe hashes. Also execute
the companion packet consumer's documented source/native AHK selections and actual
startup after its41st-name loader update. The compiler, SDK, DLL, AHK runtime,
real Windows critical-section behavior, actual send acceptance and physical output
remain **UNRUN** for this lot. A Windows VM can receive compiler/API/core facts;
a real keyboard or honestly described VM keyboard channel is needed for actual
holds/suppression. No native qualification flag or send policy is inferred.

The native bridge is now implemented software. Actual backend delivery/cleanup,
full nonhook handler/observer cohort conversion and their native/physical
qualification remain open. Keep production admission closed and TODO49 open.

## Strict source binding companion

Apply [native-serializer-source-binding.patch](native-serializer-source-binding.patch)
only with the complete C bridge and the matching required-export AHK consumer.
Its [inventory](freeze-native-serializer-source-binding-manifest.json) freezes
that existing feature guard; no roster or workflow changes. All 37 original and
three diagnostic export names, 37 original assertions and 13 inverse entries
remain. The explicit serializer export raises the exact contract to 41 and adds
14 meaningful inverses, including early unlock and the count-output alias check.
The original guard rejects the proposed 41-export source union (exit 1); its
successor passes (exit 0). These are source checks, not DLL execution.

The independently composed five C cuts (modifier, replay alias, clock, pure
serializer and this bridge) pass 8 core matrices, 11 output matrices and all
43 portable owner cases, each exit 0. All original registration/order and
assertion expressions remain. The composed 11 matrices, supplemental cross-thread
fixture and all 43 owner cases pass full Address/Undefined/Leak sanitizers with
assertions active. The paired modifier/packet AHK source union also passes its
59 source inverses; the strict bridge binding passes 13 original plus 14 new
inverses. These later union results do not qualify Windows SDK, DLL, AHK, hooks
or physical output. Preserve the separate original-code causal receipts.
