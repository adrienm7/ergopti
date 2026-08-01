; tests/meta/test_isrepeat_section_name_mismatch_latent_divergence.ahk

; ==============================================================================
; MODULE: Cache IsRepeat / TOML-Fallback Parity Meta Test
; DESCRIPTION:
; Static source guard for finding isrepeat-section-name-mismatch-latent-divergence.
;
; The cache build (_HotstringsCacheBuildRows) used to compute IsRepeat from a
; section literal "repeatcorrections" (no underscore) - but the real header is
; [[repeat_corrections]] (a casualty of the snake_case rename), so the predicate
; NEVER fired. Worse, the runtime TOML fallback (LoadHotstringsSection) does not
; set IsRepeat at all, so the cache and the fallback had structurally different
; IsRepeat logic: a plausible future TOML edit would silently activate a
; fast-boot-vs-fallback behavioural divergence.
;
; The fix removes the per-row predicate and stores IsRepeat false unconditionally
; in the cache, matching the fallback (repeat is owned by the engine-level
; HSE_TryRepeatKey). This test pins three invariants so the divergence cannot
; come back:
;   1. The cache must NOT carry the broken no-underscore "repeatcorrections"
;      predicate (it must be gone, not silently dead).
;   2. The cache build must store IsRepeat false unconditionally.
;   3. The TOML fallback LoadHotstringsSection must NOT set an IsRepeat option -
;      so both paths agree at false.
; Plus: the real magic-key section header is [[repeat_corrections]] (underscore),
; proving the old literal could never have matched.
;
; Meta-static (scans source text): asserting these by execution would require
; registering hotstrings through the live engine, which the headless runner
; cannot do for the divergence-of-two-paths claim. The source text is the
; contract here.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_ISRMM_ReadWindowsSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Reads a _shared/-relative source file (the TOML tree lives beside windows/).
_ISRMM_ReadSharedSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)   ; ...\windows
	SplitPath(WindowsDir, , &DriversDir)    ; ...\ergopti_plus
	Path := StrReplace(DriversDir, "\", "/") . "/_shared/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Parity assertions =====================
; ==================================================
; ==================================================

_ISRMM_CacheDropsBrokenPredicate() {
	Src := _ISRMM_ReadWindowsSource("infra/hotstrings/hotstrings_cache.ahk")
	Body := _DriverFuncBody("_HotstringsCacheBuildRows")
	Assert(Body != "", "_HotstringsCacheBuildRows must exist in hotstrings_cache.ahk")
	; The broken no-underscore section literal predicate must be gone (not dead).
	Assert(InStr(Body, Chr(34) . "repeatcorrections" . Chr(34)) == 0,
		"cache build must NOT test the broken no-underscore literal 'repeatcorrections' - the real header is [[repeat_corrections]]; it never matched and diverged from the TOML fallback")
	; IsRepeat must be stored false unconditionally so the cache matches the
	; TOML fallback (which never sets IsRepeat).
	Assert(InStr(Body, "IsRepeat := false") > 0,
		"cache build must store IsRepeat false unconditionally to match the TOML fallback's IsRepeat logic")
}
Test("hotstrings cache: build drops the broken IsRepeat predicate (isrepeat-section-name-mismatch-latent-divergence)", _ISRMM_CacheDropsBrokenPredicate)

_ISRMM_TomlFallbackOmitsIsRepeat() {
	Src := _ISRMM_ReadWindowsSource("infra/toml/toml_loader.ahk")
	Body := _DriverFuncBody("LoadHotstringsSection")
	Assert(Body != "", "LoadHotstringsSection must exist in toml_loader.ahk")
	; The fallback must NOT set an IsRepeat option - that is the canonical behaviour
	; the cache now matches. If a future edit adds IsRepeat here it must also add
	; byte-identical logic to the cache (and this guard's intent must be revisited).
	Assert(InStr(Body, "IsRepeat") == 0,
		"LoadHotstringsSection (TOML fallback) must not set IsRepeat - repeat is owned by the engine-level fallback; the cache matches this by storing false")
}
Test("toml loader: LoadHotstringsSection omits IsRepeat, matching the cache (isrepeat-section-name-mismatch-latent-divergence)", _ISRMM_TomlFallbackOmitsIsRepeat)

_ISRMM_RealHeaderHasUnderscore() {
	Toml := _ISRMM_ReadSharedSource("modules/hotstrings/magickey.toml")
	; The real section header carries the underscore the old cache literal lacked.
	Assert(InStr(Toml, "[[repeat_corrections]]") > 0,
		"magickey.toml must declare the [[repeat_corrections]] header - proving the old 'repeatcorrections' literal could never have matched")
}
Test("magickey toml: repeat_corrections header exists with the underscore (isrepeat-section-name-mismatch-latent-divergence)", _ISRMM_RealHeaderHasUnderscore)
