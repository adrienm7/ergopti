; tests/meta/test_tap_hold_writer_inherit_defaults.ahk

; ==============================================================================
; MODULE: Tap-Hold Writer inherit_defaults Persistence Meta Test
; DESCRIPTION:
; Regression guard ensuring _TH_WriteTapHoldToml emits inherit_defaults = false
; when TapHold["inherit_defaults"] is false.
;
; The bug: _TH_WriteTapHoldToml rewrote tap_hold.toml from the in-memory
; TapHold map but never emitted the [tap_hold] WindowsDir section with
; inherit_defaults = false.  When the user disabled all tap-holds via the tray
; menu, _TH_WriteTapHoldDisabled wrote inherit_defaults = false once, but any
; subsequent individual key change via _TH_WriteTapHoldToml wiped that line.
; On the next reload, tap_hold_loader.ahk saw no inherit_defaults key and
; defaulted to true, re-merging the shipped defaults — undoing the user's
; "disable all" intent even though no defaults key existed in the file.
;
; The fix: emit `[tap_hold]\ninherit_defaults = false` at the top of the file
; whenever TapHold["inherit_defaults"] is false so every rewrite preserves the
; flag.
;
; SCOPE: source introspection of lib/tap_hold/tap_hold_writer.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_TWHID_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_TWHID_CheckWriterEmitsInheritDefaults() {
	Src := _TWHID_ReadSource("lib/tap_hold/tap_hold_writer.ahk")
	Assert(Src != "", "lib/tap_hold/tap_hold_writer.ahk must be readable")

	Body := _DriverFuncBody("_TH_WriteTapHoldToml")
	Assert(Body != "", "_TH_WriteTapHoldToml must be present in tap_hold_writer.ahk")

	Assert(InStr(Body, "inherit_defaults"),
		"_TH_WriteTapHoldToml must emit inherit_defaults when TapHold['inherit_defaults'] is false")
}

_TWHID_CheckWriterEmitsRootSection() {
	Src := _TWHID_ReadSource("lib/tap_hold/tap_hold_writer.ahk")
	Assert(Src != "", "lib/tap_hold/tap_hold_writer.ahk must be readable")

	Body := _DriverFuncBody("_TH_WriteTapHoldToml")
	Assert(Body != "", "_TH_WriteTapHoldToml must be present in tap_hold_writer.ahk")

	; Must emit a [tap_hold] WindowsDir section (the header for the flag)
	Assert(InStr(Body, '"[tap_hold]"'),
		"_TH_WriteTapHoldToml must emit the [tap_hold] WindowsDir section when inherit_defaults is false")
}

_TWHID_CheckLoaderReadsInheritDefaults() {
	Src := _TWHID_ReadSource("lib/tap_hold/tap_hold_loader.ahk")
	Assert(Src != "", "lib/tap_hold/tap_hold_loader.ahk must be readable")

	Assert(InStr(Src, "inherit_defaults"),
		"tap_hold_loader.ahk must read and respect the inherit_defaults key from the TOML file")
}


Test("meta tap-hold-writer: _TH_WriteTapHoldToml emits inherit_defaults when false",
	_TWHID_CheckWriterEmitsInheritDefaults)

Test("meta tap-hold-writer: _TH_WriteTapHoldToml emits [tap_hold] WindowsDir section for inherit_defaults",
	_TWHID_CheckWriterEmitsRootSection)

Test("meta tap-hold-writer: tap_hold_loader reads inherit_defaults to skip default merging",
	_TWHID_CheckLoaderReadsInheritDefaults)
