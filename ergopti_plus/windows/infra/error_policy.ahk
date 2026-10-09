; infra/error_policy.ahk

; ==============================================================================
; MODULE: Error Window Policy
; DESCRIPTION:
; AHK port of _shared/lua/diagnostics/error_policy.lua: decides whether a
; logged ERROR opens the error window (_shared/ui/error_dialog/), joins the one
; already open, or is only logged. The thresholds are data:
; _shared/modules/diagnostics/error_policy.json. Both ports replay
; _shared/tests/corpus/diagnostics/error_policy_vectors.json.
;
; FEATURES & RATIONALE:
; 1. An error's signature is its module and the message template the code
;    passed to the logger, before its arguments are filled in: a path, a count
;    or a time that changes from one occurrence to the next cannot make one
;    fault look like many.
; 2. A signature opens the window at most once per session.
; 3. A budget of max_dialogs windows per window_sec seconds bounds a storm of
;    distinct faults. An error over the budget is not recorded, so it can still
;    open the window when it recurs once the budget allows.
; 4. An error logged while the window is open, or about to open, joins it and
;    spends no budget.
; 5. Pure: the host owns the clock, the window and the setting, and passes them
;    in with each event.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================
; =============================
; ======= 1/ The Policy =======
; =============================
; =============================

; True when a value is a whole number of at least Min.
; @param Value {Any}
; @param Min {Number}
; @returns {Boolean}
_ErrorPolicy_IsCount(Value, Min) {
	return (Value is Integer) && (Value >= Min)
}

; Checks a decoded error_policy.json and returns it.
; @param Policy {Map}
; @returns {Map} The same Map.
; @throws {ValueError} When a field is missing or out of range.
ErrorPolicy_Validate(Policy) {
	if !(Policy is Map)
		throw ValueError("error_policy: the policy must be a Map.")
	Separator := Policy.Get("signature_separator", "")
	if !(Separator is String) || (Separator == "")
		throw ValueError("error_policy: signature_separator must be a non-empty string.")
	if !_ErrorPolicy_IsCount(Policy.Get("max_dialogs", ""), 1)
		throw ValueError("error_policy: max_dialogs must be a whole number of at least 1.")
	Window := Policy.Get("window_sec", "")
	if !(Window is Number) || (Window <= 0)
		throw ValueError("error_policy: window_sec must be a positive number.")
	if !_ErrorPolicy_IsCount(Policy.Get("present_delay_ms", ""), 0)
		throw ValueError("error_policy: present_delay_ms must be a whole number of at least 0.")
	return Policy
}

; A fresh session: no signature seen, no window opened.
; @returns {Map} { seen: Map, shown: Array }
ErrorPolicy_NewState() {
	return Map("seen", Map(), "shown", [])
}

; An error's signature: its module, the separator, then its template.
; @param Policy {Map} { signature_separator }
; @param Module {Any}
; @param Template {Any} The message template, before its arguments.
; @returns {String}
ErrorPolicy_Signature(Policy, Module, Template) {
	return String(Module) . Policy["signature_separator"] . String(Template)
}





; ==============================
; ==============================
; ======= 2/ The Verdict =======
; ==============================
; ==============================

; Decides what one logged error does, and records it in the session.
; @param State {Map} From ErrorPolicy_NewState().
; @param Policy {Map} A validated policy.
; @param Event {Map} { module, template, at (seconds), enabled, open }
; @returns {Map} { verdict: "disabled"|"duplicate"|"folded"|"rate_limited"|"show", signature }
ErrorPolicy_Decide(State, Policy, Event) {
	Signature := ErrorPolicy_Signature(Policy, Event["module"], Event["template"])
	Verdict := _ErrorPolicy_Verdict(State, Policy, Event, Signature)
	return Map("verdict", Verdict, "signature", Signature)
}

; The verdict alone; see ErrorPolicy_Decide.
_ErrorPolicy_Verdict(State, Policy, Event, Signature) {
	if !Event["enabled"]
		return "disabled"
	Seen := State["seen"]
	if Seen.Has(Signature)
		return "duplicate"
	if Event["open"] {
		Seen[Signature] := true
		return "folded"
	}
	; The windows that no longer count against the budget, oldest first
	Shown := State["shown"]
	Now := Event["at"]
	while (Shown.Length > 0) && (Now - Shown[1] >= Policy["window_sec"])
		Shown.RemoveAt(1)
	if (Shown.Length >= Policy["max_dialogs"])
		return "rate_limited"
	Seen[Signature] := true
	Shown.Push(Now)
	return "show"
}
