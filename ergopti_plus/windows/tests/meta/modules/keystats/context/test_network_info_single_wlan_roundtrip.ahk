; tests/meta/modules/keystats/context/test_network_info_single_wlan_roundtrip.ahk

; ==============================================================================
; MODULE: NetworkInfo Single WLAN Round-trip Guard
; DESCRIPTION:
; The NetworkInfo port exposes getSsidHash() and getSignalStrength() as two
; independent methods, but both values are read out of the SAME
; WLAN_CONNECTION_ATTRIBUTES buffer (offsets +524 and +576). Before the
; keystats gained a typed one-shot snapshot, its 15 s network tick asked for
; them back to back, and a stateless adapter therefore performed the whole
; WlanOpenHandle -> WlanEnumInterfaces -> WlanQueryInterface -> WlanFreeMemory
; -> WlanCloseHandle sequence twice for one buffer.
;
; WlanOpenHandle is an RPC to the WLAN AutoConfig service and dominates the
; cost. Measured on the maintainer's machine against the real adapter
; (QueryPerformanceCounter, warm, n=10-20): the current pair cost 17.978 ms per
; tick against 9.791 ms for a single query — 8.19 ms, 46 %, of pure duplicated
; work. It is a DllCall on the AHK script thread, which cannot be interrupted
; mid-flight, so a keystroke arriving during it simply waits.
;
; ROOT CAUSE ENCODED: the port shape forces two calls, so the ADAPTER must make
; them share one round-trip. Nothing measured this before — there is no profiler
; segment around the keystats network ticks, so the waste produced no `Slow ...`
; line and looked like nothing at all.
;
; SCOPE: source introspection. The adapter's DllCall paths target live
; wlanapi/iphlpapi hardware, so a behavioural test would assert against whatever
; Wi-Fi the machine happens to have.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ The query is memoised =======
; ========================================
; ========================================

_NISW_QueryIsMemoisedBeforeTheRpc() {
	Body := _DriverFuncBody("_NI_QueryWlan")
	Assert(Body != "", "_NI_QueryWlan() must exist")

	OpenPos := InStr(Body, "WlanOpenHandle")
	TtlPos  := InStr(Body, "NI_WLAN_CACHE_TTL_MS")
	Assert(OpenPos > 0, "prerequisite: _NI_QueryWlan still opens a WLAN client handle")
	Assert(TtlPos > 0,
		"_NI_QueryWlan must serve back-to-back callers from a short-TTL cache — otherwise NI_GetSsidHash and NI_GetSignalStrength each pay their own WlanOpenHandle RPC (9.3 ms) for two fields of one buffer")
	Assert(TtlPos < OpenPos,
		"the freshness test must come BEFORE WlanOpenHandle — a cache consulted after the RPC saves nothing, and the RPC is the whole cost")
}

; A cache that only memoises the SUCCESS path leaves the expensive case — the
; WLAN service not answering — re-paid on every call, which is the opposite of
; what this is for.
_NISW_EveryExitPublishesItsResult() {
	Body := _DriverFuncBody("_NI_QueryWlan")
	Assert(Body != "", "_NI_QueryWlan() must exist")

	Assert(InStr(Body, "_NI_CacheWlanResult(") > 0,
		"_NI_QueryWlan must publish its result through the single caching exit point")
	Assert(InStr(Body, "return result") = 0,
		"no exit of _NI_QueryWlan may return an unpublished result — an early return past the cache leaves the failing query, the expensive one, re-paid on every call")
}





; =========================================================
; =========================================================
; ======= 2/ Both accessors share that single point =======
; =========================================================
; =========================================================

_NISW_BothAccessorsShareTheQuery() {
	Checked := 0
	for Name in ["NI_GetSsidHash", "NI_GetSignalStrength"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		Assert(InStr(Body, "_NI_QueryWlan(") > 0,
			Name . " must read its value through the single cached query point, or the cache it was given cannot help it")
		Assert(InStr(Body, "WlanOpenHandle") = 0,
			Name . " must not open its own WLAN client handle — that is the round-trip the shared query exists to pay exactly once")
		Checked += 1
	}
	Assert(Checked = 2, "both WLAN accessors must be exercised")
}


Test("meta network_info: the WLAN query is memoised before its WlanOpenHandle RPC",
	_NISW_QueryIsMemoisedBeforeTheRpc)
Test("meta network_info: every _NI_QueryWlan exit publishes its result to the cache",
	_NISW_EveryExitPublishesItsResult)
Test("meta network_info: both WLAN accessors share the single cached query point",
	_NISW_BothAccessorsShareTheQuery)

; Regression: NI_ADAPTER_OFFSET_OPER_STATUS was hardcoded to 56 -- wrong on x64 (should be 104)
; and wrong on x86 (should be 68) (network_info.ahk)
TestAuditV5_NetworkInfoDynamicOffsets() {
	Src := _DriverDirConcat("adapters")

	; The bug: NI_ADAPTER_OFFSET_OPER_STATUS := 56 is the DnsSuffix pointer on x64
	; (OperStatus is at offset 104). On x86 OperStatus is at 68. Both were wrong.
	; The fix: ternary expression based on A_PtrSize.
	AssertFalse(
		InStr(Src, "NI_ADAPTER_OFFSET_OPER_STATUS          := 56"),
		"NI_ADAPTER_OFFSET_OPER_STATUS must not be hardcoded to 56 (correct x64 offset is 104)"
	)
	AssertTrue(
		InStr(Src, "A_PtrSize == 8) ? 104 : 68"),
		"NI_ADAPTER_OFFSET_OPER_STATUS must use (A_PtrSize == 8) ? 104 : 68"
	)
	AssertTrue(
		InStr(Src, "A_PtrSize == 8) ? 72  : 40"),
		"NI_ADAPTER_OFFSET_FRIENDLY_NAME must use (A_PtrSize == 8) ? 72 : 40"
	)
}
Test("network info: NI_ADAPTER_OFFSET_OPER_STATUS and FRIENDLY_NAME are dynamic (A_PtrSize ternary)", TestAuditV5_NetworkInfoDynamicOffsets)
