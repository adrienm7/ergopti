; tests/meta/modules/hotstrings/catalogue/test_hotstring_override_atomic_publish.ahk

; ==============================================================================
; MODULE: Hotstring Override Atomic Publication Guard
; DESCRIPTION:
; Enumerates both catalogue mutation siblings and pins their shared transaction
; choke point. The guard prevents a future per-site edit from restoring direct
; post-I/O Map publication or moving filesystem replacement under Critical.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Whole-class transaction =======
; ==========================================
; ==========================================

_HSOA_BothCatalogueMutatorsUseAtomicPublisher() {
	for FuncName in ["_HotstringsSetOverrideOwned",
			"_HotstringsClearOverrideOwned"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist for the whole-class guard")
		Body := _StripFullLineComments(Body)
		Assert(InStr(Body, "_HotstringsPersistOverrideCandidate(") > 0,
			FuncName . " must route durable and live publication through the shared transaction")
		Assert(InStr(Body, "_HotstringsOverrides := Candidate") == 0,
			FuncName . " must not publish the candidate after the gateway returns")
		Assert(InStr(Body, "HotstringsResolveBumpGen()") == 0,
			FuncName . " must not invalidate caches outside the coupled publisher")
	}

	Publisher := _DriverFuncBody("_HotstringsPublishOverrideCandidate")
	Assert(Publisher != "",
		"the coupled hotstring override publisher must exist")
	Publisher := _StripFullLineComments(Publisher)
	MapPos := InStr(Publisher, "_HotstringsOverrides := Candidate")
	GenerationPos := InStr(Publisher, "HotstringsResolveBumpGen()")
	Assert(MapPos > 0 && GenerationPos > MapPos,
		"the memory-only publisher must swap the candidate and then invalidate its cache generation")
	for Forbidden in ["FileOpen(", "FileRead(", "FileDelete(",
			"FSAtomic", "DllCall(", "Run(", "Logger", "Notify"] {
		Assert(InStr(Publisher, Forbidden) == 0,
			"the Critical publisher must remain free of I/O: " . Forbidden)
	}
}
Test("hotstring-override-global-transaction-20260813: both mutators share one "
	. "memory-only Map and generation publisher",
	_HSOA_BothCatalogueMutatorsUseAtomicPublisher)

_HSOA_ReplacementEndsBeforePublicationCriticalBegins() {
	Body := _DriverFuncBody("_SaveOverrides")
	Assert(Body != "", "_SaveOverrides must exist for the Critical-span guard")
	Body := _StripFullLineComments(Body)
	ReplacePos := InStr(Body, "ReplaceFn.Call(StagePath, Path)")
	PublishCriticalPos := InStr(Body, 'PreviousCritical := Critical("On")',
		true, ReplacePos)
	PublishPos := InStr(Body, "PublishFn.Call()", true, ReplacePos)
	Assert(ReplacePos > 0 && PublishCriticalPos > ReplacePos
		&& PublishPos > PublishCriticalPos,
		"filesystem replacement must finish before the short live-publication Critical span begins")
	AuthorizeCriticalPos := InStr(Body, 'PreviousCritical := Critical("On")')
	AuthorizeRestorePos := InStr(Body, "finally Critical(PreviousCritical)",
		true, AuthorizeCriticalPos)
	Assert(AuthorizeCriticalPos > 0 && AuthorizeRestorePos > AuthorizeCriticalPos,
		"authorization must retain one bounded Critical span")
	AuthorizeCriticalBody := SubStr(Body, AuthorizeCriticalPos,
		AuthorizeRestorePos - AuthorizeCriticalPos)
	PublishRestorePos := InStr(Body, "finally Critical(PreviousCritical)",
		true, PublishCriticalPos)
	Assert(PublishRestorePos > PublishCriticalPos,
		"live publication must retain one bounded Critical span")
	PublishCriticalBody := SubStr(Body, PublishCriticalPos,
		PublishRestorePos - PublishCriticalPos)
	for CriticalBody in [AuthorizeCriticalBody, PublishCriticalBody] {
		Assert(InStr(CriticalBody, "Logger") == 0
			&& InStr(CriticalBody, "Notify") == 0,
			"no logger or notifier I/O may run inside either short Critical span")
	}
}
Test("hotstring-override-global-transaction-20260813: filesystem replacement "
	. "stays outside the publication Critical span",
	_HSOA_ReplacementEndsBeforePublicationCriticalBegins)

_HSOA_PublicMutatorsDefuseCallerCritical() {
	for FuncName in ["HotstringsSetOverride", "HotstringsClearOverride"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist for the inherited-Critical guard")
		Body := _StripFullLineComments(Body)
		ReadPos := InStr(Body, "InheritedCritical := A_IsCritical")
		OffPos := InStr(Body, 'Critical("Off")', true, ReadPos)
		RecursivePos := InStr(Body, FuncName . "(", true, OffPos)
		RestorePos := InStr(Body, "finally Critical(InheritedCritical)",
			true, RecursivePos)
		Assert(ReadPos > 0 && OffPos > ReadPos && RecursivePos > OffPos
			&& RestorePos > RecursivePos,
			FuncName . " must suspend and restore any caller Critical span around its complete transaction")
	}
}
Test("hotstring-override-global-transaction-20260813: both public mutators "
	. "defuse inherited Critical spans before I/O",
	_HSOA_PublicMutatorsDefuseCallerCritical)

; F-15  a delimiter write used a bare `try` with no catch and no return, so a
; read-only or cloud-locked config file made every observable signal say "saved"
; while the setting silently reverted at next boot. Built-in delimiter states
; are config.toml leaves now: they join the live configuration writer, and the
; engine strings change only from the writer's own publication callback.
_A0720B4_DelimiterWriteFailureIsSurfaced() {
	Body := _DriverFuncBody("HotstringsTerminatorBuiltinCommit")
	Assert(Body != "", "HotstringsTerminatorBuiltinCommit must exist in infra/hotstrings/terminator_records.ahk")
	CommitPos := InStr(Body, "ConfigCommitUpdates(")
	PublishPos := InStr(Body, "_HotstringsTerminatorPublishBuiltin.Bind(")
	Assert(CommitPos > 0 and PublishPos > CommitPos,
		"a delimiter write must hand its detached live publication to the configuration writer")
	Assert(InStr(Body, "FileOpen(") = 0 and InStr(Body, "FileAppend(") = 0,
		"a delimiter write must not truncate or append to the live configuration file")
	Assert(InStr(Body, "return 0") > 0 and InStr(Body, "if !ConfigCommitUpdates(") > 0,
		"a refused write must report failure instead of publishing")
	Publisher := _DriverFuncBody("_HotstringsTerminatorPublishBuiltin")
	Assert(Publisher != ""
		and InStr(Publisher, "HSE_WORD_TERMINATORS :=") > 0
		and InStr(Publisher, "HSE_CONSUMED_DELIMITERS :=") > 0,
		"one publisher must project both delimiter caches together")
	Writer := _DriverFuncBody("_SaveOverrides")
	Assert(Writer != "", "_SaveOverrides must exist")
	AuthorizePos := InStr(Writer, "AuthorizeFn.Call()")
	ReplacePos := InStr(Writer, "FSAtomicMoveReplace(")
	PublishCallPos := InStr(Writer, "PublishFn.Call()")
	Assert(AuthorizePos > 0 and ReplacePos > AuthorizePos
		and PublishCallPos > ReplacePos,
		"the complete stage must be re-authorized, atomically replaced, and projected live in that order")
}
Test("hotstrings: delimiter writes share the admitted configuration writer (F-15)", _A0720B4_DelimiterWriteFailureIsSurfaced)
