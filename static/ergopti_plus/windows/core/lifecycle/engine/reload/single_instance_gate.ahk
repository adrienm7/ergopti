; core/lifecycle/engine/reload/single_instance_gate.ahk

; ==============================================================================
; MODULE: Single-Instance Gate Decision
; DESCRIPTION:
; Pure classification for the entry point's named-mutex acquisition. Native
; calls remain in ErgoptiPlus.ahk because the gate runs before normal adapter
; bootstrap; this module makes every native result deterministic and testable.
; ==============================================================================

global DRIVER_MUTEX_ACQUIRED := "acquired"
global DRIVER_MUTEX_YIELD := "yield"
global DRIVER_MUTEX_FATAL := "fatal"
global DRIVER_MUTEX_EXEMPT := "exempt"

DriverMutex_Decide(Handle, WaitResult := unset) {
	if !Handle or !IsSet(WaitResult)
		return DRIVER_MUTEX_FATAL
	switch WaitResult {
		case 0, 0x80:  ; WAIT_OBJECT_0, WAIT_ABANDONED
			return DRIVER_MUTEX_ACQUIRED
		case 0x102:  ; WAIT_TIMEOUT
			return DRIVER_MUTEX_YIELD
		default:
			return DRIVER_MUTEX_FATAL
	}
}

DriverMutex_WaitFailed(WaitResult) {
	return WaitResult = 0xFFFFFFFF  ; WAIT_FAILED
}

; A startup smoke skips the mutex above so it can run beside a resident driver,
; and it boots the whole driver: with the maintainer's copied configuration its
; hooks act on his keyboard too, each key and each expansion then lands twice
; (« ppoouurr », `jjoou` for `a,ou`). So a smoke owns session input only on CI or
; on an explicit request, never beside a resident driver.
global DRIVER_SMOKE_INPUT_LIVE := "live"
global DRIVER_SMOKE_INPUT_QUARANTINE := "quarantine"
global DRIVER_SMOKE_INPUT_REFUSE := "refuse"
; Longer than every harness's own timeout (120 s), so a harness keeps the verdict
; and only an orphaned or wedged smoke reaches it.
global STARTUP_SMOKE_DEADLINE_MS := 150000

; Decides what a startup smoke does with the session's input.
; @param LiveInputRequested {Boolean} The caller needs real keys to reach it.
; @param RunsOnCi {Boolean} A disposable session with nobody typing.
; @param ResidentLives {Boolean} Another driver owns the single-owner mutex.
; @return {String} One of the DRIVER_SMOKE_INPUT_* decisions.
DriverSmokeInput_Decide(LiveInputRequested, RunsOnCi, ResidentLives) {
	if ResidentLives
		return LiveInputRequested ? DRIVER_SMOKE_INPUT_REFUSE : DRIVER_SMOKE_INPUT_QUARANTINE
	return (LiveInputRequested || RunsOnCi) ? DRIVER_SMOKE_INPUT_LIVE : DRIVER_SMOKE_INPUT_QUARANTINE
}

; Whether a driver holds the named mutex, without taking it. Only "no such
; mutex" proves absence: any other refusal counts as a resident.
; @param Name {String} Mutex name.
; @return {Boolean}
DriverMutex_ResidentLives(Name) {
	return PLC_NamedMutexHeld(Name)
}

; Timer ending a smoke that outlived every harness. ExitProcess, as the smoke's
; own ready path: a wedged owner could veto ExitApp and stay resident.
StartupSmokeDeadlineExit() {
	PLC_ExitProcessNow(124, "startup-smoke: deadline reached; the process ends.")
}

; Arms that deadline. Cancelled by its function identity (tests/live/live_harness.ahk).
StartupSmokeArmDeadline() {
	global STARTUP_SMOKE_DEADLINE_MS
	PLC_ArmProcessDeadline(StartupSmokeDeadlineExit, STARTUP_SMOKE_DEADLINE_MS)
}
