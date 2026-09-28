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
	Builder := _StripFullLineComments(_DriverFuncBody("_ConfigBuildCategoryIntentPlan"))
	Collector := _StripFullLineComments(_DriverFuncBody("_ConfigCollectFullSaveUpdates"))
	Assert(Builder != "" && Collector != "", "both category persistence producers must exist")
	Assert(InStr(Builder, '_ConfigSparseOperation("category_enabled",') > 0,
		"category writes use the canonical sparse baseline before typed serialization")
	Assert(RegExMatch(Collector, 'Section:\s*"category_enabled"[^\r\n]+Value:\s*TOML_Bool\(') > 0,
		"full-save category values retain Boolean intent until sparse normalization")
	for Name in ["ToggleAllHotstrings", "ToggleCategoryAllSections", "HS_TogglePersonalAllSections"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "" && InStr(Body, "_ConfigCommitHotstringIntent(") > 0,
			"section selection must use its independent transaction: " . Name)
	}
	Sections := _DriverFuncBody("_ConfigBuildHotstringIntentPlan")
	Assert(Sections != "" && InStr(Sections, '"category_enabled"') == 0,
		"selecting children must not write their master gates")
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
