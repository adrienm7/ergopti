; tests/unit/test_local_server_join.ahk

; ==============================================================================
; MODULE: Actual Local Discovery and Private Publication Join Tests
; DESCRIPTION:
; Joins the real private source/files/DPAPI/WAL and full writer defaults with
; the real shared controller, native cache and retained write-phase ownership.
; Only HTTP child responses and runtime application/notification are controlled.
; Physical network, menu input, backend application and installation are not proven.
; Load after test_local_server_models and test_local_server_private_publication.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Actual Join Fixture =======
; ======================================
; ======================================

class _LSJ_Fixture extends _LSM_Fixture {
	__New() {
		super.__New()
		this.World := 0
		this.Native := 0
		this.Control := ""
		this.PersistCalls := 0
		this.DurableCalls := 0
		this.CommittedProofs := 0
		this.ClaimCalls := 0
		this.ClaimAllowed := false
		this.ClaimCritical := 0
		this.OriginalCurrentAfterDurable := true
		this.WrongOrigin := true
		this.Mutated := false
		this.NativeAdmission := 0
		this.Source := 0
		this.OtherSource := 0
		this.Capability := 0
		this.WalHandle := 0
		this.Publications := []
		try {
			AssertFalse(_ConfigFullSaveHasPending(), "the independent join fixture must not borrow a pending global save")
			AssertFalse(_ConfigFullSaveCoordinator().timer_armed)
			this.World := _LSP_World()
			this.World.ConfigImage .= '[independent_join]`nretained = "outside-ai-sentinel"`n'
			AssertTrue(FSWriteDurable(this.World.ConfigPath, this.World.ConfigImage))
			; Upgrade the independent initial source to actual encrypted envelopes.
			; Native RAM keeps the corresponding original decoded values.
			Encrypted := JsonParse(this.World.ApiImage)
			for Entry in Encrypted {
				Token := LLM_ApiToken_Encrypt(Entry["Token"])
				AssertTrue(Token is String && LLM_ApiToken_IsValidEnvelope(Token))
				Entry["Token"] := Token
			}
			this.World.ApiImage := _LLM_Menu_SerializeApiEntries(Map("api_entries", Encrypted), (Value) => Value)
			AssertTrue(FSWriteDurable(this.World.ApiPath, this.World.ApiImage))
			this.World.Port["read"] := ObjBindMethod(this, "Read")
			; Production defaults own acquisition, settlement, the FULL collector,
			; TOML rendering, DPAPI API serialization and durable compensation.
			this.World.Owner.Options := Map("port", this.World.Port,
				"apply", ObjBindMethod(this.World, "ApplyCommitted"), "notify", _LMT_Notify,
				"pause", ObjBindMethod(this, "Pause"))
			global LLM_LOCAL_API_SERVERS, LLM_API_PROVIDER_ORDER
			this.Order := []
			for Id in LLM_API_PROVIDER_ORDER
				if LLM_LOCAL_API_SERVERS.Has(Id)
					this.Order.Push(Id)
			AssertEqual(LLM_LOCAL_API_SERVERS.Count, this.Order.Length)
			AssertTrue(this.Order.Length > 0)
			this.Owner.Options["servers"] := LLM_LOCAL_API_SERVERS
			Ports := this.World.Owner.Ports()
			Ports["order"] := this.Order
			Ports["servers"] := LLM_LOCAL_API_SERVERS
			Ports["models_owner"] := this.Owner
			Ports["poll_ms"] := TimingsGet("llm", "poll_interval_ms")
			Ports["clock"] := ObjBindMethod(this, "Clock")
			Ports["max_age"] := (*) => TimingsGet("llm", "local_server_detection_max_age_ms")
			Ports["apply"] := ObjBindMethod(this, "Persist")
			Ports["on_publish"] := ObjBindMethod(this, "Published")
			Ports["on_error"] := ObjBindMethod(this, "Report")
			this.Native := LocalServersOwner(Ports)
		} catch as Err {
			; A derived panel has not acquired its fields while this constructor runs.
			; Retire only the established join/base owners before rethrowing its failure.
			_LSJ_Fixture.Prototype.Dispose.Call(this)
			throw Err
		}
	}

	Published(Results, Changed) {
		this.Publications.Push(Results)
	}

	Prepare() {
		AssertTrue(this.Native.Rescan())
		AssertEqual(this.Order.Length, this.Requests.Length, "the real catalogue admits every local target")
		for Index, Id in this.Order {
			Body := Id == "lmstudio" ? '{"data":[{"id":"independent-joined"},{"id":"other-joined"}]}' : '{"data":[]}'
			this.Complete(Index, 200, Body)
		}
		AssertFalse(this.Native.Controller.IsSweeping())
		AssertEqual(0, this.Native.Jobs.Count)
		AssertEqual(1, this.Publications.Length)
		AssertEqual("independent-joined", this.Native.Result("lmstudio")["models"][1])
		this.OtherSource := this.World.Owner.Capture()
		AssertTrue(this.OtherSource is LLM_Menu_ApiPrivateSourceReceipt)
		this.Native.BeginView()
		this.Receipt := this.Native.Capture("lmstudio")
		AssertTrue(IsObject(this.Receipt))
		AssertTrue(this.Native.IsCurrent(this.Receipt, "independent-joined"))
		this.NativeConfiguration := this.Native.ConfigurationGeneration
		this.OriginalController := this.Native.Controller.Generation
	}

	Persist(Id, Fields, Source, Admission, SelectModel) {
		this.PersistCalls += 1
		this.Source := Source
		this.World.Receipt := Source
		this.NativeAdmission := Admission
		return this.World.Owner.Apply(Id, Fields, Source,
			ObjBindMethod(this, "ObserveAdmission", Admission), SelectModel)
	}

	ObserveAdmission(Admission, Phase := "", Capability := 0) {
		if Phase == "claim" {
			; This wrapper participates in the private publisher's short final
			; region. Only scalar observation plus the real native claim occurs.
			this.ClaimCalls += 1
			this.ClaimCritical := A_IsCritical
			this.ClaimAllowed := Admission.Call(Phase, Capability)
			return this.ClaimAllowed
		}
		Admitted := Admission.Call(Phase, Capability)
		if Phase == "committed" {
			this.Capability := Capability
			if (Admitted is Integer) && Admitted == 1
				this.CommittedProofs += 1
		}
		return Admitted
	}

	Read(Path) {
		Content := FSReadUtf8Exact(Path)
		if this.Control == "late_view" && this.CommittedProofs >= 2 && !this.Mutated {
			this.Mutated := true
			this.Native.BeginView()
		}
		return Content
	}

	Pause(Point) {
		this.World.Pause(Point)
		if !(Point == "phase:committed_new")
			return
		this.DurableCalls += 1
		this.OriginalCurrentAfterDurable := this.World.Owner.Current(this.Source)
		switch this.Control {
			case "committed_view":
				this.Mutated := true
				this.Native.BeginView()
			case "committed_controller":
				this.Mutated := true
				this.Native.Controller.Invalidate()
			case "wrong_origin":
				this.WrongOrigin := this.World.Owner.CaptureCandidate(this.OtherSource,
					this.World.OwnedBundle, this.World.ConfigCandidate, this.World.ApiCandidate)
			case "foreign_image":
				Records := JsonParse(this.World.ApiImage)
				Records[1]["Name"] := "Independent foreign writer"
				this.ForeignImage := _LLM_Menu_SerializeApiEntries(Map("api_entries", Records), (Value) => Value)
				if !FSWriteDurable(this.World.ApiPath, this.ForeignImage)
					throw Error("The fixture-owned independent source replacement was refused.")
				this.Mutated := true
			case "locked_wal":
				global _PathsFile
				this.WalHandle := DllCall("Kernel32\CreateFileW", "Str", ConfigTransitionWalPath(_PathsFile),
					"UInt", 0x80000000, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
				if this.WalHandle == 0 || this.WalHandle == -1
					throw Error("The join fixture could not acquire its exact WAL deletion lock.")
		}
	}

	ApplyModel() {
		return this.Native.Apply(this.Receipt, Map("model", "independent-joined"))
	}

	AssertRetired() {
		global _PathsFile
		AssertFalse(this.Native.Writing)
		AssertFalse(this.Native.WriteClaim is Map)
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1)
	}

	CloseWal() {
		if this.WalHandle && this.WalHandle != -1 {
			Closed := DllCall("Kernel32\CloseHandle", "Ptr", this.WalHandle, "Int")
			if !Closed
				throw Error("The join fixture could not close its exact WAL lock.")
			this.WalHandle := 0
		}
	}

	Dispose() {
		try {
			try this.CloseWal()
			finally {
				if this.Native is LocalServersOwner {
					this.Native.Cancel(true)
					this.Native.RetryPending()
					AssertEqual(0, this.Native.Jobs.Count)
				}
			}
		} finally {
			try {
				if this.World is _LSP_World
					this.World.Restore()
			} finally super.Dispose()
		}
		this.NativeAdmission := 0
		this.Source := 0
		this.OtherSource := 0
		this.Capability := 0
		this.Native := 0
		this.World := 0
	}
}





; ===========================================
; ===========================================
; ======= 2/ Nominal Joined Authority =======
; ===========================================
; ===========================================

_LSJ_Nominal(Control := "") {
	global _LLM_Menu, Features
	Fixture := _LSJ_Fixture()
	try {
		Fixture.Control := Control
		Fixture.Prepare()
		Saved := Fixture.ApplyModel()
		AssertTrue(Saved is Map, "actual joined model publication must acknowledge saved success")
		AssertTrue(Saved["saved"])
		AssertTrue(Saved["selected"])
		AssertEqual("native-active", Saved["entry_id"])
		AssertEqual(1, Fixture.PersistCalls)
		AssertEqual(1, Fixture.DurableCalls)
		AssertTrue(Fixture.CommittedProofs >= 2)
		AssertEqual(1, Fixture.ClaimCalls)
		AssertTrue(Fixture.ClaimAllowed)
		AssertTrue(Fixture.ClaimCritical > 0)
		AssertFalse(Fixture.OriginalCurrentAfterDurable, "general old source authority stays revoked at real durability")
		AssertFalse(Fixture.World.Owner.Current(Fixture.Source))
		AssertFalse(Fixture.World.Owner.CandidateCurrent(Fixture.Capability), "released bundle cannot lend candidate authority")
		AssertEqual("api", _LLM_Menu["backend"])
		AssertEqual("native-active", _LLM_Menu["api_entry_id"])
		AssertEqual("api", Features["llm"]["models"]["selected"])
		AssertEqual("Original active", _LLM_Menu["api_entries"][2]["Name"])
		AssertEqual("independent-joined", _LLM_Menu["api_entries"][2]["Model"])
		AssertEqual("private-active-sentinel", _LLM_Menu["api_entries"][2]["Token"])
		AssertEqual("http://127.0.0.1:1235/v1", _LLM_Menu["api_entries"][2]["BaseUrl"])
		Document := TOML_ParseDocument(FSReadUtf8Exact(Fixture.World.ConfigPath))
		AssertEqual("api", Document["llm"]["models"]["selected"])
		AssertEqual("native-active", Document["llm"]["api_entry_id"])
		AssertEqual("outside-ai-sentinel", Document["independent_join"]["retained"], "the actual full writer preserves an unrelated independent section")
		Records := JsonParse(FSReadUtf8Exact(Fixture.World.ApiPath))
		AssertEqual(2, Records.Length)
		AssertEqual("independent-first", Records[1]["Model"])
		AssertEqual("independent-joined", Records[2]["Model"])
		AssertTrue(LLM_ApiToken_IsValidEnvelope(Records[2]["Token"]))
		AssertEqual("private-active-sentinel", LLM_ApiToken_Decrypt(Records[2]["Token"]))
		AssertFalse(InStr(FSReadUtf8Exact(Fixture.World.ApiPath), "private-active-sentinel"))
		AssertEqual(1, Fixture.World.ApplyCalls)
		AssertEqual(Fixture.NativeConfiguration + 1, Fixture.Native.ConfigurationGeneration)
		AssertFalse(Fixture.Native.IsCurrent(Fixture.Receipt, "independent-joined"))
		if Control == "wrong_origin"
			AssertFalse(Fixture.WrongOrigin is LLM_Menu_ApiPrivateCandidateReceipt, "identical second source cannot mint the bound candidate")
		Fixture.AssertRetired()
	} finally Fixture.Dispose()
}
Test("Local join: actual discovery admission saves and selects real encrypted private files", _LSJ_Nominal)
Test("Local join: wrong originating real source cannot mint candidate during otherwise successful save", _LSJ_Nominal.Bind("wrong_origin"))

_LSJ_FieldsPreserveSelection() {
	global _LLM_Menu
	Fixture := _LSJ_Fixture()
	try {
		Fixture.Prepare()
		Saved := Fixture.Native.Apply(Fixture.Receipt, Map("base_url", "http://127.0.0.1:19311/custom/v1/",
			"token", "  exact-private-next  "))
		AssertTrue(Saved is Map && Saved["saved"])
		AssertFalse(Saved["selected"])
		AssertEqual("ollama", _LLM_Menu["backend"])
		AssertEqual("native-active", _LLM_Menu["api_entry_id"])
		AssertEqual("independent-active", _LLM_Menu["api_entries"][2]["Model"])
		AssertEqual("  exact-private-next  ", _LLM_Menu["api_entries"][2]["Token"])
		AssertEqual("http://127.0.0.1:19311/custom/v1/", _LLM_Menu["api_entries"][2]["BaseUrl"])
		Records := JsonParse(FSReadUtf8Exact(Fixture.World.ApiPath))
		AssertEqual("  exact-private-next  ", LLM_ApiToken_Decrypt(Records[2]["Token"]))
		AssertFalse(Fixture.OriginalCurrentAfterDurable)
		AssertTrue(Fixture.ClaimAllowed)
		Fixture.AssertRetired()
	} finally Fixture.Dispose()
}
Test("Local join: acknowledged address and exact key update preserves model and backend", _LSJ_FieldsPreserveSelection)





; =========================================
; =========================================
; ======= 3/ Causal Joined Refusals =======
; =========================================
; =========================================

_LSJ_StaleBeforeDurability() {
	Fixture := _LSJ_Fixture()
	try {
		Fixture.Prepare()
		Fixture.Native.BeginView()
		AssertFalse(Fixture.ApplyModel())
		AssertEqual(0, Fixture.PersistCalls)
		AssertEqual(0, Fixture.DurableCalls)
		Fixture.World.AssertUnchanged()
		Fixture.AssertRetired()
	} finally Fixture.Dispose()
}
Test("Local join: stale retained model refuses before real private writer admission", _LSJ_StaleBeforeDurability)

_LSJ_DurableRefusal(Control) {
	Fixture := _LSJ_Fixture()
	try {
		Fixture.Control := Control
		Fixture.Prepare()
		AssertFalse(Fixture.ApplyModel())
		AssertEqual(1, Fixture.PersistCalls)
		AssertEqual(1, Fixture.DurableCalls)
		AssertTrue(Fixture.Mutated, "controlled real write boundary must actually revoke the native view")
		AssertFalse(Fixture.OriginalCurrentAfterDurable)
		AssertEqual(Fixture.NativeConfiguration, Fixture.Native.ConfigurationGeneration)
		Fixture.World.AssertUnchanged()
		AssertTrue(Fixture.World.Owner.Current(Fixture.Source), "exact rollback restores ordinary source images only")
		if Control == "committed_controller" {
			; General cache views may survive a logical rescan. The in-flight
			; writer must still reject the controller that admitted its claim.
			AssertTrue(Fixture.OriginalController != Fixture.Native.Controller.Generation)
			AssertTrue(Fixture.Native.IsStale(), "the exact accepted cache generation is now stale")
		} else {
			AssertFalse(Fixture.Native.IsCurrent(Fixture.Receipt, "independent-joined"))
		}
		if Control == "late_view" {
			AssertTrue(Fixture.CommittedProofs >= 2, "both full native proofs passed before the real final file reread")
			AssertEqual(1, Fixture.ClaimCalls)
			AssertFalse(Fixture.ClaimAllowed, "final bounded claim must reject the late native view")
		} else {
			AssertEqual(0, Fixture.ClaimCalls)
			AssertEqual(0, Fixture.CommittedProofs)
		}
		Fixture.AssertRetired()
	} finally Fixture.Dispose()
}
Test("Local join: actual durable model-view refusal rolls both private files back", _LSJ_DurableRefusal.Bind("committed_view"))
Test("Local join: actual durable controller refusal rolls both private files back", _LSJ_DurableRefusal.Bind("committed_controller"))
Test("Local join: real final file reread cannot outlive the bounded native model claim", _LSJ_DurableRefusal.Bind("late_view"))

_LSJ_ForeignImageDebt() {
	global _LLM_Menu, Features, _PathsFile, _ConfigTransitionRetainedBarrier
	Fixture := _LSJ_Fixture()
	try {
		Fixture.Control := "foreign_image"
		Fixture.Prepare()
		AssertFalse(Fixture.ApplyModel())
		AssertTrue(Fixture.Mutated)
		AssertEqual(1, Fixture.DurableCalls)
		AssertFalse(Fixture.OriginalCurrentAfterDurable)
		AssertEqual(Fixture.ForeignImage, FSReadUtf8Exact(Fixture.World.ApiPath), "foreign durable bytes cannot be overwritten by compensation")
		AssertEqual(Fixture.World.ConfigCandidate, FSReadUtf8Exact(Fixture.World.ConfigPath))
		AssertTrue(_LLM_Menu == Fixture.World.OldMenu)
		AssertTrue(Features == Fixture.World.OldFeatures)
		AssertEqual(0, Fixture.World.ApplyCalls)
		AssertTrue(_ConfigWriteTerminalIsActive())
		AssertTrue(_ConfigWriteLeaseState().terminal == Fixture.World.OwnedBundle)
		AssertTrue(_ConfigTransitionRetainedBarrier == Fixture.World.OwnedBundle)
		AssertTrue(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1)
		AssertFalse(Fixture.World.Owner.Current(Fixture.Source))
		AssertFalse(Fixture.Native.IsCurrent(Fixture.Receipt, "independent-joined"))
		AssertFalse(Fixture.Native.Writing)
		AssertFalse(Fixture.Native.WriteClaim is Map)
	} finally Fixture.Dispose()
}
Test("Local join: foreign post-durable source retains exact WAL debt without native selection", _LSJ_ForeignImageDebt)

_LSJ_PhysicalCleanupDebt() {
	global _LLM_Menu, _PathsFile, _ConfigTransitionRetainedBarrier
	Fixture := _LSJ_Fixture()
	try {
		Fixture.Control := "locked_wal"
		Fixture.Prepare()
		AssertFalse(Fixture.ApplyModel(), "RAM publication without actual journal retirement must not claim saved success")
		AssertTrue(Fixture.WalHandle != 0 && Fixture.WalHandle != -1)
		AssertEqual(1, Fixture.World.ApplyCalls)
		AssertTrue(Fixture.ClaimAllowed)
		AssertEqual("api", _LLM_Menu["backend"])
		AssertEqual("independent-joined", _LLM_Menu["api_entries"][2]["Model"])
		AssertTrue(_ConfigWriteLeaseState().terminal == Fixture.World.OwnedBundle)
		AssertTrue(_ConfigTransitionRetainedBarrier == Fixture.World.OwnedBundle)
		AssertTrue(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1)
		AssertFalse(Fixture.World.Owner.Current(Fixture.Source))
		AssertFalse(Fixture.World.Owner.CandidateCurrent(Fixture.Capability), "unbound candidate cannot conceal retained physical debt")
		AssertFalse(Fixture.Native.Writing)
		AssertFalse(Fixture.Native.WriteClaim is Map)
	} finally Fixture.Dispose()
}
Test("Local join: actual Windows WAL deletion lock keeps saved acknowledgment false", _LSJ_PhysicalCleanupDebt)





; ====================================================
; ====================================================
; ======= 4/ Failed Constructor Owner Boundary =======
; ====================================================
; ====================================================

/** Refuses before any private-world files, publication or native request exist. */
class _LSJ_ConstructorRefusalWorld {
	static Primary := 0
}

_LSJ_RefuseWorldConstructor(*) {
	throw _LSJ_ConstructorRefusalWorld.Primary
}

/** Captures the partial actual join without constructing a derived panel. */
class _LSJ_UnstartedPanelFixture extends _LSJ_Fixture {
	static Probe := 0
	static DerivedDisposals := 0

	__New() {
		_LSJ_UnstartedPanelFixture.Probe := this
		super.__New()
	}

	Dispose() {
		_LSJ_UnstartedPanelFixture.DerivedDisposals += 1
		throw Error("The unstarted derived panel has no disposal authority.")
	}
}

_LSJ_ConstructorOwnerRefusal() {
	global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER
	local PriorWorld, AbortOwner, CleanupOwner, PrimaryRefusal, ReceivedRefusal, OwnedProbe
	PriorWorld := _LSP_World.Prototype.GetOwnPropDesc("__New")
	AbortOwner := _HTTP_CURL_ABORT_TIMER
	CleanupOwner := _HTTP_CURL_CLEANUP_TIMER
	PrimaryRefusal := Error("Controlled refusal before derived panel construction.")
	_LSJ_ConstructorRefusalWorld.Primary := PrimaryRefusal
	_LSJ_UnstartedPanelFixture.Probe := 0
	_LSJ_UnstartedPanelFixture.DerivedDisposals := 0
	_LSP_World.Prototype.DefineProp("__New", {Call: _LSJ_RefuseWorldConstructor})
	try {
		try _LSJ_UnstartedPanelFixture()
		catch as Err
			ReceivedRefusal := Err
		AssertTrue(IsSet(ReceivedRefusal), "The actual join constructor must preserve refusal")
		AssertTrue(ReceivedRefusal == PrimaryRefusal, "Unstarted derived cleanup cannot replace the originating error")
		AssertEqual(0, _LSJ_UnstartedPanelFixture.DerivedDisposals)
		OwnedProbe := _LSJ_UnstartedPanelFixture.Probe
		AssertTrue(OwnedProbe is _LSJ_Fixture)
		AssertFalse(OwnedProbe.HasOwnProp("SavedPanel"), "The subclass has not yet constructed any panel")
		AssertEqual(0, OwnedProbe.World)
		AssertEqual(0, OwnedProbe.Native)
		AssertEqual(0, OwnedProbe.Requests.Length, "No HTTP request is acquired by the constructor control")
		AssertEqual(0, OwnedProbe.Timers.Count)
		AssertFalse(OwnedProbe.Owner.HasPending("lmstudio"))
		AssertTrue(_HTTP_CURL_ABORT_TIMER == AbortOwner)
		AssertTrue(_HTTP_CURL_CLEANUP_TIMER == CleanupOwner)
	} finally {
		; The original defective constructor leaves its base timer owner retained.
		; This control owns that exact partial object and restores it even on RED.
		OwnedProbe := _LSJ_UnstartedPanelFixture.Probe
		try {
			if OwnedProbe is _LSJ_Fixture
				&& (_HTTP_CURL_ABORT_TIMER != AbortOwner || _HTTP_CURL_CLEANUP_TIMER != CleanupOwner)
				_LSJ_Fixture.Prototype.Dispose.Call(OwnedProbe)
		} finally {
			_LSP_World.Prototype.DefineProp("__New", PriorWorld)
			_LSJ_ConstructorRefusalWorld.Primary := 0
			_LSJ_UnstartedPanelFixture.Probe := 0
			_LSJ_UnstartedPanelFixture.DerivedDisposals := 0
		}
	}
}
Test("Local join: failed constructor retires only established base owners", _LSJ_ConstructorOwnerRefusal)
