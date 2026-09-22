; tests/unit/test_onboarding_metrics_path.ahk

; ==============================================================================
; MODULE: Onboarding Metrics Path Tests
; DESCRIPTION:
; The keystroke-logging consent text on the wizard's metrics step must name the
; metrics store of the folder chosen on the config step. The WebView2 host
; pre-formatted the warning when the locale strings were injected, which is
; before the config step, so the text kept naming the boot folder.
; ==============================================================================

_TOMP_MetricsDirRule() {
	AssertEqual(KL_MetricsDirFor("C:\Data\Ergopti\"), "C:\Data\Ergopti\metrics")
	AssertEqual(KL_MetricsDirFor("C:\Data\Ergopti"), "C:\Data\Ergopti\metrics")
	AssertThrows(() => KL_MetricsDirFor(""), "an empty folder must fail fast")
}

_TOMP_ChosenFolderNamesItsStore() {
	AssertEqual(_Onboarding_MetricsPathFor("D:\Elsewhere\"), "D:/Elsewhere/metrics")
	AssertEqual(_Onboarding_MetricsPathFor("D:\Elsewhere"), "D:/Elsewhere/metrics")
}

_TOMP_EmptyFieldNamesTheDefaultStore() {
	; boot.ahk is not part of the test build; pin the default it would compute.
	global _DefaultConfigDir := "C:\Users\me\.config\ergopti_plus\"
	global _ConfigDir
	Previous := IsSet(_ConfigDir) ? _ConfigDir : ""
	try {
		; A redirected boot folder must not leak into the empty-field answer.
		_ConfigDir := "E:\Redirected\"
		AssertEqual(_Onboarding_MetricsPathFor(""), "C:/Users/me/.config/ergopti_plus/metrics",
			"an empty field commits to the OS default, so the consent text must name its store")
	} finally {
		_ConfigDir := Previous
	}
}

_TOMP_SetMetricsPathEchoesTheRequest() {
	Js := _OnbWeb_MetricsPathJs("D:\Elsewhere\", 7)
	AssertEqual(Js, 'window.setMetricsPath({request:7,path:"D:/Elsewhere/metrics"})')
}

_TOMP_InitStringsCarryTheRawTemplate() {
	Strings := JsonParse(_OnbWeb_LocaleStringsJson("en"))
	AssertTrue(Strings.Has("dialog.metrics.enable_warning"),
		"the page formats the warning itself from the raw template")
	AssertFalse(Strings.Has("dialog.metrics.enable_warning_formatted"),
		"a pre-formatted warning freezes the path before the config step")
}

Test("onboarding metrics path: the keylogger rule places the store at the folder root",
	_TOMP_MetricsDirRule)
Test("onboarding metrics path: a chosen folder names its own store",
	_TOMP_ChosenFolderNamesItsStore)
Test("onboarding metrics path: an empty field names the default store",
	_TOMP_EmptyFieldNamesTheDefaultStore)
Test("onboarding metrics path: setMetricsPath echoes the request number",
	_TOMP_SetMetricsPathEchoesTheRequest)
Test("onboarding metrics path: locale strings carry the raw warning template",
	_TOMP_InitStringsCarryTheRawTemplate)
