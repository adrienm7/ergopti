; tests/meta/test_tooltip_expiry_timers_keep_preview.ahk

; ==============================================================================
; MODULE: Regression — no tooltip expiry timer wipes the preview buffer alone
;         (tooltip-expiry-timers-keep-preview)
; DESCRIPTION:
; _PrefixBuffer (what the tooltip describes) and HSE_Buffer (what the engine will
; match) must always describe the same screen. The tooltip module has two
; deadline-driven teardown ROUTES, represented by three timer callbacks (the
; exact dequeue deadline forwards to its poll):
;
;   - _TooltipTimerFn      — the whole-surface safety/auto-hide deadline. Fixed,
;                            and pinned by test_preview_never_wiped_alone.ahk.
;   - _TooltipDequeuePollFn — the per-row deadline sweep, which hid the surface
;                            AND called _ResetPrefixBuffer() when the last row
;                            expired. That guard named only its sibling, so this
;                            one stayed broken and invisible.
;
; ROOT CAUSE ENCODED: a timer firing on a DEADLINE means the rows have been on
; screen long enough — never that the user abandoned the word. Nothing was typed,
; nothing moved the caret, and the engine still holds the word, so resetting the
; preview alone leaves the two buffers describing different text and the tooltip
; stays silent for the whole rest of that word.
;
; SCOPE: source introspection. Both callbacks are SetTimer targets that tear down
; real Gui/GDI surfaces, so they cannot be driven headlessly.
;
; The site list is DERIVED from the driver source (every _Tooltip*Fn callback,
; regardless of its parameter list) rather than enumerated by hand. Each
; callback's tooltip-local call graph is inspected, so forwarding through an
; owner-aware helper cannot make a teardown disappear from the guard.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================================
; ======================================================================
; ======= 1/ The class of tooltip timer callbacks ======================
; ======================================================================
; ======================================================================

; Every top-level `_Tooltip<Something>Fn(...)` in the driver source. Parameters
; may be required or optional; the old `()`-only regex silently lost both
; dequeue callbacks after they gained generation/surface ownership arguments.
_TETKP_TimerCallbackNames() {
	Src := _DriverSourceNoComments()
	Names := []
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^(_Tooltip\w*Fn)\([^)]*\)\s*\{", &M, Pos)) {
		Names.Push(M[1])
		Pos += StrLen(M[0])
	}
	return Names
}

; Does Name's tooltip-local call graph contain Needle? Seen prevents helper
; cycles from recursing forever. Dynamic discovery uses OrEmpty deliberately:
; a token such as a method call is not a top-level tooltip helper and therefore
; has no body to traverse.
_TETKP_ReachableContains(Name, Needle, Seen := unset) {
	if !IsSet(Seen)
		Seen := Map()
	if Seen.Has(Name)
		return false
	Seen[Name] := true
	Body := _DriverFuncBodyOrEmpty(Name)
	if (Body == "")
		return false
	if (InStr(Body, Needle) > 0)
		return true
	Pos := 1
	while RegExMatch(Body, "\b(_Tooltip[A-Za-z0-9_]+)\s*\(", &Call, Pos) {
		Pos := Call.Pos + Call.Len
		if _TETKP_ReachableContains(Call[1], Needle, Seen)
			return true
	}
	return false
}

_TETKP_TheClassIsDiscovered() {
	Names := _TETKP_TimerCallbackNames()
	Assert(Names.Length >= 3,
		"the timer-callback scan must find the tooltip timer callbacks (found " . Names.Length . ") — if the naming convention changed, this whole guard silently stops covering anything")

	Seen := Map()
	for Name in Names
		Seen[Name] := true
	for Required in ["_TooltipTimerFn", "_TooltipDequeueDeadlineFn",
		"_TooltipDequeuePollFn"] {
		Assert(Seen.Has(Required),
			Required . " must be discovered by the signature-agnostic callback scan")
		Assert(_TETKP_ReachableContains(Required, "TooltipHide("),
			Required . " must still reach the canonical tooltip teardown through its helper call graph")
	}
}





; ======================================================================
; ======================================================================
; ======= 2/ None of them resets the preview ===========================
; ======================================================================
; ======================================================================

_TETKP_NoExpiryTimerWipesThePreview() {
	Checked := 0
	for Name in _TETKP_TimerCallbackNames() {
		; Only callbacks whose tooltip-local graph tears a surface down are in scope;
		; owner timers may forward through retry/deadline helpers first.
		if !_TETKP_ReachableContains(Name, "TooltipHide(")
			continue
		Checked += 1
		Assert(!_TETKP_ReachableContains(Name, "_ResetPrefixBuffer("),
			Name . " must not reset the preview buffer. It fires on a DEADLINE, i.e. precisely when nothing happened — no keystroke, no caret move — so the engine still holds the word. Wiping the preview alone makes the two buffers describe different text, and no later keystroke in that word can reproduce the prefix the tooltip needs, so the suggestion never comes back")
	}
	Assert(Checked >= 3,
		"both deadline-driven teardown routes, including the dequeue forwarder, must be in scope (only " . Checked . " callback(s) seen)")
}

; The teardown itself is the job and must not be removed by an over-eager fix.
_TETKP_TheDequeuePollStillHides() {
	Body := _DriverFuncBody("_TooltipDequeuePollFn")
	Assert(Body != "", "_TooltipDequeuePollFn() must exist in the driver source")
	Assert(InStr(Body, "TooltipHide") > 0,
		"the dequeue poll must still hide the tooltip once every row has expired — that is its actual job")
}


Test("meta tooltip-expiry-timers-keep-preview: the timer-callback class is discovered",
	_TETKP_TheClassIsDiscovered)
Test("meta tooltip-expiry-timers-keep-preview: no expiry timer wipes the preview alone",
	_TETKP_NoExpiryTimerWipesThePreview)
Test("meta tooltip-expiry-timers-keep-preview: the dequeue poll still hides the surface",
	_TETKP_TheDequeuePollStillHides)
