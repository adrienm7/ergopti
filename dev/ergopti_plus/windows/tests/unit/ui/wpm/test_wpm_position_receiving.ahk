; tests/unit/ui/wpm/test_wpm_position_receiving.ahk

; ==============================================================================
; MODULE: Widget Position Receiving Scenario
; DESCRIPTION:
; The native receiving scenario of WCF-001 (docs/audits/platform-parity/
; 2026-11-04-flows/windows-config): the widget position goes to the real
; Registry, under a private key of this run instead of the user's
; HKCU\Software\Ergopti\Storage, and the next boot's loader reads it back.
; A write the Registry refuses (a key name longer than its 255-character
; limit) leaves the previous pair and the live position untouched and is
; reported once, so no half pair can ever be stored.
; Registered as interactive: only the receiving runner selects it.
; ==============================================================================

#Requires AutoHotkey v2.0

; The private parent key of the receiving runs.
global PWRW_REGISTRY_PARENT := "HKCU\Software\ErgoptiReceiving"

_PWRW_PositionGoesToTheRegistry() {
	global STORAGE_REG_BASE, PWRW_REGISTRY_PARENT
	ReceivingProfileRoot()
	AssertTrue(WPMWidget_LoadSharedConst(), "the widget constants load")
	Key := PWRW_REGISTRY_PARENT . "\" . DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
	SavedBase := STORAGE_REG_BASE, SavedX := WPMWidget.pos_x, SavedY := WPMWidget.pos_y
	STORAGE_REG_BASE := Key . "\Storage"
	try {
		MonitorGetWorkArea(MonitorGetPrimary(), &Left, &Top)
		X := Left + 40, Y := Top + 60
		WPMWidget.pos_x := Left + 10, WPMWidget.pos_y := Top + 20
		Notices := []
		Notify := (Args*) => Notices.Push(Args)
		AssertTrue(WPMWidget_SavePosition(X, Y, 0, Notify), "the Registry accepts the pair")
		Stored := _ST_DecodeValue(RegRead(STORAGE_REG_BASE, WPMWidgetConst.STORE_PAIR))
		AssertTrue(Stored is Array && Stored.Length == 2 && Stored[1] == X && Stored[2] == Y,
			"one Registry value holds both coordinates")

		WPMWidget.pos_x := Left + 1, WPMWidget.pos_y := Top + 1
		WPMWidget_LoadConfig(Map())
		AssertEqual(X, WPMWidget.pos_x, "the next boot reads X back from the Registry")
		AssertEqual(Y, WPMWidget.pos_y, "the next boot reads Y back from the Registry")

		STORAGE_REG_BASE := Key . "\" . StrReplace(Format("{:300}", ""), " ", "x") . "\Storage"
		AssertFalse(WPMWidget_SavePosition(X + 5, Y + 5, 0, Notify), "the Registry refuses an over-long key")
		AssertEqual(X, WPMWidget.pos_x, "the live X is unchanged")
		AssertEqual(Y, WPMWidget.pos_y, "the live Y is unchanged")
		AssertEqual(1, Notices.Length, "the refusal is reported once")
		STORAGE_REG_BASE := Key . "\Storage"
		Stored := _ST_DecodeValue(RegRead(STORAGE_REG_BASE, WPMWidgetConst.STORE_PAIR))
		AssertTrue(Stored[1] == X && Stored[2] == Y, "the stored pair is the previous one, whole")
	} finally {
		STORAGE_REG_BASE := SavedBase
		WPMWidget.pos_x := SavedX, WPMWidget.pos_y := SavedY
		RegDeleteKey(Key)
		Others := false
		loop reg, PWRW_REGISTRY_PARENT, "KV"
			Others := true
		if !Others
			RegDeleteKey(PWRW_REGISTRY_PARENT)
	}
}
Test("widget position receiving: the pair reaches the real Registry, and a refused write keeps the previous one (phys-w-receiving-widget-position)",
	_PWRW_PositionGoesToTheRegistry, true)
