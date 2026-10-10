; ui/menu/menu_llm/local_server_panel.ahk

; ==============================================================================
; MODULE: Native Local Server Menu Panel
; DESCRIPTION:
; Binds the shared row policy to exact private source/view ownership, the native
; models transport and existing joint API publisher. Initialization waits for
; restored runtime state. Discovery never installs or starts a server.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LLM_LocalServerPanel := 0
global _LLM_LocalServerPanelInitBusy := false





; =======================================
; =======================================
; ======= 1/ Panel Initialization =======
; =======================================
; =======================================

/** Creates one native panel after restored AI runtime ownership is available. */
LLM_Menu_LocalServersInit(RequestBuild := true) {
	global _LLM_LocalServerPanel, _LLM_LocalServerPanelInitBusy
	global _LLM_Menu_Loaded, _LLM_Menu_RuntimeActivated, LLM_LOCAL_API_SERVERS
	PreviousCritical := Critical("Off")
	try {
		if !IsSet(_LLM_Menu_Loaded) || !_LLM_Menu_Loaded
				|| !IsSet(_LLM_Menu_RuntimeActivated) || !_LLM_Menu_RuntimeActivated
			return false
		if !(LLM_LOCAL_API_SERVERS is Map) || LLM_LOCAL_API_SERVERS.Count == 0 {
			LoggerWarn("LLM.local_servers", "Local server menu initialization refused an unavailable catalogue.")
			return false
		}
		ClaimCritical := Critical("On")
		try {
			if _LLM_LocalServerPanel is LLM_LocalServerPanel
				return true
			if _LLM_LocalServerPanelInitBusy
				return false
			_LLM_LocalServerPanelInitBusy := true
		} finally Critical(ClaimCritical)
		try {
			LoggerStart("LLM.local_servers", "Initializing local server menu ownership…")
			Panel := LLM_LocalServerPanel()
			ClaimCritical := Critical("On")
			try _LLM_LocalServerPanel := Panel
			finally Critical(ClaimCritical)
		} finally {
			ClaimCritical := Critical("On")
			try _LLM_LocalServerPanelInitBusy := false
			finally Critical(ClaimCritical)
		}
		LoggerSuccess("LLM.local_servers", "Local server menu owner initialized.")
		if RequestBuild
			LLM_Menu_RequestBuild("local_servers_initialized")
		return true
	} finally Critical(PreviousCritical)
}

/** Returns native rows without creating a runtime during detached boot staging. */
LLM_Menu_LocalServersRows() {
	global _LLM_LocalServerPanel
	if !IsSet(_LLM_LocalServerPanel) || !(_LLM_LocalServerPanel is LLM_LocalServerPanel)
		return MenuRenderer_StatusRows("llm_menu", "llm_backend", "unavailable")
	return _LLM_LocalServerPanel.Rows()
}

/** Resolves the precise checked provider without probing or invalidating a view. */
LLM_Menu_LocalServersBackendLabel(Fallback) {
	global _LLM_LocalServerPanel
	return IsSet(_LLM_LocalServerPanel) && _LLM_LocalServerPanel is LLM_LocalServerPanel
		? _LLM_LocalServerPanel.BackendLabel(Fallback) : Fallback
}

/** Pausing invalidates publication before requesting exact native retirement. */
LLM_Menu_LocalServersOnSuspend() {
	global _LLM_LocalServerPanel
	return !IsSet(_LLM_LocalServerPanel) || !(_LLM_LocalServerPanel is LLM_LocalServerPanel)
		|| _LLM_LocalServerPanel.Retire(false)
}

/** Resumes retained resource cleanup and asks for a fresh menu/source capture. */
LLM_Menu_LocalServersOnResume() {
	global _LLM_LocalServerPanel
	if A_IsSuspended
		return false
	if !LLM_Menu_LocalServersInit(false)
		return false
	return _LLM_LocalServerPanel.ResumeRequested()
}

/** Completes only the exact successful transition that retained resume intent. */
LLM_Menu_LocalServersResumeFinished(Transition) {
	global _LLM_LocalServerPanel
	return !IsSet(_LLM_LocalServerPanel) || !(_LLM_LocalServerPanel is LLM_LocalServerPanel)
		|| _LLM_LocalServerPanel.ResumeFinished(Transition)
}

/** Queues recovery after an honored veto; no source I/O runs on the OnExit stack. */
LLM_Menu_LocalServersShutdownRefused(Attempt) {
	global _LLM_LocalServerPanel
	return !IsSet(_LLM_LocalServerPanel) || !(_LLM_LocalServerPanel is LLM_LocalServerPanel)
		|| _LLM_LocalServerPanel.ShutdownRefused(Attempt)
}

/** Shutdown may refuse until this owner's exact HTTP and queue debts settle. */
LLM_Menu_LocalServersPrepareShutdown() {
	global _LLM_LocalServerPanel
	return !IsSet(_LLM_LocalServerPanel) || !(_LLM_LocalServerPanel is LLM_LocalServerPanel)
		|| _LLM_LocalServerPanel.Retire(false)
}





; ====================================
; ====================================
; ======= 2/ Native View Owner =======
; ====================================
; ====================================

class LLM_LocalServerPanel {
	__New(Options := unset) {
		global LLM_LOCAL_API_SERVERS, LLM_API_PROVIDER_ORDER
		if !(LLM_LOCAL_API_SERVERS is Map) || LLM_LOCAL_API_SERVERS.Count == 0
				|| !(LLM_API_PROVIDER_ORDER is Array)
			throw Error("The local AI server catalogue is unavailable.")
		this.Servers := LLM_LOCAL_API_SERVERS
		this.Order := []
		for Id in LLM_API_PROVIDER_ORDER
			if this.Servers.Has(Id)
				this.Order.Push(Id)
		if this.Order.Length != this.Servers.Count
			throw Error("The local AI server catalogue ordering is incomplete.")
		if IsSet(Options) && !(Options is Map)
			throw TypeError("Local server panel options must be a Map.")
		this.Options := IsSet(Options) ? Options.Clone() : Map()
		for Name in ["format", "notify", "build", "timer"]
			if this.Options.Has(Name) && !HasMethod(this.Options[Name], "Call")
				throw TypeError("Local server panel observer port must be callable.", -1, Name)
		this.Source := this.Options.Get("source_owner", 0)
		if (this.Source is Integer) && this.Source == 0
			this.Source := LLM_Menu_ApiPrivateSourceOwner()
		if !(this.Source is LLM_Menu_ApiPrivateSourceOwner)
			throw TypeError("Local server panel requires the native private source owner.")
		this.ResumeIntent := 0
		this.Repair := 0
		this.Discovery := 0
		this.DiscoveryGeneration := 0
		this.RepairRecords := Map()
		this.RepairGeneration := 0
		this.Generation := 0
		this.View := 0
		this.LastSnapshot := 0
		this.Writing := false
		this.Models := this.Options.Get("models_owner", 0)
		if (this.Models is Integer) && this.Models == 0
			this.Models := LocalServerModelsOwner(Map("servers", this.Servers,
			"timeout_ms", TimingsGet("llm", "local_server_probe_timeout_ms"),
			"poll_ms", TimingsGet("llm", "poll_interval_ms"),
			"on_error", ObjBindMethod(this, "_Error")))
		Ports := this.Source.Ports()
		Ports["order"] := this.Order
		Ports["servers"] := this.Servers
		Ports["models_owner"] := this.Models
		Ports["poll_ms"] := TimingsGet("llm", "poll_interval_ms")
		Ports["clock"] := ObjBindMethod(this, "_Clock")
		Ports["max_age"] := (*) => TimingsGet("llm", "local_server_detection_max_age_ms")
		Ports["on_publish"] := ObjBindMethod(this, "_Published")
		Ports["on_error"] := ObjBindMethod(this, "_Error")
		if !(this.Models is LocalServerModelsOwner)
			throw TypeError("Local server panel requires the owned native models transport.")
		this.Native := this.Options.Get("native_owner", 0)
		if (this.Native is Integer) && this.Native == 0
			this.Native := LocalServersOwner(Ports)
		if !(this.Native is LocalServersOwner)
			throw TypeError("Local server panel requires the owned native controller.")
	}

	_Clock() {
		return DllCall("Kernel32\GetTickCount64", "UInt64")
	}

	_Format(Key, Values*) {
		if this.Options.Has("format")
			return this.Options["format"].Call(Key, Values*)
		return Format(t(Key), Values*)
	}

	_Build(Reason) {
		Build := this.Options.Get("build", LLM_Menu_RequestBuild)
		return Build.Call(Reason)
	}

	_Error(Kind, Detail, Id := "") {
		; Transport errors can contain private request data. Only the fixed
		; error kind and known provider identity belong in this panel's log.
		Provider := this.Servers.Has(Id) ? Id : ""
		LoggerWarn("LLM.local_servers", "Local server {1} owner reported '{2}'.", Provider, Kind)
	}

	_Published(Results, Changed) {
		; Even an identical accepted rescan owns a new cache identity. A fresh
		; source/view capture must therefore follow every acknowledged result.
		this._Build("local_servers_published")
	}

	/** Retains display-only data under pause; native actions require a live view. */
	Rows() {
		global _LLM_Menu_ApiPrivateAuthorityGeneration
		PreviousCritical := Critical("Off")
		try {
			if A_IsSuspended || this.Writing
				return this.LastSnapshot is Map ? this._Render(this.LastSnapshot, true, 0) : this._UnavailableRows()
			if !this.Source.Admit()
				return this._UnavailableRows()
			Source := this.Source.Capture()
			if !IsObject(Source)
				return this._UnavailableRows()
			Projection := this.Native.CaptureView(Source)
			if !(Projection is Map)
				return this._UnavailableRows()
			if Projection["stale"] {
				; Discovery is optional work: a menu build must not enter managed
				; HTTP acquisition or hold the driver's startup readiness stack.
				this._QueueDiscovery(Source)
				return this._UnavailableRows()
			}
			Entries := Projection["entries"]
			Owner := Map("source", Source, "receipts", Projection["receipts"],
				"native_view", Projection["view"], "native_models", Projection["models"],
				"native_configuration", Projection["configuration"], "native_cache", Projection["cache"],
				"native_rescan", Projection["rescan"], "native_controller", Projection["controller"],
				"authority", Entries["authority"])
			Snapshot := Map("results", Projection["results"], "detected", Projection["detected"],
				"active", 0, "backend", Entries["backend"], "sweeping", Projection["sweeping"],
				"authority", Entries["authority"],
				"menu_owner", Entries["menu_owner"], "active_id", Entries["active_id"])
			for Id in this.Order {
				Entry := Entries["entries"][Id]
				if Entry is Map && Entry["Id"] == Snapshot["active_id"] {
					Snapshot["active"] := Map("provider", Id, "model", Entry["Model"])
					break
				}
			}
			ClaimCritical := Critical("On")
			try {
				Ready := !A_IsSuspended && !this.Writing
				if Ready {
					Owner["generation"] := ++this.Generation
					this.View := Owner
				}
			} finally Critical(ClaimCritical)
			if !Ready
				return this._UnavailableRows()
			Rows := this._Render(Snapshot, false, Owner)
			if !this.Source.Current(Source)
				return this._UnavailableRows()
			ClaimCritical := Critical("On")
			try {
				Ready := this._HeldCurrent(Owner)
				if Ready
					this.LastSnapshot := Snapshot
			} finally Critical(ClaimCritical)
			return Ready ? Rows : this._UnavailableRows()
		} catch as Err {
			this._Error("view", Err)
			return this._UnavailableRows()
		} finally Critical(PreviousCritical)
	}

	_ActiveSnapshot(Snapshot) {
		global _LLM_Menu
		Menu := _LLM_Menu
		if !(Menu is Map)
			return false
		Snapshot["backend"] := Menu.Get("backend", "")
		Snapshot["menu_owner"] := Menu
		EntryId := Menu.Get("api_entry_id", "")
		Snapshot["active_id"] := EntryId
		for Id in this.Order {
			Entry := this.Source.Entry(Id)
			if Entry is Map && Entry["Id"] == EntryId {
				Snapshot["active"] := Map("provider", Id, "model", Entry["Model"])
				break
			}
		}
		return true
	}

	_SnapshotResult(Snapshot, Id) {
		return Snapshot["results"].Get(Id, 0)
	}

	_Render(Snapshot, Paused, Owner) {
		return LocalServerMenuRows(Map("order", this.Order, "servers", this.Servers,
			"detected", Snapshot["detected"], "result", ObjBindMethod(this, "_SnapshotResult", Snapshot),
			"backend", Snapshot["backend"], "active", Snapshot["active"],
			"sweeping", Snapshot["sweeping"], "paused", Paused, "tr", t,
			"format", ObjBindMethod(this, "_Format"), "actions", Map(
				"select", ObjBindMethod(this, "_Select", Owner),
				"address", ObjBindMethod(this, "_Address", Owner),
				"key", ObjBindMethod(this, "_Key", Owner),
				"rescan", ObjBindMethod(this, "_Rescan", Owner))))
	}

	_UnavailableRows() {
		return MenuRenderer_StatusRows("llm_menu", "llm_backend", "unavailable")
	}

	/** Does not mint a receipt or produce HTTP work while resolving the row title. */
	BackendLabel(Fallback) {
		PreviousCritical := Critical("Off")
		try return this._BackendLabelNonCritical(Fallback)
		finally Critical(PreviousCritical)
	}

	_BackendLabelNonCritical(Fallback) {
		global _LLM_Menu, _LLM_Menu_ApiPrivateAuthorityGeneration
		Snapshot := this.LastSnapshot
		if !(Snapshot is Map) || !(_LLM_Menu is Map) || _LLM_Menu.Get("backend", "") != "api"
				|| _LLM_Menu_ApiPrivateAuthorityGeneration != Snapshot["authority"]
				|| ObjPtr(_LLM_Menu) != ObjPtr(Snapshot["menu_owner"])
				|| !(_LLM_Menu.Get("api_entry_id", "") == Snapshot["active_id"])
			return Fallback
		Label := Fallback
		for Row in this._Render(Snapshot, true, 0)
			if Row.Get("checked", false)
				Label := _LLM_Menu_OptionHead(Row["label"])
		return _LLM_Menu_ApiPrivateAuthorityGeneration == Snapshot["authority"]
			&& ObjPtr(_LLM_Menu) == ObjPtr(Snapshot["menu_owner"])
			&& (_LLM_Menu.Get("backend", "") == "api")
			&& (_LLM_Menu.Get("api_entry_id", "") == Snapshot["active_id"]) ? Label : Fallback
	}

	_Current(Owner, Id := "", Model := "") {
		if !(Owner is Map) || A_IsSuspended || this.Writing || !this.Source.Current(Owner["source"])
			return false
		if Id != "" && (!Owner["receipts"].Has(Id) || !this.Native.IsCurrent(Owner["receipts"][Id], Model))
			return false
		if !this.Source.Current(Owner["source"])
			return false
		PreviousCritical := Critical("On")
		try return this._HeldCurrent(Owner)
		finally Critical(PreviousCritical)
	}

	_HeldCurrent(Owner) {
		global _LLM_Menu_ApiPrivateAuthorityGeneration
		return this.View is Map && ObjPtr(this.View) == ObjPtr(Owner)
			&& Owner["generation"] == this.Generation && Owner["native_view"] == this.Native.ViewGeneration
			&& Owner["native_models"] == this.Native.ModelGeneration
			&& Owner["native_configuration"] == this.Native.ConfigurationGeneration
			&& Owner["native_cache"] == this.Native.Cache
			&& Owner["native_rescan"] == this.Native.RescanGeneration
			&& Owner["native_controller"] == this.Native.Controller.Generation
			&& Owner["authority"] == _LLM_Menu_ApiPrivateAuthorityGeneration
			&& !A_IsSuspended && !this.Writing
	}





; ===================================
; ===================================
; ======= 3/ Retained Actions =======
; ===================================
; ===================================

	_Select(Owner, Id, Model, *) {
		return this._Apply(Owner, Id, Map("model", Model), Model)
	}

	_Address(Owner, Id, *) {
		PreviousCritical := Critical("Off")
		try return this._PromptAddress(Owner, Id)
		finally Critical(PreviousCritical)
	}

	_PromptAddress(Owner, Id) {
		if !this._Current(Owner, Id)
			return false
		Target := this.Native.Target(Id, Owner["source"]), Server := this.Servers[Id]
		if !(Target is Map) || !this._Current(Owner, Id)
			return false
		Answer := Ui_InputBox(this._Format("dialog.local_servers.address_prompt", Server["label"], Server["base_url"]),
			t("menu.llm.local_servers.header"), "w560 h160", Target["base_url"])
		if !(Answer.Result == "OK") || !this._Current(Owner, Id)
			return false
		BaseUrl := Trim(Answer.Value)
		if BaseUrl == ""
			BaseUrl := Server["base_url"]
		if !_HTTP_CurlScalarIsSafe(BaseUrl) || !RegExMatch(BaseUrl, "i)^https?://[^[:space:]]+$") {
			Ui_MsgBox(this._Format("llm.local_servers.invalid_address", Server["base_url"]), Server["label"], "Iconx")
			return false
		}
		return this._Apply(Owner, Id, Map("base_url", BaseUrl))
	}

	_Key(Owner, Id, *) {
		PreviousCritical := Critical("Off")
		try return this._PromptKey(Owner, Id)
		finally Critical(PreviousCritical)
	}

	_PromptKey(Owner, Id) {
		if !this._Current(Owner, Id)
			return false
		Answer := Ui_InputBox(this._Format("dialog.local_servers.key_prompt", this.Servers[Id]["label"]),
			t("menu.llm.local_servers.header"), "Password w560 h160", "")
		if !(Answer.Result == "OK") || !this._Current(Owner, Id)
			return false
		return this._Apply(Owner, Id, Map("token", Answer.Value))
	}

	_Apply(Owner, Id, Fields, Model := "") {
		PreviousCritical := Critical("Off")
		try return this._ApplyNonCritical(Owner, Id, Fields, Model)
		finally Critical(PreviousCritical)
	}

	_ApplyNonCritical(Owner, Id, Fields, Model := "") {
		if !this._Current(Owner, Id, Model)
			return false
		PreviousCritical := Critical("On")
		try {
			if this.Writing || A_IsSuspended || !(this.View is Map) || ObjPtr(this.View) != ObjPtr(Owner)
				return false
			this.Writing := true
		} finally Critical(PreviousCritical)
		try Result := this.Native.Apply(Owner["receipts"][Id], Fields)
		finally {
			PreviousCritical := Critical("On")
			try this.Writing := false
			finally Critical(PreviousCritical)
		}
		if !(Result is Map)
			return false
		Saved := Result.Get("saved", 0), Pending := Result.Get("pending", 0)
		if !((Saved is Integer) && Saved == 1) && !((Pending is Integer) && Pending == 1)
			return false
		PreviousCritical := Critical("On")
		try {
			this.View := 0
			this.Generation += 1
		} finally Critical(PreviousCritical)
		LLM_Menu_RequestBuild("local_servers_applied")
		if Model == ""
			this.Native.Rescan(ObjBindMethod(this, "_ReportSweep", Id))
		return true
	}

	_Rescan(Owner, *) {
		PreviousCritical := Critical("Off")
		try return this._RescanNonCritical(Owner)
		finally Critical(PreviousCritical)
	}

	_RescanNonCritical(Owner) {
		if !this._Current(Owner)
			return false
		Started := this.Native.Rescan()
		if Started
			LLM_Menu_RequestBuild("local_servers_rescan")
		return Started
	}

	_ReportSweep(Id, Changed) {
		PreviousCritical := Critical("Off")
		try return this._ReportSweepNonCritical(Id)
		finally Critical(PreviousCritical)
	}

	_ReportSweepNonCritical(Id) {
		global _LLM_Menu_ApiPrivateAuthorityGeneration
		if A_IsSuspended || this.Writing || !this.Source.Admit() || !this.Servers.Has(Id)
			return false
		Source := this.Source.Capture()
		Receipt := this.Native.Capture(Id)
		if !IsObject(Source) || !IsObject(Receipt)
			return false
		Stamp := Map("source", Source, "receipt", Receipt, "generation", this.Generation,
			"view", this.Native.ViewGeneration, "models", this.Native.ModelGeneration,
			"configuration", this.Native.ConfigurationGeneration, "cache", this.Native.Cache,
			"rescan", this.Native.RescanGeneration, "controller", this.Native.Controller.Generation,
			"authority", _LLM_Menu_ApiPrivateAuthorityGeneration,
			"epoch", _LLM_Menu_ApiPrivateLifecycleState()["generation"])
		Verdict := this.Native.Result(Id)
		if !(Verdict is Map) || !this._ReportCurrent(Stamp)
			return false
		Server := this.Servers[Id]
		if Verdict["status"] == "up"
			Body := this._Format("llm.local_servers.found_body", Verdict["models"].Length)
		else if Verdict["status"] == "needs_key"
			Body := this._Format("menu.llm.local_servers.needs_key", Server["label"])
		else
			Body := this._Format("menu.llm.local_servers.none", LocalServerMenuHost(Verdict["base_url"]))
		if !(Body is String)
			throw TypeError("Local server report formatting must return text.")
		if !this._ReportCurrent(Stamp)
			return false
		Icon := Verdict["status"] == "up" ? "Iconi" : "Icon!"
		ClaimCritical := Critical("On")
		try {
			if !this._ReportHeldCurrent(Stamp)
				return false
			; Production publication is the bounded native effect. Observer ports
			; run outside Critical and only observe current-at-claim authority.
			if !this.Options.Has("notify") {
				TrayTip(Body, Server["label"], Icon)
				return true
			}
		} finally Critical(ClaimCritical)
		this.Options["notify"].Call(Body, Server["label"], Icon)
		return true
	}

	_ReportCurrent(Stamp) {
		if !this.Source.Current(Stamp["source"]) || !this.Native.IsCurrent(Stamp["receipt"])
				|| !this.Source.Current(Stamp["source"])
			return false
		ClaimCritical := Critical("On")
		try return this._ReportHeldCurrent(Stamp)
		finally Critical(ClaimCritical)
	}

	_ReportHeldCurrent(Stamp) {
		global _LLM_Menu_ApiPrivateAuthorityGeneration
		State := _LLM_Menu_ApiPrivateLifecycleState()
		return !A_IsSuspended && !this.Writing && Stamp["generation"] == this.Generation
			&& Stamp["view"] == this.Native.ViewGeneration && Stamp["models"] == this.Native.ModelGeneration
			&& Stamp["configuration"] == this.Native.ConfigurationGeneration && Stamp["cache"] == this.Native.Cache
			&& Stamp["rescan"] == this.Native.RescanGeneration && Stamp["controller"] == this.Native.Controller.Generation
			&& Stamp["authority"] == _LLM_Menu_ApiPrivateAuthorityGeneration
			&& Stamp["epoch"] == State["generation"] && State["attempt"] == 0 && !this.Native.Closed
	}


	/** Retains automatic discovery in the existing exact panel timer ledger. */
	_QueueDiscovery(Source) {
		if !this.Source.Current(Source)
			return false
		Prior := this.Discovery
		if Prior is Map && !this._DiscoveryCurrent(Prior) {
			this._DropRepair(Prior)
			if !this.Source.Current(Source)
				return false
		}
		PreviousCritical := Critical("On")
		try {
			if this.Discovery is Map && this._DiscoveryCurrent(this.Discovery) {
				Record := this.Discovery
			} else {
			global _LifecycleLatestTransition, _LLM_Menu_ApiPrivateAuthorityGeneration
			State := _LLM_Menu_ApiPrivateLifecycleState()
			if A_IsSuspended || this.Writing || this.Native.Closed || State["attempt"] != 0
				return false
			Record := Map("kind", "discovery", "source", Source, "generation", this.Generation,
				"epoch", State["generation"], "intent", ++this.DiscoveryGeneration,
				"transition", _LifecycleLatestTransition, "authority", _LLM_Menu_ApiPrivateAuthorityGeneration,
				"configuration", this.Native.ConfigurationGeneration, "rescan", this.Native.RescanGeneration,
				"built", false, "busy", false, "resume", 0)
			Record["timer"] := ObjBindMethod(this, "_RepairTick", Record)
			this.Discovery := Record
			this.RepairRecords[ObjPtr(Record)] := Record
			}
		} finally Critical(PreviousCritical)
		return this._ArmRepair(Record)
	}

	_DiscoveryCurrent(Record) {
		global _LifecycleLatestTransition, _LLM_Menu_ApiPrivateAuthorityGeneration
		State := _LLM_Menu_ApiPrivateLifecycleState()
		return this.Discovery is Map && this.Discovery == Record
			&& this.RepairRecords.Get(ObjPtr(Record), 0) == Record
			&& !A_IsSuspended && !this.Writing && !this.Native.Closed
			&& Record["generation"] == this.Generation && Record["epoch"] == State["generation"]
			&& Record["intent"] == this.DiscoveryGeneration && State["attempt"] == 0
			&& Record["transition"] == _LifecycleLatestTransition
			&& Record["authority"] == _LLM_Menu_ApiPrivateAuthorityGeneration
			&& Record["configuration"] == this.Native.ConfigurationGeneration
			&& Record["rescan"] == this.Native.RescanGeneration
	}

	_DiscoveryReady() {
		global _DriverReady, _LLM_MenuBuildCoordinator
		return IsSet(_DriverReady) && (_DriverReady is Integer) && _DriverReady == 1
			&& IsSet(_LLM_MenuBuildCoordinator) && _LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator
			&& !_LLM_MenuBuildCoordinator.Active
	}

	_DiscoveryTick(Record) {
		PreviousCritical := Critical("Off")
		try {
			ClaimCritical := Critical("On")
			try {
				if Record["busy"] || this.RepairRecords.Get(ObjPtr(Record), 0) != Record
					return
				Record["busy"] := true
			} finally Critical(ClaimCritical)
			try {
				if !this._DiscoveryCurrent(Record) {
					this._DropRepair(Record)
					return
				}
				if !this._DiscoveryReady() {
					this._ArmRepair(Record)
					return
				}
				if !this.Source.Current(Record["source"]) {
					this._DropRepair(Record)
					return
				}
				if !this._DiscoveryCurrent(Record)
					return this._DropRepair(Record)
				if !this._DiscoveryReady()
					return this._ArmRepair(Record)
				this._RepairTimer(Record["timer"], 0)
				if !this._DiscoveryCurrent(Record)
					return this._DropRepair(Record)
				if !this._DiscoveryReady()
					return this._ArmRepair(Record)
				Accepted := this.Native.Rescan()
				this._DropRepair(Record)
				if (Accepted is Integer) && Accepted == 1
					this._Build("local_servers_deferred_discovery")
				else this._Error("rescan", Error("Deferred local discovery was refused."))
			} catch as Err {
				; A refused timer0 keeps the exact record in the ledger as debt.
				this._DropRepair(Record)
				this._Error("rescan", Err)
			} finally Record["busy"] := false
		} finally Critical(PreviousCritical)
	}

	/** Retains exact transition intent without publishing before Finish. */
	ResumeRequested() {
		global _LifecycleLatestTransition
		if A_IsSuspended
			return false
		Transition := _LifecycleLatestTransition
		if !(Transition is Object) || !(Transition.phase == "resume")
			return false
		this.ResumeIntent := Map("transition", Transition, "generation", this.Generation,
			"epoch", _LLM_Menu_ApiPrivateLifecycleState()["generation"])
		return true
	}

	/** Called by the lifecycle owner only after an exact successful Finish. */
	ResumeFinished(Transition) {
		PreviousCritical := Critical("Off")
		try return this._ResumeFinishedNonCritical(Transition)
		finally Critical(PreviousCritical)
	}

	_ResumeFinishedNonCritical(Transition) {
		global _LifecycleLatestTransition
		Intent := this.ResumeIntent
		if !(Intent is Map)
			return true
		if Intent["transition"] != Transition || _LifecycleLatestTransition != Transition
				|| !Transition.finished || Transition.debt.Length != 0
				|| Intent["generation"] != this.Generation
				|| Intent["epoch"] != _LLM_Menu_ApiPrivateLifecycleState()["generation"] || A_IsSuspended
			return false
		Queued := this._QueueRepair(false)
		if Queued && this.ResumeIntent is Map && this.ResumeIntent == Intent
			this.ResumeIntent := 0
		return Queued
	}

	/** Requires the exact just-canceled native attempt; timer starts after OnExit unwinds. */
	ShutdownRefused(Attempt) {
		PreviousCritical := Critical("Off")
		try return this._ShutdownRefusedNonCritical(Attempt)
		finally Critical(PreviousCritical)
	}

	_ShutdownRefusedNonCritical(Attempt) {
		State := _LLM_Menu_ApiPrivateLifecycleState()
		if !(Attempt is Integer) || Attempt <= 0 || State["attempt"] != 0 || State["generation"] != Attempt + 1
			return false
		return this._QueueRepair(true)
	}

	_QueueRepair(Deferred) {
		ClaimCritical := Critical("On")
		try {
			Intent := ++this.RepairGeneration
			Generation := this.Generation
			Epoch := _LLM_Menu_ApiPrivateLifecycleState()["generation"]
			global _LifecycleLatestTransition
			Transition := _LifecycleLatestTransition
		} finally Critical(ClaimCritical)
		if !this._DropRepairs()
			return false
		ClaimCritical := Critical("On")
		try {
			State := _LLM_Menu_ApiPrivateLifecycleState()
			if Intent != this.RepairGeneration || Generation != this.Generation || Epoch != State["generation"]
					|| State["attempt"] != 0 || A_IsSuspended || this.Native.Closed || Transition != _LifecycleLatestTransition
				return false
			Record := Map("generation", Generation, "epoch", Epoch, "intent", Intent, "transition", Transition,
				"resume", Deferred ? 0 : this.ResumeIntent, "built", false, "busy", false)
			Record["timer"] := ObjBindMethod(this, "_RepairTick", Record)
			this.Repair := Record
			this.RepairRecords[ObjPtr(Record)] := Record
		} finally Critical(ClaimCritical)
		if Deferred
			this._ArmRepair(Record)
		else
			this._RepairTick(Record)
		return true
	}

	_RepairCurrent(Record) {
		if Record.Get("kind", "") == "discovery"
			return this._DiscoveryCurrent(Record)
		global _LifecycleLatestTransition
		State := _LLM_Menu_ApiPrivateLifecycleState()
		return this.Repair is Map && this.Repair == Record && !A_IsSuspended && !this.Native.Closed
			&& Record["generation"] == this.Generation && Record["epoch"] == State["generation"]
			&& Record["intent"] == this.RepairGeneration && Record["transition"] == _LifecycleLatestTransition
			&& State["attempt"] == 0
	}

	_RepairTick(Record) {
		if Record.Get("kind", "") == "discovery"
			return this._DiscoveryTick(Record)
		PreviousCritical := Critical("Off")
		try {
			ClaimCritical := Critical("On")
			try {
				if Record["busy"] || !this.RepairRecords.Has(ObjPtr(Record))
					return
				Record["busy"] := true
			} finally Critical(ClaimCritical)
			try {
				if !this._RepairCurrent(Record) {
					this._DropRepair(Record)
					return
				}
				if Record["built"] {
					this._DropRepair(Record)
					return
				}
				Settled := this.Native.RetryPending()
				if !this._RepairCurrent(Record)
					return
				if !Settled || !this.Source.Admit() {
					this._ArmRepair(Record)
					return
				}
				if !this._RepairCurrent(Record)
					return
				this._RepairTimer(Record["timer"], 0)
				if !this._RepairCurrent(Record)
					return
				Accepted := this._Build("local_servers_lifecycle_repaired")
				if (Accepted is Integer) && Accepted == 1 {
					Record["built"] := true
					this._DropRepair(Record)
				} else if this._RepairCurrent(Record) {
					this._ArmRepair(Record)
				}
			} finally Record["busy"] := false
		} finally Critical(PreviousCritical)
	}

	_ArmRepair(Record) {
		if !this._RepairCurrent(Record)
			return this._DropRepair(Record)
		this._RepairTimer(Record["timer"], -TimingsGet("llm", "poll_interval_ms"))
		if !this._RepairCurrent(Record) {
			; A yielding timer port may arm after reentrant cancellation. The
			; exact old callback remains cleanup debt, never a successor's timer.
			this.RepairRecords[ObjPtr(Record)] := Record
			return this._DropRepair(Record)
		}
		return true
	}

	_DropRepairs() {
		Snapshot := this.RepairRecords.Clone()
		for _, Record in Snapshot
			if !this._DropRepair(Record)
				return false
		return this.RepairRecords.Count == 0
	}

	_DropRepair(Record) {
		if !this.RepairRecords.Has(ObjPtr(Record))
			return true
		this._RepairTimer(Record["timer"], 0)
		ClaimCritical := Critical("On")
		try {
			if this.RepairRecords.Has(ObjPtr(Record))
				this.RepairRecords.Delete(ObjPtr(Record))
			if this.Repair is Map && this.Repair == Record
				this.Repair := 0
			if this.Discovery is Map && this.Discovery == Record
				this.Discovery := 0
			if Record["built"] && this.ResumeIntent is Map && this.ResumeIntent == Record["resume"]
				this.ResumeIntent := 0
		} finally Critical(ClaimCritical)
		return true
	}

	_RepairTimer(Callback, Period) {
		if !(Period is Integer) || Period > 0
			throw TypeError("Panel repair timers require cancellation or a negative one-shot period.")
		if this.Options.Has("timer") {
			Accepted := this.Options["timer"].Call(Callback, Period)
			if !((Accepted is Integer) && Accepted == 1)
				throw Error("Local server panel repair timer was refused.")
			return true
		}
		if Period == 0
			SetTimer(Callback, 0)
		else
			SetTimer(Callback, -Abs(Period))
		return true
	}

	/** Cleanup acknowledges only this owner; ShellRunner keeps its separate debts. */
	Retire(Shutdown) {
		PreviousCritical := Critical("Off")
		try {
			ClaimCritical := Critical("On")
			try {
				this.Generation += 1
				this.View := 0
				this.ResumeIntent := 0
				this.RepairGeneration += 1
				this.DiscoveryGeneration += 1
			} finally Critical(ClaimCritical)
			try RepairSettled := this._DropRepairs()
			finally {
				Cancelled := this.Native.Cancel(Shutdown)
				Settled := this.Native.RetryPending()
			}
			return RepairSettled && Cancelled && Settled
		} finally Critical(PreviousCritical)
	}
}
