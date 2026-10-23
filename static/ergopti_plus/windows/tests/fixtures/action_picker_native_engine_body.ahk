; tests/fixtures/action_picker_native_engine_body.ahk

; ==============================================================================
; MODULE: Action Picker Installed Engine Child
; DESCRIPTION:
; The public picker and delivered frontend run on the actual installed WebView2.
; A hidden real controller retains the private browser across Close/reopen.
; Catalogue/discovery and logging are passive; no browser/Promise API is replaced.
; ==============================================================================

#Requires AutoHotkey v2.0

_APNR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; The smoke owns no user catalogue, AI settings or external program discovery.
t(Key) => Key
GestureActionPickerItems() => []
GestureActionParameterPrompt(Action) => Action
GestureSendInputErrorText(Kind) => Kind
SendInputVocabularyJson() => "[]"
LLM_Menu_PromptChoices() => []
LLM_Vision_BackendChoices() => []
LLM_Translate_ShippedChoices() => []
GestureClearPickedParameter() => 0
HotPath_Now() => 0
HotPath_LogIfSlow(*) => 0
LoggerTrace(*) => 0
LoggerDone(*) => 0
LoggerSuccess(*) => 0
LoggerDebug(*) => 0
LoggerWarn(*) => _APNR_RecordFailure("A real browser operation reported a warning.")
LoggerError(*) => _APNR_RecordFailure("A real browser operation reported an error.")

Gui_Create(Options := "", Title := "") {
	global _APNR
	Window := Gui(Options, Title)
	_APNR.Windows.Push(Window), _APNR.Hwnds.Push(Window.Hwnd)
	return Window
}

_APNR_RecordFailure(Message) {
	global _APNR
	if !IsObject(_APNR.Failure)
		_APNR.Failure := Error(Message)
}

_APNR_OnError(Failure, *) {
	global _APNR
	if !IsObject(_APNR.Failure)
		_APNR.Failure := Failure is Error ? Failure : Error("An asynchronous browser failure was observed.")
	try FileAppend("DIAG action-picker-native async type=" . Type(Failure) . "`n", "*", "UTF-8-RAW")
	return true
}

_APNR_Timeout() {
	FileAppend("DIAG action-picker-native deadline exceeded`n", "*", "UTF-8-RAW")
	ExitApp(2)
}

_APNR_Hash(Path) => CryptoSha256Bytes(FSReadBytesStrict(Path))

_APNR_CopyAssets() {
	global _APNR, _SharedDir, _APNR_SourceShared
	for Relative in ["ui\action_picker\index.html", "ui\action_picker\script.js", "ui\action_picker\style.css",
		"ui\host_bridge.js", "ui\i18n.js", "data\locales\en.json", "data\locales\fr.json"] {
		Source := _APNR_SourceShared . "\" . Relative, Target := _SharedDir . "\" . Relative
		SplitPath(Target, , &Directory)
		DirCreate(Directory)
		FileCopy(Source, Target, false)
		Hash := _APNR_Hash(Source)
		_APNR_Require(_APNR_Hash(Target) == Hash, "A delivered page asset differs in the private mount.")
		_APNR.Assets[Relative] := Hash
	}
}

_APNR_Confirm(Id) {
	global _APNR
	_APNR_Require(Id == "none", "The actual page must preserve the selected action.")
	_APNR.Confirmed += 1
}

_APNR_Script(View, Script) {
	Pending := View.ExecuteScriptAsync(Script)
	; Keep a rejecting native Promise observed while its genuine await pumps.
	Pending.onSettled((*) => 0, (*) => 0)
	return JsonParse(Pending.await(3000))
}

; Each observed native core proves its environment identity before we retain
; a stable browser handle. A new browser PID is allowed by the real SDK.
_APNR_CaptureBrowser(Core) {
	global _APNR
	_APNR.CaptureDebt += 1
	Unknown := "{00000000-0000-0000-C000-000000000046}"
	Actual := ComObjQuery(Core.Environment.Ptr, Unknown)
	Expected := ComObjQuery(_APNR.Environment.Ptr, Unknown)
	_APNR_Require(ComObjValue(Actual) == ComObjValue(Expected),
		"A picker must belong to the exact environment created with the private profile.")
	Pid := Core.BrowserProcessId
	Handle := DllCall("OpenProcess", "UInt", 0x100001, "Int", false, "UInt", Pid, "Ptr")
	_APNR_Require(Handle != 0, "Capture each actual private browser by stable process handle.")
	try _APNR.Browsers.Push({Pid: Pid, Handle: Handle})
	catch {
		DllCall("CloseHandle", "Ptr", Handle)
		throw
	}
	_APNR.CaptureDebt -= 1
	_APNR.UnobservedBrowser := false
}

_APNR_Page(Title) {
	global _APNR, _ActPickWeb_WebView, _ActPickWeb_Gui, _ActPickWeb_Controller
	global _ActPickWeb_MsgSub, _ActPickWeb_NavSub, _ActPickWeb_SessionEpoch
	_APNR_Require(IsObject(_ActPickWeb_Gui) && IsSet(_ActPickWeb_WebView)
		&& IsSet(_ActPickWeb_Controller) && IsSet(_ActPickWeb_MsgSub) && IsSet(_ActPickWeb_NavSub),
		"The public frontdoor must publish a complete real web picker, not its native fallback.")
	View := _ActPickWeb_WebView, Window := _ActPickWeb_Gui, Epoch := _ActPickWeb_SessionEpoch
	_APNR_CaptureBrowser(View)
	Started := A_TickCount
	loop {
		if IsObject(_APNR.Failure)
			throw _APNR.Failure
		_APNR_Require(_ActPickWeb_Gui == Window && _ActPickWeb_SessionEpoch == Epoch,
			"The document observation must retain its exact session.")
		Data := _APNR_Script(View, "({title:document.getElementById('title')?.textContent||'',"
			. "none:!!document.querySelector('[data-id=none]'),source:location.href})")
		if Data is Map && Data.Get("title", "") == Title && Data.Get("none", false)
			break
		_APNR_Require(((A_TickCount - Started) & 0xFFFFFFFF) < 10000,
			"The actual frontend must render its host init payload and the none row.")
		Sleep(10)
	}
	_APNR_Require(InStr(Data["source"], "https://ergopti.actionpicker/ui/action_picker/index.html?cb=") == 1,
		"The rendered page must be the actual HTTPS virtual-host document.")
	_APNR.Frames.Push(Map("epoch", Epoch, "hwnd", Window.Hwnd, "browser_pid", View.BrowserProcessId,
		"source", Data["source"], "title_match", true, "none_row", true))
	return {Window: Window, Hwnd: Window.Hwnd, Epoch: Epoch, View: View}
}

_APNR_WaitClosed(Frame) {
	global _APNR, _ActPickWeb_SessionEpoch, _ActPickWeb_Gui, _ActPickWeb_ResetDone
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	Started := A_TickCount
	while DllCall("User32\IsWindow", "Ptr", Frame.Hwnd, "Int") || _ActPickWeb_SessionEpoch <= Frame.Epoch {
		if IsObject(_APNR.Failure)
			throw _APNR.Failure
		_APNR_Require(((A_TickCount - Started) & 0xFFFFFFFF) < 3000,
			"The actual Close/confirm callback must destroy its window and revoke the session.")
		Sleep(10)
	}
	_APNR_Require(!IsObject(_ActPickWeb_Gui) && _ActPickWeb_ResetDone
		&& !IsSet(_ActPickWeb_Controller) && !IsSet(_ActPickWeb_WebView)
		&& !IsSet(_ActPickWeb_MsgSub) && !IsSet(_ActPickWeb_NavSub),
		"Physical window closure must also retire all published browser resources.")
}

_APNR_Run() {
	global _APNR, _ActPickWeb_SessionEpoch, _ActPickWeb_Gui
	_APNR.UnobservedBrowser := true
	ShowActionPicker("Private native picker one", "none", _APNR_Confirm)
	First := _APNR_Page("Private native picker one")
	_APNR_Require(_APNR.Windows.Length == 1 && _APNR.Confirmed == 0,
		"The first public open must create exactly one real picker without confirmation.")
	DllCall("User32\SendMessageW", "Ptr", First.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	_APNR_WaitClosed(First)
	_APNR.NativeClose := true
	_APNR_Require(_APNR.Confirmed == 0, "WM_CLOSE must not invoke the selected-action callback.")
	_APNR.UnobservedBrowser := true
	ShowActionPicker("Private native picker two", "none", _APNR_Confirm)
	Second := _APNR_Page("Private native picker two")
	_APNR_Require(_APNR.Windows.Length == 2 && Second.Window != First.Window && Second.Epoch > First.Epoch,
		"Reopen must create a new real window/session, without native fallback.")
	; A real page click crosses the shipped bridge; no native handler is invoked
	; directly. This is DOM interaction, not physical mouse/keyboard input.
	Pending := Second.View.ExecuteScriptAsync("document.querySelector('[data-id=none]').click();true")
	Pending.onSettled((*) => 0, (*) => 0)
	; Do not await this script: its real confirm callback closes the target page.
	_APNR_WaitClosed(Second)
	_APNR_Require(_APNR.Confirmed == 1, "Only the reopened page may confirm exactly once.")
	_APNR.ReopenedConfirmed := true
}

_APNR_Close(*) {
	global _APNR, _WebView_SharedEnv, _WebView_SharedEnvRetired
	if _APNR.Closed
		return
	Primary := 0
	try _ActPickWeb_Close()
	catch as Failure
		Primary := Failure
	; Always attempt every acquired HWND, even if logical close refused.
	for Index, Window in _APNR.Windows {
		try {
			if DllCall("User32\IsWindow", "Ptr", _APNR.Hwnds[Index], "Int")
				Window.Destroy()
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
	}
	try {
		if IsObject(_APNR.Keeper)
			_APNR.Keeper.Close()
	} catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	_APNR.Keeper := 0
	_WebView_SharedEnvRetired := true
	_WebView_SharedEnv := 0
	_APNR.Environment := 0
	try {
		if IsObject(_APNR.KeeperGui)
			_APNR.KeeperGui.Destroy()
	} catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	_APNR.KeeperGui := 0
	_APNR.BrowserRetired := _APNR.Browsers.Length > 0 && !_APNR.UnobservedBrowser && _APNR.CaptureDebt == 0
	for Browser in _APNR.Browsers {
		try {
			State := DllCall("WaitForSingleObject", "Ptr", Browser.Handle, "UInt", 0, "UInt")
			if State == 258 {
				_APNR_Require(DllCall("TerminateProcess", "Ptr", Browser.Handle, "UInt", 0),
					"The exact retained private browser handle must retire.")
				State := DllCall("WaitForSingleObject", "Ptr", Browser.Handle, "UInt", 5000, "UInt")
			}
			_APNR_Require(State == 0, "Every captured private browser process exit must be observed.")
		} catch as Failure {
			_APNR.BrowserRetired := false
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if Browser.Handle
				DllCall("CloseHandle", "Ptr", Browser.Handle)
			Browser.Handle := 0
		}
	}
	; No profile deletion is authorized until every captured browser exited.
	if _APNR.BrowserRetired && _APNR.ProfileOwned
		WebView_RetireProfile(_APNR.Profile)
	; An attached exit watcher covers its initial PID only. AbandonProfile would
	; retire that watched owner, so it cannot preserve a later unobserved browser.
	; Keep the profile unretired on capture debt or unproven creation instead.
	if _APNR.BrowserRetired {
		Started := A_TickCount
		while (DirExist(_APNR.Profile) || FileExist(_APNR.Profile . ".retired"))
				&& ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(10)
		_APNR.ProfileRetired := !DirExist(_APNR.Profile) && !FileExist(_APNR.Profile . ".retired")
	}
	_APNR.Closed := true
	try FileAppend("DIAG action-picker-native cleanup handles=" . _APNR.Browsers.Length
		. " capture_debt=" . _APNR.CaptureDebt . " unobserved=" . _APNR.UnobservedBrowser
		. " profile_owned=" . _APNR.ProfileOwned . " browser_retired=" . _APNR.BrowserRetired
		. " profile_retired=" . _APNR.ProfileRetired . "`n", "*", "UTF-8-RAW")
	catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	if IsObject(Primary)
		throw Primary
	_APNR_Require(_APNR.BrowserRetired && _APNR.ProfileRetired,
		"A pass requires both captured browser exit and private profile retirement.")
}

_APNR_Main() {
	global _APNR, _VendorDir, _SharedDir, _APNR_Driver, WEBVIEW_SHARED_UDIR, _ActPickWeb_ProgramCapturing
	global _I18nLocale := "en", _LLM_Menu := Map("n_predictions", 3)
	if A_Args.Length != 3
		ExitApp(2)
	Persistent(true)
	_APNR := {Root: A_Args[1], Failure: 0, Windows: [], Hwnds: [], KeeperGui: 0, Keeper: 0, Environment: 0, BrowserVersion: "", PrivateFolder: false,
		Browsers: [], BrowserPid: 0, BrowserRetired: false, ProfileRetired: false, Profile: "", ProfileOwned: false, CaptureDebt: 0, UnobservedBrowser: false,
		Closed: false, Confirmed: 0, NativeClose: false, ReopenedConfirmed: false, Frames: [], Assets: Map()}
	OnError(_APNR_OnError)
	OnExit(_APNR_Close)
	Primary := 0
	try {
		_APNR_Require(_APNR_Hash(A_ScriptFullPath) == A_Args[2] && _APNR_Hash(A_AhkPath) == A_Args[3],
			"The child source and interpreter must match the launcher's measured inputs.")
		_APNR_CopyAssets()
		_VendorDir := _APNR_Driver . "\vendor"
		_APNR.Profile := WebView_NewProfilePath("ergopti_action_picker_native_")
		FSCreateDirectoryExclusiveStrict(_APNR.Profile)
		_APNR.ProfileOwned := true
		WEBVIEW_SHARED_UDIR := _APNR.Profile
		_ActPickWeb_ProgramCapturing := true
		SetTimer(_APNR_Timeout, -60000)
		_APNR.UnobservedBrowser := true
		Environment := WebView_SharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll")
		_APNR.BrowserVersion := Environment.BrowserVersionString
		_APNR.PrivateFolder := StrCompare(RTrim(Environment.UserDataFolder, "\"), RTrim(_APNR.Profile, "\"), false) == 0
		_APNR_Require(_APNR.PrivateFolder && _APNR.BrowserVersion != "",
			"The real installed environment must report the exact private profile and browser version.")
		_APNR.KeeperGui := Gui("+ToolWindow -Caption")
		_APNR.Keeper := WebView2.create(_APNR.KeeperGui.Hwnd, , Environment)
		_APNR.Keeper.IsVisible := false
		Core := _APNR.Keeper.CoreWebView2
		_APNR.BrowserPid := Core.BrowserProcessId
		_APNR.Environment := Core.Environment
		_APNR_CaptureBrowser(Core)
		WebView_WatchProfile(_APNR.Profile, Core)
		Core := 0, Environment := 0
		_APNR_Run()
	} catch as Failure {
		Primary := Failure
	} finally {
		SetTimer(_APNR_Timeout, 0)
		try _APNR_Close()
		catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnExit(_APNR_Close, 0)
		OnError(_APNR_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_APNR.Failure)
		Primary := _APNR.Failure
	if IsObject(Primary) {
		FileAppend("FAIL action-picker-native " . Primary.Message . "`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	Receipt := Map("child_pid", DllCall("GetCurrentProcessId"), "source_sha256", A_Args[2], "runtime_sha256", A_Args[3],
		"browser_handles", _APNR.Browsers.Length, "browser_pid", _APNR.BrowserPid, "browser_retired", _APNR.BrowserRetired, "profile_retired", _APNR.ProfileRetired,
		"native_close", _APNR.NativeClose, "reopened_confirmed", _APNR.ReopenedConfirmed,
		"private_folder", _APNR.PrivateFolder, "browser_version", _APNR.BrowserVersion, "windows", _APNR.Windows.Length, "confirmed", _APNR.Confirmed, "frames", _APNR.Frames, "assets", _APNR.Assets)
	FileAppend("RECEIPT action-picker-native " . KL_JsonEncode(Receipt) . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_APNR_Main()
