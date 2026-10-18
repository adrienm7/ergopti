; tests/unit/modules/llm/servers/test_local_server_private_publication.ahk

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
		global LLM_Defaults
		this.HadDefaults := IsSet(LLM_Defaults)
		this.PreviousDefaults := this.HadDefaults ? LLM_Defaults : false
		_LLM_Menu_Loaded := true
		_LifecycleLatestTransition := 0
		_LifecycleShutdownReason := ""
		this.ConfigPath := ConfigurationFile
		this.ApiPath := _LLM_Menu_ApiEntriesPath()
		this.ApplyCalls := 0
		this.ReadCalls := 0
		this.AdmissionCalls := 0
		this.Mutation := ""
		this.Mutated := false
		this.ArmRead := false
		this.ArmFinalModelRead := false
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
		this.PhysicalFault := 0
		this.WrongCandidate := true
		try {
			; This source fixture owns the canonical boot dependency even when filtered.
			LLM_Defaults_Load()
			AssertTrue(LLM_API_PROVIDERS.Has("lmstudio"), "the actual native local-provider catalogue must be present")
			AssertTrue(LLM_LOCAL_API_SERVERS.Has("lmstudio"))
			this.ConfigImage := _LSP_CurrentConfigSource('[llm]`napi_entry_id = "native-active"`n[llm.models]`nselected = "ollama"`n')
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
			; These explicit interception callbacks belong to a detached custom
			; fixture, never the genuine singleton native port's authority.
			NativePort := ConfigTransitionProductionPort()
			_LSP_AssertOriginalNativePort(NativePort)
			this.Port := NativePort.Clone()
			AssertFalse(ConfigTransitionProductionPort(this.Port, "known"),
				"the intercepted fixture copy was never issued native authority")
			AssertFalse(ConfigTransitionProductionPort(this.Port))
			this.Port["read"] := ObjBindMethod(this, "Read")
			this.Port["move_replace"] := ObjBindMethod(this, "MoveReplace")
			this.Port["delete"] := ObjBindMethod(this, "Delete")
			_LSP_AssertOriginalNativePort(NativePort)
			Owned := IsSet(Options) ? Options.Clone() : Map()
			Owned["port"] := NativePort
			Owned["acquire"] := _LMT_Acquire
			Owned["settle"] := _LMT_Settle
			Owned["collect"] := ObjBindMethod(this, "Collect")
			Owned["build_config"] := ObjBindMethod(this, "Build")
			Owned["serialize"] := ObjBindMethod(this, "Serialize")
			Owned["apply"] := ObjBindMethod(this, "ApplyCommitted")
			Owned["notify"] := ObjBindMethod(this, "Notify")
			Owned["pause"] := ObjBindMethod(this, "Pause")
			this.Owner := _LSP_NativeWriteSourceOwner(Owned, this)
			_LSP_NativeFacts(this, "fixture_acquired")
		} catch as Err {
			this.Restore()
			throw Err
		}
	}

	Restore() {
		global LLM_Defaults
		try {
			if this.HasOwnProp("PhysicalFault") && this.PhysicalFault is Object
				this.PhysicalFault.Close()
			global _LLM_Menu_Loaded, _LifecycleLatestTransition, _LifecycleShutdownReason
			global _ConfigTransitionRetainedBarrier, _PathsFile
			; Only this fixture's exclusively created files and exact bundle may be repaired
			; after the assertions. Real production code never gains this cleanup authority.
			if (this.OwnedBundle is Object) && _ConfigWriteLeaseState().terminal == this.OwnedBundle {
				CleanupSettled := false
				try {
					if this.HasOwnProp("ConfigCandidate") {
						FSWriteDurable(this.ConfigPath, this.ConfigCandidate)
						FSWriteDurable(this.ApiPath, this.ApiCandidate)
					}
					Rollback := ConfigTransitionRollbackOwned(_PathsFile, this.OwnedBundle, ConfigTransitionProductionPort())
					if this.CleanupArmed {
						AssertEqual(0, this.PhysicalFault.Handle, "the exact owned obstruction must be closed before cleanup")
						AssertTrue(ConfigTransitionResultIs(Rollback, "recovered_old"),
							"post-close cleanup must acknowledge actual durable rollback")
						AssertEqual(this.ConfigImage, FSReadUtf8Exact(this.ConfigPath))
						AssertEqual(this.ApiImage, FSReadUtf8Exact(this.ApiPath))
						AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "absent"),
							"post-close cleanup must retire the real WAL")
					}
					CleanupSettled := true
				} finally {
					; A refused cleanup preserves the exact owner, debt and private files.
					if !this.CleanupArmed || CleanupSettled {
						_ConfigWriteTerminalRelease(this.OwnedBundle)
						if _ConfigTransitionRetainedBarrier == this.OwnedBundle
							_ConfigTransitionRetainedBarrier := this.PriorRetained
					}
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
		} finally {
			if this.HadDefaults
				LLM_Defaults := this.PreviousDefaults
			else
				LLM_Defaults := unset
		}
	}

	Read(Path) {
		this.ReadCalls += 1
		Content := FSReadUtf8Exact(Path)
		if this.Mutation == "claim_model" && this.ArmFinalModelRead && !this.Mutated {
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
		if Point == "target:new:1" && this.FailApiMove {
			AssertTrue(FSReadUtf8Exact(this.ConfigPath) != this.ConfigImage,
				"the genuine first target must be published before second-target obstruction")
			this.PhysicalFault := _LSP_PhysicalSourceFault(this, this.ApiPath, this.ApiImage)
			this.PhysicalFault.Arm()
		}
		if Point != "phase:committed_new"
			return
		this.OwnedBundle := _ConfigWriteLeaseState().terminal
		this.ConfigCandidate := FSReadUtf8Exact(this.ConfigPath)
		this.ApiCandidate := FSReadUtf8Exact(this.ApiPath)
		; The writer owns this durable boundary; the committed model callback is pure.
		this.OldSourceAdmittedAfterDurability := this.Owner.Current(this.Receipt)
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
		if this.Mutation == "cleanup" {
			this.CleanupArmed := true
			Inspected := ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort())
			AssertTrue(ConfigTransitionResultIs(Inspected, "ready"))
			OldArtifact := _ConfigTransitionArtifactPaths(this.ConfigPath, Inspected["record"]["tx_id"])["old"]
			AssertEqual(this.ConfigImage, FSReadUtf8Exact(OldArtifact),
				"the actual immutable old artifact must belong to this published transaction")
			this.PhysicalFault := _LSP_PhysicalSourceFault(this, OldArtifact, this.ConfigImage)
			this.PhysicalFault.Arm()
		}
		if this.Mutation == "wrong_source"
			this.WrongCandidate := this.Owner.CaptureCandidate(this.OtherReceipt,
				this.OwnedBundle, this.ConfigCandidate, this.ApiCandidate)
	}

	Notify(Message, Options) {
		global _PathsFile
		if this.FailApiMove && this.PhysicalFault is Object {
			Result := this.PhysicalFault.Notify(Message, Options)
			this.MoveRefused := this.PhysicalFault.NativeRefusals == 2
			return Result
		}
		if this.CleanupArmed && this.PhysicalFault is Object {
			AssertEqual(1, this.ApplyCalls, "cleanup refusal follows real application of durable files")
			AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "ready"))
			this.PhysicalFault.ObserveNativeRefusal()
			DeleteRefused := false
			try FSDeleteStrict(this.PhysicalFault.ApiPath)
			catch OSError as DeleteError {
				AssertEqual(32, DeleteError.Number, "the exact held old artifact reports native sharing violation")
				DeleteRefused := true
			}
			AssertTrue(DeleteRefused, "the owned native artifact genuinely refuses deletion")
			AssertEqual(this.ConfigImage, FSReadUtf8Exact(this.PhysicalFault.ApiPath),
				"native deletion refusal preserves the exact locked old bytes")
			this.CleanupRefused := true
		}
		return _LMT_Notify(Message, Options)
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
			; Arm after the pure model admission; the writer owns its source reread.
			if this.Mutation == "claim_model" && this.CommittedCalls >= 2
				this.ArmFinalModelRead := true
			return this.ModelCurrent
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
	global _LLM_Menu, ConfigurationFile
	AssertTrue(FSDeleteStrict(World.ConfigPath))
	AssertTrue(FSDeleteStrict(World.ApiPath))
	World.ConfigPath .= ".absent"
	ConfigurationFile := World.ConfigPath
	AssertEqual("absent", ConfigMigrateBoot(World.ConfigPath)["status"],
		"honest empty authority requires its own genuine fresh-missing boot")
	_LLM_Menu["api_entries"] := []
	_LLM_Menu["api_entry_id"] := ""
	Receipt := World.Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt, "classified absence is honest empty native authority")
	AssertFalse(World.Owner.Entry("lmstudio"))
	NativePort := ConfigTransitionProductionPort()
	Unreadable := NativePort.Clone()
	AssertFalse(ConfigTransitionProductionPort(Unreadable, "known"),
		"an unreadable custom callback copy was never issued native authority")
	Unreadable["exists"] := (*) => "unknown"
	_LSP_AssertOriginalNativePort(NativePort)
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
