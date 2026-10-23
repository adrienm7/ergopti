; tests/meta/modules/updater/test_curl_staging_failure_cleanup.ahk

; ==============================================================================
; MODULE: Managed Staging Failure Cleanup Meta Test
; DESCRIPTION:
; Every CurlAsyncRequest request is staged on disk (the private request input
; and, after admission, the secret body) before the WinHTTP worker starts. A
; failed FSWrite can have left a partial file behind, and its own best-effort
; delete can be denied by a transient scanner lock. Any staging failure throws
; out of _SendManaged into Send, which must abort the request: Abort reaches
; _Cleanup(), which retains retry ownership of the capture.
;
; This is structural because the relevant OS short-write + sharing-violation
; boundary cannot be injected into FSWrite without replacing the production
; filesystem adapter. _DriverSourceNoComments keeps the assertion independent
; of the current adapter path and excludes explanatory prose from the match.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Staging cleanup invariant ==============
; ===================================================
; ===================================================

_CSFC_StagingFailureRetainsCleanupOwner() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the staging cleanup invariant")
	Staging := 'if !FSWrite\(this\.ManagedCapture\["TmpFile"\], Input\)\s*throw Error\("The exact managed request input could not be staged\."\)'
	Assert(RegExMatch(Src, Staging) > 0,
		"a failed managed request-input stage must throw out of _SendManaged (AHK-158)")
	Published := 'if !FSWrite\(StagedPath, PayloadImage\)\s*throw Error\("The exact admitted transport input could not be staged\."\)'
	Assert(RegExMatch(Src, Published) > 0,
		"a failed admitted-body stage must throw into the abort path (AHK-158)")
	Dispatch := 'try return this\._SendManaged\(Body\)\s*catch\s*\{\s*this\._MarkNativeDispatchRefused\(\)\s*if !this\.Aborted\s*this\.Abort\(\)\s*return false\s*\}'
	Assert(RegExMatch(Src, Dispatch) > 0,
		"a staging failure must abort the request so _Cleanup retains the capture (AHK-158)")
}
Test("HTTP transport: failed staging retains cleanup ownership (AHK-158)",
	_CSFC_StagingFailureRetainsCleanupOwner)
