; tests/fixtures/startup_full_save_observer.ahk

; ==============================================================================
; MODULE: Startup Full-save Acknowledgment Observer
; DESCRIPTION:
; Proves that the existing boot generation committed before a disposable startup
; process exits. Settlement alone can represent abandoned optional work.
; ==============================================================================

; Drain an existing obligation once; never create a request or retry a refusal.
_StartupSmokeRequireFullSaveAcknowledged(DrainFn := unset) {
	global CONFIG_SAVE_OK
	if IsSet(DrainFn) && !HasMethod(DrainFn, "Call")
		throw TypeError("The startup full-save drain must be callable.")
	SaveState := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		RequestedBefore := SaveState.requested_generation
		CommittedBefore := SaveState.committed_generation
	} finally Critical(PreviousCritical)
	if RequestedBefore <= 0
		throw Error("The startup smoke has no accepted boot full-save generation.")
	Result := CONFIG_SAVE_OK
	if RequestedBefore > CommittedBefore
		Result := IsSet(DrainFn) ? DrainFn.Call() : _ConfigDrainFullSave()
	PreviousCritical := Critical("On")
	try {
		RequestedAfter := SaveState.requested_generation
		CommittedAfter := SaveState.committed_generation
	} finally Critical(PreviousCritical)
	if !(Result is Integer) || Result != CONFIG_SAVE_OK
		throw Error("The startup smoke full-save drain did not acknowledge its existing generation.")
	if CommittedAfter < RequestedAfter || _ConfigFullSaveHasPending()
		throw Error("The startup smoke boot full-save generation is not committed.")
	return true
}
