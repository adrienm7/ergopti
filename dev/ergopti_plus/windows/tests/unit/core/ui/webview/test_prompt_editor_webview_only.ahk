; tests/unit/core/ui/webview/test_prompt_editor_webview_only.ahk

; ==============================================================================
; MODULE: Prompt Editor WebView-Only Refusal Tests
; DESCRIPTION:
; The LLM profile editor has no native wizard (maintainer decision 2026-11-21).
; The public create and edit entries run with the suite's genuinely absent
; WebView2 binding over a real, capturable configuration source: no Gui of this
; process may appear, the WebView2-required message is shown exactly once, and
; the refusal is logged at ERROR. The removed wizard answered with InputBox
; prompts and a native multiline Gui instead.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every top-level window this process owns, hidden ones included.
_PEWV_OwnWindows() {
	PreviousDetect := DetectHiddenWindows(true)
	try return WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . ProcessExist())
	finally DetectHiddenWindows(PreviousDetect)
}

_PEWV_Case(OpenFn) {
	global _LLM_Menu, Features, _LLM_Menu_ProfileHotkeyOwner, _LOGGER_TEST_SINK
	PreviousContext := _PEC_InstallFixture()
	World := 0
	PreviousCritical := Critical("Off")
	WasSuspended := A_IsSuspended
	SavedHotkeys := _LLM_Menu_ProfileHotkeyOwner
	PreviousSink := _LOGGER_TEST_SINK
	Logs := [], Shown := [], Result := "unset"
	try {
		Suspend(false)
		World := _LSP_World()
		_LLM_Menu_ProfileHotkeyOwner := 0
		Profile := Map("id", "user_profile_a", "label", "Profile A", "system_single", "original-a",
			"system_multi", "", "batch", false)
		_LLM_Menu["user_profiles"] := [Profile]
		_LLM_Menu["profile_id"] := "user_profile_a"
		_LLM_Menu["enabled"] := false
		AssertTrue(TOML_ConfigBatchWrite(World.ConfigPath,
			_ConfigPrepareTypedUpdates(_LLM_Menu_ProfileProjectionUpdates(Features, _LLM_Menu))),
			"The private source must match every persisted LLM leaf so the entry reaches the editor")
		AssertTrue(_LLM_Menu_CaptureProfileSource() is Map,
			"The public entry must not stop at the configuration source")
		Image := FSReadUtf8Exact(World.ConfigPath)
		AssertTrue(WebView_UnavailableReason() != "", "The suite runs without a usable WebView2")
		ShownBefore := TestMsgBoxCount(), InputsBefore := TestInputBoxCount()
		Before := Map()
		for Hwnd in _PEWV_OwnWindows()
			Before[Hwnd] := true
		try {
			TestMsgBoxResponder((Text, Title, Options) => (Shown.Push({Text: Text, Title: Title}), ""))
			_LoggerFlushRepeats(true)
			LoggerSetTestSink((Line) => Logs.Push(Line))
			Result := OpenFn.Call(Profile)
			_LoggerFlushRepeats(true)
		} finally {
			LoggerSetTestSink(PreviousSink)
			TestMsgBoxResponder("")
		}
		Created := 0
		for Hwnd in _PEWV_OwnWindows()
			if !Before.Has(Hwnd)
				Created += 1
		AssertEqual(0, Created, "No native profile window may be built without WebView2")
		AssertEqual(InputsBefore, TestInputBoxCount(), "No native InputBox wizard may ask for the profile")
		AssertTrue((Result is Integer) && Result == 0, "A refused opening must report that nothing opened")
		AssertEqual(ShownBefore + 1, TestMsgBoxCount(), "The user must be told exactly once")
		AssertEqual(1, Shown.Length)
		AssertEqual(t("webview.required"), Shown[1].Text, "The message must be the shared WebView2-required text")
		Errors := []
		for Line in Logs
			if InStr(Line, "[ERROR]") && InStr(Line, "The prompt editor cannot open: WebView2 is required")
				Errors.Push(Line)
		AssertEqual(1, Errors.Length, "The refusal must be logged once at ERROR")
		AssertEqual(Image, FSReadUtf8Exact(World.ConfigPath), "A refused opening must not touch the configuration")
		AssertEqual(0, World.ApplyCalls, "A refused opening must not publish a profile")
	} finally {
		try {
			if World is _LSP_World
				World.Restore()
		} finally {
			_PEC_RestoreFixture(PreviousContext)
			_LLM_Menu_ProfileHotkeyOwner := SavedHotkeys
			Suspend(WasSuspended)
			Critical(PreviousCritical)
		}
	}
}

Test("LLM profile create: an absent WebView2 shows the required message and builds no native wizard (prompt-editor-webview-only)",
	_PEWV_Case.Bind((Profile) => LLM_Menu_PromptCreateProfile()))

Test("LLM profile edit: an absent WebView2 shows the required message and builds no native wizard (prompt-editor-webview-only)",
	_PEWV_Case.Bind((Profile) => LLM_Menu_PromptEditProfile(Profile)))
