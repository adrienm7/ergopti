; tests/meta/test_llm_bridge_deferred_hides.ahk
;
; ==============================================================================
; MODULE: LLM Bridge Deferred Hide Coverage
; DESCRIPTION:
; Every keyboard-originated LLM dismissal must enqueue the generation-fenced
; teardown. Direct Gui destruction in Backspace, Flush/reset, or text injection
; completion stalls the hook and can let an old callback erase a new prediction.
; ==============================================================================

#Requires AutoHotkey v2.0

_LBDH_AllKeyboardDismissalsAreDeferred() {
    for Fn in ["LLM_Bridge_OnBackspace", "LLM_Bridge_ResetPredictions", "_LLM_Bridge_OnInjectComplete"] {
        Body := _DriverFuncBody(Fn)
        Assert(Body != "", Fn . " must exist")
        Assert(InStr(Body, "LLM_Bridge_DeferTooltipHide(") > 0,
            Fn . " must route tooltip teardown through the generation-fenced deferred helper")
        Assert(InStr(Body, "LLM_Tooltip_Hide(") = 0,
            Fn . " must not synchronously destroy the layered tooltip surface")
    }
}

Test("llm bridge: all keyboard-originated tooltip hides are deferred and epoch-fenced (llm-bridge-deferred-hides)",
    _LBDH_AllKeyboardDismissalsAreDeferred)
