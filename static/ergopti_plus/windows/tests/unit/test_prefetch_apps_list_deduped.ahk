; tests/unit/test_prefetch_apps_list_deduped.ahk

; ==============================================================================
; MODULE: Prefetch App Filter De-duplication (prefetch-live-apps-list-not-deduped)
; DESCRIPTION:
; KLPF_BuildTyping's "live" branch built its app filter by pushing one entry per
; (date, app) cell of the manifest, with no set. The "full" branch twelve lines
; below did guard each push with one. The value is semantically a SET -- it is
; spliced into an SQL `app IN (...)` clause that KLR_BuildTodayIdxJson re-parses
; in eleven SELECTs -- so duplicates select exactly the same rows and buy only
; SQL text and SQLite parse time. The blow-up is days-of-history x apps and it
; grows forever, because nothing prunes agg_app_day: measured on the live store,
; 27 distinct apps became 346 IN terms after 49 days of capture.
;
; It could never be caught downstream: IN ('a','a','b') and IN ('a','b') return
; identical rows, the whole cost sits inside the detached worker process where no
; profiler segment sees it, and the worker's own timing log is written to a file
; that only exists once a dashboard has been opened.
;
; ROOT CAUSE ENCODED: one owner for the app set, called by both branches. A unit
; test on the extracted helper, plus a guard that neither branch may reintroduce
; an inline push loop.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ The helper collapses the grid to a set =======
; =========================================================
; =========================================================

_PALD_ManifestCollapsesToASet() {
	; The same two apps seen on two different days, plus the "Unknown" bucket the
	; filter has always excluded.
	Manifest := Map(
		"2026-01-01", Map("chrome.exe", Map(), "code.exe", Map(), "Unknown", Map()),
		"2026-01-02", Map("chrome.exe", Map(), "code.exe", Map())
	)

	Apps := KLPF_UniqueAppsFromManifest(Manifest)
	Assert(Apps.Length = 2,
		"the app filter is a SET: a manifest listing the same app on N days must yield ONE "
		. "IN term, not N. Got " . Apps.Length . " for 2 distinct apps over 2 days "
		. "(prefetch-live-apps-list-not-deduped)")

	Seen := Map()
	for _, App in Apps
		Seen[App] := true
	Assert(Seen.Has("chrome.exe") && Seen.Has("code.exe"),
		"both distinct apps must survive de-duplication")
	Assert(!Seen.Has("Unknown"),
		'the "Unknown" bucket must stay excluded -- it is not a real app filter term')
}

; Growth must be flat in days, not linear: the defect was invisible on a small
; manifest and only became a 13x blow-up after weeks of history.
_PALD_SetSizeIsIndependentOfHistoryLength() {
	Manifest := Map()
	Loop 60
		Manifest["2026-01-" . Format("{:02}", A_Index)] :=
			Map("chrome.exe", Map(), "code.exe", Map(), "explorer.exe", Map())

	Apps := KLPF_UniqueAppsFromManifest(Manifest)
	Assert(Apps.Length = 3,
		"3 apps over 60 days must still produce 3 IN terms. Got " . Apps.Length . " -- the "
		. "clause is re-built and re-parsed on every ingest tick while a dashboard is open, "
		. "so a per-(date, app) push grows the SQL text forever "
		. "(prefetch-live-apps-list-not-deduped)")
}

Test("prefetch: the manifest app filter collapses to a set (prefetch-live-apps-list-not-deduped)",
	_PALD_ManifestCollapsesToASet)
Test("prefetch: the app filter size does not grow with days of history (prefetch-live-apps-list-not-deduped)",
	_PALD_SetSizeIsIndependentOfHistoryLength)





; ===========================================================
; ===========================================================
; ======= 2/ Neither branch may inline the loop again =======
; ===========================================================
; ===========================================================

; The bug was a duplicated loop that lost its set on the copy. Both branches must
; therefore go through the one helper -- a second inline loop is how they drifted.
_PALD_BothBranchesUseTheHelper() {
	Body := _DriverFuncBody("KLPF_BuildTyping")
	Assert(Body != "", "KLPF_BuildTyping must exist")
	Assert(InStr(Body, "apps_list.Push(") = 0,
		"KLPF_BuildTyping must not build the app filter inline: the live and full branches "
		. "each carried a copy of the loop and only one of them de-duplicated "
		. "(prefetch-live-apps-list-not-deduped)")
	Assert(InStr(Body, "KLPF_UniqueAppsFromManifest(") > 0,
		"both branches must obtain the app filter from KLPF_UniqueAppsFromManifest, so only "
		. "one answer can exist")
}

Test("prefetch: neither KLPF_BuildTyping branch rebuilds the app filter inline (prefetch-live-apps-list-not-deduped)",
	_PALD_BothBranchesUseTheHelper)
