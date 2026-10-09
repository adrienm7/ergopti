; infra/single_instance_gate.ahk

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
