; tests/meta/test_keylogger_clipboard_registration_transaction.ahk

; ============================================================================== 
; MODULE: Keylogger Clipboard Registration Transaction Regression Test
; DESCRIPTION:
; Clipboard observation and its two pass-through paste hotkeys form one feature.
; A failure after a partial registration must roll back every producer and not
; publish the handler as live.
; ============================================================================== 

#Requires AutoHotkey v2.0

_KLCRT_ClipboardRegistrationIsTransactional() {
    Body := _DriverFuncBody("KL_Clip_Start")
    Assert(Body != "", "KL_Clip_Start must exist")
    TryPos := InStr(Body, "try")
    RegisterPos := InStr(Body, "OnClipboardChange(Handler)")
    FirstHotkeyPos := InStr(Body, 'Hotkey("~^v"')
    SecondHotkeyPos := InStr(Body, 'Hotkey("~+Insert"')
    PublishPos := InStr(Body, "KLClip.clip_handler := Handler")
    CatchPos := InStr(Body, "catch as Err")
    Assert(TryPos > 0 && RegisterPos > TryPos && FirstHotkeyPos > RegisterPos && SecondHotkeyPos > FirstHotkeyPos,
        "KL_Clip_Start must register observer and both paste hotkeys inside one guarded transaction")
    Assert(PublishPos > SecondHotkeyPos && CatchPos > PublishPos,
        "KL_Clip_Start must publish clip_handler only after every producer registered")
    Assert(InStr(Body, 'Hotkey("~^v",      KL_Clip_OnPasteHK, "Off")') > CatchPos,
        "rollback must disable Ctrl+V observation after a partial registration")
    Assert(InStr(Body, 'Hotkey("~+Insert", KL_Clip_OnPasteHK, "Off")') > CatchPos,
        "rollback must disable Shift+Insert observation after a partial registration")
    Assert(InStr(Body, "OnClipboardChange(Handler, 0)") > CatchPos && InStr(Body, "LoggerError") > CatchPos,
        "rollback must remove the clipboard observer and leave a diagnostic log")
	ObserverOnPos := InStr(Body, "CB_SetOwnershipObserverActive(true)")
	Assert(ObserverOnPos > RegisterPos && ObserverOnPos < PublishPos,
		"KL_Clip_Start must publish adapter ownership observation before the handler becomes live state")
	Assert(InStr(Body, "CB_SetOwnershipObserverActive(false)", true, CatchPos) > CatchPos,
		"KL_Clip_Start rollback must stop retaining notification ownership")
	StopBody := _DriverFuncBody("KL_Clip_Stop")
	Assert(InStr(StopBody, "CB_SetOwnershipObserverActive(false)") > 0,
		"KL_Clip_Stop must stop retaining notification ownership")
}
Test("keylogger: clipboard observer/hotkeys register transactionally", _KLCRT_ClipboardRegistrationIsTransactional)
