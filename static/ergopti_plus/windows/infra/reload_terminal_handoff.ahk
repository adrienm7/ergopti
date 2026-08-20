; infra/reload_terminal_handoff.ahk

; ==============================================================================
; MODULE: Reload Terminal Hand-off
; DESCRIPTION:
; Bridges an authorized global configuration-transition bundle into AutoHotkey's
; nested OnExit callback. A Reload invokes OnExit before its caller can release
; the bundle, so shutdown must claim those exact owners instead of deadlocking
; on a second acquisition. Terminal callbacks run only after the last refusal
; gate accepts; if Reload returns, the hand-off was refused and is canceled.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Terminal ownership =======
; =====================================
; =====================================

global _ReloadTerminalHandoff := false
global _ReloadTerminalHandoffNextId := 0

ReloadTerminalHandoffPrepare(Bundle, SuccessFn := 0, CommitFn := 0,
		AbortFn := 0) {
	global _ReloadTerminalHandoff, _ReloadTerminalHandoffNextId
	if !(Bundle is Object)
		return false
	if !((SuccessFn is Integer) && SuccessFn == 0)
			&& !HasMethod(SuccessFn, "Call")
		return false
	for Callback in [CommitFn, AbortFn] {
		if !((Callback is Integer) && Callback == 0)
				&& !HasMethod(Callback, "Call")
			return false
	}
	if !_ConfigWriteTerminalAuthorize(Bundle)
		return false
	PreviousCritical := Critical("On")
	try {
		if (_ReloadTerminalHandoff is Map)
			return false
		_ReloadTerminalHandoffNextId += 1
		Record := Map(
			"id", _ReloadTerminalHandoffNextId,
			"bundle", Bundle,
			"success", SuccessFn,
			"commit", CommitFn,
			"abort", AbortFn,
			"state", "authorized")
		_ReloadTerminalHandoff := Record
		return Record
	} finally Critical(PreviousCritical)
}

ReloadTerminalHandoffClaim(ExitReason) {
	global _ReloadTerminalHandoff
	if !(ExitReason is String)
			|| StrCompare(ExitReason, "Reload", true) != 0
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
			return false
		Record := _ReloadTerminalHandoff
		if (Record["state"] != "authorized")
			return false
		if !_ConfigWriteTerminalClaimShutdown(Record["bundle"])
			return false
		Record["state"] := "claimed"
		return Record
	} finally Critical(PreviousCritical)
}

; Executes the only refusal-capable terminal callback. Keeping this separate
; from Finish lets OnExit publish durable transition authority before it tears
; down the last live OS hooks, while still deferring UI success until teardown
; has completed.
ReloadTerminalHandoffCommit(Record) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffCommitNonCritical(Record)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffCommitNonCritical(Record) {
	global _ReloadTerminalHandoff
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "claimed"
			return false
		Record["state"] := "committing"
	} finally Critical(PreviousCritical)
	CommitOk := true
	try {
		CommitFn := Record["commit"]
		if HasMethod(CommitFn, "Call") {
			CommitResult := CommitFn.Call()
			CommitOk := (CommitResult is Integer) && CommitResult == 1
		}
	} catch as Err {
		CommitOk := false
		try LoggerError("Lifecycle",
			"Reload terminal commit failed: {1}.", Err.Message)
	}
	if !CommitOk {
		PreviousCritical := Critical("On")
		try {
			if (_ReloadTerminalHandoff is Map)
					&& (_ReloadTerminalHandoff == Record)
				Record["state"] := "commit_failed"
		} finally Critical(PreviousCritical)
		return false
	}
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "committing"
			return false
		Record["state"] := "committed"
	} finally Critical(PreviousCritical)
	return true
}

ReloadTerminalHandoffFinish(Record, BeforeSuccessFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffFinishNonCritical(Record, BeforeSuccessFn)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffFinishNonCritical(Record, BeforeSuccessFn) {
	global _ReloadTerminalHandoff
	if !((BeforeSuccessFn is Integer) && BeforeSuccessFn == 0)
			&& !HasMethod(BeforeSuccessFn, "Call")
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
			return false
		State := Record["state"]
	} finally Critical(PreviousCritical)
	; Tests and non-OnExit clients may use Finish as the complete terminal seam.
	; The live OnExit path commits explicitly before destructive teardown.
	if (State == "claimed") {
		if !ReloadTerminalHandoffCommit(Record)
			return false
	} else if (State != "committed")
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "committed"
			return false
		; All validation that may refuse happens before the teardown callback.
		; Clearing the global makes the accepted record terminal and single-use.
		Record["state"] := "finishing"
		_ReloadTerminalHandoff := false
	} finally Critical(PreviousCritical)
	try {
		if HasMethod(BeforeSuccessFn, "Call")
			BeforeSuccessFn.Call()
	} catch as Err {
		try LoggerError("Lifecycle",
			"Reload terminal teardown callback failed after acceptance: {1}.",
			Err.Message)
	}
	Record["state"] := "finished"
	try {
		SuccessFn := Record["success"]
		if HasMethod(SuccessFn, "Call")
			SuccessFn.Call()
	} catch as Err {
		try LoggerError("Lifecycle",
			"Reload terminal callback failed after every refusal gate accepted: {1}.",
			Err.Message)
	}
	return true
}

ReloadTerminalHandoffCancel(Record) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffCancelNonCritical(Record)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffCancelNonCritical(Record) {
	global _ReloadTerminalHandoff
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
			return false
		Record["state"] := "canceling"
	} finally Critical(PreviousCritical)
	AbortOk := true
	try {
		AbortFn := Record["abort"]
		if HasMethod(AbortFn, "Call") {
			AbortResult := AbortFn.Call()
			AbortOk := (AbortResult is Integer) && AbortResult == 1
		}
	} catch as Err {
		AbortOk := false
		try LoggerError("Lifecycle",
			"Reload terminal abort failed: {1}.", Err.Message)
	}
	; Keep the record globally exclusive until its abort callback is finished.
	; Rearming first would let a second Prepare/Claim interleave with cleanup of
	; the previous pause marker. Both handoff and lease state become reusable in
	; this one non-yielding section.
	ResetFailed := false
	CancelResult := false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "canceling"
			return false
		if !_ConfigWriteTerminalCancelShutdown(Record["bundle"]) {
			Record["state"] := "cancel_failed"
			ResetFailed := true
		} else {
			Record["state"] := AbortOk ? "canceled" : "cancel_failed"
			_ReloadTerminalHandoff := false
			CancelResult := AbortOk
		}
	} finally Critical(PreviousCritical)
	if ResetFailed
		try LoggerError("Lifecycle",
			"Reload terminal claim could not be rearmed after refusal.")
	return CancelResult
}

; The real Reload never returns after an accepted OnExit. Returning means either
; authorization was refused or an OnExit gate kept this process alive. Tests can
; simulate the successful terminal path by Claim+Finish inside ReloadFn.
ReloadTerminalInvoke(Bundle, SuccessFn, ReloadFn, CommitFn := 0, AbortFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalInvokeNonCritical(Bundle, SuccessFn, ReloadFn,
		CommitFn, AbortFn)
	finally Critical(PreviousCritical)
}

_ReloadTerminalInvokeNonCritical(Bundle, SuccessFn, ReloadFn, CommitFn, AbortFn) {
	if !HasMethod(ReloadFn, "Call")
		throw TypeError("Reload terminal hand-off requires a reload callback.")
	Record := ReloadTerminalHandoffPrepare(Bundle, SuccessFn, CommitFn, AbortFn)
	if !(Record is Map)
		return false
	try ReloadFn.Call()
	catch as Err {
		ReloadTerminalHandoffCancel(Record)
		try LoggerError("Lifecycle", "Reload invocation failed: {1}.", Err.Message)
		return false
	}
	Accepted := Record["state"] = "finished"
	if !Accepted
		ReloadTerminalHandoffCancel(Record)
	return Accepted
}
