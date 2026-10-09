; tests/unit/test_config_toml_single_writer.ahk

; ==============================================================================
; MODULE: Regression — config.toml must have exactly ONE writer
; DESCRIPTION:
; infra/config_shortcuts.ahk used to carry a second, section-splicing writer for
; config.toml (CS_WriteShortcutsSection + its CS_ReplaceSection /
; CS_RenderSection / CS_RenderValue / CS_Join helpers), reached from CS_Save
; whenever the canonical writer was not yet armed.
;
; ROOT CAUSE ENCODED:
; That writer seeded its rewrite from a BARE `try FileRead(path)`. A read that
; failed left the body empty, the section merge short-circuited to the rendered
; [metrics] block alone, and the atomic FileMove then replaced the user's
; ENTIRE configuration with that single section. Nothing was logged: the only
; catch in the function covered the write, so a failed read followed by a
; successful write was completely signal-free. The shipped guard for the
; unreadable-config hardening pass was scoped to CS_Read's body, so this sibling
; FileRead of the SAME file, in the SAME module, was structurally invisible to
; it.
;
; The fix deletes the second writer outright: config.toml is written only by
; SaveFullConfig -> TOML_BatchWrite, which writes atomically, preserves every
; section it does not re-collect, and refuses to rebuild a file it could not
; read. This test pins that there is no way back — both that the splicer is
; gone and that nothing still CALLS it (a call left behind after the helpers
; were removed is a load-time "call to nonexistent function", i.e. a driver
; that does not start at all).
;
; SCOPE: source introspection. infra/config_shortcuts.ahk registers no hotkeys but
; its writer path is only reachable pre-boot, which the headless harness cannot
; reproduce, so the guarantee is asserted against the driver source.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ CS_Save delegates instead of writing =========
; =========================================================
; =========================================================

_CTSW_SaveDelegatesToTheCanonicalWriter() {
	Body := _DriverFuncBody("CS_Save")
	Assert(Body != "", "CS_Save() must exist in the driver source")
	Assert(InStr(Body, "SaveFullConfig") > 0,
		"CS_Save must delegate to SaveFullConfig, the single canonical writer for config.toml — it is the only path with an atomic write and a read-failure refusal")
	Assert(RegExMatch(Body, "FileMove|FileAppend|FileDelete|FileOpen") == 0,
		"CS_Save must not touch config.toml itself: a second writer for this file is what allowed one unreadable read to replace the user's whole configuration with a single rendered section")
}


; Every helper of the deleted splicer must be gone AND uncalled. The second
; assertion is the one that matters most in practice: AHK v2 resolves function
; names at load time, so a surviving call to a removed helper is not a latent
; bug — it aborts the whole driver before the first hotkey is registered.
_CTSW_NoSecondSectionSplicingWriter() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	; Positive control: without it every absence assertion below would pass on
	; an empty or wrongly-scoped source.
	Assert(InStr(Src, "CS_Save") > 0,
		"the scanned driver source must actually contain the config-shortcuts module")

	for Name in ["CS_WriteShortcutsSection", "CS_ReplaceSection", "CS_RenderSection", "CS_RenderValue", "CS_Join"] {
		Assert(_DriverFuncBodyOrEmpty(Name) == "",
			Name . " must not be reintroduced — config.toml has exactly one writer, and a section splicer seeded from a bare-try FileRead cannot tell an unreadable file from an empty one")
		Assert(InStr(Src, Name) == 0,
			Name . " must not appear anywhere in the driver source: a call left behind after the helper was deleted is a load-time 'call to nonexistent function' and the driver never starts")
	}
}


Test("config.toml: CS_Save delegates to the single canonical writer",
	_CTSW_SaveDelegatesToTheCanonicalWriter)
Test("config.toml: no second section-splicing writer exists or is called",
	_CTSW_NoSecondSectionSplicingWriter)
