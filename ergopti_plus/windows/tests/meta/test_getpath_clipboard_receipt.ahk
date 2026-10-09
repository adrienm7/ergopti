; tests/meta/test_getpath_clipboard_receipt.ahk

; ==============================================================================
; MODULE: GetPath Clipboard Receipt Regression
; DESCRIPTION:
; Pins the live Win-shortcut caller to the behaviorally tested copy-flow helper.
; Both clipboard formats must consume CB_Write's Boolean receipt before any UI
; claims that the selected path was copied.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Live Caller Wiring ==========
; ========================================
; ========================================

_GPCR_GetPathUsesCheckedCopyFlow() {
	Body := _DriverFuncBody("GetPath")
	Assert(Body != "", "GetPath must exist in the Windows shortcuts module")
	Assert(InStr(Body, "_GetPathCopyFlow(") > 0,
		"GetPath must delegate both clipboard formats to the receipt-checked flow")

	FlowBody := _DriverFuncBody("_GetPathCopyFlow")
	Assert(FlowBody != "", "the GetPath copy-flow helper must be defined")
	Assert(InStr(FlowBody, "if !WriteFn.Call(PathWithSlash)") > 0,
		"the slash-form clipboard write must gate the question dialog")
	Assert(InStr(FlowBody, "if !WriteFn.Call(PathWithBackslash)") > 0,
		"the backslash-form clipboard write must gate the success dialog")
}
Test("shortcuts: GetPath consumes clipboard receipts (getpath-copy-receipt)",
	_GPCR_GetPathUsesCheckedCopyFlow)
