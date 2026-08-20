; tests/meta/test_onboarding_toml_bool_reads.ahk

; ==============================================================================
; MODULE: Regression — the wizard must read TOML booleans as booleans
; DESCRIPTION:
; ParseTomlFile runs every value through TOML_CoerceValue, which turns the TOML
; literal `true` into a real AHK boolean. IniCacheGet then returns that value
; VERBATIM — unlike its sibling TOML_Read, it performs no coercion of its own.
;
; ROOT CAUSE ENCODED:
; _Onboarding_PreloadFromExistingConfig compared `StrLower(value) == "true"`.
; StrLower of the boolean yields the string "1", which never equals "true", so
; the comparison was a legal, non-throwing, ALWAYS-FALSE expression. Every
; saved `true` pre-filled the wizard as No — and because the presence guards
; (`!= "_"`) still passed, the assignment ran and the wizard then wrote that
; `false` back over the user's config on Finish. A user re-running the wizard
; over a working install had their entire Ergopti emulation silently disabled.
;
; The bug is strictly one-directional: TOML `false` coerces to 0, which also
; compares false, so it was correct by accident and never showed up as a
; spurious enable — which is precisely why it survived unnoticed.
;
; The file's own comment asserted the opposite contract ("ParseTomlFile
; preserves TOML's literal 'true'/'false' strings"), and the WebView2 host
; already had the correct helper. This is the documented
; `project-ahk-invariant-incomplete-application` shape: one sibling missed.
;
; SCOPE: behavioural (real ParseTomlFile round-trip) + source introspection.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ What the cache actually hands back =======
; =====================================================
; =====================================================

; Behavioural: this is the fact the wizard got wrong, proved end to end
; against the real parser rather than a hand-built Map. tests/unit/test_config
; builds its cache from string literals, which is exactly why it never caught
; this — it never observes what TOML_CoerceValue really produces.
_OTB_CacheReturnsRealBooleans() {
	Path := A_Temp . "\ergopti_test_onb_bool.toml"
	try FileDelete(Path)
	FileAppend("[layout]`nergopti_base = true`nergopti_plus = false`n", Path, "UTF-8")

	Cache := ParseTomlFile(Path)
	OnValue := IniCacheGet(Cache, "layout", "ergopti_base")
	OffValue := IniCacheGet(Cache, "layout", "ergopti_plus")
	try FileDelete(Path)

	Assert(StrLower(OnValue) != "true",
		"a TOML `true` must NOT be readable as the string 'true' through IniCacheGet — if this ever starts passing the parser changed, and the wizard's old comparison would look correct again")
	Assert(TomlCacheBool(Cache, "layout", "ergopti_base"),
		"TomlCacheBool must read a TOML `true` as true — this is the comparison the wizard needs")
	Assert(!TomlCacheBool(Cache, "layout", "ergopti_plus"),
		"TomlCacheBool must read a TOML `false` as false")
	Assert(!TomlCacheBool(Cache, "layout", "absent_key"),
		"a missing key must read as false, not as the '_' sentinel leaking through")
}

; The shared helper must also accept what a hand-edited or legacy config holds:
; TOML has no 1/0 booleans, but the driver's own writers have emitted both, and
; the WebView2 helper already tolerated them.
_OTB_HelperAcceptsLegacyShapes() {
	Cache := Map("s", Map("a", true, "b", 1, "c", "true", "d", "TRUE",
		"e", false, "f", 0, "g", "false", "h", ""))
	for Key in ["a", "b", "c", "d"]
		Assert(TomlCacheBool(Cache, "s", Key), "'" . Key . "' must read as true")
	for Key in ["e", "f", "g", "h"]
		Assert(!TomlCacheBool(Cache, "s", Key), "'" . Key . "' must read as false")
}





; =======================================================
; =======================================================
; ======= 2/ Both wizard hosts use the one helper =======
; =======================================================
; =======================================================

; Policed as a CLASS, not as one pinned site: the defect was a missing sibling,
; so the guard has to fail on the NEXT sibling too.
_OTB_NoHostReimplementsTheBoolTest() {
	Src := _DriverDirConcat("ui/onboarding")
	Assert(Src != "", "the onboarding source must be readable")
	Assert(InStr(Src, 'StrLower(') == 0 or InStr(Src, '== "true"') == 0,
		'no onboarding host may test a TOML boolean with StrLower(x) == "true" — IniCacheGet returns a real boolean, so that comparison is always false; use TomlCacheBool')
	Assert(InStr(Src, "TomlCacheBool(") > 0,
		"the onboarding hosts must read TOML booleans through the shared TomlCacheBool helper")
}

; §5.2: the helper must exist in exactly one place.
_OTB_HelperHasASingleDefinition() {
	Body := _DriverFuncBody("TomlCacheBool")
	Assert(Body != "", "TomlCacheBool() must exist in the shared TOML layer")

	Src := _DriverSourceNoComments()
	Count := 0
	Pos := 1
	while (Pos := InStr(Src, "TomlCacheBool(", false, Pos)) {
		if (SubStr(Src, Pos - 1, 1) != "_" and RegExMatch(SubStr(Src, Pos - 40, 40), "\n\s*$"))
			Count += 1
		Pos += 1
	}
	Assert(Count <= 1,
		"TomlCacheBool must be DEFINED once (found " . Count . " definition(s)) — a second copy is how the first one drifted out of sync with its sibling")
}


Test("meta onboarding: the TOML cache hands back real booleans", _OTB_CacheReturnsRealBooleans)
Test("meta onboarding: the shared bool helper accepts every stored shape", _OTB_HelperAcceptsLegacyShapes)
Test("meta onboarding: no host reimplements the TOML bool test", _OTB_NoHostReimplementsTheBoolTest)
Test("meta onboarding: the bool helper has a single definition", _OTB_HelperHasASingleDefinition)
