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

	Assert(Seen = 1,
		"IsPassword must be read exactly once, by the disposable worker shared by both secure-field consumers. Found " . Seen)
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

	TerminalBody := _DriverFuncBody("KL_OnPasswordWorkerTerminal")
	Assert(InStr(TerminalBody, 'Verdict.Get("element_id"') > 0
		and InStr(TerminalBody, "CurrentFocus.Generation != FocusGeneration") > 0
		and InStr(TerminalBody, "UIASW_ContextMatches") > 0,
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
	TabBody := _DriverFuncBody("_KL_Hook_InvalidateTabInput")
	Assert(KeyBody != "" and TabBody != "",
		"the actual Tab callback and focused-element invalidation owner must exist")
	_SFPF_TabSourceOrder(KeyBody, TabBody)
	for HandlerName in ["KL_Mouse_OnLDown", "KL_Mouse_OnRDown", "KL_Mouse_OnMDown"]
		Assert(InStr(_DriverFuncBody(HandlerName), "KL_InvalidatePasswordFocus()") > 0,
			HandlerName . " must invalidate a same-HWND focused element before reuse")
}

Test("privacy: the keylogger password verdict cache is focused-element scoped (audit-ahk-003-element-cache-key)",
	_SFPF_VerdictCacheIsKeyedOnTheFocusedElement)

; FIFO admission classifies the source field before its finally block invalidates
; Tab. The callee renews only the current receipt, so deferred commit can retain
; this key's source verdict while destination-field input requires a fresh probe.
_SFPF_TabSourceOrder(KeyBody, TabBody) {
	Assert(KeyBody != "" and TabBody != "", "both actual Tab owners are required")
	KeyCode := _DriverMaskNonCode(&KeyBody)
	TabCode := _DriverMaskNonCode(&TabBody)
	Positions := []
	for Name in ["MF_ShouldFilter", "_KL_Hook_PrepareInput",
			"_KL_Hook_InvalidateTabInput", "_KL_Hook_CompleteInput"] {
		Pattern := 'i)\b' . Name . '\s*\('
		Count := 0
		Offset := 1
		while Pos := RegExMatch(KeyCode, Pattern, &Call, Offset) {
			Count += 1
			Offset := Pos + StrLen(Call[0])
		}
		AssertEqual(1, Count, "the actual Tab call must be unique: " . Name)
		Arguments := Name = "MF_ShouldFilter" ? "" : "Intent"
		Position := RegExMatch(KeyCode, 'i)\b' . Name
			. '\s*\(\s*' . Arguments . '\s*\)')
		Assert(Position > 0, "the actual Tab call must carry its admitted receipt: " . Name)
		Positions.Push(Position)
	}
	Assert(Positions[1] < Positions[2] and Positions[2] < Positions[3]
		and Positions[3] < Positions[4],
		"source classification and preparation must precede Tab invalidation and FIFO completion")
	Assert(RegExMatch(KeyCode, 'i)\bPotentialFocusMove\s*:=\s*vk\s*=\s*0x09\b')
		and RegExMatch(KeyCode,
			'i)\bfinally\s*\{\s*try\s*\{\s*if\s+PotentialFocusMove\s+_KL_Hook_InvalidateTabInput\s*\(\s*Intent\s*\)'),
		"Tab alone must invalidate in callback finalization, including classification failures")
	Assert(RegExMatch(TabCode,
		'i)\bCurrent\s*:=\s*IsObject\s*\(\s*Intent\s*\)\s*&&\s*_KL_Hook_InputCurrent\s*\(\s*Intent\s*\)\s+KL_InvalidatePasswordFocus\s*\(\s*\)\s+if\s+Current\s+Intent\.privacy\[\s*\]\s*:=\s*KLPasswordCache\.generation'),
		"the invalidation owner must renew only a previously current receipt after retiring the source field")
	Assignment := RegExMatch(TabCode,
		'i)\bIntent\.privacy\[\s*\]\s*:=\s*KLPasswordCache\.generation', &Token)
	Assert(Assignment > 0 and RegExMatch(SubStr(TabBody, Assignment, StrLen(Token[0])),
		'i)^Intent\.privacy\["password_generation"\]\s*:=\s*KLPasswordCache\.generation$'),
		"the renewed field must be the actual password publication token")
}

_SFPF_TabSourcePolicyControls() {
	KeyBody := _DriverFuncBody("KL_Hook_OnKeyDown")
	TabBody := _DriverFuncBody("_KL_Hook_InvalidateTabInput")
	Assert(KeyBody != "" and TabBody != "", "source controls require both actual Tab owners")
	_SFPF_TabSourceOrder(KeyBody, TabBody)
	_SFPF_TabSourceOrder(StrReplace(KeyBody, "_KL_Hook_InvalidateTabInput",
		"_kl_hook_invalidatetabinput"), TabBody)
	for Name in ["MF_ShouldFilter", "_KL_Hook_PrepareInput",
			"_KL_Hook_InvalidateTabInput", "_KL_Hook_CompleteInput"] {
		for Spoof in ["'" . Name . "()'", "; " . Name . "()"] {
			Changed := RegExReplace(KeyBody, 'i)\b' . Name . '\s*\(', Spoof . "(", &Count)
			AssertEqual(1, Count, "each real callback call must be mutated exactly once")
			_SFPF_TabExpectPolicyRefusal(Changed, TabBody)
		}
	}
	_SFPF_TabExpectPolicyRefusal(KeyBody, "")
	_SFPF_TabExpectPolicyRefusal(KeyBody
		. "`n_KL_HOOK_INVALIDATETABINPUT(Intent)", TabBody)
	_SFPF_TabExpectPolicyRefusal(KeyBody,
		StrReplace(TabBody, "if Current", "if true"))
	_SFPF_TabExpectPolicyRefusal(KeyBody,
		StrReplace(TabBody, '"password_generation"', '"focus_generation"'))
	_SFPF_TabExpectPolicyRefusal(KeyBody,
		StrReplace(TabBody, "KL_InvalidatePasswordFocus()", ""))
	_SFPF_TabExpectPolicyRefusal(
		StrReplace(KeyBody, "_KL_Hook_InvalidateTabInput(Intent)",
			"_KL_Hook_InvalidateTabInput(false)"), TabBody)
	Changed := StrReplace(KeyBody, "_KL_Hook_PrepareInput(Intent)", "")
	Changed := StrReplace(Changed, "_KL_Hook_CompleteInput(Intent)",
		"_KL_Hook_PrepareInput(Intent)`n`t`t`t_KL_Hook_CompleteInput(Intent)")
	_SFPF_TabExpectPolicyRefusal(Changed, TabBody)
}

_SFPF_TabExpectPolicyRefusal(KeyBody, TabBody) {
	Refused := false
	try _SFPF_TabSourceOrder(KeyBody, TabBody)
	catch Error as Err {
		if Type(Err) != "Error"
			throw Err
		Refused := true
	}
	AssertTrue(Refused, "an absent, spoofed or reordered Tab owner must fail the actual source policy")
}

Test("privacy: Tab source-field invalidation follows actual FIFO owners and rejects source spoofs",
	_SFPF_TabSourcePolicyControls)
