; tests/meta/test_blocking_inputhook_suspend_ownership_20260813.ahk

; ==============================================================================
; MODULE: Blocking InputHook suspend ownership regression guard
; DESCRIPTION:
; A suppressive InputHook survives native Suspend. Every production function
; that constructs an InputHook and blocks in Wait() must therefore publish its
; exact hook before Start(), let suspend entry stop that owner, clear the owner
; in finally, and re-check A_IsSuspended after the message-pumping wait. The
; function set is derived from production source so a future sibling cannot be
; omitted by extending a hand-maintained list (magic-key-inputhook-suspend-ownership).
; ==============================================================================

#Requires AutoHotkey v2.0

_BIHS_BlockingInputHookFunctions() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "blocking InputHook ownership scan must read production source")
	Functions := Map()
	SearchPos := 1
	while (WaitPos := InStr(Src, ".Wait()", true, SearchPos)) {
		; Production top-level function signatures start at column zero. The nearest
		; preceding signature owns this Wait call; _DriverFuncBody then validates
		; that it is a real definition instead of trusting a multiline regex.
		Prefix := SubStr(Src, 1, WaitPos)
		NearestName := ""
		SignaturePos := 1
		while RegExMatch(Prefix, "m)^([A-Za-z_][A-Za-z0-9_]*)\(", &Match, SignaturePos) {
			NearestName := Match[1]
			SignaturePos := Match.Pos + Max(1, StrLen(Match[0]))
		}
		Assert(NearestName != "", "every production .Wait() call must belong to a top-level function")
		Body := _DriverFuncBody(NearestName)
		if InStr(Body, "InputHook(", true)
			Functions[NearestName] := Body
		SearchPos := WaitPos + StrLen(".Wait()")
	}
	Assert(Functions.Count > 0,
		"blocking InputHook ownership scan must discover at least one production function")
	Assert(Functions.Has("MagicKeyEditor"),
		"class-wide scan must include MagicKeyEditor rather than passing vacuously")
	return Functions
}

_BIHS_AllBlockingInputHooksAreSuspendOwned() {
	Functions := _BIHS_BlockingInputHookFunctions()
	Lifecycle := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Lifecycle != "", "Ergopti_OnSuspendEnter must remain present")
	for FunctionName, Body in Functions {
		HookPos := InStr(Body, "InputHook(", true)
		WaitPos := InStr(Body, ".Wait()", true, HookPos)
		Assert(HookPos > 0 and WaitPos > HookPos,
			FunctionName . " must construct its InputHook before waiting")

		OwnerPattern := "m)^[ \t]*global[ \t]+(_[A-Za-z0-9_]*InputHook)(?:[ \t,]|$)"
		Assert(RegExMatch(Body, OwnerPattern, &OwnerMatch) > 0,
			FunctionName . " must declare an exact global InputHook lifecycle owner")
		OwnerName := OwnerMatch[1]
		PublishPos := InStr(Body, OwnerName . " :=", true, HookPos)
		StartPos := InStr(Body, ".Start()", true, HookPos)
		Assert(PublishPos > HookPos and StartPos > PublishPos,
			FunctionName . " must publish " . OwnerName . " before Start()")

		FinallyPos := InStr(Body, "finally", true, WaitPos)
		ClearPos := InStr(Body, OwnerName . " := " . Chr(34) . Chr(34), true, WaitPos)
		Assert(FinallyPos > WaitPos and ClearPos > FinallyPos,
			FunctionName . " must clear " . OwnerName . " in finally after Wait()")
		Assert(InStr(Lifecycle, OwnerName . ".Stop()", true) > 0,
			"suspend entry must stop " . OwnerName . " synchronously")

		GuardPos := InStr(Body, "A_IsSuspended", true, WaitPos)
		Assert(GuardPos > WaitPos,
			FunctionName . " must re-check A_IsSuspended after its message-pumping Wait()")
		if (FunctionName == "MagicKeyEditor") {
			CriticalPos := InStr(Body, 'Critical("On")', true, HookPos)
			OffPos := InStr(Body, 'Critical("Off")', true, StartPos)
			RestorePos := InStr(Body, "Critical(_InheritedCritical)", true, WaitPos)
			Assert(CriticalPos > HookPos and CriticalPos < PublishPos
				and OffPos > StartPos and OffPos < WaitPos and RestorePos > WaitPos,
				"MagicKeyEditor must atomically publish + start, leave Critical for Wait(), then restore its caller")
			ExactClearPos := InStr(Body, OwnerName . " == IH", true, WaitPos)
			Assert(ExactClearPos > WaitPos and ExactClearPos < ClearPos,
				"MagicKeyEditor must not let an older callback clear a successor hook owner")
			CommitPos := InStr(Body, "ModifyMagicKey(", true, WaitPos)
			Assert(CommitPos > GuardPos,
				"MagicKeyEditor must refuse a paused capture before persisting or reloading")
		}
	}
}

Test("lifecycle: every blocking InputHook is suspend-owned and post-wait gated (magic-key-inputhook-suspend-ownership)",
	_BIHS_AllBlockingInputHooksAreSuspendOwned)
