; tests/unit/test_local_server_private_publication.ahk

; ==============================================================================
; MODULE: Private Local Server Publication Regression Tests
; DESCRIPTION:
; Exercises actual classified files, DPAPI and the joint transition owner with
; independent source/credential sentinels. Native mutation seams do not replace
; source parsing, expected-image checks, durable compensation or RAM publication.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Native disk fixture; registration follows the existing LLM transaction fixture. */
class _LSP_World {
	__New(Options := unset) {
		global _LLM_Menu_Loaded, _LifecycleLatestTransition, _LifecycleShutdownReason
		global _LLM_Menu, Features, ConfigurationFile, LLM_API_PROVIDERS, LLM_LOCAL_API_SERVERS
		global _ConfigTransitionRetainedBarrier
		this.Previous := _LMT_InstallApiFixture()
		this.Loaded := _LLM_Menu_Loaded
		this.Transition := _LifecycleLatestTransition
		this.HadShutdown := IsSet(_LifecycleShutdownReason)
		this.Shutdown := this.HadShutdown ? _LifecycleShutdownReason : ""
		this.PriorRetained := _ConfigTransitionRetainedBarrier
		_LLM_Menu_Loaded := true
		_LifecycleLatestTransition := 0
		_LifecycleShutdownReason := ""
		this.ConfigPath := ConfigurationFile
		this.ApiPath := _LLM_Menu_ApiEntriesPath()
		this.ApplyCalls := 0
		this.AdmissionCalls := 0
		this.Mutation := ""
		this.Mutated := false
		this.ArmRead := false
		this.Replacement := ""
		this.ModelCurrent := true
		this.CandidateSeen := false
		this.CommittedCalls := 0
		this.ClaimCalls := 0
		this.ClaimCritical := false
		this.OldSourceAdmittedAfterDurability := true
		this.FailApiMove := false
		this.MoveRefused := false
		this.OwnedBundle := 0
		this.CleanupArmed := false
		this.CleanupRefused := false
		this.WrongCandidate := true
		try {
			AssertTrue(LLM_API_PROVIDERS.Has("lmstudio"), "the actual native local-provider catalogue must be present")
			AssertTrue(LLM_LOCAL_API_SERVERS.Has("lmstudio"))
			this.ConfigImage := '[llm]`napi_entry_id = "native-active"`n[llm.models]`nselected = "ollama"`n'
			this.ApiImage := '[{"Id":"native-first","Name":"Original first","Provider":"lmstudio","BaseUrl":"http://127.0.0.1:1234/v1","Token":"private-first-sentinel","Model":"independent-first"},{"Id":"native-active","Name":"Original active","Provider":"lmstudio","BaseUrl":"http://127.0.0.1:1235/v1","Token":"private-active-sentinel","Model":"independent-active"}]'
			AssertTrue(FSWriteDurable(this.ConfigPath, this.ConfigImage))
			AssertTrue(FSWriteDurable(this.ApiPath, this.ApiImage))
			_LLM_Menu["api_entries"] := [
				Map("Id", "native-first", "Name", "Original first", "Provider", "lmstudio",
					"BaseUrl", "http://127.0.0.1:1234/v1", "Token", "private-first-sentinel", "Model", "independent-first"),
				Map("Id", "native-active", "Name", "Original active", "Provider", "lmstudio",
					"BaseUrl", "http://127.0.0.1:1235/v1", "Token", "private-active-sentinel", "Model", "independent-active")]
			_LLM_Menu["api_entry_id"] := "native-active"
			this.OldMenu := _LLM_Menu
			this.OldFeatures := Features
			this.Port := ConfigTransitionProductionPort()
			this.Port["read"] := ObjBindMethod(this, "Read")
			this.Port["move_replace"] := ObjBindMethod(this, "MoveReplace")
			this.Port["delete"] := ObjBindMethod(this, "Delete")
			Owned := IsSet(Options) ? Options.Clone() : Map()
			Owned["port"] := this.Port
			Owned["acquire"] := _LMT_Acquire
			Owned["settle"] := _LMT_Settle
			Owned["collect"] := ObjBindMethod(this, "Collect")
			Owned["build_config"] := ObjBindMethod(this, "Build")
			Owned["serialize"] := ObjBindMethod(this, "Serialize")
			Owned["apply"] := ObjBindMethod(this, "ApplyCommitted")
			Owned["notify"] := _LMT_Notify
			Owned["pause"] := ObjBindMethod(this, "Pause")
			this.Owner := LLM_Menu_ApiPrivateSourceOwner(Owned)
			_LSP_NativeFacts(this, "fixture_acquired")
		} catch as Err {
			this.Restore()
			throw Err
		}
	}

	Restore() {
		global _LLM_Menu_Loaded, _LifecycleLatestTransition, _LifecycleShutdownReason
		global _ConfigTransitionRetainedBarrier, _PathsFile
		; Only this fixture's exclusively created files and exact bundle may be repaired
		; after the assertions. Real production code never gains this cleanup authority.
		if (this.OwnedBundle is Object) && _ConfigWriteLeaseState().terminal == this.OwnedBundle {
			try {
				if this.HasOwnProp("ConfigCandidate") {
					FSWriteDurable(this.ConfigPath, this.ConfigCandidate)
					FSWriteDurable(this.ApiPath, this.ApiCandidate)
				}
				ConfigTransitionRollbackOwned(_PathsFile, this.OwnedBundle, ConfigTransitionProductionPort())
			} finally {
				_ConfigWriteTerminalRelease(this.OwnedBundle)
				if _ConfigTransitionRetainedBarrier == this.OwnedBundle
					_ConfigTransitionRetainedBarrier := this.PriorRetained
			}
		}
		_LLM_Menu_Loaded := this.Loaded
		_LifecycleLatestTransition := this.Transition
		if this.HadShutdown
			_LifecycleShutdownReason := this.Shutdown
		else
			_LifecycleShutdownReason := unset
		_LMT_RestoreApiFixture(this.Previous)
		if this.HasOwnProp("Receipt")
			this.Receipt := 0
		if this.HasOwnProp("OtherReceipt")
			this.OtherReceipt := 0
		if this.HasOwnProp("Owner") {
			this.Owner.Options := Map()
			this.Owner.Port := ConfigTransitionProductionPort()
			this.Owner := 0
		}
		if this.HasOwnProp("Port")
			this.Port := Map()
	}

	Read(Path) {
		Content := FSReadUtf8Exact(Path)
		if this.Mutation == "claim_model" && this.CommittedCalls >= 2 && !this.Mutated {
			this.Mutated := true
			this.ModelCurrent := false
		}
		if this.ArmRead && !this.Mutated && Path == this.ApiPath {
			this.Mutated := true
			if !FSWriteDurable(this.ApiPath, this.Replacement)
				throw Error("The owned test source replacement was refused.")
		}
		return Content
	}

	MoveReplace(Source, Destination) {
		if this.FailApiMove && !this.MoveRefused && Destination == this.ApiPath {
			this.MoveRefused := true
			return false
		}
		return FSAtomicMoveReplace(Source, Destination)
	}

	Delete(Path) {
		if this.CleanupArmed && !this.CleanupRefused {
			this.CleanupRefused := true
			return false
		}
		return FSDeleteStrict(Path)
	}

	Collect(CandidateFeatures, CandidateMenu) {
		this.ChangeAt("collect")
		return [{ Section: "llm.models", Key: "selected", Value: CandidateMenu["backend"] },
			{ Section: "llm", Key: "api_entry_id", Value: CandidateMenu["api_entry_id"] }]
	}

	Build(Path, Updates) {
		Built := TOML_BuildUpdatedContent(Path, Updates)
		this.ChangeAt("build")
		return Built
	}

	Serialize(MenuState) {
		Content := _LLM_Menu_SerializeApiEntries(MenuState)
		this.ChangeAt("serialize")
		if this.Mutation == "model"
			this.ModelCurrent := false
		if this.Mutation == "final_read"
			this.ArmRead := true
		return Content
	}

	ChangeAt(Phase) {
		if this.Mutation == Phase && !this.Mutated {
			this.Mutated := true
			if !FSWriteDurable(this.ApiPath, this.Replacement)
				throw Error("The owned test source replacement was refused.")
		}
	}

	Pause(Point) {
		global _LLM_Menu, _PathsFile
		if Point != "phase:committed_new"
			return
		this.OwnedBundle := _ConfigWriteLeaseState().terminal
		this.ConfigCandidate := FSReadUtf8Exact(this.ConfigPath)
		this.ApiCandidate := FSReadUtf8Exact(this.ApiPath)
		if this.Mutation == "committed_model"
			this.ModelCurrent := false
		if this.Mutation == "missing_wal" {
			this.ModelCurrent := false
			this.Mutated := FSDeleteStrict(ConfigTransitionWalPath(_PathsFile))
		}
		if this.Mutation == "committed_owner"
			_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
		if this.Mutation == "committed_external" {
			this.Mutated := true
			if !FSWriteDurable(this.ApiPath, this.Replacement)
				throw Error("The owned durable-stage source replacement was refused.")
		}
		if this.Mutation == "cleanup"
			this.CleanupArmed := true
		if this.Mutation == "wrong_source"
			this.WrongCandidate := this.Owner.CaptureCandidate(this.OtherReceipt,
				this.OwnedBundle, this.ConfigCandidate, this.ApiCandidate)
	}

	DecryptAndReplace(Token) {
		Decoded := LLM_ApiToken_Decrypt(Token)
		if !this.Mutated {
			this.Mutated := true
			if !FSWriteDurable(this.ApiPath, this.Replacement)
				throw Error("The owned decryption-boundary source replacement was refused.")
		}
		return Decoded
	}

	ApplyCommitted(Candidate) {
		this.ApplyCalls += 1
		return this.Mutation != "application"
	}

	Admission(Phase := "", Capability := 0) {
		this.AdmissionCalls += 1
		if Phase == "claim" {
			if this.Mutation == "claim_shutdown" || this.Mutation == "claim_shutdown_veto" {
				this.Mutated := true
				this.ShutdownAttempt := LLM_Menu_ApiPrivateBeginShutdown()
				if this.Mutation == "claim_shutdown_veto"
					LLM_Menu_ApiPrivateRefuseShutdown(this.ShutdownAttempt)
			}
			if this.Mutation == "claim_reload"
				_LLM_Menu_LoadApiEntries()
			this.ClaimCalls += 1
			this.ClaimCritical := A_IsCritical != 0
			return this.ModelCurrent && this.ClaimCritical
		}
		if Phase == "committed" {
			this.CommittedCalls += 1
			this.CandidateSeen := true
			this.OldSourceAdmittedAfterDurability := this.Owner.Current(this.Receipt)
			return this.ModelCurrent && this.Owner.CandidateCurrent(Capability)
		}
		return this.ModelCurrent && this.Owner.Current(this.Receipt)
	}

	Capture() {
		this.Receipt := this.Owner.Capture()
		AssertTrue(this.Receipt is LLM_Menu_ApiPrivateSourceReceipt, "the independent fixture must qualify actual disk and RAM")
		return this.Receipt
	}

	Fields() {
		return Map("base_url", "http://127.0.0.1:1236/v1", "token", "private-next-sentinel", "model", "independent-next")
	}

	Apply(SelectModel := true) {
		Fields := this.Fields()
		if !SelectModel
			Fields["model"] := "independent-active"
		return this.Owner.Apply("lmstudio", Fields, this.Receipt, ObjBindMethod(this, "Admission"), SelectModel)
	}

	AssertUnchanged() {
		global _LLM_Menu, Features
		AssertTrue(_LLM_Menu == this.OldMenu, "refusal retains the exact native menu owner")
		AssertTrue(Features == this.OldFeatures, "refusal retains the exact native feature owner")
		AssertEqual(this.ConfigImage, FSReadUtf8Exact(this.ConfigPath))
		AssertEqual(this.ApiImage, FSReadUtf8Exact(this.ApiPath))
		AssertEqual(0, this.ApplyCalls)
	}
}

_LSP_WithWorld(Body) {
	World := _LSP_World()
	try Body.Call(World)
	finally World.Restore()
}

_LSP_OpaqueAndRepeat(World) {
	global _LLM_Menu
	Receipt := World.Capture()
	Count := 0
	for Key, Value in Receipt.OwnProps()
		Count += 1
	AssertEqual(0, Count, "opaque shared receipts expose neither source bytes nor credentials")
	Other := World.Owner.Capture()
	AssertTrue(World.Owner.Current(Receipt))
	AssertTrue(World.Owner.Current(Other))
	OriginalEntries := _LLM_Menu["api_entries"]
	AssertTrue(_LLM_Menu_LoadApiEntries())
	AssertTrue(_LLM_Menu["api_entries"] != OriginalEntries)
	AssertTrue(World.Owner.Current(Receipt), "an identical supported load must preserve retained source provenance")
	Entry := World.Owner.Entry("lmstudio")
	AssertEqual("native-active", Entry["Id"])
	Entry["Token"] := "detached-edit-sentinel"
	AssertEqual("private-active-sentinel", _LLM_Menu["api_entries"][2]["Token"])
}
Test("Local server source: opaque repeated receipts and semantic reload (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_OpaqueAndRepeat))

_LSP_SixFields(World) {
	global _LLM_Menu
	for Field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"] {
		Before := _LLM_Menu["api_entries"][2][Field]
		_LLM_Menu["api_entries"][2][Field] := "different-field-sentinel"
		AssertFalse(World.Owner.Capture(), "each ordered native field is part of source authority")
		_LLM_Menu["api_entries"][2][Field] := Before
	}
	Entry := _LLM_Menu["api_entries"].RemoveAt(1)
	_LLM_Menu["api_entries"].Push(Entry)
	AssertFalse(World.Owner.Capture(), "matching values in a different API order must not authorize stale RAM")
}
Test("Local server source: every field and ordering qualify disk against RAM (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_SixFields))

_LSP_ExternalReplacement(World) {
	World.Capture()
	Replacement := StrReplace(World.ApiImage, "independent-active", "external-model-sentinel")
	AssertTrue(FSWriteDurable(World.ApiPath, Replacement))
	AssertFalse(World.Owner.Current(World.Receipt))
	AssertFalse(World.Owner.Capture(), "a fresh hash beside stale RAM cannot mint authority")
	AssertFalse(World.Apply())
	AssertEqual(Replacement, FSReadUtf8Exact(World.ApiPath))
	AssertEqual(World.ConfigImage, FSReadUtf8Exact(World.ConfigPath))
}
Test("Local server source: supported external replacement cannot qualify stale RAM (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ExternalReplacement))

_LSP_BackendAuthority(World) {
	World.Capture()
	Image := StrReplace(World.ConfigImage, 'selected = "ollama"', 'selected = "api"')
	AssertTrue(FSWriteDurable(World.ConfigPath, Image))
	AssertFalse(World.Owner.Current(World.Receipt))
	AssertFalse(World.Owner.Capture(), "canonical feature backend must agree with the loaded native owner")
	AssertEqual(Image, FSReadUtf8Exact(World.ConfigPath))
}
Test("Local server source: canonical backend projection rejects external stale authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_BackendAuthority))

_LSP_OwnerReplacement(World) {
	global _LLM_Menu
	World.Capture()
	_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
	AssertFalse(World.Owner.Current(World.Receipt), "equal values under a new committed native owner revoke old receipts")
	Fresh := World.Owner.Capture()
	AssertTrue(Fresh is LLM_Menu_ApiPrivateSourceReceipt)
}
Test("Local server source: native owner replacement revokes prior receipts (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_OwnerReplacement))

_LSP_AbsentAndUnreadable(World) {
	global _LLM_Menu
	AssertTrue(FSDeleteStrict(World.ConfigPath))
	AssertTrue(FSDeleteStrict(World.ApiPath))
	_LLM_Menu["api_entries"] := []
	_LLM_Menu["api_entry_id"] := ""
	Receipt := World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt, "classified absence is honest empty native authority")
	AssertFalse(World.Owner.Entry("lmstudio"))
	Unreadable := ConfigTransitionProductionPort()
	Unreadable["exists"] := (*) => "unknown"
	Owner := LLM_Menu_ApiPrivateSourceOwner(Map("port", Unreadable))
	AssertFalse(Owner.Capture(), "existence refusal must not be interpreted as absent")
}
Test("Local server source: absence remains distinct from unreadable existence (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_AbsentAndUnreadable))

_LSP_Unsupported(World) {
	for Image in [StrReplace(World.ApiImage, '"Model":"independent-active"', '"Model":"independent-active","Future":true'),
		'{"entries":[]}', '[{"Id":"partial"}]',
		StrReplace(World.ApiImage, '"Token":"private-active-sentinel"', '"Token":"dpapi:AA=="')] {
		AssertTrue(FSWriteDurable(World.ApiPath, Image))
		AssertFalse(World.Owner.Capture())
		AssertEqual(Image, FSReadUtf8Exact(World.ApiPath), "unsupported or malformed private sources remain byte-for-byte untouched")
	}
}
Test("Local server source: malformed future and undecodable sources remain untouched (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_Unsupported))

_LSP_Dpapi(World) {
	global _LLM_Menu
	Encrypted := LLM_ApiToken_Encrypt("private-active-sentinel")
	AssertTrue(Encrypted is String)
	AssertTrue(LLM_ApiToken_IsValidEnvelope(Encrypted))
	Image := StrReplace(World.ApiImage, '"Token":"private-active-sentinel"', '"Token":"' . Encrypted . '"')
	AssertTrue(FSWriteDurable(World.ApiPath, Image))
	Receipt := World.Capture()
	AssertTrue(World.Owner.Current(Receipt))
	AssertTrue(_LLM_Menu_LoadApiEntries())
	AssertEqual("private-active-sentinel", _LLM_Menu["api_entries"][2]["Token"])
	AssertTrue(World.Owner.Current(Receipt), "actual DPAPI decode agrees with ordered native RAM after reload")
}
Test("Local server source: actual DPAPI receipt and restart-style reload preserve authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_Dpapi))

_LSP_ForeignLease(World) {
	World.Capture()
	Token := _ConfigWriteLeaseTryAcquire(World.ConfigPath)
	AssertTrue(Token is Object)
	try {
		AssertFalse(World.Owner.Capture())
		AssertFalse(World.Owner.Current(World.Receipt))
	} finally _ConfigWriteLeaseRelease(Token)
	Bundle := _ConfigWriteTerminalTryAcquire([World.ConfigPath, World.ApiPath])
	AssertTrue(Bundle is Object)
	try AssertFalse(World.Owner.Capture(), "foreign terminal admission cannot be borrowed by a retained view")
	finally _ConfigWriteTerminalRelease(Bundle)
}
Test("Local server source: foreign targeted and terminal barriers refuse ownership (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ForeignLease))

_LSP_RefusedWriter(World) {
	World.Capture()
	World.FailApiMove := true
	AssertFalse(World.Apply())
	AssertTrue(World.MoveRefused, "the actual joint writer must reach and refuse its second durable target")
	World.AssertUnchanged()
	AssertFalse(_ConfigWriteTerminalIsActive(), "verified compensation releases terminal admission")
}
Test("Local server publication: second target refusal preserves both files and RAM (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_RefusedWriter))

_LSP_MutationBoundary(World, Phase) {
	World.Capture()
	World.Mutation := Phase
	World.Replacement := StrReplace(World.ApiImage, "independent-active", "external-after-build-sentinel")
	AssertFalse(World.Apply())
	AssertTrue(World.Mutated)
	AssertEqual(World.Replacement, FSReadUtf8Exact(World.ApiPath), "a refused retained view must not overwrite the external source")
	AssertEqual(World.ConfigImage, FSReadUtf8Exact(World.ConfigPath))
	global _LLM_Menu, Features
	AssertTrue(_LLM_Menu == World.OldMenu)
	AssertTrue(Features == World.OldFeatures)
	AssertEqual(0, World.ApplyCalls)
	AssertFalse(_ConfigWriteTerminalIsActive())
}
Test("Local server publication: original images survive collect mutation (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_MutationBoundary(World, "collect")))
Test("Local server publication: original images survive build mutation (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_MutationBoundary(World, "build")))
Test("Local server publication: original images survive serialize mutation (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_MutationBoundary(World, "serialize")))
Test("Local server publication: original images survive final_read mutation (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_MutationBoundary(World, "final_read")))

_LSP_Selected(World) {
	global _LLM_Menu, Features
	World.Capture()
	Saved := World.Apply()
	AssertTrue(Saved is Map)
	AssertTrue(Saved["saved"])
	AssertTrue(Saved["selected"])
	AssertTrue(World.CandidateSeen, "durable-new publication uses a distinct final admission contract")
	AssertEqual(1, World.ClaimCalls, "publication must own exactly one final retained model claim")
	AssertTrue(World.ClaimCritical)
	AssertFalse(World.OldSourceAdmittedAfterDurability, "general old source receipts never gain new-file authority")
	AssertEqual("native-active", Saved["entry_id"])
	AssertEqual("api", _LLM_Menu["backend"])
	AssertEqual("native-active", _LLM_Menu["api_entry_id"])
	AssertEqual("api", Features["llm"]["models"]["selected"])
	AssertEqual("Original active", _LLM_Menu["api_entries"][2]["Name"])
	AssertEqual("private-next-sentinel", _LLM_Menu["api_entries"][2]["Token"])
	AssertEqual("independent-next", _LLM_Menu["api_entries"][2]["Model"])
	Document := TOML_ParseDocument(FSReadUtf8Exact(World.ConfigPath))
	AssertEqual("api", Document["llm"]["models"]["selected"])
	AssertEqual("native-active", Document["llm"]["api_entry_id"])
	Persisted := JsonParse(FSReadUtf8Exact(World.ApiPath))
	AssertEqual(2, Persisted.Length)
	AssertTrue(LLM_ApiToken_IsValidEnvelope(Persisted[2]["Token"]))
	AssertEqual("private-next-sentinel", LLM_ApiToken_Decrypt(Persisted[2]["Token"]))
	AssertTrue(World.AdmissionCalls > 1, "the real originating model view must be checked across build boundaries")
	AssertEqual(1, World.ApplyCalls)
	AssertFalse(World.Owner.Current(World.Receipt))
	AssertTrue(World.Owner.Capture() is LLM_Menu_ApiPrivateSourceReceipt)
}
Test("Local server publication: model entry and API backend share one durable ACK (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_Selected))

_LSP_AddressWithoutSelection(World) {
	global _LLM_Menu
	World.Capture()
	Saved := World.Apply(false)
	AssertTrue(Saved is Map)
	AssertTrue(Saved["saved"])
	AssertFalse(Saved["selected"])
	AssertEqual("ollama", _LLM_Menu["backend"])
	AssertEqual("native-active", _LLM_Menu["api_entry_id"])
	AssertEqual("Original active", _LLM_Menu["api_entries"][2]["Name"])
}
Test("Local server publication: configured field update preserves backend selection (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_AddressWithoutSelection))

_LSP_ModelAdmission(World) {
	World.Capture()
	World.Mutation := "model"
	AssertFalse(World.Apply())
	World.AssertUnchanged()
	AssertTrue(World.Owner.Current(World.Receipt), "model/view revocation does not fabricate a source change")
}
Test("Local server publication: model view revocation refuses exact private persistence (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ModelAdmission))

_LSP_SecretError(World) {
	Owner := LLM_Menu_ApiPrivateSourceOwner(Map("decrypt", (*) => _LSP_RaisePrivateError()))
	AssertFalse(Owner.Capture())
	try Owner.Entry("lmstudio")
	catch as Err {
		AssertFalse(InStr(Err.Message, "private-error-sentinel"), "native private decode errors never leave their owner")
		return
	}
	throw Error("Unavailable private authority must not be returned as honest absence.")
}

_LSP_RaisePrivateError() {
	throw Error("private-error-sentinel")
}
Test("Local server source: private native decode messages do not escape authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_SecretError))

_LSP_DecryptBoundary(World) {
	World.Replacement := StrReplace(World.ApiImage, "independent-active", "external-decrypt-sentinel")
	Owner := LLM_Menu_ApiPrivateSourceOwner(Map("decrypt", ObjBindMethod(World, "DecryptAndReplace")))
	AssertFalse(Owner.Capture())
	AssertTrue(World.Mutated)
	AssertEqual(World.Replacement, FSReadUtf8Exact(World.ApiPath))
	AssertEqual(World.ConfigImage, FSReadUtf8Exact(World.ConfigPath))
}
Test("Local server source: decryption-boundary replacement cannot mint mixed authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_DecryptBoundary))

_LSP_PostDurableViewRefusal(World) {
	World.Capture()
	World.Mutation := "committed_model"
	AssertFalse(World.Apply())
	AssertTrue(World.CandidateSeen, "the independent model view must refuse the actual durable-new stage")
	AssertFalse(World.OldSourceAdmittedAfterDurability)
	World.AssertUnchanged()
	AssertFalse(_ConfigWriteTerminalIsActive(), "conditional rollback of known own-new images releases admission")
}
Test("Local server publication: post-durable model view refusal rolls back without broadening old sources (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_PostDurableViewRefusal))

_LSP_Creation(World) {
	global _LLM_Menu
	for Entry in _LLM_Menu["api_entries"]
		Entry["Provider"] := "openai"
	World.ApiImage := StrReplace(World.ApiImage, '"Provider":"lmstudio"', '"Provider":"openai"')
	AssertTrue(FSWriteDurable(World.ApiPath, World.ApiImage))
	World.Capture()
	AssertFalse(World.Owner.Entry("lmstudio"))
	Saved := World.Apply()
	AssertTrue(Saved is Map)
	AssertTrue(Saved["saved"])
	AssertTrue(Saved["selected"])
	AssertEqual(3, _LLM_Menu["api_entries"].Length)
	Entry := _LLM_Menu["api_entries"][3]
	AssertEqual("lmstudio", Entry["Provider"])
	AssertEqual("lmstudio/independent-next", Entry["Name"])
	AssertEqual("independent-next", Entry["Model"])
	AssertEqual(Saved["entry_id"], Entry["Id"])
	AssertEqual(Entry["Id"], _LLM_Menu["api_entry_id"])
	AssertEqual("api", _LLM_Menu["backend"])
}
Test("Local server publication: proved absence creates through existing ID and joint selection owner (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_Creation))

_LSP_NoImplicitModelChange(World) {
	World.Capture()
	AssertFalse(World.Owner.Apply("lmstudio", World.Fields(), World.Receipt, ObjBindMethod(World, "Admission"), false),
		"address/key updates cannot silently replace the selected model")
	World.AssertUnchanged()
}
Test("Local server publication: an implicit model replacement cannot borrow field-edit authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_NoImplicitModelChange))


_LSP_ApplicationDebt(World) {
	global _LLM_Menu, _PathsFile
	World.Capture()
	World.Mutation := "application"
	AssertFalse(World.Apply(), "durable files do not fabricate native application success")
	_LSP_NativeFacts(World, "application_debt")
	AssertEqual(1, World.ApplyCalls)
	AssertTrue(_LLM_Menu != World.OldMenu, "durable acknowledged candidate is already published")
	AssertTrue(_ConfigWriteTerminalIsActive())
	AssertTrue(ConfigTransitionRetainedBarrier() == World.OwnedBundle)
	AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "ready"),
		"application refusal leaves a discoverable native WAL")
	AssertFalse(World.Owner.Capture(), "retained debt cannot qualify a new discovery view")
	AssertFalse(World.Owner.Current(World.Receipt))
}
Test("Local server publication: native application refusal retains exact WAL and barrier (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ApplicationDebt))

_LSP_CleanupDebt(World) {
	global _LLM_Menu, _PathsFile
	World.Capture()
	World.Mutation := "cleanup"
	AssertFalse(World.Apply(), "a cleanup refusal cannot become saved success")
	_LSP_NativeFacts(World, "cleanup_debt")
	AssertTrue(World.CleanupRefused, "the real journal cleanup must reach the native delete seam")
	AssertEqual(1, World.ApplyCalls)
	AssertTrue(_LLM_Menu != World.OldMenu)
	AssertTrue(ConfigTransitionRetainedBarrier() == World.OwnedBundle)
	AssertTrue(_ConfigWriteTerminalIsActive())
	AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "ready"))
	AssertFalse(World.Owner.Capture())
}
Test("Local server publication: native cleanup refusal keeps durable debt honest (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_CleanupDebt))

_LSP_PostDurableForeignImage(World) {
	global _LLM_Menu, Features, _PathsFile
	World.Capture()
	World.Mutation := "committed_external"
	World.Replacement := StrReplace(World.ApiImage, "independent-active", "foreign-durable-sentinel")
	AssertFalse(World.Apply())
	_LSP_NativeFacts(World, "foreign_durable")
	AssertTrue(World.Mutated)
	AssertEqual(World.Replacement, FSReadUtf8Exact(World.ApiPath), "unknown external bytes survive refused durable publication")
	AssertTrue(_LLM_Menu == World.OldMenu)
	AssertTrue(Features == World.OldFeatures)
	AssertEqual(0, World.ApplyCalls)
	AssertTrue(_ConfigWriteTerminalIsActive())
	AssertTrue(ConfigTransitionRetainedBarrier() == World.OwnedBundle)
	AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "ready"))
	AssertFalse(World.Owner.Capture())
}
Test("Local server publication: foreign post-durable bytes retain unresolved ownership (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_PostDurableForeignImage))

_LSP_PostDurableNativeOwner(World) {
	global _LLM_Menu, Features
	World.Capture()
	World.Mutation := "committed_owner"
	AssertFalse(World.Apply())
	AssertTrue(_LLM_Menu != World.OldMenu, "the independently replaced native owner survives refusal")
	AssertTrue(Features == World.OldFeatures)
	AssertEqual(World.ConfigImage, FSReadUtf8Exact(World.ConfigPath))
	AssertEqual(World.ApiImage, FSReadUtf8Exact(World.ApiPath))
	AssertEqual(0, World.ApplyCalls)
	AssertFalse(_ConfigWriteTerminalIsActive())
}
Test("Local server publication: post-durable owner replacement restores files without clobbering RAM (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_PostDurableNativeOwner))

_LSP_ExactCapabilityOrigin(World) {
	World.Capture()
	World.OtherReceipt := World.Owner.Capture()
	AssertTrue(World.OtherReceipt is LLM_Menu_ApiPrivateSourceReceipt)
	AssertTrue(World.Owner.Current(World.OtherReceipt))
	AssertFalse(World.Owner.Current(LLM_Menu_ApiPrivateSourceReceipt()))
	AssertFalse(World.Owner.CandidateCurrent(LLM_Menu_ApiPrivateCandidateReceipt()))
	World.Mutation := "wrong_source"
	Saved := World.Apply()
	AssertTrue(Saved is Map)
	AssertTrue(Saved["saved"])
	AssertFalse(World.WrongCandidate, "even identical same-owner authority cannot borrow another Apply receipt's bundle")
}
Test("Local server publication: candidate capability binds the exact originating Apply receipt (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ExactCapabilityOrigin))


_LSP_FinalReadModelRefusal(World) {
	World.Capture()
	World.Mutation := "claim_model"
	AssertFalse(World.Apply())
	_LSP_NativeFacts(World, "final_reread_model")
	AssertTrue(World.Mutated, "the actual final private reread must cross the independent model revocation boundary")
	AssertEqual(2, World.CommittedCalls)
	AssertEqual(1, World.ClaimCalls)
	AssertTrue(World.ClaimCritical, "the pure final claim and actual RAM swap share the same native Critical ownership")
	World.AssertUnchanged()
	AssertFalse(_ConfigWriteTerminalIsActive())
}
Test("Local server publication: final file reread cannot outlive the retained model claim (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_FinalReadModelRefusal))


_LSP_ConfigAliases(World) {
	for Image in [StrReplace(World.ConfigImage, "[llm.models]", "[LLM.models]"),
		StrReplace(World.ConfigImage, "selected =", "SELECTED ="),
		'[llm]`napi_entry_id = "native-active"`nmodels = { selected = "ollama" }`n',
		'llm.models.selected = "ollama"`nllm.api_entry_id = "native-active"`n'] {
		AssertTrue(FSWriteDurable(World.ConfigPath, Image))
		AssertFalse(World.Owner.Capture(), "unsupported semantic/physical AI aliases never qualify default native RAM")
		AssertEqual(Image, FSReadUtf8Exact(World.ConfigPath))
	}
}
Test("Local server source: config loader aliases cannot borrow canonical default authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ConfigAliases))


_LSP_InvalidSchema(World) {
	for Version in [0, -1] {
		Image := "[_meta]`nschema_version = " . Version . "`n" . World.ConfigImage
		AssertTrue(FSWriteDurable(World.ConfigPath, Image))
		AssertFalse(World.Owner.Capture(), "an explicit version rejected by native boot cannot mint private authority")
		AssertEqual(Image, FSReadUtf8Exact(World.ConfigPath))
	}
}
Test("Local server source: invalid explicit native schema stamps remain untouched (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_InvalidSchema))

_LSP_MissingWalDebt(World) {
	global _LLM_Menu, Features, _PathsFile
	World.Capture()
	World.Mutation := "missing_wal"
	AssertFalse(World.Apply())
	_LSP_NativeFacts(World, "missing_wal")
	AssertTrue(World.Mutated, "the actual committed-new WAL must have been removed at the refusal boundary")
	AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "absent"))
	AssertEqual(World.ConfigCandidate, FSReadUtf8Exact(World.ConfigPath))
	AssertEqual(World.ApiCandidate, FSReadUtf8Exact(World.ApiPath))
	AssertTrue(_LLM_Menu == World.OldMenu)
	AssertTrue(Features == World.OldFeatures)
	AssertEqual(0, World.ApplyCalls)
	AssertTrue(_ConfigWriteTerminalIsActive(), "missing WAL does not prove either original image restored")
	AssertTrue(ConfigTransitionRetainedBarrier() == World.OwnedBundle)
	AssertFalse(World.Owner.Capture())
}
Test("Local server publication: missing durable journal cannot reopen stale RAM authority (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_MissingWalDebt))

_LSP_FinalReloadRefusal(World) {
	global _LLM_Menu
	World.Capture()
	World.Mutation := "claim_reload"
	AssertFalse(World.Apply())
	AssertEqual(1, World.ClaimCalls)
	AssertTrue(_LLM_Menu == World.OldMenu)
	AssertEqual("independent-next", _LLM_Menu["api_entries"][2]["Model"],
		"the actual independently loaded new API authority survives guarded publication refusal")
	AssertEqual(World.ConfigImage, FSReadUtf8Exact(World.ConfigPath))
	AssertEqual(World.ApiImage, FSReadUtf8Exact(World.ApiPath))
	AssertEqual(0, World.ApplyCalls)
	AssertFalse(_ConfigWriteTerminalIsActive())
}
Test("Local server publication: actual reload during final claim invalidates narrow source stamp (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_FinalReloadRefusal))

_LSP_InheritedCritical(World, Refused) {
	Prior := Critical("On")
	try {
		World.Capture()
		AssertTrue(A_IsCritical, "private source acquisition restores inherited Critical")
		AssertTrue(World.Owner.Current(World.Receipt))
		AssertTrue(A_IsCritical, "private source revalidation restores inherited Critical")
		AssertTrue(World.Owner.Entry("lmstudio") is Map)
		AssertTrue(A_IsCritical, "private source resolution restores inherited Critical")
		if Refused
			World.Mutation := "model"
		Saved := World.Apply()
		AssertTrue(A_IsCritical, "private persistence restores inherited Critical on success and refusal")
		if Refused
			AssertFalse(Saved)
		else
			AssertTrue(Saved is Map)
	} finally Critical(Prior)
}
Test("Local server publication: inherited Critical restored on success (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_InheritedCritical(World, false)))
Test("Local server publication: inherited Critical restored on refusal (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_InheritedCritical(World, true)))


_LSP_IntegralFloatSchema(World) {
	Image := "[_meta]`nschema_version = 3.0`n" . World.ConfigImage
	AssertTrue(FSWriteDurable(World.ConfigPath, Image))
	ParsedVersion := TOML_ParseDocument(FSReadUtf8Exact(World.ConfigPath))["_meta"]["schema_version"]
	AssertTrue(ParsedVersion is Float, "the independent native source must contain a genuine integral Float")
	AssertTrue(_ConfigMigrateIsVersion(ParsedVersion), "the existing native schema owner accepts this legal stamp")
	Receipt := World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt, "private AI authority preserves native positive integral Float semantics")
	AssertTrue(World.Owner.Current(Receipt))
	AssertEqual(Image, FSReadUtf8Exact(World.ConfigPath), "source qualification does not rewrite the legal Float stamp")
	AssertEqual(World.ApiImage, FSReadUtf8Exact(World.ApiPath))
}
Test("Local server source: native integral Float schema stamp qualifies unchanged source (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_IntegralFloatSchema))


_LSP_ShutdownHistory(World) {
	global _LifecycleShutdownReason
	Old := World.Capture()
	Attempt := LLM_Menu_ApiPrivateBeginShutdown()
	try {
		AssertTrue((Attempt is Integer) && Attempt > 0)
		AssertFalse(World.Owner.Admit())
		AssertFalse(World.Owner.Capture())
		AssertFalse(World.Owner.Current(Old))
		AssertFalse(World.Apply())
		_LifecycleShutdownReason := "Exit"
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		Fresh := World.Owner.Capture()
		AssertTrue(Fresh is LLM_Menu_ApiPrivateSourceReceipt)
		AssertTrue(World.Owner.Current(Fresh), "historical exit reason is not active authority")
		AssertFalse(World.Owner.Current(Old), "an honored veto never resurrects a pre-attempt receipt")
		AssertEqual("Exit", _LifecycleShutdownReason, "private lifecycle ownership never rewrites the native reason")
		World.AssertUnchanged()
	} finally LLM_Menu_ApiPrivateRefuseShutdown(Attempt)
}
Test("Local server source: exact veto allows fresh authority beside historical reason (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ShutdownHistory))

_LSP_ShutdownSuperseded(World) {
	Old := World.Capture()
	First := LLM_Menu_ApiPrivateBeginShutdown()
	Second := LLM_Menu_ApiPrivateBeginShutdown()
	try {
		AssertTrue(Second > First)
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(First))
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(String(Second)))
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(0))
		AssertFalse(World.Owner.Capture(), "a stale refusal cannot clear the superseding attempt")
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Second))
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(Second))
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(First))
		AssertTrue(World.Owner.Capture() is LLM_Menu_ApiPrivateSourceReceipt)
		AssertFalse(World.Owner.Current(Old))
		World.AssertUnchanged()
	} finally LLM_Menu_ApiPrivateRefuseShutdown(Second)
}
Test("Local server source: superseded and repeated veto tokens cannot reopen active shutdown (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ShutdownSuperseded))

_LSP_ShutdownForeignBarrier(World) {
	World.Capture()
	Bundle := _ConfigWriteTerminalTryAcquire([World.ConfigPath, World.ApiPath])
	AssertTrue(Bundle is Object)
	Attempt := LLM_Menu_ApiPrivateBeginShutdown()
	try {
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		AssertFalse(World.Owner.Admit())
		AssertFalse(World.Owner.Capture(), "a canceled AI attempt cannot borrow a foreign terminal barrier")
		AssertFalse(World.Owner.Current(World.Receipt))
		AssertFalse(World.Apply())
		AssertTrue(_ConfigWriteLeaseState().terminal == Bundle)
		World.AssertUnchanged()
	} finally {
		LLM_Menu_ApiPrivateRefuseShutdown(Attempt)
		_ConfigWriteTerminalRelease(Bundle)
	}
	AssertTrue(World.Owner.Capture() is LLM_Menu_ApiPrivateSourceReceipt)
}
Test("Local server source: exact veto preserves foreign terminal debt admission (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ShutdownForeignBarrier))

_LSP_ShutdownClaim(World, Veto) {
	World.Capture()
	World.Mutation := Veto ? "claim_shutdown_veto" : "claim_shutdown"
	try {
		AssertFalse(World.Apply())
		AssertTrue(World.Mutated, "the genuine final native claim must reach the attempt boundary")
		AssertTrue(World.ClaimCritical)
		AssertEqual(1, World.ClaimCalls)
		AssertFalse(World.Owner.Current(World.Receipt))
		World.AssertUnchanged()
		AssertFalse(_ConfigWriteTerminalIsActive(), "owned rollback retires its exact terminal bundle")
		if Veto
			AssertTrue(World.Owner.Capture() is LLM_Menu_ApiPrivateSourceReceipt)
		else
			AssertFalse(World.Owner.Capture())
	} finally {
		if World.HasOwnProp("ShutdownAttempt")
			LLM_Menu_ApiPrivateRefuseShutdown(World.ShutdownAttempt)
	}
}
Test("Local server publication: active shutdown during final claim refuses RAM (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_ShutdownClaim(World, false)))
Test("Local server publication: attempt followed by veto during final claim still refuses old RAM authority (local-server-private-source)",
	(*) => _LSP_WithWorld((World) => _LSP_ShutdownClaim(World, true)))

_LSP_ShutdownCritical(World) {
	Prior := Critical("On")
	Attempt := 0
	try {
		Attempt := LLM_Menu_ApiPrivateBeginShutdown()
		AssertTrue(A_IsCritical, "begin preserves inherited Critical")
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(Attempt + 1))
		AssertTrue(A_IsCritical, "wrong attempt refusal preserves inherited Critical")
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		AssertTrue(A_IsCritical, "exact attempt refusal preserves inherited Critical")
		AssertFalse(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		AssertTrue(A_IsCritical, "repeated refusal preserves inherited Critical")
		World.Capture()
		AssertTrue(A_IsCritical, "fresh source acquisition preserves inherited Critical after veto")
		World.AssertUnchanged()
	} finally {
		LLM_Menu_ApiPrivateRefuseShutdown(Attempt)
		Critical(Prior)
	}
}
Test("Local server source: pure shutdown attempt hooks restore inherited Critical on all outcomes (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_ShutdownCritical))


_LSP_NativeFacts(World, Point) {
	PreviousCritical := Critical("Off")
	try {
		Terminal := _ConfigWriteLeaseState().terminal
		Retained := ConfigTransitionRetainedBarrier()
		Owned := World.OwnedBundle
		Tokens := Owned is Object && Owned.HasOwnProp("tokens") ? Owned.tokens : []
		AllOwn := Tokens.Length > 0
		for Token in Tokens
			AllOwn := AllOwn && _ConfigWriteLeaseOwns(Token)
		_TestPrint("# private-publication-native point=" . Point
			. " prior_object=" . IsObject(World.PriorRetained)
			. " retained_object=" . IsObject(Retained)
			. " terminal_object=" . IsObject(Terminal)
			. " owned_object=" . IsObject(Owned)
			. " retained_owned=" . (Retained == Owned)
			. " retained_terminal=" . (Retained == Terminal)
			. " owned_terminal=" . (Owned == Terminal)
			. " tokens=" . Tokens.Length . " tokens_owned=" . AllOwn
			. " committed=" . World.CommittedCalls . " claims=" . World.ClaimCalls
			. " model_current=" . World.ModelCurrent
			. " apply_calls=" . World.ApplyCalls)
	} finally Critical(PreviousCritical)
}
