; tests/meta/test_tint_test_stale_constants_comment.ahk

; ==============================================================================
; MODULE: Tint Contract Comment-vs-Seed Consistency Meta Test
; DESCRIPTION:
; Static source guard for the tint-test-stale-constants-comment finding.
;
; tests/unit/test_tooltip_tint_contract.ahk seeds UI_TINT_LIGHTNESS /
; UI_TINT_SATURATION to the canonical constants.toml [tint] defaults
; (lightness=0.13 / saturation=0.85) before computing the expected tint
; vectors. Its header comment documents the parameters a maintainer must use
; to regenerate those vectors. Previously the comment claimed the vectors were
; generated at 0.10 / 0.40 while the seed used 0.13 / 0.85 — a maintainer
; following the comment would produce mismatching vectors and waste time or
; mask a real cross-driver tint drift.
;
; This meta-static test asserts that the lightness/saturation values seeded in
; the test match the values its own header comment references, and that both
; agree with constants.toml, so the documentation can never silently drift
; from the seed again.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root, so a tests/-rooted path is reached
; with RelPath = "tests/...".
_TTSCC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Comment-vs-seed assertions ============
; ==================================================
; ==================================================

_TTSCC_SeedMatchesComment() {
	Src := _TTSCC_ReadSource("tests/unit/test_tooltip_tint_contract.ahk")

	; The seed is the single source of truth the actual vectors are computed
	; against; assert it still uses the canonical constants.toml [tint] values.
	Assert(InStr(Src, "UI_TINT_LIGHTNESS := 0.13") > 0,
		"tint contract test must seed UI_TINT_LIGHTNESS := 0.13 (canonical constants.toml [tint] lightness)")
	Assert(InStr(Src, "UI_TINT_SATURATION := 0.85") > 0,
		"tint contract test must seed UI_TINT_SATURATION := 0.85 (canonical constants.toml [tint] saturation)")

	; The regeneration comment must reference the SAME values as the seed,
	; otherwise a maintainer regenerates vectors at the wrong parameters.
	Assert(InStr(Src, "lightness=0.13 / saturation=0.85") > 0,
		"tint contract test header comment must reference lightness=0.13 / saturation=0.85 to match the seeded values")

	; The stale 0.10 / 0.40 parameters must be gone from the comment entirely.
	Assert(InStr(Src, "0.10") = 0,
		"tint contract test must not reference the stale lightness 0.10 in its regeneration comment")
	Assert(InStr(Src, "0.40") = 0,
		"tint contract test must not reference the stale saturation 0.40 in its regeneration comment")
}
Test("tooltip tint: regeneration comment matches seeded constants (tint-test-stale-constants-comment)", _TTSCC_SeedMatchesComment)
