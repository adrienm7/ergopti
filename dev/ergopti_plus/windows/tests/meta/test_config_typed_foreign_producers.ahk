; tests/meta/test_config_typed_foreign_producers.ahk

; ==============================================================================
; MODULE: Foreign Configuration Boolean Producer Guards
; DESCRIPTION:
; Foreign category gates and the onboarding gesture marker have no manifest
; type. Their producers must explicitly retain Boolean intent. These guards
; cover live-engine and onboarding UI paths without invoking their side effects;
; unit tests separately prove sentinel rendering and real gesture persistence.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Foreign Type Ownership =======
; =========================================
; =========================================

_CTFP_CategoryProducersRetainBooleanIntent() {
	for Name in ["ToggleAllFeatures", "ToggleAllHotstrings", "ToggleCategoryAllFeatures",
		"ToggleCategoryAllSections", "HS_TogglePersonalAllSections", "_ConfigCollectFullSaveUpdates"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", "category producer must exist: " . Name)
		Position := 1
		Count := 0
		while Position := RegExMatch(Body, 'Section:\s*"category_enabled"[^\r\n]+', &Record, Position) {
			Count += 1
			AssertTrue(RegExMatch(Record[0], 'Value:\s*TOML_Bool\('),
				"foreign category Boolean intent must be explicit in " . Name)
			Position += StrLen(Record[0])
		}
		AssertTrue(Count > 0, "the producer's category updates must be inspected: " . Name)
	}
}
Test("config: every category producer retains foreign Boolean intent "
	. "(config-typed-foreign-categories)", _CTFP_CategoryProducersRetainBooleanIntent)

_CTFP_OnboardingMarkerRetainsBooleanIntent() {
	Body := _StripFullLineComments(_DriverFuncBody("_Onboarding_Commit"))
	Assert(Body != "", "the onboarding producer must exist")
	AssertTrue(RegExMatch(Body,
		'Key:\s*"auto_configure_on_next_start",\s*Value:\s*TOML_Bool\(true\)'),
		"the subsystem-owned onboarding marker is not covered by manifest typing")
}
Test("config: onboarding gives its foreign gesture marker explicit Boolean intent "
	. "(config-typed-foreign-onboarding)", _CTFP_OnboardingMarkerRetainsBooleanIntent)
