; tests/meta/test_updater_worker_terminated_on_exit.ahk

; ==============================================================================
; MODULE: Update Staging Worker Exit-Teardown Meta Test
; DESCRIPTION:
; Static source guard for updater-staging-worker-orphaned-on-exit.
;
; Updater_DownloadAndInstall spawns a DETACHED PowerShell child through
; ShellRunner (plain Run with no job object) that downloads the release asset
; and writes swap_update.cmd. The swap script is launched from exactly one place
; in the whole driver, _Updater_PollDownloadAsync, i.e. from a callback owned by
; the process that spawned the worker.
;
; Ergopti_OnShutdown is the driver's single OnExit handler, and AHK's Reload()
; and ExitApp() run nothing else on the way out. Reload is the driver's standard
; "apply settings" mechanism and also fires automatically from the keyboard-
; layout watcher, so a Reload landing mid-download used to leave the child alive
; with nobody able to complete it: it finished, wrote ErgoptiPlus_new.exe and
; swap_update.cmd, and exited, while the fresh instance re-zeroed
; _UpdaterDownloadInProgress and performed no residue scan. The user who clicked
; "Update now" got no update, no error, and not one log line in the new
; instance's log — and the next explicit attempt deletes the staged files first,
; erasing the evidence.
;
; The codebase had already recognised this hazard once and guarded exactly ONE
; Reload site (Updater_SetChannel, updater-channel-switch-download-race). This
; guard pins the seam that covers ALL of them: the process-exit handler.
;
; Meta-static because reproducing it needs a real multi-megabyte download racing
; a real Reload.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ The exit seam tears the worker down =======
; ======================================================
; ======================================================

_UWTE_ShutdownAbortsStagingWorker() {
	Body := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(Body != "", "Ergopti_OnShutdown() must exist in the driver source")

	Assert(InStr(Body, "_UpdaterDownloadWorker") > 0 or InStr(Body, "_Updater_AbortStagingOnExit") > 0,
		"the driver's single OnExit handler must tear down an in-flight update staging worker: Reload and ExitApp run no per-module destructor, and the staged swap script is launched only from _Updater_PollDownloadAsync, so an orphaned worker means the user's 'Update now' click silently installs nothing (updater-staging-worker-orphaned-on-exit)")

	; The exit handler must never throw — AHK swallows an OnExit exception and
	; can hang the exit — so the teardown has to be try-wrapped like its siblings.
	Assert(RegExMatch(Body, "try\s+_Updater_AbortStagingOnExit\(\)") > 0,
		"the staging teardown must be try-wrapped, like every other step of Ergopti_OnShutdown: an OnExit callback that throws is swallowed by AHK and can hang the exit")
}
Test("updater: process exit tears down an in-flight staging worker (updater-staging-worker-orphaned-on-exit)", _UWTE_ShutdownAbortsStagingWorker)





; =================================================
; =================================================
; ======= 2/ The teardown actually kills it =======
; =================================================
; =================================================

_UWTE_AbortHelperTerminatesAndLogs() {
	Body := _DriverFuncBody("_Updater_AbortStagingOnExit")
	Assert(Body != "", "_Updater_AbortStagingOnExit() must exist in the driver source")

	Assert(InStr(Body, ".terminate()") > 0,
		"_Updater_AbortStagingOnExit must terminate the ShellRunner task: the PowerShell child is detached (spawned with a plain Run, no job object), so it outlives the process swap unless it is killed explicitly")
	Assert(InStr(Body, "SetTimer(_Updater_MonitorStagingWorker, 0)") > 0,
		"_Updater_AbortStagingOnExit must disarm the staging monitor timer, so the teardown leaves no armed callback behind")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"an interrupted update must be VISIBLE: the whole defect was that the download vanished without a single log line, so the abort has to say so at WARNING level rather than exit quietly")
}
Test("updater: the exit teardown kills the staging child and logs it (updater-staging-worker-orphaned-on-exit)", _UWTE_AbortHelperTerminatesAndLogs)
