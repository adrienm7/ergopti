; tests/meta/test_hse_register_atomic.ahk

; ==============================================================================
; MODULE: HSE Register Atomic Meta Test
; DESCRIPTION:
; Static source guard for the hse-register-torn-read-vs-onchar finding.
;
; HSE_Register() must wrap the multiple index mutations in a Critical section
; so that the OnChar reader thread (which runs HSE_FindMatchAtEnd) always sees
; a consistent state. Without this, a star trigger could be partially
; registered (e.g. in the bucket but not the by-trigger map), causing it
; to be invisible to matches until the next registration completes.
;
; The fix adds a Critical("On") / restore block around the live-index updates.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_HRA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Atomicity assertion ====================
; ===================================================
; ===================================================

_HRA_RegisterIsAtomic() {
	Src := _HRA_ReadSource("lib/hotstrings/hotstring_engine_main.ahk")
	Body := _DriverFuncBody("HSE_Register")
	Assert(Body != "", "HSE_Register must exist in hotstring_engine_main.ahk")
	
	; Verify that Critical("On") appears before the index pushes.
	CritPos := InStr(Body, 'Critical("On")')
	PushPos := InStr(Body, 'HSE_RegistryByLastChar[LookupKey].Push')
	
	Assert(CritPos > 0, "HSE_Register must use Critical to ensure atomic index updates")
	Assert(CritPos < PushPos, "Critical must be enabled BEFORE the first index mutation in HSE_Register")
	
	; Verify that the Star-spec updates are also covered.
	StarPushPos := InStr(Body, "HSE_StarSpecs.Push(Spec)")
	Assert(CritPos < StarPushPos, "Critical must cover the star-spec index updates in HSE_Register")
}
Test("hotstring_engine: HSE_Register uses Critical for atomic index updates (hse-register-torn-read-vs-onchar)", _HRA_RegisterIsAtomic)
