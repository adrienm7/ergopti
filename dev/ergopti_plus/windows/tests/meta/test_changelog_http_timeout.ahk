; tests/meta/test_changelog_http_timeout.ahk

; ==============================================================================
; MODULE: Changelog HTTP Timeout Meta Test
; DESCRIPTION:
; Static source guard for the "infinite WinHTTP resolve timeout in the changelog
; window" finding (changelog-infinite-resolve-timeout).
;
; ui/changelog_window.ahk previously called:
;   Req.SetTimeouts(0, 10000, 20000, 20000)
; where 0 is the DNS resolution timeout. On a captive-portal network this stalls
; the timer thread indefinitely, blocking every subsequent SetTimer callback and
; freezing all keyboard remapping until the network recovers.
;
; The fix reuses UPDATER_HTTP_RESOLVE_TIMEOUT_MS (5 s) from lib/updater.ahk so
; every WinHTTP call in the driver shares the same finite budget. These tests
; assert the infinite form is gone and the shared constant is used.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Timeout assertions =====================
; ===================================================
; ===================================================

_CLWT_NoInfiniteResolveTimeout() {
	; Move-resilient: scan the ui module tree via the framework helper instead of
	; a pinned changelog path. Both timeout tokens are unique to changelog_window
	; within ui/, so the scope stays meaningful.
	Src := _DriverDirConcat("ui")
	Assert(InStr(Src, "SetTimeouts(0,") = 0,
		"changelog_window.ahk must NOT use SetTimeouts(0,...) — zero resolve timeout hangs the timer thread on captive networks")
}
Test("changelog_window: no infinite WinHTTP resolve timeout (SetTimeouts(0,...))", _CLWT_NoInfiniteResolveTimeout)

_CLWT_UsesSharedResolveConstant() {
	Src := _DriverDirConcat("ui")
	Assert(InStr(Src, "UPDATER_HTTP_RESOLVE_TIMEOUT_MS") > 0,
		"changelog_window.ahk must reference UPDATER_HTTP_RESOLVE_TIMEOUT_MS so all WinHTTP calls share the same finite DNS budget")
}
Test("changelog_window: WinHTTP uses shared UPDATER_HTTP_RESOLVE_TIMEOUT_MS constant", _CLWT_UsesSharedResolveConstant)
