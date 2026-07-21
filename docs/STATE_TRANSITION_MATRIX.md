# Garantie G5: State Transition Matrix

**Purpose**: Define all driver states and valid transitions to ensure no illegal transitions occur. Specifically, this prevents data corruption or orphaned processes by preventing background fetches or async state machines from crossing over critical transitions like `Suspend` (Pause) or `ExitApp` (Shutdown/Update).

## Driver States
1. `BOOTING`: Auto-execute phase and `BuildTrayMenuDeferred`.
2. `ACTIVE`: Normal operation.
3. `SUSPENDED`: "Pause = tout éteint". All keyboard hooks disabled, all background async network traffic suspended.
4. `UPDATING`: The driver is writing the new binary to disk and launching the swap batch script. This is a terminal state.

## Valid Transitions

| From | To | Trigger | Guards / Required Actions |
|---|---|---|---|
| `BOOTING` | `ACTIVE` | Boot complete | Tray icon shown, hooks enabled, background checks scheduled. |
| `ACTIVE` | `SUSPENDED` | `ToggleSuspend` / `Ergopti_OnSuspendEnter` | - Must cancel all timers (`_LLM_Deps_PollTimer`, `_LLM_PointerWatch_Stop`, `_UpdaterAsyncRequests`).<br>- Must cancel `LLM_Ollama_WarmupRetryTick`.<br>- A staging download caught mid-flight MUST be terminated, so nothing completes a write while the driver is supposed to be off. |
| `SUSPENDED` | `ACTIVE` | `ToggleSuspend` / `Ergopti_OnSuspendResume` | - Restore tray icon.<br>- Re-arm pointer watchers.<br>- Resume polling timers. |
| `ACTIVE` | `UPDATING` | `Updater_DownloadAndInstall` | - Mutex: `_UpdaterDownloadInProgress` flag prevents concurrent updates.<br>- The download is staged by a PowerShell child process (`_Updater_BuildStagingWorkerScript`); AHK only polls it and receives a READY token. No disk write happens on the AHK thread, so there is nothing here to make non-interruptible. |

## Invalid (Illegal) Transitions

1. **`SUSPENDED` -> `UPDATING`**
   *Why*: A polling timer bypassing `Suspend` could finish its download and call `ExitApp` while the user believes the driver is completely inactive ("tout éteint").
   *Fix*: `_Updater_MonitorStagingWorker` begins with an `A_IsSuspended` check and terminates the child worker.

2. **Interrupting `UPDATING` with `SUSPENDED`**
   *Why*: The obvious defence — making the completion block non-interruptible — is the WRONG one here, and this document used to prescribe it. Cancellation must stay possible: `Critical` on the monitor would prevent `Suspend` from terminating a staging worker that is already running, which is the very outcome the illegal transition above forbids.
   *Fix*: keep the monitor interruptible and let it terminate the child. `tests/meta/test_g5_updater_download.ahk` pins exactly this — it asserts `A_IsSuspended`, asserts `.terminate()`, and asserts that `Critical(` is **absent**. Do not reintroduce it.
