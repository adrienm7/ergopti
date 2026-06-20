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
| `ACTIVE` | `SUSPENDED` | `ToggleSuspend` / `Ergopti_OnSuspendEnter` | - Must cancel all timers (`LLM_Deps_PollTimer`, `_LLM_PointerWatch`, `_UpdaterAsyncRequests`).<br>- Must cancel `LLM_Ollama_WarmupRetryTick`.<br>- Any running background download (`_Updater_PollDownloadAsync`) MUST be aborted if caught mid-flight, to prevent mid-write completion while suspended. |
| `SUSPENDED` | `ACTIVE` | `ToggleSuspend` / `Ergopti_OnSuspendResume` | - Restore tray icon.<br>- Re-arm pointer watchers.<br>- Resume polling timers. |
| `ACTIVE` | `UPDATING` | `Updater_DownloadAndInstall` | - Mutex: `_UpdaterDownloadInProgress` flag prevents concurrent updates.<br>- Critical Section: The block that writes `Stream.SaveToFile` and calls `ExitApp` MUST be marked `Critical On` so that a `ToggleSuspend` hotkey cannot interrupt it mid-write. |

## Invalid (Illegal) Transitions

1. **`SUSPENDED` -> `UPDATING`**
   *Why*: A background download polling timer (`_Updater_PollDownloadAsync`) bypassing `Suspend` could finish its download and call `ExitApp` while the user believes the driver is completely inactive ("tout éteint").
   *Fix*: `_Updater_PollDownloadAsync` must begin with `if A_IsSuspended { try Req.Abort(), return }`.

2. **Interrupting `UPDATING` with `SUSPENDED`**
   *Why*: If a hotkey invokes `ToggleSuspend` during the `Stream.Write` or `FileAppend` phases of the updater, the thread is interrupted, creating a race condition where the script is technically suspended but actively tearing down the driver to swap binaries.
   *Fix*: The critical completion block in `_Updater_PollDownloadAsync` must be wrapped in `Critical On`.
