; tests/unit/modules/llm/servers/test_ollama_managed_model_offer.ahk

; ==============================================================================
; MODULE: Ollama Managed Model Offer
; DESCRIPTION:
; The managed model offer keeps its source through the modal, second
; consent, notification and completion, and refuses non-Boolean consent,
; stale acknowledgements and generation reuse.
; ==============================================================================

#Requires AutoHotkey v2.0





; These cases exercise production callbacks with injected OS ports. They are
; authored for pinned AutoHotkey 2.0.26 and are UNRUN in the Linux container.
class _G4B_OfferFixture extends _G4B_Fixture {
	__New(Mode := "stable") {
		super.__New()
		global _LLM_ManagedBootstrap, _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_LocalModelAsking
		this.OfferSaved := [_LLM_ManagedBootstrap, _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_LocalModelAsking]
		_LLM_ManagedBootstrap := 0
		_LLM_LocalModelNotified := Map()
		_LLM_LocalModelAsking := false
		this.Mode := Mode
		this.ConfirmAck := true
		this.NotifyAck := true
		this.Confirms := 0
		this.Notices := 0
		this.Downloads := 0
		this.Done := 0
		this.Published := 0
		this.Start()
		this.Runtime.PublishReady()
		this.Model := "qwen3:0.6b"
		this.Flow.Port["pull"] := ObjBindMethod(this, "HoldPull")
		_LLM_ManagedBootstrap := this.Flow
		this.OfferPort := Map("confirm", ObjBindMethod(this, "OfferConfirm"), "notify", ObjBindMethod(this, "OfferNotify"))
		_LLM_LocalModelOfferPort := this.OfferPort
		this.Failure := LLM_LocalModelFailure(this.Model, LLM_OllamaRequestOrigin())
	}
	ChangeSource() {
		global _LLM_ManagedBootstrap, _LLM_LocalModelOfferPort, LLM_OLLAMA_BASE_URL
		switch this.Mode {
			case "endpoint": LLM_OLLAMA_BASE_URL := "http://localhost:23457"
			case "flow": _LLM_ManagedBootstrap := this.Flow.Clone()
			case "port": _LLM_LocalModelOfferPort := this.OfferPort.Clone()
			case "installer": this.OfferPort["install"] := (*) => this.Downloads += 1
			case "failure": this.Failure["base_url"] := "http://localhost:23457", this.Failure["model"] := "foreign:latest"
			case "cancel": this.Flow.Cancel()
			case "throw": throw Error("Injected modal refusal.")
		}
	}
	OfferConfirm(*) {
		this.Confirms += 1
		this.ChangeSource()
		return this.ConfirmAck
	}
	OfferNotify(*) {
		this.Notices += 1
		this.ChangeSource()
		return this.NotifyAck
	}
	HoldPull(Target, Model, Done) {
		this.Pulls += 1
		AssertEqual("http://127.0.0.1:23456", Target["origin"], "Dispatch uses the original managed listener, not configured localhost.")
		AssertEqual(this.Model, Model, "The callback cannot replace the consented model through Failure mutation.")
		this.Done := Done
		return true
	}
	OfferClose() {
		global _LLM_ManagedBootstrap, _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_LocalModelAsking
		try this.Close()
		finally {
			_LLM_ManagedBootstrap := this.OfferSaved[1]
			_LLM_LocalModelOfferPort := this.OfferSaved[2]
			_LLM_LocalModelNotified := this.OfferSaved[3]
			_LLM_LocalModelAsking := this.OfferSaved[4]
		}
	}
}

_G4B_OfferModal(Mode, ExpectedPulls, Ack := true) {
	F := _G4B_OfferFixture(Mode)
	global _LLM_LocalModelAsking
	try {
		F.ConfirmAck := Ack
		BeforeConsents := F.Consents.Length
		AssertTrue(LLM_LocalModelOffer(F.Failure), "A missing-model failure remains handled even when consent is stale.")
		AssertEqual(1, F.Confirms)
		AssertEqual(ExpectedPulls, F.Pulls)
		AssertEqual(0, F.Downloads, "A callback-installed replacement installer is never dispatched.")
		AssertFalse(_LLM_LocalModelAsking, "Every acceptance, refusal and thrown modal restores the asking guard.")
		AssertEqual(BeforeConsents + ExpectedPulls, F.Consents.Length, "Managed model consent remains separate from offer consent.")
		AssertEqual(0, F.FailedCalls, "A retired offer does not replay the bootstrap observer.")
	} finally F.OfferClose()
}

_G4B_OfferSecondConsent(Mode) {
	F := _G4B_OfferFixture(Mode)
	try {
		F.OfferPort["confirm"] := (*) => true
		F.Flow.Port["consent"] := (*) => (F.ChangeSource(), true)
		AssertTrue(LLM_LocalModelOffer(F.Failure))
		AssertEqual(0, F.Pulls, "Withdrawal during the second model consent forbids dispatch.")
		AssertFalse(F.Flow.MenuPull is Map, "Only the exact unsent operation retires logically.")
		AssertEqual(0, F.FailedCalls)
		if Mode != "cancel" {
			AssertTrue(F.Runtime.HasOwner(), "Offer withdrawal alone does not kill the original READY runtime.")
			AssertTrue(F.Flow.Ready)
		}
	} finally F.OfferClose()
}

_G4B_OfferNotification(Mode, Ack, ExpectedCount) {
	F := _G4B_OfferFixture(Mode)
	global _LLM_LocalModelNotified
	try {
		F.NotifyAck := Ack
		AssertTrue(LLM_LocalModelOffer(F.Failure, true))
		AssertEqual(1, F.Notices)
		AssertEqual(ExpectedCount, _LLM_LocalModelNotified.Count, "Only exact typed acknowledgement for the original source stamps the notice.")
		AssertEqual(0, F.Confirms, "A native notice has no invented TrayTip click consent.")
		AssertEqual(0, F.Pulls)
		if ExpectedCount {
			AssertTrue(LLM_LocalModelOffer(LLM_LocalModelFailure("QWEN3:0.6b", F.Failure["base_url"]), true))
			AssertEqual(1, F.Notices, "Model normalization still deduplicates notices at the same origin.")
		}
	} finally F.OfferClose()
}

_G4B_OfferCompletion(Mode) {
	F := _G4B_OfferFixture("stable")
	try {
		Receipt := _LLM_LocalModelOfferCapture(F.Failure, 0)
		AssertTrue(Receipt is Map)
		AssertTrue(F.Flow.PullModel(F.Model, (*) => F.Published += 1, _LLM_LocalModelOfferCurrent.Bind(Receipt)))
		F.Mode := Mode
		if Mode != "stable"
			F.ChangeSource()
		F.Done.Call(0)
		AssertEqual(Mode == "stable" ? 1 : 0, F.Published, "Late completion cannot publish for a successor source.")
		AssertFalse(F.Flow.MenuPull is Map)
		AssertEqual(0, F.FailedCalls)
		AssertEqual(Mode == "cancel" ? 1 : 0, F.Runtime.Stops, "Only actual cancellation retires the held runtime.")
		CallbackRuns := 0
		_LLM_LocalModelOfferPublished(Receipt, (*) => CallbackRuns += 1)
		AssertEqual(Mode == "stable" ? 1 : 0, CallbackRuns, "The delayed rebuild callback independently rechecks the original source.")
	} finally F.OfferClose()
}

_G4B_OfferExternal() {
	F := _G4B_OfferFixture("stable")
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	try {
		_LLM_ManagedBootstrap := 0
		F.Failure := LLM_LocalModelFailure(F.Model, LLM_OLLAMA_BASE_URL)
		F.OfferPort["install"] := (Origin, Model) => (AssertEqual(LLM_OLLAMA_BASE_URL, Origin), AssertEqual(F.Model, Model), F.Downloads += 1, true)
		AssertTrue(LLM_LocalModelOffer(F.Failure))
		AssertEqual(1, F.Downloads)
		AssertEqual(0, F.Pulls, "Configured external sources keep their captured command owner.")
		AssertTrue(F.Runtime.HasOwner(), "The offer never stops an unrelated managed runtime.")
		Receipt := _LLM_LocalModelOfferCapture(F.Failure, 0)
		LLM_OLLAMA_BASE_URL := "http://localhost:23457"
		AssertFalse(_LLM_LocalModelOfferSchedule(Receipt, (*) => F.Published += 1, -1))
		AssertEqual(0, F.Published, "A stale external rebuild is rejected before scheduling.")
	} finally F.OfferClose()
}

Test("managed model offer: modal stable retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("stable", 1))
Test("managed model offer: modal failure retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("failure", 1))
Test("managed model offer: modal endpoint retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("endpoint", 0))
Test("managed model offer: modal flow retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("flow", 0))
Test("managed model offer: modal port retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("port", 0))
Test("managed model offer: modal installer retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("installer", 0))
Test("managed model offer: modal cancel retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("cancel", 0))
Test("managed model offer: modal throw retains source (groups247-offer-affinity)", _G4B_OfferModal.Bind("throw", 0))
Test("managed model offer: refused consent refuses dispatch (groups247-offer-affinity)", _G4B_OfferModal.Bind("stable", 0, false))
Test("managed model offer: string consent refuses dispatch (groups247-offer-affinity)", _G4B_OfferModal.Bind("stable", 0, "true"))
Test("managed model offer: numeric-string consent refuses dispatch (groups247-offer-affinity)", _G4B_OfferModal.Bind("stable", 0, "1"))
Test("managed model offer: float consent refuses dispatch (groups247-offer-affinity)", _G4B_OfferModal.Bind("stable", 0, 1.0))
Test("managed model offer: second consent flow cannot borrow successor (groups247-offer-affinity)", _G4B_OfferSecondConsent.Bind("flow"))
Test("managed model offer: second consent endpoint cannot borrow successor (groups247-offer-affinity)", _G4B_OfferSecondConsent.Bind("endpoint"))
Test("managed model offer: second consent port cannot borrow successor (groups247-offer-affinity)", _G4B_OfferSecondConsent.Bind("port"))
Test("managed model offer: second consent cancel cannot borrow successor (groups247-offer-affinity)", _G4B_OfferSecondConsent.Bind("cancel"))
Test("managed model offer: notice stable true has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("stable", true, 1))
Test("managed model offer: notice stable false has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("stable", false, 0))
Test("managed model offer: notice stable string1string has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("stable", "1", 0))
Test("managed model offer: notice stable 1.0 has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("stable", 1.0, 0))
Test("managed model offer: notice flow true has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("flow", true, 0))
Test("managed model offer: notice endpoint true has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("endpoint", true, 0))
Test("managed model offer: notice port true has exact source ACK (groups247-offer-affinity)", _G4B_OfferNotification.Bind("port", true, 0))
Test("managed model offer: completion stable preserves successor cache (groups247-offer-affinity)", _G4B_OfferCompletion.Bind("stable"))
Test("managed model offer: completion flow preserves successor cache (groups247-offer-affinity)", _G4B_OfferCompletion.Bind("flow"))
Test("managed model offer: completion endpoint preserves successor cache (groups247-offer-affinity)", _G4B_OfferCompletion.Bind("endpoint"))
Test("managed model offer: completion port preserves successor cache (groups247-offer-affinity)", _G4B_OfferCompletion.Bind("port"))
Test("managed model offer: completion cancel preserves successor cache (groups247-offer-affinity)", _G4B_OfferCompletion.Bind("cancel"))
Test("managed model offer: external source and delayed rebuild remain fenced (groups247-offer-affinity)", _G4B_OfferExternal)


_G4B_OfferGenerationABA() {
	F := _G4B_OfferFixture("stable")
	global LLM_OLLAMA_BASE_URL, _LLM_AuxGeneration
	SavedGeneration := _LLM_AuxGeneration
	Confirm(*) {
		global LLM_OLLAMA_BASE_URL, _LLM_AuxGeneration
		LLM_OLLAMA_BASE_URL := "http://localhost:23457"
		_LLM_AuxGeneration += 1
		LLM_OLLAMA_BASE_URL := "http://localhost:23456"
		return true
	}
	try {
		F.OfferPort["confirm"] := Confirm
		AssertTrue(LLM_LocalModelOffer(F.Failure))
		AssertEqual(0, F.Pulls, "Restoring equal endpoint bytes cannot restore the old consent generation.")
		AssertTrue(F.Runtime.HasOwner())
	} finally {
		_LLM_AuxGeneration := SavedGeneration
		F.OfferClose()
	}
}

_G4B_OfferCurrentAck(Ack) {
	F := _G4B_OfferFixture("stable")
	State := Map("ack", true)
	Current() {
		if State["ack"] == "throw"
			throw Error("Injected source-current callback failure.")
		return State["ack"]
	}
	try {
		F.OfferPort["confirm"] := (*) => (State["ack"] := Ack, true)
		AssertTrue(LLM_LocalModelOffer(F.Failure, false, Current))
		AssertEqual(0, F.Pulls, "An untyped, refused or thrown source acknowledgement cannot renew consent.")
		AssertEqual(0, F.FailedCalls)
	} finally F.OfferClose()
}

_G4B_OfferNoticeOrigins() {
	F := _G4B_OfferFixture("stable")
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL, _LLM_LocalModelNotified
	try {
		_LLM_ManagedBootstrap := 0
		AssertTrue(LLM_LocalModelOffer(LLM_LocalModelFailure(F.Model, LLM_OLLAMA_BASE_URL), true))
		LLM_OLLAMA_BASE_URL := "http://localhost:23457"
		AssertTrue(LLM_LocalModelOffer(LLM_LocalModelFailure(F.Model, LLM_OLLAMA_BASE_URL), true))
		AssertEqual(2, F.Notices, "The same missing model on another origin receives its own notice.")
		AssertEqual(2, _LLM_LocalModelNotified.Count)
		AssertEqual(0, F.Pulls)
	} finally F.OfferClose()
}
Test("managed model offer: endpoint ABA cannot reuse consent generation (groups247-offer-affinity)", _G4B_OfferGenerationABA)
Test("managed model offer: false current ACK forbids dispatch (groups247-offer-affinity)", _G4B_OfferCurrentAck.Bind(false))
Test("managed model offer: string current ACK forbids dispatch (groups247-offer-affinity)", _G4B_OfferCurrentAck.Bind("1"))
Test("managed model offer: float current ACK forbids dispatch (groups247-offer-affinity)", _G4B_OfferCurrentAck.Bind(1.0))
Test("managed model offer: thrown current ACK forbids dispatch (groups247-offer-affinity)", _G4B_OfferCurrentAck.Bind("throw"))
Test("managed model offer: notice dedupe includes original origin (groups247-offer-affinity)", _G4B_OfferNoticeOrigins)
