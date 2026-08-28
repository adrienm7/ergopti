; tests/meta/test_password_cache_torn_write.ahk

; ==============================================================================
; MODULE: Password-Cache Torn-Write Guard Meta Test
; DESCRIPTION:
; Static source guard for the "password-cache-torn-write" finding.
;
; The deferred password terminal runs on a separate pseudo-thread from the
; keystroke reader and once wrote the per-HWND password cache in three
; unsynchronised steps with last_hwnd FIRST. An interrupt between the writes
; could expose last_hwnd matched to the new control while last_val still held
; the previous control's verdict - a single-keystroke privacy leak (a password
; char logged) or metric suppression at field transitions.
;
; The fix funnels every cache write through KL_CommitPwCache(hwnd, at, val),
; which uses publish-after-fill ordering: last_val and last_at are written
; first and last_hwnd LAST, so a reader's hwnd-match implies last_val already
; corresponds to that hwnd (last_hwnd is the commit flag). This test pins that
; ordering and the routing of both writers through the helper.
;
; Meta-static because keylogger.ahk registers top-level hooks/timers and cannot
; be #Included by the headless runner without blocking clean exit. If the
; helper is removed, stops writing last_hwnd last, or a writer reverts to a raw
; three-step write, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Publish-after-fill assertions =========
; ==================================================
; ==================================================

_PCTW_CommitHelperWritesHwndLast() {
	Seg := _DriverFuncBody("KL_CommitPwCache")
	Assert(Seg != "", "KL_CommitPwCache(hwnd, at, val) must exist - the single source of truth for password-cache write ordering")
	PosVal  := RegExMatch(Seg, "KLPasswordCache\.last_val\s*:=")
	PosAt   := RegExMatch(Seg, "KLPasswordCache\.last_at\s*:=")
	PosHwnd := RegExMatch(Seg, "KLPasswordCache\.last_hwnd\s*:=")
	Assert(PosVal > 0 && PosAt > 0 && PosHwnd > 0,
		"KL_CommitPwCache must assign last_val, last_at and last_hwnd")
	; last_hwnd is the commit flag - it MUST be assigned after both other fields
	; so a concurrent reader that sees the new hwnd already sees the matching val.
	Assert(PosHwnd > PosVal && PosHwnd > PosAt,
		"KL_CommitPwCache must write last_hwnd LAST (publish-after-fill) - otherwise a reader can match the new hwnd while last_val still holds the previous control's verdict, leaking a password char")
}
Test("keylogger: KL_CommitPwCache writes last_hwnd last (password-cache-torn-write)", _PCTW_CommitHelperWritesHwndLast)

_PCTW_AsyncWriterRoutesThroughCommit() {
	Seg := _DriverFuncBody("KL_OnPasswordWorkerTerminal")
	Assert(Seg != "", "KL_OnPasswordWorkerTerminal must own deferred password publication")
	Assert(InStr(Seg, "KL_CommitPwCache(") > 0,
		"the deferred terminal must commit via KL_CommitPwCache - a raw three-step write with last_hwnd first is the torn-write race")
	; A direct last_hwnd assignment in the async writer means it bypassed the
	; helper and reintroduced the unsynchronised three-step write.
	Assert(!RegExMatch(Seg, "KLPasswordCache\.last_hwnd\s*:="),
		"the deferred terminal must not assign last_hwnd directly - all cache writes go through KL_CommitPwCache so the ordering cannot drift")
}
Test("keylogger: password worker terminal commits via KL_CommitPwCache (password-cache-torn-write)", _PCTW_AsyncWriterRoutesThroughCommit)
