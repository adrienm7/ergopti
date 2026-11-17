; platform/system/notifier.ahk

; ==============================================================================
; MODULE: Notifier Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Notifier port contract defined in
; static/ergopti_plus/_shared/core/ports/Notifier.spec.js. Wraps Windows TrayTip
; behind the canonical NotifierSend function so domain modules can surface
; system notifications without calling TrayTip directly. It is the driver's only
; TrayTip call (pinned by test_notifier_single_owner.ahk): a direct call showed
; the program file name "ErgoptiPlus" as its title, could throw into the action
; that raised it, and escaped the test suite's display sink.
;
; NAMING CONVENTION:
; Port method → AHK name:  send(message, opts) → NotifierSend(Message, Opts)
;
; WINDOWS TRAYTIP NOTES:
; TrayTip v2 uses integer flags for the icon type:
;   1 = Info (blue "i"), 2 = Warning (yellow "!"), 3 = Error (red "X"),
;   and 0x10 (Mute) silences the system sound. The "level" option maps to the
;   icon; a notice is silent unless the caller asks for the sound, as macOS
;   hs.notify (no soundName) and Linux notify-send (no sound hint) show it.
; ==============================================================================




; =======================================================
; =======================================================
; ======= 1/ Kind → TrayTip Icon Flag Mapping ===========
; =======================================================
; =======================================================

; Replaces the desktop for the test suite: a toggle exercised by a unit test must
; not show a real notification on the developer's machine.
global _NotifierDisplaySink := 0

; The title of a notice whose caller names none: the product name of the port
; contract (DEFAULT_TITLE), which docs/design/studio-glossary.md keeps the same
; in every locale. "ErgoptiPlus" is the program file's name, never a label.
global NOTIFIER_PRODUCT_NAME := "Ergopti+"

; TrayTip's option bit that silences the system sound.
global NOTIFIER_MUTE_FLAG := 0x10

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

; Sends a system notification via Windows TrayTip. Never throws: a refused
; balloon is logged and reported by the return value.
; @param Message {String} The notification body text.
; @param Opts    {Map|0}  Options Map: { title?, level?, sound? }
;                           title {String} Notification title (bold text); the
;                                 product name when absent or empty.
;                           level {String} "info" | "success" | "warning" | "error".
;                           sound {Boolean} Plays the system sound; silent by default.
; @param DisplayFn {Func|Integer} Replaces the desktop (tests only).
; @returns {Boolean} Whether the notification was handed to the shell.
NotifierSend(Message, Opts, DisplayFn := 0) {
	global _NotifierDisplaySink, NOTIFIER_PRODUCT_NAME, NOTIFIER_MUTE_FLAG
	Title := NOTIFIER_PRODUCT_NAME
	Level := "info"
	Sound := false
	if (Opts is Map) {
		if Opts.Has("title") and Opts["title"] != ""
			Title := Opts["title"]
		if Opts.Has("level") and Opts["level"] != ""
			Level := Opts["level"]
		if Opts.Has("sound")
			Sound := (Opts["sound"] is Integer) && Opts["sound"] != 0
	}
	Flag := _NotifierKindToFlag(Level) | (Sound ? 0 : NOTIFIER_MUTE_FLAG)

	if !IsObject(DisplayFn) && IsObject(_NotifierDisplaySink)
		DisplayFn := _NotifierDisplaySink
	try {
		; An injected display seam remains active in CI so the adapter's typed
		; acknowledgement contract can be exercised without touching the desktop.
		if IsObject(DisplayFn) {
			Result := DisplayFn.Call(Message, Title, Flag)
			Shown := Type(Result) == "Integer" and Result != 0
		} else if (EnvGet("GITHUB_ACTIONS") = "true") {
			; Skip actual OS display in CI to avoid environment-specific hangs or failures.
			Shown := true
		} else {
			TrayTip(Message, Title, Flag)
			Shown := true
		}
	} catch as Err {
		try LoggerError("Notifier", "Tray notification failed: {1}.", Err.Message)
		return false
	}
	; The text is not logged: a notice can carry a path or a process's output.
	if Shown {
		try LoggerDebug("Notifier", "Notification shown (level {1}, sound {2}).", Level, Sound ? "on" : "off")
	} else {
		try LoggerWarn("Notifier", "The notification display refused the notice (level {1}).", Level)
	}
	return Shown
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
; _shared/menu/engine/feature_notice.lua: one log line first, enabled is "success" and
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

; Tells the user that a click made while paused waits for the resume. Every
; tray row stays live under a pause (EDD-1), and the actions not yet made to
; run paused refuse; a refusal that reached only the log made the click look
; dead. The same action is told once per window (ui.paused_refusal_repeat_ms):
; a page can send several refused messages for one click.
; @param What {String} English name of the refused action, for the log.
; @param SendFn {Func|Integer} Replaces NotifierSend (tests only).
; @returns {Boolean} Whether the notice was delivered now, not folded into the last one.
NotifyPausedRefusal(What, SendFn := 0) {
	static LastShown := Map()
	try LoggerWarn("Notifier", "{1} was refused while paused.", What)
	if LastShown.Has(What) && TickElapsed(LastShown[What]) < TimingsGet("ui", "paused_refusal_repeat_ms")
		return false
	LastShown[What] := A_TickCount
	_NotifierDeliver(t("notify.paused_refused"), "warning", "Paused refusal", SendFn)
	return true
}

; Tells a committed pause or resume, as macOS publish_pause_state and Linux
; script_actions PAUSE_NOTICES do: the pause at the warning level, the resume at
; the success level. Windows' balloon keeps the system's own display time.
; @param Paused {Boolean} The committed state.
; @param SendFn {Func|Integer} Replaces NotifierSend (tests only).
NotifyPauseState(Paused, SendFn := 0) {
	_NotifierDeliver(t(Paused ? "script_control.paused" : "script_control.resumed"),
		Paused ? "warning" : "success", Paused ? "Pause" : "Resume", SendFn)
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/platform/system/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_NOTIFIER := Map(
    "send", NotifierSend
)
