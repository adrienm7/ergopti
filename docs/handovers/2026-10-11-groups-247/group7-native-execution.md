<!-- docs/handovers/2026-10-11-groups-247/group7-native-execution.md -->

# Group 7 native execution companion

The Linux container validates production C state-machine logic through a
portable shim with real threads, the pure C captured-event route core and the
receiving receipt verifier. The new AHK fixture, PowerShell supervisors, real
hooks, screenshots and native receiving have **not** run on Windows. These tools
never select a production send backend,
close a TODO item, or qualify installed ErgoptiPlus, HSE, prediction acceptance,
UIA, physical hook order or simultaneous typing from simulated observations.

## Portable software checks

Use repository-pinned Node **22.22.2** and a host C11 compiler. The group 7
software checks report **43/43** runnable production-C cases; the authored
registration census contains **44**, including the explicitly unrun native
editor matrix, with **6** negative selection controls. The pure event core
reports **8/8** cases containing **29** event vectors, including an
AddressSanitizer/UndefinedBehaviorSanitizer run. The receipt reader reports
**21/21** protocol checks. Reproduce these independently of Windows:

```sh
node tools/test/run-nav-event-owner-portable.cjs
node tools/test/run-nav-event-owner-portable.cjs 'terminal route snapshots retain exact suffix (todo49-route-fifo)'
node tools/test/test-windows-nav-portable-registration.cjs
node tools/test/run-windows-replay-route-core.cjs
node tools/test/run-windows-replay-route-core.cjs --sanitize
node tools/diagnostics/test_windows_group7_receipt.cjs
```

The native shim rejects attempted real hook, injection or editor operations;
its boundary self-test uses actual mutual exclusion, threads, initialization,
timeouts and thread-local errors. These are portable logic observations and
cannot establish Windows callback scheduling, real event delivery or physical
input.

## Native Windows VM: receiving and measurements

Use Windows 10 1607 or later and Windows 11 separately, an interactive desktop,
AutoHotkey **2.0.26 x64**, repository-pinned Node **22.22.2**, x64 MSVC build tools
and the current checkout. Use a process-scoped execution policy that admits
these reviewed local scripts; do not change persistent machine/user policy. Close other AutoHotkey scripts and ErgoptiPlus for the
isolated primitive fixture. Keep the keyboard idle and do not change clipboard
contents. The fixture owns a native Edit control and installs the actual native
arbiter DLL. It deliberately uses `SetKeyDelay(-1, -1)` and SendLevel 0; these are
measurement settings, not proposed production policy.

After the native source correction, the publication owner must generate and
review the Windows DLL and manifest through the official generator. A stale
manifest is a prerequisite failure, not permission to bypass provenance:

```powershell
.\tools\rtk\rtk.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
```

The measurement supervisor runs the official generator **without**
`-UpdateTracked` to verify current source/recipe/PE bindings before every run.
The generator includes the captured-event FIFO metadata/peek APIs, the pure
event core and the current **40-export** ABI. The tracked DLL remains stale until
this Windows generation and review occur.
It records source, executable and DLL hashes, natural child exit and OS version.
Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-send.ps1 -Interactive -Samples 3 -InstallSequence ahk-before-native
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-send.ps1 -Interactive -Samples 3 -InstallSequence native-before-ahk
```

Each command must exit 0 and produce `supervisor.json` with `phase=completed`,
`stdout.csv`, empty `stderr.log` and `measurement.json` in its announced fresh
temporary directory. Expect **18** exact receiving observations: 3 samples of
long text, Unicode text and clipboard paste for each primitive. The report keeps
individual send/receiving elapsed samples and median/max receiving times. A
missing, duplicate, reordered, nonfinite or debt-bearing row fails verification.
Maxima describe this finite run; they do not establish universal latency bounds.

These sequences record whether `InstallKeybdHook()` was requested before or
after native Start. AHK may rehook around SendInput, and another process may add
a hook. The sequence names **do not establish actual hook callback order**.
Repeat observations with the resident driver and actual HSE/LLM callers,
Notepad, a classic Edit application and a terminal before drawing product
conclusions. The existing Notepad caller supervisor can cover its six specific
caller paths under PowerShell 7; its evidence remains separate:

```powershell
.\tools\rtk\rtk.ps1 pwsh -NoProfile -File tools/diagnostics/notepad-callers.ps1 -Interactive
```

If a receiving window loses foreground/focus, a physical modifier is held, the
DLL/source changes or native retirement refuses, the run fails. The supervisor
never kills a timed-out native owner. Inspect its PID/window, reacquire the owned
receiving window and Edit focus, release held keys and retry Exit using that
window's close button; preserve logs and replay debt until natural exit. A cleanup
refuses replay while a third-party window owns foreground or focus.
Do not force-close it as a way to manufacture a successful receipt. Clipboard
restoration preserves a foreign update detected at cleanup.

## Physical keyboard: capture/replay exercise

Use a real keyboard on the native Windows desktop, a Latin layout where the
unmodified physical keys produce `xyz`, no remapping/IME/dead state, and no
held modifiers. Repeat both install sequences:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-send.ps1 -Interactive -Mode physical -Samples 3 -InstallSequence ahk-before-native
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-send.ps1 -Interactive -Mode physical -Samples 3 -InstallSequence native-before-ahk
```

During **each** three-second prompt, type exactly `xyz` once and release all
three keys. Expect no receiving text before commit, then the exact synthetic
payload followed by `xyz`, no late duplicate, at least six captured edges,
matching replay count, an empty remaining FIFO and an IDLE terminal phase.
Absent input fails; a synthetic receipt cannot replace this exercise.

This bounded exercise captures typing **before** primitive emission. It does
not measure simultaneous physical typing during expansion or prove physical
hook order. Those TODO49/50 cohorts still require native callback traces with
event flags/extra-info, real overlapping typing, both observed hook orders
before/after SendInput, held/repeated/released modifiers, KLE/deadkeys/digits,
tap/hold and shortcut cases. Keep synthetic and physical records separate.

## Native desktop: TODO19 visual evidence

Use the current production driver with synthetic prediction text. Obtain the
actual tooltip HWND and its owning PID with AutoHotkey Window Spy. Capture only
that visible, unobstructed tooltip rectangle, never a private application. This
command records per-monitor physical pixels, native DPI and process GDI/USER
resource counts; it does not automatically judge rendering:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-window.ps1 -WindowHandle 123456 -OwnerProcessId 1234 -CaptureScreenshot
```

Replace the example HWND/PID with the live tooltip identities. Expect
`window.json` and `window.png`, stable window identity/geometry and an actual
nonzero unchanged DPI and a window that remains visible. Reject evidence without
the completed JSON receipt. `gdi_resources` and `user_resources` each report
`status`, `count` and `native_error`: an observed zero count has no native error;
an unavailable read keeps `count=null` and its error, and cannot qualify resource
retirement. Review borders,
corners, font baselines, grey/green/orange states, inactive emphasis, indentation,
screen-edge placement, redraw and reopen at 100/125/150/200% scaling. Repeat on
Windows 10 and Windows 11, after cold start and reload, with the current fonts.
Take baseline/after resource snapshots around repeated opens; investigate
growth rather than inventing a constant acceptable bound. A VM can qualify its
native rendering and DPI behavior. Real monitors are needed for multi-display
transitions and physical clarity; screenshots alone cannot qualify them.

## Native desktop and user environment: TODO51/101

Start with the current source/unit/E2E/startup prerequisites using the exact
runtime and fresh configuration; record failed, skipped and unrun commands:

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static/ergopti_plus/windows/tests/e2e/run_e2e.ahk
.\tools\rtk\rtk.ps1 node tools/test/test-ahk-full-startup-smoke.cjs
```

The captured KLE regression filter contains two software cases; execute it and
the authored route-adapter filter with the regenerated current DLL:

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only todo49-captured-kle
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only todo49-route-adapter
```

The metadata FIFO, peek protocol and owned route registrations preserve the
captured layout/modifier interpretation for admitted KLE routes. Unsupported
transformed Caps/AltGr/deadkey/tap/chord/observer cohorts remain fenced until
their event-level consumers and native evidence exist. This does not close
TODO49 or remove the physical acceptance requirements below.

The following rows require production driver execution with synthetic documents
and an isolated user profile, then the same requested cases on the publication
owner's installed artifact. Unit or receiving-fixture passes do not replace them.

| Item   | Execute after cold start and reload                                                                                                                         | Required result                                                                                           | Environment                                                                                           |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| 51     | Arrow navigation, Shift/Tab acceptance, tap/hold, emulation on/off, AltGr, script/HKL transitions and held/repeated releases                                | Exact document/caret output, balanced releases, unchanged clipboard/configuration on refusal              | Real keyboard; both Windows versions where requested                                                  |
| 51     | HSE/long expansion, paste/prediction with and without overlapping physical typing; menu/version/editor cancellation, rollback and source removal            | No loss, duplicate or interleaving; refused/cancelled writes retain prior state and unknown personal data | Receiving applications plus real keyboard; source and installed artifact                              |
| 101    | Enable metrics; switch between synthetic Edit/Notepad documents, browser private context and password field; wait across configured idle/session boundaries | Exactly paired accepted session/idle closures, private text withheld, no duplicate publication            | Native UIA, actual focus/session events; a VM is sufficient for ordinary desktop apps                 |
| 101    | Pause/resume, reload and shutdown while a session is open; make the owned log destination temporarily unwritable, then restore access                       | Refusal retains retryable owner/debt; successful retry closes exactly once; stale owner cannot publish    | Isolated native user/log directory; preserve existing user files                                      |
| 49/101 | Lock/unlock and secure-desktop transition with held input; capture a new timestamped diagnostic if the debt recurs                                          | Private contexts remain fail-closed; actual closure/release debt and owner identities retained            | Native OS session; VM can exercise session transitions, physical keys needed for physical-held cohort |

Retain current-source hashes, tool/OS/application versions, exact expected versus
observed synthetic document/caret states and privacy-safe lifecycle/error logs.
Do not retain password text, personal window titles or private page content.
The historical `watchers=0` diagnostic is lost and has no established cause;
new stalls must be measured before attributing them to hooks or tooltip code.

No new user-facing strings or cross-driver feature policy are introduced by
these Windows-only diagnostic tools. macOS/Linux cannot execute the Win32 DLL,
AHK native Edit or GDI calls; their portable tests remain distinct evidence.

## Guarded canonical output planning

The actual native FIFO now authenticates an output preview by owner, capture
identity, immutable event sequence and current queue index. The AHK consumer
supplies UTF-16 from the retained canonical KLE model with an explicit neutral
state. Previews copy literal Unicode DOWN/UP units and frozen natural modifier
edges. They never send input, acknowledge an output prefix, consume a queued
physical edge, change live composition, or enable a partial handler cohort.

The portable output owner implements unique plan and attempt identities, exact
accepted prefixes, zero-acceptance debt, immutable suffix retries (including a
stranded Unicode UP), zero-unit character UP consumption, and refusal to abandon
accepted output. Seven independent C matrices pass normally and under ASan/UBSan;
four deliberate mutations are rejected. A real routing-core interoperability
regression failed before correcting held registration identities on unregistered
snapshots. The native preview regression preserves the capture receipt across
successful and refused plans and rejects a moved queue index after partial raw
replay. These are container software results, not Windows delivery evidence.

```bash
node tools/test/run-nav-event-owner-portable.cjs
node tools/test/test-windows-nav-portable-registration.cjs
node tools/test/run-windows-terminal-output-plan.cjs
node tools/test/run-windows-terminal-output-plan.cjs --sanitize
```

Expect **43/43** portable production C cases, **44** authored native registrations
plus six source-selection negative controls, and **7/7** output planning matrices.
The native editor receiver remains excluded on Linux. After the official Windows
DLL/manifest regeneration, run the pinned AHK runtime:

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only todo49-output-preview
```

Expect six AHK canonical-preview cases. These execute AHK with injected native
boundaries; they do not qualify a native SendInput emitter. The actual DLL preview
and all C matrices also run through the official MSVC generator. The current
native DLL source/export contract requires **40 exports**; tracked bytes and
manifest must be regenerated officially, never restamped from Linux.

Transformed production replay remains disabled. Remaining software includes
whole-cohort nonhook dispatch and observer migration, event-owned Caps/AltGr,
dead-state, tap/hold, prefix and shortcut semantics. The native plan/FIFO custody
coupling described below is implemented; its real delivery consumer remains
fenced with the complete cohort. Handler migration must preserve external
modifiers and cancel/abort recovery before activation. A native VM is
needed to observe AHK HotIf/custom-combo/InputHook delivery and rehook behavior;
a real keyboard is then needed for simultaneous physical typing and modifier
holds. Neither a portable planner nor a mocked AHK preview closes TODO49.

## Guarded output and FIFO custody

The native owner now retains the canonical output plan against the exact current
FIFO head, using capture token, immutable sequence, plan identity and a separate
identity for each output attempt. Its five custody APIs are part of the official
**40-export** source contract. They never choose or invoke an OS send primitive.
The production admission function always refuses; a testing-only grant is absent
from the shipped DLL and its export definition. Native qualification is unchanged.

An acquired attempt leaves the original physical edge in the FIFO. Exact partial
acceptance advances only the immutable output prefix; zero acceptance leaves the
whole suffix retryable. Invalid counts, stale attempts, owners, tokens and plans
cannot acknowledge another event. Consumption removes exactly one authenticated
head only after every output unit is settled, including a stranded Unicode UP.
Zero-unit character UP still requires explicit consumption. Cancellation is
allowed only before any output acceptance and without an outstanding attempt;
it preserves the original edge for raw abort recovery.

Raw commit/abort, reentrant planning and shutdown cannot steal an active output
plan. Shutdown also retains physical tail or overflow debt after that plan has
retired. Authentic physical capture can append while a caller's attempt remains
outstanding. Overflow preserves the existing plan, its remaining output and the
faulted physical suffix; settling the earlier output never erases the lost-edge
fault. New plans refuse faulted or unknown metadata rather than silently deleting
an unconverted event.

Reproduce the two actual production-C custody regressions on Linux:

```bash
node tools/test/run-nav-event-owner-portable.cjs 'terminal output custody settles exact FIFO head (todo49-output-custody)'
node tools/test/run-nav-event-owner-portable.cjs 'terminal output custody preserves fault debt (todo49-output-custody)'
```

Both must report **1/1**. The complete portable gate reports **43/43** with
**44** native registrations; the native editor receiver remains excluded.
Five deliberate actual-source mutations fail genuine assertions for raw-release
custody, unsettled consumption, whole-suffix acknowledgement, shutdown debt and
the default cohort guard. All original C assertions are preserved. The native
MSVC generator executes these same authored cases with the official current
sources; that Windows execution remains unrun here.

Production cohort admission requires a measured native delivery contract before
wiring the final nonhook handlers and observers. AutoHotkey conditional admission
and custom combinations do not expose the native hook's authenticated event
receipt; their callback suppression and InputHook notifications can vary around
hook installation and SendInput reinstallation. Capture must suppress every
converted physical observer in either observed callback order while deliberate
nonhook dispatch publishes that observer exactly once. A Windows VM must trace
those callback boundaries and establish the supported receipt/admission contract.
The implemented routing, canonical preview, output planning and FIFO custody can
then be consumed without guessing that contract. Complete handler migration and
native delivery execution remain required; a real keyboard separately validates
simultaneous physical input, repetitions and effective modifier holds.

## Exact ABI byte custody

Immutable snapshots and returned edges use `memcpy` across pure and native
output owners. C17 section 6.2.6.1 paragraph 6 does not guarantee padding
identity after struct assignment, while the authenticated FIFO contract compares
complete receipt bytes. The seventh matrix pins 13 nonzero padding bytes and
checks the full 168-byte snapshot and 24-byte edge. It passes normally and under
ASan/UBSan; two deliberate padding-loss mutations abort on genuine assertions.
The old assignments also pass this matrix with GCC 14.2 at `-O2`; this is a
representation guarantee correction, without a fabricated historical failure.
The source ABI now has 40 exports, with 43 portable/44 native cases.

## AHK output custody coordination

The committed adapter retains canonical units, exact plan keys and separate
attempt identities against the original route owner/generation. It validates
all buffer sizes before decoding, rejects forged or mutable handles, and retains
unknown native receipts after a callback throws or returns an unrecognized ACK.
Neither it nor the native owner emits input or grants incomplete cohort
admission. Twelve authored AHK regressions remain **UNEXECUTED** here; the source
guard checks the five real DllCall helpers, ABI widths and thirteen negative controls
without claiming interpreter execution.

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut static/ergopti_plus/windows/tests/run_all.ahk --only todo49-output-custody-adapter
```

Require the exact twelve registered cases, zero failures and no missing
selection. These injected-port cases precede real native delivery qualification.

## Bounded native callback trace

Three opt-in diagnostic exports extend the existing 37 operations to **40**.
Disabled production runs do not query QPC. Activation requires a same-process
foreground HWND and its exact focused receiver; each enabled native callback
rechecks those identities before copying raw input. Lost ownership records an
incomplete-evidence receipt without copying a foreign payload. The 256-entry
buffer never overwrites old observations, retains sticky overflow/drop counts,
and permits exact read-only pages after Stop. Owner, token and generation fence
all operations. Deterministic test dispatch cannot manufacture native traces.

Six independent pure C matrices pass normally and under ASan/UBSan; four actual
assertion mutations fail. The protocol reader passes two independent positive
fixtures and **46 negative controls**, including escaped/duplicate JSON fields,
stale identities, missing callback channels and dropped events. The source guard
retains all 40 exports and rejects thirteen source mutations. These container checks
are not observations of Windows callbacks.

```sh
npm run test:windows-hook-trace-core
node tools/test/run-windows-hook-trace-core.cjs --sanitize
npm run test:windows-hook-trace-protocol
npm run test:windows-hook-trace-source
```

After the official DLL/manifest generation, use the native VM preconditions
above, with an idle keyboard and no other driver instance. Run both requested
installation sequences in fresh output directories:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-trace.ps1 -Interactive -Samples 3 -InstallSequence ahk-before-native
powershell -NoProfile -ExecutionPolicy Bypass -File tools/diagnostics/run-windows-group7-trace.ps1 -Interactive -Samples 3 -InstallSequence native-before-ahk
```

The isolated native Edit receives six synthetic `a` cases: three SendEvent and
three SendInput. A complete receipt requires the actual native DOWN/UP flags,
extra-info marker and QPC, plus actual HotIf/hotkey/InputHook down/char/up
observations in each owned case, exact receiving and natural retirement.
Missing notifications or failed cleanup produce a failed receipt with retained
`stdout.jsonl`, `stderr.log` and `supervisor.json`; never invent the absent lane.
Successful verification produces `trace.json` and `phase=completed`, while
hook-order, physical and production qualification remain **false**.

Native entry QPC and append/completion sequence are separate: a reentrant
callback can append before its caller. Neither append order nor requested
installation sequence proves actual low-level callback order. Synthetic
injected events must have `capture_sequence=0`; they cannot qualify physical
FIFO capture or the full production handler cohort. Interpret these native
observations before the remaining nonhook handler/observer migration. Real
keyboard capture, effective modifier holds, repeat/release and overlapping
typing remain separate physical experiments. The AHK/PowerShell supervisor and
MSVC generation are **UNEXECUTED** in this container.

The AHK harness records actual VK/SC only for InputHook down/up arguments and
actual codepoints for char callbacks. HotIf/hotkey observations carry an explicit
registered-fixture label, with the actual HotIf decision. Attribution to the owned
case/QPC window is separate from native edge identity. The protocol retains all
original 38 controls and adds eight refusals; the source guard adds four mutations.

The twelve custody cases retain all 139 original assertion calls. Four loop
closures now use immediate `.Bind(...)` arguments so an AHK UnsetError cannot
falsely satisfy a product-refusal assertion. The unmodified portable scanner
rejects all four original captures and accepts the correction at baseline zero;
four source mutations prevent regression. Actual AHK execution remains unrun.

The managed Ollama 150 ms ownership watch is documented in both existing timer
inventories without changing its cadence, floors or stale-entry assertions.
The native full unit run must also pass the five `meta timers:` cases.
