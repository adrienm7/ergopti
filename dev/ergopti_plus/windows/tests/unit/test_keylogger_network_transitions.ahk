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
