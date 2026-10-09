; tests/unit/test_managed_remote_sspi.ahk
; Actual buffered remote POST over the existing common owned curl transport.
; SSPI, full-URL PAC and ordered proxy fallback are native conjunctions here.

class _ManagedRemoteSspiTlsOwner extends _ManagedRemoteFixtureOwner {
	__New() {
		super.__New()
		this.NtlmProxy := 0
		this.OrderedPac := false
	}
	ReadConfig() {
		if !IsObject(this.NtlmProxy)
			return super.ReadConfig()
		Port := this.NtlmProxy.State["port"]
		return Map("auto_detect", false,
			"pac_url", this.OrderedPac ? "http://127.0.0.1:" . Port . "/remote-ordered.pac" : "",
			"proxy", this.OrderedPac ? "" : "127.0.0.1:" . Port, "bypass", "")
	}
}

_ManagedRemote_ActualPostSspiAndOrderedRoutes(OrderedPac := false) {
	Fixture := _ManagedRemoteSspiTlsOwner()
	Proxy := 0
	try {
		Fixture.Start()
		Fixture.ChangeTrust(true)
		Proxy := _ArtifactNtlmProxyOwner(Fixture, "NtlmOnly", OrderedPac)
		Proxy.Start()
		Fixture.NtlmProxy := Proxy
		Fixture.OrderedPac := OrderedPac
		; CheckGeneration calls the real remote dispatcher, reservation, POST,
		; provider headers/body, bounded worker and response parser. Only the
		; user's settings reader points at these owned native fixture services.
		Fixture.CheckGeneration(true)
		Fixture.Observe()
		AssertEqual(1, Fixture.State["Requests"], "only one accepted native TLS request reaches the provider")
		AssertEqual(1, Fixture.State["Generations"], "exact original POST body reaches the owned origin once")
		AssertTrue(Fixture.State["CrlRequests"] >= 1, "actual remote POST retains strict Schannel revocation checking")
		Proxy.Close()
		AssertEqual(1, Proxy.State.Get("type_one", -1), "one causal native NTLM successor for the owned remote request")
		AssertEqual(1, Proxy.State.Get("type_three", -1), "actual native Type2 leads to one SSPI Type3")
		AssertEqual(1, Proxy.State.Get("authenticated", -1), "Windows SSPI accepts the current-user proxy identity")
		AssertTrue(Proxy.State.Get("identity_matched", false), "actual native context identity matches without serialization")
		if OrderedPac {
			AssertTrue(Proxy.State.Get("pac_requests", 0) >= 2, "actual configured full-URL PAC is freshly fetched again after capability observation")
			AssertTrue(Proxy.State.Get("refused_route_verified", false), "the exclusive non-listening first PAC route actually refuses native TCP")
		} else
			AssertEqual(0, Proxy.State.Get("pac_requests", -1), "fixed routing performs no invented PAC lookup")
		Proxy := 0
	} finally {
		try {
			if IsObject(Proxy)
				Proxy.Close()
		} finally {
			Closed := Fixture.Close()
			if !Closed
				Fixture.RetainCleanup()
			AssertTrue(Closed, "actual remote request, native services, exact root and private captures retire")
			if Fixture.RootThumbprint != "" {
				AssertTrue(Fixture.RootRemovalVerified, "independent exact-thumbprint removal is acknowledged")
				AssertTrue(Fixture.GracefulReceiptVerified, "physical native service closure has its own receipt")
			}
		}
	}
}
Test("managed remote: actual buffered POST shares native SSPI NTLM curl ownership", _ManagedRemote_ActualPostSspiAndOrderedRoutes)
Test("managed remote: actual full-URL PAC keeps ordered closed-proxy, SSPI relay and DIRECT fallback", _ManagedRemote_ActualPostSspiAndOrderedRoutes.Bind(true))
