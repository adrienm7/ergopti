; adapters/notifier.ahk

; ==============================================================================
; MODULE: Notifier Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Notifier port contract defined in
; static/ergopti_plus/shared/ports/Notifier.spec.js. Wraps Windows TrayTip
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
		case "warn":  return 2
		case "error": return 3
		default:      return 1
	}
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Method =============================
; =======================================================
; =======================================================

; Sends a system notification via Windows TrayTip.
; @param Title {String} The notification title (bold text in balloon).
; @param Opts  {Map|0}  Options Map: { body?, kind? }
;                         body  {String} Notification body text.
;                         kind  {String} "info" | "warn" | "error" (default "info").
NotifierSend(Title, Opts) {
	Body := ""
	Kind := "info"
	if (Opts is Map) {
		if Opts.Has("body") and Opts["body"] != ""
			Body := Opts["body"]
		if Opts.Has("kind") and Opts["kind"] != ""
			Kind := Opts["kind"]
	}
	Flag := _NotifierKindToFlag(Kind)
	try TrayTip(Body, Title, Flag)
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_NOTIFIER := Map(
    "notify", NotifierSend
)
