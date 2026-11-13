; tests/meta/shortcuts/engine/test_wrap_symbols_load_flush.ahk

; Historical F40: a custom pair followed by a disabled block must survive an
; unrelated real save and reload. Drive the existing private-file owner instead
; of pinning the reader's former InDisabled/CurLeft implementation variables.
#Requires AutoHotkey v2.0

_WSLF_DisabledBranchFlushesPendingCustom() {
	_WSIC_CommentRoundTrip("custom-before-disabled")
}
Test("wrap-symbols: a pending custom pair survives a following [[disabled]] block",
	_WSLF_DisabledBranchFlushesPendingCustom)
