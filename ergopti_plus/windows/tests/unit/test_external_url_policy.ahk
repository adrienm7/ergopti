; tests/unit/test_external_url_policy.ahk

; ==============================================================================
; MODULE: External URL Policy Tests
; DESCRIPTION:
; Proves that privileged WebView actions cannot launch arbitrary Windows URL
; schemes while valid HTTP(S) links still reach the injected native opener.
; ==============================================================================

_ExternalUrlPolicy_Allowlist() {
	Allowed := [
		"https://example.test/releases",
		"HtTp://example.test/model?q=one#two"
	]
	Blocked := [
		"shortcuts://run-shortcut?name=fixture",
		"file:///C:/fixture.txt",
		"javascript:alert(1)",
		"https:///missing-host",
		"https://safe.example/path`nfile:///C:/fixture.txt",
		123
	]

	Opened := []
	OpenSpy := (Url) => Opened.Push(Url)
	for Url in Blocked {
		AssertFalse(ExternalUrl_OpenHttp(Url, OpenSpy),
			"blocked WebView URL must be refused")
	}
	AssertEqual(0, Opened.Length,
		"a refused URL must never reach the native opener")

	for Url in Allowed {
		AssertTrue(ExternalUrl_OpenHttp(Url, OpenSpy),
			"valid HTTP(S) URL must be accepted: " . Url)
	}
	AssertEqual(Allowed.Length, Opened.Length,
		"every valid HTTP(S) URL must reach the native opener exactly once")
	loop Allowed.Length
		AssertEqual(Allowed[A_Index], Opened[A_Index],
			"the policy must preserve accepted URL bytes")
}
Test("external URL policy: only absolute HTTP(S) reaches the native opener (hs-070)",
	_ExternalUrlPolicy_Allowlist)
