; tests/unit/ui/onboarding/test_onboarding_publication_owner.ahk

; ==============================================================================
; MODULE: Onboarding Publication Ownership Tests
; DESCRIPTION:
; Real source reads and private native WM_CLOSE events revoke an old wizard
; before its response returns. Its deferred-page queue must remain retired and
; a replacement's queue, locale and HWND must survive the old completion.
; Chromium is not instantiated: the real not-ready page queue is the receipt.
; ==============================================================================

#Requires AutoHotkey v2.0

_OBP_StartWindow(World, Replacement := false) {
	global _ob_gui, _OnbWeb_SessionEpoch, _OnbWeb_ResetDone, _OnbWeb_Ready, _OnbWeb_Queue
	_OnbWeb_SessionEpoch += 1
	_OnbWeb_ResetDone := false
	_OnbWeb_Ready := false
	_OnbWeb_Queue := Replacement ? ["replacementOwned();"] : []
	Window := Gui_Create(, "Private onboarding publication fixture")
	Window.OnEvent("Close", _OnbWeb_SessionCall.Bind(_OnbWeb_SessionEpoch, _OnbWeb_OnClose))
	Window.Show("Hide w240 h160")
	World.Windows.Push(Window)
	_ob_gui := Window
	return Window.Hwnd
}

_OBP_Transition(World) {
	global _ob_gui
	World.Transitions += 1
	if World.Mode == "live"
		return
	OldHwnd := _ob_gui.Hwnd
	AssertTrue(DllCall("PostMessageW", "Ptr", OldHwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int"),
		"the original private wizard receives an actual native Close event")
	Started := A_TickCount
	while WMHandleExists(OldHwnd) && A_TickCount - Started < 2000
		Sleep(1)
	AssertFalse(WMHandleExists(OldHwnd), "the real close handler must retire the original HWND")
	if World.Mode == "reopened"
		World.ReplacementHwnd := _OBP_StartWindow(World, true)
}

_OBP_Read(World, Index, Path) {
	World.Reads += 1
	Values := OnboardingReadCurrentValues(Index, Path)
	if World.Route != "init-error" && World.Route != "error-popup" {
		AssertTrue(Values is Map, "the controlled boundary still reads the actual booted configuration")
		AssertTrue(Values["metrics.metrics_enabled"] is TOML_Bool)
		AssertTrue(Values["metrics.metrics_enabled"].Value)
	} else
		AssertTrue(Values is String, "the actual malformed source must produce its ordinary read refusal")
	if World.Route != "error-popup"
		_OBP_Transition(World)
	return Values
}

_OBP_Strings(World, Code) {
	World.Strings += 1
	Strings := _OnbWeb_LocaleStringsJson(Code)
	AssertTrue(JsonParse(Strings) is Map, "the locale boundary returns a genuine shipped document")
	_OBP_Transition(World)
	return Strings
}

_OBP_Metrics(World, Dir, Request) {
	World.Metrics += 1
	Script := _OnbWeb_MetricsPathJs(Dir, Request)
	_OBP_Transition(World)
	return Script
}

_OBP_ShowError(World, Key) {
	World.Popups += 1
	AssertEqual("onboarding.error.open_failed", Key)
	if World.Route == "error-popup"
		_OBP_Transition(World)
}

_OBP_Fail(World, Detail, Epoch) {
	World.Errors += 1
	return _OnbWeb_OpenFailed(Detail, Epoch, _OBP_ShowError.Bind(World))
}

_OBP_Message(World, Args) {
	World.Messages += 1
	_OBP_Transition(World)
	return '{"action":"localeSelected","locale":"fr"}'
}

_OBP_ExpiredEntry(World, Epoch, Folder) {
	_OBP_Transition(World)
	AssertFalse(_OnbWeb_InjectInitData(Epoch, _OBP_Read.Bind(World), _OBP_Fail.Bind(World)))
	AssertFalse(_OnbWeb_LoadExistingConfig(Folder, 1, Epoch, _OBP_Read.Bind(World)))
	AssertFalse(_OnbWeb_ResolveMetricsPath(Folder, 1, Epoch, _OBP_Metrics.Bind(World)))
	AssertFalse(_OnbWeb_PreviewLocale("en", Epoch, _OBP_Strings.Bind(World)))
	AssertFalse(_OnbWeb_SafetyFlush(Epoch))
	AssertFalse(_OnbWeb_Finish(Map(), Epoch))
	AssertFalse(_OnbWeb_RegisterGesturesAuto(Epoch))
	AssertFalse(_OnbWeb_RegisterGesturesManual(Epoch))
	AssertEqual(0, World.Reads + World.Strings + World.Metrics + World.Errors,
		"a callback already revoked after dispatcher admission cannot recapture the new epoch")
}

_OBP_Publication(Route, Mode) {
	global _ob_gui, _ob_locale, _OB_ALTGR_PASSTHROUGH, ConfigurationFile, _AhkSubDir
	global _ConfigDir, _DefaultConfigDir, _OnboardingCatalogue
	global _OnbWeb_SessionEpoch, _OnbWeb_ResetDone, _OnbWeb_Ready, _OnbWeb_Queue
	global _OnbWeb_Controller, _OnbWeb_WebView, _OnbWeb_MsgSub
	Saved := { Gui: _ob_gui, Locale: _ob_locale, AltGr: _OB_ALTGR_PASSTHROUGH,
		Config: ConfigurationFile, SubDirSet: IsSet(_AhkSubDir), SubDir: IsSet(_AhkSubDir) ? _AhkSubDir : "",
		Dir: _ConfigDir, HasDefault: IsSet(_DefaultConfigDir), DefaultDir: IsSet(_DefaultConfigDir) ? _DefaultConfigDir : "",
		Catalogue: _OnboardingCatalogue,
		Epoch: _OnbWeb_SessionEpoch, Reset: _OnbWeb_ResetDone, Ready: _OnbWeb_Ready, Queue: _OnbWeb_Queue,
		HasController: IsSet(_OnbWeb_Controller), Controller: IsSet(_OnbWeb_Controller) ? _OnbWeb_Controller : 0,
		HasView: IsSet(_OnbWeb_WebView), View: IsSet(_OnbWeb_WebView) ? _OnbWeb_WebView : 0,
		HasSub: IsSet(_OnbWeb_MsgSub), Sub: IsSet(_OnbWeb_MsgSub) ? _OnbWeb_MsgSub : 0,
		Suspended: A_IsSuspended, Critical: A_IsCritical }
	World := { Route: Route, Mode: Mode, Windows: [], Reads: 0, Strings: 0, Metrics: 0,
		Errors: 0, Popups: 0, Messages: 0, Transitions: 0, ReplacementHwnd: 0 }
	Fixture := 0
	try {
		Fixture := _ScopeOwnerFixture('[metrics]`nmetrics_enabled = true`n')
		ConfigurationFile := Fixture.path
		_AhkSubDir := ""
		_ConfigDir := Fixture.directory . "\"
		_DefaultConfigDir := _ConfigDir
		_ob_locale := "en"
		_OnbWeb_Controller := unset
		_OnbWeb_WebView := unset
		_OnbWeb_MsgSub := unset
		Suspend(false)
		Critical("Off")
		OriginalHwnd := _OBP_StartWindow(World)
		Epoch := _OnbWeb_SessionEpoch
		if Route == "init-error" || Route == "error-popup"
			AssertTrue(FSWriteDurable(Fixture.path, Fixture.source . '[metrics]`nmetrics_enabled = false`n'),
				"an external invalid edit exercises a genuine read refusal without a second Boot")
		SourceBefore := FSReadUtf8Exact(Fixture.path)
		switch Route {
			case "load": _OnbWeb_LoadExistingConfig(Fixture.directory, 1, Epoch, _OBP_Read.Bind(World))
			case "init-read", "init-error", "error-popup":
				_OnbWeb_InjectInitData(Epoch, _OBP_Read.Bind(World), _OBP_Fail.Bind(World))
			case "init-locale":
				_OnbWeb_InjectInitData(Epoch, OnboardingReadCurrentValues, _OBP_Fail.Bind(World), _OBP_Strings.Bind(World))
			case "preview-locale": _OnbWeb_PreviewLocale("en", Epoch, _OBP_Strings.Bind(World))
			case "metrics": _OnbWeb_ResolveMetricsPath(Fixture.directory, 1, Epoch, _OBP_Metrics.Bind(World))
			case "expired": _OBP_ExpiredEntry(World, Epoch, Fixture.directory)
			case "bridge":
				_OnbWeb_OnWebMessage(Epoch, 0, {TryGetWebMessageAsString: _OBP_Message.Bind(World)})
			default: throw ValueError("Unknown onboarding publication fixture route.")
		}
		AssertEqual(1, World.Transitions, "the fixture must reach its actual completion boundary")
		AssertEqual(SourceBefore, FSReadUtf8Exact(Fixture.path), "UI publication never writes the observed source")
		if Route == "bridge" {
			AssertEqual(1, World.Messages)
			AssertEqual(Mode == "live" ? "fr" : "en", _ob_locale,
				"a COM message which lost its origin cannot select the replacement's locale")
		}
		if Mode == "live" {
			if Route == "init-error" {
				AssertEqual(1, World.Errors)
				AssertEqual(1, World.Popups, "a current read failure still reports its normal error")
				AssertFalse(WMHandleExists(OriginalHwnd), "a current startup failure still closes its own wizard")
				AssertEqual(0, _OnbWeb_Queue.Length)
			} else {
				AssertTrue(WMHandleExists(OriginalHwnd), "a current successful read retains its native host")
				AssertEqual(Route == "bridge" ? 0 : 1, _OnbWeb_Queue.Length)
				if Route != "bridge" {
					Script := _OnbWeb_Queue[1]
					Expected := Route == "load" ? "window.applyCurrentValues({request:1" : Route == "metrics"
						? "window.setMetricsPath({request:1" : Route == "preview-locale" ? "window.applyStrings(" : "window.initData("
					AssertTrue(InStr(Script, Expected) == 1, "the actual current route still publishes its complete response")
					if Route == "load" || Route == "init-read" || Route == "init-locale"
						AssertContains(Script, '"metrics.metrics_enabled":true')
				}
			}
		} else {
			AssertFalse(WMHandleExists(OriginalHwnd))
			AssertEqual(Route == "error-popup" ? 1 : 0, World.Errors,
				"a retired read failure cannot report against the replacement")
			AssertEqual(Route == "error-popup" ? 1 : 0, World.Popups)
			if Mode == "reopened" {
				AssertTrue(WMHandleExists(World.ReplacementHwnd), "the old completion cannot close the new native wizard")
				AssertEqual(1, _OnbWeb_Queue.Length)
				AssertEqual("replacementOwned();", _OnbWeb_Queue[1], "the replacement cannot receive an old request-1 or init reply")
				AssertEqual(WindowTitle("Private onboarding publication fixture"), _ob_gui.Title,
					"an old locale completion cannot rename the replacement")
			} else {
				AssertEqual(0, _ob_gui)
				AssertEqual(0, _OnbWeb_Queue.Length, "a closed session cannot recover deferred work")
			}
		}
	} finally {
		for Window in World.Windows {
			if _ob_gui == Window
				_OnbWeb_OnClose()
			try Window.Destroy()
		}
		World.Windows := []
		_ob_gui := Saved.Gui, _ob_locale := Saved.Locale, _OB_ALTGR_PASSTHROUGH := Saved.AltGr
		ConfigurationFile := Saved.Config, _AhkSubDir := Saved.SubDirSet ? Saved.SubDir : unset
		_ConfigDir := Saved.Dir, _DefaultConfigDir := Saved.HasDefault ? Saved.DefaultDir : unset
		_OnboardingCatalogue := Saved.Catalogue
		_OnbWeb_SessionEpoch := Saved.Epoch, _OnbWeb_ResetDone := Saved.Reset
		_OnbWeb_Ready := Saved.Ready, _OnbWeb_Queue := Saved.Queue
		_OnbWeb_Controller := Saved.HasController ? Saved.Controller : unset
		_OnbWeb_WebView := Saved.HasView ? Saved.View : unset
		_OnbWeb_MsgSub := Saved.HasSub ? Saved.Sub : unset
		Suspend(Saved.Suspended)
		Critical(Saved.Critical)
		if Fixture is Object
			_ScopeOwnerCleanup(Fixture)
	}
}

for _OBP_Route in ["load", "init-read", "init-locale", "preview-locale", "metrics", "init-error", "bridge"]
	for _OBP_Mode in ["live", "closed", "reopened"]
		Test("onboarding publication: " . _OBP_Route . " after " . _OBP_Mode
			. " completion (onboarding-publication-owner)", _OBP_Publication.Bind(_OBP_Route, _OBP_Mode))
for _OBP_ErrorMode in ["closed", "reopened"]
	Test("onboarding publication: error popup retains its origin after " . _OBP_ErrorMode
		. " (onboarding-publication-owner)", _OBP_Publication.Bind("error-popup", _OBP_ErrorMode))
Test("onboarding publication: admitted old callbacks cannot recapture a replacement (onboarding-publication-owner)",
	_OBP_Publication.Bind("expired", "reopened"))
