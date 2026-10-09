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

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_NOTIFIER := Map(
    "send", NotifierSend
)
