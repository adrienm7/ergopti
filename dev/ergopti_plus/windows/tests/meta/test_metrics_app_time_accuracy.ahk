; tests/meta/test_metrics_app_time_accuracy.ahk

; ==============================================================================
; MODULE: Metrics App Time Accuracy Meta Test
; DESCRIPTION:
; Guards two sources of under-counted application time: treating every
; micro-idle as a session break and omitting the currently open foreground
; interval from the metrics manifest.
; ==============================================================================

#Requires AutoHotkey v2.0

_MATA_MicroIdleDoesNotResetAppTime() {
	Src := _DriverFuncBody("KL_Watchers_OnKeystroke")
	Assert(Src != "", "KL_Watchers_OnKeystroke must exist")
	Assert(!InStr(Src, "KLWatch.is_idle or gap >= KLWatchConst.SESSION_TIMEOUT_MS"),
		"micro-idle must not reset app_entered_at: it under-counts reading and thinking time")
	Assert(InStr(Src, "if (gap >= KLWatchConst.SESSION_TIMEOUT_MS)") > 0,
		"only a true session timeout may reset the foreground interval")
}
Test("metrics app time: micro-idle does not discard foreground duration", _MATA_MicroIdleDoesNotResetAppTime)

_MATA_ManifestIncludesLiveForegroundInterval() {
	ReaderBody := _DriverFuncBody("KLR_ReadManifest")
	Src := _DriverFuncBody("KLR_AddLiveForegroundTime")
	_MATA_AssertLiveProjection(ReaderBody, Src)
	; Inclusive and excluded date bounds are executed against this owner and
	; both real SQLite consumers by the registered klr-live-date-bounds cases.
}
Test("metrics app time: manifest includes the current foreground interval", _MATA_ManifestIncludesLiveForegroundInterval)

; A final clock is optional. Both historical and clock-forwarding readers must
; execute one projection call, rather than merely mention it in source prose.
_MATA_UniqueStatement(Code, Pattern, Message) {
	AssertTrue(Trim(Code) != "", "the projection owner must contain executable code")
	Position := RegExMatch(Code, Pattern, &Found)
	AssertTrue(Position > 0, Message)
	AssertEqual(0, RegExMatch(Code, Pattern, , Position + Found.Len),
		"the projection statement must have one executable owner")
	return Found
}

_MATA_AssertLiveProjection(ReaderBody, ProjectionBody) {
	AssertTrue(ReaderBody != "", "KLR_ReadManifest must exist")
	ReaderCode := _DriverMaskNonCode(&ReaderBody)
	_MATA_UniqueStatement(ReaderCode, "i)\bKLR_AddLiveForegroundTime\h*\(",
		"the reader must actually invoke its live projection")
	_MATA_UniqueStatement(ReaderCode,
		"im)^\h*KLR_AddLiveForegroundTime\h*\(\h*manifest\h*,\h*start_date\h*,\h*end_date"
			. "(?:\h*,\h*Now\?)?\h*\)\h*$",
		"the real projection call must preserve manifest, bounds and optional clock forwarding")
	AssertTrue(ProjectionBody != "", "KLR_AddLiveForegroundTime must exist")
	ProjectionCode := _DriverMaskNonCode(&ProjectionBody)
	Delta := _MATA_UniqueStatement(ProjectionCode,
		"im)^\h*cell\h*\[\h+\]\h*\+=\h*elapsed\h*$",
		"the actual projection must increment application time")
	; The mask preserves offsets. Verify the key of that executable assignment,
	; rather than accepting a quoted example or comment containing the key.
	Statement := SubStr(ProjectionBody, Delta.Pos, Delta.Len)
	AssertTrue(RegExMatch(Statement, 'i)^\h*cell\h*\[\h*["' . "'" . '](?-i:app_time_ms)["' . "'" . ']\h*\]') > 0,
		"the real map increment must target app_time_ms")
}

_MATA_LiveProjectionMutations() {
	Reader := _DriverFuncBody("KLR_ReadManifest")
	Projection := _DriverFuncBody("KLR_AddLiveForegroundTime")
	_MATA_AssertLiveProjection(Reader, Projection)
	Call := "KLR_AddLiveForegroundTime(manifest, start_date, end_date, Now?)"
	if !InStr(Reader, Call)
		Call := "KLR_AddLiveForegroundTime(manifest, start_date, end_date)"
	StrReplace(Reader, Call, "", false, &CallCount)
	AssertEqual(1, CallCount, "the mutation fixture must alter the unique actual call")
	for Replacement in ["", "Ignored := '" . Call . "'", "Ignored := 1 `; " . Call,
		"/*`n" . Call . "`n*/", Call . "`n" . Call, Call . "`n" . StrUpper(Call),
		"KLR_AddLiveForegroundTime(other, start_date, end_date, Now?)",
		"KLR_AddLiveForegroundTime(manifest, end_date, start_date, Now?)",
		"KLR_AddLiveForegroundTime(manifest, start_date, end_date, Other?)",
		"KLR_AddLiveForegroundTime(manifest, start_date, end_date, Now)"] {
		Changed := StrReplace(Reader, Call, Replacement)
		AssertThrows(() => _MATA_AssertLiveProjection(Changed, Projection))
	}
	for Replacement in ["KLR_AddLiveForegroundTime(manifest, start_date, end_date)",
		"KLR_AddLiveForegroundTime(manifest, start_date, end_date, Now?)",
		"KLR_ADDLIVEFOREGROUNDTIME(MANIFEST, START_DATE, END_DATE, NOW?)",
		"KLR_AddLiveForegroundTime ( manifest , start_date , end_date , Now? ) `; clock forwarding"]
		_MATA_AssertLiveProjection(StrReplace(Reader, Call, Replacement), Projection)
	Delta := 'cell["app_time_ms"] += elapsed'
	StrReplace(Projection, Delta, "", false, &DeltaCount)
	AssertEqual(1, DeltaCount, "the mutation fixture must alter the actual map increment")
	for Replacement in ["", "Ignored := '" . Delta . "'", "Ignored := 1 `; " . Delta,
		"/*`n" . Delta . "`n*/", Delta . "`n" . Delta,
		Delta . '`nCELL["app_time_ms"] += ELAPSED', 'cell["other"] += elapsed',
		'cell["APP_TIME_MS"] += elapsed',
		'cell["app_time_ms"] := elapsed', 'cell["app_time_ms"] += other'] {
		Changed := StrReplace(Projection, Delta, Replacement)
		AssertThrows(() => _MATA_AssertLiveProjection(Reader, Changed))
	}
	_MATA_AssertLiveProjection(Reader, StrReplace(Projection, Delta, 'CELL["app_time_ms"] += ELAPSED'))
	_MATA_AssertLiveProjection("/*`n" . Call . "`n*/`n" . Reader,
		"/*`n" . Delta . "`n*/`n" . Projection)
}
Test("metrics app time: manifest projection source controls reject decoys (klr-live-reader-call)",
	_MATA_LiveProjectionMutations)
