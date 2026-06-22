; tests/meta/test_wrap_symbols_gate.ahk

; ==============================================================================
; MODULE: Wrap-Symbols Gate Regression Test
; DESCRIPTION:
; Guards the fix for the bug where typing a wrap symbol that was disabled from
; the tray menu (e.g. "@") still wrapped the current text selection.
;
; ROOT CAUSE ENCODED:
; On the Ergopti layout a wrap symbol such as "@" is produced by an AltGr layer
; key (SC011) bound to WrapTextIfSelected (modules/keymap/layout.ahk) - a code path
; entirely SEPARATE from the PrefixWatcher's _OnPrefixChar handler. The original
; WrapTextIfSelected gated only on the master "wrap_text_if_selected" feature
; flag and never consulted the per-symbol disabled set, so a symbol the user had
; switched off in the menu kept wrapping the selection regardless.
;
; The fix makes WrapTextIfSelected gate on WrapSymbols_IsEnabled (the canonical
; per-symbol state). This test reads the function body and fails if that gate is
; ever dropped, so the disabled-symbol bug can never silently return.
; ==============================================================================

#Requires AutoHotkey v2.0

; Read the WrapTextIfSelected definition out of modules/keymap/layout.ahk and assert it
; consults the per-symbol enable/disable state before wrapping. A bare mention
; elsewhere in the file must not satisfy the check, so the assertion runs against
; a window scoped to the function body only.
_MetaWrapSymbolsGateBody() {
	; Move-resilient: extract WrapTextIfSelected()'s body by name via the framework
	; helper instead of a pinned modules/keymap/layout.ahk read. The helper anchors on the
	; DEFINITION and scopes to the function body, so a bare mention elsewhere in the
	; file cannot satisfy the gate check.
	Snippet := _DriverFuncBody("WrapTextIfSelected")
	AssertTrue(Snippet != "",
		"WrapTextIfSelected(Symbol, ...) definition not found in modules/keymap/layout.ahk")
	AssertContains(Snippet, "WrapSymbols_IsEnabled",
		"WrapTextIfSelected must gate on WrapSymbols_IsEnabled so menu-disabled "
		. "symbols (e.g. '@') do not wrap the selection")
}

_MetaRunWrapSymbolsGateTests() {
	Test("meta wrap-symbols gate: WrapTextIfSelected honours per-symbol disabled state",
		_MetaWrapSymbolsGateBody)
}

_MetaRunWrapSymbolsGateTests()
