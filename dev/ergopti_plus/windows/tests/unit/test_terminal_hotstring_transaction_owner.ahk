; tests/unit/test_terminal_hotstring_transaction_owner.ahk

; ==============================================================================
; MODULE: Terminal Hotstring Transaction Owner Tests
; DESCRIPTION:
; The deferred terminal sender owns schedule, revalidation, output and commit.
; Physical suffixes are replayed; stale or failed owners publish nothing.
; ==============================================================================

#Requires AutoHotkey v2.0

global _THTO_Runner := 0
global _THTO_Payloads := []
global _THTO_SendVerdict := true
global _THTO_Identity := Map("Hwnd", 701, "Pid", 7001)

_THTO_IdentityProbe() {
	global _THTO_Identity
	return _THTO_Identity.Clone()
}

_THTO_MetadataProbe(Hwnd, Pid) {
	return Map("Exe", "WindowsTerminal.exe", "Class", "fixture", "Title", "Terminal")
}

_THTO_Schedule(Runner, DelayMs) {
	global _THTO_Runner
	_THTO_Runner := Runner
	return true
}

_THTO_Emit(Payload) {
	global _THTO_Payloads, _THTO_SendVerdict
	_THTO_Payloads.Push(Payload)
	return _THTO_SendVerdict
}

_THTO_NoOp(*) {
	return true
}

_THTO_MakeOwner() {
	global HSE_Buffer, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	global _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global _THTO_Identity
	return Map(
		"Id", 1, "Pending", true, "Backspaces", 7,
		"PlainInsertedText", "XGBoost", "SendPayload", "{Text}XGBoost",
		"EndCharPart", "", "OnlyText", true, "DelayMs", 20,
		"EmitFn", _THTO_Emit, "DelayFn", _THTO_NoOp, "BlockFn", _THTO_NoOp,
		"BufferSnapshot", HSE_Buffer,
		"Hwnd", _THTO_Identity["Hwnd"], "Pid", _THTO_Identity["Pid"],
		"RegistryGeneration", HSE_RegistryGeneration,
		"DecisionGeneration", HSE_RuntimeDecisionGeneration,
		"InputGeneration", _PrefixInputContextGeneration,
		"LifecycleGeneration", _PrefixDeferredGeneration,
		"Trigger", "xgboost", "ReplacementForLog", "XGBoost",
		"HType", "star", "Category", "fixture", "Section", "fixture",
		"IsPrivate", false
	)
}

_THTO_Reset() {
	global HSE_Buffer, _PrefixBuffer, _HSE_TerminalOwner
	global _THTO_Runner, _THTO_Payloads, _THTO_SendVerdict, _THTO_Identity
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, _PrefixWatcherSuppressed
	HSE_Buffer := "xgboost"
	_PrefixBuffer := "xgboost"
	_HSE_TerminalOwner := 0
	_THTO_Runner := 0
	_THTO_Payloads := []
	_THTO_SendVerdict := true
	_THTO_Identity := Map("Hwnd", 701, "Pid", 7001)
	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_PrefixWatcherSuppressed := 1
	OutputHostResolverConfigure(_THTO_IdentityProbe, _THTO_MetadataProbe)
}

_THTO_PhysicalSuffixIsReplayedAndCommittedAfterSend() {
	global HSE_Buffer, _PrefixBuffer, _THTO_Runner, _THTO_Payloads
	global _HSE_FireLogQueue
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule))
	AssertEqual("xgboost", HSE_Buffer, "scheduling must not commit canonical state")
	HSE_Buffer .= "q"
	_PrefixBuffer .= "q"
	AssertTrue(_THTO_Runner.Call())
	AssertEqual("{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{Text}XGBoostq",
		_THTO_Payloads[1], "the visible suffix must be erased and replayed after the replacement")
	AssertEqual("XGBoostq", HSE_Buffer)
	AssertEqual("XGBoostq", _PrefixBuffer)
	AssertEqual(1, _HSE_FireLogQueue.Length,
		"metrics become publishable only after successful terminal output")
}
Test("terminal transaction: physical suffix survives deferred output", _THTO_PhysicalSuffixIsReplayedAndCommittedAfterSend)

_THTO_SenderRefusalLeavesEveryStateUncommitted() {
	global HSE_Buffer, _PrefixBuffer, _THTO_Runner, _THTO_SendVerdict
	global _HSE_FireLogQueue
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule))
	HSE_Buffer .= "q"
	_PrefixBuffer .= "q"
	_THTO_SendVerdict := false
	AssertFalse(_THTO_Runner.Call())
	AssertEqual("xgboostq", HSE_Buffer)
	AssertEqual("xgboostq", _PrefixBuffer)
	AssertEqual(0, _HSE_FireLogQueue.Length)
}
Test("terminal transaction: accepted schedule plus failed sender commits nothing", _THTO_SenderRefusalLeavesEveryStateUncommitted)

_THTO_EachOwnershipGenerationAbortsBeforeOutput() {
	global HSE_Buffer, _PrefixDeferredGeneration, HSE_RegistryGeneration
	global _PrefixInputContextGeneration, _THTO_Runner, _THTO_Payloads, _THTO_Identity
	Mutations := [
		(*) => (_THTO_Identity := Map("Hwnd", 702, "Pid", 7002)),
		(*) => (_PrefixDeferredGeneration += 1),
		(*) => (HSE_RegistryGeneration += 1),
		(*) => (_PrefixInputContextGeneration += 1)
	]
	for Mutate in Mutations {
		_THTO_Reset()
		Owner := _THTO_MakeOwner()
		AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule))
		Mutate.Call()
		AssertFalse(_THTO_Runner.Call())
		AssertEqual(0, _THTO_Payloads.Length,
			"a stale target/lifecycle/registry/input owner must emit nothing")
		AssertEqual("xgboost", HSE_Buffer)
	}
}
Test("terminal transaction: every ownership generation is revalidated", _THTO_EachOwnershipGenerationAbortsBeforeOutput)

OutputHostResolverConfigure()

