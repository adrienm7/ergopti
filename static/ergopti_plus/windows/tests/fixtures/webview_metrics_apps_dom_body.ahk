; tests/fixtures/webview_metrics_apps_dom_body.ahk

; ==============================================================================
; MODULE: Native Apps DOM Integration Body
; DESCRIPTION:
; Actual shared DOM actions, owned native dialogs, durable categories and detached
; production projection workers. This does not boot the full resident driver.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MVSP := {Phase: "initialization", Root: _MAD_Root, Profile: "", Gui: 0, Controller: 0,
	View: 0, Sender: 0, HostSubscription: 0, ObserverSubscription: 0, BrowserHandle: 0,
	BrowserPid: 0, BrowserRetired: false, ProfileRetired: false, Closed: false}
global _MAD := {Failure: 0, Closed: false, Actors: Map(), Hwnds: [], Messages: [], NativeFrames: [],
	Inputs: 0, Pickers: 0, ButtonReceipts: [], Action: "", WorkerRole: false, AssetHashes: Map()}
OnError(_MAD_InitializationError, 0)
OnError(_MAD_Error)
OnExit(_MAD_Close)
if KLPF_IsWorkerInvocation()
	_MAD_Worker()
_MAD_Main()

_MAD_InitializationError(Failure, *) {
	FileAppend("Apps integration initialization failed: " . Failure.Message . "`n" . Failure.Stack . "`n", "**", "UTF-8-RAW")
	ExitApp(2)
	return true
}

_MAD_Error(Failure, *) {
	global _MAD
	if _MAD.WorkerRole
		return _MAD_InitializationError(Failure)
	if !IsObject(_MAD.Failure)
		_MAD.Failure := Failure
	SetTimer(_MAD_RetirePrompt, -1)
	return true
}

_MAD_Deadline() {
	global _MVSP
	FileAppend("Native Apps integration deadline at " . _MVSP.Phase . ".`n", "**", "UTF-8-RAW")
	ExitApp(2)
}

_MAD_Check() {
	global _MAD
	if IsObject(_MAD.Failure)
		throw _MAD.Failure
}

_MAD_Worker() {
	global _MAD, _MAD_Root, _MAD_ExpectedRoot
	_MAD.WorkerRole := true
	Flag := KLPF_WorkerFlagIndex()
	_MVSP_Require(A_Args.Length >= Flag + 11 && A_Args[Flag + 1] == "apps"
		&& _MAD_Root == _MAD_ExpectedRoot && A_Args[Flag + 2] == _MAD_Root && A_Args[Flag + 3] == "full"
		&& A_Args[Flag + 5] == _MAD_Root . "\config\",
		"Only the canonical private apps/full worker ABI is admitted.")
	_MAD.WorkerStage := A_Args[Flag + 4]
	Prefix := KLPF_PrefetchPath("apps", _MAD_Root) . ".stage."
	_MVSP_Require(InStr(_MAD.WorkerStage, Prefix, true) == 1
		&& RegExMatch(SubStr(_MAD.WorkerStage, StrLen(Prefix) + 1),
			"^[1-9]\d*\.[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.[1-9]\d*$"),
		"The genuine worker must retain the private scheduler stage namespace.")
	OnExit(_MAD_WorkerReceipt)
	; The actual function decodes timing argv, rebuilds SQLite, serializes its
	; real stage and exits. No copy of the production entry/body or fake process.
	KLPF_WorkerMain()
	throw Error("The genuine worker unexpectedly returned.")
}

_MAD_WorkerReceipt(Reason, Code) {
	global _MAD, _MAD_Root
	try {
		Receipt := Map("pid", DllCall("GetCurrentProcessId", "UInt"), "exit_code", Code,
			"script_sha256", _MVSP_Hash(A_ScriptFullPath), "runtime_sha256", _MVSP_Hash(A_AhkPath),
			"stage", _MAD.WorkerStage, "stage_sha256", _MVSP_Hash(_MAD.WorkerStage),
			"worker_main", "KLPF_WorkerMain", "timings", KLW_TimingValues(),
			"root", _MAD_Root, "config_dir", A_Args[KLPF_WorkerFlagIndex() + 5],
			"mode", A_Args[KLPF_WorkerFlagIndex() + 3])
		Path := _MAD_Root . "\native-workers\" . CryptoSha256(_MAD.WorkerStage) . ".json"
		_MVSP_Require(FSWriteCreateDurable(Path, KL_JsonEncode(Receipt)), "The real worker exit receipt could not be published.")
	} catch as Failure {
		FileAppend("Actual worker receipt failed: " . Failure.Message . "`n", "**", "UTF-8-RAW")
	}
}

_MAD_CopyShared() {
	global _MAD, _MAD_Root, _MAD_SourceShared, _SharedDir
	for Relative in ["ui\metrics_apps\index.html", "ui\metrics_apps\style.css", "ui\metrics_apps\helpers.js",
		"ui\metrics_apps\state.js", "ui\metrics_apps\main.js", "ui\metrics_apps\charts.js", "ui\metrics_apps\modal.js",
		"ui\vendor\chart.umd.js", "ui\host_bridge.js", "ui\dom_utils.js", "ui\i18n.js", "ui\metrics_rebuild_banner.js",
		"data\locales\fr.json", "data\locales\en.json", "data\db\schema.sql", "data\db\media_schema.sql",
		"modules\diagnostics\redaction.json", "modules\timings\constants.toml"] {
		Source := _MAD_SourceShared . "\" . Relative, Destination := _SharedDir . "\" . Relative
		SplitPath(Destination, , &Directory)
		DirCreate(Directory)
		FileCopy(Source, Destination, false)
		Hash := _MVSP_Hash(Source)
		_MVSP_Require(_MVSP_Hash(Destination) == Hash, "A private shared asset differs from its actual source: " . Relative)
		_MAD.AssetHashes[Relative] := Hash
	}
	for Directory in ["config", "logs", "native-workers", "by_device\owned"]
		DirCreate(_MAD_Root . "\" . Directory)
}

_MAD_SeedLedger(App) {
	global _MAD_Root
	Day := FormatTime(, "yyyy-MM-dd"), Stamp := Day . "T" . FormatTime(, "HH:mm:ss") . ".000"
	Events := []
	loop 12
		Events.Push([Chr(96 + A_Index), 120, Map("kc", 65, "sk", 30)])
	; Independent synthetic data has the canonical writer's transaction shape.
	Sql := "-- ergopti metrics — device owned — schema_version 1`n"
		. "PRAGMA foreign_keys = OFF;`n-- === ingest batch " . Stamp . " (offset 0 -> 0, 1 entry(ies)) ===`n"
		. "BEGIN TRANSACTION;`nINSERT OR IGNORE INTO events_typing (device_id,id,ts,date,app,app_category,"
		. "title,url,field_role,layout,document_path,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,"
		. "mouse_distance_px,pause_before_ms,battery_level,audio_volume,wpm,text,rich_text,events_json) VALUES "
		. "('owned',1," . SQLite_Q(Stamp) . "," . SQLite_Q(Day) . "," . SQLite_Q(App)
		. ",'neutral',NULL,NULL,NULL,NULL,NULL,0,0,0,0,0,150,NULL,NULL,120.0,'abcdefghijkl',NULL,"
		. SQLite_Q(KL_JsonEncode(Events)) . ");`nCOMMIT;`n"
	_MVSP_Require(FSWriteCreateDurable(_MAD_Root . "\by_device\owned\data.sql", Sql), "The private source ledger must be created once.")
}

_MAD_Message(Sender, Args) {
	global _MAD, _MVSP
	Payload := JsonParse(Args.TryGetWebMessageAsString())
	if !(Payload is Map) || !Payload.Has("action")
		return
	Action := Payload["action"]
	if Action != "ready" && Action != "pick" && Action != "edit"
		return
	Unknown := "{00000000-0000-0000-C000-000000000046}"
	Expected := ComObjQuery(_MVSP.View.Ptr, Unknown), Observed := ComObjQuery(Sender.Ptr, Unknown)
	_MVSP_Require(ComObjValue(Expected) == ComObjValue(Observed) && Args.Source == _MAD.Url
		&& _MVSP.View.Source == _MAD.Url && KLWV.windows.Get("apps", 0) == _MAD.Entry
		&& KLWV_IsCurrent("apps", 61) && !A_IsSuspended, "The real Apps callback has no current native document owner.")
	_MAD.Messages.Push(Payload)
	_MAD.NativeFrames.Push(Map("action", Action, "callback_objptr", Format("{:X}", ObjPtr(Sender)),
		"retained_objptr", Format("{:X}", ObjPtr(_MVSP.View)), "callback_iunknown", Format("{:X}", ComObjValue(Observed)),
		"retained_iunknown", Format("{:X}", ComObjValue(Expected)), "source", Args.Source, "epoch", 61))
}

_MAD_RetirePrompt() {
	global _MAD
	if !_MAD.HasOwnProp("Entry") || !(_MAD.Entry is Map)
		return
	KLWV_RetireAppsEditor(_MAD.Entry)
}

_MAD_Act() {
	global _MAD
	try {
		if _MAD.Action == ""
			return
		Request := _MAD.Entry.Get("apps_editor_request", 0)
		NativeGui := Request is Map ? Request.Get("native_gui", 0) : 0
		if !(NativeGui is Gui) || _MAD.Actors.Has(NativeGui)
			return
		Hwnd := NativeGui.Hwnd
		if !DllCall("IsWindowVisible", "Ptr", Hwnd, "Int")
			return
		_MVSP_Require(WinGetPID("ahk_id " . Hwnd) == DllCall("GetCurrentProcessId", "UInt"), "An action cannot target a foreign HWND.")
		_MAD.Actors[NativeGui] := true, _MAD.Hwnds.Push(Hwnd)
		List := 0
		for Control in NativeGui
			if Control.Type == "ListView"
				List := Control
		if IsObject(List) {
			_MAD.Pickers += 1
			_MVSP_Require(_MAD.Action == "pick" && _MAD.Pickers == 1, "Only the actual pick action may create one running-app picker.")
			Found := 0
			loop List.GetCount()
				if StrLower(List.GetText(A_Index, 2)) == _MAD.App {
					_MVSP_Require(Found == 0, "The owned process must have exactly one canonical picker row.")
					Found := A_Index
				}
			_MVSP_Require(Found > 0, "The actual running-app picker must contain the fixture's visible process.")
			List.Modify(0, "-Check")
			List.Modify(Found, "Check")
		} else {
			_MAD.Inputs += 1
			Index := Mod(_MAD.Inputs - 1, 2)
			Value := Index == 0 ? (_MAD.Action == "pick" ? "Private pick 😀" : "Private edit §")
				: (_MAD.Action == "pick" ? "1.25" : "-0.5")
			ControlSetText(Value, "Edit1", "ahk_id " . Hwnd)
			_MVSP_Require(ControlGetText("Edit1", "ahk_id " . Hwnd) == Value, "The real owned edit control did not accept its complete value.")
		}
		Button := 0
		for Control in NativeGui
			if Control.Type == "Button" && Control.Text == t("common.ok") {
				_MVSP_Require(!IsObject(Button), "The owned surface must expose one actual OK button.")
				Button := Control
			}
		_MVSP_Require(IsObject(Button), "The actual owned surface has no OK button.")
		_MAD.ButtonReceipts.Push(_TestClickOwnedNativeButton(NativeGui, Button.Hwnd))
	} catch as Failure {
		_MAD_Error(Failure)
	}
}

_MAD_Eval(Script) {
	global _MVSP
	_MAD_Check()
	return JsonParse(_MVSP.View.ExecuteScriptAsync(Script).await())
}

_MAD_Row() {
	global _MAD
	return _MAD_Eval('(function(){const r=[...document.querySelectorAll("#apps-tbody tr")].find(x=>x.querySelector(".app-name-cell strong")?.textContent==='
		. JsonStringLiteral(_MAD.App) . ');return r?{name:r.querySelector(".app-name-cell").textContent,category:r.querySelector(".app-cat-cell").textContent}:null})()')
}

_MAD_WaitRow(Expected := "") {
	Started := A_TickCount
	loop {
		Row := _MAD_Row()
		if Row is Map && (Expected == "" || InStr(Row["category"], Expected, true))
			return Row
		_MVSP_Require(TickElapsed(Started) < 15000, "The actual Apps document did not render its fresh expected category.")
		Sleep(20)
	}
}

_MAD_WaitWorkers(ExpectedCount) {
	global _MAD_Root
	Started := A_TickCount
	loop {
		_MAD_Check()
		Count := 0
		Loop Files _MAD_Root . "\native-workers\*.json", "F"
			Count += 1
		if Count == ExpectedCount && !KLPFWorker.jobs.Has("apps")
			return
		_MVSP_Require(TickElapsed(Started) < 15000, "The actual detached projection did not settle with its native worker receipt.")
		Sleep(10)
	}
}

_MAD_FileSnapshot(Path) {
	Reader := FSOpenStrict(Path, "r-wd", "UTF-8-RAW")
	_MVSP_Require(IsObject(Reader), "The actual published projection must remain inspectable.")
	try return FSHandleSnapshot(Reader.Handle)
	finally Reader.Close()
}

_MAD_SameSnapshot(Expected, Path) {
	Current := _MAD_FileSnapshot(Path)
	if !(Current is Map) || !Current.Get("ok", false)
		return false
	for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
		if Current[Key] != Expected[Key]
			return false
	return true
}

_MAD_VerifyProjection(Category, Score, Count) {
	global _MAD, _MAD_Root
	_MAD_WaitWorkers(Count)
	_MVSP_Require(KL_AppCat_Reload(), "The actual canonical store reload must admit the durable edit.")
	_MVSP_Require(KL_AppCat_Get(_MAD.App) == Category, "The public string category must round-trip through the actual file.")
	Document := JsonParse(FSReadStrict(KLAppCat.file_path))
	_MVSP_Require(Document["apps"]["legacy-owned.exe"] == "never change"
		&& Document["apps"][_MAD.App]["type"] == Category && Document["apps"][_MAD.App]["score"] == Score,
		"The genuine record must preserve its legacy sibling and exact confirmed values.")
	Path := KLPF_PrefetchPath("apps", _MAD_Root)
	Projection := JsonParse(FSReadStrict(Path))
	_MVSP_Require(Projection["user_categories"][_MAD.App]["type"] == Category
		&& Projection["user_categories"][_MAD.App]["score"] == Score,
		"The fresh detached worker must project the current durable category and score.")
	Hash := _MVSP_Hash(Path), Matches := 0, WorkerReceipts := []
	Loop Files _MAD_Root . "\native-workers\*.json", "F" {
		Receipt := JsonParse(FSReadStrict(A_LoopFileFullPath))
		_MVSP_Require(Receipt["exit_code"] == 0 && Receipt["script_sha256"] == _MAD.SourceHash
			&& Receipt["runtime_sha256"] == _MAD.RuntimeHash && Receipt["worker_main"] == "KLPF_WorkerMain"
			&& Receipt["pid"] != DllCall("GetCurrentProcessId", "UInt") && Receipt["root"] == _MAD_Root
			&& Receipt["config_dir"] == _MAD_Root . "\config\" && Receipt["mode"] == "full",
			"Every real worker must bind its executed source, runtime and successful exit.")
		WorkerReceipts.Push(Receipt)
		if Receipt["stage_sha256"] == Hash
			Matches += 1
	}
	_MVSP_Require(Matches == 1, "The published projection must match exactly one actual worker's completed stage.")
	_MAD.WorkerReceipts := WorkerReceipts
	_MAD.PrefetchReceipt := _MAD_FileSnapshot(Path)
	_MAD_WaitRow(Category)
}

_MAD_RunDom(Action) {
	global _MAD
	_MAD.Action := Action
	Before := _MAD.Inputs
	_MVSP_Require(!_MAD.Entry.Has("apps_editor_ports") && KLPFWorker.spawn_fn == 0,
		"Dialogs, backend, refresh and process launch must use their real production defaults.")
	if Action == "pick" {
		_MVSP_Require(_MAD_Eval('(function(){const b=document.getElementById("btn-add-app");if(!b||!b.getClientRects().length)return false;b.click();return true})()'),
			"The actual visible Apps button must be clicked through the DOM.")
	} else {
		_MVSP_Require(_MAD_Eval('(function(){document.querySelector("[data-tab-target=apps]").click();const r=[...document.querySelectorAll("#apps-tbody tr")].find(x=>x.querySelector(".app-name-cell strong")?.textContent==='
			. JsonStringLiteral(_MAD.App) . ');const c=r?.querySelector(".app-cat-cell");if(!c)return false;c.scrollIntoView({block:"center",inline:"center"});const b=c.getBoundingClientRect();if(b.width<=0||b.height<=0||b.top<0||b.bottom>innerHeight)return false;c.click();return true})()'),
			"The actual visible category cell must emit its own edit action.")
	}
	Started := A_TickCount
	while _MAD.Inputs < Before + 2 || _MAD.Entry.Has("apps_editor_request") {
		_MAD_Check()
		_MVSP_Require(TickElapsed(Started) < 15000, "The actual DOM action did not complete its two real owned prompts.")
		Sleep(10)
	}
	_MVSP_Require(_MAD.Inputs == Before + 2, "Each real action must confirm category and score exactly once.")
	_MAD.Action := ""
}

_MAD_Main() {
	global _MAD, _MVSP, _MAD_Root, _MAD_DriverDir, _MAD_ExpectedRoot, _SharedDir, _ConfigDir
	Primary := 0, CleanupError := 0
	try {
		_MVSP_Require(A_Args.Length == 3 && _MAD_Root == _MAD_ExpectedRoot, "The host requires its exact private root and two source digests.")
		_MAD.SourceHash := _MVSP_Hash(A_ScriptFullPath), _MAD.RuntimeHash := _MVSP_Hash(A_AhkPath)
		_MVSP_Require(_MAD.SourceHash == A_Args[2] && _MAD.RuntimeHash == A_Args[3], "The actual host source/runtime differs from the parent launch receipt.")
		_MVSP_Require(!FSStrictExists(_MAD_Root), "The native Apps child must never adopt an existing private store.")
		FSCreateDirectoryExclusiveStrict(_MAD_Root)
		_MAD_CopyShared()
		TimingsLoadShared()
		KeyloggerWalkerLoadTimings()
		_MVSP.Gui := Gui("+ToolWindow", "Private Apps DOM integration")
		_MVSP.Gui.Show("w1000 h760")
		_MAD.App := StrLower(WinGetProcessName("ahk_id " . _MVSP.Gui.Hwnd))
		_MAD_SeedLedger(_MAD.App)
		_MVSP_Require(FSWriteCreateDurable(_MAD_Root . "\" . KLAppCatConst.FILE_NAME,
			'{"legacy-owned.exe":"never change"}'), "The private canonical store seed must be created once.")
		_MVSP_Require(KL_AppCat_Init(_MAD_Root), "The actual classifier must admit the private store.")
		_MVSP.Phase := "native-controller"
		SetTimer(_MAD_Deadline, -60000)
		_MVSP.Profile := WebView_NewProfilePath("ergopti_apps_dom_")
		FSCreateDirectoryExclusiveStrict(_MVSP.Profile)
		_MVSP.Controller := WebView2.create(_MVSP.Gui.Hwnd, , 0, _MVSP.Profile, "", 0,
			_MAD_DriverDir . "\vendor\64bit\WebView2Loader.dll")
		_MVSP.View := _MVSP.Controller.CoreWebView2
		WebView_WatchProfile(_MVSP.Profile, _MVSP.View)
		_MVSP.BrowserPid := _MVSP.View.BrowserProcessId
		_MVSP.BrowserHandle := DllCall("OpenProcess", "UInt", 0x100001, "Int", false, "UInt", _MVSP.BrowserPid, "Ptr")
		_MVSP_Require(_MVSP.BrowserHandle != 0, "The exact private browser must be supervised before navigation.")
		_MVSP.Controller.Fill()
		_MVSP.Controller.IsVisible := true
		_MAD.Url := "https://ergopti.metrics/ui/metrics_apps/index.html?epoch=61"
		_MAD.Entry := Map("epoch", 61, "webview", _MVSP.View, "controller", _MVSP.Controller,
			"gui", _MVSP.Gui, "udir", _MVSP.Profile, "navigation_url", _MAD.Url,
			"metrics_dir", _MAD_Root, "first_paint_done", true, "full_build_done", true)
		_MVSP.Entry := _MAD.Entry
		KLWV.windows := Map("apps", _MAD.Entry)
		_MVSP.ObserverSubscription := _MVSP.View.WebMessageReceived(_MAD_Message)
		_MVSP.HostSubscription := _MVSP.View.WebMessageReceived(KLWV_OnWebMessage.Bind("apps", 61))
		_MAD.Entry["msg_sub"] := _MVSP.HostSubscription
		_MVSP.View.SetVirtualHostNameToFolderMapping("ergopti.metrics", _SharedDir, 1)
		_MVSP.Phase := "initial-native-worker"
		_MAD.PrefetchPath := KLPF_PrefetchPath("apps", _MAD_Root)
		_MVSP_Require(!FSStrictExists(_MAD.PrefetchPath) && KLPFWorker.spawn_fn == 0,
			"The real initial worker must neither adopt a foreign snapshot nor substitute process launch.")
		_MVSP_Require(KLPF_RequestBuild("apps", _MAD_Root, "full", 61), "The actual initial worker must start.")
		_MAD_WaitWorkers(1)
		_MAD.PrefetchReceipt := _MAD_FileSnapshot(_MAD.PrefetchPath)
		_MVSP.Phase := "actual-apps-dom"
		_MVSP.View.Navigate(_MAD.Url)
		_MAD_WaitRow()
		SetTimer(_MAD_Act, 10)
		_MVSP.Phase := "dom-pick"
		_MAD_RunDom("pick")
		_MAD_VerifyProjection("Private pick 😀", 1.25, 2)
		_MVSP.Phase := "dom-edit"
		_MAD_RunDom("edit")
		_MAD_VerifyProjection("Private edit §", -0.5, 3)
		Counts := Map("ready", 0, "pick", 0, "edit", 0)
		for Message in _MAD.Messages
			Counts[Message["action"]] += 1
		_MVSP_Require(Counts["ready"] == 1 && Counts["pick"] == 1 && Counts["edit"] == 1
			&& _MAD.Pickers == 1 && _MAD.Inputs == 4, "The genuine DOM/native dialog routes must execute exactly once.")
		_MAD.Receipt := Map("source_sha256", _MAD.SourceHash, "runtime_sha256", _MAD.RuntimeHash,
			"host_pid", DllCall("GetCurrentProcessId", "UInt"), "messages", Counts, "real_prompts", _MAD.Inputs,
			"real_pickers", _MAD.Pickers, "real_workers", _MAD.WorkerReceipts.Length, "worker_receipts", _MAD.WorkerReceipts, "assets", _MAD.AssetHashes, "native_frames", _MAD.NativeFrames,
			"worker_substituted", false, "button_transport", "semantic-native-bm-click",
			"native_button_receipts", _MAD.ButtonReceipts,
			"scope", "native DOM-dialog-store-worker integration, not resident boot E2E")
	} catch as Failure {
		Primary := Failure
	}
	try _MAD_Close()
	catch as Failure {
		CleanupError := Failure
	}
	if IsObject(Primary) || IsObject(CleanupError) {
		Failure := IsObject(Primary) ? Primary : CleanupError
		FileAppend("Apps DOM integration failed at " . _MVSP.Phase . ": " . Failure.Message . "`n" . Failure.Stack . "`n", "**", "UTF-8-RAW")
		ExitApp(2)
	}
	_MAD.Receipt["browser_retired"] := _MVSP.BrowserRetired
	_MAD.Receipt["profile_retired"] := _MVSP.ProfileRetired
	_MAD.Receipt["jobs_retired"] := KLPFWorker.jobs.Count == 0
	FileAppend("RECEIPT " . KL_JsonEncode(_MAD.Receipt) . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_MAD_Close(*) {
	global _MAD, _MVSP
	if _MAD.Closed
		return
	SetTimer(_MAD_Act, 0), SetTimer(_MAD_Deadline, 0)
	_MAD_RetirePrompt()
	_MVSP_Require(KLPF_CancelAll(), "Every actual projection worker must physically retire before cleanup.")
	_MVSP.ObserverSubscription := 0, _MVSP.HostSubscription := 0
	if KLWV.windows.Has("apps") {
		KLWV_Close("apps")
		_MVSP.Controller := 0
	}
	_MAD.Entry := 0
	_MVSP_Close()
	for Hwnd in _MAD.Hwnds
		_MVSP_Require(!DllCall("IsWindow", "Ptr", Hwnd, "Int"), "An exact request-owned dialog HWND remains alive.")
	KLR_ResetCache()
	if _MAD.HasOwnProp("PrefetchReceipt")
		_MVSP_Require(FSDeleteVerified(_MAD.PrefetchPath, _MAD_SameSnapshot.Bind(_MAD.PrefetchReceipt)),
			"Only the exact last published native projection may be removed.")
	_MAD.Closed := true
}
