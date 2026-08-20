; tests/meta/test_metrics_shortcut_transaction.ahk

; ==============================================================================
; MODULE: Metrics shortcut transaction structural guard
; DESCRIPTION:
; Pins the whole shortcut class to reserve-Off, same-lease durable recovery,
; explicit retained-handle completion and strict boot-status consumption.
; ==============================================================================

#Requires AutoHotkey v2.0

_MST_Body(Name) {
	Body := _DriverFuncBody(Name)
	Assert(Body != "", Name . " must exist for the metrics shortcut guard")
	return Body
}

_MST_EveryShortcutPathUsesOneRecoveryOwner() {
	Prompt := _MST_Body("MS_PromptShortcut")
	Assert(InStr(Prompt, "MS_CommitShortcutCandidate(") > 0,
		"typing and apps prompts must share one transaction owner")
	Assert(InStr(Prompt, "MetricsShortcuts.typing_str :=") = 0
		and InStr(Prompt, "MetricsShortcuts.apps_str :=") = 0,
		"the prompt must not publish either slot itself")

	Public := _MST_Body("MS_CommitShortcutCandidate")
	Assert(InStr(Public, "MS_RetryShortcutRecovery(") > 0
		and InStr(Public, "CS_SaveBuilt(") > 0,
		"every later edit must finish retained recovery before its owned build")
	Builder := _MST_Body("_MS_BuildShortcutPlan")
	for Field in ["rollback_updates:", "finalize:", "cleanup:", "compensate:",
			"retain:", "publish:"]
		Assert(InStr(Builder, Field) > 0,
			"the shortcut plan must declare " . Field)
	Assert(InStr(Builder, "_HotkeyRegistrarReserveOwned(") > 0,
		"the new callback must enter native state Off before persistence")
	Assert(InStr(Builder, "noop: true") = 0,
		"invalid syntax and owner collisions must not become silent success")
	Assert(InStr(Builder, "throw ValueError(") > 0
		and InStr(Builder, "throw Error(") > 0,
		"invalid and colliding edits must reach the gateway notifier")

	Activate := _MST_Body("_MS_ActivatePreparedShortcut")
	Abort := _MST_Body("_MS_AbortPreparedShortcut")
	Cleanup := _MST_Body("_MS_RetirePreviousShortcut")
	Assert(InStr(Activate, "_HotkeyRegistrarActivate(") > 0
		and InStr(Abort, "_HotkeyRegistrarAbort(") > 0
		and InStr(Cleanup, "_HotkeyRegistrarRetire(") > 0,
		"activation, inert abort and old-authority cleanup must stay distinct")

	Retry := _MST_Body("MS_RetryShortcutRecovery")
	RetryBuilder := _MST_Body("_MS_BuildShortcutRecoveryPlan")
	Assert(InStr(Retry, "CS_SaveBuilt(") > 0
		and InStr(RetryBuilder, "_HotkeyRegistrarRetire(") > 0
		and InStr(RetryBuilder, "_MS_ClearShortcutRecovery.Bind(") > 0,
		"retained handles and rollback state must have a terminable owned path")

	Reporter := _MST_Body("_MS_NotifyBootBindingFailure")
	Assert(InStr(Reporter, "NotifierSend(") > 0
		and InStr(Reporter, "MsgBox(") = 0,
		"boot registration failures must surface once through a non-modal notice")
	ApplyAll := _MST_Body("MS_ApplyAll")
	Assert(InStr(ApplyAll, "Ready := Typing.ok && Apps.ok") > 0
		and InStr(ApplyAll, "_MS_NotifyBootBindingFailure(") > 0,
		"boot must attempt both independent slots and report their aggregate failure")
	Driver := FileRead(A_ScriptDir . "\..\ErgoptiPlus.ahk", "UTF-8")
	Assert(InStr(Driver, "MetricsBindingsReady := MS_ApplyAll(") > 0
		and InStr(Driver, "MetricsBindingsReady is Integer") > 0,
		"boot must strictly consume incomplete metrics activation")
}
Test("metrics shortcut transaction: all slots reserve, recover and publish "
	. "under one owner (metrics-shortcut-transaction-class)",
	_MST_EveryShortcutPathUsesOneRecoveryOwner)
