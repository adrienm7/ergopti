; tests/meta/core/ui/webview/test_no_native_webview_fallback.ahk

; ==============================================================================
; MODULE: No Native WebView Fallback Census
; DESCRIPTION:
; WebView windows had native AutoHotkey forms that opened when WebView2 was
; missing, too old or short of RAM. The unit suite never loads the vendored
; binding, so every test path that reached such a window showed the native form
; on the desktop (maintainer report 2026-11-21). They were removed: a WebView
; window asks the shared admission and refuses with one localized message.
;
; WHAT IS PINNED (webview-no-native-fallback):
; 1. No production source names a retired native fallback or the RAM gate.
; 2. Every source that creates a WebView2 controller goes through the shared
;    admission or refusal, so an unavailable runtime is told, never replaced.
; 3. The suite answers MsgBox and InputBox itself: a test path that reaches a
;    native modal cannot show it on the desktop.
; ==============================================================================

#Requires AutoHotkey v2.0

; The removed native forms and the low-RAM switch that chose them.
global _NNWF_RETIRED := ["WebView_ShouldUseNativeFallback", "WEBVIEW_MIN_AVAIL_RAM_MB", "WebView_AvailRamMb",
	"_LLM_ModelBrowser_Build", "_LLM_ModelBrowser_RefreshRows", "_LLM_ModelBrowser_PickRow",
	"_UpdateCheck_BuildNative", "_UpdateCheck_FallBackToNative", "_UpdateCheck_NativeTexts", "_UC_Native",
	"_Updater_BuildChangelogGui", "_Updater_OpenChangelogWindow", "_Updater_ReleaseNotesToPlain",
	"_Updater_MarkdownToPlain", "_PathsEdNative_", "_ActPickWeb_Available", "_GesturePickProgram",
	"_CLW_WebView2Available", "_OnbWeb_Available", "_LayMgrWeb_Available", "OllamaWV_WebView2Available",
	"_LLM_Menu_ProfilePromptInput", "_PromptEdWeb_Available", "_HCWWeb_Available", "_HCWGui", "_HC_ShowNativeSnapshot",
	"ManagedNativeFailureWindow", "_LLM_MBW_WebView2Available"]

; Each production source with its masked code (comments and strings blanked).
_NNWF_Sources() {
	static Sources := 0
	if IsObject(Sources)
		return Sources
	Sources := []
	for Path in _DriverProductionSourceCensus().Paths {
		Raw := FileRead(Path, "UTF-8")
		Sources.Push({Path: Path, Code: _DriverMaskNonCode(&Raw)})
	}
	Assert(Sources.Length > 500, "the production census must reach the whole driver")
	return Sources
}

_NNWF_NoRetiredFallback() {
	Found := ""
	for Source in _NNWF_Sources() {
		for Name in _NNWF_RETIRED {
			if RegExMatch(Source.Code, "(?<![A-Za-z0-9_])" . Name)
				Found .= (Found == "" ? "" : ", ") . Name . " in " . Source.Path
		}
	}
	AssertEqual("", Found, "a removed native WebView fallback came back")
}
Test("webview fallbacks: no production source names a removed native form or the RAM gate (webview-no-native-fallback)",
	_NNWF_NoRetiredFallback)

_NNWF_EveryControllerIsAdmitted() {
	Hosts := 0, Missing := ""
	for Source in _NNWF_Sources() {
		if !RegExMatch(Source.Code, "\bWebView2\.create\(")
			continue
		Hosts += 1
		if !RegExMatch(Source.Code, "\bWebView_(RequireAvailable|RefuseUnavailable|UnavailableReason)\(")
			Missing .= (Missing == "" ? "" : ", ") . Source.Path
	}
	Assert(Hosts >= 10, "the census must find the WebView hosts (found " . Hosts . ")")
	AssertEqual("", Missing, "a WebView host creates a controller without the shared admission or refusal")
}
Test("webview fallbacks: every WebView2 host admits or refuses through the shared owner (webview-no-native-fallback)",
	_NNWF_EveryControllerIsAdmitted)

; The framework's own definitions shadow the built-in modals for every test.
_NNWF_SuiteAnswersNativeModals() {
	Path := A_ScriptDir . "\test_framework.ahk"
	Raw := FileRead(Path, "UTF-8")
	Code := _DriverMaskNonCode(&Raw)
	for Name in ["MsgBox", "InputBox"]
		Assert(RegExMatch(Code, "m)^" . Name . "\(Prompt|^" . Name . "\(Text"),
			"the suite must answer " . Name . " itself rather than show it")
	Started := A_TickCount
	Answer := Ui_InputBox("Census probe", "Census", "T5")
	Assert(A_TickCount - Started < 2000 && Answer.Result == "Cancel",
		"an unanswered production InputBox must return at once as Cancel")
}
Test("webview fallbacks: the suite answers native modals instead of showing them (webview-no-native-fallback)",
	_NNWF_SuiteAnswersNativeModals)

; The program parameter had a native editor beside the picker page; without a
; value from the page the action now saves nothing and opens no window.
_NNWF_ProgramParameterHasNoNativeEditor() {
	global _GesturePickedParameter
	AssertEqual("program", GestureActionParameterSpec("run_program"), "run_program takes a program")
	Saved := _GesturePickedParameter
	PreviousDetect := DetectHiddenWindows(true)
	try {
		_GesturePickedParameter := 0
		Before := WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . ProcessExist()).Length
		AssertFalse(GesturePromptActionParameter("gesture__tap_3", "run_program"),
			"a program with no value from the page is not saved")
		AssertEqual(Before, WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . ProcessExist()).Length,
			"no native program editor may open")
	} finally {
		_GesturePickedParameter := Saved
		DetectHiddenWindows(PreviousDetect)
	}
}
Test("webview fallbacks: a program parameter opens no native editor (webview-no-native-fallback)",
	_NNWF_ProgramParameterHasNoNativeEditor)
