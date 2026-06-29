; tests/meta/test_personal_hotstring_seed.ahk

; ==============================================================================
; MODULE: Personal-Hotstring Section Seeding Meta Test
; DESCRIPTION:
; Static source guard for finding personal-hotstring-seed (F-M11).
;
; A user-defined personal_hotstrings.toml section beyond the manifest's fixed 5
; (autocorrection/code/email_shortcuts/professional_vocabulary/test) was never
; seeded into Features["hotstrings"]["personal"], so: the bulk "Tout activer"
; toggle silently no-op'd on it (WriteFeatureBatchV2's FeatureLocateV2 returned
; false), and its hotstrings never registered (the loader iterates the Map, not the
; file). The fix adds EnsurePersonalHotstringFeature (seeding a default-disabled Map
; node mirroring the manifest shape) and runs a seeding pass over
; ReadPersonalToml().sections_order BEFORE ApplyConfigToml — so a persisted custom-
; section toggle is accepted and the section loads + honours its tray toggle.
;
; Source-scan: asserts the helper seeds a Map and the startup seeding precedes
; ApplyConfigToml.
; ==============================================================================

#Requires AutoHotkey v2.0


_PHS_AssertSeedingWired() {
	SplitPath(A_ScriptDir, , &Root)   ; A_ScriptDir = windows/tests -> Root = windows
	Root := StrReplace(Root, "\", "/")
	; Scan the whole driver source for the seeding helper (move-resilient); the
	; ErgoptiPlus.ahk entrypoint read below stays pinned (the entrypoint never moves).
	pf := _DriverSourceConcat()
	Assert(InStr(pf, "EnsurePersonalHotstringFeature(SecName)") > 0,
		"EnsurePersonalHotstringFeature must exist to seed custom personal hotstring sections (personal-hotstring-seed)")
	Assert(InStr(pf, '["hotstrings"]["personal"][SecName] := Map(') > 0,
		"EnsurePersonalHotstringFeature must seed a Map node (not a bool) mirroring the manifest shape (personal-hotstring-seed)")

	ep := FileRead(Root . "/ErgoptiPlus.ahk")
	seedPos  := InStr(ep, "EnsurePersonalHotstringFeature")
	applyPos := InStr(ep, "ApplyConfigToml(Features")
	Assert(seedPos > 0,
		"ErgoptiPlus.ahk must seed file-discovered personal hotstring sections at startup (personal-hotstring-seed)")
	Assert(applyPos > 0 and seedPos < applyPos,
		"the personal-section seeding must run BEFORE ApplyConfigToml so a persisted custom-section toggle is accepted, not rejected as an unknown path (personal-hotstring-seed)")
}
Test("config: custom personal hotstring sections are seeded before ApplyConfigToml (personal-hotstring-seed)", _PHS_AssertSeedingWired)
