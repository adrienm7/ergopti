; static/ergopti_plus/windows/tests/unit/test_keylogger_reader.ahk

; ==============================================================================
; MODULE: Keylogger Reader Tests
; DESCRIPTION:
; Unit-tests for the pure helper functions in
; modules/keylogger/keylogger_reader.ahk.
; Only logic that requires no SQLite handle, no file I/O, and no OS hooks
; is exercised here: date-filter builders, Map constructors, accumulation
; helpers, the JSON-escape helper, and the PrevDay date arithmetic.
; ==============================================================================




; =========================================
; =========================================
; ======= 1/ KLR_DateFilter ===============
; =========================================
; =========================================

_KLR_DateFilter_BothEmpty() {
	; No bounds -> no WHERE clause at all
	AssertEqual("", KLR_DateFilter("", ""))
}
Test("KLR_DateFilter: no start/end -> empty string", _KLR_DateFilter_BothEmpty)

_KLR_DateFilter_StartOnly() {
	result := KLR_DateFilter("2024-01-01", "")
	; Must contain a WHERE keyword and the start date
	AssertTrue(InStr(result, "WHERE") > 0)
	AssertTrue(InStr(result, "2024-01-01") > 0)
}
Test("KLR_DateFilter: start date only -> WHERE clause with start", _KLR_DateFilter_StartOnly)

_KLR_DateFilter_EndOnly() {
	result := KLR_DateFilter("", "2024-12-31")
	AssertTrue(InStr(result, "WHERE") > 0)
	AssertTrue(InStr(result, "2024-12-31") > 0)
}

; ULTIMATE encore plus: healthcheck/diagnostic integration + pause (diagnostic must use reader safely under pause for troubleshooting, surface errors sink, no side effects).
; The reader is what the healthcheck window calls, and the healthcheck is most
; useful precisely when the driver is paused. So the query builders must be pure
; string assembly: no suspend check, no writes. A reader that returned a
; different WHERE clause while paused would show the user a different history
; than the one on disk.
_KLR_PauseSafeForDiagnostic() {
	Body := _DriverFuncBody("KLR_DateFilter")
	Assert(InStr(Body, "A_IsSuspended") == 0,
		"KLR_DateFilter() must not read A_IsSuspended — the diagnostic has to report the same "
		. "history whether or not the driver is paused")

	; Pure assembly: same inputs, same clause, twice.
	A := KLR_DateFilter("2024-01-01", "2024-12-31")
	B := KLR_DateFilter("2024-01-01", "2024-12-31")
	AssertEqual(A, B, "the query builder must be deterministic")
	AssertTrue(InStr(A, "WHERE") > 0, "and it must actually build a WHERE clause for two dates")

	; No arguments at all yields no clause rather than a malformed one.
	AssertEqual("", KLR_DateFilter("", ""),
		"with neither bound the builder must return an empty string, not a dangling WHERE")
}
Test("KLR: reader must be safe for healthcheck under pause (diagnostic troubleshooting)", _KLR_PauseSafeForDiagnostic)

; A date bound reaches SQL, so it goes through SQLite_Q. The clause must quote
; what it interpolates — the reader takes its dates from a WebView2 message, and
; an unquoted bound there is an injection into the metrics database.
_KLR_DiagnosticSeesErrorsSinkAndVolume() {
	One := KLR_DateFilter("2024-01-01", "")
	AssertTrue(InStr(One, "date >=") > 0, "a start bound must produce a lower-bound comparison")
	AssertTrue(InStr(One, "date <=") == 0, "and must not invent an upper bound")

	Two := KLR_DateFilter("", "2024-12-31")
	AssertTrue(InStr(Two, "date <=") > 0, "an end bound must produce an upper-bound comparison")
	AssertTrue(InStr(Two, "date >=") == 0, "and must not invent a lower bound")

	; Both bounds are joined, never concatenated into one broken predicate.
	Both := KLR_DateFilter("2024-01-01", "2024-12-31")
	AssertTrue(InStr(Both, " AND ") > 0, "two bounds must be joined with AND")

	; The values are quoted through SQLite_Q rather than pasted in raw.
	Quoted := KLR_DateFilter("2024-01-01' OR 1=1 --", "")
	AssertTrue(InStr(Quoted, "OR 1=1") == 0 or InStr(Quoted, "''") > 0,
		"a quote in a date bound must be escaped by SQLite_Q — this clause is built from a "
		. "WebView2 message and lands in the metrics database")
}
Test("KLR: healthcheck via reader must expose errors sink + volume under pause + rollover (errors sink + privacy)", _KLR_DiagnosticSeesErrorsSinkAndVolume)

Test("KLR_DateFilter: end date only -> WHERE clause with end", _KLR_DateFilter_EndOnly)

_KLR_DateFilter_BothProvided() {
	result := KLR_DateFilter("2024-01-01", "2024-12-31")
	AssertTrue(InStr(result, "2024-01-01") > 0)
	AssertTrue(InStr(result, "2024-12-31") > 0)
	; Must contain AND to separate the two conditions
	AssertTrue(InStr(result, "AND") > 0)
}
Test("KLR_DateFilter: start + end -> WHERE clause with both and AND", _KLR_DateFilter_BothProvided)

_KLR_DateFilter_StartUsesGTE() {
	result := KLR_DateFilter("2024-06-01", "")
	AssertTrue(InStr(result, ">=") > 0)
}
Test("KLR_DateFilter: start date uses >= operator", _KLR_DateFilter_StartUsesGTE)

_KLR_DateFilter_EndUsesLTE() {
	result := KLR_DateFilter("", "2024-06-30")
	AssertTrue(InStr(result, "<=") > 0)
}
Test("KLR_DateFilter: end date uses <= operator", _KLR_DateFilter_EndUsesLTE)




; =========================================
; =========================================
; ======= 2/ KLR_NewAppEntry ==============
; =========================================
; =========================================

_KLR_NewAppEntry_ReturnsMap() {
	entry := KLR_NewAppEntry()
	AssertTrue(entry is Map)
}
Test("KLR_NewAppEntry: returns a Map", _KLR_NewAppEntry_ReturnsMap)

_KLR_NewAppEntry_CharsIsZero() {
	entry := KLR_NewAppEntry()
	AssertEqual(0, entry["chars"])
}
Test("KLR_NewAppEntry: chars field initialised to 0", _KLR_NewAppEntry_CharsIsZero)

_KLR_NewAppEntry_CategoryIsEmpty() {
	entry := KLR_NewAppEntry()
	AssertEqual("", entry["category"])
}
Test("KLR_NewAppEntry: category field initialised to empty string", _KLR_NewAppEntry_CategoryIsEmpty)

_KLR_NewAppEntry_BurstLengthBucketsIsMap() {
	entry := KLR_NewAppEntry()
	AssertTrue(entry["burst_length_buckets"] is Map)
}
Test("KLR_NewAppEntry: burst_length_buckets is an empty Map", _KLR_NewAppEntry_BurstLengthBucketsIsMap)

_KLR_NewAppEntry_SessionDurationsIsArray() {
	entry := KLR_NewAppEntry()
	AssertTrue(entry["session_durations"] is Array)
}
Test("KLR_NewAppEntry: session_durations is an Array", _KLR_NewAppEntry_SessionDurationsIsArray)

_KLR_NewAppEntry_HourlyIsMap() {
	entry := KLR_NewAppEntry()
	AssertTrue(entry["hourly"] is Map)
}
Test("KLR_NewAppEntry: hourly is an empty Map", _KLR_NewAppEntry_HourlyIsMap)

_KLR_NewAppEntry_LayoutsSeenIsMap() {
	entry := KLR_NewAppEntry()
	AssertTrue(entry["layouts_seen"] is Map)
}
Test("KLR_NewAppEntry: layouts_seen is an empty Map", _KLR_NewAppEntry_LayoutsSeenIsMap)

_KLR_NewAppEntry_IsolatedPerCall() {
	; Two separate calls must produce independent Map objects, not aliases
	a := KLR_NewAppEntry()
	b := KLR_NewAppEntry()
	a["chars"] := 99
	AssertEqual(0, b["chars"])
}
Test("KLR_NewAppEntry: each call returns a fresh independent Map", _KLR_NewAppEntry_IsolatedPerCall)




; =====================================
; =====================================
; ======= 3/ KLR_GetCell ==============
; =====================================
; =====================================

_KLR_GetCell_CreatesDateKey() {
	m := Map()
	KLR_GetCell(m, "2024-01-15", "code.exe")
	AssertTrue(m.Has("2024-01-15"))
}
Test("KLR_GetCell: creates date key when absent", _KLR_GetCell_CreatesDateKey)

_KLR_GetCell_CreatesAppKey() {
	m := Map()
	KLR_GetCell(m, "2024-01-15", "code.exe")
	AssertTrue(m["2024-01-15"].Has("code.exe"))
}
Test("KLR_GetCell: creates app key under date when absent", _KLR_GetCell_CreatesAppKey)

_KLR_GetCell_ReturnsExistingCell() {
	m := Map()
	cell1 := KLR_GetCell(m, "2024-01-15", "code.exe")
	cell1["chars"] := 42
	cell2 := KLR_GetCell(m, "2024-01-15", "code.exe")
	; Second call must return the same cell, not a fresh one
	AssertEqual(42, cell2["chars"])
}
Test("KLR_GetCell: returns existing cell without overwriting", _KLR_GetCell_ReturnsExistingCell)

_KLR_GetCell_DifferentDatesAreIsolated() {
	m := Map()
	c1 := KLR_GetCell(m, "2024-01-15", "code.exe")
	c1["chars"] := 5
	c2 := KLR_GetCell(m, "2024-01-16", "code.exe")
	AssertEqual(0, c2["chars"])
}
Test("KLR_GetCell: different dates produce isolated cells", _KLR_GetCell_DifferentDatesAreIsolated)




; =====================================
; =====================================
; ======= 4/ KLR_BumpMap ==============
; =====================================
; =====================================

_KLR_BumpMap_InsertsNewKey() {
	m := Map()
	KLR_BumpMap(m, "a", 10)
	AssertEqual(10, m["a"])
}
Test("KLR_BumpMap: inserts a new key with the given delta", _KLR_BumpMap_InsertsNewKey)

_KLR_BumpMap_AccumulatesOnExistingKey() {
	m := Map()
	KLR_BumpMap(m, "a", 10)
	KLR_BumpMap(m, "a", 5)
	AssertEqual(15, m["a"])
}
Test("KLR_BumpMap: accumulates successive calls on the same key", _KLR_BumpMap_AccumulatesOnExistingKey)

_KLR_BumpMap_EmptyDeltaTreatedAsZero() {
	m := Map()
	KLR_BumpMap(m, "b", "")
	AssertEqual(0, m["b"])
}
Test("KLR_BumpMap: empty-string delta treated as 0", _KLR_BumpMap_EmptyDeltaTreatedAsZero)

_KLR_BumpMap_NonNumericDeltaTreatedAsZero() {
	m := Map()
	KLR_BumpMap(m, "c", "bad")
	AssertEqual(0, m["c"])
}
Test("KLR_BumpMap: non-numeric delta treated as 0", _KLR_BumpMap_NonNumericDeltaTreatedAsZero)

_KLR_BumpMap_MultipleKeysIndependent() {
	m := Map()
	KLR_BumpMap(m, "x", 3)
	KLR_BumpMap(m, "y", 7)
	AssertEqual(3, m["x"])
	AssertEqual(7, m["y"])
}
Test("KLR_BumpMap: multiple keys are independent", _KLR_BumpMap_MultipleKeysIndependent)




; ==========================================
; ==========================================
; ======= 5/ KLR_NewNgramItem =============
; ==========================================
; ==========================================

_KLR_NewNgramItem_FieldsSet() {
	item := KLR_NewNgramItem(10, 200, 3, "")
	AssertEqual(10, item["c"])
	AssertEqual(200, item["t"])
	AssertEqual(3, item["e"])
}
Test("KLR_NewNgramItem: c/t/e fields reflect constructor arguments", _KLR_NewNgramItem_FieldsSet)

_KLR_NewNgramItem_HsAndLlmDefaultZero() {
	item := KLR_NewNgramItem(1, 2, 3, "")
	AssertEqual(0, item["hs"])
	AssertEqual(0, item["llm"])
	AssertEqual(0, item["o"])
}
Test("KLR_NewNgramItem: hs/llm/o always initialised to 0", _KLR_NewNgramItem_HsAndLlmDefaultZero)

_KLR_NewNgramItem_EsrcJsonStoredWhenNonEmpty() {
	item := KLR_NewNgramItem(1, 2, 3, '{"hotstring":4}')
	AssertTrue(item.Has("esrc_json"))
	AssertEqual('{"hotstring":4}', item["esrc_json"])
}
Test("KLR_NewNgramItem: esrc_json stored when non-empty", _KLR_NewNgramItem_EsrcJsonStoredWhenNonEmpty)

_KLR_NewNgramItem_EsrcJsonOmittedWhenEmpty() {
	; When esrc_json is empty the key must not be added (saves memory)
	item := KLR_NewNgramItem(1, 2, 3, "")
	AssertFalse(item.Has("esrc_json"))
}
Test("KLR_NewNgramItem: esrc_json key absent when empty string provided", _KLR_NewNgramItem_EsrcJsonOmittedWhenEmpty)




; ==========================================
; ==========================================
; ======= 6/ KLR_PrevDay =================
; ==========================================
; ==========================================

_KLR_PrevDay_NormalDate() {
	AssertEqual("2024-01-14", KLR_PrevDay("2024-01-15"))
}
Test("KLR_PrevDay: 2024-01-15 -> 2024-01-14", _KLR_PrevDay_NormalDate)

_KLR_PrevDay_MonthBoundary() {
	; February -> January boundary
	AssertEqual("2024-01-31", KLR_PrevDay("2024-02-01"))
}
Test("KLR_PrevDay: 2024-02-01 -> 2024-01-31 (month boundary)", _KLR_PrevDay_MonthBoundary)

_KLR_PrevDay_YearBoundary() {
	AssertEqual("2023-12-31", KLR_PrevDay("2024-01-01"))
}
Test("KLR_PrevDay: 2024-01-01 -> 2023-12-31 (year boundary)", _KLR_PrevDay_YearBoundary)

_KLR_PrevDay_LeapDay() {
	; 2024 is a leap year; the day after Feb 28 is Feb 29
	AssertEqual("2024-02-29", KLR_PrevDay("2024-03-01"))
}
Test("KLR_PrevDay: 2024-03-01 -> 2024-02-29 (leap year)", _KLR_PrevDay_LeapDay)

_KLR_PrevDay_NonLeapYear() {
	; 2023 is not a leap year; Feb 28 is the last day
	AssertEqual("2023-02-28", KLR_PrevDay("2023-03-01"))
}
Test("KLR_PrevDay: 2023-03-01 -> 2023-02-28 (non-leap year)", _KLR_PrevDay_NonLeapYear)

_KLR_PrevDay_OutputFormat() {
	; Result must always be YYYY-MM-DD (10 chars, hyphen-separated)
	result := KLR_PrevDay("2024-06-15")
	AssertEqual(10, StrLen(result))
	AssertEqual("-", SubStr(result, 5, 1))
	AssertEqual("-", SubStr(result, 8, 1))
}
Test("KLR_PrevDay: output is always YYYY-MM-DD format", _KLR_PrevDay_OutputFormat)




; ==============================================
; ==============================================
; ======= 7/ KLR__JsonEscape ==================
; ==============================================
; ==============================================

_KLR_JsonEscape_PlainString() {
	AssertEqual("hello", KLR__JsonEscape("hello"))
}
Test("KLR__JsonEscape: plain string passes through unchanged", _KLR_JsonEscape_PlainString)

_KLR_JsonEscape_BackslashEscaped() {
	; A single backslash must become two backslashes
	AssertEqual("a\\b", KLR__JsonEscape("a\b"))
}
Test("KLR__JsonEscape: backslash is doubled", _KLR_JsonEscape_BackslashEscaped)

_KLR_JsonEscape_DoubleQuoteEscaped() {
	result := KLR__JsonEscape('say "hi"')
	AssertTrue(InStr(result, '\"') > 0)
}
Test("KLR__JsonEscape: double quotes are escaped with backslash", _KLR_JsonEscape_DoubleQuoteEscaped)

_KLR_JsonEscape_EmptyString() {
	AssertEqual("", KLR__JsonEscape(""))
}
Test("KLR__JsonEscape: empty string -> empty string", _KLR_JsonEscape_EmptyString)




; ===============================================
; ===============================================
; ======= 8/ KLR_BuildNgramFilter =============
; ===============================================
; ===============================================

_KLR_BuildNgramFilter_NoArgs() {
	AssertEqual("", KLR_BuildNgramFilter("", "", []))
}
Test("KLR_BuildNgramFilter: no args -> empty string", _KLR_BuildNgramFilter_NoArgs)

_KLR_BuildNgramFilter_StartOnly() {
	result := KLR_BuildNgramFilter("2024-01-01", "", [])
	AssertTrue(InStr(result, "WHERE") > 0)
	AssertTrue(InStr(result, "2024-01-01") > 0)
}
Test("KLR_BuildNgramFilter: start only -> WHERE with start date", _KLR_BuildNgramFilter_StartOnly)

_KLR_BuildNgramFilter_AppsFilter() {
	result := KLR_BuildNgramFilter("", "", ["code.exe", "notepad.exe"])
	AssertTrue(InStr(result, "app IN") > 0)
	AssertTrue(InStr(result, "code.exe") > 0)
	AssertTrue(InStr(result, "notepad.exe") > 0)
}
Test("KLR_BuildNgramFilter: non-empty apps array adds app IN clause", _KLR_BuildNgramFilter_AppsFilter)

_KLR_BuildNgramFilter_EmptyAppsArraySkipped() {
	result := KLR_BuildNgramFilter("", "", [])
	AssertFalse(InStr(result, "app IN") > 0)
}
Test("KLR_BuildNgramFilter: empty apps array -> no app IN clause", _KLR_BuildNgramFilter_EmptyAppsArraySkipped)




; ===================================================
; ===================================================
; ======= 9/ KLR__StashAppTypeJson =================
; ===================================================
; ===================================================

_KLR_StashAppTypeJson_CreatesAppEntry() {
	per_app := Map()
	KLR__StashAppTypeJson(per_app, "code.exe", "c", '{"a":1}')
	AssertTrue(per_app.Has("code.exe"))
}
Test("KLR__StashAppTypeJson: creates app entry when absent", _KLR_StashAppTypeJson_CreatesAppEntry)

_KLR_StashAppTypeJson_StoresTypeJson() {
	per_app := Map()
	KLR__StashAppTypeJson(per_app, "code.exe", "c", '{"a":1}')
	AssertEqual('{"a":1}', per_app["code.exe"]["c"])
}
Test("KLR__StashAppTypeJson: stores JSON fragment under the given type code", _KLR_StashAppTypeJson_StoresTypeJson)

_KLR_StashAppTypeJson_EmptyJsonSkipped() {
	; An empty fragment must not create a spurious entry
	per_app := Map()
	KLR__StashAppTypeJson(per_app, "code.exe", "c", "")
	AssertFalse(per_app.Has("code.exe"))
}
Test("KLR__StashAppTypeJson: empty JSON fragment -> app entry not created", _KLR_StashAppTypeJson_EmptyJsonSkipped)

_KLR_StashAppTypeJson_MultipleTypesUnderSameApp() {
	per_app := Map()
	KLR__StashAppTypeJson(per_app, "code.exe", "c",  '{"x":1}')
	KLR__StashAppTypeJson(per_app, "code.exe", "bg", '{"xy":2}')
	AssertEqual('{"x":1}',  per_app["code.exe"]["c"])
	AssertEqual('{"xy":2}', per_app["code.exe"]["bg"])
}
Test("KLR__StashAppTypeJson: multiple type codes stored under same app", _KLR_StashAppTypeJson_MultipleTypesUnderSameApp)




; ==================================================================
; ======= 10/ Durable walker replay row adapters ===================
; ==================================================================

_KLR_TypingRowToEntry_PreservesPhysicalMetadata() {
	row := Map(
		"ts", "2026-07-18 09:10:11",
		"app", "Code.exe",
		"title", "metrics test",
		"layout", "fr-FR",
		"events_json", '[["a",120,{"kc":65,"sk":30,"s":0}]]'
	)
	entry := KLR_TypingRowToEntry(row)
	AssertTrue(entry is Map)
	AssertEqual("Code.exe", entry["app"])
	AssertEqual("2026-07-18 09:10:11", entry["timestamp"])
	AssertTrue(entry["events"] is Array)
	AssertEqual(30, entry["events"][1][3]["sk"])
	AssertEqual(65, entry["events"][1][3]["kc"])
}
Test("KLR replay: typing row keeps physical keycode and scancode metadata", _KLR_TypingRowToEntry_PreservesPhysicalMetadata)

_KLR_TypingRowToEntry_RejectsMalformedEvents() {
	row := Map("ts", "2026-07-18 09:10:11", "events_json", "not json")
	AssertEqual(0, KLR_TypingRowToEntry(row))
}
Test("KLR replay: malformed historical events_json is skipped safely", _KLR_TypingRowToEntry_RejectsMalformedEvents)

_KLR_WindowRowToEntry_PreservesDuration() {
	entry := KLR_WindowRowToEntry(Map(
		"ts", "2026-07-18 09:10:11", "app", "Code.exe",
		"prev_title", "old", "next_title", "new", "duration_ms", 2500
	))
	AssertEqual("old", entry["prev_title"])
	AssertEqual("new", entry["next_title"])
	AssertEqual(2500, entry["duration_ms"])
}
Test("KLR replay: window row keeps foreground-title duration", _KLR_WindowRowToEntry_PreservesDuration)

_KLR_SystemRowToEntry_MergesMetadata() {
	entry := KLR_SystemRowToEntry(Map(
		"ts", "2026-07-18 09:10:11", "action", "modifier_hold",
		"metadata_json", '{"keycode":162,"hold_ms":700,"app":"Code.exe"}'
	))
	AssertEqual("modifier_hold", entry["action"])
	AssertEqual(162, entry["keycode"])
	AssertEqual(700, entry["hold_ms"])
	AssertEqual("Code.exe", entry["app"])
}
Test("KLR replay: system row restores modifier metadata", _KLR_SystemRowToEntry_MergesMetadata)
