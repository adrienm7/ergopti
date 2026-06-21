; tests/meta/test_format_toml_stale_path_deadcode.ahk

; ==============================================================================
; MODULE: Stale TOML-Formatter Path Dead-Code Meta Test
; DESCRIPTION:
; Static source guard for finding format-toml-stale-path-deadcode.
;
; TOML_FormatViaScript and the two personal_toml_editor formatters derived a
; repo root by stripping "\static\drivers\autohotkey" and pointed RunWait at
; "tools\format_toml.py". That layout no longer exists (the driver lives under
; static\ergopti_plus\windows and the formatter at tools\dev\format_toml.py),
; so FileExist always failed and the RunWait never fired - dead code that also
; lied (comments promised reformatting that never happened). Worse, "fixing"
; only the path would have re-armed a synchronous blocking python RunWait on
; the SaveFullConfig hot path (boot timer + every menu toggle).
;
; The fix removes the dead formatter blocks entirely (rule 5.6). This
; meta-static test asserts the stale layout tokens are gone from all three
; source files and that the dead TOML_FormatViaScript helper no longer exists,
; so neither the dead code nor the latent blocking RunWait can return.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Stale-token absence assertions ========
; ==================================================
; ==================================================

_FTSP_NoStalePathTokens() {
	; Build the stale tokens at runtime so this test file itself does not
	; contain the literal it forbids (which would make the grep self-trip).
	StaleLayout := "static" . "\drivers\autohotkey"
	StaleScript := "tools" . "\format_toml.py"

	; Move-resilient AND strengthened: scan the WHOLE driver source (tests/ tree
	; excluded by the helper) instead of two pinned paths. These stale tokens
	; must be absent everywhere, so a whole-tree scan catches a reappearance in
	; any file, not just the two the fix originally touched.
	Src := _DriverSourceConcat()
	Files := ["lib/toml/toml_helpers.ahk", "ui/personal_toml_editor.ahk"]
	for _, Rel in Files {
		Assert(InStr(Src, StaleLayout) = 0,
			Rel . " must not reference the stale '" . StaleLayout . "' layout - the driver lives under static/ergopti_plus/windows")
		Assert(InStr(Src, StaleScript) = 0,
			Rel . " must not reference the stale '" . StaleScript . "' path - the formatter lives at tools/dev/format_toml.py")
	}
}
Test("toml_helpers: no stale drivers/autohotkey + tools/format_toml.py tokens (format-toml-stale-path-deadcode)", _FTSP_NoStalePathTokens)

_FTSP_DeadFormatterRemoved() {
	; The dead synchronous formatter helper must be gone so it cannot be
	; revived into a blocking RunWait on the SaveFullConfig save path. Whole-tree
	; scan strengthens this: the removed helper must not resurface anywhere.
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "TOML_FormatViaScript") = 0,
		"TOML_FormatViaScript must be removed - it never ran (stale path) and reviving it would block SaveFullConfig with a synchronous python RunWait")
}
Test("toml_helpers: dead TOML_FormatViaScript formatter removed (format-toml-stale-path-deadcode)", _FTSP_DeadFormatterRemoved)
