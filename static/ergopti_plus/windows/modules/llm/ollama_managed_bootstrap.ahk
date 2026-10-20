; modules/llm/ollama_managed_bootstrap.ahk

; ==============================================================================
; MODULE: Windows Managed Ollama Bootstrap
; DESCRIPTION:
; Composes the existing exact native file and runtime owners. Installation,
; start and model-download consent remain independent from AI enable consent.
; Published versions and models survive cancellation; private creation journals
; and runtime receipts retire only through their native identity owners.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ollama_runtime_owner.ahk

global _LLM_ManagedBootstrap := 0

/** Dispatches explicit installation without an administrator/system fallback. */
LLM_Deps_RunManagedInstaller(Model, Epoch, OnReady?, OnFailed?) {
	global _LLM_ManagedBootstrap
	if IsObject(_LLM_ManagedBootstrap) && !_LLM_ManagedBootstrap.CanReplace()
		return _LLM_Deps_PublishFailure(t("ollama.deps_failed"), OnFailed?, Epoch)
	try {
		Flow := OllamaManagedBootstrap(Model, Epoch, IsSet(OnReady) ? OnReady : 0,
			IsSet(OnFailed) ? OnFailed : 0)
		_LLM_ManagedBootstrap := Flow
		return Flow.Begin()
	} catch as Err {
		LoggerError("LLM.managed", "Managed bootstrap construction failed: {1}.", Err.Message)
		return _LLM_Deps_PublishFailure(t("ollama.runtime_repair_failed"), OnFailed?, Epoch)
	}
}

/** @returns {Boolean} Exact native owners and private file debts are settled. */
LLM_ManagedBootstrapCancel() {
	global _LLM_ManagedBootstrap
	return !IsObject(_LLM_ManagedBootstrap) || _LLM_ManagedBootstrap.Cancel()
}

/** Selected external origin or the exact live managed listener; never alias it. */
LLM_OllamaRequestOrigin() {
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	Flow := _LLM_ManagedBootstrap
	if !(Flow is OllamaManagedBootstrap) || !Flow.Runtime.HasOwner()
		return LLM_OLLAMA_BASE_URL
	if Flow.Ready && Flow._Current() && Flow.RuntimeIdentityReady()
		return Flow.Target["origin"]
	throw Error("The exact managed Ollama listener is not currently admitted.")
}

LLM_OllamaManagedOriginRequired() {
	global _LLM_ManagedBootstrap
	return _LLM_ManagedBootstrap is OllamaManagedBootstrap && _LLM_ManagedBootstrap.Runtime.HasOwner()
}

/** Captures currency before the origin reader can pump a replacement owner. */
LLM_OllamaCaptureOriginCustody(Reader := 0) {
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	Flow := _LLM_ManagedBootstrap, Configured := LLM_OLLAMA_BASE_URL
	AuxGeneration := LLM_AuxGeneration()
	Runtime := Flow is OllamaManagedBootstrap ? Flow.Runtime : 0
	Record := IsObject(Runtime) && Runtime.HasOwnProp("Record") ? Runtime.Record : 0
	Target := Flow is OllamaManagedBootstrap ? Flow.Target : 0
	RecordTarget := Record is Map ? Record.Get("target", 0) : 0
	Task := Record is Map ? Record.Get("task", 0) : 0
	Generation := IsObject(Runtime) && Runtime.HasOwnProp("Generation") ? Runtime.Generation : 0
	Tickets := Map()
	if Target is Map
		for Name in ["origin", "runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256"]
			Tickets[Name] := Target.Get(Name, "")
	Owned := IsObject(Runtime) && Runtime.HasOwner()
	if !(Owned is Integer) || (Owned != false && Owned != true)
		throw ValueError("Managed origin ownership must return an exact Boolean.")
	Origin := Owned && Tickets.Has("origin") ? Tickets["origin"] : Configured
	ReadFn := HasMethod(Reader, "Call") ? Reader : LLM_OllamaRequestOrigin
	if Reader != 0 && !HasMethod(Reader, "Call")
		throw TypeError("Origin reader must be callable.")
	if !Bound()
		throw Error("Origin ownership changed before its reader.")
	Observed := ReadFn.Call()
	if !Bound() || !(Observed is String) || !(Observed == Origin)
		throw Error("Origin reader replaced its captured ownership.")
	return Currency

	Bound() {
		global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
		if AuxGeneration != LLM_AuxGeneration() || !(LLM_OLLAMA_BASE_URL == Configured) || !(Origin is String) || Origin == ""
			return false
		if !Owned {
			Active := _LLM_ManagedBootstrap
			ActiveRuntime := Active is OllamaManagedBootstrap ? Active.Runtime : 0
			ActiveOwned := IsObject(ActiveRuntime) && ActiveRuntime.HasOwner()
			return Active == _LLM_ManagedBootstrap && (!(Active is OllamaManagedBootstrap) || Active.Runtime == ActiveRuntime)
				&& ActiveOwned is Integer && ActiveOwned == false
				&& LLM_OLLAMA_BASE_URL == Configured && AuxGeneration == LLM_AuxGeneration()
		}
		if _LLM_ManagedBootstrap != Flow || !(Record is Map) || !(Target is Map) || !(RecordTarget is Map)
				|| Flow.Runtime != Runtime || Runtime.Record != Record || Flow.Target != Target
				|| Record.Get("target", 0) != RecordTarget || Record.Get("task", 0) != Task
				|| !Runtime.HasOwnProp("Generation") || !(Generation is Integer) || Generation <= 0 || Runtime.Generation != Generation
			return false
		for Name, Value in Tickets {
			if !(Value is String) || Value == "" || !(Target.Get(Name, "") == Value) || !(RecordTarget.Get(Name, "") == Value)
				return false
		}
		return true
	}

	Currency(Action, Expected := "") {
		if Action == "owned"
			return Owned
		try Valid := Bound() && LLM_OllamaRequestOrigin() == Origin && Bound()
		catch
			Valid := false
		if Action == "current"
			return Valid && Expected is String && Expected == Origin
		if Action != "origin"
			throw ValueError("Unknown origin currency operation.")
		if !Valid
			throw Error("The original origin owner is no longer current.")
		return Origin
	}
}

/** A currency receipt reads its captured closure, never grants readiness. */
LLM_OllamaOriginCustodyCurrent(Custody, Origin) {
	if !HasMethod(Custody, "Call")
		return false
	try {
		Valid := Custody.Call("current", Origin)
		return Valid is Integer && Valid == true
	}
	catch
		return false
}

/** Retains the lexical receipt across native readers, cleanup and delivery callbacks. */
LLM_OllamaInvokeOriginCurrent(Custody, Origin, Callback, Name, Args*) {
	if !LLM_OllamaOriginCustodyCurrent(Custody, Origin)
		return false
	_LLM_InvokeCallback(Callback, Name, Args*)
	return true
}

LLM_OllamaOriginMatches(Origin) {
	try return Origin is String && StrCompare(Origin, LLM_OllamaRequestOrigin(), true) == 0
	catch
		return false
}

LLM_OllamaProbeOriginCurrent(Owner, Origin) {
	if !LLM_AuxIsCurrent(Owner)
		return false
	if LLM_ManagedBootstrapOriginIsCurrent(Owner, Origin)
		return true
	if Owner.Has("origin_custody")
		return LLM_OllamaOriginCustodyCurrent(Owner["origin_custody"], Origin)
	try return !LLM_OllamaManagedOriginRequired() && StrCompare(Origin, LLM_OllamaRequestOrigin(), true) == 0
	catch
		return false
}

/** Narrow override for probes of the exact app-owned native listener. */
LLM_ManagedBootstrapOriginIsCurrent(Owner, Origin) {
	global _LLM_ManagedBootstrap
	return _LLM_ManagedBootstrap is OllamaManagedBootstrap
		&& _LLM_ManagedBootstrap.OwnsProbe(Owner, Origin)
}

/** Resolves catalogue labels before the native literal-only model boundary. */
LLM_ManagedModelTag(Model) {
	Tag := LLM_ResolveOllamaTag(Model)
	if !(Tag is String) || (Tag != "" && !RegExMatch(Tag, "^[A-Za-z0-9_][A-Za-z0-9_./:-]*$"))
		throw ValueError("Managed model admission requires a canonical literal Ollama tag.")
	return Tag
}

/** One source-bound managed bootstrap, retaining physical debt independently. */
class OllamaManagedBootstrap {
	/** Captures every native source before admission; no installation occurs here. */
	__New(Model, Epoch, OnReady, OnFailed, Port := 0) {
		global _SharedDir, _StaticDir, _VendorDir, LLM_OLLAMA_BASE_URL, LLM_DEPS_POLL_TIMEOUT_MS, _LLM_Menu
		this.Port := Port
		this.Model := Model
		this.Epoch := Epoch
		this.OnReady := OnReady
		this.OnFailed := OnFailed
		this.Endpoint := LLM_OLLAMA_BASE_URL
		this.Cancelled := false
		this.Failed := false
		this.Ready := false
		this.ServerReady := false
		this.UiShown := false
		this.Pulled := false
		this.Debts := Map()
		this.LastReceipt := 0
		this.EnableHandoff := 0
		this.CleanupRunning := false
		this.PullTask := 0
		this.MenuPull := 0
		this.RuntimeRetired := false
		this.RuntimeRetiring := false
		this.Target := 0
		this.Timer := ObjBindMethod(this, "_Tick")
		this.Sources := Map()
		if Port is Map {
			this.Plan := Port["plan"].Clone()
			this.Files := Port["files"]
			this.Runtime := Port["runtime"]
			if Port.Has("read_source") {
				this.Source := Port["read_source"].Call()
				this.MenuIntent := Port["menu_intent"].Call().Clone()
				this.AuxGeneration := Port["aux_generation"].Call()
			}
			return
		}
		if !RegExMatch(this.Endpoint, "^http://(?:localhost|127\.0\.0\.1):([0-9]+)$", &Match)
			throw ValueError("Managed runtime requires the selected loopback Ollama endpoint.")
		this.Model := LLM_ManagedModelTag(Model)
		this.Source := _LLM_Menu_EnableReadSource()
		this.MenuIntent := Map("backend", _LLM_Menu.Get("backend", ""),
			"model", _LLM_Menu.Get("model", ""), "enabled", _LLM_Menu.Get("enabled", false),
			"api_entry_id", _LLM_Menu.Get("api_entry_id", ""))
		this.AuxGeneration := LLM_AuxGeneration()
		this.AuxPrefix := "ollama_managed_" . this._Ticket() . "_"
		NativeArchitecture := OllamaRuntime_HostArchitecture()
		Asset := NativeArchitecture == "arm64" ? "windows-arm64" : "windows-amd64"
		Root := EnvGet("LOCALAPPDATA") . "\" . AppDirsWindowsManagedOllamaFolderName()
		Directory := _StaticDir . "\ergopti_plus\windows\modules\llm"
		Catalogue := _SharedDir . "\modules\llm\ollama_release.json"
		Updater := _SharedDir . "\modules\updater\defaults.json"
		Policy := _SharedDir . "\modules\network\proxy_policy.json"
		ServeEnvironment := _SharedDir . "\modules\llm\managed_ollama_environment.json"
		Helper := Directory . "\ollama_managed_files.ps1"
		Acquisition := Directory . "\ollama_managed_acquisition.ps1"
		Vendor := _VendorDir
		for Path in [Catalogue, Updater, Policy, ServeEnvironment, Helper, Acquisition,
			Directory . "\ollama_download_archive.ps1", Directory . "\ollama-runtime-launch.ps1",
			Directory . "\ollama-model-pull.ps1"]
			this.Sources[Path] := this._Hash(Path)
		Inventory := ""
		for Name in ["ergopti_updater_download.ps1", "ergopti_network_routes.ps1",
			"ergopti_windows_proxy_config.ps1", "ergopti_native_proxy_ex.ps1",
			"ergopti_network_pac.ps1", "ergopti_curl_attempt.ps1", "ergopti_curl_capabilities_worker.ps1"] {
			Path := Vendor . "\" . Name
			this.Sources[Path] := this._Hash(Path)
			Inventory .= Name . "`n" . this.Sources[Path] . "`n"
		}
		Release := JsonParse(FSReadUtf8ExactBounded(Catalogue, 65536))
		Defaults := JsonParse(FSReadUtf8ExactBounded(Updater, 65536))
		DownloadMs := Defaults["archive_transfer"]["phase_timeout_ms"]["archive"]
		ConnectMs := Defaults["release_sources"]["proxy_resolve_timeout_sec"] * 1000
		this.Plan := Map("version", Release["version"], "ManagedRoot", Root, "CataloguePath", Catalogue,
			"CatalogueSha256", this.Sources[Catalogue], "AssetId", Asset,
			"helper", Helper, "helper_sha256", this.Sources[Helper], "directory", Directory,
			"environment", ServeEnvironment, "environment_sha256", this.Sources[ServeEnvironment],
			"port", Integer(Match[1]), "deadline_ms", LLM_DEPS_POLL_TIMEOUT_MS,
			"download", Map("ManagedRoot", Root, "CataloguePath", Catalogue,
				"CatalogueSha256", this.Sources[Catalogue], "AssetId", Asset,
				"ManagedHelperPath", Helper, "ManagedHelperSha256", this.Sources[Helper],
				"AcquisitionHelperPath", Acquisition, "AcquisitionHelperSha256", this.Sources[Acquisition],
				"VendorDirectory", Vendor, "VendorSha256", CryptoSha256(Inventory),
				"ProxyPolicyPath", Policy, "ProxyPolicySha256", this.Sources[Policy],
				"UpdaterDefaultsPath", Updater, "UpdaterDefaultsSha256", this.Sources[Updater],
				"ConnectTimeoutMs", ConnectMs, "DeadlineMs", DownloadMs))
		this.Files := OllamaInstallFilesPort(Map("helper", Helper,
			"download_helper", Directory . "\ollama_download_archive.ps1",
			"powershell", A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			"capture_bytes", 65536, "spawn", OllamaInstallFiles_Spawn,
			"on_physical", ObjBindMethod(this, "_Physical"), "on_error", ObjBindMethod(this, "_Error")))
		this.Runtime := OllamaRuntimeOwner(Map("launcher", Directory . "\ollama-runtime-launch.ps1",
			"helper", Helper, "helper_sha256", this.Sources[Helper],
			"environment", ServeEnvironment, "environment_sha256", this.Sources[ServeEnvironment],
			"on_retired", ObjBindMethod(this, "_RuntimeRetired"), "on_error", ObjBindMethod(this, "_Error")))
	}

	/** Starts a read-only inspection; no missing runtime is installed implicitly. */
	Begin() {
		this.StartedTick := this._Now()
		return this._Run("inspect", this._BaseRequest(), ObjBindMethod(this, "_Inspected"))
	}

	_BaseRequest() {
		return Map("ManagedRoot", this.Plan["ManagedRoot"], "CataloguePath", this.Plan["CataloguePath"],
			"CatalogueSha256", this.Plan["CatalogueSha256"], "AssetId", this.Plan["AssetId"])
	}

	_Run(Action, Request, Result) {
		if !this.Files.HasOwner()
			this.LastReceipt := 0
		this.CleanupRunning := Action == "cleanup_partial" || Action == "retire_runtime"
		Authority := Map("authorize", ObjBindMethod(this, "_Authorize"),
			"is_current", ObjBindMethod(this, "_Authorize"))
		if !this._True(this.Files.Run(Action, Request, Authority, Result)) {
			this._Fail("file_dispatch")
			return false
		}
		return true
	}

	_Authorize(Action, Request) {
		if Action == "cleanup_partial" || Action == "retire_runtime"
			return Request.Get("ManagedRoot", "") == this.Plan["ManagedRoot"]
		return this._Current()
	}

	_Current() {
		global _LLM_Deps_Epoch, LLM_OLLAMA_BASE_URL, _LLM_Menu
		if this.Cancelled || this.Failed || A_IsSuspended || (this.Epoch != _LLM_Deps_Epoch && !this.Ready)
				|| this.Endpoint != LLM_OLLAMA_BASE_URL
			return false
		if this.Port is Map {
			return this._True(this.Port["current"].Call()) && (!this.Port.Has("read_source")
				|| this._ConfigCurrent(this.Port["read_source"].Call(),
					this.Port["menu_intent"].Call(), this.Port["aux_generation"].Call()))
		}
		try {
			if !this._ConfigCurrent(_LLM_Menu_EnableReadSource(), _LLM_Menu, LLM_AuxGeneration())
				return false
			for Path, Digest in this.Sources
				if this._Hash(Path) != Digest
					return false
		} catch as Err {
			this._Error("source_revalidation", Err)
			return false
		}
		return true
	}

	OwnsProbe(Owner, Origin) {
		if !(Owner is Map) || !this.HasOwnProp("AuxPrefix") || !LLM_AuxIsCurrent(Owner)
				|| (Owner.Get("kind", "") != this.AuxPrefix . "version" && Owner.Get("kind", "") != this.AuxPrefix . "models")
				|| !(this.Target is Map) || Origin != this.Target["origin"] || Owner.Get("endpoint", "") != Origin
				|| !this.ServerReady || !this.Runtime.HasOwner() || !this._Current()
			return false
		return this.RuntimeIdentityReady()
	}

	RuntimeIdentityReady() {
		if !(this.Target is Map) || !this.Runtime.HasOwner()
			return false
		Record := this.Runtime.Record
		if !(Record is Map) || !this._True(Record.Get("accepted", false)) || !this._True(Record.Get("ready", false))
				|| !(Record.Get("cancelled", "") is Integer) || Record["cancelled"] != false
				|| !(Record.Get("terminal", "") is Integer) || Record["terminal"] != false || !(Record.Get("target", 0) is Map)
			return false
		for Name in ["origin", "runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256"]
			if Record["target"].Get(Name, "") != this.Target[Name]
				return false
		return this.Runtime.IdentityReady()
	}

	/** Exact borrowed enable writer successor; no arbitrary source recapture. */
	PrepareEnableHandoff(Source, Expected) {
		if !this.Ready || !this._Current() || !this.HasOwnProp("Source")
				|| !(this.MenuIntent["enabled"] is Integer) || this.MenuIntent["enabled"] != false
				|| !_LLM_Menu_EnableSourceMatches(this.Source, Source)
				|| !(Expected is Map) || !(Expected.Get("bytes", 0) is Buffer)
				|| Expected.Get("path", "") != Source["path"] || IsObject(this.EnableHandoff)
			return 0
		Menu := this.MenuIntent.Clone()
		Menu["enabled"] := true
		Token := Map("source", Expected, "menu", Menu, "generation", this.AuxGeneration)
		this.EnableHandoff := Token
		return Token
	}

	FinishEnableHandoff(Token) {
		if !(Token is Map) || !IsObject(this.EnableHandoff) || Token != this.EnableHandoff
				|| !this._Current()
			return false
		if this.Port is Map
			Source := this.Port["read_source"].Call(), Menu := this.Port["menu_intent"].Call()
		else {
			global _LLM_Menu
			Source := _LLM_Menu_EnableReadSource(), Menu := _LLM_Menu
		}
		if !_LLM_Menu_EnableSourceMatches(Token["source"], Source) || !this._IntentMatches(Token["menu"], Menu)
			return false
		this.Source := Token["source"]
		this.MenuIntent := Token["menu"]
		this.EnableHandoff := 0
		return true
	}

	AbortEnableHandoff(Token) {
		if IsObject(this.EnableHandoff) && Token == this.EnableHandoff
			this.EnableHandoff := 0
	}

	_ConfigCurrent(Source, Menu, Generation) {
		if Generation != this.AuxGeneration
			return false
		if _LLM_Menu_EnableSourceMatches(this.Source, Source) && this._IntentMatches(this.MenuIntent, Menu)
			return true
		Token := this.EnableHandoff
		return Token is Map && _LLM_Menu_EnableSourceMatches(Token["source"], Source)
			&& (this._IntentMatches(this.MenuIntent, Menu) || this._IntentMatches(Token["menu"], Menu))
	}

	_IntentMatches(Expected, Current) {
		for Name, Value in Expected
			if Type(Current.Get(Name, "")) != Type(Value) || Current[Name] != Value
				return false
		return true
	}

	_Hash(Path) {
		return CryptoSha256Bytes(FSReadBytesStrict(Path))
	}

	_Consent(Kind, Model := "") {
		if !this._Current()
			return false
		if this.Port is Map
			Accepted := this.Port["consent"].Call(Kind, Model)
		else {
			if Kind == "install"
				Title := t("ollama.runtime_missing_title"), Body := t("ollama.offer_body")
			else if Kind == "start"
				Title := t("ollama.runtime_start"), Body := StrReplace(t("llm.unreachable.start"), "{1}", "Ollama") . "?"
			else
				Title := t("llm.local_model.missing_title"), Body := StrReplace(t("llm.local_model.missing_body"), "{1}", Model)
			Accepted := _LLM_LocalModelConfirm(Title, Body)
		}
		return Accepted is Integer && Accepted == true && this._Current()
	}

	_Inspected(Terminal) {
		Receipt := this.LastReceipt
		if !this._Success(Terminal, Receipt)
			return this._Fail("inspection")
		if Receipt["phase"] == "published"
			return this._PrepareStart(Receipt)
		if Receipt["phase"] != "missing"
			return this._Fail("inspection_receipt")
		if !this._Consent("install")
			return this._Declined()
		Request := this.Plan["download"].Clone()
		Request["TicketId"] := this._Ticket()
		Request["StartedTick"] := this._Now()
		if !(this.Port is Map)
			Request["DeadlineMs"] := Min(Request["DeadlineMs"], this.Plan["deadline_ms"] - (Request["StartedTick"] - this.StartedTick))
		this._Ui("ollama.install_subtitle")
		return this._Run("download", Request, ObjBindMethod(this, "_Downloaded"))
	}

	_Downloaded(Terminal) {
		Receipt := this.LastReceipt
		if !this._Success(Terminal, Receipt) || Receipt["phase"] != "downloaded"
			return this._Fail("download")
		Request := this._BaseRequest()
		Request["TicketId"] := this._Ticket()
		Request["ArchivePath"] := Receipt["archive"]
		this._Ui("ollama.deps_step_installing")
		return this._Run("prepare", Request, ObjBindMethod(this, "_Prepared"))
	}

	_Prepared(Terminal) {
		Receipt := this.LastReceipt
		if !this._Success(Terminal, Receipt) || Receipt["phase"] != "prepared"
			return this._Fail("preparation")
		this.Prepared := Receipt.Clone()
		Request := Map("ManagedRoot", this.Plan["ManagedRoot"], "TicketId", Receipt["ticket"],
			"StageIdentity", Receipt["stage_identity"], "ManifestSha256", Receipt["manifest_sha256"])
		return this._Run("publish", Request, ObjBindMethod(this, "_Published"))
	}

	_Published(Terminal) {
		Receipt := this.LastReceipt
		if !this._Success(Terminal, Receipt) || Receipt["phase"] != "published"
			return this._Fail("publication")
		Receipt["root_identity"] := this.Prepared["root_identity"]
		Receipt["manifest_sha256"] := this.Prepared["manifest_sha256"]
		this.Published := Receipt.Clone()
		return this._Drain(ObjBindMethod(this, "_StartPublished"))
	}

	_StartPublished(*) {
		return this._PrepareStart(this.Published)
	}

	_PrepareStart(Receipt) {
		if !this._Consent("start")
			return this._Declined()
		Target := Map("managed_root", this.Plan["ManagedRoot"],
			"version_path", Receipt["version_path"], "executable", Receipt["executable"],
			"root_identity", Receipt["root_identity"], "version_identity", Receipt["version_identity"],
			"ticket", Receipt["ticket"], "manifest_sha256", Receipt["manifest_sha256"],
			"runtime_ticket", this._Ticket(), "port", this.Plan["port"],
			"origin", "http://127.0.0.1:" . this.Plan["port"],
			"models_dir", this.Plan["ManagedRoot"] . "\models",
			"started_tick", this._Now(), "deadline_ms", this.Plan["deadline_ms"] - (this._Now() - this.StartedTick))
		this._Ui("ollama.deps_step_starting")
		this.Target := Target
		Authority := Map("authorize", (*) => this._Current(), "is_current", (*) => this._Current())
		if !this._True(this.Runtime.Start(Target, Authority, ObjBindMethod(this, "_ServerReady"), ObjBindMethod(this, "_ServerExited")))
			return this._Fail("runtime_start")
		SetTimer(this.Timer, 150)
		return true
	}

	_Tick() {
		if this.Cancelled || this.Failed
			return this.Cancel()
		if this.MenuPull is Map && !this._MenuPullCurrent(this.MenuPull)
			return this.Cancel()
		if !this.Ready && (this._Now() < this.StartedTick || this._Now() - this.StartedTick >= this.Plan["deadline_ms"])
			return this._Fail("bootstrap_timeout")
		if !this._Current()
			return this._Declined()
		if this.Ready
			return true
		if !(this.Port is Map) && this.UiShown && !OllamaWV_IsAlive()
			return this._Declined()
		if this._Now() - this.StartedTick >= this.Plan["deadline_ms"]
			return this._Fail("runtime_timeout")
		if IsObject(this.Target) && !this.ServerReady
			this.Runtime.ObserveReady()
	}

	_ServerReady(Target, Receipt) {
		this.ServerReady := true
		this.Target["ready_file_identity"] := Receipt["ready_file_identity"]
		this.Target["ready_image_sha256"] := this.Runtime.Record["ready_image_sha256"]
		if !this._Current()
			return this.Cancel()
		if this.Port is Map
			return this.Port["version"].Call(ObjBindMethod(this, "_VersionReceived"))
		Owner := LLM_AuxBegin(this.AuxPrefix . "version", Map("backend", "ollama", "endpoint", this.Target["origin"]))
		return LLM_OllamaIsRunning_Async(ObjBindMethod(this, "_VersionReceived"), Owner, true)
	}

	_VersionReceived(Receipt) {
		if !this._Current()
			return this.Cancel()
		if !LLM_EnableReceipt(Receipt)["admitted"]
			return this._Fail("version_receipt")
		Version := JsonParse(Receipt["body"])
		if Version["version"] != this.Plan["version"]
			return this._Fail("configured_version")
		return this._Models()
	}

	_Models() {
		if this.Model == ""
			return this._Complete()
		if this.Port is Map
			return this.Port["models"].Call(ObjBindMethod(this, "_ModelsReceived"))
		Owner := LLM_AuxBegin(this.AuxPrefix . "models", Map("backend", "ollama",
			"endpoint", this.Target["origin"], "identity", this.Model))
		return LLM_OllamaListModels_Async(ObjBindMethod(this, "_ModelsReceived"), Owner, true)
	}

	_ModelsReceived(Receipt) {
		if !this._Current()
			return this.Cancel()
		if !(Receipt is Map) || !this._True(Receipt.Get("ok", false)) || !(Receipt.Get("names", 0) is Map)
			return this._Fail("models_receipt")
		if Receipt["names"].Has(LLM_LocalModelNormalize(this.Model))
			return this._Complete()
		if this.Pulled
			return this._Fail("model_missing_after_pull")
		if !this._Consent("model", this.Model)
			return this._Declined()
		this.Pulled := true
		this._Ui("ollama.downloading")
		if this.Port is Map
			return this.Port["pull"].Call(this.Target.Clone(), this.Model, ObjBindMethod(this, "_PullResult"))
		return this._NativePull()
	}

	/** An explicit menu download borrows this exact ready runtime, never PATH. */
	PullModel(Model, OnDone := 0, CurrentFn := 0) {
		if !this.Ready || !this._Current() || !this.RuntimeIdentityReady() || IsObject(this.PullTask) || this.MenuPull is Map
			return false
		try Tag := LLM_ManagedModelTag(Model)
		catch
			return false
		if Tag == ""
			return false
		; A READY flow can outlive its bootstrap clock. The new request owns one
		; captured budget through consent, native retirement and fresh model tags.
		Operation := Map("tag", Tag, "callback", OnDone, "started_tick", this._Now(),
			"deadline_ms", this.Plan["deadline_ms"], "failed", false, "source_current", CurrentFn)
		this.MenuPull := Operation
		if !this._MenuPullCurrent(Operation)
			return false
		LoggerTrace("LLM.managed", "Starting bounded managed menu model download.")
		try {
			if !this._Consent("model", Tag) {
				this._MenuPullRetire(Operation)
				return false
			}
			if !this._MenuPullCurrent(Operation)
				return false
			Done := ObjBindMethod(this, "_MenuPulled", Operation)
			Accepted := this.Port is Map
				? this.Port["pull"].Call(this.Target.Clone(), Tag, Done) : this._NativePull(Tag, Done)
			if !this._True(Accepted) && this.MenuPull == Operation
				return this._MenuPullFail(Operation)
			return this._True(Accepted)
		} catch as Err {
			this._MenuPullFail(Operation)
			throw Err
		}
	}

	/** A menu operation cannot borrow another request or reset its deadline. */
	_MenuPullCurrent(Operation) {
		if !(Operation is Map) || this.MenuPull != Operation || Operation["failed"]
			return false
		SourceCurrent := Operation.Get("source_current", 0)
		try {
			if HasMethod(SourceCurrent, "Call") && !this._True(SourceCurrent.Call()) {
				this._MenuPullRetire(Operation)
				return false
			}
		} catch {
			this._MenuPullRetire(Operation)
			return false
		}
		; A source callback may pump a modal or replace the exact operation.
		if this.MenuPull != Operation || Operation["failed"]
			return false
		Now := this._Now()
		if Now < Operation["started_tick"] || Now - Operation["started_tick"] >= Operation["deadline_ms"]
			return this._MenuPullFail(Operation)
		return this.Ready && this._Current() && this.RuntimeIdentityReady()
	}

	_MenuPullRetire(Operation) {
		if this.MenuPull != Operation
			return false
		this.MenuPull := 0
		LoggerDone("LLM.managed", "Managed menu model download settled logically; native task custody remains independent.")
		return true
	}

	_MenuPullFail(Operation) {
		if !(Operation is Map) || this.MenuPull != Operation || Operation["failed"]
			return false
		Operation["failed"] := true
		LoggerError("LLM.managed", "Managed menu model download failed; cancelling its retained owners.")
		try {
			this._Ui("ollama.runtime_repair_failed")
			if !(this.Port is Map) && this.UiShown && !A_IsSuspended
				OllamaWV_SetError(t("ollama.runtime_repair_failed"))
		} finally this.Cancel()
		return false
	}

	_MenuPulled(Operation, ExitCode, *) {
		if !this._MenuPullCurrent(Operation)
			return false
		if !(ExitCode is Integer) || ExitCode != 0
			return this._MenuPullFail(Operation)
		Done := ObjBindMethod(this, "_MenuPullModels", Operation)
		if this.Port is Map
			return this.Port["models"].Call(Done)
		Owner := LLM_AuxBegin(this.AuxPrefix . "models", Map("backend", "ollama",
			"endpoint", this.Target["origin"], "identity", Operation["tag"]))
		return LLM_OllamaListModels_Async(Done, Owner, true)
	}

	_MenuPullModels(Operation, Receipt) {
		if !this._MenuPullCurrent(Operation)
			return false
		if !(Receipt is Map) || !this._True(Receipt.Get("ok", false)) || !(Receipt.Get("names", 0) is Map)
			return this._MenuPullFail(Operation)
		if Receipt["names"].Has(LLM_LocalModelNormalize(Operation["tag"])) {
			OnDone := Operation["callback"]
			this._MenuPullRetire(Operation)
			if HasMethod(OnDone, "Call")
				OnDone.Call()
			return true
		}
		return this._MenuPullFail(Operation)
	}

	_NativePull(Model := unset, OnDone := 0, SpawnFn := 0) {
		; Capture logical custody before a native boundary can cancel or retire it.
		MenuOperation := HasMethod(OnDone, "Call") && this.MenuPull is Map ? this.MenuPull : 0
		if !IsSet(Model)
			Model := this.Model
		Target := this.Target
		Args := ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
			this.Plan["directory"] . "\ollama-model-pull.ps1", "-ManagedHelperPath", this.Plan["helper"],
			"-ManagedHelperSha256", this.Plan["helper_sha256"], "-ManagedRoot", Target["managed_root"],
			"-RuntimeLauncherPath", this.Plan["directory"] . "\ollama-runtime-launch.ps1",
			"-RuntimeLauncherSha256", this.Sources[this.Plan["directory"] . "\ollama-runtime-launch.ps1"],
			"-ServeEnvironmentPath", this.Plan["environment"], "-ServeEnvironmentSha256", this.Plan["environment_sha256"],
			"-ReadyFileIdentity", Target["ready_file_identity"], "-ReadyImageSha256", Target["ready_image_sha256"],
			"-RootIdentity", Target["root_identity"], "-PublishedPath", Target["version_path"],
			"-StageIdentity", Target["version_identity"], "-TicketId", Target["ticket"],
			"-ManifestSha256", Target["manifest_sha256"], "-RuntimeTicket", Target["runtime_ticket"],
			"-Port", String(Target["port"]), "-Model", Model]
		Owner := Map("task", 0, "building", true, "accepted", false, "terminal", 0, "callback", OnDone)
		this.PullTask := Owner
		Accepted := false
		try {
			Factory := HasMethod(SpawnFn, "Call") ? SpawnFn : ShellRunner_SpawnTreeOwned
			Task := Factory.Call(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
				Args, ObjBindMethod(this, "_Pulled", Owner), , , 65536, true, true)
			Owner["task"] := Task
			Accepted := this._Current() && this._True(Task.start()) && this._Current()
			Owner["accepted"] := Accepted
		} catch as Err {
			this._Error("model_dispatch", Err)
		} finally {
			Owner["building"] := false
			if Owner["terminal"] is Map
				this._Pulled(Owner, Owner["terminal"]["exit"])
		}
		if Accepted
			return true
		; A post-READY menu dispatch cannot re-notify the completed bootstrap.
		; Retain the captured operation even when native completion retired it.
		if MenuOperation is Map {
			try return this._MenuPullFail(MenuOperation)
			finally this.Cancel()
		}
		return this._Fail("model_dispatch")
	}

	_Pulled(Owner, ExitCode, Stdout := "", Stderr := "") {
		; Canonical tree completion occurs after exact native quiescence. A stale
		; task callback must never clear a successor's task or publish its model.
		if this.PullTask != Owner
			return false
		if Owner["building"] {
			Owner["terminal"] := Map("exit", ExitCode)
			return false
		}
		Owner["task"] := 0
		this.PullTask := 0
		if Owner["accepted"] && HasMethod(Owner.Get("callback", 0), "Call")
			return Owner["callback"].Call(ExitCode)
		return Owner["accepted"] ? this._PullResult(ExitCode) : this.Cancel()
	}

	_PullResult(ExitCode, Stdout := "", Stderr := "") {
		if !this._Current()
			return this.Cancel()
		if !(ExitCode is Integer) || ExitCode != 0
			return this._Fail("model_pull")
		return this._Models()
	}

	_Complete() {
		global _LLM_Deps_State, _LLM_Deps_Checking
		if !this._Current()
			return this.Cancel()
		this.Ready := true
		SetTimer(this.Timer, 150)
		if !(this.Port is Map) && this.UiShown
			OllamaWV_Done(true, t("ollama.deps_step_ready"))
		_LLM_Deps_State := "ready"
		_LLM_Deps_Checking := false
		if HasMethod(this.OnReady, "Call")
			this.OnReady.Call()
		this.OnReady := 0
		return true
	}

	_ServerExited(ExitCode, Target) {
		this._Fail("runtime_exit")
	}

	/** Adopts exact terminal file evidence before any logical continuation. */
	_Physical(Action, Request, Terminal) {
		if Terminal.Get("kind", "") == "undispatched" && Terminal.Get("dispatched", true) == false
			return true
		if !this._True(Terminal.Get("exit_observed", false)) || !this._True(Terminal.Get("output_observed", false))
			return false
		try {
			Lines := StrSplit(Trim(Terminal.Get("stdout", "")), "`n", "`r")
			Receipt := JsonParse(Lines[Lines.Length])
			if !(Receipt is Map) || !(Receipt.Get("ok", "") is Integer)
					|| (Receipt["ok"] != true && Receipt["ok"] != false)
				return false
			if Action != "inspect" && Receipt.Get("ticket", "") != Request.Get("TicketId", "")
				return false
			this.LastReceipt := Receipt
			this.CleanupRunning := false
			if Action == "cleanup_partial" && Terminal.Get("exit", -1) == 0 && this._True(Receipt.Get("ok", false)) {
				if this.Debts.Has(Request["TicketId"])
					this.Debts.Delete(Request["TicketId"])
			}
			if Action == "retire_runtime" && Terminal.Get("exit", -1) == 0 && this._True(Receipt.Get("ok", false))
				this.RuntimeRetired := true
			Creation := Receipt.Has("creation_receipt") ? Receipt["creation_receipt"] : Receipt
			if Creation is Map && Creation.Has("creation_wal_identity") && Creation.Has("creation_wal_sha256") {
				Debt := Map("ManagedRoot", this.Plan["ManagedRoot"], "TicketId", Creation["ticket"],
					"CreationWalIdentity", Creation["creation_wal_identity"], "CreationWalSha256", Creation["creation_wal_sha256"])
				this.Debts[Creation["ticket"]] := Debt
			}
			if this.Cancelled
				SetTimer(ObjBindMethod(this, "Cancel"), -1)
			return true
		} catch as Err {
			this._Error("file_receipt", Err)
			return false
		}
	}

	_Success(Terminal, Receipt) {
		return (Terminal.Get("exit", "") is Integer) && Terminal["exit"] == 0 && Receipt is Map && this._True(Receipt.Get("ok", false)) && this._Current()
	}

	_Drain(OnDone) {
		if this.Files.HasOwner()
			return false
		for Ticket, Debt in this.Debts
			return this._Run("cleanup_partial", Debt, ObjBindMethod(this, "_Drained", Ticket, OnDone))
		return OnDone.Call()
	}

	_Drained(Ticket, OnDone, Terminal) {
		if Terminal.Get("exit", -1) != 0 || !this._True(this.LastReceipt.Get("ok", false))
			return this._Fail("private_cleanup")
		if this.Debts.Has(Ticket)
			this.Debts.Delete(Ticket)
		return this._Drain(OnDone)
	}

	_RuntimeRetired(Target) {
		if this.RuntimeRetired
			return true
		if !this.RuntimeRetiring && !this.Files.HasOwner() {
			this.RuntimeRetiring := true
			Request := Map("ManagedRoot", Target["managed_root"], "RootIdentity", Target["root_identity"],
				"TicketId", Target["ticket"], "RuntimeTicket", Target["runtime_ticket"],
				"ReadyFileIdentity", Target["ready_file_identity"], "ReadyImageSha256", Target["ready_image_sha256"])
			SetTimer(() => this._Run("retire_runtime", Request, ObjBindMethod(this, "_ReceiptRetired")), -1)
		}
		return false
	}

	_ReceiptRetired(Terminal) {
		this.RuntimeRetiring := false
		if Terminal.Get("exit", -1) == 0 && this._True(this.LastReceipt.Get("ok", false)) {
			this.RuntimeRetired := true
			this.Runtime.Stop()
			this.Cancel()
		} else
			this._Error("runtime_receipt_cleanup", Error("Exact runtime receipt retirement was refused."))
	}

	/** Invalidates logic first; retained native/file owners block all successors. */
	Cancel(*) {
		global _LLM_ManagedBootstrap, _LLM_Deps_State
		this.Cancelled := true
		if this.MenuPull is Map
			this._MenuPullRetire(this.MenuPull)
		if this.Ready && IsObject(_LLM_ManagedBootstrap) && _LLM_ManagedBootstrap == this
				&& _LLM_Deps_State == "ready"
			_LLM_Deps_State := "pending"
		this.Ready := false
		SetTimer(this.Timer, 0)
		AuxStopped := true
		if !(this.Port is Map) {
			LLM_AuxRetirePrefix(this.AuxPrefix)
			AuxStopped := LLM_AuxRetryCleanupDebt()
		}
		PullStopped := !IsObject(this.PullTask)
		if !PullStopped {
			Owner := this.PullTask
			Task := Owner["task"]
			PullStopped := !IsObject(Task)
			if IsObject(Task)
				PullStopped := this._True(Task.requestTerminate())
			; STARTING cancellation retains the construction record until its
			; stack ends. Strict canonical ACK proves native tree/handle closure.
			if PullStopped && !Owner["building"] && this.PullTask == Owner
				this.PullTask := 0
			PullStopped := PullStopped && !Owner["building"]
		}
		FilesStopped := !this.Files.HasOwner()
		if !FilesStopped && !this.CleanupRunning
			FilesStopped := this._True(this.Files.Cancel())
		RuntimeStopped := this._True(this.Runtime.Stop())
		if FilesStopped && this.Debts.Count
			this._Drain(() => true)
		return AuxStopped && PullStopped && FilesStopped && RuntimeStopped && this.Debts.Count == 0
	}

	/** Keeps installed versions and model files; only owned temporary files retire. */
	CanReplace() {
		return !this.Files.HasOwner() && !this.Runtime.HasOwner() && !IsObject(this.PullTask) && this.Debts.Count == 0
			&& (this.Port is Map || LLM_AuxRetryCleanupDebt())
	}

	_Declined() {
		global _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_Epoch
		if this.Epoch == _LLM_Deps_Epoch {
			_LLM_Deps_Checking := false
			_LLM_Deps_State := "pending"
		}
		return this.Cancel()
	}

	_Fail(Phase) {
		global _LLM_Deps_Epoch
		if !this.Failed {
			if !(this.Port is Map) && !this.Cancelled && this.Epoch == _LLM_Deps_Epoch && !A_IsSuspended
				this._Ui("ollama.runtime_repair_failed")
			this.Failed := true
			LoggerError("LLM.managed", "Managed bootstrap failed at {1}; retained owners remain explicit.", Phase)
			if this.Epoch == _LLM_Deps_Epoch {
				if !(this.Port is Map) && this.UiShown && !A_IsSuspended
					OllamaWV_SetError(t("ollama.runtime_repair_failed"))
				if HasMethod(this.OnFailed, "Call")
					_LLM_Deps_PublishFailure(t("ollama.runtime_repair_failed"), this.OnFailed, this.Epoch)
				else
					_LLM_Deps_PublishFailure(t("ollama.runtime_repair_failed"), , this.Epoch)
			}
		}
		this.Cancel()
		return false
	}

	_Retry(*) {
		global _LLM_Deps_Epoch
		if this.Epoch != _LLM_Deps_Epoch || !this.CanReplace() || A_IsSuspended
			return false
		Ready := this.OnReady
		Failed := this.OnFailed
		if !HasMethod(Ready, "Call")
			Ready := unset
		if !HasMethod(Failed, "Call")
			Failed := unset
		return LLM_Deps_CheckAndInstall(this.Model, Ready?, Failed?, true)
	}

	_Ui(Key) {
		if this.Port is Map || !this._Current()
			return
		if !this.UiShown {
			OllamaWV_Show("ollama_install", t("ollama.install_subtitle"), (*) => LLM_Deps_Cancel(), ObjBindMethod(this, "_Retry"))
			this.UiShown := true
			SetTimer(this.Timer, 150)
		}
		OllamaWV_SetStep(t(Key))
	}

	_Error(Kind, Err) {
		LoggerError("LLM.managed", "Managed {1} failed: {2}.", Kind, Err.Message)
	}

	_Ticket() {
		Guid := Buffer(16, 0)
		if PLC_CreateGuid(Guid.Ptr, "HRESULT") != 0
			throw Error("Managed acquisition cannot allocate its unique ticket.")
		Result := ""
		loop Guid.Size
			Result .= Format("{:02x}", NumGet(Guid, A_Index - 1, "UChar"))
		return Result
	}

	_True(Value) {
		return Value is Integer && Value == true
	}

	_Now() {
		return this.Port is Map ? this.Port["clock"].Call() : OllamaRuntime_Now()
	}
}
