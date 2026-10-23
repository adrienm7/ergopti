; tests/unit/platform/network/test_winhttp_transport.ahk
; Real WinHTTP against owned loopback services (no internet, no trust-store
; change). The fixture proves the transport contract the managed requests rely
; on: exact request, bounded response, deadline and retirement, closed failure
; receipts, and proxy authentication with the signed-in user (actual SSPI NTLM
; and Negotiate) without ever answering an origin server.

_WinHttpTransport_ExpectedControls() {
	return [
		"direct_get_exact_target_headers_and_body",
		"post_sends_exact_utf8_body_length",
		"redirects_are_surfaced_never_followed",
		"declared_oversize_refused_before_reading",
		"undeclared_oversize_stops_the_stream_at_the_bound",
		"oversized_headers_refused",
		"silent_server_ends_at_the_deadline_with_retired_handles",
		"slow_body_is_cancelled_at_the_deadline",
		"refused_direct_connection_has_a_closed_receipt_and_no_failover",
		"refused_proxy_before_any_byte_allows_ordered_failover",
		"unresolvable_proxy_has_a_closed_receipt_and_allows_failover",
		"unresolvable_origin_is_a_connect_failure",
		"basic_only_proxy_gets_no_credentials",
		"direct_origin_challenge_is_never_answered",
		"origin_challenge_behind_an_authenticated_proxy_is_never_answered",
		"ntlm_only_proxy_authenticates_the_current_user_over_winhttp",
		"negotiate_proxy_authenticates_the_current_user_over_winhttp",
		"untrusted_certificate_is_refused_with_a_closed_receipt",
		"connect_tunnel_authenticates_then_still_verifies_the_certificate",
		"connect_refusal_is_attributed_to_the_proxy",
		"capability_is_observed_from_the_installed_providers"
	]
}

_WinHttpTransport_Controls() {
	global _DriverDir, _VendorDir, _SharedDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\winhttp_transport_controls.ps1",
				"-TransportPath", _VendorDir . "\ergopti_winhttp_transport.ps1",
				"-SchemaPath", _SharedDir . "\modules\network\managed_network.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 16384)
		AssertTrue(Handle.start(), "the WinHTTP control fixture process must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 120000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the WinHTTP control fixture must finish once within its bound")
		if Observed.Length != 1
			return
		; The fixture names the failing control; carry it into the report.
		AssertEqual(0, Observed[1]["exit"], "fixture output: " . Observed[1]["stdout"] . " | " . Observed[1]["stderr"])
		Lines := StrSplit(StrReplace(Observed[1]["stdout"], "`r`n", "`n"), "`n")
		Expected := _WinHttpTransport_ExpectedControls()
		for Index, Name in Expected
			AssertEqual("CONTROL " . Name, Lines.Has(Index) ? Lines[Index] : "", "control " . Index . " must hold in order")
		AssertEqual("WINHTTP_TRANSPORT_CONTROLS:" . Expected.Length, Lines.Has(Expected.Length + 1) ? Lines[Expected.Length + 1] : "",
			"every expected control must have run")
		AssertEqual("", Observed[1]["stderr"], "the fixture must not write errors")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "the WinHTTP control fixture Job must physically retire")
	}
}
Test("winhttp transport: real WinHTTP honours the managed request contract against owned loopback services", _WinHttpTransport_Controls)
