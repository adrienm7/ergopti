; modules/llm/local_server_models.ahk

; ==============================================================================
; MODULE: Owned Local Server Models Requests
; DESCRIPTION:
; Acquires the existing tree-owned curl transport for discovery probes. Logical
; tickets, request creation, response delivery and native cancellation have
; separate owners. ShellRunner retains its own capture-release debts.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Models Request Ownership =======
; ===========================================
; ===========================================

/** Owns provider-scoped models GET requests without replacing the HTTP adapter. */
class LocalServerModelsOwner {

	/**
	 * @param {Map} Options Catalogue servers, timeout_ms and poll_ms are required.
	 * Optional request, timer and clock ports exercise the same production owner.
	 */
	__New(Options) {
		if !(Options is Map) || !(Options.Get("servers", 0) is Map)
				|| !(Options.Get("timeout_ms", 0) is Integer) || Options["timeout_ms"] <= 0
				|| Options["timeout_ms"] > 0x7FFFFFFF
				|| !(Options.Get("poll_ms", 0) is Integer) || Options["poll_ms"] <= 0
			throw TypeError("Models ownership requires catalogue and positive timing limits.")
		this.Options := Options.Clone()
		this.Records := Map()
		this.Generation := 0
		for Name in ["request", "timer", "clock", "on_error"]
			if Options.Has(Name) && !HasMethod(Options[Name], "Call")
				throw TypeError("Models ownership port must be callable.", -1, Name)
	}

	/**
	 * @param {Map} Target Captured provider id, configured base_url and token.
	 * @param {Func} Settle Receives one typed HTTP/models receipt while current.
	 * @param {Map} Ticket Logical discovery ticket exposing is_current.
	 * @returns {Boolean} Dispatch accepted, independent of resource settlement.
	 */
	Probe(Target, Settle, Ticket) {
		PreviousCritical := Critical("Off")
		try return this._ProbeNonCritical(Target, Settle, Ticket)
		finally Critical(PreviousCritical)
	}

	_ProbeNonCritical(Target, Settle, Ticket) {
		if !(Target is Map) || !HasMethod(Settle, "Call") || !(Ticket is Map)
				|| !HasMethod(Ticket.Get("is_current", 0), "Call")
			throw TypeError("Models probe requires a captured target, observer and ticket.")
		Id := Target.Get("id", ""), Url := Target.Get("base_url", ""), Token := Target.Get("token", "")
		if A_IsSuspended || !LocalServerAuthTokenAllowed(Id, Token, this.Options["servers"])
				|| !this.Options["servers"].Has(Id) || !_HTTP_CurlScalarIsSafe(Token)
				|| !_HTTP_CurlScalarIsSafe(Url) || !RegExMatch(Url, "i)^https?://[^[:space:]]+$")
			return false
		Current := Ticket["is_current"]
		Valid := Current.Call()
		if !((Valid is Integer) && Valid == true)
			return false
		; A superseding logical sweep cannot borrow an old cancellation request
		; as physical settlement. It is refused while the exact old request owes work.
		if this.Records.Has(Id) && !this.Cancel(Id)
			return false
		StartedAt := this._Clock()
		PreviousCritical := Critical("On")
		try {
			if this.Records.Has(Id) || A_IsSuspended
				return false
			Record := Map("id", Id, "generation", ++this.Generation,
				"ticket", Current, "settle", Settle, "request", 0,
				"building", true, "cancelled", false, "delivered", false,
				"busy", false, "started_at", StartedAt)
			Record["timer"] := ObjBindMethod(this, "_Poll", Record)
			this.Records[Id] := Record
		} finally Critical(PreviousCritical)
		Accepted := false
		try {
			if !this._IsCurrent(Record) || A_IsSuspended
				return false
			Factory := this.Options.Get("request", ObjBindMethod(this, "_NativeRequest"))
			Http := Factory.Call()
			if !(Http is CurlAsyncRequest)
				throw TypeError("Models probes require the owned curl request adapter.")
			Record["request"] := Http
			OriginalBoundary := Http._DispatchPortFn("before_launch")
			Http.DispatchPort := Http.DispatchPort is Map ? Http.DispatchPort.Clone() : Map()
			Http.DispatchPort["before_launch"] := ObjBindMethod(this, "_BeforeLaunch", Record, OriginalBoundary)
			if !this._IsCurrent(Record) || A_IsSuspended
				return false
			Http.Open("GET", RTrim(Url, "/") . "/models", true)
			Limit := this.Options["timeout_ms"]
			Http.SetTimeouts(Limit, Limit, Limit, Limit)
			if StrLen(Token) > 0
				Http.SetRequestHeader("Authorization", "Bearer " . Token)
			; Header setup and request acquisition can pump a newer generation.
			if !this._IsCurrent(Record) || A_IsSuspended
				return false
			Accepted := Http.Send()
			if !this._IsCurrent(Record) || A_IsSuspended
				Accepted := false
			return Accepted
		} catch as Err {
			this._Report("dispatch", Err, Id)
			return false
		} finally {
			Record["building"] := false
			if !Accepted
				this._CancelRecord(Record)
			else
				this._Poll(Record)
		}
	}

	/**
	 * @param {String} Id Provider whose exact request must be cancelled.
	 * @returns {Boolean} Curl child and private curl files are settled.
	 * ShellRunner may independently retain its capture-release receipt.
	 */
	Cancel(Id) {
		PreviousCritical := Critical("Off")
		try {
			Record := this.Records.Get(Id, 0)
			return !(Record is Map) || this._CancelRecord(Record)
		} finally Critical(PreviousCritical)
	}

	/** Retries retained requests after a timer refusal or external state change. */
	RetryPending() {
		PreviousCritical := Critical("Off")
		try {
			Snapshot := this.Records.Clone()
			for _, Record in Snapshot
				this._Poll(Record)
			return this.Records.Count == 0
		} finally Critical(PreviousCritical)
	}

	/** @returns {Boolean} This owner still retains a provider's curl request. */
	HasPending(Id) {
		return this.Records.Has(Id)
	}

	_Owns(Record) {
		Held := this.Records.Get(Record["id"], 0)
		return Held is Map && ObjPtr(Held) == ObjPtr(Record)
			&& Held["generation"] == Record["generation"]
	}

	_IsCurrent(Record) {
		if !this._Owns(Record) || Record["cancelled"] || Record["delivered"]
			return false
		Current := Record["ticket"]
		Valid := Current.Call()
		; The ticket port can yield or reenter. Recheck exact native ownership.
		return (Valid is Integer) && Valid == true && this._Owns(Record) && !Record["cancelled"] && !Record["delivered"]
	}

	_BeforeLaunch(Record, OriginalBoundary, Http) {
		if HasMethod(OriginalBoundary, "Call")
			OriginalBoundary.Call(Http)
		; Send stages private files and can pump timers after the caller's gate.
		; Recheck at curl's actual child-acquisition boundary, not only before Send.
		if A_IsSuspended || !this._IsCurrent(Record)
			Http.Abort()
	}

	_CancelRecord(Record) {
		PreviousCritical := Critical("On")
		try {
			if !this._Owns(Record)
				return false
			Record["cancelled"] := true
			Record["settle"] := 0
			Http := Record["request"]
		} finally Critical(PreviousCritical)
		if Http is CurlAsyncRequest {
			try Http.Abort()
			catch as Err {
				this._Report("cancellation", Err, Record["id"])
			}
		}
		if this._ReleaseSettled(Record)
			return true
		this._Schedule(Record)
		return false
	}

	_Poll(Record) {
		PreviousCritical := Critical("Off")
		try return this._PollNonCritical(Record)
		finally Critical(PreviousCritical)
	}

	_PollNonCritical(Record) {
		PreviousCritical := Critical("On")
		try {
			if !this._Owns(Record) || Record["busy"] || Record["building"]
				return
			Record["busy"] := true
			Http := Record["request"]
		} finally Critical(PreviousCritical)
		try {
			if Record["cancelled"] {
				this._CancelRecord(Record)
				return
			}
			if Record["delivered"] {
				this._ReleaseSettled(Record)
				return
			}
			if !this._IsCurrent(Record) {
				this._CancelRecord(Record)
				return
			}
			if Http.WaitForResponse(0) {
				if A_IsSuspended
					return
				Receipt := Map("ok", Http.Status == 200, "status", Http.Status, "body", Http.ResponseText)
				Models := LocalServerAuthModelsReceipt(Receipt)
				Receipt["ok"] := Models is Array
				Receipt["models"] := Models is Array ? Models : []
				if !this._Deliver(Record, Receipt) && A_IsSuspended
					return
				this._ReleaseSettled(Record)
				return
			}
			if ((this._Clock() - Record["started_at"]) & 0xFFFFFFFF) >= this.Options["timeout_ms"] {
				if A_IsSuspended
					return
				if !this._Deliver(Record, Map("ok", false, "status", 0, "body", "", "models", [])) && A_IsSuspended
					return
				this._CancelRecord(Record)
			}
		} catch as Err {
			try {
				this._Report("poll", Err, Record["id"])
				if !A_IsSuspended
					this._Deliver(Record, Map("ok", false, "status", 0, "body", "", "models", []))
			} finally this._CancelRecord(Record)
		} finally {
			PreviousCritical := Critical("On")
			try Record["busy"] := false
			finally Critical(PreviousCritical)
			if this._Owns(Record)
				this._Schedule(Record)
		}
	}

	_Deliver(Record, Receipt) {
		if A_IsSuspended || !this._IsCurrent(Record)
			return false
		PreviousCritical := Critical("On")
		try {
			if A_IsSuspended || !this._Owns(Record) || Record["cancelled"] || Record["delivered"]
				return false
			Done := Record["settle"]
			Record["delivered"] := true
			Record["settle"] := 0
		} finally Critical(PreviousCritical)
		; Native slot admission is atomic; the logical ticket is current at its
		; independent check. Shared Settle owns the final atomic publication fence.
		; Client callbacks never run under Critical.
		Done.Call(Receipt)
		return true
	}

	_ReleaseSettled(Record) {
		if !this._Owns(Record) || Record["building"]
			return false
		Http := Record["request"]
		if Http is CurlAsyncRequest {
			if !Http.WaitForResponse(0)
				return false
			if Http.CleanupPending
				Http._Cleanup()
			if Http.CleanupPending
				return false
		}
		this._Timer(Record["timer"], 0)
		PreviousCritical := Critical("On")
		try {
			if !this._Owns(Record) || Record["building"]
				return false
			this.Records.Delete(Record["id"])
			Record["request"] := 0
			return true
		} finally Critical(PreviousCritical)
	}

	_Schedule(Record) {
		if this._Owns(Record)
			this._Timer(Record["timer"], -this.Options["poll_ms"])
	}

	_Timer(Callback, Period) {
		Timer := this.Options.Get("timer", ObjBindMethod(this, "_NativeTimer"))
		try {
			Accepted := Timer.Call(Callback, Period)
			if !((Accepted is Integer) && Accepted == true)
				throw Error("Models timer operation was refused.")
		} catch as Err {
			this._Report("timer", Err)
			throw Err
		}
	}

	_Clock() {
		Clock := this.Options.Get("clock", ObjBindMethod(this, "_NativeClock"))
		Now := Clock.Call()
		if !(Now is Integer)
			throw TypeError("Models clock must return integer milliseconds.")
		return Now
	}

	_Report(Kind, Err, Id := "") {
		Report := this.Options.Get("on_error", 0)
		if HasMethod(Report, "Call")
			Report.Call(Kind, Err, Id)
		else
			LoggerWarn("LLM.local_models", "Models {1} failed for provider {2}: {3}.", Kind, Id, Err.Message)
	}

	_NativeRequest() {
		return CurlAsyncRequest()
	}

	_NativeTimer(Callback, Period) {
		; This owner only cancels or rearms one exact record's one-shot. An
		; opaque positive interval must never become an idle repeating poller.
		if !(Period is Integer) || Period > 0
			throw TypeError("Models timers require cancellation or a negative one-shot period.")
		if Period == 0
			SetTimer(Callback, 0)
		else
			SetTimer(Callback, -Abs(Period))
		return true
	}

	_NativeClock() {
		return A_TickCount
	}
}
