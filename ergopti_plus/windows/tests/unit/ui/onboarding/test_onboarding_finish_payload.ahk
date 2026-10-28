; tests/unit/ui/onboarding/test_onboarding_finish_payload.ahk

; ==============================================================================
; MODULE: Onboarding WebView Finish Payload Tests
; DESCRIPTION:
; The WebView bridge must reject a malformed ``answers`` value before it can
; enter the onboarding persistence/reload transaction. A scalar used to throw
; from ``answers.Has(...)``; an Array could instead reach the transaction with
; every choice silently defaulted.
; ==============================================================================

_TOFP_FinishRejectsNonMapAnswers() {
	for _, Answers in ["malformed", []] {
		Thrown := false
		Result := true
		try Result := _OnbWeb_Finish(Answers)
		catch
			Thrown := true
		AssertFalse(Thrown,
			"a non-Map finish payload must not throw from the deferred WebView callback")
		AssertFalse(Result,
			"a non-Map finish payload must be rejected before persistence")
	}
}
Test("onboarding WebView: finish rejects non-Map answers (AHK-147)",
	_TOFP_FinishRejectsNonMapAnswers)


; Observes the real producer through its existing deferred-page queue. No native
; WebView is created and no personal configuration source is read or written.
_TOFP_InitDataStringField(Script, Field) {
	Pattern := "(?:^|,)" . Field . ':("(?:\\.|[^"\\])*")'
	Assert(RegExMatch(Script, Pattern, &Captured) > 0,
		"the genuine initData producer must publish " . Field)
	return JsonParse(Captured[1])
}

_TOFP_EmptyFolderInitDestination(Custom) {
	global _ob_locale, _DefaultConfigDir, _ConfigDir, ConfigurationFile
	global _OnbWeb_Ready, _OnbWeb_Queue, _OnboardingCatalogue
	SavedLocale := { present: IsSet(_ob_locale), value: IsSet(_ob_locale) ? _ob_locale : 0 }
	SavedDefault := { present: IsSet(_DefaultConfigDir), value: IsSet(_DefaultConfigDir) ? _DefaultConfigDir : 0 }
	SavedCurrent := { present: IsSet(_ConfigDir), value: IsSet(_ConfigDir) ? _ConfigDir : 0 }
	SavedConfig := { present: IsSet(ConfigurationFile), value: IsSet(ConfigurationFile) ? ConfigurationFile : 0 }
	SavedReady := _OnbWeb_Ready, SavedQueue := _OnbWeb_Queue, SavedCatalogue := _OnboardingCatalogue
	Directory := A_Temp . "\ergopti_onboarding_empty_target_" . DllCall("GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "_" . Random(100000, 999999)
	DirCreate(Directory)
	try {
		_ob_locale := "en"
		_DefaultConfigDir := "C:\Users\fixture\.config\ergopti_plus\"
		_ConfigDir := Custom ? "E:\Custom-B\" : "C:\Users\fixture\.config\ergopti_plus\"
		ConfigurationFile := Directory . "\config.toml"
		_OnbWeb_Ready := false, _OnbWeb_Queue := [], _OnboardingCatalogue := ""
		_OnbWeb_InjectInitData()
		AssertEqual(_OnbWeb_Queue.Length, 1,
			"the real ready producer queues exactly one initialization without creating a WebView")
		Script := _OnbWeb_Queue[1]
		Assert(InStr(Script, "window.initData({") == 1, "the observed publication must initialize the wizard")
		AssertEqual(_TOFP_InitDataStringField(Script, "empty_config_dir"),
			"C:\Users\fixture\.config\ergopti_plus\",
			"clearing the Windows field selects the OS default even from a custom boot folder")
		AssertEqual(_TOFP_InitDataStringField(Script, "default_config_dir"),
			"C:\Users\fixture\.config\ergopti_plus\")
		AssertEqual(_TOFP_InitDataStringField(Script, "config_dir"), Custom ? "E:\Custom-B\" : "",
			"the original custom-choice payload is preserved")
		Assert(InStr(Script, ",capabilities:{gesture_registration:true},"),
			"the Windows host tells the page it registers gestures with the system")
		AssertFalse(FileExist(ConfigurationFile), "initial presentation cannot create configuration")
	} finally {
		_ob_locale := SavedLocale.present ? SavedLocale.value : unset
		_DefaultConfigDir := SavedDefault.present ? SavedDefault.value : unset
		_ConfigDir := SavedCurrent.present ? SavedCurrent.value : unset
		ConfigurationFile := SavedConfig.present ? SavedConfig.value : unset
		_OnbWeb_Ready := SavedReady, _OnbWeb_Queue := SavedQueue, _OnboardingCatalogue := SavedCatalogue
		DirDelete(Directory)
	}
}

Test("onboarding WebView: empty-folder initData names the default destination from a custom folder",
	_TOFP_EmptyFolderInitDestination.Bind(true))
Test("onboarding WebView: empty-folder initData preserves the default-folder display contract",
	_TOFP_EmptyFolderInitDestination.Bind(false))

#Include test_onboarding_publication_owner.ahk
