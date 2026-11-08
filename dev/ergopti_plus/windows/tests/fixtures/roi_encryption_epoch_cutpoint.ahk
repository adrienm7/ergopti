; tests/fixtures/roi_encryption_epoch_cutpoint.ahk

; ==============================================================================
; MODULE: ROI Encryption Epoch Cutpoint
; DESCRIPTION: Interrupts the real preference read once with an owned request
; that cleanly returns to OFF. Production producers and publication stay intact.
; ==============================================================================

_KRECP_Read(State, *) {
	State.Reads += 1
	if State.Armed && State.Reads == State.Target {
		State.Armed := false
		State.Calls += 1
		Owner := KL_Roi_BeginEncryptionRequest(true)
		if !IsObject(Owner)
			throw Error("The cutpoint must own the actual encryption request.")
		KL_Roi_EndEncryptionRequest(Owner)
		if IsObject(State.After)
			State.After.Call()
	}
	return false
}

_KRECP_Install(Target, After := 0) {
	State := {Target: Target, Reads: 0, Calls: 0, Armed: true, After: After,
		Descriptor: MetricsFilters.GetOwnPropDesc("encrypt")}
	MetricsFilters.DefineProp("encrypt", {Get: _KRECP_Read.Bind(State)})
	return State
}

_KRECP_Restore(State) {
	MetricsFilters.DefineProp("encrypt", State.Descriptor)
}
