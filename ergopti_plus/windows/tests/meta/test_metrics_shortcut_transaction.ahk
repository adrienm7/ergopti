; tests/meta/test_metrics_shortcut_transaction.ahk

; ==============================================================================
; MODULE: Metrics Dedicated Binding Retirement Guard
; DESCRIPTION:
; Dashboard actions stay in the ordinary catalogue. Neither boot nor full-save
; may resurrect the retired binding keys; collection preferences retain their
; lease-backed publication owner.
; ==============================================================================

#Requires AutoHotkey v2.0

_MST_NoDedicatedBindingOwner() {
	Driver := _DriverSourceNoComments()
	Assert(Driver != "", "the actual boot source must be readable")
	AssertEqual(0, InStr(Driver, "MS_ApplyAll("), "boot must never replay a dedicated dashboard binding")
	Collector := _DriverFuncBody("_ConfigCollectFullSaveUpdates")
	Assert(Collector != "", "the real full-save collector must be present")
	for Retired in ["metrics_shortcut_typing", "metrics_shortcut_apps"]
		AssertEqual(0, InStr(Collector, Retired), "full-save must preserve unowned " . Retired)
	Preference := _DriverFuncBody("MS_CommitPreference")
	Assert(Preference != "", "the remaining Metrics preference owner must exist")
	AssertContains(Preference, "MS_SaveBuiltToIni(", "consent and colors retain built-plan persistence")
}
Test("metrics: boot and full-save never revive retired dedicated bindings", _MST_NoDedicatedBindingOwner)
