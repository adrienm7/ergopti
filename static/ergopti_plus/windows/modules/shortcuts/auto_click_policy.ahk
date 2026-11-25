; modules/shortcuts/auto_click_policy.ahk

; ==============================================================================
; MODULE: Auto-Click Policy (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/shortcuts/engine/auto_click_policy.lua: whether one tick of
; the anti-sleep auto-clicker may capture the foreground window, and whether a
; match found there may be clicked. Every refusal lives here, so no Windows
; path can click outside the scope the maintainer set on 2026-11-25.
;
; FEATURES & RATIONALE:
; 1. Allowed apps only (the executable name of the foreground window, compared
;    without case): a system « Allow » dialog belongs to another process.
; 2. Never while the session is locked, Ergopti is paused or a secure field
;    has the focus; never outside the captured window; never twice for one
;    image inside its cooldown.
; 3. The reasons are the shared closed vocabulary, logged as they are.
;
; Pinned by _shared/tests/corpus/keep_awake/auto_click_policy_vectors.json,
; which tests/unit/modules/shortcuts/test_auto_click_matcher.ahk replays.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 1/ Public API ============
; ==================================
; ==================================

; The closed vocabulary of a decision, the shared module's REASONS.
AutoClickReasons() {
	static Reasons := ["click", "app_not_allowed", "no_foreground_window", "screen_locked", "paused",
		"secure_field", "outside_window", "cooldown"]
	return Reasons
}

; Whether an app identity is in the allowed list, without case.
; @param AppId {String} The executable name; "" for none.
; @param Allowed {Array} The allowed identities.
AutoClickAppAllowed(AppId, Allowed) {
	if !(Allowed is Array)
		throw TypeError("The allowed apps are a list.")
	if !(AppId is String) || AppId = ""
		return false
	for Entry in Allowed {
		if (Entry is String) && StrLower(Entry) == StrLower(AppId)
			return true
	}
	return false
}

; Whether a tick may capture the foreground window at all.
; @param State {Map} app_id, allowed_apps, has_window, locked, paused, secure_field.
; @param Reason {VarRef} Set to one word of AutoClickReasons ("click" when allowed).
AutoClickMayCapture(State, &Reason) {
	if !(State is Map)
		throw TypeError("The policy needs the session state.")
	if _AutoClickFlag(State, "locked") {
		Reason := "screen_locked"
		return false
	}
	if _AutoClickFlag(State, "paused") {
		Reason := "paused"
		return false
	}
	if _AutoClickFlag(State, "secure_field") {
		Reason := "secure_field"
		return false
	}
	if !_AutoClickFlag(State, "has_window") {
		Reason := "no_foreground_window"
		return false
	}
	AppId := State.Has("app_id") ? State["app_id"] : ""
	if !AutoClickAppAllowed(AppId is String ? AppId : "", State["allowed_apps"]) {
		Reason := "app_not_allowed"
		return false
	}
	Reason := "click"
	return true
}

; Whether a match may be clicked now.
; @param State {Map} As AutoClickMayCapture, plus window { width, height },
;   match { x, y, width, height }, image_id, last_clicks, now_ms, cooldown_ms.
; @param Reason {VarRef} Set to one word of AutoClickReasons.
AutoClickMayClick(State, &Reason) {
	if !AutoClickMayCapture(State, &Reason)
		return false
	W := State["window"], M := State["match"]
	if M["x"] < 0 || M["y"] < 0 || M["x"] + M["width"] > W["width"] || M["y"] + M["height"] > W["height"] {
		Reason := "outside_window"
		return false
	}
	if !(State["image_id"] is String)
		throw TypeError("A click decision needs the image id.")
	if !IsNumber(State["now_ms"]) || !IsNumber(State["cooldown_ms"])
		throw TypeError("A click decision needs the time and the cooldown.")
	LastClicks := State.Has("last_clicks") && (State["last_clicks"] is Map) ? State["last_clicks"] : Map()
	if LastClicks.Has(State["image_id"]) && State["now_ms"] - LastClicks[State["image_id"]] < State["cooldown_ms"] {
		Reason := "cooldown"
		return false
	}
	Reason := "click"
	return true
}

; A boolean field of the state; absent or JSON null reads false.
_AutoClickFlag(State, Key) {
	if !State.Has(Key)
		return false
	Value := State[Key]
	return (Value is Integer) ? Value != 0 : false
}
