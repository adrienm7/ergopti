; tests/unit/platform/network/test_host_curl_capability.ahk

; ==============================================================================
; MODULE: Host Curl Capability Probe Tests
; DESCRIPTION:
; The probe decides whether an NTLM proxy case runs. Only a well-formed
; receipt without NTLM may stop a case; every malformed or failed observation
; must be "unknown" so the case runs and a real failure stays a failure.
; ==============================================================================

#Requires AutoHotkey v2.0

; Real header and features of the System32 curl 8.21.0 seen on 2026-10-21.
_HCC_HEADER := "curl 8.21.0 (Windows) libcurl/8.21.0 Schannel zlib/1.3.2 WinIDN WinLDAP`r`nRelease-Date: 2026-06-24`r`n"
_HCC_PROTOCOLS := "Protocols: dict file ftp ftps gopher gophers http https imap imaps ldap ldaps pop3 pop3s smtp smtps telnet tftp ws wss`r`n"
_HCC_NO_NTLM := "Features: alt-svc AsynchDNS HSTS HTTPS-proxy IDN IPv6 Kerberos Largefile libz SPNEGO SSL SSPI threadsafe Unicode UnixSockets`r`n"
_HCC_NTLM := "Features: alt-svc AsynchDNS HSTS HTTPS-proxy IDN IPv6 Kerberos Largefile libz NTLM SPNEGO SSL SSPI threadsafe Unicode UnixSockets`r`n"

_HCC_AssertReceipt(State, Version, Receipt, Message) {
	AssertEqual(State, Receipt["state"], Message)
	AssertEqual(Version, Receipt["version"], Message . " (version)")
}

_HCC_WellFormedReceipts() {
	global _HCC_HEADER, _HCC_PROTOCOLS, _HCC_NO_NTLM, _HCC_NTLM
	_HCC_AssertReceipt("no_ntlm", "8.21.0",
		HostCurlParseNtlmCapability(0, _HCC_HEADER . _HCC_PROTOCOLS . _HCC_NO_NTLM, ""),
		"a curl whose Features omit NTLM is positively incapable")
	_HCC_AssertReceipt("ntlm", "8.21.0",
		HostCurlParseNtlmCapability(0, _HCC_HEADER . _HCC_PROTOCOLS . _HCC_NTLM, ""),
		"a curl listing NTLM is capable")
	_HCC_AssertReceipt("ntlm", "8.13.0",
		HostCurlParseNtlmCapability(0, StrReplace(_HCC_HEADER . _HCC_NTLM, "8.21.0", "8.13.0"), ""),
		"LF or CRLF, the version comes from the header")
	; Only the exact token counts: a feature that merely contains the letters does not.
	_HCC_AssertReceipt("no_ntlm", "8.21.0",
		HostCurlParseNtlmCapability(0, _HCC_HEADER . StrReplace(_HCC_NTLM, " NTLM ", " NTLMX "), ""),
		"a longer token is not the NTLM feature")
	; The production capability worker refuses a Features line outside
	; [A-Za-z0-9 -] (an old curl's NTLM_WB), so the probe cannot classify it.
	_HCC_AssertReceipt("unknown", "",
		HostCurlParseNtlmCapability(0, _HCC_HEADER . StrReplace(_HCC_NTLM, " NTLM ", " NTLM NTLM_WB "), ""),
		"a Features line the worker refuses is unknown")
	_HCC_AssertReceipt("no_ntlm", "8.21.0",
		HostCurlParseNtlmCapability(0, _HCC_HEADER . StrReplace(_HCC_NTLM, " NTLM ", " ntlm "), ""),
		"the feature token is case-sensitive, as curl prints it")
}
Test("host curl probe: well-formed version receipts classify NTLM exactly (host-curl-capability)",
	_HCC_WellFormedReceipts)

_HCC_MalformedReceiptsAreUnknown() {
	global _HCC_HEADER, _HCC_PROTOCOLS, _HCC_NO_NTLM
	Cases := Map(
		"nonzero exit", [2, _HCC_HEADER . _HCC_NO_NTLM, ""],
		"stderr", [0, _HCC_HEADER . _HCC_NO_NTLM, "curl: warning"],
		"empty output", [0, "", ""],
		"no Features line", [0, _HCC_HEADER . _HCC_PROTOCOLS, ""],
		"two Features lines", [0, _HCC_HEADER . _HCC_NO_NTLM . _HCC_NO_NTLM, ""],
		"foreign first line", [0, "Microsoft curl`r`n" . _HCC_NO_NTLM, ""],
		"versionless header", [0, "curl (Windows) libcurl Schannel`r`n" . _HCC_NO_NTLM, ""],
		"punctuated Features", [0, _HCC_HEADER . "Features: SSPI, SPNEGO`r`n", ""],
		"empty Features", [0, _HCC_HEADER . "Features: `r`n", ""],
		"non-integer exit", ["0", _HCC_HEADER . _HCC_NO_NTLM, ""],
		"non-string output", [0, 0, ""])
	for Label, Args in Cases
		_HCC_AssertReceipt("unknown", "", HostCurlParseNtlmCapability(Args*),
			"a " . Label . " receipt fails closed to unknown")
}
Test("host curl probe: malformed or failed receipts fail closed to unknown (host-curl-capability)",
	_HCC_MalformedReceiptsAreUnknown)

_HCC_Receipt(State) => Map("state", State, "version", "8.21.0")

; Only a positive no_ntlm receipt ends the case; capable and unknown hosts run it.
_HCC_RequirementOnlyStopsIncapableHosts() {
	Signal := 0
	try TestRequireHostCurlNtlm(_HCC_Receipt.Bind("no_ntlm"))
	catch as Raised
		Signal := Raised
	AssertTrue(Signal is TestNotExecutedSignal, "an incapable host ends the case as not executed")
	AssertEqual("host curl 8.21.0 lists no NTLM; needs the owned SSPI curl (TODO item 62)", Signal.Message)
	for State in ["ntlm", "unknown"]
		AssertEqual("", TestRequireHostCurlNtlm(_HCC_Receipt.Bind(State)),
			"a " . State . " host must run the case")
}
Test("host curl probe: only an incapable host stops a case (host-curl-capability)",
	_HCC_RequirementOnlyStopsIncapableHosts)

; The real System32 binary yields a classified or unknown receipt, observed once.
_HCC_RealProbeIsCached() {
	First := HostCurlNtlmCapability()
	AssertTrue(First is Map, "the real probe returns a receipt")
	State := First["state"]
	AssertTrue(State == "ntlm" || State == "no_ntlm" || State == "unknown", "the receipt state is one of three")
	AssertTrue(State == "unknown" ? First["version"] == "" : RegExMatch(First["version"], "^\d+\.\d+\.\d+$"),
		"a classified receipt names the observed version")
	AssertTrue(HostCurlNtlmCapability() == First, "one observation serves the whole runner")
}
Test("host curl probe: the real System32 curl is observed once per runner (host-curl-capability)",
	_HCC_RealProbeIsCached)
