; tests/meta/core/ui/windows/test_list_view_headers_localized.ahk

; ==============================================================================
; MODULE: List View Headers Localized Meta Test
; DESCRIPTION:
; Static guard for PCK-08 of the pickers-and-prompts parity campaign. The
; application picker drew its two column headers from a literal array,
; « Application » and « Processus », so every user read a French header under
; a dialog translated in 21 languages. The headers now come from t(). The
; guard covers every list view of the driver, not the one site it was found at:
; a header array may hold no string literal.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Header assertion ======================
; ==================================================
; ==================================================

_LVHL_HeadersComeFromI18n() {
	Src := _DriverSourceNoComments()
	Calls := 0
	Pos := 1
	; The header array is the call's second argument; a continued call may wrap
	; it to the next line, so the span reaches the first closing bracket.
	while (Pos := RegExMatch(Src, "s)AddListView\([^\[\)]*\[([^\]]*)\]", &Match, Pos)) {
		Calls += 1
		Header := Match[1]
		Assert(!RegExMatch(Header, '^\s*"|,\s*"'),
			"pck-08: a list view header is a literal string, not a t() key: [" . Header . "]")
		Pos += Match.Len
	}
	Assert(Calls >= 1, "pck-08: the application picker's list view must still be found")
}
Test("list views: column headers come from t() (pck-08)", _LVHL_HeadersComeFromI18n)
