; tests/meta/test_curl_staging_failure_cleanup.ahk

; ==============================================================================
; MODULE: Curl Staging Failure Cleanup Meta Test
; DESCRIPTION:
; Every CurlAsyncRequest request body is staged on disk before curl starts. A
; failed FSWrite can have left a partial body behind, and its own best-effort
; delete can be denied by a transient scanner lock. The configuration staging
; branch already delegates this condition to _Cleanup(), which retains retry
; ownership; the body branch used to throw immediately and lost that owner.
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

_CSFC_BodyWriteFailureRetainsCleanupOwner() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the curl staging cleanup invariant")
	Pattern := 'if !FSWrite\(this\.BodyPath, String\(Body\)\)\s*\{\s*this\._Cleanup\(\)\s*throw Error\("Could not stage the asynchronous HTTP request body\."\)\s*\}'
	Assert(RegExMatch(Src, Pattern) > 0,
		"a failed curl body stage must retain _Cleanup ownership before it throws (AHK-158)")
}
Test("HTTP transport: failed body staging retains cleanup ownership (AHK-158)",
	_CSFC_BodyWriteFailureRetainsCleanupOwner)
