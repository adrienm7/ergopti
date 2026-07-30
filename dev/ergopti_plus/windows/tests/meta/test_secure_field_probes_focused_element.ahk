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





; ============================================================
; ============================================================
; ======= 3/ The latching cache is still the amplifier =======
; ============================================================
; ============================================================

; Prerequisite half: the per-HWND cache is what turns one wrong answer into a
; window-wide, self-renewing leak. If it ever gained focus-change invalidation
; the assertion above would still be right, but the severity recorded here would
; have rotted -- so pin what makes it load-bearing.
_SFPF_VerdictCacheIsKeyedOnTheControlHwnd() {
	Body := _DriverFuncBody("KL_IsFocusedFieldPassword")
	Assert(Body != "", "KL_IsFocusedFieldPassword must exist")
	Assert(InStr(Body, "ControlGetFocus") > 0 && InStr(Body, "KLPasswordCache.last_hwnd") > 0,
		"prerequisite: the verdict is still cached per focused-control HWND, which for any "
		. "single-HWND UI framework is per WINDOW -- one wrong answer covers every field in "
		. "it")
	Assert(InStr(Body, "KLPW_CACHE_TTL_MS") > 0,
		"prerequisite: the stale entry is refreshed by re-running the detector, so a probe "
		. "that answers about the window re-commits the same wrong verdict forever")
}

Test("privacy: the keylogger password verdict is still cached per HWND (keylogger-secure-field-window-scoped-probe)",
	_SFPF_VerdictCacheIsKeyedOnTheControlHwnd)
