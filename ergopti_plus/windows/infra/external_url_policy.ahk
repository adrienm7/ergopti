; infra/external_url_policy.ahk

; ==============================================================================
; MODULE: External URL Policy
; DESCRIPTION:
; Owns the native allowlist for URLs received from privileged WebView bridges.
; Frontend checks are not a security boundary: only absolute HTTP and HTTPS
; URLs may reach the system shell.
; ==============================================================================

ExternalUrl_IsHttp(Url) {
	if !(Url is String)
		return false
	return RegExMatch(Url, "i)^https?://[^/?#\s\x00-\x1F\x7F][^\s\x00-\x1F\x7F]*$") > 0
}

ExternalUrl_OpenHttp(Url, RunFn := 0) {
	if !ExternalUrl_IsHttp(Url) {
		LoggerWarn("ExternalUrl", "Refusing external URL: only absolute HTTP and HTTPS URLs are allowed.")
		return false
	}

	try {
		if IsObject(RunFn)
			RunFn.Call(Url)
		else
			Run(Url)
	} catch {
		LoggerError("ExternalUrl", "Failed to open a validated external HTTP URL.")
		return false
	}
	return true
}
