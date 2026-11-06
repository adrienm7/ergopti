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

; Exit code of ollama-model-pull.ps1 when the relay demands a Windows login
; (NTLM, Negotiate) the owned daemon cannot answer (Get-OllamaPullProxyLoginExitCode)
global LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT := 3
; The local sign-in relay beside the other vendor helpers (ergopti-proxy-relay).
global LLM_OLLAMA_PROXY_RELAY_EXECUTABLE := "ergopti-proxy-relay.exe"
; Its build identity (tools/build/build_windows_proxy_relay.ps1), read for the expected digest.
global LLM_OLLAMA_PROXY_RELAY_MANIFEST := "ergopti-proxy-relay.json"

; The launcher's proxy dependencies under vendor/, in the order of its
; Get-OllamaRuntimeVendorNames: both sides hash name and digest in this order
global LLM_OLLAMA_RUNTIME_VENDOR_NAMES := ["ergopti_route_plan.ps1", "ergopti_network_routes.ps1",
	"ergopti_windows_proxy_config.ps1", "ergopti_native_proxy_ex.ps1", "ergopti_network_pac.ps1"]

#Include ollama_runtime_owner.ahk

global _LLM_ManagedBootstrap := 0
; The one observer of a menu pull's percentage (the model selector page):
; called with (Tag, Percent) at each new whole percentage, then (Tag, "") once
; the pull ended. 0 when no page observes it.
global LLM_PULL_PERCENT_LISTENER := 0
; The end of a pull's capture read for its percentage: a few progress frames.
global LLM_PULL_PERCENT_TAIL_BYTES := 4096
; The ceiling of a pull's capture. Ollama prints a progress frame every 100 ms,
; piped or not, and past the ceiling the shell runner reads no body and reports
; exit 63: this bound must hold hours of frames, or a long pull fails after it
; succeeded and its last line, the only one that names a failure, is lost.
global LLM_OLLAMA_PULL_CAPTURE_BYTES := 67108864
; What marks each class of a failed pull, first match wins: the closed vocabulary
; of macos/modules/llm/managed_ollama_pull.py ERROR_CLASSES. The transport classes
; come before "manifest": Ollama prefixes a failed fetch with "pull model manifest".
global LLM_OLLAMA_PULL_ERROR_CLASSES := [["digest mismatch", "digest_mismatch"], ["no space left", "no_space"],
	["permission denied", "permission_denied"], ["context canceled", "cancelled"],
	["max retries", "max_retries"], ["deadline exceeded", "timeout"], ["timeout", "timeout"],
	["certificate", "certificate"], ["tls", "certificate"], ["no such host", "dns"],
	["connection refused", "connection"], ["connection reset", "connection"], ["unexpected eof", "connection"],
	["too many requests", "rate_limited"], ["manifest", "manifest"], ["file does not exist", "not_found"]]

/** Dispatches explicit installation without an administrator/system fallback. */
LLM_Deps_RunManagedInstaller(Model, Epoch, OnReady?, OnFailed?, Silent := false) {
	global _LLM_ManagedBootstrap
	if IsObject(_LLM_ManagedBootstrap) && !_LLM_ManagedBootstrap.CanReplace()
		return _LLM_Deps_PublishFailure(t("ollama.deps_failed"), OnFailed?, Epoch)
	try {
		Flow := OllamaManagedBootstrap(Model, Epoch, IsSet(OnReady) ? OnReady : 0,
			IsSet(OnFailed) ? OnFailed : 0, 0, Silent)
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

/** The configured owned port or the exact live managed listener; never alias it. */
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

/**
 * The last whole percentage an Ollama pull printed ("pulling 6a07…:  45% ▕██
 * ▏ 2.1 GB/4.7 GB"), as the macOS download window reads the same output.
 * @param {String} Text The tail of the pull's output.
 * @returns {Integer|String} 0-100, or "" when the text holds none.
 */
LLM_OllamaPullPercent(Text) {
	if !(Text is String) || Text == ""
		return ""
	Percent := "", Pos := 1
	while (Pos := RegExMatch(Text, "(?<![\d.])(\d{1,3})%", &Match, Pos)) {
		if (Integer(Match[1]) <= 100)
			Percent := Integer(Match[1])
		Pos += Match.Len
	}
	return Percent
}

/**
 * Names why a pull failed from its captured output. Only the CLI's closing
 * "Error:" line counts: a progress frame says "pulling manifest" on every pull.
 * @param {String} Text The pull's output.
 * @returns {String} A class of the closed vocabulary, "other", or "" without an error line.
 */
LLM_OllamaPullErrorClass(Text) {
	global LLM_OLLAMA_PULL_ERROR_CLASSES
	if !(Text is String) || !(Position := InStr(Text, "Error:", true, -1))
		return ""
	Message := SubStr(Text, Position + StrLen("Error:"))
	if RegExMatch(Message, "[\r\n]", &LineEnd)
		Message := SubStr(Message, 1, LineEnd.Pos - 1)
	for Row in LLM_OLLAMA_PULL_ERROR_CLASSES {
		if InStr(Message, Row[1])
			return Row[2]
	}
	return "other"
}

/**
 * The message of a pull refused at its login exit code: the relay's own refusal
 * when it names one, else the proxy that demands a Windows login no installed
 * relay can answer.
 * @param {String} Text The pull's output.
 * @param {String} ContractPath proxy_auth_relay.json, whose refusals name each message.
 * @returns {String} A locale key.
 */
LLM_OllamaPullRefusalKey(Text, ContractPath := "") {
	global _SharedDir
	if !(Text is String) || !RegExMatch(Text, "Managed model pull refused: proxy_relay ([a-z_]+)", &Found)
		return "network.failure.proxy_windows_login"
	if ContractPath == ""
		ContractPath := _SharedDir . "\modules\network\proxy_auth_relay.json"
	Refusals := JsonParse(FSReadUtf8ExactBounded(ContractPath, 8192))["refusals"]
	return Refusals.Has(Found[1]) ? Refusals[Found[1]] : Refusals["relay_unavailable"]
}

/**
 * The digest the bundled relay must have, from its manifest. A binary without a
 * readable manifest is an invalid install, not an absent relay.
 * @param {String} ManifestPath ergopti-proxy-relay.json beside the binary.
 * @returns {String} The lowercase SHA-256 of the binary.
 */
LLM_OllamaProxyRelayDigest(ManifestPath) {
	Text := FSReadUtf8ExactBounded(ManifestPath, 4096)
	if !(Text is String)
		throw ValueError("The bundled proxy relay has no readable manifest.")
	Digest := JsonParse(Text).Get("exe_sha256", "")
	if !(Digest is String) || !RegExMatch(Digest, "^[0-9a-f]{64}$")
		throw ValueError("The bundled proxy relay manifest names no digest.")
	return Digest
}

/** One source-bound managed bootstrap, retaining physical debt independently. */
class OllamaManagedBootstrap {
	/** Captures every native source before admission; no installation occurs here. */
	__New(Model, Epoch, OnReady, OnFailed, Port := 0, Silent := false) {
		global _SharedDir, _StaticDir, _VendorDir, LLM_OLLAMA_BASE_URL, LLM_DEPS_POLL_TIMEOUT_MS, _LLM_Menu
		this.Port := Port
		; Restarting the installed runtime for an AI already on: no window and no
		; question. It never installs or downloads; the first READY ends the mode.
		this.Silent := Silent
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
		this.PullDigestRetried := false
		this.MenuPull := 0
		this.RuntimeRetired := false
		this.RuntimeRetiring := false
		this.Target := 0
		this.Timer := 0
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
			this.Timer := ObjBindMethod(this, "_Tick")
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
		Root := AppFoldersManagedOllamaRoot()
		Directory := _StaticDir . "\ergopti_plus\windows\modules\llm"
		Catalogue := _SharedDir . "\modules\llm\ollama_release.json"
		Updater := _SharedDir . "\modules\updater\defaults.json"
		Policy := _SharedDir . "\modules\network\proxy_policy.json"
		ServeEnvironment := _SharedDir . "\modules\llm\managed_ollama_environment.json"
		RouteOrigins := _SharedDir . "\modules\network\route_origins.json"
		RelayContract := _SharedDir . "\modules\network\proxy_auth_relay.json"
		Helper := Directory . "\ollama_managed_files.ps1"
		Acquisition := Directory . "\ollama_managed_acquisition.ps1"
		Vendor := _VendorDir
		for Path in [Catalogue, Updater, Policy, ServeEnvironment, RouteOrigins, RelayContract, Helper, Acquisition,
			Directory . "\ollama_download_archive.ps1", Directory . "\ollama-runtime-launch.ps1",
			Directory . "\ollama-model-pull.ps1"]
			this.Sources[Path] := this._Hash(Path)
		Inventory := ""
		for Name in ["ergopti_updater_download.ps1", "ergopti_network_routes.ps1",
			"ergopti_windows_proxy_config.ps1", "ergopti_native_proxy_ex.ps1",
			"ergopti_network_pac.ps1", "ergopti_winhttp_transport.ps1"] {
			Path := Vendor . "\" . Name
			this.Sources[Path] := this._Hash(Path)
			Inventory .= Name . "`n" . this.Sources[Path] . "`n"
		}
		; The launcher's proxy dependencies, in the order its
		; Get-OllamaRuntimeVendorNames lists them (one digest over name and hash)
		RuntimeInventory := ""
		for Name in LLM_OLLAMA_RUNTIME_VENDOR_NAMES {
			Path := Vendor . "\" . Name
			if !this.Sources.Has(Path)
				this.Sources[Path] := this._Hash(Path)
			RuntimeInventory .= Name . "`n" . this.Sources[Path] . "`n"
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
			"on_physical", OllamaManagedBootstrap._UnstartedObserver,
			"on_error", OllamaManagedBootstrap._UnstartedObserver))
		RuntimeProxy := Map("VendorDirectory", Vendor, "VendorSha256", CryptoSha256(RuntimeInventory),
			"ProxyPolicyPath", Policy, "ProxyPolicySha256", this.Sources[Policy],
			"UpdaterDefaultsPath", Updater, "UpdaterDefaultsSha256", this.Sources[Updater],
			"RouteOriginsPath", RouteOrigins, "RouteOriginsSha256", this.Sources[RouteOrigins],
			"ProxyRelayContractPath", RelayContract, "ProxyRelayContractSha256", this.Sources[RelayContract],
			"ProxyRelayDialMs", TimingsGet("adapters", "proxy_relay_dial_timeout_ms"),
			"ProxyRelayHandshakeMs", TimingsGet("adapters", "proxy_relay_handshake_timeout_ms"),
			"ProxyRelayIdleMs", TimingsGet("adapters", "proxy_relay_idle_timeout_ms"),
			"ProxyRelayProbeMs", TimingsGet("adapters", "proxy_relay_probe_timeout_ms"))
		; Absent only in a checkout without the binary (docs/design/proxy-auth-relay.md).
		; The expected digest is the manifest's: hashing the file here would admit
		; whatever sits at this path. The launcher compares and holds the image.
		Relay := Vendor . "\" . LLM_OLLAMA_PROXY_RELAY_EXECUTABLE
		if FileExist(Relay) {
			RuntimeProxy["ProxyRelayPath"] := Relay
			RuntimeProxy["ProxyRelaySha256"] := LLM_OllamaProxyRelayDigest(Vendor . "\" . LLM_OLLAMA_PROXY_RELAY_MANIFEST)
		}
		this.Runtime := OllamaRuntimeOwner(Map("launcher", Directory . "\ollama-runtime-launch.ps1",
			"helper", Helper, "helper_sha256", this.Sources[Helper],
			"environment", ServeEnvironment, "environment_sha256", this.Sources[ServeEnvironment],
			"proxy", RuntimeProxy,
			"on_retired", OllamaManagedBootstrap._UnstartedObserver,
			"on_error", OllamaManagedBootstrap._UnstartedObserver))
		this._PublishConstructionObservers()
	}

	; Before constructor success there is no native task or physical receipt.
	; An unreachable callback keeps new ports acyclic through fallible capture.
	static _UnstartedObserver(*) {
		throw Error("Managed constructor observers cannot run before source capture completes.")
	}

	_PublishConstructionObservers() {
		; Prepare every fallible binding before any instance points back to this
		; flow. Failure releases these local references with the constructor frame.
		Physical := ObjBindMethod(this, "_Physical")
		ErrorObserver := ObjBindMethod(this, "_Error")
		Retired := ObjBindMethod(this, "_RuntimeRetired")
		Polling := ObjBindMethod(this, "_Tick")
		PreviousCritical := Critical("On")
		try {
			; Existing slots of the freshly constructed native ports, RAM only.
			this.Files.Options["on_physical"] := Physical
			this.Files.Options["on_error"] := ErrorObserver
			this.Runtime.Options["on_retired"] := Retired
			this.Runtime.Options["on_error"] := ErrorObserver
			this.Timer := Polling
		} finally Critical(PreviousCritical)
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
			; READY outlives ordinary saves: a running daemon only follows the AI
			; intent, and hashing every source each tick would tax the session.
			if this.Ready
				return this._ReadyIntentCurrent(_LLM_Menu, LLM_AuxGeneration())
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
		if !(this.Target is Map) || !this.Runtime.HasOwner() || !(this._RuntimeReadyRecord(this.Target) is Map)
			return false
		return this.Runtime.IdentityReady()
	}

	; This pure state predicate can also guard the short readiness publication.
	_RuntimeReadyRecord(Target) {
		if !(Target is Map) || !(this.Target is Map)
			return false
		Record := this.Runtime.Record
		if !(Record is Map) || !this._True(Record.Get("accepted", false)) || !this._True(Record.Get("ready", false))
				|| !(Record.Get("cancelled", "") is Integer) || Record["cancelled"] != false
				|| !(Record.Get("terminal", "") is Integer) || Record["terminal"] != false || !(Record.Get("target", 0) is Map)
			return false
		for Name in ["origin", "runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256"]
			if Record["target"].Get(Name, "") != Target[Name] || Target[Name] != this.Target[Name]
				return false
		return Record
	}

	/** Exact borrowed enable writer successor; no arbitrary source recapture. */
	PrepareEnableHandoff(Source, Expected) {
		if !this.Ready || !this._Current() || !this.HasOwnProp("Source")
				|| !(this.MenuIntent["enabled"] is Integer) || this.MenuIntent["enabled"] != false
				|| !_LLM_Menu_EnableSourceMatches(this.Source, Source)
				|| !(Expected is Map) || !(Expected.Get("bytes", 0) is Buffer)
				|| Expected.Get("path", "") != Source["path"] || IsObject(this.EnableHandoff)
			return 0
		MenuIntent := this.MenuIntent.Clone()
		MenuIntent["enabled"] := true
		Token := Map("source", Expected, "menu", MenuIntent, "generation", this.AuxGeneration)
		this.EnableHandoff := Token
		return Token
	}

	FinishEnableHandoff(Token) {
		if !(Token is Map) || !IsObject(this.EnableHandoff) || Token != this.EnableHandoff
				|| !this._Current()
			return false
		if this.Port is Map
			Source := this.Port["read_source"].Call(), MenuIntent := this.Port["menu_intent"].Call()
		else {
			global _LLM_Menu
			Source := _LLM_Menu_EnableReadSource(), MenuIntent := _LLM_Menu
		}
		if !_LLM_Menu_EnableSourceMatches(Token["source"], Source) || !this._IntentMatches(Token["menu"], MenuIntent)
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

	_ReadyIntentCurrent(Menu, Generation) {
		if Generation != this.AuxGeneration
			return false
		Token := this.EnableHandoff
		return this._IntentMatches(this.MenuIntent, Menu)
			|| (Token is Map && this._IntentMatches(Token["menu"], Menu))
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
		if this.Silent
			return Kind == "start"
		if this.Port is Map
			Accepted := this.Port["consent"].Call(Kind, Model)
		else {
			if Kind == "install"
				Title := t("ollama.native_offer_title"), Body := StrReplace(t("ollama.native_offer_body"), "%s", this.Plan["version"])
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
		if Receipt.Get("pac_fallback_stage", "") != ""
			LoggerWarn("LLM.managed", "Automatic proxy configuration unusable at {1}; the download went direct.",
				Receipt["pac_fallback_stage"])
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
		return this._ArmPolling()
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
		if !this._Current()
			return this.Cancel()
		PreviousCritical := Critical("On")
		try {
			Record := this._RuntimeReadyRecord(Target)
			if this.Cancelled || this.Failed || !(Record is Map)
				return false
			this.ServerReady := true
			this.Target["ready_file_identity"] := Receipt["ready_file_identity"]
			this.Target["ready_image_sha256"] := Record["ready_image_sha256"]
		} finally Critical(PreviousCritical)
		; A closed value, never a proxy or a token: what the network check would report.
		RelayState := Receipt.Get("proxy_relay", "not_applicable")
		if RelayState == "relay_not_installed"
			LoggerWarn("LLM.managed", "The proxy demands a Windows sign-in and the local relay is not installed: pulls are refused.")
		else if RelayState != "not_applicable"
			LoggerInfo("LLM.managed", "Managed Ollama proxy sign-in relay: {1}.", RelayState)
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
		; The local model offer names a missing model on first use, not at login.
		if this.Silent
			return this._Complete()
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
			return this._MenuPullDispatch(Operation)
		} catch as Err {
			this._MenuPullFail(Operation)
			throw Err
		}
	}

	/** Starts the operation's pull, its first or its retry, and observes its percentage. */
	_MenuPullDispatch(Operation) {
		Done := ObjBindMethod(this, "_MenuPulled", Operation)
		Accepted := this.Port is Map
			? this.Port["pull"].Call(this.Target.Clone(), Operation["tag"], Done) : this._NativePull(Operation["tag"], Done)
		if !this._True(Accepted) && this.MenuPull == Operation
			return this._MenuPullFail(Operation)
		if this._True(Accepted) && !(this.Port is Map) && this.PullTask is Map
			this._PollMenuPullPercent(Operation, this.PullTask, "")
		return this._True(Accepted)
	}

	/**
	 * Reads the running menu pull's percentage from its capture and tells the
	 * page each new whole one, then "" once the pull ended.
	 * @param {Map} Operation The menu pull.
	 * @param {Map} PullOwner Its native task owner.
	 * @param {Integer|String} Told The percentage last told.
	 */
	_PollMenuPullPercent(Operation, PullOwner, Told) {
		global LLM_PULL_PERCENT_LISTENER, LLM_PULL_PERCENT_TAIL_BYTES
		Listener := LLM_PULL_PERCENT_LISTENER
		if (this.MenuPull != Operation || this.PullTask != PullOwner || !IsObject(PullOwner.Get("task", 0))) {
			if HasMethod(Listener, "Call")
				try Listener.Call(Operation["tag"], "")
				catch as Err
					LoggerWarn("LLM.managed", "Pull percentage observer raised: {1}.", Err.Message)
			return false
		}
		Percent := ""
		try Percent := LLM_OllamaPullPercent(PullOwner["task"].outputTail(LLM_PULL_PERCENT_TAIL_BYTES))
		; Paused, the page is told nothing; the pull itself keeps running.
		if (!A_IsSuspended && Percent != "" && Percent != Told && HasMethod(Listener, "Call")) {
			Told := Percent
			try Listener.Call(Operation["tag"], Percent)
			catch as Err
				LoggerWarn("LLM.managed", "Pull percentage observer raised: {1}.", Err.Message)
		}
		SetTimer(ObjBindMethod(this, "_PollMenuPullPercent", Operation, PullOwner, Told),
			-TimingsGet("llm", "pull_progress_poll_ms"))
		return true
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

	_MenuPullFail(Operation, MessageKey := "ollama.runtime_repair_failed") {
		if !(Operation is Map) || this.MenuPull != Operation || Operation["failed"]
			return false
		Operation["failed"] := true
		LoggerError("LLM.managed", "Managed menu model download failed ({1}); cancelling its retained owners.", MessageKey)
		try {
			this._Ui(MessageKey, Operation["tag"])
			if !(this.Port is Map) && this.UiShown && !A_IsSuspended
				OllamaWV_SetError(this._Message(MessageKey, Operation["tag"]))
		} finally this.Cancel()
		return false
	}

	_MenuPulled(Operation, ExitCode, Stdout := "", *) {
		global LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT
		if !this._MenuPullCurrent(Operation)
			return false
		if (ExitCode is Integer) && ExitCode == LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT
			return this._MenuPullFail(Operation, LLM_OllamaPullRefusalKey(Stdout))
		if !(ExitCode is Integer) || ExitCode != 0 {
			ErrorClass := LLM_OllamaPullErrorClass(Stdout)
			if ErrorClass != "digest_mismatch" {
				LoggerError("LLM.managed", "Managed menu model download exited {1} (class '{2}').", ExitCode, ErrorClass)
				return this._MenuPullFail(Operation)
			}
			if Operation.Get("digest_retried", false)
				return this._MenuPullFail(Operation, "ollama.digest_mismatch")
			Operation["digest_retried"] := true
			this._LogDigestRetry()
			return this._MenuPullDispatch(Operation)
		}
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
			Factory := HasMethod(SpawnFn, "Call") ? SpawnFn : ProxyOverride_SpawnWorker
			Task := Factory.Call(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
				Args, ObjBindMethod(this, "_Pulled", Owner), , , LLM_OLLAMA_PULL_CAPTURE_BYTES, true, true)
			Owner["task"] := Task
			Accepted := this._Current() && this._True(Task.start()) && this._Current()
			Owner["accepted"] := Accepted
		} catch as Err {
			this._Error("model_dispatch", Err)
		} finally {
			Owner["building"] := false
			if Owner["terminal"] is Map
				this._Pulled(Owner, Owner["terminal"]["exit"], Owner["terminal"]["stdout"])
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
			Owner["terminal"] := Map("exit", ExitCode, "stdout", Stdout)
			return false
		}
		Owner["task"] := 0
		this.PullTask := 0
		if Owner["accepted"] && HasMethod(Owner.Get("callback", 0), "Call")
			return Owner["callback"].Call(ExitCode, Stdout)
		return Owner["accepted"] ? this._PullResult(ExitCode, Stdout) : this.Cancel()
	}

	_PullResult(ExitCode, Stdout := "", Stderr := "") {
		global LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT
		if !this._Current()
			return this.Cancel()
		if (ExitCode is Integer) && ExitCode == LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT
			return this._Fail("model_pull_proxy_login", LLM_OllamaPullRefusalKey(Stdout))
		if !(ExitCode is Integer) || ExitCode != 0 {
			ErrorClass := LLM_OllamaPullErrorClass(Stdout)
			if ErrorClass != "digest_mismatch"
				return this._Fail(ErrorClass == "" ? "model_pull" : "model_pull_" . ErrorClass)
			if this.PullDigestRetried
				return this._Fail("model_pull_digest_mismatch", "ollama.digest_mismatch", this.Model)
			this.PullDigestRetried := true
			this._LogDigestRetry()
			if this.Port is Map
				return this.Port["pull"].Call(this.Target.Clone(), this.Model, ObjBindMethod(this, "_PullResult"))
			return this._NativePull()
		}
		return this._Models()
	}

	; Ollama deletes a layer whose sha256 does not match before it reports the
	; mismatch, so one more pull downloads it afresh (macOS field run of 2026-10-31).
	_LogDigestRetry() {
		LoggerWarn("LLM.managed", "The model pull failed its digest check; Ollama removed the layer, so it is pulled once more.")
	}

	_Complete() {
		global _LLM_Deps_State, _LLM_Deps_Checking
		if !this._Current()
			return this.Cancel()
		this.Ready := true
		this.Silent := false
		if !this._ArmPolling()
			return false
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
		; Runtime terminal delivery deliberately has no live task. Revalidate the
		; bootstrap's source and captured target, not runtime READY currentness.
		Captured := this.Target
		if !(Target is Map) || !(Captured is Map)
			return false
		for Name in ["origin", "runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256"]
			if !(Target.Get(Name, 0) is String) || !(Target[Name] == Captured[Name])
				return false
		if !this._Current() {
			this.Cancel()
			return false
		}
		if this.Target != Captured
			return false
		return this._Fail("runtime_exit")
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

	; Native readiness can cancel inline before the original arming caller returns.
	_ArmPolling() {
		PreviousCritical := Critical("On")
		try {
			if this.Cancelled || this.Failed || !IsObject(this.Timer)
				return false
			SetTimer(this.Timer, 150)
			return true
		} finally Critical(PreviousCritical)
	}

	; Keep the existing callback while native/file debt still needs this owner.
	; CanReplace has already settled the yielding auxiliary cleanup check.
	_RetirePolling() {
		PreviousCritical := Critical("On")
		try {
			if !this.Cancelled || this.Files.HasOwner() || this.Runtime.HasOwner()
					|| IsObject(this.PullTask) || this.Debts.Count
				return false
			if this.Files is OllamaInstallFilesPort && !this.Files.RetireCallbacks(&FileObservers)
				return false
			if this.Runtime is OllamaRuntimeOwner && !this.Runtime.RetireCallbacks(&RuntimeObservers)
				return false
			this.Timer := 0
			return true
		} finally Critical(PreviousCritical)
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
		if IsObject(this.Timer)
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
		if !(AuxStopped && PullStopped && FilesStopped && RuntimeStopped && this.Debts.Count == 0)
				|| !this.CanReplace()
			return false
		return this._RetirePolling()
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

	_Fail(Phase, MessageKey := "ollama.runtime_repair_failed", Model := "") {
		global _LLM_Deps_Epoch
		if this.Cancelled || A_IsSuspended || this.Epoch != _LLM_Deps_Epoch {
			this.Cancel()
			return false
		}
		if !this.Failed {
			if !(this.Port is Map)
				this._Ui(MessageKey, Model)
			; UI can call the real cancellation path. Claim only current failure
			; state under Critical; native cleanup and file-backed logs stay out.
			Claimed := false
			PreviousCritical := Critical("On")
			try {
				if !this.Cancelled && !this.Failed && !A_IsSuspended && this.Epoch == _LLM_Deps_Epoch {
					this.Failed := true
					Claimed := true
				}
			} finally Critical(PreviousCritical)
			if !Claimed {
				this.Cancel()
				return false
			}
			LoggerError("LLM.managed", "Managed bootstrap failed at {1}; retained owners remain explicit.", Phase)
			if !this.Cancelled && !A_IsSuspended && this.Epoch == _LLM_Deps_Epoch {
				if !(this.Port is Map) && this.UiShown
					OllamaWV_SetError(this._Message(MessageKey, Model))
				if !this.Cancelled && !A_IsSuspended && this.Epoch == _LLM_Deps_Epoch {
					if HasMethod(this.OnFailed, "Call")
						_LLM_Deps_PublishFailure(this._Message(MessageKey, Model), this.OnFailed, this.Epoch)
					else
						_LLM_Deps_PublishFailure(this._Message(MessageKey, Model), , this.Epoch)
				}
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

	; A message that names the model carries it in its %s.
	_Message(Key, Model := "") {
		return Model == "" ? t(Key) : StrReplace(t(Key), "%s", Model)
	}

	_Ui(Key, Model := "") {
		if this.Port is Map || this.Silent || !this._Current()
			return
		if !this.UiShown {
			OllamaWV_Show("ollama_install", t("ollama.install_subtitle"), (*) => LLM_Deps_Cancel(), ObjBindMethod(this, "_Retry"))
			this.UiShown := true
			if !this._ArmPolling()
				return
		}
		OllamaWV_SetStep(this._Message(Key, Model))
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
