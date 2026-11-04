; tests/meta/modules/keystats/metrics/test_metrics_private_title_memo.ahk

; ==============================================================================
; MODULE: Private-Browsing Title Verdict (metrics-private-title-regex-per-event)
; DESCRIPTION:
; MF_ShouldFilter() is the single chokepoint KL_AppendLog calls before any disk
; I/O, so a wrong verdict means keystrokes from a private window reach the disk.
; It memoizes its pattern scan on the focused title, which only changes when the
; focus refresh publishes a new snapshot.
;
; The memo must not become a correctness hole, so these tests drive the real
; predicate through the focus cache: the verdict follows each title change in both
; directions, the user's toggle wins over a remembered verdict, and
; MF_ShouldFilterFor answers for the title it is given, whatever the live one is.
;
; Only the first test still reads source: sparing the regex calls changes no
; result, so a behaviour test cannot see the memo disappear.
; ==============================================================================

#Requires AutoHotkey v2.0

; One line per case-insensitive heuristic of MF_PRIVATE_TITLE_PATTERNS, in its locales.
global _MFP_PRIVATE_TITLES := ["Site - InPrivate", "Site - Incognito", "Site - Private Browsing",
	"Site (Private)", "Site - Navigation privée", "Site - Privé", "Site - Privater Modus"]





; =====================================================================
; =====================================================================
; ======= 1/ The scan is memoized on the title ========================
; =====================================================================
; =====================================================================

_MFP_ScanIsMemoizedOnTheTitle() {
	Body := _DriverFuncBody("MF_ShouldFilter")
	GuardPos := InStr(Body, "title !== memo.title")
	LoopPos := InStr(Body, "for _, pat in MF_PRIVATE_TITLE_PATTERNS")
	Assert(LoopPos > 0, "MF_ShouldFilter must scan MF_PRIVATE_TITLE_PATTERNS")
	Assert(GuardPos > 0 and GuardPos < LoopPos,
		"the pattern loop must sit behind a title-change guard: seven RegExMatch calls per keystroke re-derive a value that only changes when the focus refresh publishes a new title")
}
Test("metrics_filters: the private-browsing title scan is memoized (metrics-private-title-regex-per-event)",
	_MFP_ScanIsMemoizedOnTheTitle)





; ======================================================================
; ======================================================================
; ======= 2/ The verdict follows the title and the user's choice =======
; ======================================================================
; ======================================================================

; Runs Body with only the private-browsing filter on and event-driven refresh off,
; so the snapshot under test is the one MF_ShouldFilter reads.
_MFP_WithFilters(Body) {
	SavedState := MetricsFocusCache.state
	SavedEventMode := MetricsFocusCache.event_mode
	SavedDisabledApps := MetricsFilters.disabled_apps
	SavedPrivate := MetricsFilters.private_browsing
	SavedSecure := MetricsFilters.secure_field
	SavedSystemAuth := MetricsFilters.system_auth
	try {
		MetricsFocusCache.event_mode := false
		MetricsFilters.disabled_apps := Map()
		MetricsFilters.private_browsing := true
		MetricsFilters.secure_field := false
		MetricsFilters.system_auth := false
		Body.Call()
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFocusCache.event_mode := SavedEventMode
		MetricsFilters.disabled_apps := SavedDisabledApps
		MetricsFilters.private_browsing := SavedPrivate
		MetricsFilters.secure_field := SavedSecure
		MetricsFilters.system_auth := SavedSystemAuth
	}
}

_MFP_Focus(Title) {
	MetricsFocusCache.state := {valid: true, last_at: 0, hwnd: 0, process_name: "browser.exe",
		title: Title, class: "BrowserHost", failure_reason: "", timed_out: false}
}

_MFP_VerdictFollowsTheTitle() {
	_MFP_WithFilters(() => (
		_MFP_Focus("Ordinary page"),
		AssertFalse(MF_ShouldFilter(), "an ordinary title is kept"),
		_MFP_Focus("Secret - InPrivate"),
		AssertTrue(MF_ShouldFilter(), "the new private title must not inherit the ordinary verdict"),
		AssertTrue(MF_ShouldFilter(), "the remembered verdict answers the same title"),
		_MFP_Focus("Ordinary page"),
		AssertFalse(MF_ShouldFilter(), "leaving the private window must not keep filtering"),
		0))
}
Test("metrics_filters: the private verdict follows every title change (metrics-private-title-regex-per-event)",
	_MFP_VerdictFollowsTheTitle)

_MFP_ToggleWinsOverTheMemo() {
	_MFP_WithFilters(() => (
		_MFP_Focus("Secret - InPrivate"),
		AssertTrue(MF_ShouldFilter(), "the filter on: the private title is dropped"),
		MetricsFilters.private_browsing := false,
		AssertFalse(MF_ShouldFilter(), "a remembered private verdict must not survive the user switching the filter off"),
		MetricsFilters.private_browsing := true,
		AssertTrue(MF_ShouldFilter(), "switching it back applies at once"),
		0))
}
Test("metrics_filters: the user's toggle wins over the remembered verdict (metrics-private-title-regex-per-event)",
	_MFP_ToggleWinsOverTheMemo)

; It is handed the OUTGOING window of a switch, so the live focus must not answer.
_MFP_OutgoingVariantIgnoresTheLiveFocus() {
	_MFP_WithFilters(() => (
		_MFP_Focus("Secret - InPrivate"),
		AssertTrue(MF_ShouldFilter(), "the live title is private"),
		AssertFalse(MF_ShouldFilterFor("browser.exe", "Ordinary page"), "an ordinary outgoing title stays ordinary"),
		_MFP_Focus("Ordinary page"),
		AssertFalse(MF_ShouldFilter(), "the live title is ordinary"),
		AssertTrue(MF_ShouldFilterFor("browser.exe", "Secret - InPrivate"), "a private outgoing title stays private"),
		0))
}
Test("metrics_filters: the outgoing-context variant does not reuse the live-focus memo (metrics-private-title-regex-per-event)",
	_MFP_OutgoingVariantIgnoresTheLiveFocus)





; =====================================================================
; =====================================================================
; ======= 3/ No pattern was dropped in the name of speed ==============
; =====================================================================
; =====================================================================

; The cheapest way to "fix" seven regexes per event is to delete some of them. A
; false positive only means logging less, the safe direction, so every locale stays.
_MFP_EveryPatternSurvived() {
	global _MFP_PRIVATE_TITLES
	_MFP_WithFilters(() => _MFP_AssertEveryTitleFiltered(_MFP_PRIVATE_TITLES))
}
_MFP_AssertEveryTitleFiltered(Titles) {
	for Title in Titles {
		_MFP_Focus(Title)
		AssertTrue(MF_ShouldFilter(), "a private window was kept: " . Title)
		AssertTrue(MF_ShouldFilterFor("browser.exe", Title), "an outgoing private window was kept: " . Title)
	}
}
Test("metrics_filters: no private-browsing pattern was dropped for speed (metrics-private-title-regex-per-event)",
	_MFP_EveryPatternSurvived)
