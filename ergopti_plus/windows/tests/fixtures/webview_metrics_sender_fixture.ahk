; tests/fixtures/webview_metrics_sender_fixture.ahk

; ==============================================================================
; MODULE: Native Metrics WebView Sender Identity Probe
; DESCRIPTION:
; Owns a real private WebView2 and forwards its unmodified native event directly
; to the production metrics host. Only detached worker creation is substituted.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Warn VarUnset, Off
#Include ../../vendor/ComVar.ahk
#Include ../../vendor/Promise.ahk
#Include ../../vendor/WebView2.ahk
#Include ../../infra/json.ahk
#Include ../../infra/text_utils.ahk
#Include ../../infra/tick_count.ahk
#Include ../../infra/wall_clock.ahk
#Include ../../infra/logger.ahk
#Include ../../infra/hotpath_profiler.ahk
#Include ../../adapters/file_system.ahk
#Include ../../adapters/crypto.ahk
#Include ../../adapters/webview_profiles.ahk
#Include ../../infra/webview_utils.ahk
#Include ../../infra/config_transition.ahk
#Include ../../infra/config_transition_runtime.ahk
#Include ../../infra/reload_terminal_handoff.ahk
#Include ../../modules/keystats/keystats_json.ahk
#Include ../../modules/keystats/keystats_walker_core.ahk
#Include ../../modules/keystats/keystats_prefetch.ahk
#Include ../../modules/keystats/keystats_webview.ahk

class _MVSP_PassiveCoreProbe {
	Reads := 0
	Ptr {
		get {
			this.Reads += 1
			throw Error("A mixed passive view cannot expose a native pointer.")
		}
	}
}

global _MVSP := {Phase: "arguments", Root: "", Profile: "", Gui: 0, Controller: 0,
	View: 0, Sender: 0, HostSubscription: 0, ObserverSubscription: 0, BrowserHandle: 0,
	BrowserPid: 0, BrowserRetired: false, ProfileRetired: false, Closed: false,
	NativeValid: false, Received: false, AsyncError: 0, Calls: 0, Spawns: 0, Starts: 0, Stops: 0, Receipt: Map()}
global _ConfigDir := ""
OnError(_MVSP_Error)
OnExit(_MVSP_Exit)
_MVSP_Main()

_MVSP_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_MVSP_Hash(Path) {
	Hash := CryptoSha256Bytes(FSReadBytesStrict(Path))
	_MVSP_Require(RegExMatch(Hash, "^[0-9a-f]{64}$"), "A native probe source hash was unavailable.")
	return Hash
}

_MVSP_Start(*) {
	global _MVSP
	_MVSP.Starts += 1
	return true
}

_MVSP_Stop(*) {
	global _MVSP
	_MVSP.Stops += 1
	return true
}

; This is the sole substituted production boundary. The real RequestBuild
; still owns reservation, argv serialization, handle admission and cleanup.
_MVSP_Spawn(Executable, Args, Done) {
	global _MVSP
	try return _MVSP_SpawnChecked(Executable, Args, Done)
	catch as Failure {
		; RequestBuild catches launch errors. Preserve a fixture prerequisite
		; failure instead of misclassifying it as a native identity refusal.
		_MVSP_Error(Failure)
		throw Failure
	}
}

_MVSP_SpawnChecked(Executable, Args, Done) {
	global _MVSP
	_MVSP.Spawns += 1
	_MVSP_Require(KLPFWorker.jobs.Has("apps"), "The actual worker reservation was not admitted.")
	Flag := 0
	for Index, Arg in Args
		if Arg == "--keystats-prefetch-worker"
			Flag := Index
	_MVSP_Require(Flag > 0 && Args[Flag + 1] == "apps"
		&& Args[Flag + 2] == _MVSP.Root && Args[Flag + 3] == "full",
		"The real refresh did not retain its native worker arguments.")
	return {start: _MVSP_Start, terminate: _MVSP_Stop}
}

_MVSP_Observe(Sender, Args) {
	global _MVSP
	Message := JsonParse(Args.TryGetWebMessageAsString())
	_MVSP_Require(Message is Map && Message.Get("action", "") == "request_refresh"
		&& Message.Get("probe", "") == _MVSP.Token, "The native observer received an unexpected message.")
	_MVSP.Calls += 1
	_MVSP_Require(_MVSP.Calls == 1, "The private page posted more than one probe action.")
	_MVSP.Sender := Sender
	IUnknown := "{00000000-0000-0000-C000-000000000046}"
	RetainedUnknown := ComObjQuery(_MVSP.View.Ptr, IUnknown)
	CallbackUnknown := ComObjQuery(Sender.Ptr, IUnknown)
	RetainedCore := ComObjQuery(_MVSP.View.Ptr, WebView2.Core.IID)
	CallbackCore := ComObjQuery(Sender.Ptr, WebView2.Core.IID)
	Receipt := _MVSP.Receipt
	Receipt["retained_objptr"] := Format("{:X}", ObjPtr(_MVSP.View))
	Receipt["callback_objptr"] := Format("{:X}", ObjPtr(Sender))
	Receipt["retained_ptr"] := Format("{:X}", _MVSP.View.Ptr)
	Receipt["callback_ptr"] := Format("{:X}", Sender.Ptr)
	Receipt["retained_iunknown"] := Format("{:X}", ComObjValue(RetainedUnknown))
	Receipt["callback_iunknown"] := Format("{:X}", ComObjValue(CallbackUnknown))
	Receipt["retained_core"] := Format("{:X}", ComObjValue(RetainedCore))
	Receipt["callback_core"] := Format("{:X}", ComObjValue(CallbackCore))
	Receipt["ahk_object_equal"] := Sender == _MVSP.View
	Receipt["core_identity_equal"] := ComObjValue(RetainedCore) == ComObjValue(CallbackCore)
	Receipt["iunknown_identity_equal"] := ComObjValue(RetainedUnknown) == ComObjValue(CallbackUnknown)
	Receipt["native_source_equal"] := Args.Source == _MVSP.Url && _MVSP.View.Source == _MVSP.Url
	Receipt["current_epoch"] := KLWV_IsCurrent("apps", 71)
	Receipt["same_entry"] := KLWV.windows.Get("apps", 0) == _MVSP.Entry
	Receipt["not_suspended"] := !A_IsSuspended
	Receipt["sender_class"] := Type(Sender)
	_MVSP_Require(Receipt["core_identity_equal"] && Receipt["iunknown_identity_equal"],
		"The native sender does not represent the retained COM core.")
	_MVSP_Require(Receipt["native_source_equal"] && Receipt["current_epoch"]
		&& Receipt["same_entry"] && Receipt["not_suspended"],
		"The real callback did not satisfy the current document admission premises.")
	_MVSP.NativeValid := true
	_MVSP.ReceivedAt := A_TickCount
	_MVSP.Received := true
}

_MVSP_ObserveOther(Sender, Args) {
	global _MVSP
	Other := _MVSP.Other
	Message := JsonParse(Args.TryGetWebMessageAsString())
	_MVSP_Require(Message is Map && Message.Get("action", "") == "request_refresh"
		&& Message.Get("probe", "") == _MVSP.Token, "The other native core posted an unexpected action.")
	Other.Calls += 1
	_MVSP_Require(Other.Calls == 1, "The other native core must post exactly once.")
	Other.Sender := Sender
	IUnknown := "{00000000-0000-0000-C000-000000000046}"
	CurrentUnknown := ComObjQuery(_MVSP.View.Ptr, IUnknown)
	OtherUnknown := ComObjQuery(Other.View.Ptr, IUnknown)
	CallbackUnknown := ComObjQuery(Sender.Ptr, IUnknown)
	CurrentCore := ComObjQuery(_MVSP.View.Ptr, WebView2.Core.IID)
	OtherCore := ComObjQuery(Other.View.Ptr, WebView2.Core.IID)
	CallbackCore := ComObjQuery(Sender.Ptr, WebView2.Core.IID)
	Receipt := _MVSP.Receipt
	Receipt["other_objptr"] := Format("{:X}", ObjPtr(Other.View))
	Receipt["other_callback_objptr"] := Format("{:X}", ObjPtr(Sender))
	Receipt["other_iunknown"] := Format("{:X}", ComObjValue(OtherUnknown))
	Receipt["other_callback_iunknown"] := Format("{:X}", ComObjValue(CallbackUnknown))
	Receipt["other_current_iunknown"] := Format("{:X}", ComObjValue(CurrentUnknown))
	Receipt["other_core"] := Format("{:X}", ComObjValue(OtherCore))
	Receipt["other_callback_core"] := Format("{:X}", ComObjValue(CallbackCore))
	Receipt["other_current_core"] := Format("{:X}", ComObjValue(CurrentCore))
	Receipt["other_callback_identity_equal"] := ComObjValue(CallbackUnknown) == ComObjValue(OtherUnknown)
		&& ComObjValue(CallbackCore) == ComObjValue(OtherCore)
	Receipt["other_identity_distinct"] := ComObjValue(CallbackUnknown) != ComObjValue(CurrentUnknown)
		&& ComObjValue(CallbackCore) != ComObjValue(CurrentCore)
	Receipt["other_same_url"] := Args.Source == _MVSP.Url && Other.View.Source == _MVSP.Url
		&& _MVSP.View.Source == _MVSP.Url
	Receipt["other_current_entry"] := KLWV_IsCurrent("apps", 71)
		&& KLWV.windows.Get("apps", 0) == _MVSP.Entry && _MVSP.Entry["webview"] == _MVSP.View
	Receipt["other_not_suspended"] := !A_IsSuspended
	_MVSP_Require(Receipt["other_callback_identity_equal"] && Receipt["other_identity_distinct"],
		"The callback must be the genuine other COM core, distinct from the current one.")
	_MVSP_Require(Receipt["other_same_url"] && Receipt["other_current_entry"] && Receipt["other_not_suspended"],
		"The other core must differ only in native identity at the document admission boundary.")
	Other.ReceivedAt := A_TickCount
	Other.Received := true
}

_MVSP_Navigation(State, Sender, Args) {
	_MVSP_Require(Args.IsSuccess, "The actual private document navigation failed.")
	State.Done := true
}

_MVSP_LoadWithoutMessage(View) {
	global _MVSP
	State := {Done: false}
	Subscription := View.NavigationCompleted(_MVSP_Navigation.Bind(State))
	try {
		View.Navigate(_MVSP.Url)
		while !State.Done && !IsObject(_MVSP.AsyncError)
			Sleep(10)
		if IsObject(_MVSP.AsyncError)
			throw _MVSP.AsyncError
		_MVSP_Require(View.Source == _MVSP.Url, "The completed private navigation has a different source.")
	} finally Subscription := 0
}

_MVSP_RunOtherCore() {
	global _MVSP
	_MVSP.Other := {Controller: 0, View: 0, Sender: 0, HostSubscription: 0, ObserverSubscription: 0,
		BrowserHandle: 0, BrowserPid: 0, Received: false, Calls: 0, ControllerClosed: false}
	Other := _MVSP.Other
	_MVSP.Phase := "other-core-controller"
	; Reusing the genuine Environment creates two distinct cores in one private
	; browser. No second profile or duplicate process termination is assumed.
	Other.Controller := WebView2.create(_MVSP.Gui.Hwnd, , _MVSP.View.Environment)
	Other.View := Other.Controller.CoreWebView2
	Other.BrowserPid := Other.View.BrowserProcessId
	if Other.BrowserPid != _MVSP.BrowserPid {
		; Even an unexpected environment/process split needs an exact owner before
		; rejecting this prerequisite. This handle is never opened for the shared PID.
		Other.BrowserHandle := DllCall("OpenProcess", "UInt", 0x100001, "Int", false,
			"UInt", Other.BrowserPid, "Ptr")
		_MVSP_Require(Other.BrowserHandle != 0, "The unexpected second browser could not be supervised.")
	}
	_MVSP_Require(Other.BrowserPid == _MVSP.BrowserPid, "The reused native environment did not share its browser process.")
	Bounds := Buffer(16, 0)
	NumPut("Int", 480, "Int", 320, Bounds, 8)
	Other.Controller.Bounds := Bounds
	Other.Controller.IsVisible := true
	Other.View.SetVirtualHostNameToFolderMapping("ergopti.metrics", _MVSP.Root . "\assets", 1)
	Other.ObserverSubscription := Other.View.WebMessageReceived(_MVSP_ObserveOther)
	Other.HostSubscription := Other.View.WebMessageReceived(KLWV_OnWebMessage.Bind("apps", 71))
	_MVSP_LoadWithoutMessage(_MVSP.View)
	_MVSP_LoadWithoutMessage(Other.View)
	_MVSP_Require(_MVSP.Calls == 0 && Other.Calls == 0 && _MVSP.Spawns == 0,
		"Both actual documents must be ready before either probe action.")
	_MVSP.Phase := "other-core-message"
	Other.View.ExecuteScriptAsync("window.emitProbe()").await()
	while !Other.Received && !IsObject(_MVSP.AsyncError)
		Sleep(10)
	if IsObject(_MVSP.AsyncError)
		throw _MVSP.AsyncError
	; Let the independently subscribed host finish handling the same event. A
	; wrong admission remains a business failure with the measured identities.
	while TickElapsed(Other.ReceivedAt) < 1000
		Sleep(10)
	if IsObject(_MVSP.AsyncError)
		throw _MVSP.AsyncError
	_MVSP.Receipt["other_worker_spawns"] := _MVSP.Spawns
	_MVSP.Receipt["other_worker_reserved"] := KLPFWorker.jobs.Has("apps")
	_MVSP.Receipt["other_native_callbacks"] := Other.Calls
	_MVSP.Receipt["other_browser_pid"] := Other.BrowserPid
	_MVSP.Receipt["shared_browser_process"] := Other.BrowserPid == _MVSP.BrowserPid
	_MVSP_Require(KLPF_CancelBuild("apps"), "An erroneously admitted other-core worker must still retire.")
	Other.BeforePositive := _MVSP.Spawns
	_MVSP.Phase := "current-core-after-other"
	_MVSP.View.ExecuteScriptAsync("window.emitProbe()").await()
}

_MVSP_CloseOther() {
	global _MVSP
	if !_MVSP.HasOwnProp("Other")
		return
	Other := _MVSP.Other
	Other.HostSubscription := 0, Other.ObserverSubscription := 0
	if IsObject(Other.Controller)
		Other.Controller.Close()
	Other.Controller := 0, Other.View := 0, Other.Sender := 0
	Other.ControllerClosed := true
}

_MVSP_RetireOtherBrowser() {
	global _MVSP
	if !_MVSP.HasOwnProp("Other") || !_MVSP.Other.BrowserHandle
		return
	Other := _MVSP.Other
	State := DllCall("WaitForSingleObject", "Ptr", Other.BrowserHandle, "UInt", 0, "UInt")
	if State == 258 {
		_MVSP_Require(DllCall("TerminateProcess", "Ptr", Other.BrowserHandle, "UInt", 0),
			"The unexpected second browser could not be retired.")
		State := DllCall("WaitForSingleObject", "Ptr", Other.BrowserHandle, "UInt", 5000, "UInt")
	}
	_MVSP_Require(State == 0, "The unexpected second browser exit was not observed.")
	DllCall("CloseHandle", "Ptr", Other.BrowserHandle), Other.BrowserHandle := 0
}

_MVSP_Error(Failure, *) {
	global _MVSP
	; Keep asynchronous callback failures separate from a valid host refusal.
	if !IsObject(_MVSP.AsyncError)
		_MVSP.AsyncError := Failure
	_MVSP.Received := true
	return true
}

_MVSP_Deadline() {
	global _MVSP
	FileAppend("Native metrics sender prerequisite deadline at " . _MVSP.Phase . ".`n", "**", "UTF-8-RAW")
	ExitApp(2)
}

_MVSP_Main() {
	global _MVSP, _ConfigDir
	Primary := 0, CleanupError := 0
	try {
		_MVSP_Require(A_Args.Length == 5 || A_Args.Length == 6, "The probe requires five private arguments and at most one exact mode.")
		_MVSP.Mode := A_Args.Length == 6 ? A_Args[6] : ""
		_MVSP_Require(_MVSP.Mode == "" || _MVSP.Mode == "other-core", "The native probe mode is invalid.")
		_MVSP.Root := A_Args[1], _MVSP.Token := A_Args[2]
		_MVSP_Require(RegExMatch(_MVSP.Token, "^[A-Za-z0-9_-]+$"), "The private probe token is invalid.")
		_MVSP_Require(!FSStrictExists(_MVSP.Root), "The probe cannot adopt an existing private destination.")
		FixtureHash := _MVSP_Hash(A_ScriptFullPath)
		HostHash := _MVSP_Hash(A_ScriptDir . "\..\..\modules\keystats\keystats_webview.ahk")
		RuntimeHash := _MVSP_Hash(A_AhkPath)
		_MVSP_Require(FixtureHash == A_Args[3] && HostHash == A_Args[4] && RuntimeHash == A_Args[5],
			"The actual native child sources differ from the parent's launch receipt.")
		_MVSP.Receipt := Map("child_pid", DllCall("GetCurrentProcessId", "UInt"),
			"fixture_sha256", FixtureHash, "host_sha256", HostHash,
			"runtime_sha256", RuntimeHash, "runtime_version", A_AhkVersion,
			"action", "request_refresh", "external_boundary", "worker_spawn_only")
		_MVSP.Phase := "empty-core-controls"
		EmptyCore := WebView2.Core(), OtherEmptyCore := WebView2.Core()
		_MVSP.Receipt["empty_core_same_refused"] := !WebView_SameCore(EmptyCore, EmptyCore)
		_MVSP.Receipt["empty_core_distinct_refused"] := !WebView_SameCore(EmptyCore, OtherEmptyCore)
		_MVSP_Require(_MVSP.Receipt["empty_core_same_refused"] && _MVSP.Receipt["empty_core_distinct_refused"],
			"Real vendor Core wrappers without native pointers must never grant browser identity.")
		Passive := _MVSP_PassiveCoreProbe()
		_MVSP.Receipt["mixed_core_passive_refused"] := !WebView_SameCore(EmptyCore, Passive)
		_MVSP.Receipt["mixed_passive_core_refused"] := !WebView_SameCore(Passive, EmptyCore)
		_MVSP.Receipt["mixed_passive_ptr_reads"] := Passive.Reads
		_MVSP_Require(_MVSP.Receipt["mixed_core_passive_refused"] && _MVSP.Receipt["mixed_passive_core_refused"]
			&& Passive.Reads == 0, "A mixed Core/passive pair must be refused before reading passive pointers.")
		_MVSP.Phase := "private-profile"
		FSCreateDirectoryExclusiveStrict(_MVSP.Root)
		FSCreateDirectoryExclusiveStrict(_MVSP.Root . "\assets")
		_ConfigDir := _MVSP.Root . "\"
		_MVSP.Profile := WebView_NewProfilePath("ergopti_metrics_sender_")
		FSCreateDirectoryExclusiveStrict(_MVSP.Profile)
		_MVSP.Gui := Gui("+ToolWindow", "Native metrics sender probe")
		_MVSP.Gui.Show("w480 h320 NoActivate")
		_MVSP.Phase := "controller"
		SetTimer(_MVSP_Deadline, -30000)
		_MVSP.Controller := WebView2.create(_MVSP.Gui.Hwnd, , 0, _MVSP.Profile, "", 0,
			A_ScriptDir . "\..\..\vendor\64bit\WebView2Loader.dll")
		_MVSP.View := _MVSP.Controller.CoreWebView2
		WebView_WatchProfile(_MVSP.Profile, _MVSP.View)
		_MVSP.BrowserPid := _MVSP.View.BrowserProcessId
		_MVSP.BrowserHandle := DllCall("OpenProcess", "UInt", 0x100001, "Int", false,
			"UInt", _MVSP.BrowserPid, "Ptr")
		_MVSP_Require(_MVSP.BrowserHandle != 0, "The exact owned browser process could not be supervised.")
		Bounds := Buffer(16, 0)
		NumPut("Int", 480, "Int", 320, Bounds, 8)
		_MVSP.Controller.Bounds := Bounds
		_MVSP.Controller.IsVisible := true
		_MVSP.Url := "https://ergopti.metrics/index.html?epoch=71&probe=" . _MVSP.Token
		_MVSP.Entry := Map("epoch", 71, "webview", _MVSP.View, "navigation_url", _MVSP.Url,
			"metrics_dir", _MVSP.Root, "first_paint_done", true, "full_build_done", true)
		KLWV.windows := Map("apps", _MVSP.Entry)
		KLPFWorker.spawn_fn := _MVSP_Spawn
		; The exact production subscription is never wrapped or fed a substituted sender.
		_MVSP.ObserverSubscription := _MVSP.View.WebMessageReceived(_MVSP_Observe)
		_MVSP.HostSubscription := _MVSP.View.WebMessageReceived(KLWV_OnWebMessage.Bind("apps", 71))
		_MVSP.View.SetVirtualHostNameToFolderMapping("ergopti.metrics", _MVSP.Root . "\assets", 1)
		Payload := JsonStringLiteral('{"action":"request_refresh","probe":"' . _MVSP.Token . '"}')
		Html := '<!doctype html><meta charset="utf-8"><title>Owned native sender</title><script>'
			. 'window.addEventListener("DOMContentLoaded",()=>chrome.webview.postMessage(' . Payload . '));</script>'
		if _MVSP.Mode == "other-core"
			Html := '<!doctype html><meta charset="utf-8"><title>Owned native cores</title><script>'
				. 'window.emitProbe=()=>chrome.webview.postMessage(' . Payload . ');</script>'
		_MVSP_Require(FSWriteCreateDurable(_MVSP.Root . "\assets\index.html", Html), "The private native page was not created.")
		_MVSP.Phase := "native-message"
		if _MVSP.Mode == "other-core"
			_MVSP_RunOtherCore()
		else
			_MVSP.View.Navigate(_MVSP.Url)
		while !_MVSP.Received
			Sleep(10)
		if IsObject(_MVSP.AsyncError)
			throw _MVSP.AsyncError
		; The observer is passive and cannot make the host dispatch. Allow the
		; same native event to finish before observing its external launch boundary.
		while _MVSP.Spawns == 0 && TickElapsed(_MVSP.ReceivedAt) < 1000
			Sleep(10)
		if IsObject(_MVSP.AsyncError)
			throw _MVSP.AsyncError
		if _MVSP.Mode == "other-core" {
			while _MVSP.Spawns == _MVSP.Other.BeforePositive && TickElapsed(_MVSP.ReceivedAt) < 1000
				Sleep(10)
			_MVSP.Receipt["primary_worker_spawns"] := _MVSP.Spawns - _MVSP.Other.BeforePositive
		}
		_MVSP_Require(_MVSP.Calls == 1, "The native callback did not settle exactly once.")
		_MVSP.Phase := "retirement"
	} catch as Failure {
		Primary := Failure
	}
	try _MVSP_Close()
	catch as Failure {
		CleanupError := Failure
	}
	if !IsObject(Primary) && IsObject(_MVSP.AsyncError)
		Primary := _MVSP.AsyncError
	if _MVSP.NativeValid {
		if _MVSP.Mode == "other-core"
			_MVSP.Receipt["other_controller_closed"] := _MVSP.Other.ControllerClosed
		_MVSP.Receipt["native_callbacks"] := _MVSP.Calls
		_MVSP.Receipt["worker_spawns"] := _MVSP.Spawns
		_MVSP.Receipt["worker_starts"] := _MVSP.Starts
		_MVSP.Receipt["worker_stops"] := _MVSP.Stops
		_MVSP.Receipt["browser_pid"] := _MVSP.BrowserPid
		_MVSP.Receipt["browser_retired"] := _MVSP.BrowserRetired
		_MVSP.Receipt["profile_retired"] := _MVSP.ProfileRetired
		FileAppend("RECEIPT " . KL_JsonEncode(_MVSP.Receipt) . "`n", "*", "UTF-8-RAW")
	}
	if IsObject(Primary) || IsObject(CleanupError) {
		Failure := IsObject(Primary) ? Primary : CleanupError
		FileAppend("Native metrics sender prerequisite/cleanup failure at " . _MVSP.Phase . ": "
			. Failure.Message . "`n" . Failure.Stack . "`n", "**", "UTF-8-RAW")
		ExitApp(2)
	}
	_MVSP_Require(_MVSP.NativeValid, "No valid native callback was received.")
	if _MVSP.Spawns != 1 || _MVSP.Starts != 1
		|| (_MVSP.Mode == "other-core" && (_MVSP.Receipt["other_worker_spawns"] != 0
			|| _MVSP.Receipt["other_worker_reserved"] || _MVSP.Receipt["primary_worker_spawns"] != 1)) {
		FileAppend("The real metrics host did not admit its current native callback.`n", "**", "UTF-8-RAW")
		ExitApp(1)
	}
	ExitApp(0)
}

_MVSP_Close() {
	global _MVSP
	if _MVSP.Closed
		return
	SetTimer(_MVSP_Deadline, 0)
	_MVSP_CloseOther()
	_MVSP.HostSubscription := 0, _MVSP.ObserverSubscription := 0
	KLWV.windows := Map()
	if _MVSP.HasOwnProp("Entry")
		_MVSP.Entry := 0
	_MVSP_Require(KLPF_CancelBuild("apps"), "The exact probe worker owner did not retire.")
	if _MVSP.Profile != ""
		WebView_RetireProfile(_MVSP.Profile)
	if IsObject(_MVSP.Controller)
		_MVSP.Controller.Close()
	_MVSP.Sender := 0, _MVSP.View := 0, _MVSP.Controller := 0
	_MVSP_RetireOtherBrowser()
	if _MVSP.Gui is Gui
		_MVSP.Gui.Destroy()
	if _MVSP.BrowserHandle {
		State := DllCall("WaitForSingleObject", "Ptr", _MVSP.BrowserHandle, "UInt", 0, "UInt")
		if State == 258 {
			_MVSP_Require(DllCall("TerminateProcess", "Ptr", _MVSP.BrowserHandle, "UInt", 0),
				"The exact private browser could not be terminated.")
			State := DllCall("WaitForSingleObject", "Ptr", _MVSP.BrowserHandle, "UInt", 5000, "UInt")
		}
		_MVSP_Require(State == 0, "The owned browser process exit was not observed.")
		DllCall("CloseHandle", "Ptr", _MVSP.BrowserHandle), _MVSP.BrowserHandle := 0
		_MVSP.BrowserRetired := true
		Started := A_TickCount
		while (DirExist(_MVSP.Profile) || FileExist(_MVSP.Profile . ".retired")) && TickElapsed(Started) < 5000
			Sleep(10)
		_MVSP_Require(!DirExist(_MVSP.Profile) && !FileExist(_MVSP.Profile . ".retired"),
			"The native browser exit did not retire its private profile.")
		_MVSP.ProfileRetired := true
	} else if _MVSP.Profile != "" {
		; A failed controller cannot grant permission to delete an unobserved profile.
		WebView_AbandonProfile(_MVSP.Profile)
	}
	_MVSP.Closed := true
}

_MVSP_Exit(*) {
	try _MVSP_Close()
	catch as Failure
		FileAppend("Exact native browser cleanup remains unacknowledged: " . Failure.Message . "`n", "**", "UTF-8-RAW")
}
