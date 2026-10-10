; tests/unit/test_local_servers.ahk

; ==============================================================================
; MODULE: Composed Local Server Ownership Tests
; DESCRIPTION:
; Composes the actual shared controller, LocalServerModelsOwner and curl request
; seams. Controlled sources exercise causality, not DPAPI, disk or network E2E.
; Existing test_local_server_models.ahk provides the actual curl lifetime fixture.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Composition Fixture =======
; ======================================
; ======================================

class _LSO_Fixture extends _LSM_Fixture {
	__New(TwoProviders := false) {
		super.__New()
		this.Transport := this.Owner
		this.SourceGeneration := 1
		this.QueueTimers := Map()
		this.OnEntry := 0
		this.OnCapture := 0
		this.OnAdmission := 0
		this.PublicationDrift := false
		this.PublicationSeamHits := 0
		this.Published := []
		this.PersistCalls := []
		this.PersistAllowed := false
		this.RefuseReport := false
		this.Servers := Map("lmstudio", Map("label", "LM Studio", "auth", "optional",
			"base_url", "http://127.0.0.1:19273/custom/v1/"))
		this.Order := ["lmstudio"]
		this.Entries := Map("lmstudio", Map("Id", "entry-studio", "Provider", "lmstudio",
			"BaseUrl", this.Servers["lmstudio"]["base_url"], "Token", "old-key", "Model", "saved"))
		if TwoProviders {
			this.Servers["llamacpp"] := Map("label", "llama.cpp", "auth", "optional", "base_url", "http://127.0.0.1:19274/v1")
			this.Order.Push("llamacpp")
			this.Entries["llamacpp"] := Map("Id", "entry-llama", "Provider", "llamacpp",
				"BaseUrl", this.Servers["llamacpp"]["base_url"], "Token", "", "Model", "saved-llama")
		}
		this.Transport.Options["servers"] := this.Servers
		this.Native := LocalServersOwner(Map("order", this.Order, "servers", this.Servers,
			"models_owner", this.Transport, "poll_ms", 20,
			"clock", ObjBindMethod(this, "Clock"), "max_age", (*) => 1000,
			"entry", ObjBindMethod(this, "Entry"), "capture_source", ObjBindMethod(this, "CaptureSource"),
			"source_current", ObjBindMethod(this, "SourceCurrent"), "admit", ObjBindMethod(this, "Admission"),
			"apply", ObjBindMethod(this, "Persist"), "timer", ObjBindMethod(this, "QueueTimer"),
			"on_publish", ObjBindMethod(this, "Publish"), "on_error", ObjBindMethod(this, "NativeError")))
	}

	Entry(Id) {
		if HasMethod(this.OnEntry, "Call") {
			Callback := this.OnEntry, this.OnEntry := 0
			Callback.Call()
		}
		Entry := this.Entries.Get(Id, 0)
		return Entry is Map ? Entry.Clone() : 0
	}

	CaptureSource() {
		Source := {generation: this.SourceGeneration}
		if HasMethod(this.OnCapture, "Call") {
			Callback := this.OnCapture, this.OnCapture := 0
			Callback.Call()
		}
		return Source
	}

	SourceCurrent(Source) {
		if this.PublicationDrift && !this.Native.Controller.IsSweeping() && this.Native.Controller.HasCheckedAt {
			this.PublicationDrift := false
			this.PublicationSeamHits += 1
			this.Drift("old-key")
		}
		return IsObject(Source) && Source.generation == this.SourceGeneration
	}

	Admission() {
		if HasMethod(this.OnAdmission, "Call") {
			Callback := this.OnAdmission, this.OnAdmission := 0
			Callback.Call()
		}
		return true
	}

	Drift(Token := "new-key") {
		this.SourceGeneration += 1
		this.Entries["lmstudio"]["Token"] := Token
	}

	QueueTimer(Callback, Period) {
		this.CallbackCritical.Push(A_IsCritical)
		if Period == 0 {
			if this.QueueTimers.Has(ObjPtr(Callback))
				this.QueueTimers.Delete(ObjPtr(Callback))
		} else this.QueueTimers[ObjPtr(Callback)] := Callback
		return true
	}

	Publish(Fresh, Changed) {
		this.Published.Push(Fresh)
	}

	NativeError(Kind, Err, Id := "") {
		if this.RefuseReport {
			this.RefuseReport := false
			throw Error("controlled reporter failure")
		}
		this.Errors.Push(Kind)
	}

	Persist(Id, Fields, Source, Admission, SelectModel) {
		this.PersistCalls.Push(Map("id", Id, "fields", Fields, "source", Source))
		return this.PersistAllowed && this.SourceCurrent(Source) && Admission.Call()
			? Map("saved", true) : false
	}

	Dispose() {
		try {
			for Child in this.Children
				Child.TerminateAllowed := true
			this.OnEntry := 0, this.OnCapture := 0, this.OnAdmission := 0
			this.Native.Cancel(true)
			this.Native.RetryPending()
			AssertEqual(0, this.Native.Jobs.Count, "composition teardown must release every exact native queue job")
			AssertEqual(0, this.QueueTimers.Count, "composition teardown must acknowledge queue timers")
		} finally super.Dispose()
	}
}





; ===========================================
; ===========================================
; ======= 2/ Independent Causal Cases =======
; ===========================================
; ===========================================

_LSO_CacheCannotBorrowNewSource() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Complete(1, 200, '{"data":[{"id":"old-model"}]}')
		AssertEqual("old-model", Fixture.Native.Result("lmstudio")["models"][1])
		AssertEqual(1, Fixture.Published.Length)
		Fixture.Drift()
		Fixture.Native.BeginView()
		Receipt := Fixture.Native.Capture("lmstudio")
		AssertTrue(IsObject(Receipt), "address/key actions may capture current authority without model provenance")
		AssertFalse(Fixture.Native.IsCurrent(Receipt, "old-model"), "models discovered under the old key cannot borrow the new source")
		AssertEqual(0, Fixture.Native.Detected().Length)
		AssertTrue(Fixture.Native.IsStale())
		AssertFalse(Fixture.Native.Apply(Receipt, Map("model", "old-model")))
		AssertEqual(0, Fixture.PersistCalls.Length, "a stale cache cannot reach even the injected private publisher")
	} finally Fixture.Dispose()
}
Test("local server composition: fresh key cannot inherit old cached models", _LSO_CacheCannotBorrowNewSource)

_LSO_JointPublicationFencesSourceDrift() {
	Fixture := _LSO_Fixture(true)
	try {
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual(2, Fixture.Requests.Length)
		Fixture.Complete(1, 200, '{"data":[{"id":"early-model"}]}')
		AssertEqual(0, Fixture.Published.Length, "the first provider cannot publish a partial cache")
		Fixture.Drift()
		Fixture.Complete(2, 200, '{"data":[{"id":"late-model"}]}')
		Fixture.Native.RetryPending()
		AssertEqual(0, Fixture.Published.Length, "source replacement rejects the whole originating sweep")
		AssertFalse(Fixture.Native.Controller.IsSweeping())
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertFalse(Fixture.Native.Cache is Map, "old and new authority cannot form an accepted mixed cache")
	} finally Fixture.Dispose()
}
Test("local server composition: joint publication rejects partial-source drift", _LSO_JointPublicationFencesSourceDrift)

_LSO_SilentRetirementIsObserved() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual("active", Fixture.Native.Jobs["lmstudio"]["phase"])
		AssertEqual(1, Fixture.QueueTimers.Count, "active composition must retain a settlement observer timer")
		Fixture.Drift()
		Fixture.Transport.RetryPending()
		AssertFalse(Fixture.Transport.HasPending("lmstudio"), "the real transport silently retires the stale ticket")
		AssertTrue(Fixture.Native.Controller.IsSweeping(), "logical retirement has not yet been observed")
		Fixture.Native.RetryPending()
		AssertFalse(Fixture.Native.Controller.IsSweeping(), "native observation must end the stale logical search")
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertEqual(0, Fixture.QueueTimers.Count)
		AssertEqual(0, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
Test("local server composition: active timer observes silent stale transport retirement", _LSO_SilentRetirementIsObserved)

_LSO_EntryPortCannotBlessReplacedSource() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Complete(1, 200, '{"data":[{"id":"chosen"}]}')
		Fixture.Native.BeginView()
		Receipt := Fixture.Native.Capture("lmstudio")
		AssertTrue(Fixture.Native.IsCurrent(Receipt, "chosen"))
		Fixture.OnEntry := () => Fixture.Drift("old-key")
		AssertFalse(Fixture.Native.IsCurrent(Receipt), "retained address/key actions cannot borrow a replaced source even when target values match")
		AssertEqual(0, Fixture.PersistCalls.Length)
	} finally Fixture.Dispose()
}
Test("local server composition: yielding entry port cannot bless a replaced source", _LSO_EntryPortCannotBlessReplacedSource)

_LSO_ArmCreatorDrift(Fixture) {
	Fixture.OnEntry := () => Fixture.Drift("old-key")
}

_LSO_CreatorEntryPortFencesDispatch() {
	Fixture := _LSO_Fixture()
	try {
		Fixture.OnLaunch := (Request) => _LSO_ArmCreatorDrift(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Native.RetryPending()
		AssertEqual(1, Fixture.Requests.Length, "the real request factory was reached")
		AssertEqual(0, Fixture.Children.Length, "final source recheck refuses physical dispatch after the actual launch hook")
		AssertFalse(Fixture.Native.Controller.IsSweeping())
		AssertEqual(0, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
Test("local server composition: source drift during creator entry check prevents native launch", _LSO_CreatorEntryPortFencesDispatch)

_LSO_NewestSweepWaitsForExactDebt() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Children[1].TerminateAllowed := false
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual(1, Fixture.Requests.Length, "new search waits behind exact refused old child retirement")
		AssertTrue(Fixture.Transport.HasPending("lmstudio"))
		AssertEqual("waiting", Fixture.Native.Jobs["lmstudio"]["phase"])
		Fixture.Children[1].TerminateAllowed := true
		Fixture.Native.RetryPending()
		AssertEqual(2, Fixture.Requests.Length, "only acknowledged old settlement permits a new request")
		Fixture.Requests[1]._OnDone(0, '{"data":[{"id":"obsolete"}]}', "")
		AssertEqual(0, Fixture.Published.Length, "old native completion has no new logical publication authority")
		Fixture.Complete(2, 200, '{"data":[{"id":"newest"},{"id":"first"},{"id":"newest"}]}')
		Models := Fixture.Native.Result("lmstudio")["models"]
		AssertEqual(3, Models.Length)
		AssertEqual("newest", Models[1])
		AssertEqual("first", Models[2])
		AssertEqual("newest", Models[3])
		AssertEqual(1, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
Test("local server composition: newest search waits for exact old native debt", _LSO_NewestSweepWaitsForExactDebt)

_LSO_CaptureCannotStampNewView() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Complete(1, 200, '{"data":[{"id":"chosen"}]}')
		Fixture.Native.BeginView()
		Fixture.OnCapture := ObjBindMethod(Fixture.Native, "BeginView")
		AssertFalse(Fixture.Native.Capture("lmstudio"), "old acquisition cannot borrow a reentrant new menu generation")
		AssertEqual(0, Fixture.Native.Views.Count)
	} finally Fixture.Dispose()
}
Test("local server composition: interrupted acquisition cannot stamp a new view", _LSO_CaptureCannotStampNewView)

_LSO_ArmLateAdmission(Fixture) {
	Fixture.OnAdmission := () => Fixture.Drift("old-key")
}

_LSO_ArmCreatorAdmission(Fixture) {
	Fixture.OnEntry := _LSO_ArmLateAdmission.Bind(Fixture)
}

_LSO_LateAdmissionCannotBlessSource() {
	Fixture := _LSO_Fixture()
	try {
		Fixture.OnLaunch := (Request) => _LSO_ArmCreatorAdmission(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Native.RetryPending()
		AssertEqual(1, Fixture.Requests.Length)
		AssertEqual(0, Fixture.Children.Length, "final admission replacement cannot borrow the earlier source check")
		AssertFalse(Fixture.Native.Controller.IsSweeping())
		AssertEqual(0, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
Test("local server composition: late admission replacement cannot bless an old source", _LSO_LateAdmissionCannotBlessSource)

_LSO_PublicationRechecksOriginatingSource() {
	Fixture := _LSO_Fixture()
	try {
		Observed := Map("done", 0)
		OnDone := (Changed) => Observed["done"] += 1
		AssertTrue(Fixture.Native.Rescan(OnDone))
		Fixture.PublicationDrift := true
		Fixture.Complete(1, 200, '{"data":[{"id":"unpublished"}]}')
		Fixture.Native.RetryPending()
		AssertEqual(1, Fixture.PublicationSeamHits, "source replacement occurs inside the actual joint-publication seam")
		AssertEqual(0, Fixture.Published.Length, "a shared completed cache is not a native authority receipt")
		AssertEqual(0, Observed["done"], "rejected provenance cannot advertise a completed native rescan")
		AssertFalse(Fixture.Native.Cache is Map)
		AssertTrue(Fixture.Native.IsStale())
		AssertFalse(Fixture.Native.Controller.IsSweeping())
	} finally Fixture.Dispose()
}
Test("local server composition: joint publication independently rechecks original source", _LSO_PublicationRechecksOriginatingSource)

_LSO_ThrownProbeOwnsAutomaticPublication() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Complete(1, 200, '{"data":[{"id":"cached"}]}')
		PreviousCache := Fixture.Native.Cache
		AssertEqual(1, Fixture.Published.Length)
		AssertTrue(Fixture.Native.Rescan())
		Fixture.RefuseStop := true
		AssertTrue(Fixture.Native.Rescan(), "shared creator handles the real exact-transport timer-stop exception")
		AssertEqual(2, Fixture.Requests.Length, "the thrown replacement cannot claim a third child")
		AssertEqual(2, Fixture.Published.Length, "automatic shared failure settlement carries the newest source provenance")
		AssertTrue(ObjPtr(PreviousCache) != ObjPtr(Fixture.Native.Cache), "a rejected request must not freshen the old models cache")
		AssertEqual("down", Fixture.Native.Result("lmstudio")["status"])
		AssertFalse(Fixture.Native.IsStale(), "the acknowledged failure verdict, rather than old cached models, owns this age")
		Fixture.RefuseStop := false
		Fixture.Native.RetryPending()
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertFalse(Fixture.Native.IsStale(), "late orphaned queue retirement cannot invalidate accepted failure provenance")
	} finally {
		Fixture.RefuseStop := false
		Fixture.Dispose()
	}
}
Test("local server composition: thrown probe binds shared automatic failure publication", _LSO_ThrownProbeOwnsAutomaticPublication)

_LSO_DelayedOldProbeCannotBorrowGeneration() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		OldJob := Fixture.Native.Jobs["lmstudio"]
		OldSweep := OldJob["sweep"], OldSettle := OldJob["settle"], OldTicket := OldJob["ticket"]
		AssertTrue(Fixture.Native.Rescan())
		NewestJob := Fixture.Native.Jobs["lmstudio"]
		NewestRecord := Fixture.Transport.Records["lmstudio"]
		Generation := Fixture.Native.Controller.Generation
		AssertEqual(2, Fixture.Requests.Length)
		AssertTrue(Fixture.Native._Probe(OldSweep, Map("id", "lmstudio", "base_url", OldJob["target"]["base_url"]),
			OldSettle, Map("is_current", OldTicket)))
		AssertEqual(Generation, Fixture.Native.Controller.Generation)
		AssertEqual(ObjPtr(NewestJob), ObjPtr(Fixture.Native.Jobs["lmstudio"]), "stale producer preserves the newest exact native job")
		AssertEqual(ObjPtr(NewestRecord), ObjPtr(Fixture.Transport.Records["lmstudio"]), "stale producer cannot cancel the newest HTTP slot")
		AssertEqual(0, Fixture.Children[2].Terminations)
		Fixture.Complete(2, 200, '{"data":[{"id":"newest"}]}')
		AssertEqual("newest", Fixture.Native.Result("lmstudio")["models"][1])
	} finally Fixture.Dispose()
}
Test("local server composition: delayed old producer cannot borrow the newest generation", _LSO_DelayedOldProbeCannotBorrowGeneration)

_LSO_LogicalCreatorBoundary(Fixture, Original, Controller, Targets, Probe, OnDone) {
	Controller.DeleteProp("Sweep")
	Fixture.CreatorObserved["queued"] := Fixture.Native.Rescan()
	return Original.Call(Controller, Targets, Probe, OnDone)
}

_LSO_NewerIntentReplayedAfterOldCreator() {
	Fixture := _LSO_Fixture()
	try {
		Fixture.CreatorObserved := Map("queued", false)
		Original := LocalServerDiscoveryController.Prototype.GetOwnPropDesc("Sweep").Call
		Fixture.Native.Controller.DefineProp("Sweep", {Call: _LSO_LogicalCreatorBoundary.Bind(Fixture, Original)})
		AssertTrue(Fixture.Native.Rescan())
		AssertTrue(Fixture.CreatorObserved["queued"], "newer intent is admitted at the exact old logical creator boundary")
		AssertEqual(1, Fixture.Requests.Length, "the stale old logical creator cannot acquire a native child")
		AssertEqual(Fixture.Native.RescanGeneration, Fixture.Native.Jobs["lmstudio"]["sweep"]["intent"])
		AssertEqual(Fixture.Native.Controller.Generation, Fixture.Native.Jobs["lmstudio"]["sweep"]["generation"])
		AssertFalse(Fixture.Native.RescanBusy)
		Fixture.Complete(1, 200, '{"data":[{"id":"latest-intent"}]}')
		AssertEqual("latest-intent", Fixture.Native.Result("lmstudio")["models"][1])
		AssertEqual(1, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
Test("local server composition: newer intent replays after the old shared creator", _LSO_NewerIntentReplayedAfterOldCreator)

_LSO_ExactCancellationBoundary(Fixture, Original, Native, CapturedRecord) {
	Native.DeleteProp("_CancelExact")
	Fixture.CancellationObserved["old_settled"] := Original.Call(Native, CapturedRecord)
	Fixture.CancellationObserved["new_started"] := Native.Rescan()
	Fixture.CancellationObserved["new_record"] := Fixture.Transport.Records["lmstudio"]
	return Original.Call(Native, CapturedRecord)
}

_LSO_StaleCancellationPreservesPromotedNativeChild() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		OldSweep := Fixture.Native.Jobs["lmstudio"]["sweep"]
		Fixture.CancellationObserved := Map("old_settled", false, "new_started", false)
		Original := LocalServersOwner.Prototype.GetOwnPropDesc("_CancelExact").Call
		Fixture.Native.DefineProp("_CancelExact", {Call: _LSO_ExactCancellationBoundary.Bind(Fixture, Original)})
		Fixture.Native._InvalidateSweep(OldSweep)
		AssertTrue(Fixture.CancellationObserved["old_settled"])
		AssertTrue(Fixture.CancellationObserved["new_started"])
		AssertEqual(2, Fixture.Requests.Length)
		AssertEqual(ObjPtr(Fixture.CancellationObserved["new_record"]), ObjPtr(Fixture.Transport.Records["lmstudio"]))
		AssertEqual(0, Fixture.Children[2].Terminations, "stale exact-record cancellation cannot borrow a promoted provider slot")
		AssertTrue(Fixture.Native.Controller.IsSweeping(), "the successor's logical generation also survives old cancellation")
		Fixture.Complete(2, 200, '{"data":[{"id":"survivor"}]}')
		AssertEqual("survivor", Fixture.Native.Result("lmstudio")["models"][1])
	} finally Fixture.Dispose()
}
Test("local server composition: stale cancellation preserves a promoted native child", _LSO_StaleCancellationPreservesPromotedNativeChild)

_LSO_CancelledLogicalCreatorBoundary(Fixture, Original, Shutdown, Controller, Targets, Probe, OnDone) {
	Controller.DeleteProp("Sweep")
	Fixture.CreatorObserved["cancelled"] := Fixture.Native.Cancel(Shutdown)
	return Original.Call(Controller, Targets, Probe, OnDone)
}

_LSO_CancelAtLogicalCreatorCannotLeaveGhostSweep(Shutdown) {
	Fixture := _LSO_Fixture()
	try {
		Fixture.CreatorObserved := Map("cancelled", false)
		Original := LocalServerDiscoveryController.Prototype.GetOwnPropDesc("Sweep").Call
		Fixture.Native.Controller.DefineProp("Sweep", {Call: _LSO_CancelledLogicalCreatorBoundary.Bind(Fixture, Original, Shutdown)})
		Fixture.Native.Rescan()
		AssertTrue(Fixture.CreatorObserved["cancelled"])
		AssertEqual(0, Fixture.Requests.Length, "cancellation at the old creator boundary acquires no native child")
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertEqual(0, Fixture.QueueTimers.Count)
		AssertFalse(Fixture.Native.Controller.IsSweeping(), "refused live producer must finish the exact delayed logical generation")
		AssertFalse(Fixture.Native.RescanBusy)
		AssertEqual(Shutdown, Fixture.Native.Closed)
	} finally Fixture.Dispose()
}
Test("local server composition: creator-gap cancellation leaves no ghost search", _LSO_CancelAtLogicalCreatorCannotLeaveGhostSweep.Bind(false))
Test("local server composition: creator-gap shutdown leaves no ghost search", _LSO_CancelAtLogicalCreatorCannotLeaveGhostSweep.Bind(true))

_LSO_QueuedSourceFailure(Fixture) {
	Fixture.CreatorObserved["queued"] := Fixture.Native.Rescan()
	throw Error("controlled source failure")
}

_LSO_ReporterFailureStillReplaysLatestCreator() {
	Fixture := _LSO_Fixture()
	try {
		Fixture.CreatorObserved := Map("queued", false)
		Fixture.RefuseReport := true
		Fixture.OnCapture := _LSO_QueuedSourceFailure.Bind(Fixture)
		ObservedError := ""
		try Fixture.Native.Rescan()
		catch as Err {
			ObservedError := Err.Message
		}
		AssertTrue(InStr(ObservedError, "controlled reporter failure"), "secondary failure must reach the caller after ownership is released")
		AssertTrue(Fixture.CreatorObserved["queued"])
		AssertFalse(Fixture.Native.RescanBusy, "exceptional reporting cannot strand creator admission")
		AssertFalse(Fixture.Native.QueuedRescan is Map)
		AssertEqual(1, Fixture.Requests.Length, "the newest queued intent is replayed despite an earlier report failure")
		AssertEqual(Fixture.Native.RescanGeneration, Fixture.Native.Jobs["lmstudio"]["sweep"]["intent"])
		Fixture.Complete(1, 200, '{"data":[{"id":"replayed"}]}')
		AssertEqual("replayed", Fixture.Native.Result("lmstudio")["models"][1])
	} finally Fixture.Dispose()
}
Test("local server composition: reporting failure releases and replays the latest creator", _LSO_ReporterFailureStillReplaysLatestCreator)





; ===========================================
; ===========================================
; ======= 3/ Active Queue Observation =======
; ===========================================
; ===========================================

_LSO_CountSourceCurrent(Fixture, Source) {
	Fixture.SourceChecks += 1
	return _LSO_Fixture.Prototype.SourceCurrent.Call(Fixture, Source)
}

_LSO_ActivePendingObserver() {
	Fixture := _LSO_Fixture()
	try {
		Fixture.SourceChecks := 0
		Fixture.DefineProp("SourceCurrent", {Call: _LSO_CountSourceCurrent})
		AssertTrue(Fixture.Native.Rescan())
		Job := Fixture.Native.Jobs["lmstudio"]
		AssertEqual("active", Job["phase"])
		AssertTrue(Fixture.Transport.HasPending("lmstudio"))
		Fixture.SourceChecks := 0
		Fixture.Native._Tick(Job)
		AssertEqual(0, Fixture.SourceChecks, "a pending queue observation must not duplicate the transport's source reads")
		AssertEqual(1, Fixture.QueueTimers.Count, "the exact settlement observer remains armed")
		AssertEqual(1, Fixture.Requests.Length, "the observer acquires no successor request")
		Fixture.Drift()
		Fixture.Transport.RetryPending()
		AssertTrue(Fixture.SourceChecks > 0, "the real transport must still check and refuse the changed source")
		AssertFalse(Fixture.Transport.HasPending("lmstudio"))
		Fixture.Native.RetryPending()
		AssertFalse(Fixture.Native.Controller.IsSweeping())
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertEqual(0, Fixture.QueueTimers.Count)
		AssertEqual(0, Fixture.Published.Length, "changed-source retirement cannot publish a cache")
	} finally Fixture.Dispose()
}
Test("local active observer: pending tick delegates source cancellation to actual transport", _LSO_ActivePendingObserver)

_LSO_ActivePendingCheapFence(Kind) {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Job := Fixture.Native.Jobs["lmstudio"]
		switch Kind {
			case "closed": Fixture.Native.Closed := true
			case "configuration": Fixture.Native.ConfigurationGeneration += 1
			case "rescan": Fixture.Native.RescanGeneration += 1
			case "ticket": Fixture.Native.Controller.Invalidate()
		}
		Fixture.Native._Tick(Job)
		AssertEqual(0, Fixture.Native.Jobs.Count, "a cheap ownership refusal must still retire the exact job")
		AssertFalse(Fixture.Transport.HasPending("lmstudio"))
		AssertTrue(Fixture.Children[1].Terminations > 0, "refusal must request exact physical child retirement")
		AssertEqual(0, Fixture.QueueTimers.Count)
		AssertEqual(0, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
for Kind in ["closed", "configuration", "rescan", "ticket"]
	Test("local active observer: pending tick retains " Kind " refusal", _LSO_ActivePendingCheapFence.Bind(Kind))





; =========================================
; =========================================
; ======= 4/ Final Job Source Fence =======
; =========================================
; =========================================

_LSCJ_MutatingTicket(Fixture, Original) {
	Fixture.TicketReads += 1
	if Fixture.TicketReads == 2
		Fixture.Drift("old-key")
	return Original.Call()
}

_LSCJ_LastTicketCannotReplaceSource() {
	Fixture := _LSO_Fixture()
	Job := 0, Original := 0
	try {
		AssertTrue(Fixture.Native.Rescan())
		Job := Fixture.Native.Jobs["lmstudio"]
		Original := Job["ticket"]
		Fixture.TicketReads := 0
		Job["ticket"] := _LSCJ_MutatingTicket.Bind(Fixture, Original)
		AssertFalse(Fixture.Native._CurrentJob(Job), "the final callback cannot replace source after its last full check")
		AssertEqual(2, Fixture.TicketReads, "the source mutation must occur at the real last ticket callback")
		AssertTrue(Fixture.Transport.HasPending("lmstudio"), "a rejected query cannot infer physical retirement")
		AssertEqual(0, Fixture.Published.Length)
	} finally {
		if Job is Map && HasMethod(Original, "Call")
			Job["ticket"] := Original
		Fixture.Dispose()
	}
}
Test("local job final fence: last ticket source replacement is refused", _LSCJ_LastTicketCannotReplaceSource)

_LSCJ_LastSourceInvalidatesLogicalTicket(Fixture, Source) {
	Fixture.SourceChecks += 1
	Accepted := _LSO_Fixture.Prototype.SourceCurrent.Call(Fixture, Source)
	if Fixture.SourceChecks == 2
		Fixture.Native.Controller.Invalidate()
	return Accepted
}

_LSCJ_LastSourceCannotReplaceTicket() {
	Fixture := _LSO_Fixture()
	try {
		AssertTrue(Fixture.Native.Rescan())
		Job := Fixture.Native.Jobs["lmstudio"]
		Fixture.SourceChecks := 0
		Fixture.DefineProp("SourceCurrent", {Call: _LSCJ_LastSourceInvalidatesLogicalTicket})
		AssertFalse(Fixture.Native._CurrentJob(Job), "a final source read cannot retain a replaced logical sweep")
		AssertEqual(2, Fixture.SourceChecks, "the logical replacement must occur at the actual final source boundary")
		AssertTrue(Fixture.Transport.HasPending("lmstudio"))
		AssertEqual(0, Fixture.Published.Length)
	} finally Fixture.Dispose()
}
Test("local job final fence: last source boundary preserves logical refusal", _LSCJ_LastSourceCannotReplaceTicket)


