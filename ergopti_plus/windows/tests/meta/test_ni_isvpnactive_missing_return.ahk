; tests/meta/test_ni_isvpnactive_missing_return.ahk

; ==============================================================================
; MODULE: NetworkInfo VPN-Active Explicit-Return Meta Test
; DESCRIPTION:
; Static source guard for finding ni-isvpnactive-missing-return-on-no-match.
;
; NI_GetVpnStatus() walks the GetAdaptersAddresses linked list and returns a
; typed observation when a recognised VPN adapter is up. On the no-match path
; the original NI_IsVpnActive implementation
; fell off the end of the while loop with no return statement - an AHK v2
; function with no return yields "" (empty string), violating the boolean
; contract in NetworkInfo.spec.js on the common (no-VPN) path. The typed helper
; must explicitly return down and the public wrapper must reduce it to boolean.
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
	Seg := _DriverFuncBody("NI_GetVpnStatus")
	Assert(Seg != "", "NI_GetVpnStatus() declaration must exist in network_info.ahk")
	; The function must contain the no-match typed return that follows the
	; `while` walk and precedes the `catch`. Locate the loop close, then assert
	; a down observation appears after it but before the catch handler.
	WhileIdx := InStr(Seg, "while (p) {")
	Assert(WhileIdx > 0, "NI_GetVpnStatus must still iterate adapters with a while (p) loop")
	CatchIdx := InStr(Seg, "} catch {")
	Assert(CatchIdx > WhileIdx, "NI_GetVpnStatus must keep its catch handler after the adapter walk")
	Between := SubStr(Seg, WhileIdx, CatchIdx - WhileIdx)
	Assert(InStr(Between, "return NI_BINARY_STATUS_DOWN") > 0,
		"NI_GetVpnStatus must explicitly return down on the no-VPN path after the adapter walk")
	Wrapper := _DriverFuncBody("NI_IsVpnActive")
	AssertContains(Wrapper, "NI_GetVpnStatus() = NI_BINARY_STATUS_UP",
		"the public port method must reduce the typed observation to a boolean")
}
Test("NetworkInfo: NI_IsVpnActive returns explicit false on no-match path (ni-isvpnactive-missing-return-on-no-match)", _VpnRet_NoMatchPathReturnsFalse)
