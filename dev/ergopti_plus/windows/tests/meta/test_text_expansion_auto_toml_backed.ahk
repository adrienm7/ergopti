; tests/meta/test_text_expansion_auto_toml_backed.ahk

; ==============================================================================
; MODULE: text_expansion_auto TOML-Backing Meta Test
; DESCRIPTION:
; Static source guard for finding F49 (AUDIT_AHK_2026-07-01.md): the
; hotstrings.magic_key.text_expansion_auto feature is enabled by default in
; manifest.toml but historically had no [[text_expansion_auto]] table in
; magickey.toml, so LoadHotstringsSection silently loaded 0 entries for it -
; a harmless-looking but completely dead toggle, distinguished from the "file
; not found" WARN path only by a DEBUG line nobody watches.
;
; Pins three invariants so the category can never silently go dead again:
;   1. magickey.toml declares a [[text_expansion_auto]] table with at least
;      one real entry.
;   2. [_meta.sections] carries a text_expansion_auto description, so the
;      hotstrings config window shows a real label instead of the raw key.
;   3. The manifest entry (hotstrings.magic_key.text_expansion_auto) still
;      exists - proving the fix authored the missing content rather than
;      silently dropping the feature.
;
; Meta-static (scans TOML source text) rather than executing the loader: the
; fix is about data presence, not runtime behaviour.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a _shared/-relative source file (the TOML tree lives beside windows/).
; Mirrors _ISRMM_ReadSharedSource in
; test_isrepeat_section_name_mismatch_latent_divergence.ahk.
_TEA_ReadSharedSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)   ; ...\windows
	SplitPath(WindowsDir, , &DriversDir)    ; ...\ergopti_plus
	Path := StrReplace(DriversDir, "\", "/") . "/_shared/" . RelPath
	return FileRead(Path, "UTF-8")
}




; ==================================================
; ==================================================
; ======= 2/ Invariant assertions ==================
; ==================================================
; ==================================================

_TEA_SectionTableExists() {
	Toml := _TEA_ReadSharedSource("modules/hotstrings/magickey.toml")
	Assert(InStr(Toml, "[[text_expansion_auto]]") > 0,
		"magickey.toml must declare a [[text_expansion_auto]] table - F49: the category was enabled by default with zero TOML-backed entries")

	HeaderPos := InStr(Toml, "[[text_expansion_auto]]")
	NextTablePos := InStr(Toml, "[[", , HeaderPos + StrLen("[[text_expansion_auto]]"))
	Body := (NextTablePos > 0) ? SubStr(Toml, HeaderPos, NextTablePos - HeaderPos) : SubStr(Toml, HeaderPos)

	EntryCount := 0
	for Line in StrSplit(Body, "`n", "`r") {
		Line := Trim(Line, " `t")
		if RegExMatch(Line, '^"[^"]+"\s*=\s*\{')
			EntryCount++
	}
	Assert(EntryCount >= 1,
		"[[text_expansion_auto]] must carry at least one real entry, not just an empty header")
}
Test("magickey toml: text_expansion_auto table exists with real entries (F49)", _TEA_SectionTableExists)

_TEA_MetaSectionsDescribesIt() {
	Toml := _TEA_ReadSharedSource("modules/hotstrings/magickey.toml")
	MetaPos := InStr(Toml, "[_meta.sections]")
	Assert(MetaPos > 0, "magickey.toml must declare a [_meta.sections] block")
	NextTablePos := InStr(Toml, "[[", , MetaPos)
	Body := (NextTablePos > 0) ? SubStr(Toml, MetaPos, NextTablePos - MetaPos) : SubStr(Toml, MetaPos)
	Assert(RegExMatch(Body, "im)^text_expansion_auto\s*=\s*\{") > 0,
		"[_meta.sections] must describe text_expansion_auto - F49: without it the hotstrings config window falls back to the raw key name")
}
Test("magickey toml: [_meta.sections] describes text_expansion_auto (F49)", _TEA_MetaSectionsDescribesIt)

_TEA_ManifestStillDeclaresFeature() {
	Toml := _TEA_ReadSharedSource("modules/features/manifest.toml")
	Assert(InStr(Toml, 'id = "text_expansion_auto"') > 0,
		"manifest.toml must still declare the text_expansion_auto feature - F49 was fixed by authoring the missing TOML content, not by deleting the toggle")
}
Test("manifest toml: text_expansion_auto feature entry preserved (F49)", _TEA_ManifestStillDeclaresFeature)
