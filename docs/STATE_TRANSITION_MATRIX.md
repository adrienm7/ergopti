# Garantie G5: State Transition Matrix

**Purpose**: define the driver's states and the transitions between them, so that no
background work ever crosses a boundary it must not cross. Two boundaries actually
lose data or leave orphans: `Suspend` (Pause — « tout éteint ») and `ExitApp`
(shutdown, and the self-update swap that rides on it).

**Reading rule**: this page names the function that OWNS each transition. It does not
mirror the list of subsystems that function tears down. That list grows every time a
timer, an `InputHook`, an `OnMessage` handler or a subprocess is added, so a copy here
would rot silently and be believed anyway. Read the body of the named function — it is
the authority; this page only says which function that is, and what it is forbidden
from doing.

## Driver states

1. `BOOTING` — auto-execute phase, then `BuildTrayMenuDeferred` (`infra/lifecycle.ahk`)
   builds the tray menu off the boot critical path.
2. `ACTIVE` — normal operation.
3. `SUSPEND_PENDING` — the user asked to pause while a custom-combination prefix key
   (`SUSPEND_CUSTOM_COMBO_PREFIX_KEYS`) is still physically held. `Suspend(1)` has NOT
   been called yet; nothing is torn down. AHK's prefix-down flag latches across
   `Suspend` and cannot be cleared synthetically, hence the wait.
4. `SUSPENDED` — « Pause = tout éteint ». Native `Suspend` disarms hotkeys and
   hotstrings only; every subsystem that bypasses it (`InputHook`, `SetTimer`,
   `OnMessage`, spawned processes) is torn down explicitly.
5. `UPDATING` — a staging transaction is in flight. Staging itself runs in a
   PowerShell **child process**; the AHK side only polls it.
6. `EXITING` — `Ergopti_OnShutdown`, wired to `OnExit`. Reached by `ExitApp`, by
   `Reload` (the driver's own apply-settings path), and by a successful update.

## Valid transitions

| From | To | Trigger | Owner / guards |
|---|---|---|---|
| `BOOTING` | `ACTIVE` | boot complete | Hooks enabled, tray icon shown, `BuildTrayMenuDeferred` armed off the critical path, background checks scheduled. |
| `ACTIVE` | `SUSPEND_PENDING` | `ToggleSuspend` while `_SuspendPrefixesAreClear()` is false | `_SuspendPendingPoll` armed at 25 ms; the held keys are named in the log so the user knows which one to cycle. |
| `SUSPEND_PENDING` | `ACTIVE` | second `ToggleSuspend` | Cancels the deferral. Nothing was torn down, so there is nothing to restore — the escape hatch must never itself be swallowed. |
| `SUSPEND_PENDING` | `SUSPENDED` | prefix keys released, or `SUSPEND_DEFER_TIMEOUT_MS` elapsed | Past the deadline `_ReleasePhantomModifiers()` is tried once, then the driver suspends anyway and logs an ERROR naming the still-held key. Fail loudly rather than hang silently. |
| `ACTIVE` | `SUSPENDED` | `ToggleSuspend` with prefixes clear | `Suspend(1)`, then `_SuspendStateWatchdog` → `UpdateTrayIcon()` + `Ergopti_OnSuspendEnter()`. |
| `SUSPENDED` | `ACTIVE` | `ToggleSuspend` | `Suspend(0)`, then `_SuspendStateWatchdog` → `UpdateTrayIcon()` + `Ergopti_OnSuspendResume()`. Every teardown done on entry must have a matching re-arm here, gated on the same feature flag. |
| `ACTIVE` | `UPDATING` | `Updater_DownloadAndInstall` | Mutex: the `_UpdaterDownloadInProgress` flag rejects a duplicate call (two dialogs can both reach it). `_Updater_StartStagingWorker` spawns the PowerShell worker and arms `_Updater_MonitorStagingWorker` at `UPDATER_ASYNC_POLL_MS`. |
| `UPDATING` | `ACTIVE` | worker failed, or was cancelled | `_Updater_EndDownloadTransaction()` clears the mutex and rebuilds the menu. It is the ONLY way out of the mutex — every failure path must call it or the updater latches until restart. |
| `UPDATING` | `EXITING` | worker returned the `READY` token | `_Updater_PollDownloadAsync` launches the swap script and calls `ExitApp(0)`. It re-checks `A_IsSuspended` first and discards the completion if the driver was paused meanwhile. |
| any | `EXITING` | `ExitApp` / `Reload` | `Ergopti_OnShutdown` flushes the RAM-buffered keylogger and closes WebViews. Every step is `try`-wrapped: an `OnExit` callback that throws is swallowed by AHK and can hang the exit. |

`_SuspendStateWatchdog` serialises the two suspend reactors behind a `_TransitionBusy`
static. AHK pseudo-threads are interruptible, so without it a rapid double toggle could
interrupt `Ergopti_OnSuspendEnter` with `Ergopti_OnSuspendResume` and leave a resumed
driver half torn down; the repeating watchdog tick re-detects the real state afterwards
and dispatches the correct reactor once.

## Invalid (illegal) transitions

1. **`SUSPENDED` → `UPDATING`, or a staging transaction completing while suspended**

   _Why_: a poller that bypasses `Suspend` could finish its download and call `ExitApp`
   while the user believes the driver is completely inactive.

   _Defence_ — four independent layers, because any single one can be bypassed:
   - `_Updater_MonitorStagingWorker` runs on its own timer and, while `A_IsSuspended`,
     calls `_UpdaterDownloadWorker.terminate()` and ends the transaction.
   - `_SR_HandleTerminate` kills the `cmd.exe` child tree before falling back to the
     direct process, otherwise the PowerShell staging process survives its parent.
   - `_SR_Poll` (`adapters/shell_runner.ahk`) refuses to fire any `OnDone` callback
     while suspended; tasks stay queued for the first tick after resume.
   - `Ergopti_OnSuspendEnter` calls `_Updater_CancelAsyncChecks()`, which fires each
     pending `on_json("")` so consumers reset instead of latching a disabled menu item.

2. **Making the completion path non-interruptible**

   _Why_: the obvious defence — wrapping the monitor in `Critical` — is the WRONG one,
   and this document used to prescribe it. `Critical` on the monitor would stop
   `Suspend` from terminating a staging worker that is already running, which is exactly
   the outcome the illegal transition above forbids. Cancellation must stay possible.

   _Pinned by_: `static/ergopti_plus/windows/tests/meta/test_g5_updater_download.ahk`
   asserts `A_IsSuspended` is
   present, `.terminate()` is present, and `Critical(` is **absent**. Do not reintroduce
   it.

3. **Disk or network work on the AHK thread during `UPDATING`**

   _Why_: AHK's single interpreter thread is also the keyboard hook thread. Response-body
   COM, file persistence, the Content-Length and minimum-size checks and the swap-script
   creation would each freeze the keyboard for their whole duration.

   _Defence_: all of it lives in the PowerShell text returned by
   `_Updater_BuildStagingWorkerScript` and runs in the child process, which reports back
   a single `READY` token. Paths and URLs are passed as `argv`, never interpolated into
   the script, so release metadata cannot alter the commands. Do not move any of that
   work back onto the AHK side.
