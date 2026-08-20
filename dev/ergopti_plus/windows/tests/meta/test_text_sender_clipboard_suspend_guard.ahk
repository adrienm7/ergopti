; tests/meta/test_text_sender_clipboard_suspend_guard.ahk

; ==============================================================================
; MODULE: TextSender Clipboard Suspend Guard Meta Test (Pattern 1, 1d)
; DESCRIPTION:
; Regression guard for the "native Suspend() never disarms a SetTimer
; callback" gap-class as it applies to TextSend's clipboard-mode round-trip.
; _TextSendClipboard runs entirely on a one-shot SetTimer (deliberately, to
; keep the blocking ClipWait off the keyboard-hook thread), which means a
; Suspend toggled between TextSend's scheduling and the timer firing does
; NOT stop the write/paste from happening — the timer is not a Hotkey or
; Hotstring, so native Suspend() has no effect on it.
;
; SCOPE: source introspection of adapters/text_sender.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ _TextSendClipboard guard =============
; =================================================
; =================================================

_TSCSG_ClipboardHasSuspendGuardBeforeWrite() {
	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard must exist in adapters/text_sender.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	Assert(GuardPos > 0,
		"_TextSendClipboard must check A_IsSuspended — it runs entirely on a SetTimer callback, which native Suspend() never disarms")

	WritePos := InStr(Body, "CB_Write(")
	Assert(WritePos > 0, "_TextSendClipboard must still call CB_Write")
	Assert(GuardPos < WritePos,
		"_TextSendClipboard: the A_IsSuspended guard must appear BEFORE CB_Write — a guard placed after the write still overwrites the clipboard while paused")

	ClipWaitPos := InStr(Body, "ClipWait(", true, WritePos)
	SecondGuardPos := InStr(Body, "A_IsSuspended", true, ClipWaitPos)
	AtomicPastePos := InStr(Body, '_AHK_SendInput.Bind("^v")', true, SecondGuardPos)
	FallbackPastePos := InStr(Body,
		'_TextSenderSendInput("^v", "clipboard paste")', true, SecondGuardPos)
	Assert(ClipWaitPos > WritePos and SecondGuardPos > ClipWaitPos,
		"_TextSendClipboard must recheck suspension AFTER ClipWait yields; the entry guard alone lets a pause requested during the wait paste anyway")
	Assert(AtomicPastePos > SecondGuardPos and FallbackPastePos > SecondGuardPos,
		"the post-ClipWait suspend guard must precede both atomic and ordinary Ctrl+V paths")
}
Test("text_sender: _TextSendClipboard guards entry and post-ClipWait paste (suspend-guard-pattern-1)",
	_TSCSG_ClipboardHasSuspendGuardBeforeWrite)
