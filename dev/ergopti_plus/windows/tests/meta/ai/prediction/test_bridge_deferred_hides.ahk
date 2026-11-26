; tests/meta/ai/prediction/test_bridge_deferred_hides.ahk
;
; ==============================================================================
; MODULE: LLM Bridge Deferred Hide Coverage
; DESCRIPTION:
; Every keyboard-originated LLM dismissal must enqueue the exact-record-fenced
; teardown. Direct Gui destruction in Backspace, Flush/reset, or text injection
; completion stalls the hook and can let an old callback erase a new prediction.
; ==============================================================================

#Requires AutoHotkey v2.0

_LBDH_AllKeyboardDismissalsAreDeferred() {
    for Fn in ["LLM_Bridge_ResetPredictions", "_LLM_Bridge_OnInjectComplete"] {
        Body := _DriverFuncBody(Fn)
        Assert(Body != "", Fn . " must exist")
        Assert(InStr(Body, "LLM_Bridge_DeferTooltipHide(") > 0,
            Fn . " must route tooltip teardown through the exact-record deferred helper")
        Assert(InStr(Body, "LLM_Tooltip_Hide(") = 0,
            Fn . " must not synchronously destroy the layered tooltip surface")
    }
	Backspace := _DriverFuncBody("LLM_Bridge_OnBackspace")
	Schedule := _DriverFuncBody("_LLM_Bridge_SchedulePrefixObserver")
	Observer := _DriverFuncBody("_LLM_Bridge_RunPrefixObserver")
	Notify := _DriverFuncBody("_LLM_Bridge_NotifyChar")
	AssertContains(Backspace, "_LLM_Bridge_SchedulePrefixObserver(")
	AssertContains(Schedule, "_LLM_Bridge_RunPrefixObserver.Bind(Owner)")
	AssertContains(Observer, "_LLM_Bridge_NotifyChar(Owner.Char, _LLM_Bridge_Buffer, CurrentFn, Owner.Source, Receipt)")
	AssertContains(Notify, "LLM_Bridge_DeferTooltipHide(")
	for Body in [Backspace, Schedule, Observer, Notify] {
		Assert(!InStr(Body, "LLM_Tooltip_Hide("), "every Backspace delegation edge must exclude synchronous surface destruction")
		Assert(!InStr(Body, "LLM_Tooltip_HideExact("), "the exact-record destroy belongs only to the deferred worker")
	}
	Defer := _DriverFuncBody("LLM_Bridge_DeferTooltipHide")
	Worker := _DriverFuncBody("_LLM_Bridge_DeferredTooltipHide")
	Complete := RegExReplace(
		_DriverFuncBody("_LLM_Bridge_OnInjectComplete"), "\s+", " ")
	Assert(InStr(Defer, "LLM_Tooltip_GetPresentedToken()") > 0
		and InStr(Defer,
			"_LLM_Bridge_DeferredTooltipHide.Bind(Record, accepted)") > 0,
		"the hook must snapshot one exact presentation object, not only an integer epoch")
	Assert(InStr(Worker,
		"LLM_Tooltip_HideExact(ExpectedRecord, accepted)") > 0,
		"the deferred worker must retire only the captured record")
	Assert(InStr(Complete,
		"LLM_Bridge_DeferTooltipHide(true, Transaction.PresentedRecord)") > 0
		and InStr(Complete,
			"LLM_Bridge_DeferTooltipHide(false, Transaction.PresentedRecord)") > 0,
		"sender success and failure must finish the exact record claimed before output")
}

Test("llm bridge: all keyboard-originated tooltip hides are deferred and record-fenced (llm-bridge-deferred-hides)",
    _LBDH_AllKeyboardDismissalsAreDeferred)
