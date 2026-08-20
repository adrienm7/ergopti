; tests/meta/test_config_shortcuts_inline_comment.ahk

; ==============================================================================
; MODULE: config_shortcuts inline-comment strip guard
; DESCRIPTION:
; CS_Read/CS_CoerceValue hand-roll a mini TOML parser over the AHK config file.
; It skipped only whole-line '#' comments, never inline ones, so a hand-edited
; line like `metrics_enabled = false # off for privacy` kept the whole
; "false # off..." string; CS_CoerceValue fell through to its bare-string
; fallback, the boolean consumer treated the non-empty string as truthy, and the
; keylogger started -- then SaveFullConfig persisted the inversion. The fix strips
; a trailing inline comment that sits OUTSIDE a quoted string before coercion.
; config_shortcuts.ahk is not part of the headless run_all include graph, so this
; is a source-scan (via _DriverSourceConcat's file sweep). (F04, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_CSIC_InlineCommentStrippedQuoteAware() {
	Helper := _DriverFuncBody("CS_StripInlineComment")
	Coerce := _DriverFuncBody("CS_CoerceValue")
	Assert(Helper != "", "CS_StripInlineComment must exist in infra/config_shortcuts.ahk")
	Assert(Coerce != "", "CS_CoerceValue must exist in infra/config_shortcuts.ahk")

	; Quote-aware: the strip must track quoted-string state from the raw stream and
	; only cut a '#' when NOT inside a quoted string, so a '#' in a quoted value stays.
	Q := Chr(34)
	Assert(InStr(Helper, "in_str") > 0,
		"CS_StripInlineComment must track quoted-string state (in_str) so a '#' inside quotes is preserved")
	Assert(InStr(Helper, "!in_str") > 0 && InStr(Helper, "c = " . Q . "#" . Q) > 0,
		"CS_StripInlineComment must cut on a '#' only when NOT inside a quoted string")

	; The comment strip must run BEFORE the type checks so an inline comment can
	; never invert a boolean or hide an array's trailing bracket.
	StripPos := InStr(Coerce, "CS_StripInlineComment(")
	BoolPos := InStr(Coerce, "StrLower(raw) = " . Q . "true" . Q)
	Assert(StripPos > 0,
		"CS_CoerceValue must strip inline comments (an inline TOML comment must never invert a boolean)")
	Assert(BoolPos > 0 && StripPos < BoolPos,
		"the inline-comment strip must run before the boolean/array/integer coercion checks")
}
Test("config_shortcuts: inline TOML comment stripped quote-aware before coercion (no bool inversion)",
	_CSIC_InlineCommentStrippedQuoteAware)
