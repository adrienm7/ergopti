; tests/unit/modules/hotstrings/personal/test_toml_count_publication.ahk

; ==============================================================================
; MODULE: TOML Count Publication Tests
; DESCRIPTION:
; Real read refusal, diagnostic and timer interleave with a newer public count.
; A returning failed warm read must not hide the newer registerable rows.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TCWP_Fixture {
	__New(Mode, Path) {
		this.Mode := Mode, this.Path := Path
		this.Lock := 0, this.Failure := 0, this.Done := false
		this.LogCalls := 0, this.TimerCalls := 0, this.NestedCount := -1
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
	}
	OnLog(Line) {
		if !InStr(Line, "[ERROR] [TomlLoader] Cannot read '", true) || !InStr(Line, this.Path, true)
			return
		this.LogCalls += 1
		if this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the real failed-read diagnostic must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the observed timer must settle before the old read returns")
		} catch as Failure
			this.Failure := Failure
	}
	OnTimer() {
		global _TomlFileCache, _TomlFileSectionCounts
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical)
			AssertTrue(TOML_UnreadableFile(this.Path), "the real failed read must raise its sticky latch")
			AssertTrue(IsObject(this.Lock), "the exact private deny-read handle must still exist")
			this.Lock.Close()
			this.Lock := 0
			if this.Mode != "retry" {
				AssertEqual(1, FSWriteDurable(this.Path, _TCWP_Image(true)))
				this.NestedCount := CountTomlSection("private", "mix", this.Path)
				AssertEqual(2, this.NestedCount, "the newer public count must see both real entry shapes")
				AssertEqual(_TCWP_Image(true), ReadTomlFile(this.Path))
				AssertFalse(TOML_UnreadableFile(this.Path), "the successful real read must clear the latch")
				AssertEqual(2, _TomlFileSectionCounts[this.Path]["mix"])
				if this.Mode == "invalidate-during" {
					_ParseTomlGroupConfig_InvalidatePath(this.Path)
					AssertFalse(_TomlFileCache.Has(this.Path))
					AssertFalse(_TomlFileSectionCounts.Has(this.Path),
						"the real invalidator must evict raw and derived cache entries")
				}
			}
			this.Bytes := FSReadBytesStrict(this.Path)
		} catch as Failure
			this.Failure := Failure
		finally this.Done := true
	}
	Exercise() {
		global _TomlFileCache, _TomlFileSectionCounts
		AssertEqual(1, FSWriteDurable(this.Path, _TCWP_Image(false)))
		AssertFalse(_TomlFileCache.Has(this.Path))
		AssertFalse(_TomlFileSectionCounts.Has(this.Path))
		this.Lock := FileOpen(this.Path, "r-rwd")
		AssertTrue(IsObject(this.Lock), "the native deny-read lock must really be acquired")
		Denied := false
		try FileRead(this.Path, "UTF-8")
		catch OSError
			Denied := true
		AssertTrue(Denied, "an independent native read must observe the real sharing refusal")
		LoggerSetTestSink(this.SinkFn)
		Older := CountTomlSection("private", "mix", this.Path)
		LoggerClearTestSink()
		if this.Failure is Error
			throw this.Failure
		AssertEqual(1, this.LogCalls)
		AssertEqual(1, this.TimerCalls)
		if this.Mode == "invalidate-after"
			_ParseTomlGroupConfig_InvalidatePath(this.Path)
		Expected := this.Mode == "retry" ? 1 : 2
		; Menus and extension registration use these public count consumers.
		; The old detached return need not be retried in-place; only the next
		; current consumer must not see a failed read cached over the winner.
		Current := CountTomlSection("private", "mix", this.Path)
		FileAppend("RECEIPT toml-count-publication mode=" . this.Mode . " old=" . Older
			. " nested=" . this.NestedCount . " current=" . Current
			. " expected=" . Expected . " log_calls=" . this.LogCalls
			. " timer_calls=" . this.TimerCalls . "`n", "*")
		AssertEqual(Expected, Current,
			"a failed returning warm read cannot hide the newer registerable hotstrings from menus")
		AssertEqual(Expected, CountTomlHotstrings("private", this.Path),
			"the public file total must agree with the actual registerable rows")
		AssertEqual(_TCWP_Image(this.Mode != "retry"), ReadTomlFile(this.Path))
		AssertFalse(TOML_UnreadableFile(this.Path))
		AssertEqual(Expected, _TomlFileSectionCounts[this.Path]["mix"])
		_TCWP_Bytes(this.Bytes, FSReadBytesStrict(this.Path))
		AssertEqual(1, this.LogCalls, "the repaired warm cache must not repeat the refusal")
	}
	Close() {
		try SetTimer(this.TimerFn, 0)
		finally {
			this.TimerFn := 0, this.SinkFn := 0
			if IsObject(this.Lock) {
				this.Lock.Close()
				this.Lock := 0
			}
		}
	}
}

_TCWP_Image(Second) {
	return '[[mix]]`n"first" = { output = "alpha", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`n'
		. (Second ? 'second = "beta"`n' : "") . 'ignored = 17`n[_meta]`ndescription = "metadata is not an entry"`n'
}

_TCWP_Bytes(Expected, Actual) {
	AssertTrue(Expected is Buffer && Actual is Buffer)
	AssertEqual(Expected.Size, Actual.Size, "read/count completion must not change the repaired source")
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, "the exact repaired bytes must survive cache publication")
}

_TCWP_Case(Mode) {
	global _TomlFileCache, _TomlFileSectionCounts, _TomlCountCache, _TomlUnreadableFiles, _HSResolveGen
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy, _ED_Busy, _ED_PendingRecord
	static Sequence := 0
	AssertFalse(A_IsSuspended)
	AssertEqual(0, _LOGGER_TEST_SINK, "the fixture cannot replace a foreign observer")
	AssertFalse(IsSet(_ED_Busy) && _ED_Busy, "the fixture cannot adopt a foreign error dialog")
	AssertFalse(IsSet(_ED_PendingRecord) && IsObject(_ED_PendingRecord),
		"the fixture cannot adopt a foreign pending error record")
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	Saved := {Gen: _HSResolveGen, Repeat: _LOGGER_REPEAT_ENABLED, PathDate: _LOGGER_PATH_DATE,
		Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN,
		HadHealthError: IsSet(_HealthCheckLastError), HadHealthCount: IsSet(_HealthCheckErrCount),
		HadErrorPolicy: IsSet(_ED_Policy)}
	if Saved.HadHealthError
		Saved.HealthError := _HealthCheckLastError
	if Saved.HadHealthCount
		Saved.HealthCount := _HealthCheckErrCount
	if Saved.HadErrorPolicy
		Saved.ErrorPolicy := _ED_Policy
	Root := A_Temp . "\ergopti_toml_count_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	F := _TCWP_Fixture(Mode, Root . "\hotstrings.toml"), Primary := 0, CleanupError := 0
	PreviousCritical := A_IsCritical
	try {
		; Keep the genuine error logger and health hook, with no UI policy admitted.
		_ED_Policy := 0
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := ""
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		Critical("Off")
		F.Exercise()
	} catch as Failure {
		Primary := Failure
	} finally {
		try F.Close()
		catch as Failure {
			CleanupError := Failure
		} finally {
			_LOGGER_TEST_SINK := 0
			_LOGGER_REPEAT_ENABLED := Saved.Repeat, _LOGGER_PATH_DATE := Saved.PathDate
			_LOGGER_CLOCK_FN := Saved.Clock, _LOGGER_STAMP_FN := Saved.Stamp
			_TLOG_RestoreLoggerState(SavedLogger)
			_HealthCheckLastError := Saved.HadHealthError ? Saved.HealthError : unset
			_HealthCheckErrCount := Saved.HadHealthCount ? Saved.HealthCount : unset
			_ED_Policy := Saved.HadErrorPolicy ? Saved.ErrorPolicy : unset
			try _ParseTomlGroupConfig_InvalidatePath(F.Path)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
			_HSResolveGen := Saved.Gen
			if _TomlUnreadableFiles.Has(F.Path)
				_TomlUnreadableFiles.Delete(F.Path)
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for _TCWP_Mode in ["newer-read", "invalidate-during", "invalidate-after", "retry"]
	Test("TOML counts: " . _TCWP_Mode . " retains current registerable rows (toml-count-publication)",
		_TCWP_Case.Bind(_TCWP_Mode))
