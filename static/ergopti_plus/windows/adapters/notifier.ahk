; adapters/notifier.ahk

; ==============================================================================
; MODULE: Notifier Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Notifier port contract defined in
; static/ergopti_plus/_shared/core/ports/Notifier.spec.js. Wraps Windows TrayTip
; behind the canonical NotifierSend function so domain modules can surface
; system notifications without calling TrayTip directly.
;
; NAMING CONVENTION:
; Port method → AHK name:  send(title, opts) → NotifierSend(Title, Opts)
;
; WINDOWS TRAYTIP NOTES:
; TrayTip v2 uses integer flags for the icon type:
;   1 = Info (blue "i"), 2 = Warning (yellow "!"), 3 = Error (red "X").
; The optional "kind" field in opts maps to these constants.
; ==============================================================================




; =======================================================
; =======================================================
; ======= 1/ Kind → TrayTip Icon Flag Mapping ===========
; =======================================================
; =======================================================

; Replaces the desktop for the test suite: a toggle exercised by a unit test must
; not show a real notification on the developer's machine.
global _NotifierDisplaySink := 0

; Maps the contract "kind" string to the Windows TrayTip icon constant.
; A missing or unknown kind defaults to Info (1).
_NotifierKindToFlag(Kind) {
	switch Kind {
		case "warning": return 2
		case "error":   return 3
		default:        return 1
	}
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Method =============================
; =======================================================
; =======================================================

; Sends a system notification via Windows TrayTip.
; @param Message {String} The notification body text.
; @param Opts    {Map|0}  Options Map: { title?, level? }
;                           title {String} Notification title (bold text).
;                           level {String} "info" | "success" | "warning" | "error".
NotifierSend(Message, Opts, DisplayFn := 0) {
	Title := "Ergopti+"
	Level := "info"
	if (Opts is Map) {
		if Opts.Has("title") and Opts["title"] != ""
			Title := Opts["title"]
		if Opts.Has("level") and Opts["level"] != ""
			Level := Opts["level"]
	}
	Flag := _NotifierKindToFlag(Level)
	global _NotifierDisplaySink

	if !IsObject(DisplayFn) && IsObject(_NotifierDisplaySink)
		DisplayFn := _NotifierDisplaySink
	try {
		; An injected display seam remains active in CI so the adapter's typed
		; acknowledgement contract can be exercised without touching the desktop.
		if IsObject(DisplayFn) {
			Result := DisplayFn.Call(Message, Title, Flag)
			return Type(Result) == "Integer" and Result != 0
		}
		; Skip actual OS display in CI to avoid environment-specific hangs or failures.
		if (EnvGet("GITHUB_ACTIONS") = "true")
			return true
		TrayTip(Message, Title, Flag)
		return true
	} catch as Err {
		try LoggerError("Notifier", "Tray notification failed: {1}.", Err.Message)
		return false
	}
}

; Replaces the desktop for the test suite.
; @param DisplayFn {Func} Called as (Message, Title, Flag).
NotifierSetDisplaySink(DisplayFn) {
	global _NotifierDisplaySink
	_NotifierDisplaySink := DisplayFn
}

; Sends one notice; a raised error or a refusal is logged and forgotten. A switch
; that was committed must not look failed because the desktop refused a balloon.
_NotifierDeliver(Text, Level, What, SendFn) {
	try {
		Shown := IsObject(SendFn) ? SendFn.Call(Text, Map("level", Level)) : NotifierSend(Text, Map("level", Level))
	} catch as Err {
		try LoggerWarn("Notifier", "{1} notification failed: {2}.", What, Err.Message)
		return
	}
	if !Shown
		try LoggerWarn("Notifier", "{1} notification was not shown.", What)
}

; Announces that a menu feature was switched, with the contract of
; _shared/lua/feature_notice.lua: one log line first, enabled is "success" and
; disabled "error", and a failing notifier is never fatal.
; @param Label {String} Display name of the feature.
; @param Enabled {Boolean} The new state; anything but a true value is disabled.
; @param SendFn {Func|Integer} Replaces NotifierSend (tests only).
NotifyFeature(Label, Enabled, SendFn := 0) {
	On := (Enabled is Integer) && Enabled != 0
	try LoggerInfo("Menu", "Feature toggled from the menu: '{1}' " . Chr(0x2192) . " {2}.", Label, On ? "enabled" : "disabled")
	_NotifierDeliver(Label, On ? "success" : "error", "Feature toggle", SendFn)
}

; Tells the user that Quit was refused: a refusal used to reach only the log, so
; the user saw Quit do nothing.
; @param SendFn {Func|Integer} Replaces NotifierSend (tests only).
NotifyQuitRefused(SendFn := 0) {
	try LoggerWarn("Notifier", "Quit was refused; the user is notified.")
	_NotifierDeliver(t("notify.quit_refused"), "error", "Quit refusal", SendFn)
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_NOTIFIER := Map(
    "send", NotifierSend
)
