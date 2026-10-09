; tests/meta/test_wrap_symbols_load_flush.ahk

; ==============================================================================
; MODULE: _WS_Load flushes a pending custom pair on every section transition
; DESCRIPTION:
; _WS_Load accumulates a [[custom]] wrap pair in CurLeft/CurRight and flushes it when
; it reaches the next section. That flush was implemented in the [[custom]] branch and
; in the generic "[" branch, but the [disabled]/[[disabled]] branch predates the flush
; logic and never got it — so a [[custom]] block immediately followed by a disabled
; block silently dropped the user's wrap pair. It is masked today only because
; _WS_Save happens to emit disabled blocks before custom ones; a hand-edited or
; reordered file loses data. (F40, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_WSLF_DisabledBranchFlushesPendingCustom() {
	Body := _DriverFuncBody("_WS_Load")
	Assert(Body != "", "_WS_Load must exist in infra/wrap_symbols_config.ahk")

	DisPos := InStr(Body, '"[disabled]"')
	Assert(DisPos > 0, "_WS_Load must handle the [disabled] section header")
	InDisPos := InStr(Body, "InDisabled := true", , DisPos)
	Assert(InDisPos > DisPos, "the [disabled] branch must set InDisabled")

	Seg := SubStr(Body, DisPos, InDisPos - DisPos)
	Assert(InStr(Seg, "_WS_Custom.Push") > 0,
		"the [disabled] branch must flush a pending [[custom]] pair BEFORE switching state — otherwise a custom block followed by a disabled block silently loses the user's wrap pair")
}
Test("wrap-symbols: a pending custom pair survives a following [[disabled]] block",
	_WSLF_DisabledBranchFlushesPendingCustom)
