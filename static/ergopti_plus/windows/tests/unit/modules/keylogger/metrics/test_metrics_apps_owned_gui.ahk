; tests/unit/modules/keylogger/metrics/test_metrics_apps_owned_gui.ahk

; ==============================================================================
; MODULE: Apps Editor Owned Native GUI Tests
; DESCRIPTION:
; Exercises real prompt and picker HWNDs without replacing their UI ports.
; A passive WebView boundary and the sibling's native file-receipt helpers keep
; the test independent of controller creation and arbitrary process launch.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MAOG_Controller {
	__New() {
		this.Closed := 0, this.IsVisible := true
	}
	Close() {
		this.Closed += 1
	}
}

class _MAOG_View {
	__New(World) {
		this.World := World
	}
	Source {
		get {
			World := this.World
			if InStr(World.Mode, "picker-before-") == 1 && !World.SawNative {
				Request := World.Entry.Get("apps_editor_request", 0)
				NativeGui := Request is Map ? Request.Get("native_gui", 0) : 0
				if NativeGui is Gui {
					_MAOG_Record(World, NativeGui, Request["receipt"])
					World.BeforeShow := !DllCall("IsWindowVisible", "Ptr", World.Hwnd, "Int")
					_MAOG_RetirePage(World)
				}
			}
			return World.Url
		}
	}
}

_MAOG_Record(World, NativeGui, Receipt := 0) {
	World.NativeGui := NativeGui, World.Hwnd := NativeGui.Hwnd
	World.Receipt := Receipt, World.SawNative := true
	World.Guis.Push(NativeGui)
}

_MAOG_RetirePage(World) {
	if InStr(World.Mode, "hide")
		KLWV_Hide("apps", World.Parent)
	else
		KLWV_Close("apps")
}

; Observe only the exact request-owned surface. The one-shot action requires
; native visibility; no input is injected into another application or thread.
_MAOG_Shown(World, WParam, LParam, Message, Hwnd) {
	if !WParam
		return
	if InStr(World.Mode, "generic-") == 1 || InStr(World.Mode, "picker-before-") == 1 {
		if Hwnd == World.Hwnd
			World.Shown.Push(Hwnd)
		return
	}
	Request := World.Entry.Get("apps_editor_request", 0)
	NativeGui := Request is Map ? Request.Get("native_gui", 0) : 0
	if !(NativeGui is Gui)
		return
	try OwnedHwnd := NativeGui.Hwnd
	catch
		return
	if OwnedHwnd != Hwnd
		return
	_MAOG_Record(World, NativeGui, Request.Get("receipt", 0))
	World.Shown.Push(Hwnd)
	SetTimer(World.Action, -1)
}

_MAOG_Act(World) {
	try {
		Hwnd := World.Hwnd
		AssertTrue(WMHandleExists(Hwnd), "the native action requires the real owned HWND")
		AssertTrue(DllCall("IsWindowVisible", "Ptr", Hwnd, "Int"), "the actual prompt or picker must be visible")
		if World.Mode == "prompt-confirm-cancel" {
			if World.Shown.Length == 1 {
				ControlSetText("Native category 😀", "Edit1", "ahk_id " . Hwnd)
				AssertEqual("Native category 😀", ControlGetText("Edit1", "ahk_id " . Hwnd))
				ControlClick("Button1", "ahk_id " . Hwnd)
			} else {
				AssertEqual(2, World.Shown.Length, "accepting the category must reach exactly one real score prompt")
				AssertEqual("0", ControlGetText("Edit1", "ahk_id " . Hwnd))
				ControlClick("Button2", "ahk_id " . Hwnd)
			}
		} else if World.Mode == "picker-cancel" {
			ControlClick("Button2", "ahk_id " . Hwnd)
		} else {
			_MAOG_RetirePage(World)
		}
	} catch as Failure {
		World.Failure := Failure
		if KLWV.windows.Get("apps", 0) == World.Entry
			KLWV_Close("apps")
	}
}

_MAOG_Deadline(World) {
	if !IsObject(World.Failure)
		World.Failure := Error("The owned native UI did not complete before its fixture deadline.")
	if KLWV.windows.Get("apps", 0) == World.Entry
		KLWV_Close("apps")
}

_MAOG_SpawnUnexpected(World, *) {
	World.Spawns += 1
	throw Error("A canceled native editor must not launch a projection process.")
}

_MAOG_SaveUnexpected(*) {
	throw Error("A physical GUI retirement control must not confirm a category.")
}

_MAOG_SuccessorOpened(World, NativeGui, Receipt) {
	World.SuccessorGui := NativeGui, World.SuccessorReceipt := Receipt
	return true
}

_MAOG_Open(World, NativeGui, Receipt) {
	_MAOG_Record(World, NativeGui, Receipt)
	World.BeforeShow := !DllCall("IsWindowVisible", "Ptr", World.Hwnd, "Int")
	if World.Mode == "generic-throw"
		throw Error("owned GUI open refusal")
	if World.Mode == "generic-successor" {
		World.SuccessorReceipt := AppPicker_Show(Map("owner", "metrics:app-categories",
			"title", "Owned native successor", "prompt", "Fixture successor", "initial", [],
			"on_save", _MAOG_SaveUnexpected, "on_open", _MAOG_SuccessorOpened.Bind(World)))
		return true
	}
	return false
}

_MAOG_Generic(World) {
	global _AppPickerActiveReceipts
	Caught := 0, Result := 0
	try Result := AppPicker_Show(Map("owner", "metrics:app-categories",
		"title", "Owned native picker", "prompt", "Fixture picker", "initial", [],
		"on_save", _MAOG_SaveUnexpected, "on_open", _MAOG_Open.Bind(World)))
	catch as Failure {
		Caught := Failure
	}
	if World.Mode == "generic-throw" {
		AssertTrue(IsObject(Caught), "the real generic picker must preserve a failing open callback")
		AssertEqual("owned GUI open refusal", Caught.Message)
	} else {
		if IsObject(Caught)
			throw Caught
		AssertFalse(Result, "a refused or superseded native picker cannot be shown")
	}
	AssertTrue(World.SawNative && World.BeforeShow, "the callback must receive a genuine still-hidden native GUI")
	AssertFalse(WMHandleExists(World.Hwnd), "the exact refused GUI must be destroyed")
	AssertEqual(0, World.Shown.Length, "the refused old picker must never become visible")
	AssertEqual("retired", World.Receipt["state"])
	if World.Mode == "generic-successor" {
		AssertTrue(World.SuccessorReceipt is Map)
		AssertTrue(WMHandleExists(World.SuccessorGui.Hwnd), "cleanup must preserve the actual successor GUI")
		AssertTrue(DllCall("IsWindowVisible", "Ptr", World.SuccessorGui.Hwnd, "Int"))
		AssertEqual("open", World.SuccessorReceipt["state"], "old cleanup cannot retire the new receipt")
		AssertTrue(_AppPickerActiveReceipts.Get("metrics:app-categories", 0) == World.SuccessorReceipt)
	}
}

_MAOG_Exercise(World) {
	if InStr(World.Mode, "generic-") == 1 {
		_MAOG_Generic(World)
		return
	}
	Action := InStr(World.Mode, "picker-") == 1 ? "pick" : "edit"
	Message := Action == "pick" ? '{"action":"pick"}'
		: '{"action":"edit","app":"audit.exe","cat":"unconfirmed","score":2}'
	KLWV_OnWebMessage("apps", 81, World.View,
		{Source: World.Url, TryGetWebMessageAsString: (*) => Message})
	Started := A_TickCount
	loop {
		if IsObject(World.Failure)
			throw World.Failure
		Request := World.Entry.Get("apps_editor_request", 0)
		if World.SawNative && (!(Request is Map)
				|| (World.Mode == "picker-cancel" && World.Receipt is Map
					&& World.Receipt["state"] == "retired" && !WMHandleExists(World.Hwnd)))
			break
		if A_TickCount - Started >= 6000
			throw Error("The real apps editor did not retire its native surface.")
		Sleep(10)
	}
	AssertTrue(World.SawNative, "the action must reach the genuine native UI without an input/picker port")
	AssertFalse(WMHandleExists(World.Hwnd), "the exact owned UI must be gone after retirement or cancel")
	if InStr(World.Mode, "picker-before-") == 1 {
		AssertTrue(World.BeforeShow, "source reentry must retire the picker before Show")
		AssertEqual(0, World.Shown.Length, "a destroyed picker cannot be shown again")
	} else if World.Mode == "prompt-confirm-cancel" {
		AssertEqual(2, World.Shown.Length, "real category confirmation must reach the real score control")
	} else {
		AssertEqual(1, World.Shown.Length)
	}
	if InStr(World.Mode, "hide") {
		AssertTrue(WMHandleExists(World.ParentHwnd), "Hide must retain the native dashboard host")
		AssertFalse(DllCall("IsWindowVisible", "Ptr", World.ParentHwnd, "Int"))
	} else if InStr(World.Mode, "close") {
		AssertFalse(WMHandleExists(World.ParentHwnd), "Close must release the actual dashboard host")
	}
}

_MAOG_Case(Mode) {
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts
	static Serial := 0
	PreviousCritical := Critical("On")
	SavedCategory := Map()
	for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"]
		if KLAppCat.HasOwnProp(Key)
			SavedCategory[Key] := KLAppCat.%Key%
	Saved := {Windows: KLWV.windows, Warm: KLWV.warm_hosts, Retiring: KLWV.retiring,
		Opening: KLWV.opening, Jobs: KLPFWorker.jobs, Generation: KLPFWorker.generation,
		Spawn: KLPFWorker.spawn_fn, FullTimer: KLWV.full_build_timer_fn, PickerEpochs: _AppPickerOwnerEpochs, PickerReceipts: _AppPickerActiveReceipts}
	Root := A_Temp . "\ergopti_apps_native_gui_" . A_ScriptHwnd . "_" . ++Serial
	World := {Mode: Mode, Root: Root, Path: Root . "\" . KLAppCatConst.FILE_NAME,
		Url: "https://ergopti.metrics/ui/metrics_apps/index.html?native_owned=81",
		Failure: 0, SawNative: false, BeforeShow: false, NativeGui: 0, Receipt: 0,
		Hwnd: 0, Spawns: 0, RetryTimers: [], Guis: [], Shown: [], SuccessorGui: 0, SuccessorReceipt: 0}
	World.Action := _MAOG_Act.Bind(World), Deadline := _MAOG_Deadline.Bind(World)
	Monitor := _MAOG_Shown.Bind(World), Timer := (*) => 0
	Owned := false, Installed := false, Primary := 0, CleanupError := 0, Hooked := false
	Original := '{"audit.exe":"productive"}' . "`n"
	try {
		AssertFalse(A_IsSuspended, "native UI controls cannot borrow a suspended driver's admission")
		AssertTrue(SavedCategory.Get("write_owner", 0) is Integer && SavedCategory.Get("write_owner", 0) == 0)
		if SavedCategory.Has("save_fn") && IsObject(SavedCategory["save_fn"])
			SetTimer(SavedCategory["save_fn"], 0)
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		AssertTrue(FSWriteCreateDurable(World.Path, Original))
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
		KLAppCat.save_fn := Timer
		if KLAppCat.HasOwnProp("write_owner")
			KLAppCat.write_owner := 0
		AssertTrue(KL_AppCat_Init(Root))
		World.FileReceipt := _MAE_FileSnapshot(World.Path)
		World.Parent := Gui_Create("", "Apps native UI fixture")
		World.Foreign := Gui_Create("", "Unrelated native UI fixture")
		World.ParentHwnd := World.Parent.Hwnd, World.ForeignHwnd := World.Foreign.Hwnd
		World.Parent.Show("w260 h100 NoActivate"), World.Foreign.Show("Hide")
		World.Controller := _MAOG_Controller(), World.View := _MAOG_View(World)
		World.Entry := Map("epoch", 81, "webview", World.View, "navigation_url", World.Url,
			"metrics_dir", Root, "gui", World.Parent, "controller", World.Controller,
			"udir", "", "reuse_key", "owned-native-fixture")
		KLWV.windows := Map("apps", World.Entry), KLWV.warm_hosts := Map()
		KLWV.retiring := Map(), KLWV.opening := Map(), Installed := true
		KLPFWorker.jobs := Map(), KLPFWorker.spawn_fn := _MAOG_SpawnUnexpected.Bind(World)
		KLWV.full_build_timer_fn := (Callback, Period) => World.RetryTimers.Push(Callback)
		_AppPickerOwnerEpochs := Map(), _AppPickerActiveReceipts := Map()
		OnMessage(0x18, Monitor), Hooked := true
		SetTimer(Deadline, -5000)
		Critical("Off")
		_MAOG_Exercise(World)
		Critical("On")
		AssertTrue(WMHandleExists(World.ForeignHwnd), "retirement must never destroy an unrelated GUI")
		AssertTrue(FSUtf8ExactMatches(World.Path, Original), "cancel and teardown cannot publish a late category edit")
		AssertTrue(_MAE_SameFile(World.FileReceipt, World.Path), "no replacement may be hidden behind equal source bytes")
		AssertEqual("productive", KL_AppCat_Get("audit.exe"))
		AssertEqual(0, World.Spawns, "unconfirmed native UI work cannot launch a projection")
		Loop Files, World.Path . ".*.tmp"
			AssertFalse(true, "cancellation must not leave a category stage")
	} catch as Failure {
		Primary := Failure
	} finally {
		Critical("On")
		try {
			SetTimer(Deadline, 0), SetTimer(World.Action, 0), SetTimer(Timer, 0)
			if Hooked
				OnMessage(0x18, Monitor, 0)
			if Installed {
				KLWV_CloseAll()
				AssertTrue(KLPF_CancelBuild("apps"))
			}
			for Callback in World.RetryTimers
				SetTimer(Callback, 0)
			for NativeGui in World.Guis
				NativeGui.Destroy()
			if World.SuccessorGui is Gui
				World.SuccessorGui.Destroy()
			if World.SuccessorReceipt is Map
				AppPicker_RetireReceipt(World.SuccessorReceipt)
			if World.HasOwnProp("Parent")
				World.Parent.Destroy()
			if World.HasOwnProp("Foreign")
				World.Foreign.Destroy()
		} catch as Failure {
			CleanupError := Failure
		} finally {
			for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"] {
				if SavedCategory.Has(Key)
					KLAppCat.%Key% := SavedCategory[Key]
				else if KLAppCat.HasOwnProp(Key)
					KLAppCat.DeleteProp(Key)
			}
			KLWV.windows := Saved.Windows, KLWV.warm_hosts := Saved.Warm
			KLWV.retiring := Saved.Retiring, KLWV.opening := Saved.Opening
			KLPFWorker.jobs := Saved.Jobs, KLPFWorker.generation := Saved.Generation
			KLPFWorker.spawn_fn := Saved.Spawn, KLWV.full_build_timer_fn := Saved.FullTimer
			_AppPickerOwnerEpochs := Saved.PickerEpochs, _AppPickerActiveReceipts := Saved.PickerReceipts
			if SavedCategory.Get("dirty", false) && SavedCategory.Has("save_fn")
					&& IsObject(SavedCategory["save_fn"])
				_KL_AppCat_ScheduleDeferredSave()
			World.Guis.Length := 0, World.RetryTimers.Length := 0, World.Action := 0
			if World.HasOwnProp("View")
				World.View.World := 0
			Critical(PreviousCritical)
		}
		if Owned {
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for _MAOG_Mode in ["prompt-close", "prompt-hide", "prompt-confirm-cancel", "picker-before-close",
	"picker-before-hide", "picker-cancel", "generic-false", "generic-throw", "generic-successor"]
	Test("Apps owned native UI: " . _MAOG_Mode . " retires its exact HWND (metrics-apps-owned-native-ui)",
		_MAOG_Case.Bind(_MAOG_Mode))
