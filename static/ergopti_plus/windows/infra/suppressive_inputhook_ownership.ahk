; infra/suppressive_inputhook_ownership.ahk

; ==============================================================================
; MODULE: Suppressive InputHook Ownership
; DESCRIPTION:
; Owns every concurrently armed suppressive InputHook by an immutable token.
; Native Suspend does not remove InputHooks, so lifecycle teardown must retain
; all live instances until their individual terminal paths unregister them.
; ==============================================================================

#Requires AutoHotkey v2.0

global _SIHO_Owners := Map()
global _SIHO_NextToken := 0

; Publishes ownership and arms the hook in one non-interruptible transaction.
; An exclusive suppressive state machine cannot compose with any other live
; hook: the newest native InputHook would consume the next event before the
; older wait sees it, leaving that older capture armed for a later keystroke.
SIHO_StartOwned(Hook, Owner, Exclusive := false) {
	global _SIHO_Owners, _SIHO_NextToken
	if !IsObject(Hook) or !HasMethod(Hook, "Start") or !HasMethod(Hook, "Stop")
		throw TypeError("A suppressive InputHook owner needs Start and Stop methods.")
	if !(Owner is String) or (Trim(Owner) == "")
		throw ValueError("A suppressive InputHook owner name is required.")

	PreviousCritical := Critical("On")
	try {
		; The native suspended bit is set before Ergopti_OnSuspendEnter runs. Testing
		; it inside the same Critical section as publication closes the entry race:
		; teardown either sees this record or this call refuses to arm the hook.
		if A_IsSuspended
			return 0
		for _, Record in _SIHO_Owners
			if Exclusive || Record["exclusive"]
				return 0
		_SIHO_NextToken += 1
		Token := _SIHO_NextToken
		_SIHO_Owners[Token] := Map(
			"hook", Hook,
			"owner", Owner,
			"exclusive", Exclusive ? true : false)
		try Hook.Start()
		catch as Err {
			_SIHO_Owners.Delete(Token)
			throw Err
		}
		return Token
	} finally Critical(PreviousCritical)
}

; Removes only the exact token/object pair. A stale finally therefore cannot
; clear a successor that began while an older Wait was unwinding.
SIHO_Unregister(Token, Hook) {
	global _SIHO_Owners
	PreviousCritical := Critical("On")
	try {
		if !(Token is Integer) or (Token <= 0) or !_SIHO_Owners.Has(Token)
			return false
		Record := _SIHO_Owners[Token]
		if (Record["hook"] != Hook)
			return false
		_SIHO_Owners.Delete(Token)
		return true
	} finally Critical(PreviousCritical)
}

; Stops a stable snapshot so callbacks may unregister themselves while Stop
; resumes their interrupted Wait. Every owner is attempted before an error is
; rethrown; a failed owner remains registered and visible to later teardown.
SIHO_StopAll() {
	global _SIHO_Owners
	PreviousCritical := Critical("On")
	try {
		Snapshot := []
		for _, Record in _SIHO_Owners
			Snapshot.Push(Record)
	} finally Critical(PreviousCritical)

	Stopped := 0
	FirstError := 0
	for Record in Snapshot {
		try {
			Record["hook"].Stop()
			Stopped += 1
		} catch as Err {
			if !IsObject(FirstError)
				FirstError := Err
		}
	}
	if IsObject(FirstError)
		throw FirstError
	return Stopped
}

SIHO_Count() {
	global _SIHO_Owners
	PreviousCritical := Critical("On")
	try return _SIHO_Owners.Count
	finally Critical(PreviousCritical)
}

SIHO_HasActive() {
	return SIHO_Count() > 0
}
