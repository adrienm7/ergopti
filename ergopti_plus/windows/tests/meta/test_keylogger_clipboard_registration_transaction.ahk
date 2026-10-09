; tests/meta/test_keylogger_clipboard_registration_transaction.ahk

; ============================================================================== 
; MODULE: Keylogger Clipboard Registration Transaction Regression Test
; DESCRIPTION:
; Clipboard observation and its paste-chord observer form one feature. A
; failure after a partial registration must roll back every producer and not
; publish the handler as live. The paste chords are observed on the shared
; InputHook, never claimed by a hotkey: the "~^v" hotkey this replaced was named
; by its virtual key on keys the driver declares by scan code, and AutoHotkey's
; hook never looked it up (hardening-c-scan-code-precedence).
; ============================================================================== 

#Requires AutoHotkey v2.0

_KLCRT_ClipboardRegistrationIsTransactional() {
	Body := _DriverFuncBody("KL_Clip_Start")
	Assert(Body != "", "KL_Clip_Start must exist")
	StopBody := _DriverFuncBody("KL_Clip_Stop")
	Assert(StopBody != "", "KL_Clip_Stop must exist")
	Subscribe := "HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, KL_Clip_OnKeyDown)"
	Unsubscribe := "HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, KL_Clip_OnKeyDown)"
	TryPos := InStr(Body, "try")
	RegisterPos := InStr(Body, "OnClipboardChange(Handler)")
	SubscribePos := InStr(Body, Subscribe)
	PublishPos := InStr(Body, "KLClip.clip_handler := Handler")
	CatchPos := InStr(Body, "catch as Err")
	Assert(TryPos > 0 && RegisterPos > TryPos && SubscribePos > RegisterPos,
		"KL_Clip_Start must register the clipboard and paste-chord observers inside one guarded transaction")
	Assert(PublishPos > SubscribePos && CatchPos > PublishPos,
		"KL_Clip_Start must publish clip_handler only after every producer registered")
	Assert(InStr(Body, Unsubscribe, true, CatchPos) > CatchPos,
		"rollback must unsubscribe the paste-chord observer after a partial registration")
	Assert(InStr(Body, "OnClipboardChange(Handler, 0)") > CatchPos && InStr(Body, "LoggerError") > CatchPos,
		"rollback must remove the clipboard observer and leave a diagnostic log")
	Assert(InStr(StopBody, Unsubscribe) > 0, "KL_Clip_Stop must unsubscribe the paste-chord observer")
	Assert(!RegExMatch(_StripFullLineComments(Body . "`n" . StopBody), "\bHotkey\("),
		"the paste chords must be observed, not claimed by a hotkey: a hotkey named by a character "
		. "never fires on a key the driver declares by scan code, and one declared by scan code competes "
		. "with the layout emulation's hotkeys of that key")
	ObserverOnPos := InStr(Body, "CB_SetOwnershipObserverActive(true)")
	Assert(ObserverOnPos > RegisterPos && ObserverOnPos < PublishPos,
		"KL_Clip_Start must publish adapter ownership observation before the handler becomes live state")
	Assert(InStr(Body, "CB_SetOwnershipObserverActive(false)", true, CatchPos) > CatchPos,
		"KL_Clip_Start rollback must stop retaining notification ownership")
	Assert(InStr(StopBody, "CB_SetOwnershipObserverActive(false)") > 0,
		"KL_Clip_Stop must stop retaining notification ownership")
}
Test("keylogger: clipboard and paste-chord observers register transactionally", _KLCRT_ClipboardRegistrationIsTransactional)

; The layout emulation types Ctrl+V itself (Ctrl on the QWERTY V position, and
; Ctrl on Ergopti's V through RemapKey). The paste observer sees that output
; only when it is sent by SendEvent at the hotkey's SendLevel 2: SendInput
; removes the script's own keyboard hook while it sends (keyboard_mouse.cpp
; SendEventArray), so no InputHook of this process sees the keys it types.
_KLCRT_EmulatedPasteReachesTheObserver() {
	Code := _DriverSourceNoComments()
	Assert(RegExMatch(Code, "m)^\^SC02F::[ \t]*(.*)$", &Paste) > 0,
		"the emulation's Ctrl paste on SC02F must stay declared")
	AssertEqual(1, InStr(Paste[1], '_RemapEmit("^v"'),
		"the emulation's Ctrl paste must emit through _RemapEmit, as RemapKey's Ctrl variant of V does")
	EmitBody := _DriverFuncBody("_RemapEmit")
	Assert(EmitBody != "", "_RemapEmit must exist")
	Assert(InStr(EmitBody, "SendEvent(") > 0 && !InStr(EmitBody, "SendInput("),
		"_RemapEmit must send by SendEvent, which the script's own InputHooks observe")
}
Test("keylogger: the layout emulation's own Ctrl+V reaches the paste observer",
	_KLCRT_EmulatedPasteReachesTheObserver)
