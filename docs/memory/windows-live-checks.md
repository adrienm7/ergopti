<!-- docs/memory/windows-live-checks.md -->

# Windows live checks memory

How `tools/maintainer/windows-live-checks.cjs` drives a real driver, and what
cost time while building it. Usage and the manual list are in
[windows-maintainer-checks](../tooling/windows-maintainer-checks.md).

### project-live-checks-boot-through-the-smoke-hooks

The startup smoke boots the real entry in an isolated profile and calls three
optional globals: `_DriverStartupSmokeInspectShell` once the complete root is
published and input is not ready (the moment a click "during startup" can
happen), `_DriverStartupSmokeInspect` at ready, then `ExitProcess`. A wrapper
that defines them before `#Include ErgoptiPlus.ahk` can serve commands from the
ready hook instead of exiting, and click rows from the shell hook. Top-level
statements placed after the include never run: register commands before it.
Run the wrapper from Node or PowerShell, never Git Bash (`/ErrorStdOut` is path
mangled and the child hangs on a dialog).

### project-live-checks-click-with-wm-command-and-drive-from-timers

A tray row is clicked by `PostMessageW(A_ScriptHwnd, WM_COMMAND, itemId)`: a
window-title search cannot find the hidden main window. The click runs as a new
thread on top of the one that is pumping. A modal dialog it opens (InputBox,
MsgBox) blocks the interrupted thread, so answer it from a timer armed before
the click. A timer thread is not interrupted by another timer, so it must not
wait for something a second timer does (a window's own close handling): schedule
the close with a one-shot timer and wait on the main thread. No timer runs while
a native popup menu is open (the key-combination pair menu): build it through
its test seam and post the chosen row instead of showing it.

### project-live-checks-real-keys-need-send-event-and-a-quiet-desktop

Input a separate process sends with `SendInput` at level 0 reaches hotkeys but
not the `I1` InputHook the hotstring watcher uses; `SendEvent` at `SendLevel`
100 reaches both. Any other ErgoptiPlus driver on the desktop sees the same
keys: with the maintainer's driver running, `c★` expanded twice (« c’esc’est »)
and its keystats ledger recorded the test keys. Judge such a check from the
private driver's own state (`HSE_Buffer`, its log), and leave CapsWord, which
writes the real CapsLock state, to a desktop with no other driver.

### project-a-smoke-boot-never-owns-the-session-keyboard

A smoke skips the single-owner mutex, so it boots a whole driver beside the
resident one. On 2026-11-02 a boot-cost bench on the maintainer's copied config
failed its readiness receipt and stayed resident: its log showed his physical
Enter, and he got `ppoouurr` and `jjoou` for `a,ou`. Two remappers each emit the
key, and two engines each send the same paced burst, Backspaces included.
`DriverSmokeInput_Decide` now boots a smoke paused unless it runs on CI or asks
for `ERGOPTI_STARTUP_SMOKE_LIVE_INPUT`; that request beside a resident ends the
boot. The native hook ignores Suspend, so it is not started. Any uncaught error
ends a smoke, ready or not, and a 150 s deadline ends an orphan. A pause guard
on a boot write must let a quarantined smoke through (`_PersonalWritesPaused`).
Action: never bypass `ERGOPTI_STARTUP_SMOKE_DIR` to boot the entry beside a
driver. Read suspended state from `A_IsSuspended`: `ListHotkeys` still shows
`k-hook` for a paused parse-time hotkey. `(smoke-input-quarantine)` pins it.

### project-live-checks-hse-reset-makes-the-word-start-unknown

`hse_reset` calls `HSE_HardReset`, which no driver path calls and which leaves
`HSE_StartIsWordBoundary` false, so a word-start trigger typed next refuses. The
idle reset hides this from the second word of a session on (the pause before its
first key restores a known start), but not from the first: the driver has no
previous keystroke to measure. A check about word-start triggers therefore skips
`hse_reset`: only a scenario that needs the unknown start (Backspace word start)
uses it. A refusal measured after it proves nothing.

### project-live-checks-send-restores-capslock

A `Send` that is not `{Blind}` lifts CapsLock around its keys and restores it
when it ends, even a Send from another process. CapsWord ends between those two
moments on the driver side, so `{Space}` put the toggle back on 15 ms after
CapsWord had turned it off and the next word came out in capitals: a false
failure, the driver had done its work (a probe saw `CapsWordEnabled` 0, `SC039`
as the hotkey, U+0009 in OnChar). Named keys of a CapsLock check are therefore
`{Blind}{SC039}`, the form a physical key takes. `{Text}` is a packet and is safe.

### project-live-checks-quiet-logs-do-not-prove-an-idle-driver

A scope restore or clear spends seconds inside native menu code without logging
(about 17 s measured on a loaded machine), and a reload successor logs nothing
while it parses. "Quiet" therefore needs a command the driver answers (its only
thread is free) and a single live process of the session; counting the log is
not enough.

### project-live-checks-a-held-write-delays-every-menu-click

`MenuDispatcher` holds a click behind a configuration write for 10 s before it
runs it, so a Quit clicked under a held lease reports its refusal after 10 s plus
its own 12 s deadline. A check that waits for only the deadline sees nothing and
blames the driver. Read the log with `waitForLog` for both.

### project-live-checks-silent-hang-is-a-blocked-command

A command that gives « no answer » with an idle driver is not a frozen driver:
the serving thread lies under a thread that waits. A dialog's opener sits in
`WinWaitClose` over the command, and a native context menu runs its own loop on
the only thread. Before suspecting the driver, attach AutoHotkey's debugger late
(post the registered message `AHK_ATTACH_DEBUGGER` with the IP and port to the
script's hidden window, then `stack_get` over DBGp): a `--keep` trace cannot show
this, and timing probes inside the timer can hide it. So a dialog is pressed with
`LiveClickDialogButton`, never `ControlClick`, and the typist cancels the menu of
a right click.

### project-live-checks-menu-click-replay-exercises-two-close-races

The successor's close request can run OnExit on top of any thread. Over a log or
keystats flush, the owner under OnExit can only resume once OnExit returns, so
waiting inside it cannot work: `ReloadTerminalHandoffDeferClaim` puts the reload
back to pending and retries the same exit once the owner settled, keeping the
successor, which asks only once. Over `MenuStartupCommands.Drain`, the rows not
reached yet are handed to the next successor by `TakeForReload`. Each metrics
toggle reloads, so this check chains about five reloads. Action: when it fails
again, read the phase in the log; do not mask the error in the check.

### project-live-checks-a-vetoed-exitapp-does-not-return

A veto ends the thread that called `ExitApp`; only its `finally` still runs, so
nothing written after the call answers a refused Quit. `_LifecycleRefuseShutdown`
arms `_LifecycleAnswerVetoedQuit` instead, and a retry armed by the gate keeps the
answer owed. Any exit that interrupts a flush or a read goes through
`_LifecycleArmFlushExitRetry`, which keeps the OnExit reason (a retried logoff is
no Quit) and leaves an updater exit to the updater's retry, as a plain `ExitApp`
would skip `FinalExit`. `quit-over-a-log-flush` is the live check. Windows may end
the process right after a vetoed logoff, so that retry is best effort. Action: a
new shutdown gate that settles by itself uses this retry and logs no error.

### project-live-checks-versions-window-needs-memory

`Changelog_Open` opens its WebView2 form only when `WebView_ShouldUseNativeFallback()`
is false; below its free-memory threshold it opens the native window and there
is no page to read. The check reports that as not executed.

### project-an-isolated-driver-writes-no-machine-touchpad-key

A smoke or live-check driver shares the signed-in user's HKCU: on 2026-11-11
`clear-restore-categories` clicked the Gestures Clear all of a fresh profile,
which has no touchpad backup, and the owner wrote the Windows factory values
over the maintainer's own gesture settings. Under `ERGOPTI_STARTUP_SMOKE_DIR`
the owner (`modules/gestures/touchpad_registry.ahk`) now swaps every machine
port, a caller's included, for the profile's `touchpad_registry_private.txt`,
and every launcher of the elevated device restart asks
`TouchpadRegistrySkipsDeviceRestart` first. Judge a touchpad outcome from that
file; the real key is read only to catch a leak. Action: a new machine-scoped
writer (Startup folder, `HKCU\Software\Ergopti\Storage`, an OS setting) follows
the same rule before a live check clicks it.
