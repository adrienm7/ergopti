; infra/hotstrings/hotstring_injection_plan.ahk

; ==============================================================================
; MODULE: Hotstring Injection Plan
; DESCRIPTION:
; The Windows reader of _shared/lua/hotstring_engine/injection_plan.lua: how many
; codepoints an expansion erases, what it types, which terminator it replays and
; what the rolling buffer holds afterwards. Same inputs, same outputs, pinned by
; _shared/tests/corpus/hotstrings/injection_plan_vectors.json. Delivery stays in
; hotstring_dispatch.ahk.
;
; FEATURES & RATIONALE:
; 1. Pure: no global state, no clock, no I/O. Map keys are the Lua field names,
;    so one vector reads the same on the three drivers.
; 2. AutoHotkey has no nil: an absent tail is "" and an absent replay is 0.
; 3. event_on_screen is always true on Windows: a watcher observes the completing
;    key after the application got it, so it is erased with the trigger. This is
;    the one driver-dependent input of the plan.
; 4. The plan's `replay` tells how a terminator travels where key events and the
;    text pipeline do not order themselves. Windows sends one atomic burst, whose
;    {Text} mode turns Enter and Tab into their keys, so it never needs them apart.
; ==============================================================================

#Requires AutoHotkey v2.0

global HSE_PLAN_PATH_AUTO := "auto"
global HSE_PLAN_PATH_TERMINATOR := "terminator"

; Fails on anything but a whole non-negative length.
_HSE_PlanRequireLength(Name, Value) {
	if !(Value is Integer) or Value < 0
		throw ValueError(Name . " must be a non-negative integer")
}

; Codepoints to erase from the screen. Auto path: the event is the trigger's last
; codepoint, already counted by TriggerLen; it is subtracted when it never reached
; the screen, clamped at 0 for a composed event. Terminator path: TriggerLen
; excludes the terminator, so the stripped no-break space and an on-screen
; terminator are added.
; @param Path {String} HSE_PLAN_PATH_AUTO or HSE_PLAN_PATH_TERMINATOR.
; @param TriggerLen {Integer} Length of the trigger.
; @param EventLen {Integer} Length of the completing event.
; @param EventOnScreen {Boolean} Whether the application already holds the event.
; @param NbspStripped {Boolean} Whether a no-break space precedes the terminator.
; @returns {Integer}
HSE_PlanEraseCount(Path, TriggerLen, EventLen, EventOnScreen, NbspStripped := false) {
	_HSE_PlanRequireLength("trigger_len", TriggerLen)
	_HSE_PlanRequireLength("event_len", EventLen)
	if !(EventOnScreen is Integer) or (EventOnScreen != 0 and EventOnScreen != 1)
		throw ValueError("event_on_screen must be a boolean")
	if (Path == HSE_PLAN_PATH_AUTO)
		return Max(0, TriggerLen - (EventOnScreen ? 0 : EventLen))
	if (Path == HSE_PLAN_PATH_TERMINATOR)
		return TriggerLen + (EventOnScreen ? EventLen : 0) + (NbspStripped ? 1 : 0)
	throw ValueError("path must be 'auto' or 'terminator', got " . String(Path))
}

; The terminator to replay: the typed one, unless its delimiter is consumed. Only
; the terminator path has one.
; @param Path {String} The path that completed the match.
; @param ConsumeTerminator {Boolean} Whether the delimiter is consumed.
; @param Terminator {String} The typed terminator, "" for none.
; @returns {String} The tail, "" for none.
HSE_PlanTail(Path, ConsumeTerminator, Terminator) {
	return (Path == HSE_PLAN_PATH_TERMINATOR and !ConsumeTerminator) ? Terminator : ""
}

; How a replayed terminator travels: Enter and Tab as raw keys, the rest as text.
; @param Chars {String} The terminator.
; @returns {Map} kind, chars and, for a raw key, key.
HSE_PlanReplaySpec(Chars) {
	if (Chars == "`r" or Chars == "`n")
		return Map("kind", "key", "key", "return", "chars", Chars)
	if (Chars == "`t")
		return Map("kind", "key", "key", "tab", "chars", Chars)
	return Map("kind", "text", "chars", Chars)
}

; Builds the plan of one expansion. `cascade`, when the chain produced a net edit,
; replaces the first step's replacement, trigger length, tail and final flag.
; @param Request {Map} path, trigger_len, event_len, event_on_screen, nbsp_stripped,
;   replacement, terminator, consume_terminator, final_result and
;   cascade (Map: replacement, trigger_len, tail, final_result); only the first
;   four and the replacement are required.
; @returns {Map} erase, text, tail, replay (0 for none), buffer_suffix, final_result.
HSE_PlanBuild(Request) {
	if !(Request is Map)
		throw TypeError("the injection plan needs a request Map")
	Text := Request.Get("replacement", 0)
	if !(Text is String)
		throw ValueError("replacement must be a string")
	Path := Request.Get("path", "")
	TriggerLen := Request.Get("trigger_len", "")
	Terminator := Request.Get("terminator", "")
	Tail := HSE_PlanTail(Path, Request.Get("consume_terminator", false), Terminator)
	Final := Request.Get("final_result", false)
	if Request.Has("cascade") {
		Cascade := Request["cascade"]
		Text := Cascade["replacement"]
		TriggerLen := Cascade["trigger_len"]
		Tail := Cascade.Get("tail", "")
		Final := Cascade.Get("final_result", false)
	}
	return Map(
		"erase", HSE_PlanEraseCount(Path, TriggerLen, Request.Get("event_len", ""),
			Request.Get("event_on_screen", ""), Request.Get("nbsp_stripped", false)),
		"text", Text,
		"tail", Tail,
		"replay", Tail != "" ? HSE_PlanReplaySpec(Terminator != "" ? Terminator : Tail) : 0,
		"buffer_suffix", Text . Tail,
		"final_result", Final ? true : false)
}
