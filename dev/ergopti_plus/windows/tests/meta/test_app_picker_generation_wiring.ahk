; tests/meta/test_app_picker_generation_wiring.ahk

; ==============================================================================
; MODULE: App Picker Generation Wiring Guard
; DESCRIPTION:
; Pins the production-only GUI callbacks that the headless behavioral suite
; cannot open. Both consumers must carry the exact receipt into their candidate
; builders; merely implementing the receipt helper is not a remediation.
; ==============================================================================

#Requires AutoHotkey v2.0

_APGW_ProductionPickersCarryTheirReceipt() {
	Show := _DriverFuncBody("AppPicker_Show")
	Ok := _DriverFuncBody("AppPicker_OnOK")
	Invoke := _DriverFuncBody("AppPicker_InvokeSave")
	LlmOpen := _DriverFuncBody("LLM_Menu_OpenAppPicker")
	LlmSave := _DriverFuncBody("LLM_Menu_OnAppPickerSave")
	MetricsOpen := _DriverFuncBody("OpenMetricsAppPicker")
	MetricsSave := _DriverFuncBody("OnMetricsAppPickerSave")
	LlmPublish := _DriverFuncBody("_LLM_Menu_PublishCandidate")
	MetricsPublish := _DriverFuncBody("_MF_PublishDisabledAppsCandidate")
	for Name, Body in Map("AppPicker_Show", Show, "AppPicker_OnOK", Ok,
			"AppPicker_InvokeSave", Invoke, "LLM_Menu_OpenAppPicker", LlmOpen,
			"LLM_Menu_OnAppPickerSave", LlmSave,
			"OpenMetricsAppPicker", MetricsOpen,
			"OnMetricsAppPickerSave", MetricsSave) {
		Assert(Body != "", Name . " must remain source-visible")
	}
	Assert(InStr(Show, "AppPicker_IssueReceipt(owner, initial)") > 0
			&& InStr(Show, "AppPicker_OnOK(g, lv, on_save, receipt)") > 0,
		"the GUI must bind its exact issued receipt into the OK callback")
	Assert(InStr(Ok, "AppPicker_InvokeSave(on_save, selected, receipt)") > 0,
		"OK must forward the selected rows and immutable receipt together")
	Assert(InStr(Invoke, 'HasMethod(OnSave, "Call")') > 0
			&& InStr(Invoke, "OnSave.Call(Selected, Receipt)") > 0,
		"the callback boundary must accept every callable and pass the receipt")
	Assert(InStr(LlmOpen, '"owner",    "llm:disabled_apps"') > 0
			&& InStr(LlmSave, "selected, receipt") > 0,
		"the LLM picker must own and consume its dedicated receipt")
	Assert(InStr(MetricsOpen,
		'"owner",    "metrics:disabled_apps"') > 0
			&& InStr(MetricsSave, "Receipt") > 0,
		"the Metrics picker must own and consume an independent receipt")
	Assert(InStr(LlmPublish,
		'AppPicker_AdvanceOwner("llm:disabled_apps")') > 0,
		"non-picker LLM publication must invalidate the same logical owner")
	Assert(InStr(MetricsPublish,
		'AppPicker_AdvanceOwner("metrics:disabled_apps")') > 0,
		"every Metrics disabled-app producer must invalidate the picker owner")
}
Test("AHK-020 app picker wiring: production callbacks carry exact receipts "
	. "(ahk020-production-wiring)",
	_APGW_ProductionPickersCarryTheirReceipt)
