; tests/fixtures/wifi_dashboard_kpi_owner_body.ahk

_KSD_WifiSample() {
	global _KSD
	_KSD.WifiIndex += 1
	return _KSD.WifiSamples[_KSD.WifiIndex]
}

_KSD_WifiReportExercise() {
	global _KSD
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
