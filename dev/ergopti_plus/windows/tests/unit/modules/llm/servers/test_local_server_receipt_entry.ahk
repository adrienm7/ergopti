; tests/unit/modules/llm/servers/test_local_server_receipt_entry.ahk

; ==============================================================================
; MODULE: Local Server Receipt Entry Authority
; DESCRIPTION:
; The source-defaults fixture owns cold admission, and a receipt entry
; resolves only from its exact native source: detached maps, stale files,
; mutations and non-verdict port results are refused.
; ==============================================================================

#Requires AutoHotkey v2.0





_LSP_DefaultsFixtureOwnsColdAdmission(InitiallySet) {
	global LLM_Defaults
	HadOuterDefaults := IsSet(LLM_Defaults)
	OuterDefaults := HadOuterDefaults ? LLM_Defaults : false
	ForeignDefaults := Map("unrelated_fixture_sentinel", Map("retained", true))
	World := 0
	try {
		if InitiallySet
			LLM_Defaults := ForeignDefaults
		else
			LLM_Defaults := unset
		World := _LSP_World()
		Receipt := World.Owner.Capture()
		AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt,
			"the actual private source must acquire authority without an earlier defaults test")
		AssertTrue(IsSet(LLM_Defaults) && LLM_Defaults is Map)
		AssertEqual("ollama", LLM_Defaults["llm_backend"])
		World.Restore()
		World := 0
		if InitiallySet {
			AssertTrue(IsSet(LLM_Defaults) && LLM_Defaults == ForeignDefaults,
				"fixture retirement must restore the exact inherited defaults object")
			AssertTrue(LLM_Defaults["unrelated_fixture_sentinel"]["retained"])
		} else
			AssertFalse(IsSet(LLM_Defaults), "fixture retirement must restore an unset boot dependency")
	} finally {
		try {
			if World is _LSP_World
				World.Restore()
		} finally {
			if HadOuterDefaults
				LLM_Defaults := OuterDefaults
			else
				LLM_Defaults := unset
		}
	}
}
Test("Local source defaults fixture: cold admission owns and restores unset defaults (local-source-defaults-fixture)",
	_LSP_DefaultsFixtureOwnsColdAdmission.Bind(false))
Test("Local source defaults fixture: cold admission restores the exact inherited object (local-source-defaults-fixture)",
	_LSP_DefaultsFixtureOwnsColdAdmission.Bind(true))





; =======================================================
; =======================================================
; ======= 2/ Receipt Bound Native Entry Authority =======
; =======================================================
; =======================================================

class _LSER_Observation {
	__New(Fixture) {
		this.Fixture := Fixture
		this.Decodes := 0
		this.Reads := 0
		this.MutateAtRead := 0
		this.ReadCritical := []
		this.LegacyCalls := 0
		this.BoundCalls := 0
		this.BoundValue := 0
		this.BoundError := 0
		this.Origin := 0
		Fixture.World.Owner.Options["decrypt"] := ObjBindMethod(this, "Decrypt")
	}

	Decrypt(Value) {
		this.Decodes += 1
		return LLM_ApiToken_Decrypt(Value)
	}

	LegacyEntry(Id) {
		this.LegacyCalls += 1
		return this.Fixture.World.Owner.Entry(Id)
	}

	BoundVerdict(Id, Source) {
		AssertEqual("lmstudio", Id)
		AssertTrue(Source == this.Origin, "the native resolver must forward the exact originating receipt")
		this.BoundCalls += 1
		if this.BoundError is Error
			throw this.BoundError
		return this.BoundValue
	}

	Read(Path) {
		this.Reads += 1
		this.ReadCritical.Push(A_IsCritical)
		Content := this.Fixture.World.Read(Path)
		if this.MutateAtRead == this.Reads {
			AssertTrue(FSWriteDurable(this.Fixture.World.ApiPath, this.Fixture.World.ApiImage . "`n"))
		}
		return Content
	}
}

_LSER_WithJoin(Callback) {
	Fixture := _LSJ_Fixture()
	try {
		Observed := _LSER_Observation(Fixture)
		Callback.Call(Fixture, Observed)
	} finally Fixture.Dispose()
}

_LSER_RescanDecodesOnce(Fixture, Observed) {
	AssertTrue(Fixture.Native.Rescan(), "the actual catalogue sweep must be admitted")
	AssertEqual(Fixture.Order.Length, Fixture.Requests.Length)
	AssertEqual(2, Observed.Decodes,
		"target checks must reuse the two decoded entries in their originating source receipt")
}
Test("Receipt entry: actual sweep target checks decode the source once (receipt-entry-decode)",
	_LSER_WithJoin.Bind(_LSER_RescanDecodesOnce))

_LSER_ViewDecodesOnlyNewReceipts(Fixture, Observed) {
	Fixture.Prepare()
	AssertEqual(6, Observed.Decodes,
		"sweep, independent source and view capture each decode only their two original entries")
	AssertTrue(Fixture.Native.IsCurrent(Fixture.Receipt, "independent-joined"))
	AssertEqual("independent-joined", Fixture.Native.Result("lmstudio")["models"][1])
	AssertEqual(6, Observed.Decodes, "cache and view revalidation must not reacquire decoded entries")
}
Test("Receipt entry: actual view and cache preserve source decoding ownership (receipt-entry-decode)",
	_LSER_WithJoin.Bind(_LSER_ViewDecodesOnlyNewReceipts))

_LSER_ExpectedRefusal(Callback, ExpectedType, ExpectedMessage) {
	try Callback.Call()
	catch as Refusal {
		AssertEqual(ExpectedType, Type(Refusal))
		AssertEqual(ExpectedMessage, Refusal.Message)
		return
	}
	throw Error("The receipt entry request must refuse before returning an entry or absence.")
}

_LSER_DetachedAndLegacy(Fixture, Observed) {
	Receipt := Fixture.World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
	AssertEqual(2, Observed.Decodes)
	First := Fixture.World.Owner.EntryBound("lmstudio", Receipt)
	Second := Fixture.World.Owner.EntryBound("lmstudio", Receipt)
	AssertEqual("native-active", First["Id"])
	AssertEqual("private-active-sentinel", First["Token"])
	AssertTrue(First != Second, "entry callers own distinct detached maps")
	First["Token"] := "detached-edit"
	First["Model"] := "detached-model"
	AssertEqual("private-active-sentinel", Second["Token"])
	AssertEqual("independent-active", Fixture.World.Owner.EntryBound("lmstudio", Receipt)["Model"])
	AssertEqual(2, Observed.Decodes)
	AssertTrue(Fixture.World.Owner.Entry("lmstudio") is Map)
	AssertEqual(4, Observed.Decodes, "the existing one-argument entry contract still acquires a fresh source")
	Ports := Fixture.World.Owner.Ports()
	AssertTrue(HasMethod(Ports["entry_bound"], "Call"))
}
Test("Receipt entry: detached maps and legacy fresh acquisition remain distinct (receipt-entry-authority)",
	_LSER_WithJoin.Bind(_LSER_DetachedAndLegacy))

_LSER_InvalidReceipt(Fixture, Observed, Kind) {
	Receipt := Fixture.World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
	Resolver := Fixture.World.Owner
	switch Kind {
		case "plain": Receipt := {}
		case "candidate": Receipt := LLM_Menu_ApiPrivateCandidateReceipt()
		case "foreign": Resolver := LLM_Menu_ApiPrivateSourceOwner()
	}
	_LSER_ExpectedRefusal(ObjBindMethod(Resolver, "EntryBound", "lmstudio", Receipt), "Error",
		"The private API source receipt is unavailable.")
	AssertEqual(2, Observed.Decodes, "invalid receipt resolution never reacquires authority")
}
Test("Receipt entry: plain object cannot borrow native authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_InvalidReceipt(Fixture, Observed, "plain")))
Test("Receipt entry: durable candidate is not ordinary source authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_InvalidReceipt(Fixture, Observed, "candidate")))
Test("Receipt entry: another source owner cannot resolve the receipt (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_InvalidReceipt(Fixture, Observed, "foreign")))

_LSER_UnknownProvider(Fixture, Observed) {
	Receipt := Fixture.World.Owner.Capture()
	_LSER_ExpectedRefusal(ObjBindMethod(Fixture.World.Owner, "EntryBound", "independent-unknown", Receipt),
		"ValueError", "The requested local server is outside the native catalogue.")
	AssertEqual(2, Observed.Decodes)
}
Test("Receipt entry: unknown provider is a typed catalogue refusal (receipt-entry-authority)",
	_LSER_WithJoin.Bind(_LSER_UnknownProvider))

_LSER_Stale(Fixture, Observed, Kind) {
	global _LLM_Menu, Features, LLM_Defaults
	Receipt := Fixture.World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
	switch Kind {
		case "api": AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage . "`n"))
		case "config": AssertTrue(FSWriteDurable(Fixture.World.ConfigPath, Fixture.World.ConfigImage . "`n"))
		case "token": _LLM_Menu["api_entries"][2]["Token"] := "independent-changed-token"
		case "order": _LLM_Menu["api_entries"] := [_LLM_Menu["api_entries"][2], _LLM_Menu["api_entries"][1]]
		case "active": _LLM_Menu["api_entry_id"] := "native-first"
		case "defaults": LLM_Defaults := LLM_Defaults.Clone()
		case "generation":
			Attempt := LLM_Menu_ApiPrivateBeginShutdown()
			AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
	}
	_LSER_ExpectedRefusal(ObjBindMethod(Fixture.World.Owner, "EntryBound", "lmstudio", Receipt), "Error",
		"The private API source authority changed during resolution.")
	AssertEqual(2, Observed.Decodes, "stale authority never mints fresh replacement authority")
}
Test("Receipt entry: changed API file refuses original authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "api")))
Test("Receipt entry: changed config file refuses original authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "config")))
Test("Receipt entry: changed native token refuses original authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "token")))
Test("Receipt entry: reordered native entries refuse original authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "order")))
Test("Receipt entry: changed active entry refuses original authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "active")))
Test("Receipt entry: replaced defaults object refuses original authority (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "defaults")))
Test("Receipt entry: shutdown veto cannot revive an old epoch (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_Stale(Fixture, Observed, "generation")))

_LSER_ReadMutation(Fixture, Observed, FinalCheck) {
	Receipt := Fixture.World.Owner.Capture()
	Observed.Reads := 0
	Observed.MutateAtRead := FinalCheck ? 5 : 1
	Fixture.World.Port["read"] := ObjBindMethod(Observed, "Read")
	_LSER_ExpectedRefusal(ObjBindMethod(Fixture.World.Owner, "EntryBound", "lmstudio", Receipt), "Error",
		"The private API source authority changed during resolution.")
	AssertTrue(Observed.Reads >= Observed.MutateAtRead, "the actual snapshot port must reach the mutation")
	AssertEqual(2, Observed.Decodes)
}
Test("Receipt entry: mutation during first image check refuses resolution (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_ReadMutation(Fixture, Observed, false)))
Test("Receipt entry: mutation during final image check refuses detached result (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_ReadMutation(Fixture, Observed, true)))

_LSER_CriticalRestoration(Fixture, Observed) {
	Receipt := Fixture.World.Owner.Capture()
	Observed.Reads := 0
	Fixture.World.Port["read"] := ObjBindMethod(Observed, "Read")
	Prior := Critical(17)
	try {
		AssertTrue(Fixture.World.Owner.EntryBound("lmstudio", Receipt) is Map)
		AssertEqual(17, A_IsCritical)
		Observed.MutateAtRead := Observed.Reads + 1
		_LSER_ExpectedRefusal(ObjBindMethod(Fixture.World.Owner, "EntryBound", "lmstudio", Receipt), "Error",
			"The private API source authority changed during resolution.")
		AssertEqual(17, A_IsCritical)
		AssertTrue(Observed.ReadCritical.Length > 0)
		for Value in Observed.ReadCritical
			AssertEqual(0, Value, "receipt-bound file queries must run outside inherited Critical")
	} finally Critical(Prior)
}
Test("Receipt entry: inherited Critical restores after success and refusal (receipt-entry-authority)",
	_LSER_WithJoin.Bind(_LSER_CriticalRestoration))

_LSER_AbsenceAndPending(Fixture, Observed) {
	global _LLM_Menu
	_LLM_Menu["api_entries"] := []
	_LLM_Menu["api_entry_id"] := ""
	AssertTrue(FSWriteDurable(Fixture.World.ApiPath, "[]"))
	AssertTrue(FSWriteDurable(Fixture.World.ConfigPath,
		_LSP_CurrentConfigSource('[llm]`napi_entry_id = ""`n[llm.models]`nselected = "ollama"`n')))
	Receipt := Fixture.World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
	AssertFalse(Fixture.World.Owner.EntryBound("lmstudio", Receipt))
	Fixture.Native.Pending["lmstudio"] := Map("base_url", "http://127.0.0.1:1239/v1", "token", "pending-only")
	Target := Fixture.Native._Target("lmstudio", Receipt)
	AssertEqual("", Target["entry_id"])
	AssertEqual("pending-only", Target["token"])
	AssertEqual("http://127.0.0.1:1239/v1", Target["base_url"])
	Fixture.Native.Pending["lmstudio"]["token"] := "changed-pending"
	AssertFalse(Fixture.Native._SameTarget(Target, Fixture.Native._Target("lmstudio", Receipt)))
	AssertTrue(FSWriteDurable(Fixture.World.ApiPath, "[]`n"))
	_LSER_ExpectedRefusal(ObjBindMethod(Fixture.Native, "_Target", "lmstudio", Receipt), "Error",
		"The private API source authority changed during resolution.")
}
Test("Receipt entry: proved absence preserves pending target drift but stale is not absence (receipt-entry-authority)",
	_LSER_WithJoin.Bind(_LSER_AbsenceAndPending))

_LSER_NativePortBoundary(Fixture, Observed, Kind) {
	Receipt := Fixture.World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
	Observed.Origin := Receipt
	Fixture.Native.Options["entry"] := ObjBindMethod(Observed, "LegacyEntry")
	Fixture.Native.Options["entry_bound"] := ObjBindMethod(Observed, "BoundVerdict")
	if Kind == "missing" {
		_LSER_ExpectedRefusal(ObjBindMethod(Fixture.Native, "Target", "lmstudio"), "TypeError",
			"Receipt-bound local target resolution requires an originating source.")
		AssertEqual(0, Observed.BoundCalls)
	} else if Kind == "refusal" {
		Expected := Error("Independent receipt-bound port refusal.")
		Observed.BoundError := Expected
		Refused := false
		try Fixture.Native.Target("lmstudio", Receipt)
		catch as PortFailure {
			AssertTrue(PortFailure == Expected, "the supplied port's exact refusal must propagate")
			Refused := true
		}
		AssertTrue(Refused)
		AssertEqual(1, Observed.BoundCalls)
	} else {
		switch Kind {
			case "string": Observed.BoundValue := "0"
			case "float": Observed.BoundValue := 0.0
			case "true": Observed.BoundValue := true
			case "array": Observed.BoundValue := []
			case "object": Observed.BoundValue := {}
		}
		_LSER_ExpectedRefusal(ObjBindMethod(Fixture.Native, "Target", "lmstudio", Receipt), "TypeError",
			"Receipt-bound local entry verdict must be a Map or false.")
		AssertEqual(1, Observed.BoundCalls)
	}
	AssertEqual(0, Observed.LegacyCalls, "missing, refused or invalid bound authority never invokes legacy entry")
	AssertEqual(2, Observed.Decodes)
}
Test("Receipt entry: missing origin cannot invoke the legacy entry port (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "missing")))
Test("Receipt entry: supplied port refusal propagates without legacy acquisition (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "refusal")))
Test("Receipt entry: string zero is not verified absence (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "string")))
Test("Receipt entry: float zero is not verified absence (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "float")))
Test("Receipt entry: true is not an entry verdict (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "true")))
Test("Receipt entry: array is not an entry verdict (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "array")))
Test("Receipt entry: object is not an entry verdict (receipt-entry-authority)",
	_LSER_WithJoin.Bind((Fixture, Observed) => _LSER_NativePortBoundary(Fixture, Observed, "object")))

_LSER_InvalidDeclaredPort(Fixture, Observed) {
	Options := Fixture.Native.Options.Clone()
	Options["entry_bound"] := "not-callable"
	_LSER_ExpectedRefusal(() => LocalServersOwner(Options), "TypeError", "Local server optional port must be callable.")
	AssertEqual(0, Observed.Decodes)
}
Test("Receipt entry: invalid declared port is rejected at construction (receipt-entry-authority)",
	_LSER_WithJoin.Bind(_LSER_InvalidDeclaredPort))

_LSER_LegacyPortContract(Fixture, Observed) {
	Fixture.Native.Options.Delete("entry_bound")
	Fixture.Native.Options["entry"] := ObjBindMethod(Observed, "LegacyEntry")
	Target := Fixture.Native.Target("lmstudio")
	AssertEqual("native-active", Target["entry_id"])
	AssertEqual(1, Observed.LegacyCalls)
	AssertEqual(2, Observed.Decodes, "an explicitly legacy owner preserves fresh one-argument acquisition")
}
Test("Receipt entry: absent bound port preserves the legacy one-argument contract (receipt-entry-authority)",
	_LSER_WithJoin.Bind(_LSER_LegacyPortContract))
