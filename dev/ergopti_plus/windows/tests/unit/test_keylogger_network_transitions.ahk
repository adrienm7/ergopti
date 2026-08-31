; tests/unit/test_keylogger_network_transitions.ahk

; ==============================================================================
; MODULE: Keylogger Wi-Fi Transition Regression Tests
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
		"initialized", Keylogger.initialized,
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
	Keylogger.initialized    := true
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
	Keylogger.initialized  := saved["initialized"]
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


Test("keylogger network: A/disconnected/A emits disconnect and reconnect (AHK-23)",
	_KLNet_DisconnectThenSameSsidReconnects)
Test("keylogger network: A/unknown/A preserves state without false transitions (AHK-23)",
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
		"initialized", Keylogger.initialized,
		"rows", _Stub_AppendLogRows,
		"internet_up", KLNet.internet_up,
		"vpn_active", KLNet.vpn_active,
		"reach_fn", KLNet.reach_status_fn,
		"vpn_fn", KLNet.vpn_status_fn)
	Captured := []
	try {
		Keylogger.initialized := true
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
		Keylogger.initialized := saved["initialized"]
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
		"initialized", Keylogger.initialized,
		"rows", _Stub_AppendLogRows,
		"active", KLAVState.capture_active,
		"exe", KLAVState.capture_exe,
		"snapshot_fn", KLAVState.capture_snapshot_fn)
	Captured := []
	try {
		Keylogger.initialized := true
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
		Keylogger.initialized := saved["initialized"]
		_Stub_AppendLogRows := saved["rows"]
		KLAVState.capture_active := saved["active"]
		KLAVState.capture_exe := saved["exe"]
		KLAVState.capture_snapshot_fn := saved["snapshot_fn"]
	}
}

Test("keylogger network: unknown internet and VPN samples preserve both baselines (probe-unknown-preserves-state)",
	_KLNet_UnknownInternetAndVpnSamplesAreIgnored)
Test("keylogger AV: unknown capture samples preserve both baselines (probe-unknown-preserves-state)",
	_KLAV_UnknownCaptureSamplesAreIgnored)
