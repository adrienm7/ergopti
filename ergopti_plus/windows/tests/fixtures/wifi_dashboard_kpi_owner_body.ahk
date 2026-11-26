; tests/fixtures/wifi_dashboard_kpi_owner_body.ahk

_KSD_WifiSample() {
	global _KSD
	_KSD.WifiIndex += 1
	return _KSD.WifiSamples[_KSD.WifiIndex]
}

_KSD_WifiReportExercise() {
	global _KSD
	if A_Args[1] == "wifi-report-connectivity-flow"
		return _KSD_WifiConnectivityFlow()
	; This extra exercise bypasses the ordinary _KSD_Exercise initializer.
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	ChangedNetwork := A_Args[1] == "wifi-report-switch"
	_KSD_Acquire({App: "fixture-wifi-report.exe", Title: "Fixture public Wi-Fi report", Hwnd: 301})
	_KSD_Require(KL_Hook_RefreshContext(true) && Keystats._pending_entries.Length == 0,
		"The actual canonical focus gate must initialize without fabricated network history.")
	HashA := CryptoSha256("fixture-network-a")
	HashB := CryptoSha256("fixture-network-b")
	_KSD_Require(RegExMatch(HashA, "^[0-9a-f]{64}$") && RegExMatch(HashB, "^[0-9a-f]{64}$") && HashA != HashB,
		"The native Crypto owner must produce valid distinct SSID fingerprints.")
	FinalHash := ChangedNetwork ? HashB : HashA
	_KSD.WifiSamples := [
		Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashA, "signal_pct", 65),
		Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashA, "signal_pct", 85)]
	if ChangedNetwork
		_KSD.WifiSamples.Push(Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashB, "signal_pct", 85))
	_KSD.WifiSamples.Push(Map("status", NI_WIFI_STATUS_UNKNOWN))
	_KSD.WifiSamples.Push(Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", FinalHash, "signal_pct", 85))
	_KSD.WifiIndex := 0
	KLNet.wifi_snapshot_fn := _KSD_WifiSample
	Loop _KSD.WifiSamples.Length
		KL_Net_WifiTick()
	_KSD_Require(_KSD.WifiIndex == _KSD.WifiSamples.Length && _KSD.Errors == 0,
		"The actual poll must consume every acquisition sample without swallowed exceptions.")
	_KSD_Require(Keystats._pending_entries.Length == (ChangedNetwork ? 3 : 2),
		"The real canonical append must accept baseline, signal and optional SSID transition only.")
	for Row in Keystats._pending_entries {
		_KSD_Require(Row["type"] == "network_change" && Row["app"] == "fixture-wifi-report.exe",
			"Only genuine public Wi-Fi poll rows may reach report reconstruction.")
		; All fields are this fixture's controlled ASCII observations. They are
		; exported unchanged from the real canonical append, not authored by the parent.
		FileAppend("WIFIROW " . Row["_event_id"] . "|" . Row["timestamp"] . "|" . Row["app"]
			. "|" . Row.Get("ssid_hash", "") . "|" . Row.Get("prev_ssid_hash", "")
			. "|" . Row.Get("signal", "") . "|" . Row.Get("connection_state", "") . "`n", "*", "UTF-8")
	}
}


_KSD_WifiConnectivityFlow() {
	global _KSD
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	_KSD_Acquire({App: "fixture-wifi-flow.exe", Title: "Fixture public Wi-Fi connectivity", Hwnd: 303})
	_KSD_Require(KL_Hook_RefreshContext(true) && Keystats._pending_entries.Length == 0,
		"The real canonical context must start without fabricated network history.")
	HashA := CryptoSha256("fixture-flow-network-a"), HashB := CryptoSha256("fixture-flow-network-b")
	_KSD.WifiSamples := [
		Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashA, "signal_pct", 65),
		Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashA, "signal_pct", 85),
		Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashB, "signal_pct", 85),
		Map("status", NI_WIFI_STATUS_UNKNOWN),
		Map("status", NI_WIFI_STATUS_DISCONNECTED),
		Map("status", NI_WIFI_STATUS_UNKNOWN),
		Map("status", NI_WIFI_STATUS_CONNECTED, "ssid_hash", HashB, "signal_pct", 85)]
	_KSD.WifiIndex := 0
	KLNet.wifi_snapshot_fn := _KSD_WifiSample
	Loop _KSD.WifiSamples.Length
		KL_Net_WifiTick()
	_KSD_Require(_KSD.WifiIndex == 7 && _KSD.Errors == 0 && Keystats._pending_entries.Length == 5,
		"The real poll must preserve unknown observations and publish baseline/signal/switch/disconnect/reconnect exactly once.")
	ExpectedPrior := ["unknown", "connected", "connected", "connected", "disconnected"]
	for Index, Row in Keystats._pending_entries {
		_KSD_Require(Row["type"] == "network_change" && Row["app"] == "fixture-wifi-flow.exe"
			&& Row.Get("prev_connection_state", "") == ExpectedPrior[Index],
			"The actual producer must retain its accepted prior connectivity, including a reconnect with no prior hash.")
		FileAppend("WIFIFLOW " . Row["_event_id"] . "|" . Row["timestamp"] . "|" . Row["app"]
			. "|" . Row.Get("ssid_hash", "") . "|" . Row.Get("prev_ssid_hash", "")
			. "|" . Row.Get("signal", "") . "|" . Row.Get("connection_state", "")
			. "|" . Row["prev_connection_state"] . "`n", "*", "UTF-8")
	}
}
