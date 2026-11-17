; tests/unit/platform/system/test_notifier_send.ahk

; ==============================================================================
; MODULE: NotifierSend Behaviour
; DESCRIPTION:
; Drives NotifierSend through its display seam, never the desktop: the title
; defaults to the product name, a notice is silent unless the caller asks for
; the sound, a refusing or raising display is logged and answered false, and a
; former direct caller (the user actions' notify port) now reaches the notifier.
;
; ROOT CAUSE ENCODED:
; Direct TrayTip calls titled "ErgoptiPlus" bypassed the notifier (notifications
; parity report, 2026-11-12). The contract is the one of the macOS and Linux
; adapters: product-name title, no sound, never fatal.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Recorder ===============================
; ===================================================
; ===================================================

; Records what the desktop would have shown and answers Reply.
_TNS_Recorder(Shown, Reply := 1) {
	return (Message, Title, Flag) => (Shown.Push(Map("message", Message, "title", Title, "flag", Flag)), Reply)
}




; ===================================================
; ===================================================
; ======= 2/ Title and sound ========================
; ===================================================
; ===================================================

_TNS_TitleIsTheProductName() {
	Shown := []
	AssertTrue(NotifierSend("Body.", 0, _TNS_Recorder(Shown)))
	AssertTrue(NotifierSend("Body.", Map("title", ""), _TNS_Recorder(Shown)))
	AssertTrue(NotifierSend("Body.", Map("title", "Keep awake"), _TNS_Recorder(Shown)))
	AssertEqual("Ergopti+", Shown[1]["title"], "a notice without a title carries the product name")
	AssertEqual("Ergopti+", Shown[2]["title"], "an empty title is the product name too")
	AssertEqual("Keep awake", Shown[3]["title"], "a caller's own title is kept")
}
Test("notifier: the default title is the product name Ergopti+", _TNS_TitleIsTheProductName)

_TNS_SilentUnlessAsked() {
	Shown := []
	NotifierSend("Info.", 0, _TNS_Recorder(Shown))
	NotifierSend("Warn.", Map("level", "warning"), _TNS_Recorder(Shown))
	NotifierSend("Error.", Map("level", "error"), _TNS_Recorder(Shown))
	NotifierSend("Offer.", Map("sound", true), _TNS_Recorder(Shown))
	NotifierSend("Error.", Map("level", "error", "sound", true), _TNS_Recorder(Shown))
	NotifierSend("Odd.", Map("sound", "yes"), _TNS_Recorder(Shown))
	AssertEqual(0x11, Shown[1]["flag"], "info is the info icon, muted")
	AssertEqual(0x12, Shown[2]["flag"], "warning is the warning icon, muted")
	AssertEqual(0x13, Shown[3]["flag"], "error is the error icon, muted")
	AssertEqual(0x1, Shown[4]["flag"], "sound true leaves the system sound on")
	AssertEqual(0x3, Shown[5]["flag"], "the sound option keeps the level's icon")
	AssertEqual(0x11, Shown[6]["flag"], "only a true Boolean turns the sound on")
}
Test("notifier: a notice is silent unless the caller asks for the sound", _TNS_SilentUnlessAsked)




; ===================================================
; ===================================================
; ======= 3/ Never fatal ============================
; ===================================================
; ===================================================

_TNS_FailuresAreLoggedNotThrown() {
	Logged := []
	LoggerSetTestSink((Line) => Logged.Push(Line))
	try {
		Raising(*) {
			throw Error("shell refused the balloon")
		}
		AssertFalse(NotifierSend("Body.", 0, Raising), "a raising display answers false")
		AssertFalse(NotifierSend("Body.", 0, _TNS_Recorder([], 0)), "a refusing display answers false")
	} finally LoggerClearTestSink()
	Text := ""
	for Line in Logged
		Text .= Line . "`n"
	AssertTrue(InStr(Text, "shell refused the balloon") > 0, "the raised error is logged")
	AssertTrue(InStr(Text, "refused the notice") > 0, "the refusal is logged")
	AssertEqual(0, InStr(Text, "Body."), "the notice text never reaches the log")
}
Test("notifier: a failing display is logged and answered false, never thrown", _TNS_FailuresAreLoggedNotThrown)




; ===================================================
; ===================================================
; ======= 4/ A former direct caller =================
; ===================================================
; ===================================================

; The user actions' notify port used to call TrayTip under "ErgoptiPlus".
_TNS_UserActionNoticeUsesTheNotifier() {
	global _NotifierDisplaySink
	Shown := []
	Saved := _NotifierDisplaySink
	NotifierSetDisplaySink(_TNS_Recorder(Shown))
	try _UserActionDefaultPorts()["notify"].Call("Could not open the folder.")
	finally NotifierSetDisplaySink(Saved)
	AssertEqual(1, Shown.Length, "the notify port reaches the notifier's display")
	AssertEqual("Ergopti+", Shown[1]["title"], "under the product name")
	AssertEqual(0x13, Shown[1]["flag"], "as a silent error")
}
Test("notifier: the user actions' failure notice goes through NotifierSend", _TNS_UserActionNoticeUsesTheNotifier)
