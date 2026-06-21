; tests/meta/test_ni_isvpnactive_missing_return.ahk

; ==============================================================================
; MODULE: NetworkInfo VPN-Active Explicit-Return Meta Test
; DESCRIPTION:
; Static source guard for finding ni-isvpnactive-missing-return-on-no-match.
;
; NI_IsVpnActive() walks the GetAdaptersAddresses linked list and returns true
; when a recognised VPN adapter is up. On the no-match path the original code
; fell off the end of the while loop with no return statement - an AHK v2
; function with no return yields "" (empty string), violating the boolean
; contract in NetworkInfo.spec.js on the common (no-VPN) path. The fix adds an
; explicit `return false` after the loop, inside the try.
;
; This is a meta-static test (scans source text) because adapters/network_info.ahk
; is NOT part of the headless runner include graph (run_all.ahk does not include
; it - its DllCall paths target live iphlpapi hardware). Calling NI_IsVpnActive()
; from a test would be a load-time error that hangs the suite, so the regression
; is encoded as a source guard for the explicit boolean return instead.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_VpnRet_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Explicit-return assertion =============
; ==================================================
; ==================================================

_VpnRet_NoMatchPathReturnsFalse() {
	Src := _VpnRet_ReadSource("adapters/network_info.ahk")
	Seg := _DriverFuncBody("NI_IsVpnActive")
	Assert(Seg != "", "NI_IsVpnActive() declaration must exist in network_info.ahk")
	; The function must contain the no-match boolean return that follows the
	; `while` walk and precedes the `catch`. Locate the loop close, then assert
	; a `return false` appears after it but before the catch handler.
	WhileIdx := InStr(Seg, "while (p) {")
	Assert(WhileIdx > 0, "NI_IsVpnActive must still iterate adapters with a while (p) loop")
	CatchIdx := InStr(Seg, "} catch {")
	Assert(CatchIdx > WhileIdx, "NI_IsVpnActive must keep its catch handler after the adapter walk")
	Between := SubStr(Seg, WhileIdx, CatchIdx - WhileIdx)
	; Two `return false` occurrences are expected in this slice: one for the rc!=0
	; early bail BEFORE the loop is outside this slice, so the count here reflects
	; the no-match path return added by the fix.
	Assert(InStr(Between, "return false") > 0,
		"NI_IsVpnActive must explicitly return false on the no-VPN path after the adapter walk - falling off the end yields an empty string and breaks the boolean contract")
}
Test("NetworkInfo: NI_IsVpnActive returns explicit false on no-match path (ni-isvpnactive-missing-return-on-no-match)", _VpnRet_NoMatchPathReturnsFalse)
