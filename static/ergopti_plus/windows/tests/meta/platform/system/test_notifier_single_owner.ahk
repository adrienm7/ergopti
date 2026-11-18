; tests/meta/platform/system/test_notifier_single_owner.ahk

; ==============================================================================
; MODULE: Notifier Single Owner Guard
; DESCRIPTION:
; Pins that every user notification of the Windows driver goes through
; NotifierSend (platform/system/notifier.ahk), as every macOS and Linux notice
; goes through their notifier adapter.
;
; ROOT CAUSE ENCODED:
; The notifications parity report (2026-11-12) found direct TrayTip calls
; titled "ErgoptiPlus" (the program file name, never a label per
; docs/design/studio-glossary.md), some outside a try, so a refused balloon
; interrupted the action that raised it, and none of them reached the
; notifier's failure log, its silent-by-default sound option or the suite's
; display sink. Scanning code only (strings and comments masked) keeps prose
; that names TrayTip from counting, and naming each offending file keeps the
; failure actionable after the structure moves.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================================
; =================================================================
; ======= 1/ TrayTip is called by the notifier only ===============
; =================================================================
; =================================================================

_TNSO_NoDirectTrayTip() {
	Pattern := "(?<![\w.])TrayTip\s*\("
	Offenders := ""
	OwnerCalls := 0
	Scanned := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Src := FileRead(Path, "UTF-8")
		Code := _DriverMaskNonCode(&Src)
		Scanned += 1
		Count := 0, Position := 1
		while Position := RegExMatch(Code, Pattern, &Found, Position) {
			Count += 1
			Position += Found.Len
		}
		if !Count
			continue
		SplitPath(Path, &Name)
		if Name == "notifier.ahk" && InStr(Src, "NotifierSend(Message, Opts")
			OwnerCalls += Count
		else
			Offenders .= "`n  " . Path . " (" . Count . ")"
	}
	Assert(Scanned > 100, "the production source census must list the driver files")
	AssertEqual(1, OwnerCalls, "NotifierSend must hold the driver's one TrayTip call")
	AssertEqual("", Offenders, "user notifications must go through NotifierSend, not a direct TrayTip:" . Offenders)
}
Test("notifier: no direct TrayTip outside NotifierSend (notifications parity)", _TNSO_NoDirectTrayTip)

; A caller that passed the program file name as a title would undo the default.
_TNSO_NoFileNameTitle() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	Assert(!RegExMatch(Src, 'NotifierSend\([^\n]*"ErgoptiPlus"'),
		"a notification title must be the product name, never the program file name ErgoptiPlus")
	Body := _DriverFuncBody("NotifierSend")
	Assert(InStr(Body, "Identifiers.App.DISPLAY_NAME") > 0, "NotifierSend must default its title to the product name")
}
Test("notifier: no notification is titled with the program file name", _TNSO_NoFileNameTitle)
