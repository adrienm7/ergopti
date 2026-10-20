; tests/unit/modules/llm/servers/test_local_server_source_operations.ahk

; ==============================================================================
; MODULE: Local Server Source Operations
; DESCRIPTION:
; Each source and capture operation keeps the original native port, the
; authored schema stamp is admitted, and generic and configured local
; endpoints keep their identity through private publication.
; ==============================================================================

#Requires AutoHotkey v2.0





; Handwritten original callback expectations remain independent of the fixture
; interceptors. Real issued port withdrawal controls stay in the native unit.
_LSP_AssertOriginalNativePort(NativePort) {
	Expected := Map("exists", FSStrictExists, "read", FSReadUtf8Exact,
		"read_bounded", FSReadUtf8ExactBounded, "write_create_durable", FSWriteCreateDurable,
		"move_create", FSAtomicMoveCreate, "move_replace", FSAtomicMoveReplace,
		"delete", FSDeleteStrict, "hash", CryptoSha256)
	AssertEqual(8, Expected.Count)
	AssertEqual(8, NativePort.Count, "custom fixture callbacks cannot contaminate the actual native class")
	AssertTrue(ConfigTransitionProductionPort(NativePort), "the original genuine canonical owner remains admitted")
	AssertTrue(ConfigTransitionProductionPort() == NativePort, "interception never rotates or repairs native authority")
	for Method, Callback in Expected
		AssertTrue(NativePort[Method] == Callback, "original native callback identity remains exact: " . Method)
}

; Observe actual source operations without replacing schema or snapshot producers.
class _LSP_SourceOperationObserver {
	__New(World, ReadIndex := 0, Kind := "") {
		this.World := World
		this.Owner := World.Owner
		this.ReadIndex := ReadIndex
		this.Kind := Kind
		this.Reads := 0
		this.FullAdmissions := 0
		this.Mutated := false
		this.Registry := ConfigMigrateShippedRegistry()
		this.Step := this.Registry["steps"][1]
		this.Reason := this.Step["reason"]
		this.OriginalAdmit := LLM_Menu_ApiPrivateSourceOwner.Prototype.GetOwnPropDesc("_AdmitNonCritical").Call
		this.OriginalSnapshot := LLM_Menu_ApiPrivateSourceOwner.Prototype.GetOwnPropDesc("_Snapshot").Call
		AssertFalse(Object.Prototype.HasOwnProp.Call(this.Owner, "_AdmitNonCritical"))
		AssertFalse(Object.Prototype.HasOwnProp.Call(this.Owner, "_Snapshot"))
		this.Owner.DefineProp("_AdmitNonCritical", {Call: ObjBindMethod(this, "Admit")})
		this.Owner.DefineProp("_Snapshot", {Call: ObjBindMethod(this, "Snapshot")})
	}

	Admit(Owner) {
		global _LLM_Menu
		this.FullAdmissions += 1
		Accepted := this.OriginalAdmit.Call(Owner)
		; A source operation's only full admission is its final one.
		if this.Kind == "final_context" && this.FullAdmissions == 1 && Accepted {
			_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
			this.Mutated := true
		}
		return Accepted
	}

	Snapshot(Owner, Path) {
		global _LLM_Menu
		this.Reads += 1
		if this.Reads == this.ReadIndex && this.Kind != "final_context" {
			switch this.Kind {
				case "source":
					Content := Path == this.World.ConfigPath
						? StrReplace(this.World.ConfigImage, "native-active", "changed-active")
						: StrReplace(this.World.ApiImage, "Original first", "Changed first")
					AssertTrue(FSWriteDurable(Path, Content))
				case "registry":
					this.Step["reason"] := this.Reason . " changed"
				case "context":
					_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
				case "future":
					Content := StrReplace(this.World.ConfigImage,
						"schema_version = " . ConfigMigrateCurrentVersion(),
						"schema_version = " . (ConfigMigrateCurrentVersion() + 1))
					AssertTrue(FSWriteDurable(this.World.ConfigPath, Content))
				case "malformed":
					AssertTrue(FSWriteDurable(this.World.ConfigPath,
						this.World.ConfigImage . "schema_version = " . ConfigMigrateCurrentVersion() . "`n"))
			}
			this.Mutated := true
		}
		return this.OriginalSnapshot.Call(Owner, Path)
	}

	Restore() {
		this.Step["reason"] := this.Reason
		this.Owner.DeleteProp("_AdmitNonCritical")
		this.Owner.DeleteProp("_Snapshot")
	}
}

_LSP_SourceOperationBody(ReadIndex, Kind, World) {
	AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
	AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath))
	World.Capture()
	Observed := _LSP_SourceOperationObserver(World, ReadIndex, Kind)
	try {
		if Kind == "nominal" {
			AssertTrue(World.Owner.Current(World.Receipt))
			AssertEqual(4, Observed.Reads, "all four external snapshot fences remain active")
			AssertEqual(1, Observed.FullAdmissions,
				"one source operation pays one full admission, after its reads (llm-source-current-single-admission)")
		} else if Kind == "default_full" {
			Held := World.Owner._Held(World.Receipt)
			AssertTrue(World.Owner._NativeCurrent(Held))
			AssertEqual(1, Observed.FullAdmissions, "default native checks outside the read operation remain fully admitted")
			AssertEqual(0, Observed.Reads)
		} else {
			AssertFalse(World.Owner.Current(World.Receipt), "changed source, registry or context cannot mint currentness")
			AssertTrue(Observed.Mutated, "the actual designated external-read or final-admission seam must execute")
			if Kind == "registry" || Kind == "future" || Kind == "malformed" || Kind == "final_context"
				AssertEqual(1, Observed.FullAdmissions, "persistent schema or registry refusal is rechecked at the final boundary")
		}
		AssertEqual(0, World.ApplyCalls, "read-only validation cannot publish RAM or initiate application")
	} finally Observed.Restore()
}

_LSP_RegisterSourceOperationCases() {
	local Kind, Index
	for Kind in ["source", "registry", "context"]
		loop 4 {
			Index := A_Index
			Test("Local source operation: " . Kind . " changes at snapshot " . Index . " (source-operation-boundary)",
				_LSP_WithWorld.Bind(_LSP_SourceOperationBody.Bind(Index, Kind)))
		}
	for Kind in ["future", "malformed", "final_context", "nominal", "default_full"]
		Test("Local source operation: " . Kind . " retains final admission (source-operation-boundary)",
				_LSP_WithWorld.Bind(_LSP_SourceOperationBody.Bind((Kind == "nominal" || Kind == "default_full") ? 0 : 4, Kind)))
}
_LSP_RegisterSourceOperationCases()

; The same read-boundary contract also applies to initial source acquisition.
_LSP_CaptureOperationBody(ReadIndex, Kind, World) {
	AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
	AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath))
	Observed := _LSP_SourceOperationObserver(World, ReadIndex, Kind)
	try {
		Receipt := World.Owner.Capture()
		if Kind == "nominal" {
			AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
			AssertEqual(6, Observed.Reads, "capture retains its two acquisitions and four external image rechecks")
			AssertEqual(2, Observed.FullAdmissions,
				"capture pays one opening and one closing full admission (llm-source-current-single-admission)")
		} else {
			AssertFalse(Receipt is LLM_Menu_ApiPrivateSourceReceipt,
				"source, registry or context replacement cannot issue initial authority")
			AssertTrue(Observed.Mutated, "the designated initial-read mutation must actually execute")
		}
		AssertEqual(0, World.ApplyCalls)
	} finally Observed.Restore()
}

_LSP_RegisterCaptureOperationCases() {
	local Kind, Index
	Test("Local capture operation: nominal bounded full admission (capture-operation-boundary)",
		_LSP_WithWorld.Bind(_LSP_CaptureOperationBody.Bind(0, "nominal")))
	for Kind in ["source", "context", "registry", "future"]
		loop 2 {
			Index := A_Index
			Test("Local capture operation: " . Kind . " changes at initial snapshot " . Index . " (capture-operation-boundary)",
				_LSP_WithWorld.Bind(_LSP_CaptureOperationBody.Bind(Index, Kind)))
		}
}
_LSP_RegisterCaptureOperationCases()



; Authored native source fixtures preserve the same current stamp as their real boot.
_LSP_CurrentConfigSource(AuthoredImage) {
	return AuthoredImage . "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n"
}

_LSP_AuthoredSchemaAdmission(World) {
	AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath), "the authored fixture must retain its genuine current boot admission")
	World.Capture()
	Unstamped := StrReplace(World.ConfigImage, "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n")
	AssertTrue(FSWriteDurable(World.ConfigPath, Unstamped))
	AssertFalse(ConfigSchemaCanPrepareWrite(World.ConfigPath), "removing the genuine stamp must lose native schema admission")
	AssertFalse(World.Owner.Capture(), "an unstamped fixture cannot borrow its earlier READY receipt")
	AssertEqual(Unstamped, FSReadUtf8Exact(World.ConfigPath), "qualification cannot repair an unversioned source")
	AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
	AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath), "restoring the exact current source is observed afresh")
	AssertTrue(World.Owner.Current(World.Receipt), "the original receipt remains bound to exact restored source bytes")
}
Test("Local server source: authored current stamp and unstamped refusal (local-server-current-schema-fixture)",
	(*) => _LSP_WithWorld(_LSP_AuthoredSchemaAdmission))


; Read interleaving belongs to this test object; it never emits native write authority.
class _LSP_NativeWriteSourceOwner extends LLM_Menu_ApiPrivateSourceOwner {
	__New(Options, World) {
		super.__New(Options)
		this.World := World
	}

	_Snapshot(Path) {
		Result := _ConfigTransitionReadSnapshot(this.World.Port, Path)
		return ConfigTransitionResultIs(Result, "snapshot") ? Result["snapshot"] : false
	}
}


; The existing physical publication fixture supplies exact close/probe/rollback evidence.
class _LSP_PhysicalSourceFault extends _LMT_ApiPhysicalPublicationFault {
	__New(World, TargetPath, ExpectedImage) {
		super.__New(false)
		this.ApiPath := TargetPath
		this.OldApi := ExpectedImage
		this.OldConfig := World.ConfigImage
		this.Bundle := _ConfigWriteLeaseState().terminal
		this.Published := 1
	}

	Arm() {
		AssertTrue(ConfigTransitionProductionPort(this.Port))
		AssertEqual(this.OldApi, FSReadUtf8Exact(this.ApiPath))
		; The exact owned file remains readable while native replacement/delete refuses.
		this.Handle := DllCall("kernel32\CreateFileW", "Str", this.ApiPath,
			"UInt", 0x80000000, "UInt", 1, "Ptr", 0, "UInt", 3,
			"UInt", 0x80, "Ptr", 0, "Ptr")
		NativeError := A_LastError
		if this.Handle == -1 {
			this.Handle := 0
			throw OSError(NativeError, A_ThisFunc, "Cannot acquire the owned publication fault handle.")
		}
		AssertTrue(this.Handle != 0)
		this.ObserveNativeRefusal()
	}
}

_LSP_AffinitySource(World, Explicit := false) {
	global _LLM_Menu
	Entries := [Map("Id", "generic-first", "Name", "Private generic name", "Provider", "openai_compat",
		"BaseUrl", "http://127.0.0.1:8000/v1", "Token", "generic-first-secret", "Model", "first-model"),
		Map("Id", "generic-active", "Name", "Personal active name", "Provider", "openai",
			"BaseUrl", "http://[::1]:8000/v1/", "Token", "generic-active-secret", "Model", "active-model"),
		Map("Id", "foreign-cloud", "Name", "Cloud name", "Provider", "openai",
			"BaseUrl", "https://cloud.invalid/v1", "Token", "foreign-credential-sentinel", "Model", "cloud-model")]
	if Explicit
		Entries.Push(Map("Id", "explicit-local", "Name", "Explicit custom", "Provider", "omlx",
			"BaseUrl", "http://localhost:19423/custom/v1", "Token", "explicit-local-secret", "Model", "explicit-model"))
	_LLM_Menu["api_entries"] := Entries
	_LLM_Menu["api_entry_id"] := "generic-active"
	World.ConfigImage := StrReplace(World.ConfigImage, 'api_entry_id = "native-active"', 'api_entry_id = "generic-active"')
	World.ApiImage := _LLM_Menu_SerializeApiEntries(Map("api_entries", Entries))
	AssertTrue(World.ApiImage is String)
	AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
	AssertTrue(FSWriteDurable(World.ApiPath, World.ApiImage))
	return World.Capture()
}

_LSP_AffinityPublish(World) {
	global _LLM_Menu
	Receipt := _LSP_AffinitySource(World)
	Entry := World.Owner.EntryBound("omlx", Receipt)
	AssertEqual("generic-active", Entry["Id"], "active generic affinity follows explicit-provider precedence")
	AssertEqual("openai", Entry["Provider"])
	Fields := Map("base_url", Entry["BaseUrl"], "token", Entry["Token"], "model", "Qwen3-8B-4bit")
	Saved := World.Owner.Apply("omlx", Fields, Receipt, ObjBindMethod(World, "Admission"), true)
	AssertTrue(Saved is Map && Saved["saved"] == true)
	AssertEqual("generic-active", Saved["entry_id"])
	AssertEqual(3, _LLM_Menu["api_entries"].Length, "model selection must edit the original row rather than create a catalogue duplicate")
	Actual := _LLM_Menu["api_entries"][2]
	AssertEqual("openai", Actual["Provider"])
	AssertEqual("Personal active name", Actual["Name"])
	AssertEqual("generic-active-secret", Actual["Token"])
	AssertEqual("Qwen3-8B-4bit", Actual["Model"])
	AssertEqual("foreign-credential-sentinel", _LLM_Menu["api_entries"][3]["Token"])
	Restart := _LLM_Menu_ParseAndValidateApiEntries(FSReadUtf8Exact(World.ApiPath))
	AssertTrue(Restart["ok"])
	AssertEqual("generic-active", Restart["entries"][2]["Id"])
	AssertEqual("openai", Restart["entries"][2]["Provider"])
	AssertEqual("Personal active name", Restart["entries"][2]["Name"])
}
Test("local-server-affinity: actual private publication preserves the original generic row", (*) => _LSP_WithWorld(_LSP_AffinityPublish))

_LSP_AffinityPrecedence(World) {
	Receipt := _LSP_AffinitySource(World, true)
	Entry := World.Owner.EntryBound("omlx", Receipt)
	AssertEqual("explicit-local", Entry["Id"], "an explicit provider outranks an active generic canonical alias")
	AssertEqual("http://localhost:19423/custom/v1", Entry["BaseUrl"])
	Projection := World.Owner.EntriesBound(["omlx"], Receipt)
	AssertEqual("explicit-local", Projection["entries"]["omlx"]["Id"])
}
Test("local-server-affinity: actual private source keeps explicit provider precedence", (*) => _LSP_WithWorld(_LSP_AffinityPrecedence))

_LSP_AffinityPrecommitRefusal(World) {
	global _LLM_Menu
	Receipt := _LSP_AffinitySource(World)
	Entry := World.Owner.EntryBound("omlx", Receipt)
	for Kind in ["address", "foreign"] {
		Fields := Map("base_url", Entry["BaseUrl"], "token", Entry["Token"], "model", Entry["Model"])
		if Kind == "address"
			Fields["base_url"] := "http://localhost:19423/v1"
		else
			Fields["base_url"] := "http://external.invalid:8000/v1"
		AssertFalse(World.Owner.Apply("omlx", Fields, Receipt, ObjBindMethod(World, "Admission"), false),
			"generic edits outside canonical affinity must refuse before committing")
		AssertEqual(World.ApiImage, FSReadUtf8Exact(World.ApiPath))
		AssertEqual(World.ConfigImage, FSReadUtf8Exact(World.ConfigPath))
		AssertEqual(0, World.ApplyCalls)
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertTrue(World.Owner.Current(Receipt))
	}
}
Test("local-server-affinity: off-catalogue generic address edits refuse before native WAL", (*) => _LSP_WithWorld(_LSP_AffinityPrecommitRefusal))

_LSP_AffinityKeyless(World) {
	Receipt := _LSP_AffinitySource(World)
	Entry := World.Owner.EntryBound("omlx", Receipt)
	Fields := Map("base_url", Entry["BaseUrl"], "token", "", "model", Entry["Model"])
	Saved := World.Owner.Apply("omlx", Fields, Receipt, ObjBindMethod(World, "Admission"), false)
	AssertTrue(Saved is Map && Saved["saved"] == true, "a canonical generic loopback entry may explicitly store an empty key")
	Restart := _LLM_Menu_ParseAndValidateApiEntries(FSReadUtf8Exact(World.ApiPath))
	AssertTrue(Restart["ok"])
	AssertEqual("generic-active", Restart["entries"][2]["Id"])
	AssertEqual("openai", Restart["entries"][2]["Provider"])
	AssertEqual("Personal active name", Restart["entries"][2]["Name"])
	AssertEqual("", Restart["entries"][2]["Token"])
	AssertEqual("active-model", Restart["entries"][2]["Model"])
	AssertTrue(_LLMRemoteResolveEntry(Restart["entries"][2]) is Map, "the saved entry must remain usable by the real native resolver")
}
Test("local-server-affinity: actual generic private publication preserves keyless loopback identity", (*) => _LSP_WithWorld(_LSP_AffinityKeyless))

_LSP_ConfiguredSource(World) {
	global _LLM_Menu
	Receipt := _LSP_AffinitySource(World)
	_LLM_Menu["api_entries"][2]["BaseUrl"] := "http://127.0.0.1:19423/custom/v1"
	_LLM_Menu["api_entries"][2]["Token"] := ""
	World.ApiImage := _LLM_Menu_SerializeApiEntries(Map("api_entries", _LLM_Menu["api_entries"]))
	AssertTrue(FSWriteDurable(World.ApiPath, World.ApiImage))
	AssertFalse(World.Owner.Current(Receipt))
	return World.Capture()
}

_LSP_ConfiguredPrivatePublication(World, Canonical := false) {
	global _LLM_Menu, LLM_API_PROVIDER_ORDER
	Receipt := _LSP_ConfiguredSource(World)
	Base := []
	for Id in LLM_API_PROVIDER_ORDER {
		if Id == "omlx" || Id == "lmstudio" || Id == "llamacpp" || Id == "jan"
			Base.Push(Id)
	}
	Projection := World.Owner.ViewsBound(Receipt, Base)
	AssertEqual(5, Projection["order"].Length, "four declared providers precede one configured endpoint view")
	AssertEqual("configured:generic-active", Projection["order"][5])
	View := Projection["servers"]["configured:generic-active"]
	AssertEqual("openai", View["provider"])
	AssertEqual("generic-active", View["entry_id"])
	AssertFalse(View.Has("token"))
	AssertFalse(View.Has("model"))
	AssertFalse(View.Has("Name"))
	Entry := World.Owner.EntryBound("configured:generic-active", Receipt)
	AssertEqual("generic-active", Entry["Id"])
	AssertEqual("openai", Entry["Provider"])
	Url := Canonical ? "http://localhost:8000/v1" : "http://[::1]:19424/other/v1"
	Fields := Map("base_url", Url, "token", "", "model", "selected-generic-model")
	Saved := World.Owner.Apply("configured:generic-active", Fields, Receipt, ObjBindMethod(World, "Admission"), true)
	AssertTrue(Saved is Map && Saved["saved"] == true, "a safe endpoint edit must acknowledge the exact original row after durability")
	AssertEqual("generic-active", Saved["entry_id"])
	AssertEqual(3, _LLM_Menu["api_entries"].Length)
	Actual := _LLM_Menu["api_entries"][2]
	AssertEqual("openai", Actual["Provider"])
	AssertEqual("Personal active name", Actual["Name"])
	AssertEqual("", Actual["Token"])
	AssertEqual(Url, Actual["BaseUrl"])
	AssertTrue(_LLMRemoteResolveEntry(Actual) is Map)
	New := World.Capture()
	AssertFalse(World.Owner.Current(Receipt))
	Projection := World.Owner.ViewsBound(New, Base)
	AssertEqual(Canonical ? 4 : 5, Projection["order"].Length, "canonical transitions remove only the ephemeral configured view")
	AssertEqual("generic-active", World.Owner.EntryBound("configured:generic-active", New)["Id"],
		"post-save acknowledgement stays bound to the original entry independently of displayed membership")
}
Test("configured-local-view: actual private writer preserves nondefault generic endpoint and keyless identity", (*) => _LSP_WithWorld(_LSP_ConfiguredPrivatePublication))
Test("configured-local-view: canonical endpoint transition retains the original durable acknowledgement", (*) => _LSP_WithWorld((World) => _LSP_ConfiguredPrivatePublication(World, true)))

_LSP_ConfiguredSourceRefusesDrift(World) {
	Receipt := _LSP_ConfiguredSource(World)
	Foreign := StrReplace(World.ApiImage, "19423", "19425")
	AssertTrue(FSWriteDurable(World.ApiPath, Foreign))
	AssertFalse(World.Owner.ViewsBound(Receipt, ["omlx", "lmstudio", "llamacpp", "jan"]))
	AssertFalse(World.Owner.Apply("configured:generic-active", Map("base_url", "http://localhost:19423/custom/v1", "token", "", "model", "late"),
		Receipt, ObjBindMethod(World, "Admission"), true))
	AssertEqual(Foreign, FSReadUtf8Exact(World.ApiPath))
	AssertEqual(0, World.ApplyCalls)
}
Test("configured-local-view: stale private source cannot project or persist configured endpoints", (*) => _LSP_WithWorld(_LSP_ConfiguredSourceRefusesDrift))
