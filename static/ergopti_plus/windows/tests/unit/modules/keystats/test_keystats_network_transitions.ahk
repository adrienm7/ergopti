; tests/unit/modules/keystats/test_keystats_network_transitions.ahk

; ==============================================================================
; MODULE: Keystats Wi-Fi Transition Regression Tests
; DESCRIPTION:
; Proves that a real disconnect clears the accepted SSID state so reconnecting
; to the same network emits a new event, while an unknown adapter result keeps
; the prior state and cannot manufacture a disconnect/reconnect pair. (AHK-23.)
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Deterministic adapter seam =======
; =============================================
; =============================================

class _KLNet_TestSamples {
	static items := []
	static index := 0
}

_KLNet_SetSamples(items) {
	_KLNet_TestSamples.items := items
	_KLNet_TestSamples.index := 0
}

_KLNet_NextSample() {
	_KLNet_TestSamples.index += 1
	return _KLNet_TestSamples.items[_KLNet_TestSamples.index]
}

_KLNet_SaveState() {
	global _Stub_AppendLogRows
	return Map(
		"initialized", Keystats.initialized,
		"rows",        _Stub_AppendLogRows,
		"status",      KLNet.wifi_status,
		"hash",        KLNet.last_ssid_hash,
		"signal",      KLNet.last_signal,
		"active",      KLNet.wifi_poll_active,
		"snapshot_fn", KLNet.wifi_snapshot_fn
	)
}

_KLNet_PrepareSequence(samples) {
	global _Stub_AppendLogRows
	Keystats.initialized    := true
	_Stub_AppendLogRows      := []
	KLNet.wifi_status        := NI_WIFI_STATUS_UNKNOWN
	KLNet.last_ssid_hash     := ""
	KLNet.last_signal        := ""
	KLNet.wifi_poll_active   := false
	KLNet.wifi_snapshot_fn   := _KLNet_NextSample
	_KLNet_SetSamples(samples)
}

_KLNet_RestoreState(saved) {
	global _Stub_AppendLogRows
	Keystats.initialized  := saved["initialized"]
	_Stub_AppendLogRows    := saved["rows"]
	KLNet.wifi_status      := saved["status"]
	KLNet.last_ssid_hash   := saved["hash"]
	KLNet.last_signal      := saved["signal"]
	KLNet.wifi_poll_active := saved["active"]
	KLNet.wifi_snapshot_fn := saved["snapshot_fn"]
}





; ==========================================================
; ==========================================================
; ======= 2/ Disconnect and reconnect are observable =======
; ==========================================================
; ==========================================================

_KLNet_DisconnectThenSameSsidReconnects() {
	global _Stub_AppendLogRows
	saved := _KLNet_SaveState()
	try {
		_KLNet_PrepareSequence([
			Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", "hash-a", "signal_pct", 65),
			Map("status", NI_WIFI_STATUS_DISCONNECTED),
			Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", "hash-a", "signal_pct", 65)
		])

		KL_Net_WifiTick()
		KL_Net_WifiTick()
		KL_Net_WifiTick()

		AssertEqual(3, _Stub_AppendLogRows.Length,
			"A -> disconnected -> same A must emit baseline, disconnect, and reconnect")
		disconnect := _Stub_AppendLogRows[2]
		reconnect  := _Stub_AppendLogRows[3]
		AssertEqual(NI_WIFI_STATUS_DISCONNECTED, disconnect["connection_state"],
			"the second row must identify a proven disconnect")
		AssertEqual("hash-a", disconnect["prev_ssid_hash"],
			"the disconnect must retain the network being left")
		AssertEqual(NI_WIFI_STATUS_CONNECTED, reconnect["connection_state"],
			"the third row must identify the reconnect")
		AssertEqual("hash-a", reconnect["ssid_hash"],
			"the reconnect must publish the newly accepted SSID")
		AssertEqual(NI_WIFI_STATUS_CONNECTED, KLNet.wifi_status,
			"the accepted state must finish connected")
		AssertEqual("hash-a", KLNet.last_ssid_hash,
			"the accepted state must finish on the reconnected SSID")
	} finally {
		_KLNet_RestoreState(saved)
	}
}





; ======================================================
; ======================================================
; ======= 3/ Adapter errors preserve known state =======
; ======================================================
; ======================================================

_KLNet_UnknownThenSameSsidDoesNotReconnect() {
	global _Stub_AppendLogRows
	saved := _KLNet_SaveState()
	try {
		_KLNet_PrepareSequence([
			Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", "hash-a", "signal_pct", 65),
			Map("status", NI_WIFI_STATUS_UNKNOWN),
			Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", "hash-a", "signal_pct", 65)
		])

		KL_Net_WifiTick()
		KL_Net_WifiTick()
		KL_Net_WifiTick()

		AssertEqual(1, _Stub_AppendLogRows.Length,
			"A -> adapter error -> same A must emit only the initial baseline")
		AssertEqual(NI_WIFI_STATUS_CONNECTED, KLNet.wifi_status,
			"an unknown sample must preserve connected state")
		AssertEqual("hash-a", KLNet.last_ssid_hash,
			"an unknown sample must preserve the accepted SSID hash")
		AssertEqual("good", KLNet.last_signal,
			"an unknown sample must preserve the accepted signal bucket")
	} finally {
		_KLNet_RestoreState(saved)
	}
}


Test("keystats network: A/disconnected/A emits disconnect and reconnect (AHK-23)",
	_KLNet_DisconnectThenSameSsidReconnects)
Test("keystats network: A/unknown/A preserves state without false transitions (AHK-23)",
	_KLNet_UnknownThenSameSsidDoesNotReconnect)





; ================================================================
; ================================================================
; ======= 4/ Binary probe failures preserve accepted state =======
; ================================================================
; ================================================================

class _KL_BinaryProbeSamples {
	static items := []
	static index := 0
}

_KL_BinaryProbeSet(items) {
	_KL_BinaryProbeSamples.items := items
	_KL_BinaryProbeSamples.index := 0
}

_KL_BinaryProbeNext() {
	_KL_BinaryProbeSamples.index += 1
	return _KL_BinaryProbeSamples.items[_KL_BinaryProbeSamples.index]
}

_KLNet_AssertUnknownSequence(TickFn, StateOwner, StateName, InitialValue, StableStatus) {
	global _Stub_AppendLogRows
	_Stub_AppendLogRows := []
	StateOwner.%StateName% := InitialValue
	_KL_BinaryProbeSet([NI_BINARY_STATUS_UNKNOWN, StableStatus])
	TickFn.Call()
	AssertEqual(InitialValue, StateOwner.%StateName%,
		"unknown must preserve the prior accepted binary state")
	TickFn.Call()
	AssertEqual(InitialValue, StateOwner.%StateName%,
		"recovery to the same state must remain stable")
	AssertEqual(0, _Stub_AppendLogRows.Length,
		"unknown followed by the same state must emit no false transition")
}

_KLNet_UnknownInternetAndVpnSamplesAreIgnored() {
	global _Stub_AppendLogRows
	saved := Map(
		"initialized", Keystats.initialized,
		"rows", _Stub_AppendLogRows,
		"internet_up", KLNet.internet_up,
		"vpn_active", KLNet.vpn_active,
		"reach_fn", KLNet.reach_status_fn,
		"vpn_fn", KLNet.vpn_status_fn)
	Captured := []
	try {
		Keystats.initialized := true
		KLNet.reach_status_fn := _KL_BinaryProbeNext
		KLNet.vpn_status_fn := _KL_BinaryProbeNext
		LoggerSetTestSink((Line) => Captured.Push(Line))

		_KLNet_AssertUnknownSequence(KL_Net_ReachTick, KLNet, "internet_up",
			true, NI_BINARY_STATUS_UP)
		_KLNet_AssertUnknownSequence(KL_Net_ReachTick, KLNet, "internet_up",
			false, NI_BINARY_STATUS_DOWN)
		_KLNet_AssertUnknownSequence(KL_Net_VpnTick, KLNet, "vpn_active",
			true, NI_BINARY_STATUS_UP)
		_KLNet_AssertUnknownSequence(KL_Net_VpnTick, KLNet, "vpn_active",
			false, NI_BINARY_STATUS_DOWN)

		UnknownLogs := 0
		for Line in Captured {
			if InStr(Line, "state is unknown")
				UnknownLogs += 1
		}
		AssertEqual(2, UnknownLogs,
			"each network/VPN sensor must keep unknown observations diagnostic-visible")
	} finally {
		LoggerClearTestSink()
		Keystats.initialized := saved["initialized"]
		_Stub_AppendLogRows := saved["rows"]
		KLNet.internet_up := saved["internet_up"]
		KLNet.vpn_active := saved["vpn_active"]
		KLNet.reach_status_fn := saved["reach_fn"]
		KLNet.vpn_status_fn := saved["vpn_fn"]
	}
}

_KLAV_UnknownCaptureSamplesAreIgnored() {
	global _Stub_AppendLogRows
	saved := Map(
		"initialized", Keystats.initialized,
		"rows", _Stub_AppendLogRows,
		"active", KLAVState.capture_active,
		"exe", KLAVState.capture_exe,
		"snapshot_fn", KLAVState.capture_snapshot_fn)
	Captured := []
	try {
		Keystats.initialized := true
		KLAVState.capture_snapshot_fn := _KL_BinaryProbeNext
		LoggerSetTestSink((Line) => Captured.Push(Line))

		_Stub_AppendLogRows := []
		KLAVState.capture_active := true
		KLAVState.capture_exe := "obs64.exe"
		_KL_BinaryProbeSet([
			Map("status", KL_AV_CAPTURE_STATUS_UNKNOWN),
			Map("status", KL_AV_CAPTURE_STATUS_ACTIVE, "exe", "obs64.exe")])
		KL_AV_ScanCapture()
		KL_AV_ScanCapture()
		AssertTrue(KLAVState.capture_active)
		AssertEqual("obs64.exe", KLAVState.capture_exe)
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"active/unknown/active must emit no false capture end/start pair")

		KLAVState.capture_active := false
		KLAVState.capture_exe := ""
		_KL_BinaryProbeSet([
			Map("status", KL_AV_CAPTURE_STATUS_UNKNOWN),
			Map("status", KL_AV_CAPTURE_STATUS_INACTIVE)])
		KL_AV_ScanCapture()
		KL_AV_ScanCapture()
		AssertFalse(KLAVState.capture_active)
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"inactive/unknown/inactive must emit no capture transition")

		UnknownLogs := 0
		for Line in Captured {
			if InStr(Line, "Capture-process state is unknown")
				UnknownLogs += 1
		}
		AssertEqual(1, UnknownLogs,
			"unknown capture observations must remain diagnostic-visible")
	} finally {
		LoggerClearTestSink()
		Keystats.initialized := saved["initialized"]
		_Stub_AppendLogRows := saved["rows"]
		KLAVState.capture_active := saved["active"]
		KLAVState.capture_exe := saved["exe"]
		KLAVState.capture_snapshot_fn := saved["snapshot_fn"]
	}
}

Test("keystats network: unknown internet and VPN samples preserve both baselines (probe-unknown-preserves-state)",
	_KLNet_UnknownInternetAndVpnSamplesAreIgnored)
Test("keystats AV: unknown capture samples preserve both baselines (probe-unknown-preserves-state)",
	_KLAV_UnknownCaptureSamplesAreIgnored)


; A later durability failure leaves KL_Stop retryable. Auxiliary Stop calls
; therefore cannot append the same accepted closing row on every retry.
_KLNet_StopClosesOnce(StopFn, Owner, ActiveProperty, NameProperty, EventType) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept
	global _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	SavedActive := Owner.%ActiveProperty%
	SavedName := Owner.%NameProperty%
	TimerProperties := ["wifi_start_fn", "reach_start_fn", "vpn_start_fn",
		"wifi_fn", "reach_fn", "vpn_fn", "warmup_fn", "fast_fn", "slow_fn"]
	SavedTimers := Map()
	for PropertyName in TimerProperties
		if Owner.HasOwnProp(PropertyName)
			SavedTimers[PropertyName] := Owner.%PropertyName%
	try {
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		Owner.%ActiveProperty% := true
		Owner.%NameProperty% := "closing-test"
		AssertTrue(StopFn.Call((*) => 0))
		AssertTrue(StopFn.Call((*) => 0))
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"a repeated shutdown must emit the accepted close exactly once")
		AssertEqual(EventType, _Stub_AppendLogRows[1]["type"])
		AssertFalse(Owner.%ActiveProperty%, "the accepted interval must be retired")
		AssertEqual("", Owner.%NameProperty%, "retired metadata cannot seed another close")
	} finally {
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
		Owner.%ActiveProperty% := SavedActive
		Owner.%NameProperty% := SavedName
		for PropertyName in TimerProperties {
			if SavedTimers.Has(PropertyName)
				Owner.%PropertyName% := SavedTimers[PropertyName]
			else if Owner.HasOwnProp(PropertyName)
				Owner.%PropertyName% := unset
		}
	}
}
Test("keystats network: a shutdown retry closes VPN once (sensor-close-once)",
	_KLNet_StopClosesOnce.Bind(KL_Net_Stop, KLNet, "vpn_active", "vpn_adapter_name", "vpn_disconnected"))
Test("keystats AV: a shutdown retry closes capture once (sensor-close-once)",
	_KLNet_StopClosesOnce.Bind(KL_AV_Stop, KLAVState, "capture_active", "capture_exe", "screen_recording_end"))


_KLNet_CloseAppendHook(Mode, Owner, Entry) {
	if Mode = "reenter" {
		AssertTrue(_KL_StopObservedInterval(Owner, "active", "name", "vpn_disconnected", "adapter"),
			"a committed close must already be retired before a reentrant stop")
		return
	}
	throw Error("injected closing-row failure")
}

_KLNet_CloseOutcome(Mode) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept
	global _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	Owner := {active: true, name: "closing-test"}
	try {
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := Mode != "privacy" && Mode != "throw-before"
		_Stub_AppendLogRejectSuspend := Mode = "suspend"
		_Stub_AppendLogHook := Mode = "throw-before" || Mode = "throw-after" || Mode = "reenter"
			? _KLNet_CloseAppendHook.Bind(Mode, Owner) : 0
		Completed := _KL_StopObservedInterval(Owner, "active", "name", "vpn_disconnected", "adapter")
		AssertEqual(Mode = "privacy" || Mode = "reenter", Completed,
			"privacy is terminal; suspension and technical failures remain retryable")
		AssertEqual(Mode = "suspend" || Mode = "throw-before", Owner.active,
			"an accepted or privacy-dropped close must retire its interval")
		AssertEqual(Mode = "throw-after" || Mode = "reenter" ? 1 : 0, _Stub_AppendLogRows.Length,
			"only an acknowledged append may publish a closing row")

		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		AssertTrue(_KL_StopObservedInterval(Owner, "active", "name", "vpn_disconnected", "adapter"))
		AssertTrue(_KL_StopObservedInterval(Owner, "active", "name", "vpn_disconnected", "adapter"))
		AssertEqual(Mode = "privacy" ? 0 : 1, _Stub_AppendLogRows.Length,
			"retry must publish pending technical debt once and never replay a privacy drop")
		AssertFalse(Owner.active)
		AssertEqual("", Owner.name)
	} finally {
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
	}
}
for _KLNet_CloseMode in ["privacy", "suspend", "throw-before", "throw-after", "reenter"]
	Test("keystats shutdown: closing outcome " . _KLNet_CloseMode . " (sensor-close-once)",
		_KLNet_CloseOutcome.Bind(_KLNet_CloseMode))
