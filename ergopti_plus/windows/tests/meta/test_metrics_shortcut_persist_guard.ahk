; tests/meta/test_metrics_shortcut_persist_guard.ahk

; ==============================================================================
; MODULE: Metrics Preference Persistence Guard
; DESCRIPTION:
; Retirement removes only dedicated bindings. The remaining consent and color
; preferences still build under the configuration lease and publish only after
; acknowledged persistence.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSPG_PreferenceRetainsLeasePublication() {
	Body := _DriverFuncBody("MS_SaveBuiltToIni")
	Assert(Body != "", "the retained Metrics persistence owner must exist")
	AssertContains(Body, "CS_SaveBuilt(", "the owner must retain leased plan construction")
	AssertContains(Body, "Committed is Integer", "native persistence requires a typed acknowledgement")
	AssertContains(Body, "Committed == 1", "truthy refusal must never publish consent")
	Builder := _DriverFuncBody("_MS_BuildPreferencePlan")
	Assert(Builder != "", "the retained Metrics plan builder must exist")
	AssertContains(Builder, "throw ValueError(", "unknown preference mutations must refuse")
	AssertContains(Builder, "publish: _MS_PublishPreferenceCandidate.Bind(", "live state is a post-write publication")
}
Test("metrics: retirement preserves the preference lease and exact acknowledgement", _MSPG_PreferenceRetainsLeasePublication)
