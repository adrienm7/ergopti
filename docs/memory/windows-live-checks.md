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

### project-live-checks-quiet-logs-do-not-prove-an-idle-driver

A scope restore or clear spends seconds inside native menu code without logging
(about 17 s measured on a loaded machine), and a reload successor logs nothing
while it parses. "Quiet" therefore needs a command the driver answers (its only
thread is free) and a single live process of the session; counting the log is
not enough.

### project-live-checks-versions-window-needs-memory

`Changelog_Open` opens its WebView2 form only when `WebView_ShouldUseNativeFallback()`
is false; below its free-memory threshold it opens the native window and there
is no page to read. The check reports that as not executed.
