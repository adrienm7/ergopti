; tests/unit/modules/llm/servers/test_local_server_publication_rollback.ahk

; ==============================================================================
; MODULE: Local Server Private Publication
; DESCRIPTION:
; Private local-server publication: a refused second target, a mutated
; image or a model-view revocation leaves both files and RAM intact, durable
; debt stays honest, and shutdown vetoes and inherited Critical are
; restored.
; ==============================================================================

#Requires AutoHotkey v2.0





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
	; A generic OpenAI row at the canonical URL is a valid local-server alias.
	; Proved absence needs a nonmatching path in both RAM and durable source.
	_LLM_Menu["api_entries"][1]["BaseUrl"] := "http://127.0.0.1:1234/independent"
	World.ApiImage := StrReplace(World.ApiImage, '"BaseUrl":"http://127.0.0.1:1234/v1"',
		'"BaseUrl":"http://127.0.0.1:1234/independent"', , &ChangedUrls, 1)
	AssertEqual(1, ChangedUrls, "the independent durable row must match its RAM premise")
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
		Image := StrReplace(World.ConfigImage, "schema_version = " . ConfigMigrateCurrentVersion(),
			"schema_version = " . Version)
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
	Image := StrReplace(World.ConfigImage, "schema_version = " . ConfigMigrateCurrentVersion(),
		"schema_version = " . ConfigMigrateCurrentVersion() . ".0")
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
			. " kind_exact=" . (Owned is Object && Owned.HasOwnProp("kind") && Owned.kind == "terminal_bundle")
			. " tokens=" . Tokens.Length . " tokens_owned=" . AllOwn
			. " committed=" . World.CommittedCalls . " claims=" . World.ClaimCalls
			. " model_current=" . World.ModelCurrent
			. " apply_calls=" . World.ApplyCalls)
	} finally Critical(PreviousCritical)
}


_LSP_CommittedCallbackNoIO(World) {
	World.Capture()
	Reads := World.ReadCalls
	Capability := LLM_Menu_ApiPrivateCandidateReceipt()
	Admitted := World.Admission("committed", Capability)
	AssertEqual(Reads, World.ReadCalls, "the retained model callback cannot acquire or reread private source files")
	AssertTrue((Admitted is Integer) && Admitted == 1)
	World.ModelCurrent := false
	Admitted := World.Admission("committed", Capability)
	AssertEqual(Reads, World.ReadCalls, "a refused retained model callback also remains source-port free")
	AssertTrue((Admitted is Integer) && Admitted == 0)
	World.AssertUnchanged()
}
Test("Local server publication: committed model callback performs no private source I/O (local-server-private-source)",
	(*) => _LSP_WithWorld(_LSP_CommittedCallbackNoIO))
