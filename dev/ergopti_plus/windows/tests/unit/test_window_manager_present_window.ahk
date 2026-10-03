; tests/unit/test_window_manager_present_window.ahk

; ==============================================================================
; MODULE: Windows Are Presented, Never Kept On Top (Windows)
; DESCRIPTION:
; Maintainer rule (2026-09-29): an ErgoptiPlus window is shown, raised and
; focused when it opens or is requested again, and never kept above the
; windows the user opens afterwards. WMPresentWindow is the driver's one
; present step for an open window; these tests drive it through a recording
; Win32 double, build the real window factories and check the native
; extended style, and pin every singleton re-open to the helper
; (ui-focus-not-topmost).
; ==============================================================================

#Requires AutoHotkey v2.0

; WS_EX_TOPMOST, the native flag behind Gui +AlwaysOnTop.
global _WMPW_WS_EX_TOPMOST := 0x8

class _WMPWNative {
	static window_valid := true
	static iconic := false
	static visible := true
	static foreground_ok := true
	static foreground_hwnd := 99
	static calls := []

	static Reset() {
		_WMPWNative.window_valid := true
		_WMPWNative.iconic := false
		_WMPWNative.visible := true
		_WMPWNative.foreground_ok := true
		_WMPWNative.foreground_hwnd := 99
		_WMPWNative.calls := []
	}

	static IsWindow(HWnd) {
		_WMPWNative.calls.Push("is-window:" . HWnd)
		return _WMPWNative.window_valid
	}

	static IsIconic(HWnd) {
		return _WMPWNative.iconic
	}

	static IsWindowVisible(HWnd) {
		return _WMPWNative.visible
	}

	static Restore(HWnd) {
		_WMPWNative.calls.Push("restore:" . HWnd)
		_WMPWNative.iconic := false
	}

	static Show(HWnd) {
		_WMPWNative.calls.Push("show:" . HWnd)
		_WMPWNative.visible := true
	}

	static GetForegroundWindow() {
		return _WMPWNative.foreground_hwnd
	}

	static GetWindowThreadProcessId(HWnd) {
		return HWnd = 42 ? 20 : 10
	}

	static AttachThreadInput(ForeThread, TargThread, Attach) {
		_WMPWNative.calls.Push((Attach ? "attach:" : "detach:") . ForeThread . ":" . TargThread)
		return true
	}

	static BringWindowToTop(HWnd) {
		_WMPWNative.calls.Push("bring:" . HWnd)
		return true
	}

	static SetForegroundWindow(HWnd) {
		_WMPWNative.calls.Push("set-foreground:" . HWnd)
		if _WMPWNative.foreground_ok
			_WMPWNative.foreground_hwnd := HWnd
		return _WMPWNative.foreground_ok
	}

	static Activate(HWnd) {
		_WMPWNative.calls.Push("activate:" . HWnd)
		return true
	}
}

; Position of the first recorded call equal to Expected, 0 when absent.
_WMPW_CallIndex(Expected) {
	for Index, Call in _WMPWNative.calls {
		if (Call = Expected)
			return Index
	}
	return 0
}

; The extended style of a real native window.
_WMPW_ExStyle(Hwnd) {
	return DllCall(A_PtrSize = 8 ? "GetWindowLongPtr" : "GetWindowLong", "Ptr", Hwnd, "Int", -20, "Ptr")
}





; ====================================================
; ====================================================
; ======= 1/ The present helper, behaviourally =======
; ====================================================
; ====================================================

_WMPW_CoveredWindowIsRaisedAndFocused() {
	_WMPWNative.Reset()
	AssertTrue(WMPresentWindow(42, _WMPWNative),
		"a window covered by the user's app must come back to the foreground")
	AssertTrue(_WMPW_CallIndex("bring:42") > 0, "the window must be raised")
	AssertTrue(_WMPW_CallIndex("set-foreground:42") > 0, "the window must take the keyboard")
	AssertEqual(0, _WMPW_CallIndex("restore:42"), "a visible window is not restored")
	AssertEqual(0, _WMPW_CallIndex("show:42"), "a visible window is not shown again")
	AssertTrue(_WMPW_CallIndex("detach:10:20") > 0, "the foreground-lock workaround must detach")
}
Test("present window: a covered window is raised and focused (ui-focus-not-topmost)",
	_WMPW_CoveredWindowIsRaisedAndFocused)

_WMPW_MinimizedOrHiddenWindowComesBackFirst() {
	_WMPWNative.Reset()
	_WMPWNative.iconic := true
	AssertTrue(WMPresentWindow(42, _WMPWNative))
	Restore := _WMPW_CallIndex("restore:42")
	Foreground := _WMPW_CallIndex("set-foreground:42")
	AssertTrue(Restore > 0 && Foreground > Restore,
		"a minimized window must be restored before it takes the foreground")

	_WMPWNative.Reset()
	_WMPWNative.visible := false
	AssertTrue(WMPresentWindow(42, _WMPWNative))
	Shown := _WMPW_CallIndex("show:42")
	Foreground := _WMPW_CallIndex("set-foreground:42")
	AssertTrue(Shown > 0 && Foreground > Shown,
		"a hidden window must be shown before it takes the foreground")
}
Test("present window: a minimized or hidden window comes back first (ui-focus-not-topmost)",
	_WMPW_MinimizedOrHiddenWindowComesBackFirst)

_WMPW_RefusalAndClosedWindowFail() {
	_WMPWNative.Reset()
	_WMPWNative.foreground_ok := false
	AssertFalse(WMPresentWindow(42, _WMPWNative),
		"a refused foreground must not be reported as presented")

	_WMPWNative.Reset()
	_WMPWNative.window_valid := false
	AssertFalse(WMPresentWindow(42, _WMPWNative), "a closed window cannot be presented")
	AssertEqual(1, _WMPWNative.calls.Length, "a closed window must not reach any native mutation")

	Gone := Gui()
	Gone.Destroy()
	_WMPWNative.Reset()
	AssertFalse(WMPresentWindow(Gone, _WMPWNative),
		"a destroyed Gui is reported, never thrown at the caller")
	AssertEqual(0, _WMPWNative.calls.Length, "a destroyed Gui has no handle to present")
}
Test("present window: refusals and closed windows fail visibly (ui-focus-not-topmost)",
	_WMPW_RefusalAndClosedWindowFail)





; ==========================================================
; ==========================================================
; ======= 2/ Real windows are never topmost natively =======
; ==========================================================
; ==========================================================

_WMPW_WindowFactoriesAreNeverTopmost() {
	global _WMPW_WS_EX_TOPMOST
	for Name, Factory in Map("diagnostics", _HC_NewWindow, "error", _ErrorDialog_NewWindow,
		"plain", Gui_Create.Bind("", "x")) {
		Window := Factory.Call()
		try {
			AssertEqual(0, _WMPW_ExStyle(Window.Hwnd) & _WMPW_WS_EX_TOPMOST,
				"the " . Name . " window must not carry WS_EX_TOPMOST")
		} finally Window.Destroy()
	}
}
Test("windows: the diagnostics and error windows are never topmost natively (ui-focus-not-topmost)",
	_WMPW_WindowFactoriesAreNeverTopmost)

_WMPW_FactoryRefusesATopmostWindow() {
	for Options in ["+AlwaysOnTop", "+Resize +alwaysontop", "+E0x8", "-Caption +E0x80008"] {
		Refused := false
		try {
			Window := Gui_Create(Options, "x")
			Window.Destroy()
		} catch ValueError
			Refused := true
		AssertTrue(Refused, "Gui_Create must refuse a topmost window: " . Options)
	}
	Window := Gui_Create("+Resize -Caption +E0x20 +E0x80", "x")
	try AssertEqual(0, _WMPW_ExStyle(Window.Hwnd) & 0x8, "click-through styles are not topmost")
	finally Window.Destroy()
}
Test("windows: the window factory refuses AlwaysOnTop and WS_EX_TOPMOST (ui-focus-not-topmost)",
	_WMPW_FactoryRefusesATopmostWindow)





; ========================================================
; ========================================================
; ======= 3/ Every re-open goes through the helper =======
; ========================================================
; ========================================================

_WMPW_EveryReopenPresentsThroughTheHelper() {
	; Top-level re-open paths and the exact window each must present.
	Sites := Map(
		"_CLW_OpenCapturedRequest", "WMPresentWindow(_CLW_Gui)",
		"Updater_ShowUpdatePrompt", "WMPresentWindow(_Updater_PromptGui)",
		"_LLM_ModelBrowser_ShowWeb", "WMPresentWindow(_LLM_MBW_Gui)",
		"_PathsEdWeb_TryOpen", "WMPresentWindow(_PathsEdWeb_Gui)",
		"_PiEdWeb_TryOpen", "WMPresentWindow(_PiEdWeb_Gui)",
		"LayoutManager_Open", "WMPresentWindow(_LayMgrWeb_Gui)",
		"_PromptEdWeb_TryOpen", "WMPresentWindow(_PromptEdWeb_Gui)",
		"_Onboarding_TryWeb", "WMPresentWindow(_ob_gui)",
		"_HCWWeb_TryOpen", "WMPresentWindow(_HCWWeb_Gui)",
		"_HsEdWeb_TryOpen", "WMPresentWindow(_HsEdWeb_Gui)",
		"OpenHotstringsConfigWindow", "WMPresentWindow(_HCWGui)",
		"KLWV_Focus", 'WMPresentWindow(KLWV.windows[which]["gui"])'
	)
	for Name, Call in Sites {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must exist")
		Assert(InStr(Body, Call) > 0, Name . " must present its open window with " . Call)
		Assert(!RegExMatch(Body, "WinActivate\("),
			Name . " must not re-activate its window with a bare WinActivate: the shared helper restores it and logs a refusal")
	}
	; Class methods are not top-level functions; pin them in the whole source.
	Source := _DriverSourceNoComments()
	Assert(RegExMatch(Source, "WMPresentWindow\(Existing\.Gui\)\R\s*return Existing\b"),
		"WebViewHost.TryOpen must present the existing singleton through WMPresentWindow")
	Assert(InStr(Source, "return WMPresentWindow(Existing.Gui)") > 0,
		"ConfigCleanupWindow.Open must present the open cleanup window through WMPresentWindow")
	Assert(!RegExMatch(Source, "WinActivate\([^\r\n]*\.Hwnd\b"),
		"no driver window may be re-activated with a bare WinActivate on its own Gui handle")
}
Test("windows: every singleton re-open presents through WMPresentWindow (ui-focus-not-topmost)",
	_WMPW_EveryReopenPresentsThroughTheHelper)

/**
 * Checks the real native factories without starting embedded browser processes.
 * Browser attachment does not own captions; both production openers call these.
 */
_WMPW_SharedWindowTitles() {
	global _SharedDir
	Source := JsonParse(FileRead(_SharedDir . "\ui\apps.manifest.json", "UTF-8"))
	Policy := Source["window_title"]
	AssertEqual(Policy["prefix"], WindowTitle(), "an unnamed native window uses the shared product name")
	for Key in ["layout_manager.window_title", "layer_editor.window_title"] {
		Label := t(Key)
		Expected := Policy["prefix"] == "" ? Label : Policy["prefix"] . Policy["separator"] . Label
		if Key == "layout_manager.window_title"
			Window := _LayMgrWeb_NewWindow()
		else {
			Host := WebViewHost()
			Host.Opts := Map("Title", Label)
			Window := Host._NewWindow("900x620")
		}
		try AssertEqual(Expected, Window.Title, "the " . Key . " native factory owns the caption")
		finally Window.Destroy()
	}
	Host := WebViewHost()
	Host.Opts := Map()
	Window := Host._NewWindow("320x200")
	try AssertEqual(Policy["prefix"], Window.Title, "an unnamed WebView host never duplicates branding")
	finally Window.Destroy()
}
Test("windows: layout and navigation windows use the shared caption policy (shared-window-titles)",
	_WMPW_SharedWindowTitles)

/**
 * Runs an exact, tree-owned child and checks receipts after its callback returns.
 * @param {string} Executable - The native executable to launch.
 * @param {Array} Args - Structured child arguments.
 * @returns {string} The successful child's captured stdout.
 */
_WMPW_TitlePolicyChild(Executable, Args) {
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(Executable, Args, OnDone)
	try {
		AssertTrue(Handle.start(), "the private title-policy child must start")
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the private title-policy child must complete exactly once")
		AssertEqual(0, Receipt.Code, "the generated policy must parse and execute: " . Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "the generated policy must produce no native errors")
		return Receipt.Output
	} finally AssertTrue(Handle.terminate(), "the exact title-policy child must be fully retired")
}

/**
 * Uses the actual Node generator and the actual AHK parser in private fixtures.
 * Independent expected captions detect quote, comment and empty-prefix defects.
 */
_WMPW_GeneratedTitlePoliciesExecuteNatively() {
	global _StaticDir
	Root := A_Temp . "\ergopti_window_titles_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the native title-policy fixture must be privately owned")
	DirCreate(Root)
	Cases := [
		{Prefix: "ErgoptiPlus", Separator: " — ", Expected: "ErgoptiPlus — Navigation layer"},
		{Prefix: "", Separator: " — ", Expected: "Navigation layer"},
		{Prefix: "Other product", Separator: ": ", Expected: "Other product: Navigation layer"},
		{Prefix: 'Quoted "product" ``name``', Separator: "", Expected: 'Quoted "product" ``name``Navigation layer'},
		{Prefix: "Other `; product", Separator: " `; ", Expected: "Other `; product `; Navigation layer"}
	]
	try {
		Policies := "["
		for Index, Spec in Cases {
			if Index > 1
				Policies .= ","
			Policies .= '{"prefix":' . JsonStringLiteral(Spec.Prefix)
				. ',"separator":' . JsonStringLiteral(Spec.Separator) . '}'
		}
		FileAppend(Policies . "]", Root . "\policies.json", "UTF-8-RAW")
		Bootstrap := Root . "\generate.cjs"
		FileAppend('const fs = require("node:fs"); const path = require("node:path");' . "`n"
			. 'const root = process.argv[2]; const generator = require(process.argv[3]);' . "`n"
			. 'const policies = require(path.join(root, "policies.json"));' . "`n"
			. 'for (const [index, policy] of policies.entries()) {' . "`n"
			. 'const target = path.join(root, String(index + 1)); const source = path.join(target, generator.SOURCE);' . "`n"
			. 'fs.mkdirSync(path.dirname(source), {recursive:true});' . "`n"
			. 'fs.writeFileSync(source, JSON.stringify({window_title:policy, apps:{}}));' . "`n"
			. 'generator.main(target); } process.stdout.write(String(policies.length));' . "`n",
			Bootstrap, "UTF-8-RAW")
		Generator := _StaticDir . "\..\tools\codegen\codegen-window-titles.cjs"
		AssertEqual("5", _WMPW_TitlePolicyChild("node.exe", [Bootstrap, Root, Generator]),
			"the actual generator must emit every private policy")
		for Index, Spec in Cases {
			Artifact := Root . "\" . Index . "\static\ergopti_plus\windows\_generated\window_titles.ahk"
			AssertTrue(FileExist(Artifact), "the actual generator owns the AHK artifact")
			Harness := Root . "\policy_" . Index . ".ahk"
			FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n"
				. '#Include ' . Artifact . "`n"
				. 'OnError(_WMPWPolicyError)' . "`n"
				. 'OwnedWindow := Gui(, WindowTitle(A_Args[1]))' . "`n"
				. 'FileAppend(OwnedWindow.Title, A_Args[2], "UTF-8-RAW")' . "`n"
				. 'OwnedWindow.Destroy()' . "`n"
				. 'FileAppend("caption-written", "*", "UTF-8-RAW")' . "`nExitApp(0)`n"
				. '_WMPWPolicyError(Err, *) {' . "`n"
				. 'FileAppend(Err.Message, "*", "UTF-8-RAW")' . "`nExitApp(2)`n}`n",
				Harness, "UTF-8")
			Caption := Root . "\caption_" . Index . ".txt"
			AssertEqual("caption-written", _WMPW_TitlePolicyChild(A_AhkPath,
				["/ErrorStdOut", Harness, "Navigation layer", Caption]),
				"the native caption owner acknowledges its private receipt with ASCII stdout")
			AssertEqual(Spec.Expected, FileRead(Caption, "UTF-8"),
				"native AHK executes private title policy " . Index . " without data becoming source")
		}
	} finally DirDelete(Root, true)
}
Test("windows: generated title policies execute with empty, quoted and semicolon prefixes (shared-window-titles)",
	_WMPW_GeneratedTitlePoliciesExecuteNatively)
