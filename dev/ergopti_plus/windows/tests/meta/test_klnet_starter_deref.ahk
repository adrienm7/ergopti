; tests/meta/test_klnet_starter_deref.ahk

; ==============================================================================
; MODULE: KLNet Starter Deref Meta Test
; DESCRIPTION:
; Guards the fix for "too many parameters" crashes in KL_Net_WifiStarter,
; KL_Net_ReachStarter, and KL_Net_VpnStarter.
;
; ROOT CAUSE:
; AHK v2 treats obj.prop() as a method call and passes the object itself as
; the implicit first argument (this). When obj is a class (KLNet) and prop
; holds a BoundFunc that wraps a zero-param function, the implicit this causes
; "too many parameters passed to function". The fix is to dereference the
; BoundFunc into a local variable (fn := KLNet.xxx_fn) and call that local
; (fn()) — the object is then not involved in the call at all.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ============================================
; ======= 1/ Source inspection helpers =======
; ============================================
; ==============================================

_KSD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "\", "/") . "/" . RelPath)
}





; =====================================================
; ===================================================
; ======= 2/ Per-starter deref pattern checks =======
; ===================================================
; =====================================================

_KSD_WifiStarterDerefsBeforeCall() {
	Src  := _KSD_ReadSource("modules/keylogger/keylogger_network.ahk")
	Body := _DriverFuncBody("KL_Net_WifiStarter")
	Assert(Body != "", "KL_Net_WifiStarter must exist in keylogger_network.ahk")
	Assert(InStr(Body, "fn := KLNet.wifi_fn") > 0,
		"KL_Net_WifiStarter must copy the BoundFunc to a local variable before calling")
	Assert(!InStr(Body, "KLNet.wifi_fn()"),
		"KL_Net_WifiStarter must NOT call KLNet.wifi_fn() directly (implicit this crash)")
}
Test("keylogger_network: KL_Net_WifiStarter dereferences BoundFunc before call (klnet-starter-deref)", _KSD_WifiStarterDerefsBeforeCall)

_KSD_ReachStarterDerefsBeforeCall() {
	Src  := _KSD_ReadSource("modules/keylogger/keylogger_network.ahk")
	Body := _DriverFuncBody("KL_Net_ReachStarter")
	Assert(Body != "", "KL_Net_ReachStarter must exist in keylogger_network.ahk")
	Assert(InStr(Body, "fn := KLNet.reach_fn") > 0,
		"KL_Net_ReachStarter must copy the BoundFunc to a local variable before calling")
	Assert(!InStr(Body, "KLNet.reach_fn()"),
		"KL_Net_ReachStarter must NOT call KLNet.reach_fn() directly (implicit this crash)")
}
Test("keylogger_network: KL_Net_ReachStarter dereferences BoundFunc before call (klnet-starter-deref)", _KSD_ReachStarterDerefsBeforeCall)

_KSD_VpnStarterDerefsBeforeCall() {
	Src  := _KSD_ReadSource("modules/keylogger/keylogger_network.ahk")
	Body := _DriverFuncBody("KL_Net_VpnStarter")
	Assert(Body != "", "KL_Net_VpnStarter must exist in keylogger_network.ahk")
	Assert(InStr(Body, "fn := KLNet.vpn_fn") > 0,
		"KL_Net_VpnStarter must copy the BoundFunc to a local variable before calling")
	Assert(!InStr(Body, "KLNet.vpn_fn()"),
		"KL_Net_VpnStarter must NOT call KLNet.vpn_fn() directly (implicit this crash)")
}
Test("keylogger_network: KL_Net_VpnStarter dereferences BoundFunc before call (klnet-starter-deref)", _KSD_VpnStarterDerefsBeforeCall)
