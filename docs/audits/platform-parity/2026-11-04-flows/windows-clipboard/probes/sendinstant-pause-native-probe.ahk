; Source-derived isolated native probe. NOT EXECUTED in Linux audit.
; Native SendInput and every clipboard boundary are recording functions only.
#Requires AutoHotkey v2.0
#SingleInstance Off
global _SendHook := 0, SEND_INSTANT_PASTE_DELAY_MS := 10000
global ProbeWrites := 0, ProbeSends := 0
CB_TryBeginPasteTransaction(*) => 1
CB_EndOwnedTransaction(*) => true
CB_IsBusy() => false
CB_HasImage() => false
CB_SaveAll() {
    Suspend(true)
    return "opaque original snapshot"
}
CB_WriteTextWithReceipt(Text, &OwnedSequence) {
    global ProbeWrites
    ProbeWrites += 1
    OwnedSequence := 42
    return true
}
ProbeSendInput(Keys) {
    global ProbeSends
    ProbeSends += 1
}
_SendInstantReport(*) => true
_SendInstant_RestoreClipboard(*) => true
LoggerDebug(*) => true
LoggerWarn(*) => true
LoggerError(*) => true
_SendVerdictSucceeded(Result) {
		; Legacy recorder hooks return an empty string after capturing a send. Only an
		; explicit Boolean false is a failure; type-checking first prevents the AHK v2
		; `"0" = false` coercion from rejecting a string token as a failed injection.
		return !((Result is Integer) and Result = 0)
}

SendInstant(Text, Prefix := "") {
	; Sends a large text through the clipboard while keeping Prefix (typically the
	; hotstring erase sequence) in the SAME SendInput burst as Ctrl+V. Splitting
	; these two injections lets a physical key land between erase and paste.
	; Uses try so the user's clipboard is restored even on error/crash.
	if _SendHook {
		try {
			Hook := _SendHook
			Sent := _SendVerdictSucceeded(Hook("SendInstant", Text, Prefix))
			if Sent
				_SendInstantReport(Text)
			return Sent
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant hook failed: {1}", Err.Message)
			return false
		}
	}
	; Reentrancy guard: a previous SendInstant's deferred restore has not run
	; yet, so the clipboard still holds its payload. Touching A_Clipboard now
	; would race the in-flight paste/restore — fall back to the clipboard-free
	; {Text} route so the two dances never interleave.
	; SendInput (not SendEvent) is used here to stay atomic and avoid interleaving
	; with the InputHook, which processes SendEvent characters as physical input.
	OwnerToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
	if !OwnerToken {
		try LoggerDebug("Hotstrings", "SendInstant: a restore is still in flight; routing through the clipboard-free path.")
		try {
			ProbeSendInput(Prefix . "{Text}" . Text)
			_SendInstantReport(Text)
			return true
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant clipboard-free injection failed: {1}", Err.Message)
			return false
		}
	}
	; The Notepad caller holds Critical across this whole call, so anything slow
	; here starves the keyboard hook rather than merely delaying one expansion.
	; CB_SaveAll snapshots EVERY format, and A_Clipboard retries for
	; #ClipboardTimeout — a full second by default — when another process holds
	; the clipboard open. A remote-desktop client, a clipboard manager or a
	; freshly captured full-screen bitmap can therefore freeze the thread for
	; ~1-2 s. Route those cases through the clipboard-free path instead: it
	; renders slightly worse in Notepad, which is precisely the trade the
	; reentrancy branch above already accepts.
	if (CB_IsBusy() or CB_HasImage()) {
		CB_EndOwnedTransaction(OwnerToken)
		try LoggerDebug("Hotstrings", "SendInstant: clipboard is contended or holds a bitmap; routing through the clipboard-free path.")
		try {
			ProbeSendInput(Prefix . "{Text}" . Text)
			_SendInstantReport(Text)
			return true
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant clipboard-free injection failed: {1}", Err.Message)
			return false
		}
	}
	OldClipboard := CB_SaveAll()
	if (Type(OldClipboard) == "String" && OldClipboard == "__CB_SAVE_ERROR__") {
		CB_EndOwnedTransaction(OwnerToken)
		try LoggerWarn("Hotstrings", "SendInstant: clipboard snapshot failed; expansion was not injected.")
		return false
	}
	RestoreCallback := false
	RestoreTimerArmed := false
	try {
		if !CB_WriteTextWithReceipt(Text, &OwnedSequence)
			throw Error("clipboard write failed")
		if !OwnedSequence
			throw Error("clipboard sequence unavailable")
		; Arm every fallible post-paste stage before the irreversible injection. If
		; timer registration fails, no erase/paste has reached the application and
		; the caller can safely leave its engine and preview state untouched.
		RestoreCallback := _SendInstant_RestoreClipboard.Bind(OldClipboard, OwnedSequence, OwnerToken)
		SetTimer(RestoreCallback, -SEND_INSTANT_PASTE_DELAY_MS)
		RestoreTimerArmed := true
		; Prefix and Ctrl+V are one kernel injection transaction. Critical callers
		; therefore cannot be interrupted after the erase but before the paste.
		ProbeSendInput(Prefix . "^v")
		_SendInstantReport(Text)
		return true
	} catch as err {
		; SendInput can fail after the restore timer was armed. Cancel that exact
		; callback before doing the cleanup inline so ownership is ended once.
		if RestoreTimerArmed
			try SetTimer(RestoreCallback, 0)
		if IsSet(OwnedSequence) && OwnedSequence {
			try CB_RestoreOwnedAllEventually(OldClipboard, OwnedSequence, OwnerToken,
				"hotstring_send_instant_rollback")
		} else {
			CB_EndOwnedTransaction(OwnerToken)
		}
		try LoggerError("Hotstrings", "SendInstant: clipboard injection failed: {1}", err.Message)
		return false
	}
}

Suspend(false)
Result := SendInstant("synthetic selection")
if !A_IsSuspended || !Result || ProbeWrites != 1 || ProbeSends != 1
    throw Error("Audited stale-output observation changed")
FileAppend("OBSERVED suspended=1 writes=1 sends=1 result=1; no native clipboard/input invoked`n", "*")
ExitApp()
