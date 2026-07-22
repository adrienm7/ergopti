; static/ergopti_plus/windows/tests/unit/test_domain_registry.ahk

; ==============================================================================
; MODULE: Registry Domain Contract Tests (AutoHotkey)
; DESCRIPTION:
; AHK translation of the contractTestVectors() scenarios defined in
; static/ergopti_plus/_shared/core/domain/Registry.spec.js. Every vector
; exercises the same logical assertion as the JS spec so the AHK engine
; and the Hammerspoon engine are held to an identical standard.
;
; APPROACH:
; The AHK Registry is implemented by the functions in hotstring_engine_main.ahk
; (HSE_Register / HSE_MappingsForTail / HSE_EnableGroup / HSE_DisableGroup /
; HSE_RegistryClear / HSE_Size). Each test calls HSE_TestReset() to start from
; a clean state, then exercises exactly the steps described in the JS spec.
; ==============================================================================




; ===========================
; ===========================
; ======= 1/ Helpers ========
; ===========================
; ===========================

; Shorthand: register a plain end-char trigger with a group.
_DR_Add(Trigger, Repl, Group := "default", IsWord := false) {
	Flags := IsWord ? "" : "?"
	Meta := Map("group", Group, "Repl", Repl, "Replacement", Repl)
	return HSE_Register(Flags, Trigger, 0, Meta)
}




; ==========================================
; ==========================================
; ======= 2/ add_and_lookup_by_tail ========
; ==========================================
; ==========================================

_DR_AddAndLookupByTail() {
	HSE_TestReset()
	_DR_Add("btw", "by the way")
	Mappings := HSE_MappingsForTail("w")
	Found := false
	for M in Mappings {
		if (M.Trigger == "btw") {
			Found := true
			break
		}
	}
	AssertTrue(Found, "add_and_lookup_by_tail: 'btw' must appear in MappingsForTail('w')")
}
Test("Registry: add('btw') is found by MappingsForTail('w')", _DR_AddAndLookupByTail)




; =========================================
; =========================================
; ======= 3/ longest_match_first ==========
; =========================================
; =========================================

_DR_LongestMatchFirst() {
	HSE_TestReset()
	_DR_Add("btw",  "by the way")
	_DR_Add("btww", "by the way, wow")
	Mappings := HSE_MappingsForTail("w")
	AssertTrue(Mappings.Length >= 2, "longest_match_first: at least 2 mappings expected")
	AssertEqual("btww", Mappings[1].Trigger, "longest_match_first: btww must come first")
}
Test("Registry: longer trigger appears before shorter (MappingsForTail)", _DR_LongestMatchFirst)




; ===========================================
; ===========================================
; ======= 4/ disable_group_removes ==========
; ===========================================
; ===========================================

_DR_DisableGroupRemoves() {
	HSE_TestReset()
	_DR_Add("btw", "by the way", "test_group")
	HSE_DisableGroup("test_group")
	Mappings := HSE_MappingsForTail("w")
	AssertEqual(0, Mappings.Length, "disable_group_removes: no mappings after disableGroup")
}
Test("Registry: disableGroup removes mappings from MappingsForTail", _DR_DisableGroupRemoves)




; =============================================
; =============================================
; ======= 5/ enable_group_restores ============
; =============================================
; =============================================

_DR_EnableGroupRestores() {
	HSE_TestReset()
	_DR_Add("btw", "by the way", "g")
	HSE_DisableGroup("g")
	HSE_EnableGroup("g")
	Mappings := HSE_MappingsForTail("w")
	Found := false
	for M in Mappings {
		if (M.Trigger == "btw") {
			Found := true
			break
		}
	}
	AssertTrue(Found, "enable_group_restores: 'btw' must be back after enableGroup")
}
Test("Registry: enableGroup after disableGroup restores mappings", _DR_EnableGroupRestores)




; ==========================================
; ==========================================
; ======= 6/ clear_empties_registry ========
; ==========================================
; ==========================================

_DR_ClearEmpties() {
	HSE_TestReset()
	_DR_Add("a", "alpha")
	_DR_Add("b", "beta")
	HSE_RegistryClear()
	AssertEqual(0, HSE_Size(), "clear_empties_registry: size() must be 0 after clear()")
}
Test("Registry: clear() results in size() == 0", _DR_ClearEmpties)




; =============================================
; =============================================
; ======= 7/ mapping_fields_populated =========
; =============================================
; =============================================

_DR_MappingFieldsPopulated() {
	HSE_TestReset()
	Flags := ""
	Meta  := Map("group", "g", "Repl", "world", "Replacement", "world")
	M := HSE_Register(Flags, "hello", 0, Meta)
	; Required string fields
	AssertTrue(M.Trigger   is String, "mapping.Trigger must be a string")
	AssertTrue(M.Repl      is String, "mapping.Repl must be a string")
	AssertTrue(M.PlainRepl is String, "mapping.PlainRepl must be a string")
	AssertTrue(M.TailChar  is String, "mapping.TailChar must be a string")
	AssertTrue(M.Group     is String, "mapping.Group must be a string")
	AssertTrue(M.StarBase  is String, "mapping.StarBase must be a string")
	; Required boolean fields
	AssertTrue(M.Auto        = true or M.Auto        = false, "mapping.Auto must be boolean")
	AssertTrue(M.HasMagic    = true or M.HasMagic    = false, "mapping.HasMagic must be boolean")
	AssertTrue(M.FinalResult = true or M.FinalResult = false, "mapping.FinalResult must be boolean")
	; Required numeric fields
	AssertTrue(M.Seq          > 0,  "mapping.Seq must be a positive number")
	AssertTrue(M.TLen         > 0,  "mapping.TLen must be positive")
	AssertTrue(M.TriggerBytes > 0,  "mapping.TriggerBytes must be positive")
	AssertTrue(M.GroupOrder   >= 0, "mapping.GroupOrder must be >= 0")
	; Value checks
	AssertEqual("hello", M.Trigger,  "mapping.Trigger must equal 'hello'")
	AssertEqual("o",     M.TailChar, "mapping.TailChar must be 'o'")
	AssertEqual("g",     M.Group,    "mapping.Group must be 'g'")
	AssertEqual(5,       M.TLen,     "mapping.TLen must be 5")
}
Test("Registry: Mapping object has all required fields with correct types", _DR_MappingFieldsPopulated)




; =====================================
; =====================================
; ======= 8/ size_tracks_active ========
; =====================================
; =====================================

_DR_SizeTracksActive() {
	HSE_TestReset()
	AssertEqual(0, HSE_Size(), "size() must be 0 after reset")
	_DR_Add("aa", "alpha", "g1")
	_DR_Add("bb", "beta",  "g1")
	_DR_Add("cc", "gamma", "g2")
	AssertEqual(3, HSE_Size(), "size() must be 3 after 3 adds")
	HSE_DisableGroup("g1")
	AssertEqual(1, HSE_Size(), "size() must be 1 after disabling g1 (2 mappings)")
	HSE_EnableGroup("g1")
	AssertEqual(3, HSE_Size(), "size() must return to 3 after re-enabling g1")
}
Test("Registry: size() tracks active mapping count across enable/disable", _DR_SizeTracksActive)
