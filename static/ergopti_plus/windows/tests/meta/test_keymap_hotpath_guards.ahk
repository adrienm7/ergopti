; tests/meta/test_keymap_hotpath_guards.ahk

; ==============================================================================
; MODULE: Keymap Hot-Path Guard Meta Test
; DESCRIPTION:
; Guards for the per-keystroke layer, where the severity bar differs from the
; rest of the driver: a fault here drops a character, transposes two, or makes
; Windows silently discard everything typed during a stall.
;
; WrapTextIfSelected is reached from AltGrShiftDispatch, which wraps EVERY AltGr
; callback in Critical("On") — and 24 of the 34 ALTGR_BASE_ROWS entries, plus
; SHIFT_SYMBOLS["SC039"], are binds of it. It makes a synchronous clipboard
; snapshot there: CB_SaveAll() is ClipboardAll(), an unbounded all-formats copy.
; With a screenshot bitmap, large HTML/RTF or a file list on the clipboard, or
; another process holding it open, that blocks past LowLevelHooksTimeout — and
; Windows then DROPS the keys typed during the window.
;
; Two comments actively told the next maintainer this was already handled
; ("WrapTextIfSelected stays OUT of Critical — it Sleeps"). The Sleep is long
; gone; the blocking is not. A stale comment asserting a safety property is
; worse than no comment, because it stops the reader checking.
;
; HotIf sets a PROCESS-WIDE criterion. A throw between setting and resetting it
; leaks that criterion into every later Hotkey() call in the driver.
;
; SCOPE: source introspection of the keymap layer.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ The wrap path yields the hook =======
; ================================================
; ================================================

_KHG_WrapReleasesCriticalAroundTheClipboard() {
	Body := _DriverFuncBody("WrapTextIfSelected")
	Assert(Body != "", "WrapTextIfSelected() must exist")

	CritPos := InStr(Body, 'Critical("Off")')
	Assert(CritPos > 0,
		"WrapTextIfSelected must RELEASE Critical around its clipboard round-trip — its callers wrap it in Critical(On), and CB_SaveAll() is an unbounded ClipboardAll() snapshot that blocks the keystroke thread past LowLevelHooksTimeout, at which point Windows drops the keys typed meanwhile")

	SendPos := InStr(Body, "SendInstant(")
	Assert(SendPos > CritPos,
		"the release must come BEFORE the clipboard work it exists to yield across")
	Assert(InStr(Body, "finally") > 0,
		"the caller's Critical state must be restored on EVERY exit path, including the throwing one")
}

; The Features read on this path is one of three siblings; the other two guard.
_KHG_WrapFeatureReadIsGuarded() {
	Body := _DriverFuncBody("WrapTextIfSelected")
	Assert(Body != "", "WrapTextIfSelected() must exist")
	Assert(InStr(Body, 'Features["shortcuts"].Has("wrap_text_if_selected")') > 0,
		"the wrap feature flag must be read through .Has() like its two siblings — ManifestBuildFeaturesMap returns an empty Map when the manifest fails to load, and a raw Map read throws on the keystroke thread")
}

; The stale comments claimed the hazard was already avoided.
_KHG_StaleCriticalCommentsAreCorrected() {
	Src := _DriverDirConcat("modules/keymap")
	Assert(Src != "", "the keymap source must be readable")
	Assert(InStr(Src, "WrapTextIfSelected stays OUT of") == 0,
		"the comment claiming WrapTextIfSelected stays out of Critical must not return — it is called from inside Critical by every AltGr binding, and the Sleep it cited as the reason no longer exists")
}





; ==================================================
; ==================================================
; ======= 2/ HotIf resets are exception-safe =======
; ==================================================
; ==================================================

; Checked as a class: a leaked criterion silently gates unrelated layers, and the
; only non-literal key name in these loops comes from user-editable TOML.
_KHG_HotIfResetsAreExceptionSafe() {
	Checked := 0
	for Name in ["RegisterAltGrLayer", "RegisterShiftLayer"] {
		Body := _DriverFuncBody(Name)
		if (Body == "" or InStr(Body, "HotIf(") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "finally") > 0,
			Name . " must reset HotIf in a finally — the criterion is process-wide, so a throw before the reset leaks it into every later Hotkey() call in the driver")
	}
	Assert(Checked >= 2,
		"expected at least two HotIf-setting registrars to police (found " . Checked . ")")
}


Test("meta keymap: the wrap path releases Critical across its clipboard work",
	_KHG_WrapReleasesCriticalAroundTheClipboard)
Test("meta keymap: the wrap feature flag is read defensively",
	_KHG_WrapFeatureReadIsGuarded)
Test("meta keymap: the stale out-of-Critical comments stay corrected",
	_KHG_StaleCriticalCommentsAreCorrected)
Test("meta keymap: HotIf criteria are reset in a finally",
	_KHG_HotIfResetsAreExceptionSafe)
