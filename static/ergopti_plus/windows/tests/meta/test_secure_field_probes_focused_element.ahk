; tests/meta/test_secure_field_probes_focused_element.ahk

; ==============================================================================
; MODULE: IsPassword Probe Scope (keylogger-secure-field-window-scoped-probe)
; DESCRIPTION:
; The keylogger's secure-field detector asked UIA the right question of the
; wrong element. KL_DetectPasswordFor called UIA.ElementFromHandle(hwnd), which
; describes the element BEHIND that window handle. Chromium and Electron expose
; one Chrome_RenderWidgetHostHWND for the whole window and WPF/UWP one
; HwndWrapper[...], so the probe always landed on the render widget or the
; window pane, never on the focused input, and its IsPassword was always 0.
; Layers 1-2 cannot classify those frameworks either -- the class allow-list is
; matched against a WINDOW class -- so a bogus "not a password" was committed
; for the whole window, and KL_IsFocusedFieldPassword's per-HWND cache then
; latched it across every field in it, the site's password box included. Every
; character typed there reached events_typing.text in data.sql, the file the
; driver documents as its git-friendly, cloud-syncable source of truth. The
; 2000 ms TTL re-detect re-ran the same window-scoped probe, so it never healed.
;
; adapters/secure_field_detector.ahk already asked the same question the right
; way, via UIA.GetFocusedElement(). The stronger probe was on the weaker
; consequence: the SFD path only decides whether to send context to a local LLM.
;
; ROOT CAUSE ENCODED: a transitive guard, not a per-function one. The shipped
; test for this invariant asserted GetFocusedElement for SFD_ProbeFocusedUia
; ONLY, so the keylogger sibling was written wrong and the suite stayed green.
; This derives the set of IsPassword consumers FROM the source, so a third one
; joins the guarantee automatically.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Name of the top-level function whose body encloses byte offset Pos: the last
; column-0 "Name(params) {" line at or before it. Src must already have its
; full-line comments stripped, so prose can never be mistaken for a definition.
_SFPF_EnclosingFunction(Src, Pos) {
	Name := ""
	for Line in StrSplit(SubStr(Src, 1, Pos), "`n", "`r")
		if RegExMatch(Line, "^([A-Za-z_]\w*)\([^\r\n]*\)\s*\{\s*$", &m)
			Name := m[1]
	return Name
}





; =========================================================
; =========================================================
; ======= 2/ Every IsPassword reader uses the focus =======
; =========================================================
; =========================================================

_SFPF_IsPasswordIsReadFromTheFocusedElement() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be locatable")

	Needle := "UIA.Property.IsPassword"
	Seen   := 0
	Pos    := 1
	while (Pos := InStr(Src, Needle, , Pos)) {
		Name := _SFPF_EnclosingFunction(Src, Pos)
		Pos += StrLen(Needle)
		Assert(Name != "",
			"every UIA.Property.IsPassword read must sit inside a resolvable top-level "
			. "function so this guard can reach it")

		Body := _DriverFuncBody(Name)
		Assert(Body != "", "the body of '" . Name . "' must be resolvable")
		Seen += 1

		Assert(InStr(Body, "UIA.GetFocusedElement()") > 0,
			"'" . Name . "' must read IsPassword from the FOCUSED element. It is a "
			. "focus-scoped question, and the answer decides whether a keystroke is "
			. "persisted to disk (keylogger-secure-field-window-scoped-probe)")
		Assert(InStr(Body, "UIA.ElementFromHandle(") = 0,
			"'" . Name . "' must not acquire its element with UIA.ElementFromHandle: that "
			. "answers about the WINDOW, and for a Chromium / Electron / WPF password box "
			. "-- one HWND for every field in the window -- it is always false, after which "
			. "the per-HWND verdict cache latches that answer for the whole window")
	}

	Assert(Seen >= 2,
		"prerequisite: both secure-field detectors must still read UIA.Property.IsPassword "
		. "-- the keylogger one and the LLM adapter one. Found " . Seen . ". A single "
		. "consumer would mean this guard had quietly stopped covering the class")
}

Test("privacy: every UIA IsPassword verdict is read from the focused element (keylogger-secure-field-window-scoped-probe)",
	_SFPF_IsPasswordIsReadFromTheFocusedElement)





; =============================================================
; =============================================================
; ======= 3/ Cache identity follows the focused element =======
; =============================================================
; =============================================================

; A UIA RuntimeId plus a focus-event generation now scopes every negative cache
; hit. Keeping this structural guard beside the focused-element probe prevents a
; later optimisation from silently collapsing the key back to HWND-only.
_SFPF_VerdictCacheIsKeyedOnTheFocusedElement() {
	CacheBody := _DriverFuncBody("KL_TryGetPwCachedVerdict")
	Assert(CacheBody != "", "KL_TryGetPwCachedVerdict must exist")
	Assert(InStr(CacheBody, "last_hwnd") > 0
		and InStr(CacheBody, "last_focus_generation") > 0
		and InStr(CacheBody, "last_element_id") > 0,
		"the cache key must include host HWND, focus generation and UIA element identity")
	Assert(InStr(CacheBody, "focus_tracking_active") > 0,
		"a negative verdict must fail closed when the focus invalidator is unavailable")

	InvalidateBody := _DriverFuncBody("KL_InvalidatePasswordFocus")
	Assert(InStr(InvalidateBody, "focus_generation += 1") > 0
		and InStr(InvalidateBody, 'current_element_id := ""') > 0,
		"every focus event must retire the published element identity before reuse")

	AsyncBody := _DriverFuncBody("KL_AsyncPasswordDetect")
	Assert(InStr(AsyncBody, 'Verdict.Get("element_id"') > 0
		and InStr(AsyncBody, "CurrentFocus.Generation = FocusGeneration") > 0,
		"a deferred UIA verdict must publish only to the exact focus generation it probed")

	StartBody := _DriverFuncBody("KL_Hook_Start")
	StopBody := _DriverFuncBody("KL_Hook_Stop")
	Assert(InStr(StartBody, "KL_PasswordFocusTrackingStart()") > 0
		and InStr(StopBody, "KL_PasswordFocusTrackingStop()") > 0,
		"the focused-element invalidator must be lifecycle-paired with the keylogger hook")
	TrackerStopBody := _DriverFuncBody("KL_PasswordFocusTrackingStop")
	UnhookFencePos := InStr(TrackerStopBody, "if !Unhooked")
	CallbackFreePos := InStr(TrackerStopBody, "KL_FreePasswordFocusCallback")
	CallbackClearPos := InStr(TrackerStopBody, "KLPasswordCache.focus_callback := 0")
	Assert(UnhookFencePos > 0
		and CallbackFreePos > UnhookFencePos
		and CallbackClearPos > CallbackFreePos,
		"a failed native unhook must retain the callback thunk and ownership fields for a safe retry")

	KeyBody := _DriverFuncBody("KL_Hook_OnKeyDown")
	KeyInvalidatePos := InStr(KeyBody, "KL_InvalidatePasswordFocus()")
	KeyFilterPos := InStr(KeyBody, "MF_ShouldFilter()")
	Assert(KeyFilterPos > 0 and KeyInvalidatePos > KeyFilterPos,
		"Tab must retire the source-field verdict after its own filter and before the destination field's first character")
	for HandlerName in ["KL_Mouse_OnLDown", "KL_Mouse_OnRDown", "KL_Mouse_OnMDown"]
		Assert(InStr(_DriverFuncBody(HandlerName), "KL_InvalidatePasswordFocus()") > 0,
			HandlerName . " must invalidate a same-HWND focused element before reuse")
}

Test("privacy: the keylogger password verdict cache is focused-element scoped (audit-ahk-003-element-cache-key)",
	_SFPF_VerdictCacheIsKeyedOnTheFocusedElement)
