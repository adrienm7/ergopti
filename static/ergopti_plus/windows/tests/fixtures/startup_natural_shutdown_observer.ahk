; tests/fixtures/startup_natural_shutdown_observer.ahk

; ==============================================================================
; MODULE: Natural Startup Shutdown Observer
; DESCRIPTION:
; Observes real accepted production OnExit and subsequent natural interpreter
; termination. The existing startup-only ExitProcess probe cannot prove native
; menu destruction. A veto remains live; this owner never exhausts that budget.
; ==============================================================================

#Requires AutoHotkey v2.0

_StartupSmokeNaturalShutdown() {
	global _DriverReady, _DriverMenuReady, _DriverBootPhase
	if !_DriverReady || !_DriverMenuReady || _DriverBootPhase != "ready"
		throw Error("Natural shutdown requires complete actual driver readiness.")
	NaturalDirectory := EnvGet("ERGOPTI_STARTUP_SMOKE_DIR")
	NaturalNonce := EnvGet("ERGOPTI_STARTUP_SMOKE_NONCE")
	if !LoggerPrepareShutdown()
		throw Error("Natural startup diagnostics are not durable.")
	StartupSmokePublishReady(NaturalDirectory, NaturalNonce, true)
	; Registration after complete startup makes this the last actual OnExit owner.
	OnExit(_StartupSmokeNaturalAcceptedExit)
	SetTimer(_StartupSmokeNaturalRequestExit, 200)
	loop {
		if FileExist(NaturalDirectory . "\stop.request") {
			SetTimer(_StartupSmokeNaturalRequestExit, 0)
			if FSReadStrict(NaturalDirectory . "\stop.request") != NaturalNonce
				FileAppend("natural-shutdown-foreign-stop-request`n", "**", "UTF-8-RAW")
			else
				FileAppend("natural-shutdown-cooperative-budget-expired`n", "**", "UTF-8-RAW")
			; Keep the live driver's real debt and native callbacks. No forced exit,
			; new producer or repeated request may turn the expired budget green.
			loop
				Sleep(100)
		}
		Sleep(20)
	}
}

_StartupSmokeNaturalRequestExit(*) {
	if !LifecycleShutdownVetoHonored() {
		SetTimer(_StartupSmokeNaturalRequestExit, 0)
		FileAppend("natural-shutdown-retained-veto-debt`n", "**", "UTF-8-RAW")
		return
	}
	ExitApp(0)
}

_StartupSmokeNaturalAcceptedExit(NaturalReason, NaturalCode) {
	global _LifecycleShutdownReason, DriverPid
	try {
		; A refused earlier OnExit stops the callback chain. A forced-budget exit
		; must still not produce a healthy observer acknowledgment.
		if NaturalReason != "Exit" || NaturalCode != 0 || _LifecycleShutdownReason != NaturalReason
			throw Error("The actual production shutdown was not accepted normally.")
		if !LifecycleShutdownVetoHonored()
			throw Error("The production shutdown veto budget is exhausted.")
		if !LoggerPrepareShutdown()
			throw Error("Accepted production shutdown diagnostics remain non-durable.")
		NaturalNonce := EnvGet("ERGOPTI_STARTUP_SMOKE_NONCE")
		if !RegExMatch(NaturalNonce, "^[0-9a-f]{32}$")
			throw ValueError("Invalid natural shutdown nonce.")
		NaturalReceipt := '{"schema_version":1,"nonce":' . JsonStringLiteral(NaturalNonce)
			. ',"pid":' . DriverPid . ',"reason":"Exit","code":0'
			. ',"accepted":true,"logs_flushed":true,"veto_exhausted":false}' . "`n"
		if !FSWriteCreateDurable(EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") . "\natural-exit.json", NaturalReceipt)
			throw Error("The natural shutdown acknowledgment could not be created durably.")
	} catch as NaturalFailure {
		; Teardown is already terminal: report missing acknowledgment without a
		; late veto that would resurrect a driver whose producers were retired.
		try FileAppend("natural-shutdown-observer-refusal: " . NaturalFailure.Message . "`n", "**", "UTF-8-RAW")
	}
	return 0
}
