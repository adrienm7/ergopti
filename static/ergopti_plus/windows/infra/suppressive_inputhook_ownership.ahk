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
		catch as StartErr {
			RollbackError := 0
			try Hook.Stop()
			catch as StopErr
				RollbackError := StopErr
			if IsObject(RollbackError) {
				try LoggerError("InputHookOwnership",
					"Suppressive owner {1} failed to start and its rollback was refused; cleanup ownership was retained: {2}.",
					Owner, RollbackError.Message)
			} else {
				_SIHO_Owners.Delete(Token)
			}
			throw StartErr
		}
		return Token
	} finally Critical(PreviousCritical)
}

; Whether the exact token/hook pair is still admitted. A caller publishing
; logical state after Start must keep its query and publication in one Critical.
; @param Token {Integer} Immutable ownership token returned by SIHO_StartOwned.
; @param Hook {Object} The suppressive hook admitted with that token.
; @returns {Boolean} True only while that exact pair remains registered.
SIHO_IsOwned(Token, Hook) {
	global _SIHO_Owners
	PreviousCritical := Critical("On")
	try {
		return Token is Integer && Token > 0 && _SIHO_Owners.Has(Token)
			&& _SIHO_Owners[Token]["hook"] == Hook
	} finally Critical(PreviousCritical)
}

; Stops and unregisters one exact owner as a single terminal transaction. A
; refused native Stop leaves the record intact so lifecycle teardown can retry.
SIHO_StopOwned(Token, Hook) {
	global _SIHO_Owners
	PreviousCritical := Critical("On")
	try {
		if !(Token is Integer) or (Token <= 0) or !_SIHO_Owners.Has(Token)
			return false
		Record := _SIHO_Owners[Token]
		if (Record["hook"] != Hook)
			return false
		Owner := Record["owner"]
	} finally Critical(PreviousCritical)

	try Hook.Stop()
	catch as Err {
		try LoggerError("InputHookOwnership",
			"Could not stop suppressive owner {1}; cleanup ownership was retained: {2}.",
			Owner, Err.Message)
		return false
	}
	; A concurrent lifecycle Stop may already have removed this exact token.
	; Only the terminal path which still retires it may dispatch captured input.
	return SIHO_Unregister(Token, Hook)
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

; Stops a stable snapshot. Every owner is attempted before an error is rethrown;
; successful owners are retired exactly, while refused owners remain visible to
; later teardown.
SIHO_StopAll() {
	global _SIHO_Owners
	PreviousCritical := Critical("On")
	try {
		Snapshot := []
		for Token, Record in _SIHO_Owners
			Snapshot.Push({ token: Token, hook: Record["hook"] })
	} finally Critical(PreviousCritical)

	Stopped := 0
	FirstError := 0
	for Record in Snapshot {
		try {
			Record.hook.Stop()
			Stopped += 1
			SIHO_Unregister(Record.token, Record.hook)
		} catch as Err {
			if !IsObject(FirstError)
				FirstError := Err
		}
	}
	if IsObject(FirstError)
		throw FirstError
	return Stopped
}

; Number of currently armed suppressive hooks.
;
; Remap and digit-row hotkeys are registered when the script is loaded, so they
; fire while the auto-execute thread is still above this module's include
; position — and _EmitReachedScreen asks this question on every emitted
; character. ErgoptiPlus.ahk seeds _EMIT_SUPPRESSING_HOOKS in its pre-pump block
; for exactly that reason, but the SIHO registry it also reads is created here,
; roughly a thousand lines later. The bare read therefore raised UnsetError
; inside a hotkey thread, and before the driver publishes "ready" the global
; error net treats any uncaught error as fatal: typing one digit while the driver
; started killed it with a modal dialog (siho-count-before-include).
;
; Zero is not a fallback here, it is the fact: SIHO_Register is the only writer
; and it cannot have run before the registry it writes into exists.
; @returns {Integer} Live owner count, 0 before the registry is created.
SIHO_Count() {
	global _SIHO_Owners
	if !IsSet(_SIHO_Owners)
		return 0
	PreviousCritical := Critical("On")
	try return _SIHO_Owners.Count
	finally Critical(PreviousCritical)
}

SIHO_HasActive() {
	return SIHO_Count() > 0
}

; Native L1 limits UTF-16 units, so it can stop halfway through a scalar.
; EndChars stops synchronously before buffering: every ordinary unit and low
; surrogate ends capture, while a high is retained for its matching low.
; Boot warms this immutable table before configured capture hotkeys can fire.
_SIHO_ScalarEndKeys() {
	static Cached := 0
	if Cached is String
		return Cached
	Units := 0xFFFF - 0x400 + 4
	Bytes := Buffer((Units + 1) * 2, 0)
	Offset := 0
	loop 0xFFFF {
		Unit := A_Index
		if Unit >= 0xD800 && Unit <= 0xDBFF
			continue
		if Unit == 0x7B || Unit == 0x7D {
			NumPut("UShort", 0x7B, "UShort", Unit, "UShort", 0x7D, Bytes, Offset)
			Offset += 6
		} else {
			NumPut("UShort", Unit, Bytes, Offset)
			Offset += 2
		}
	}
	if Offset != Units * 2
		throw Error("The scalar capture table did not fill its exact buffer.")
	Candidate := StrGet(Bytes, Units, "UTF-16")
	if StrLen(Candidate) != Units
		throw Error("The scalar capture table lost a UTF-16 unit.")
	; Publish only the complete validated string, including on a cold reentry.
	; No registry globals are available at the earlier boot prewarm position.
	Cached := Candidate
	return Cached
}

; Named controls are explicit native EndKeys, never literal text. The only
; text completions admitted here are a BMP unit or a complete high/low pair.
; Invalid prefixes stay out of emitters and logs even when a control follows.
_SIHO_ReadScalar(Hook, NamedKeys) {
	Text := Hook.Input, EndKey := Hook.EndKey
	Result := { Kind: "invalid", Text: "", Name: "", Reason: "incomplete-scalar" }
	if Hook.EndReason == "Timeout" {
		Result.Kind := "timeout"
		Result.Reason := Text == "" ? "" : "incomplete-timeout"
		return Result
	}
	if Hook.EndReason != "EndKey" {
		Result.Reason := "unexpected-end-reason"
		return Result
	}
	if StrLen(EndKey) > 1 {
		for Name in StrSplit(NamedKeys, "{}") {
			if Name != "" && EndKey = Name {
				Result.Kind := "control", Result.Name := EndKey
				Result.Reason := Text == "" ? "" : "incomplete-control-prefix"
				return Result
			}
		}
		Result.Reason := "unknown-end-key"
		return Result
	}
	if StrLen(EndKey) != 1
		return Result
	Unit := NumGet(StrPtr(EndKey), 0, "UShort")
	if Text == "" && Unit > 0 && !(Unit >= 0xD800 && Unit <= 0xDFFF) {
		Result.Kind := "text", Result.Text := EndKey, Result.Reason := ""
		return Result
	}
	if StrLen(Text) == 1 && Unit >= 0xDC00 && Unit <= 0xDFFF {
		High := NumGet(StrPtr(Text), 0, "UShort")
		if High >= 0xD800 && High <= 0xDBFF
			Result.Kind := "text", Result.Text := Text . EndKey, Result.Reason := ""
	}
	return Result
}
