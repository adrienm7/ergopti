; ui/onboarding/gesture_registration.ahk

; ==============================================================================
; MODULE: Onboarding / Touchpad Gesture Registration
; DESCRIPTION:
; Registers the Precision Touchpad gesture shortcuts from the wizard's gestures
; page. One elevated PowerShell worker writes the registry values and cycles the
; touchpad device; it runs asynchronously and publishes its own result file, so
; the wizard never blocks on the UAC prompt and never mistakes a vanished
; process for a success. Definitions only: the test harness includes it to
; exercise the reservation without building the wizard.
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
			TimerFn.Call(PollFn, -100)
		else
			SetTimer(PollFn, -100)
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
	; The elevated script overwrites the touchpad values: the one registry owner
	; backs up the user's own first, or nothing is written at all.
	if !TouchpadRegistryEnsureBackup() {
		try LoggerError("Onboarding", "Gesture auto-config refused: the touchpad values could not be backed up.")
		return false
	}
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
	if !FSWrite(ScriptPath, _Onboarding_BuildGesturePsScript(ResultPath)) {
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
		SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -100)
		return
	}
	if !_OnboardingGestureJob["pid"]
		return
	; Suspend does not stop timers. Do not mutate onboarding UI or invoke a
	; callback while the keyboard driver is suspended; retain the job until it
	; resumes instead.
	if A_IsSuspended {
		SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -100)
		return
	}
	; The atomically published result is the terminal authority. Check it before
	; the diagnostic PID because Windows may already have recycled that number.
	if !FileExist(_OnboardingGestureJob["result"])
			&& ProcessExist(_OnboardingGestureJob["pid"]) {
		SetTimer(_Onboarding_PollGestureAuto.Bind(Epoch), -100)
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





; ================================
; ================================
; ======= 2/ Worker script =======
; ================================
; ================================

; Builds a self-contained PowerShell script that writes every PrecisionTouchPad
; registry value AND restarts the touchpad PnP device so the new gesture map
; takes effect without a logout. The key and the values come from the generated
; touchpad table through its one owner (modules/gestures/touchpad_registry.ahk),
; the same table the in-process writer uses; the caller has already backed up
; the values it replaces. Functions, not globals, so the wizard can build it
; before modules/gestures/init.ahk runs.
;
; The returned text is a full .ps1 script (multi-line, comments allowed)
; written to a temp file by the caller — running it via ``-File`` avoids the
; argv-quoting issues that plagued the previous ``-Command`` inline variant.
_Onboarding_BuildGesturePsScript(ResultPath) {
	; The script is assembled line-by-line instead of via a multi-line
	; continuation section because the latter — combined with embedded
	; ``foreach (...)`` lines — triggers a fail-fast crash
	; (STATUS_STACK_BUFFER_OVERRUN, 0xC0000409) during AHK v2's continuation-
	; section parser. Concatenating with explicit ``\`r\`n`` separators keeps
	; the parser happy AND yields identical .ps1 content on disk.
	CRLF := "`r`n"
	ResultLiteral := StrReplace(ResultPath, "'", "''")
	S := ""
	S .= "$ErrorActionPreference = 'Stop'" . CRLF
	S .= "$ResultPath = '" . ResultLiteral . "'" . CRLF
	S .= "$ResultStage = $ResultPath + '.stage'" . CRLF
	S .= "$ErgoptiExitCode = 1" . CRLF
	S .= "$Reg = '" . TouchpadRegistryPowerShellKey() . "'" . CRLF
	; Create the PrecisionTouchPad key if missing (machines that never had a
	; precision touchpad driver loaded won't have it). Without this guard,
	; Set-ItemProperty -Force still fails with "Cannot find path" and the
	; whole script bails out before any value is written. -Force on New-Item
	; makes the call idempotent so it's safe when the key already exists.
	S .= "if (-not (Test-Path $Reg)) { New-Item -Path $Reg -Force | Out-Null }" . CRLF
	S .= "$V = [ordered]@{" . CRLF
	S .= TouchpadRegistryPowerShellValues()
	S .= "}" . CRLF
	S .= "try {" . CRLF
	S .= "  foreach ($n in $V.Keys) {" . CRLF
	; New-ItemProperty -Force creates the property OR updates it in place.
	; Set-ItemProperty raises "Property X does not exist" on a first-time
	; PrecisionTouchPad key (one we may have just created above), which
	; aborts the whole script under $ErrorActionPreference='Stop'.
	S .= "    New-ItemProperty -Path $Reg -Name $n -Value $V[$n] -PropertyType DWord -Force | Out-Null" . CRLF
	S .= "  }" . CRLF
	S .= "  $devs = Get-PnpDevice -PresentOnly | Where-Object {" . CRLF
	S .= "    $_.Class -eq 'HIDClass' -and $_.FriendlyName -match 'Input Configuration|I2C HID'" . CRLF
	S .= "  }" . CRLF
	S .= "  foreach ($d in $devs) {" . CRLF
	S .= "    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue" . CRLF
	S .= "  }" . CRLF
	S .= "  Start-Sleep -Milliseconds 500" . CRLF
	S .= "  foreach ($d in $devs) {" . CRLF
	S .= "    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue" . CRLF
	S .= "  }" . CRLF
	S .= "  $ErgoptiExitCode = 0" . CRLF
	S .= "} catch {" . CRLF
	S .= "}" . CRLF
	S .= "try {" . CRLF
	S .= "  [System.IO.File]::WriteAllText($ResultStage, [string]$ErgoptiExitCode, [System.Text.Encoding]::ASCII)" . CRLF
	S .= "  [System.IO.File]::Move($ResultStage, $ResultPath)" . CRLF
	S .= "} catch { Remove-Item -LiteralPath $ResultStage -Force -ErrorAction SilentlyContinue; exit 1 }" . CRLF
	S .= "exit $ErgoptiExitCode" . CRLF
	return S
}
