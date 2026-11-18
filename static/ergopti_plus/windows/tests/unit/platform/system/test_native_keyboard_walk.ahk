; tests/unit/platform/system/test_native_keyboard_walk.ahk

; ==============================================================================
; MODULE: Native Window Keyboard Walk Tests
; DESCRIPTION:
; The Studio's keyboard walk covered the web pages only (a11y-keyboard-
; 2026-11-18). These tests open the driver's own native windows (settings
; prompts, pickers, editors, help and report windows) through their real
; openers, off screen, and walk each one with Tab and Shift+Tab: every
; control must be reached, no control may keep the focus, and the way back
; must retrace the way in (WCAG 2.1.1, 2.1.2, 2.4.3). The first tests prove
; the walk refuses a trap and a control Tab skips.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ The walk refuses =======
; ===================================
; ===================================

_NKWT_ProblemsMatch(Walk, Pattern) {
	for Problem in Walk["problems"]
		if RegExMatch(Problem, Pattern)
			return true
	return false
}

_NKWT_OnlyWalk(Walks) {
	AssertEqual(1, Walks.Length, "the opener shows exactly one window")
	return Walks[1]
}

; A window of every control kind the driver uses walks clean, radio group
; included, and is closed by the capture.
_NKWT_CleanWindowWalks() {
	Hwnd := 0
	Open() {
		G := Gui(, "a11y walk clean")
		G.AddText(, "Label")
		G.AddEdit("w100")
		G.AddRadio("Checked", "One")
		G.AddRadio(, "Two")
		G.AddCheckbox(, "Check")
		G.AddDropDownList(, ["a", "b"])
		G.AddEdit("r3 Multi ReadOnly", "text")
		G.AddListView(, ["Column"])
		G.AddButton(, "OK")
		G.OnEvent("Close", (*) => G.Destroy())
		Hwnd := G.Hwnd
		G.Show()
		WinWaitClose("ahk_id " . Hwnd)
	}
	Walk := _NKWT_OnlyWalk(NativeKeyboardWalk_Capture(Open))
	AssertEqual(0, Walk["problems"].Length, "a clean window has no problem: " . _NKWT_Join(Walk["problems"]))
	AssertEqual(Walk["stops"], Walk["forward"].Length, "Tab meets each stop once, the radio group once")
	AssertFalse(DllCall("IsWindow", "Ptr", Hwnd), "the capture closes the window it walked")
}
Test("a11y keyboard walk: a clean native window walks without a problem (a11y-keyboard-2026-11-18)",
	_NKWT_CleanWindowWalks)

; A WantTab edit keeps every Tab: the walk names the trap and what it hides.
_NKWT_TrapIsRefused() {
	Open() {
		G := Gui(, "a11y walk trap")
		G.AddEdit("w100")
		G.AddEdit("w100 WantTab")
		G.AddButton(, "OK")
		G.Show()
	}
	Walk := _NKWT_OnlyWalk(NativeKeyboardWalk_Capture(Open))
	AssertTrue(_NKWT_ProblemsMatch(Walk, "Tab cannot leave Edit .*keyboard trap"), _NKWT_Join(Walk["problems"]))
	AssertTrue(_NKWT_ProblemsMatch(Walk, "Tab never reaches Button « OK »"), _NKWT_Join(Walk["problems"]))
}
Test("a11y keyboard walk: a control that keeps Tab is refused as a trap (a11y-keyboard-2026-11-18)",
	_NKWT_TrapIsRefused)

; A button without a tab stop is skipped by Tab: the walk names it.
_NKWT_SkippedControlIsRefused() {
	Open() {
		G := Gui(, "a11y walk skipped")
		G.AddEdit("w100")
		G.AddButton("-Tabstop", "Skipped")
		G.AddButton(, "OK")
		G.Show()
	}
	Walk := _NKWT_OnlyWalk(NativeKeyboardWalk_Capture(Open))
	AssertTrue(_NKWT_ProblemsMatch(Walk, "Tab never reaches Button « Skipped »"), _NKWT_Join(Walk["problems"]))
}
Test("a11y keyboard walk: a control Tab skips is refused (a11y-keyboard-2026-11-18)", _NKWT_SkippedControlIsRefused)

_NKWT_Join(Problems) {
	Text := ""
	for Problem in Problems
		Text .= (Text == "" ? "" : " | ") . Problem
	return Text
}





; =======================================
; =======================================
; ======= 2/ The driver's windows =======
; =======================================
; =======================================

; Each opener is the one its menu row or caller runs; each must show a window
; with something to reach, and every window it shows must walk clean.
_NKWT_AssertWindowsWalk(Name, Open) {
	Walks := NativeKeyboardWalk_Capture(Open)
	AssertTrue(Walks.Length > 0, Name . " must open a native window to walk")
	for Walk in Walks {
		AssertTrue(Walk["stops"] > 0, Name . ": " . Walk["title"] . " has a control to reach")
		AssertEqual(0, Walk["problems"].Length, Name . ": " . _NKWT_Join(Walk["problems"]))
	}
}

_NKWT_ProfilePrompt() {
	_NKWT_AssertWindowsWalk("profile prompt",
		() => _LLM_Menu_ProfilePromptInput("Prompt", "Profile"))
}
Test("a11y keyboard walk: the AI profile prompt (a11y-keyboard-2026-11-18)", _NKWT_ProfilePrompt)

_NKWT_GestureBackendPicker() {
	Choices := [Map("value", "first", "label", "First"), Map("value", "second", "label", "Second")]
	_NKWT_AssertWindowsWalk("gesture vision backend picker",
		() => _GestureVisionPickBackend("Backend", "Backend", Choices, ""))
}
Test("a11y keyboard walk: the gesture vision backend picker (a11y-keyboard-2026-11-18)", _NKWT_GestureBackendPicker)

_NKWT_GestureTutorial() {
	_NKWT_AssertWindowsWalk("manual gesture tutorial", GestureShowManualTutorialDialog)
}
Test("a11y keyboard walk: the manual gesture setup window (a11y-keyboard-2026-11-18)", _NKWT_GestureTutorial)

_NKWT_ComposerCheck() {
	_NKWT_AssertWindowsWalk("layout composer check report",
		() => _ComposerCheck_ShowWindow(t("menu.debug.composer_check"), "report"))
}
Test("a11y keyboard walk: the layout composer check report (a11y-keyboard-2026-11-18)", _NKWT_ComposerCheck)

_NKWT_GptLinkEditor() {
	_NKWT_AssertWindowsWalk("ChatGPT link editor", GPTLinkEditor)
}
Test("a11y keyboard walk: the ChatGPT link editor (a11y-keyboard-2026-11-18)", _NKWT_GptLinkEditor)

_NKWT_AppPicker() {
	_NKWT_AssertWindowsWalk("application picker",
		() => AppPicker_Show(Map("on_save", (*) => 1, "owner", "a11y-keyboard-walk")))
}
Test("a11y keyboard walk: the application picker (a11y-keyboard-2026-11-18)", _NKWT_AppPicker)

; The WebView2 windows fall back to these native ones when the runtime's
; loader is missing; the walk opens the fallback the same way.
_NKWT_WithoutWebView(Open) {
	global _VendorDir
	Saved := _VendorDir
	_VendorDir := A_Temp . "\ergopti_a11y_walk_no_webview_" . A_TickCount
	AssertFalse(FileExist(_VendorDir), "the WebView2 loader is genuinely missing for the native fallback")
	try Open.Call()
	finally _VendorDir := Saved
}

_NKWT_HotstringSettings() {
	_NKWT_AssertWindowsWalk("hotstring settings", () => _NKWT_WithoutWebView(OpenHotstringsConfigWindow))
}
Test("a11y keyboard walk: the hotstring settings window (a11y-keyboard-2026-11-18)", _NKWT_HotstringSettings)

_NKWT_PathsEditor() {
	_NKWT_AssertWindowsWalk("configuration folder editor", () => _NKWT_WithoutWebView(FilePathsEditor))
}
Test("a11y keyboard walk: the configuration folder editor (a11y-keyboard-2026-11-18)", _NKWT_PathsEditor)

_NKWT_ActionPicker() {
	_NKWT_AssertWindowsWalk("action picker",
		() => _NKWT_WithoutWebView(() => ShowActionPicker("Action", "", (Id) => 0)))
}
Test("a11y keyboard walk: the action picker (a11y-keyboard-2026-11-18)", _NKWT_ActionPicker)

_NKWT_KeyboardSlotPicker() {
	_NKWT_AssertWindowsWalk("keyboard shortcut slot picker", () => ShowKeyboardSlotPicker("primary_"))
}
Test("a11y keyboard walk: the keyboard shortcut slot picker (a11y-keyboard-2026-11-18)", _NKWT_KeyboardSlotPicker)

_NKWT_DelimiterPrompt() {
	_NKWT_AssertWindowsWalk("new hotstring delimiter prompt", _HS_DelimAddCustom)
}
Test("a11y keyboard walk: the new hotstring delimiter prompt (a11y-keyboard-2026-11-18)", _NKWT_DelimiterPrompt)

_NKWT_BundledAppChoice() {
	_NKWT_AssertWindowsWalk("bundled app question", () => BundledAppUi_Choice("Question", "Text", "Yes", "No"))
}
Test("a11y keyboard walk: the bundled apps' two-button question (a11y-keyboard-2026-11-18)", _NKWT_BundledAppChoice)

_NKWT_EncryptorDropWindow() {
	global _SharedDir
	; The bundled apps run as their own process and load their strings first.
	if !BundledAppStrings.loaded
		BundledAppStrings_Load(_SharedDir . "\core\i18n\data\locales", "en")
	_NKWT_AssertWindowsWalk("Encryptor drop window", () => Encryptor_ShowDropWindow(BundledAppUi_Ports()))
}
Test("a11y keyboard walk: the Encryptor drop window (a11y-keyboard-2026-11-18)", _NKWT_EncryptorDropWindow)

_NKWT_UpdatePrompt() {
	Release := {Tag: "v0.0.0-a11y", PublishedAt: "2026-11-18T00:00:00Z", Body: "", Url: ""}
	_NKWT_AssertWindowsWalk("update prompt", () => _NKWT_WithoutWebView(() => Updater_ShowUpdatePrompt(Release)))
}
Test("a11y keyboard walk: the update prompt (a11y-keyboard-2026-11-18)", _NKWT_UpdatePrompt)
