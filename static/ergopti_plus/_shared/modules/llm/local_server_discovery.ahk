; _shared/modules/llm/local_server_discovery.ahk

; ==============================================================================
; MODULE: Local Server Discovery Controller
; DESCRIPTION:
; Ports the shared Lua controller's ordered joint publication, cache age and
; superseding search tickets. Native HTTP, credential, timer and process owners
; remain injected; logical invalidation never acknowledges their retirement.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include local_server_auth.ahk





; ===============================================
; ===============================================
; ======= 1/ Logical Discovery Controller =======
; ===============================================
; ===============================================

/** Owns one logical discovery cache without acquiring native resources. */
class LocalServerDiscoveryController {

	/**
	 * @param {Map} Options Order, clock, max_age and optional observer ports.
	 */
	__New(Options) {
		if !(Options is Map) || !(Options.Get("order", 0) is Array)
				|| !HasMethod(Options.Get("clock", 0), "Call")
				|| !HasMethod(Options.Get("max_age", 0), "Call")
			throw TypeError("Local discovery requires order, clock and cache age ports.")
		this.Options := Options.Clone()
		this.Order := Options["order"].Clone()
		this.Results := Map()
		this.CheckedAt := 0
		this.HasCheckedAt := false
		this.Generation := 0
		this.Active := false
		this.Waiters := []
	}

	/**
	 * @param {Any} Response Actual HTTP adapter receipt.
	 * @returns {Map} Status and ordered model identifiers.
	 */
	static Classify(Response) {
		if !(Response is Map)
			return Map("status", "down", "models", [])
		Status := Response.Get("status", 0)
		if Status == 401 || Status == 403
			return Map("status", "needs_key", "models", [])
		Models := LocalServerAuthModelsReceipt(Response)
		return Map("status", Models is Array ? "up" : "down",
			"models", Models is Array ? Models : [])
	}

	/**
	 * @param {Array} Targets Provider, address and optional native identity snapshots.
	 * @param {Func} Probe Receives captured target, settle callback and logical ticket.
	 * @param {Func|Integer} OnDone Optional observer of the newest publication.
	 * @returns {Boolean} Logical sweep accepted, independent of native retirement.
	 */
	Sweep(Targets, Probe, OnDone := 0) {
		PreviousCritical := Critical("Off")
		try return this._SweepNonCritical(Targets, Probe, OnDone)
		finally Critical(PreviousCritical)
	}

	_SweepNonCritical(Targets, Probe, OnDone) {
		if !(Targets is Array) || !HasMethod(Probe, "Call")
			throw TypeError("Local discovery sweep requires targets and a probe.")
		if OnDone != 0 && !HasMethod(OnDone, "Call")
			throw TypeError("Local discovery observer must be callable.")
		Captured := []
		for Target in Targets {
			if !(Target is Map)
				throw TypeError("Local discovery target must be a map.")
			Captured.Push(Target.Clone())
		}
		Sweep := Map("generation", 0, "fresh", Map(), "pending", Captured.Length)
		HasObserver := HasMethod(OnDone, "Call")
		PreviousCritical := Critical("On")
		try {
			this.Generation += 1
			Sweep["generation"] := this.Generation
			this.Active := true
			if HasObserver
				this.Waiters.Push(OnDone)
		} finally Critical(PreviousCritical)
		if Captured.Length == 0 {
			this._Finish(Sweep)
			return true
		}
		for Target in Captured {
			; A native acquisition may synchronously start a newer sweep. The old
			; loop must not dispatch another request against its successor's owner.
			if Sweep["generation"] != this.Generation
				return true
			Record := Map("id", Target["id"], "base_url", Target["base_url"],
				"settled", false)
			Settle := ObjBindMethod(this, "_Settle", Sweep, Record)
			Ticket := Map("is_current", ObjBindMethod(this, "_TicketCurrent", Sweep, Record))
			try Dispatched := Probe.Call(Target, Settle, Ticket)
			catch as Err {
				this._Report("probe", Err, Record["id"])
				Settle.Call(0)
				continue
			}
			if !((Dispatched is Integer) && Dispatched == true) {
				this._Report("probe", "the probe was refused", Record["id"])
				Settle.Call(0)
			}
		}
		return true
	}

	/** @returns {Map|Integer} Last jointly published verdict for the provider. */
	Result(Id) {
		return this.Results.Get(Id, 0)
	}

	/** @returns {Array} Answering providers in catalogue order. */
	Detected() {
		Ids := []
		Results := this.Results
		for Id in this.Order {
			Verdict := Results.Get(Id, 0)
			if Verdict is Map && !(Verdict["status"] == "down")
				Ids.Push(Id)
		}
		return Ids
	}

	/** @returns {Boolean} Whether a new logical sweep is due. */
	IsStale() {
		PreviousCritical := Critical("Off")
		try return this._IsStaleNonCritical()
		finally Critical(PreviousCritical)
	}

	_IsStaleNonCritical() {
		PreviousCritical := Critical("On")
		try {
			if this.Active
				return false
			if !this.HasCheckedAt
				return true
		} finally Critical(PreviousCritical)
		Clock := this.Options["clock"], MaxAge := this.Options["max_age"]
		Now := Clock.Call(), Age := MaxAge.Call()
		PreviousCritical := Critical("On")
		try {
			if this.Active
				return false
			if !this.HasCheckedAt
				return true
			return Now - this.CheckedAt >= Age
		} finally Critical(PreviousCritical)
	}

	/** Invalidates logical tickets and observers while preserving the last cache. */
	Invalidate() {
		PreviousCritical := Critical("On")
		try {
			this.Generation += 1
			this.Active := false
			this.HasCheckedAt := false
			this.Waiters := []
		} finally Critical(PreviousCritical)
	}

	/** @returns {Boolean} Logical activity, never native retirement. */
	IsSweeping() {
		return this.Active
	}

	_TicketCurrent(Sweep, Record) {
		PreviousCritical := Critical("On")
		try return Sweep["generation"] == this.Generation && !Record["settled"]
		finally Critical(PreviousCritical)
	}

	_Settle(Sweep, Record, Response := 0) {
		PreviousCritical := Critical("Off")
		try return this._SettleNonCritical(Sweep, Record, Response)
		finally Critical(PreviousCritical)
	}

	_SettleNonCritical(Sweep, Record, Response) {
		if !this._TicketCurrent(Sweep, Record)
			return
		; JSON decoding may yield. Claim only after it completes and the exact
		; generation and record still own this pending response.
		Verdict := LocalServerDiscoveryController.Classify(Response)
		Verdict["base_url"] := Record["base_url"]
		PreviousCritical := Critical("On")
		try {
			if Sweep["generation"] != this.Generation || Record["settled"]
				return
			Record["settled"] := true
			Sweep["fresh"][Record["id"]] := Verdict
			Sweep["pending"] -= 1
			Complete := Sweep["pending"] == 0
		} finally Critical(PreviousCritical)
		if Complete
			this._Finish(Sweep)
	}

	_Finish(Sweep) {
		PreviousCritical := Critical("Off")
		try return this._FinishNonCritical(Sweep)
		finally Critical(PreviousCritical)
	}

	_FinishNonCritical(Sweep) {
		PreviousCritical := Critical("On")
		try {
			if Sweep["generation"] != this.Generation
				return
			Before := this.Results
		} finally Critical(PreviousCritical)
		Fresh := Sweep["fresh"]
		Changed := false
		for Id in this.Order
			if this._VerdictChanged(Before.Get(Id, 0), Fresh.Get(Id, 0))
				Changed := true
		Clock := this.Options["clock"]
		CheckedAt := Clock.Call()
		; Model comparison and the injected clock can yield or synchronously start
		; a successor. Recheck before one atomic publication and waiter detachment.
		PreviousCritical := Critical("On")
		try {
			if Sweep["generation"] != this.Generation
				return
			this.Results := Fresh
			this.CheckedAt := CheckedAt
			this.HasCheckedAt := true
			this.Active := false
			Completed := this.Waiters
			this.Waiters := []
		} finally Critical(PreviousCritical)
		Publish := this.Options.Get("on_publish", 0)
		if HasMethod(Publish, "Call") {
			try Publish.Call(Fresh, Changed)
			catch as Err {
				this._Report("publication", Err)
			}
		}
		for Observer in Completed {
			try Observer.Call(Changed)
			catch as Err {
				this._Report("observer", Err)
			}
		}
	}

	_VerdictChanged(Before, After) {
		if !(Before is Map) || !(After is Map)
			return (Before is Map) != (After is Map)
		if !(Before["status"] == After["status"])
				|| !(Before["base_url"] == After["base_url"])
				|| Before["models"].Length != After["models"].Length
			return true
		for Index, Model in Before["models"]
			if !(Model == After["models"][Index])
				return true
		return false
	}

	_Report(Kind, Detail, Id := "") {
		Report := this.Options.Get("on_error", 0)
		if HasMethod(Report, "Call")
			Report.Call(Kind, Detail, Id)
	}
}
