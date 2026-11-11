; ui/onboarding/gesture_registration.ahk

; ==============================================================================
; MODULE: Onboarding / Touchpad Gesture Registration
; DESCRIPTION:
; Registers the Precision Touchpad gesture shortcuts from the wizard's gestures
; page. The registry values are written in this resident process, then one
; elevated PowerShell worker cycles the touchpad device; it runs asynchronously
; and publishes its own result file, so the wizard never blocks on the UAC
; prompt and never mistakes a vanished process for a success. Definitions only:
; the test harness includes it to exercise the reservation without building the
; wizard.
; ==============================================================================

; Success token the elevated PowerShell worker writes to its result file
; ([string]$ErgoptiExitCode, 0 on success). Named because it is a NUMERIC
; STRING: comparing the reader's String|false result against `false` makes AHK
; v2 compare numerically, so "0" = false is TRUE and success reads as failure.
global GESTURE_AUTO_SUCCESS_TOKEN := "0"





; ===================================
; ===================================
; ======= 1/ Worker lifecycle =======
; ===================================
; ===================================

; The elevated worker writes its own result before it exits. Polling a PID and
; then asking OpenProcess for an exit code is racy: Windows may already have
; released the process object, and _SR_GetExitCode deliberately returns 0 in
; that case. A missing or malformed result is therefore a failure, never a
; false success shown to the user.
global _OnboardingGestureJob := Map("epoch", 0, "pid", 0, "script", "", "result", "", "done", 0,
	"starting", false)

_Onboarding_ReserveGestureAuto(Candidate, TimerFn := 0) {
	global _OnboardingGestureJob
	if !(Candidate is Map) || !Candidate.Get("starting", false)
		throw TypeError("Onboarding gesture reservation requires a starting candidate.")
	PreviousCritical := Critical("On")
	try {
		if _OnboardingGestureJob.Get("starting", false) || _OnboardingGestureJob["pid"]
			return false
		PollFn := _Onboarding_PollGestureAuto.Bind(Candidate["epoch"])
		if HasMethod(TimerFn, "Call")
			TimerFn.Call(PollFn, -TimingsGet("gestures", "worker_result_poll_ms"))
		else
			SetTimer(PollFn, -TimingsGet("gestures", "worker_result_poll_ms"))
		_OnboardingGestureJob := Candidate
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_Onboarding_AbortGestureAutoReservation(Epoch) {
	global _OnboardingGestureJob
	PreviousCritical := Critical("On")
	try {
		if (_OnboardingGestureJob["epoch"] == Epoch
				&& _OnboardingGestureJob.Get("starting", false)) {
			_OnboardingGestureJob["starting"] := false
			_OnboardingGestureJob["done"] := 0
		}
	} finally {
		Critical(PreviousCritical)
	}
}

_Onboarding_StartGestureAuto(OnDone) {
	global _OnboardingGestureJob
	if _OnboardingGestureJob.Get("starting", false)
		return false
	if _OnboardingGestureJob["pid"] {
		; Deliver a receipt before consulting the diagnostic PID. An old PID may
		; already identify an unrelated process by the time the click arrives.
		if FileExist(_OnboardingGestureJob["result"])
			_Onboarding_PollGestureAuto(_OnboardingGestureJob["epoch"])
		else if ProcessExist(_OnboardingGestureJob["pid"])
			return false
		else
			_Onboarding_PollGestureAuto(_OnboardingGestureJob["epoch"])
		if _OnboardingGestureJob["pid"]
			return false
	}
	; Write the values here, as the signed-in user, exactly like the tray action.
	; HKCU in an elevated worker is the hive of whichever account answered the UAC
	; prompt: a standard user typing an administrator's credentials configured
	; that administrator's touchpad while the backup held their own (WG-003). Only
	; the device restart needs elevation, and it touches no per-user state. The
	; owner backs up the user's values first, or writes nothing at all.
	if !TouchpadRegistryApply() {
		try LoggerError("Onboarding", "Gesture auto-config refused: the touchpad values were not backed up and written.")
		return false
	}
	; An isolated profile wrote its private key: no device restart, no UAC prompt.
	if TouchpadRegistrySkipsDeviceRestart(OnDone)
		return true
	Epoch := _OnboardingGestureJob["epoch"] + 1
	JobStem := A_Temp . "\ergopti_gesture_config_" . DriverPid . "_" . Epoch
	ScriptPath := JobStem . ".ps1"
	ResultPath := JobStem . ".result"
	Candidate := Map("epoch", Epoch, "pid", 0, "script", ScriptPath,
		"result", ResultPath, "done", OnDone, "starting", true)
	try Reserved := _Onboarding_ReserveGestureAuto(Candidate)
	catch as err {
		try LoggerError("Onboarding", "Could not arm gesture auto-config completion: {1}.", err.Message)
		return false
	}
	if !Reserved
		return false
	FSDelete(ResultPath)
	FSDelete(ResultPath . ".stage")
	; Windows PowerShell 5.1 otherwise decodes a BOMless source with the ANSI code page.
	if !FSWrite(ScriptPath, Chr(0xFEFF) . _GestureRestartBuildPsScript(ResultPath)) {
		_Onboarding_AbortGestureAutoReservation(Epoch)
		try LoggerError("Onboarding", "Could not write gesture PS script.")
		return false
	}
	Pid := 0
	try Run('*RunAs powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . ScriptPath . '"', , "Hide", &Pid)
	catch as err {
		FSDelete(ScriptPath)
		_Onboarding_AbortGestureAutoReservation(Epoch)
		try LoggerError("Onboarding", "Gesture auto-config launch failed: {1}.", err.Message)
		return false
	}
	PreviousCritical := Critical("On")
	try {
		if (_OnboardingGestureJob["epoch"] != Epoch
				|| !_OnboardingGestureJob.Get("starting", false))
			throw Error("Onboarding gesture reservation was lost before PID publication.")
		_OnboardingGestureJob["pid"] := Pid
		_OnboardingGestureJob["starting"] := false
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

_Onboarding_PollGestureAuto(Epoch) {
	global _OnboardingGestureJob
	if (_OnboardingGestureJob["epoch"] != Epoch)
		return
	if _OnboardingGestureJob.Get("starting", false) {
		SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -TimingsGet("gestures", "worker_result_poll_ms"))
		return
	}
	if !_OnboardingGestureJob["pid"]
		return
	; Suspend does not stop timers. Do not mutate onboarding UI or invoke a
	; callback while the keyboard driver is suspended; retain the job until it
	; resumes instead.
	if A_IsSuspended {
		SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -TimingsGet("gestures", "worker_result_poll_ms"))
		return
	}
	; The atomically published result is the terminal authority. Check it before
	; the diagnostic PID because Windows may already have recycled that number.
	if !FileExist(_OnboardingGestureJob["result"])
			&& ProcessExist(_OnboardingGestureJob["pid"]) {
		SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -TimingsGet("gestures", "worker_result_poll_ms"))
		return
	}
	Ok := _Onboarding_ReadGestureAutoResult(_OnboardingGestureJob["result"])
	Done := _OnboardingGestureJob["done"]
	FSDelete(_OnboardingGestureJob["script"])
	FSDelete(_OnboardingGestureJob["result"])
	FSDelete(_OnboardingGestureJob["result"] . ".stage")
	_OnboardingGestureJob["pid"] := 0
	_OnboardingGestureJob["done"] := 0
	if IsObject(Done)
		try Done.Call(Ok)
}

_Onboarding_ReadGestureAutoResult(ResultPath) {
	Result := FSRead(ResultPath)
	; FSRead returns a String on success and the INTEGER false on failure. Never
	; compare the result against false: AHK v2 compares NUMERICALLY when one side
	; is a number and the other a numeric string, so the success token "0"
	; satisfies `Result = false` (0 = 0) and every successful registration was
	; swallowed as "result missing". `==` does not help — it is numeric-equal here
	; too. Type-checking is the only correct discriminator.
	if !(Result is String) {
		try LoggerError("Onboarding", "Gesture auto-config result missing.")
		return false
	}
	Result := Trim(Result)
	if (Result != GESTURE_AUTO_SUCCESS_TOKEN) {
		try LoggerWarn("Onboarding", "Gesture auto-config returned invalid/failing result: {1}.", Result)
		return false
	}
	return true
}

