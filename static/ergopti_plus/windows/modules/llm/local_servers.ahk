; modules/llm/local_servers.ahk

; ==============================================================================
; MODULE: Native Local Server Orchestration
; DESCRIPTION:
; Composes shared discovery with exact curl ownership and the existing private
; API source/transaction ports. Newest queued logical jobs wait behind native
; debt; view receipts fence native dialogs and acknowledged menu selections.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Native Orchestration Owner =======
; =============================================
; =============================================

/** Native ownership proposal; private publication remains an injected existing owner. */
class LocalServersOwner extends _LocalServersTimerNativeAdapter {

	/**
	 * @param {Map} Options Catalogue, transport, timings and native private-owner ports.
	 * Required native ports: entry(id), capture_source(), source_current(receipt),
	 * admit(), apply(id, fields, source, admission, select_model).
	 */
	__New(Options) {
		if !(Options is Map) || !(Options.Get("order", 0) is Array)
				|| Options["order"].Length == 0 || !(Options.Get("servers", 0) is Map)
				|| !(Options.Get("models_owner", 0) is LocalServerModelsOwner)
				|| !(Options.Get("poll_ms", 0) is Integer) || Options["poll_ms"] <= 0 || Options["poll_ms"] > 0x7FFFFFFF
			throw TypeError("Local servers require catalogue, curl owner and positive polling cadence.")
		for Name in ["entry", "capture_source", "source_current", "admit", "apply", "clock", "max_age"]
			if !HasMethod(Options.Get(Name, 0), "Call")
				throw TypeError("Local server native port is unavailable.", -1, Name)
		for Name in ["timer", "on_publish", "on_error"]
			if Options.Has(Name) && !HasMethod(Options[Name], "Call")
				throw TypeError("Local server optional port must be callable.", -1, Name)
		this.Options := Options.Clone()
		this.Models := Options["models_owner"]
		this.Order := Options["order"].Clone()
		this.Servers := Options["servers"]
		this.Pending := Map()
		this.Jobs := Map()
		this.Views := Map()
		this.ConfigurationGeneration := 0
		this.ModelGeneration := 0
		this.ViewGeneration := 0
		this.RescanGeneration := 0
		this.Closed := false
		this.Writing := false
		this.WriteGeneration := 0
		this.WriteClaim := 0
		this.Cache := 0
		this.Sweeps := Map()
		this.RescanBusy := false
		this.QueuedRescan := 0
		this.Controller := LocalServerDiscoveryController(Map("order", this.Order,
			"clock", Options["clock"], "max_age", Options["max_age"],
			"on_publish", ObjBindMethod(this, "_Published"),
			"on_error", ObjBindMethod(this, "_DiscoveryError")))
	}

	/** @returns {Map|Integer} Captured configured target; no secret enters shared state. */
	Target(Id) {
		PreviousCritical := Critical("Off")
		try return this._Target(Id)
		finally Critical(PreviousCritical)
	}

	_Target(Id) {
		Server := this.Servers.Get(Id, 0)
		if !(Server is Map)
			return false
		Entry := this._Call("entry", Id)
		if Entry is Map {
			if !(Entry.Get("Id", 0) is String) || !(Entry.Get("Provider", "") == Id)
					|| !(Entry.Get("BaseUrl", 0) is String) || !(Entry.Get("Token", 0) is String)
					|| !(Entry.Get("Model", 0) is String)
				throw TypeError("Local server entry must come from the validated native API owner.")
			return Map("id", Id, "entry_id", Entry["Id"],
				"base_url", Entry["BaseUrl"] == "" ? Server["base_url"] : Entry["BaseUrl"],
				"token", Entry["Token"])
		}
		Fields := this.Pending.Get(Id, Map())
		return Map("id", Id, "entry_id", "", "base_url", Fields.Get("base_url", Server["base_url"]),
			"token", Fields.Get("token", ""))
	}

	/** Starts one shared logical sweep; exact same-provider native debt stays owned. */
	Rescan(OnDone := 0) {
		PreviousCritical := Critical("Off")
		try return this._Rescan(OnDone)
		finally Critical(PreviousCritical)
	}

	_Rescan(OnDone) {
		if OnDone != 0 && !HasMethod(OnDone, "Call")
			throw TypeError("Local server completion observer must be callable.")
		if !this._Admitted()
			return false
		PreviousCritical := Critical("On")
		try {
			if this.Closed || A_IsSuspended
				return false
			Request := Map("intent", ++this.RescanGeneration, "observer", OnDone)
			if this.RescanBusy {
				this.QueuedRescan := Request
				return true
			}
			this.RescanBusy := true
		} finally Critical(PreviousCritical)
		Accepted := false, ReportFailure := 0
		loop {
			try {
				if this._SetupRescan(Request)
					Accepted := true
			} catch as Err {
				try this._Report("rescan", Err)
				catch as ReportErr {
					; Surface reporter failure after the latest creator unwinds;
					; preserving the queue here is not silent suppression.
					ReportFailure := Map("error", ReportErr)
				}
			} finally {
				PreviousCritical := Critical("On")
				try {
					Request := this.QueuedRescan
					this.QueuedRescan := 0
					if !(Request is Map) || this.Closed || A_IsSuspended {
						Request := 0
						this.RescanBusy := false
					}
				} finally Critical(PreviousCritical)
			}
			if !(Request is Map) {
				if ReportFailure is Map
					throw ReportFailure["error"]
				return Accepted
			}
		}
	}

	_SetupRescan(Request) {
		Intent := Request["intent"]
		if !this._Admitted()
			return false
		PreviousCritical := Critical("On")
		try {
			if Intent != this.RescanGeneration
				return false
			Configuration := this.ConfigurationGeneration
		} finally Critical(PreviousCritical)
		Source := this._Call("capture_source")
		if !IsObject(Source)
			return false
		PrivateTargets := Map(), Targets := []
		for Id in this.Order {
			Target := this._Target(Id)
			if !(Target is Map)
				throw Error("Local discovery catalogue target is unavailable.")
			PrivateTargets[Id] := Target
			Targets.Push(Map("id", Id, "base_url", Target["base_url"]))
		}
		if !this._Admitted() || !this._True("source_current", Source)
			return false
		if Intent != this.RescanGeneration || Configuration != this.ConfigurationGeneration || this.Closed || A_IsSuspended
			return false
		Sweep := Map("source", Source, "targets", PrivateTargets,
			"configuration", Configuration, "intent", Intent, "generation", 0, "accepted", false)
		OnDone := Request["observer"]
		Done := HasMethod(OnDone, "Call") ? ObjBindMethod(this, "_Done", Sweep, OnDone) : 0
		; RescanBusy remains held through the shared creator and all synchronous
		; native factories. A newer intent is replayed after this call unwinds.
		return this.Controller.Sweep(Targets, ObjBindMethod(this, "_Probe", Sweep), Done)
	}

	_Probe(Sweep, PublicTarget, Settle, Ticket) {
		Id := PublicTarget["id"]
		Generation := this.Controller.Generation
		Valid := Ticket["is_current"].Call()
		if !((Valid is Integer) && Valid == true)
			return true
		Job := Map("id", Id, "sweep", Sweep, "target", Sweep["targets"][Id], "source", Sweep["source"],
			"configuration", Sweep["configuration"], "ticket", Ticket["is_current"],
			"settle", Settle, "phase", "waiting", "busy", false, "successor", 0)
		Job["timer"] := ObjBindMethod(this, "_Tick", Job)
		PreviousCritical := Critical("On")
		try {
			if Generation != this.Controller.Generation || Sweep["intent"] != this.RescanGeneration
					|| Sweep["configuration"] != this.ConfigurationGeneration || this.Closed || A_IsSuspended
					|| (Sweep["generation"] != 0 && Sweep["generation"] != Generation)
				; The live shared record must finish even if cancellation leaves
				; no queued successor; its automatic refusal receipt remains
				; fenced by exact-generation publication rejection.
				return false
			Sweep["generation"] := Generation
			this.Sweeps := Map(Generation, Sweep)
			Old := this.Jobs.Get(Id, 0)
			NativeRecord := this.Models.Records.Get(Id, 0)
			if Old is Map {
				Old["phase"] := "cancelled"
				Old["settle"] := 0
				Old["successor"] := Job
			} else this.Jobs[Id] := Job
		} finally Critical(PreviousCritical)
		if Old is Map {
			; Only the captured exact transport capability may be cancelled.
			; A timer promoting a newer child cannot lend its provider slot.
			this._CancelExact(NativeRecord)
			this._DropJob(Old)
			return true
		}
		this._Tick(Job)
		return true
	}

	_CancelExact(Record) {
		return !(Record is Map) || this.Models._CancelRecord(Record)
	}

	_OwnsJob(Job) {
		Held := this.Jobs.Get(Job["id"], 0)
		return Held is Map && ObjPtr(Held) == ObjPtr(Job)
	}

	_CurrentJob(Job) {
		if !this._OwnsJob(Job) || Job["phase"] == "cancelled" || this.Closed
			return false
		Ticket := Job["ticket"]
		Valid := Ticket.Call()
		if !((Valid is Integer) && Valid == true) || !this._Admitted()
				|| !this._True("source_current", Job["source"])
			return false
		Target := this._Target(Job["id"])
		if !this._SameTarget(Job["target"], Target)
			return false
		if !this._Admitted() || !this._True("source_current", Job["source"])
			return false
		Valid := Ticket.Call()
		if !((Valid is Integer) && Valid == true)
			return false
		; Logical/source admission is current-at-check. The shared Settle
		; remains the final logical publication claim; only native slot state
		; is claimed atomically here, with no foreign port inside Critical.
		PreviousCritical := Critical("On")
		try return this._OwnsJob(Job) && Job["phase"] != "cancelled" && !this.Closed && !A_IsSuspended
			&& Job["configuration"] == this.ConfigurationGeneration
			&& Job["sweep"]["intent"] == this.RescanGeneration
		finally Critical(PreviousCritical)
	}

	_Tick(Job) {
		PreviousCritical := Critical("Off")
		try return this._TickNonCritical(Job)
		finally Critical(PreviousCritical)
	}

	_TickNonCritical(Job) {
		PreviousCritical := Critical("On")
		try {
			if !this._OwnsJob(Job) || Job["busy"]
				return
			Job["busy"] := true
		} finally Critical(PreviousCritical)
		try {
			; The native pause owner invalidates/cancels explicitly. A waiting
			; queue timer which reaches suspension first preserves the cache.
			if A_IsSuspended && Job["phase"] != "cancelled"
				return
			if Job["phase"] == "cancelled" {
				this._DropJob(Job)
				return
			}
			if !this._CurrentJob(Job) {
				this._InvalidateSweep(Job["sweep"])
				return
			}
			if Job["phase"] == "active" {
				; The curl owner can retire a stale delivery without calling its
				; detached observer. This timer observes that exact lifecycle.
				if !this.Models.HasPending(Job["id"]) && this._CurrentJob(Job)
					this._SettleJob(Job, 0)
				return
			}
			if Job["phase"] != "waiting"
				return
			PreviousCritical := Critical("On")
			try NativeRecord := this._OwnsJob(Job) ? this.Models.Records.Get(Job["id"], 0) : 0
			finally Critical(PreviousCritical)
			this._CancelExact(NativeRecord)
			if !this._CurrentJob(Job)
				return
			if this.Models.HasPending(Job["id"])
				return
			PreviousCritical := Critical("On")
			try {
				if !this._OwnsJob(Job) || Job["phase"] != "waiting" || this.Closed || A_IsSuspended
					return
				Job["phase"] := "dispatching"
			} finally Critical(PreviousCritical)
			Accepted := this.Models.Probe(Job["target"], ObjBindMethod(this, "_SettleJob", Job),
				Map("is_current", ObjBindMethod(this, "_CurrentJob", Job)))
			if !this._OwnsJob(Job)
				return
			if !((Accepted is Integer) && Accepted == true)
				this._SettleJob(Job, 0)
			else {
				PreviousCritical := Critical("On")
				try {
					if this._OwnsJob(Job) && Job["phase"] == "dispatching"
						Job["phase"] := "active"
				} finally Critical(PreviousCritical)
			}
		} catch as Err {
			this._Report("probe", Err, Job["id"])
			this._SettleJob(Job, 0)
		} finally {
			PreviousCritical := Critical("On")
			try Job["busy"] := false
			finally Critical(PreviousCritical)
			if this._OwnsJob(Job) {
				if Job["phase"] == "cancelled"
					this._DropJob(Job)
				if this._OwnsJob(Job) && (Job["phase"] == "waiting" || Job["phase"] == "active" || Job["phase"] == "cancelled")
					this._Timer(Job["timer"], -this.Options["poll_ms"])
			}
		}
	}

	_SettleJob(Job, Response := 0) {
		if !this._OwnsJob(Job) || Job["phase"] == "cancelled"
			return
		Current := this._CurrentJob(Job)
		if !Current {
			this._InvalidateSweep(Job["sweep"])
			return
		}
		if !this._OwnsJob(Job) || Job["phase"] == "cancelled"
			return
		PreviousCritical := Critical("On")
		try {
			if !this._OwnsJob(Job) || Job["phase"] == "cancelled"
				return
			Settle := Job["settle"]
			Job["phase"] := "cancelled"
			Job["settle"] := 0
		} finally Critical(PreviousCritical)
		try {
			if HasMethod(Settle, "Call")
				Settle.Call(Response)
		} finally this._DropJob(Job)
	}

	/** Discards a source-stale search without publishing false server failures. */
	_InvalidateSweep(Sweep) {
		PreviousCritical := Critical("On")
		try {
			Current := Sweep["generation"] == this.Controller.Generation
			Snapshot := []
			for _, Job in this.Jobs {
				if ObjPtr(Job["sweep"]) == ObjPtr(Sweep) {
					Job["phase"] := "cancelled"
					Job["settle"] := 0
					Snapshot.Push(Map("job", Job, "native", this.Models.Records.Get(Job["id"], 0)))
				}
			}
			; This shared method owns no foreign ports. Its own brief nested
			; claim restores our prior Critical value exactly.
			if Current && !Sweep["accepted"]
				this.Controller.Invalidate()
		} finally Critical(PreviousCritical)
		for Captured in Snapshot {
			this._CancelExact(Captured["native"])
			this._DropJob(Captured["job"])
		}
	}

	_DropJob(Job) {
		if !this._OwnsJob(Job) || Job["busy"]
			return false
		if !this._Timer(Job["timer"], 0)
			return false
		Successor := 0
		PreviousCritical := Critical("On")
		try {
			if !this._OwnsJob(Job) || Job["busy"]
				return false
			this.Jobs.Delete(Job["id"])
			Successor := Job["successor"]
			Job["successor"] := 0
			if Successor is Map && !this.Closed && !Successor["sweep"]["accepted"]
				this.Jobs[Job["id"]] := Successor
			else Successor := 0
		} finally Critical(PreviousCritical)
		if Successor is Map && !this.Closed
			this._Tick(Successor)
		return true
	}

	/** Retires old menu handles' opaque receipts before a new row tree is captured. */
	BeginView() {
		PreviousCritical := Critical("On")
		try {
			this.ViewGeneration += 1
			this.Views := Map()
		} finally Critical(PreviousCritical)
	}

	/** @returns {Object|Integer} Opaque receipt; native source/credentials stay private. */
	Capture(Id) {
		PreviousCritical := Critical("Off")
		try {
			if !this._Admitted()
				return false
			ClaimCritical := Critical("On")
			try {
				View := this.ViewGeneration
				Configuration := this.ConfigurationGeneration
				Models := this.ModelGeneration
			} finally Critical(ClaimCritical)
			Source := this._Call("capture_source"), Target := this._Target(Id)
			if !IsObject(Source) || !(Target is Map)
				return false
			Cache := this.Cache
			CacheCurrent := this._CacheCurrent(Cache)
			Verdict := CacheCurrent ? Cache["results"].Get(Id, 0) : 0
			if !this._Admitted() || !this._True("source_current", Source)
					|| (CacheCurrent && (!this._CacheCurrent(Cache) || !this._SameTarget(Cache["targets"][Id], Target)))
				return false
			CapturedModels := Verdict is Map ? Verdict["models"].Clone() : []
			ClaimCritical := Critical("On")
			try {
				if this.Closed || A_IsSuspended || View != this.ViewGeneration
						|| Configuration != this.ConfigurationGeneration || Models != this.ModelGeneration
					return false
				Receipt := {}
				this.Views[ObjPtr(Receipt)] := Map("receipt", Receipt, "source", Source, "target", Target,
					"view", View, "configuration", Configuration,
					"models_generation", Models, "models", CapturedModels, "cache", CacheCurrent ? Cache : 0)
				return Receipt
			} finally Critical(ClaimCritical)
		} finally Critical(PreviousCritical)
	}

	/** Rechecks the exact private source, native target and ordered model view. */
	IsCurrent(Receipt, Model := "") {
		PreviousCritical := Critical("Off")
		try return this._ViewCurrent(Receipt, Model)
		finally Critical(PreviousCritical)
	}

	_ViewCurrent(Receipt, Model) {
		if !IsObject(Receipt) || !this._Admitted()
			return false
		Held := this.Views.Get(ObjPtr(Receipt), 0)
		if !(Held is Map) || ObjPtr(Held["receipt"]) != ObjPtr(Receipt)
				|| !this._True("source_current", Held["source"])
				|| !this._SameTarget(Held["target"], this._Target(Held["target"]["id"]))
			return false
		if Held["view"] != this.ViewGeneration || Held["configuration"] != this.ConfigurationGeneration
				|| Held["models_generation"] != this.ModelGeneration
				|| !this.Views.Has(ObjPtr(Receipt)) || this.Closed
			return false
		if Model != "" {
			Cache := Held["cache"]
			if !this._CacheCurrent(Cache)
				return false
			Verdict := Cache["results"].Get(Held["target"]["id"], 0)
			if !(Verdict is Map) || !(Verdict["status"] == "up")
					|| !(Verdict["base_url"] == Held["target"]["base_url"])
					|| Verdict["models"].Length != Held["models"].Length
				return false
			Found := false
			for Index, Id in Verdict["models"] {
				if !(Id == Held["models"][Index])
					return false
				if Id == Model
					Found := true
			}
			if !Found
				return false
		}
		if !this._Admitted() || !this._True("source_current", Held["source"])
				|| (Model != "" && !this._CacheCurrent(Held["cache"]))
			return false
		PreviousCritical := Critical("On")
		try return this._HeldViewCurrent(Held, Receipt)
		finally Critical(PreviousCritical)
	}

	/** Uses the existing private publisher; unsaved address/key fields stay ephemeral. */
	Apply(Receipt, Fields) {
		PreviousCritical := Critical("Off")
		try return this._Apply(Receipt, Fields)
		finally Critical(PreviousCritical)
	}

	_HeldViewCurrent(Held, Receipt) {
		Current := this.Views.Get(ObjPtr(Receipt), 0)
		return Current is Map && ObjPtr(Current) == ObjPtr(Held) && !this.Closed && !A_IsSuspended
			&& Held["view"] == this.ViewGeneration
			&& Held["configuration"] == this.ConfigurationGeneration
			&& Held["models_generation"] == this.ModelGeneration
	}

	/**
	 * Before durability, retain ordinary exact-source admission. After durability,
	 * this boolean checks only the originating native view; the private writer
	 * separately brackets it with exact candidate image/bundle/source validation.
	 */
	_WriteAdmission(Claim, Phase := "", Capability := 0) {
		if (Phase is String) && Phase == "claim" {
			Proof := Claim.Get("candidate", 0)
			; The private publisher owns this final Critical region. No logical
			; port, scan or Critical restoration may open a publication gap.
			return A_IsCritical && (Type(Capability) == "LLM_Menu_ApiPrivateCandidateReceipt")
				&& IsObject(Proof) && ObjPtr(Proof) == ObjPtr(Capability) && this._HeldWriteCurrent(Claim)
		}
		PreviousCritical := Critical("Off")
		try {
			if Phase == "" {
				if Capability != 0 || !this._ViewCurrent(Claim["receipt"], Claim["model"])
					return false
			} else if !(Phase is String) || !(Phase == "committed")
					|| !(Type(Capability) == "LLM_Menu_ApiPrivateCandidateReceipt") {
				return false
			}
			if Phase == "committed" {
				ClaimCritical := Critical("On")
				try Claim["candidate"] := 0
				finally Critical(ClaimCritical)
			}
			; No source_current, entry or native admit port belongs in the
			; committed branch: ordinary old source authority remains revoked.
			if !this._WriteModelsMatch(Claim) || !this._WritePendingMatch(Claim)
				return false
			ClaimCritical := Critical("On")
			try {
				Current := this._HeldWriteCurrent(Claim)
				if Current && Phase == "committed"
					Claim["candidate"] := Capability
				return Current
			} finally Critical(ClaimCritical)
		} finally Critical(PreviousCritical)
	}

	_HeldWriteCurrent(Claim) {
		if !(this.WriteClaim is Map) || ObjPtr(this.WriteClaim) != ObjPtr(Claim) || !this.Writing
				|| Claim["generation"] != this.WriteGeneration
				|| !this._HeldViewCurrent(Claim["held"], Claim["receipt"])
				|| Claim["rescan"] != this.RescanGeneration || Claim["controller"] != this.Controller.Generation
				|| ObjPtr(Claim["source"]) != ObjPtr(Claim["held"]["source"])
				|| !this._SameTarget(Claim["target"], Claim["held"]["target"])
			return false
		Pending := this.Pending.Get(Claim["target"]["id"], 0), Original := Claim["pending"]
		if (Pending is Map) != (Original is Map)
			return false
		if Pending is Map && ObjPtr(Pending) != ObjPtr(Original)
			return false
		return Claim["model"] == "" || (this.Cache is Map && Claim["cache"] is Map
			&& ObjPtr(this.Cache) == ObjPtr(Claim["cache"])
			&& ObjPtr(Claim["held"]["cache"]) == ObjPtr(Claim["cache"]))
	}

	_WritePendingMatch(Claim) {
		Original := Claim["pending_values"], Current := this.Pending.Get(Claim["target"]["id"], 0)
		if !(Original is Map)
			return !(Current is Map)
		if !(Current is Map) || Current.Count != Original.Count
			return false
		for Key, Value in Original
			if !Current.Has(Key) || !(Current[Key] == Value)
				return false
		return true
	}

	/** Ordered model comparison may yield; the final held claim rechecks identity. */
	_WriteModelsMatch(Claim) {
		if Claim["model"] == ""
			return true
		Cache := Claim["cache"], Target := Claim["target"]
		if !(Cache is Map) || !(this.Cache is Map) || ObjPtr(Cache) != ObjPtr(this.Cache)
				|| !this._SameTarget(Cache["targets"][Target["id"]], Target)
			return false
		Verdict := Cache["results"].Get(Target["id"], 0)
		if !(Verdict is Map) || !(Verdict["status"] == "up") || !(Verdict["base_url"] == Target["base_url"])
				|| Verdict["models"].Length != Claim["models"].Length
			return false
		Found := false
		for Index, Id in Verdict["models"] {
			if !(Id == Claim["models"][Index])
				return false
			if Id == Claim["model"]
				Found := true
		}
		return Found
	}

	_Apply(Receipt, Fields) {
		if !(Fields is Map) || Fields.Count == 0 || this.Writing
			return false
		for Key, Value in Fields
			if !(Key is String) || !RegExMatch(Key, "^(base_url|token|model)$")
					|| !(Value is String) || !_HTTP_CurlScalarIsSafe(Value)
				return false
		Model := Fields.Get("model", "")
		if Fields.Has("model") && Model == ""
			return false
		if !this._ViewCurrent(Receipt, Model)
			return false
		Held := this.Views[ObjPtr(Receipt)], Target := Held["target"], Id := Target["id"]
		if Fields.Has("base_url") && !RegExMatch(Fields["base_url"], "i)^https?://[^[:space:]]+$")
			return false
		if Fields.Has("token") && !LocalServerAuthTokenAllowed(Id, Fields["token"], this.Servers)
			return false
		CapturedTarget := Target.Clone(), CapturedModels := Held["models"].Clone()
		PendingOwner := this.Pending.Get(Id, 0)
		PendingValues := PendingOwner is Map ? PendingOwner.Clone() : 0
		PreviousCritical := Critical("On")
		try {
			if this.Writing || !this._HeldViewCurrent(Held, Receipt)
				return false
			this.Writing := true
			Claim := Map("generation", ++this.WriteGeneration, "held", Held, "receipt", Receipt,
				"source", Held["source"], "target", CapturedTarget, "model", Model,
				"models", CapturedModels, "cache", Held["cache"],
				"pending", PendingOwner, "pending_values", PendingValues, "rescan", this.RescanGeneration,
				"controller", this.Controller.Generation)
			this.WriteClaim := Claim
		} finally Critical(PreviousCritical)
		try {
			if Target["entry_id"] == "" && !Fields.Has("model") {
				Pending := this.Pending.Get(Id, Map()).Clone()
				for Key, Value in Fields
					Pending[Key] := Value
				PreviousCritical := Critical("On")
				try {
					if !this._HeldViewCurrent(Held, Receipt)
						return false
					this.Pending[Id] := Pending
					this.ConfigurationGeneration += 1
				} finally Critical(PreviousCritical)
				this.Controller.Invalidate()
				return Map("saved", false, "pending", true)
			}
			Entry := this._Call("entry", Id)
			Changes := Map("base_url", Fields.Get("base_url", Target["base_url"]),
				"token", Fields.Get("token", Target["token"]),
				"model", Model != "" ? Model : Entry["Model"])
			Result := this._Call("apply", Id, Changes, Held["source"],
				ObjBindMethod(this, "_WriteAdmission", Claim), Fields.Has("model"))
			if !(Result is Map) || !((Result.Get("saved", 0) is Integer) && Result["saved"] == true)
				return false
			PreviousCritical := Critical("On")
			try {
				if this.Pending.Has(Id)
					this.Pending.Delete(Id)
				this.ConfigurationGeneration += 1
			} finally Critical(PreviousCritical)
			this.Controller.Invalidate()
			return Result
		} finally {
			PreviousCritical := Critical("On")
			try {
				this.Writing := false
				this.WriteClaim := 0
			} finally Critical(PreviousCritical)
		}
	}

	/** Logical invalidation precedes cancellation; unresolved exact owners stay retained. */
	Cancel(Shutdown := false) {
		PreviousCritical := Critical("Off")
		try {
			ClaimCritical := Critical("On")
			try {
				if Shutdown
					this.Closed := true
				this.RescanGeneration += 1
				this.QueuedRescan := 0
				this.Controller.Invalidate()
				NativeRecords := this.Models.Records.Clone()
				this.ViewGeneration += 1
				this.Views := Map()
				Snapshot := this.Jobs.Clone()
				for _, Job in Snapshot {
					Job["phase"] := "cancelled"
					Job["settle"] := 0
					Job["successor"] := 0
				}
			} finally Critical(ClaimCritical)
			Settled := true
			for _, Job in Snapshot {
				if !this._DropJob(Job)
					Settled := false
			}
			for _, NativeRecord in NativeRecords
				if !this._CancelExact(NativeRecord)
					Settled := false
			return Settled
		} finally Critical(PreviousCritical)
	}

	/** Explicit retry boundary for refused native queue timers and curl debt. */
	RetryPending() {
		PreviousCritical := Critical("Off")
		try {
			ModelsSettled := this.Models.RetryPending()
			Snapshot := this.Jobs.Clone()
			for _, Job in Snapshot
				this._Tick(Job)
			return ModelsSettled && this.Jobs.Count == 0
		} finally Critical(PreviousCritical)
	}

	_Admitted() {
		return !this.Closed && !A_IsSuspended && this._True("admit") && !this.Closed && !A_IsSuspended
	}

	_SameTarget(Before, After) {
		if !(Before is Map) || !(After is Map)
			return false
		for Key in ["id", "entry_id", "base_url", "token"]
			if !(Before[Key] == After[Key])
				return false
		return true
	}

	/** Private accepted provenance is required before any cached model action. */
	_CacheCurrent(Cache) {
		if !(Cache is Map) || !this._Admitted() || !this._True("source_current", Cache["source"])
			return false
		for Id, Target in Cache["targets"]
			if !this._SameTarget(Target, this._Target(Id))
				return false
		if !this._Admitted() || !this._True("source_current", Cache["source"])
			return false
		PreviousCritical := Critical("On")
		try return this.Cache is Map && ObjPtr(this.Cache) == ObjPtr(Cache)
			&& Cache["configuration"] == this.ConfigurationGeneration && !this.Closed && !A_IsSuspended
		finally Critical(PreviousCritical)
	}

	/** All outward verdicts detach ordered models from private accepted cache data. */
	_CopyVerdict(Verdict) {
		if !(Verdict is Map)
			return 0
		Copy := Verdict.Clone()
		if Copy.Has("models") && Copy["models"] is Array
			Copy["models"] := Copy["models"].Clone()
		return Copy
	}

	_CopyResults(Results) {
		Copy := Map()
		for Id, Verdict in Results
			Copy[Id] := this._CopyVerdict(Verdict)
		return Copy
	}

	/** Menu callers consume detached data whose original private authority survives. */
	Result(Id) {
		PreviousCritical := Critical("Off")
		try {
			Cache := this.Cache
			if !this._CacheCurrent(Cache)
				return 0
			Copy := this._CopyVerdict(Cache["results"].Get(Id, 0))
			return this._CacheCurrent(Cache) ? Copy : 0
		} finally Critical(PreviousCritical)
	}

	Detected() {
		PreviousCritical := Critical("Off")
		try {
			Cache := this.Cache, Ids := []
			if !this._CacheCurrent(Cache)
				return Ids
			for Id in this.Order {
				Verdict := Cache["results"].Get(Id, 0)
				if Verdict is Map && !(Verdict["status"] == "down")
					Ids.Push(Id)
			}
			return Ids
		} finally Critical(PreviousCritical)
	}

	/** Native retirement can silently detach an observer; cache age alone is insufficient. */
	IsStale() {
		PreviousCritical := Critical("Off")
		try {
			if this.Controller.IsSweeping()
				return false
			return !this._CacheCurrent(this.Cache) || this.Cache["generation"] != this.Controller.Generation
				|| this.Controller.IsStale()
		} finally Critical(PreviousCritical)
	}

	_Done(Sweep, Observer, Changed) {
		if !Sweep["accepted"] || !this._CacheCurrent(this.Cache)
				|| !this._True("source_current", Sweep["source"])
			return
		PreviousCritical := Critical("On")
		try Current := Sweep["generation"] == this.Controller.Generation
			&& Sweep["intent"] == this.RescanGeneration && !this.Closed && !A_IsSuspended
		finally Critical(PreviousCritical)
		if Current
			Observer.Call(Changed)
	}

	/** Reject only this exact completed result; an active/newer sweep survives. */
	_RejectPublication(Generation, Fresh) {
		PreviousCritical := Critical("On")
		try {
			if Generation == this.Controller.Generation && !this.Controller.IsSweeping()
					&& ObjPtr(Fresh) == ObjPtr(this.Controller.Results)
				this.Controller.Invalidate()
		} finally Critical(PreviousCritical)
	}

	_Published(Fresh, Changed) {
		PreviousCritical := Critical("On")
		try {
			Generation := this.Controller.Generation
			Sweep := this.Sweeps.Get(Generation, 0)
			Ready := Sweep is Map && !this.Controller.IsSweeping() && ObjPtr(Fresh) == ObjPtr(this.Controller.Results)
		} finally Critical(PreviousCritical)
		if !Ready {
			this._RejectPublication(Generation, Fresh)
			return
		}
		; Shared results and observer snapshots cannot mutate this native cache.
		PrivateResults := this._CopyResults(Fresh)
		Accepted := false
		try {
			if !this._Admitted() || !this._True("source_current", Sweep["source"])
				return
			for Id, Target in Sweep["targets"]
				if !this._SameTarget(Target, this._Target(Id))
					return
			if !this._Admitted() || !this._True("source_current", Sweep["source"])
				return
			PreviousCritical := Critical("On")
			try {
				if this.Closed || A_IsSuspended || Sweep["configuration"] != this.ConfigurationGeneration
						|| Sweep["intent"] != this.RescanGeneration
						|| Sweep["generation"] != this.Controller.Generation
						|| ObjPtr(Fresh) != ObjPtr(this.Controller.Results)
					return
				this.Cache := Map("results", PrivateResults, "source", Sweep["source"], "targets", Sweep["targets"],
					"configuration", Sweep["configuration"], "generation", Generation)
				Sweep["accepted"] := true
				Accepted := true
				if Changed
					this.ModelGeneration += 1
			} finally Critical(PreviousCritical)
		} finally {
			if !Accepted
				this._InvalidateSweep(Sweep)
		}
		Notify := this.Options.Get("on_publish", 0)
		if HasMethod(Notify, "Call")
			Notify.Call(this._CopyResults(PrivateResults), Changed)
	}

	_DiscoveryError(Kind, Detail, Id) {
		this._Report(Kind, Detail, Id)
	}

	_Call(Name, Args*) {
		Fn := this.Options[Name]
		return Fn.Call(Args*)
	}

	_True(Name, Args*) {
		Value := this._Call(Name, Args*)
		return (Value is Integer) && Value == true
	}

	_Timer(Callback, Period) {
		Timer := this.Options.Get("timer", ObjBindMethod(this, "_NativeTimer"))
		try {
			Value := Timer.Call(Callback, Period)
			if (Value is Integer) && Value == true
				return true
			throw Error("Local server queue timer was refused.")
		} catch as Err {
			this._Report("timer", Err)
			return false
		}
	}



	_Report(Kind, Detail, Id := "") {
		Report := this.Options.Get("on_error", 0)
		if HasMethod(Report, "Call")
			Report.Call(Kind, Detail, Id)
		else
			LoggerWarn("LLM.local_servers", "Local server {1} was refused for provider {2}.", Kind, Id)
	}
}
