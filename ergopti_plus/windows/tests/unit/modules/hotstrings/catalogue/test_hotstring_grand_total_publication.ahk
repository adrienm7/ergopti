; tests/unit/modules/hotstrings/catalogue/test_hotstring_grand_total_publication.ahk

; ==============================================================================
; MODULE: Hotstring Grand Total Publication Tests
; DESCRIPTION:
; The tray's actual grand-total provider must not freeze an older personal-file
; sum after a real writer or a nested total has admitted the replacement. A real
; diagnostic timer supplies the interleave; no count/reader/writer is replaced.
; ==============================================================================

#Requires AutoHotkey v2.0

class _HGTP_Fixture {
	__New(Mode, Path) {
		this.Mode := Mode, this.Path := Path
		this.LogCalls := 0, this.TimerCalls := 0, this.WriterResult := 0
		this.Done := false, this.Failure := 0, this.NestedTotal := -1
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
	}
	OnLog(Line) {
		if !InStr(Line, "[WARNING] [PersonalToml] Metadata source in", true) || !InStr(Line, this.Path, true)
			return
		this.LogCalls += 1
		if this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the actual metadata diagnostic must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the genuine diagnostic timer must settle before the old total resumes")
		} catch as Failure
			this.Failure := Failure
	}
	OnTimer() {
		global _ReadPersonalTomlCache, _HS_GrandTotalCache
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical)
			if this.Mode != "live" {
				; Admit a valid repair before the canonical writer's real preconditions.
				AssertEqual(1, FSWriteDurable(this.Path, _HGTP_Image(true, false)))
				Winner := ReadPersonalToml(true)
				AssertEqual(2, Winner["sections"]["alpha"]["entries"].Length)
				Candidate := _PersonalTomlCloneDetached(Winner)
				Candidate["sections"]["alpha"]["entries"][2]["output"] := "Committed second"
				this.WriterResult := WritePersonalToml(Candidate)
				AssertTrue(this.WriterResult is Integer && this.WriterResult == 1,
					"the unmodified public writer must acknowledge a real durable replacement")
				AssertFalse(_ReadPersonalTomlCache, "the real writer must evict the model cache")
				AssertEqual(-1, _HS_GrandTotalCache,
					"the completed writer must really invalidate the pending tray total")
				Committed := ReadPersonalToml()
				AssertEqual("Committed second", Committed["sections"]["alpha"]["entries"][2]["output"])
				if this.Mode == "newer-total" {
					this.NestedTotal := _HS_ComputeGrandTotal()
					AssertEqual(2, this.NestedTotal, "the newer actual provider must admit both active entries")
					AssertEqual(2, _HS_GrandTotalCache)
				} else
					AssertEqual(-1, _HS_GrandTotalCache, "the public model read must leave the writer's total invalidation intact")
			}
			this.Bytes := FSReadBytesStrict(this.Path)
		} catch as Failure
			this.Failure := Failure
		finally this.Done := true
	}
	Exercise() {
		global _ReadPersonalTomlCache, _HS_GrandTotalCache
		AssertEqual(1, FSWriteDurable(this.Path, _HGTP_Image(false, true)))
		AssertFalse(_ReadPersonalTomlCache)
		AssertEqual(-1, _HS_GrandTotalCache)
		LoggerSetTestSink(this.SinkFn)
		Older := _HS_ComputeGrandTotal()
		LoggerClearTestSink()
		if this.Failure is Error
			throw this.Failure
		AssertEqual(1, this.LogCalls)
		AssertEqual(1, this.TimerCalls)
		if this.Mode == "invalidate-after"
			_HS_InvalidateCaches()
		Expected := this.Mode == "live" ? 1 : 2
		Current := _HS_ComputeGrandTotal()
		FileAppend("RECEIPT hotstrings-grand-total-publication mode=" . this.Mode
			. " old=" . Older . " nested=" . this.NestedTotal . " current=" . Current
			. " expected=" . Expected . " writer=" . this.WriterResult
			. " log_calls=" . this.LogCalls . " timer_calls=" . this.TimerCalls . "`n", "*")
		; menu_init uses this exact provider for its staged hotstrings_parent_total.
		; A future fix may also recompute Older; only the next current total is fixed.
		AssertEqual(Expected, Current,
			"the tray parent total cannot hide a newer committed hotstring catalogue behind an older sum")
		AssertEqual(Expected, _HS_GrandTotalCache)
		CurrentModel := ReadPersonalToml()
		AssertEqual(Expected, CurrentModel["sections"]["alpha"]["entries"].Length)
		if this.Mode != "live"
			AssertEqual("Committed second", CurrentModel["sections"]["alpha"]["entries"][2]["output"])
		_HGTP_Bytes(this.Bytes, FSReadBytesStrict(this.Path))
		AssertEqual(Expected, _HS_ComputeGrandTotal(), "a current cache hit must preserve the real active count")
		AssertEqual(1, this.LogCalls)
		Lease := _PersonalTomlWriteLeaseTryAcquire(this.Path, "grand-total-control")
		AssertTrue(Lease is Object)
		try AssertTrue(_PersonalTomlWriteLeaseOwns(Lease, this.Path))
		finally _PersonalTomlWriteLeaseRelease(Lease)
		Stages := 0
		loop files, this.Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	}
	Close() {
		SetTimer(this.TimerFn, 0)
		this.TimerFn := 0, this.SinkFn := 0
	}
}

_HGTP_Image(Second, Broken) {
	Description := Broken ? 'description = "unterminated' : 'description = "Admitted catalogue"'
	return "[_meta]`n" . Description . '`n[[alpha]]`n"first" = { output = "First", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
		. (Second ? '"second" = { output = "Second", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n' : "")
}

_HGTP_Bytes(Expected, Actual) {
	AssertTrue(Expected is Buffer && Actual is Buffer)
	AssertEqual(Expected.Size, Actual.Size, "returning an old total cannot modify the committed catalogue")
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, "the real writer's exact bytes must remain intact")
}

_HGTP_Case(Mode) {
	global ScriptInformation, Features, CategoryEnabled, HotstringCategoriesStd, HotstringCategoriesErgopti
	global _ReadPersonalTomlCache, _HS_GrandTotalCache, _PersonalTomlReadGeneration, _HSResolveGen
	global _TomlFileCache, _TomlFileSectionCounts, _TomlCountCache, HotstringGroupConfig, _HotstringExtensionPacks
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckLastError, _HealthCheckErrCount, _HealthCheckWarnCount, _ED_Policy, _ED_Busy, _ED_PendingRecord
	global _TomlUnreadableFiles, _FLAT_HOTSTRING_V1_CATS, _V1CatToV2CatMap, _LegacyTopCategoryMap
	static Sequence := 0
	AssertFalse(A_IsSuspended)
	for Symbol in ["_HS_ComputeGrandTotal", "_HS_InvalidateCaches", "WritePersonalToml"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(_DriverIsProductionSource(Owner) && FileExist(Owner) != "",
			"the actual suite must resolve the complete production owner: " . Symbol)
	}
	AssertEqual(0, _LOGGER_TEST_SINK, "the fixture cannot replace a foreign observer")
	AssertFalse(IsSet(_ED_Busy) && _ED_Busy)
	AssertFalse(IsSet(_ED_PendingRecord) && IsObject(_ED_PendingRecord))
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	Saved := {Features: Features, Categories: CategoryEnabled,
		Model: _ReadPersonalTomlCache, Total: _HS_GrandTotalCache, Generation: _PersonalTomlReadGeneration,
		ResolveGen: _HSResolveGen, Raw: _TomlFileCache, Counts: _TomlFileSectionCounts,
		Legacy: _TomlCountCache, Groups: HotstringGroupConfig, Packs: _HotstringExtensionPacks,
		Adopted: PersonalFileControls.owners, HadPath: ScriptInformation.Has("PersonalTomlPath"),
		Path: ScriptInformation.Get("PersonalTomlPath", ""), HadStd: IsSet(HotstringCategoriesStd),
		HadErgopti: IsSet(HotstringCategoriesErgopti), Extras: Map()}
	if Saved.HadStd
		Saved.Standard := HotstringCategoriesStd
	if Saved.HadErgopti
		Saved.Ergopti := HotstringCategoriesErgopti
	for Name in ["_LOGGER_REPEAT_ENABLED", "_LOGGER_PATH_DATE", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_HealthCheckLastError", "_HealthCheckErrCount", "_HealthCheckWarnCount", "_ED_Policy",
		"_FLAT_HOTSTRING_V1_CATS", "_V1CatToV2CatMap", "_LegacyTopCategoryMap"]
		Saved.Extras[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Root := A_Temp . "\ergopti_grand_total_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	F := _HGTP_Fixture(Mode, Root . "\personal_hotstrings.toml"), Primary := 0, CleanupError := 0
	PreviousCritical := A_IsCritical
	try {
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := "", _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		_ED_Policy := 0
		_TomlFileCache := Map(), _TomlFileSectionCounts := Map(), _TomlCountCache := Map(), HotstringGroupConfig := Map()
		; Cold immutable catalogue reads use the private logger and raw cache too.
		AssertTrue(HotstringsLanguageCategories() is Array)
		MenuGroups := MenuManifest_LoadHotstringGroups()
		ScriptInformation["PersonalTomlPath"] := F.Path
		Features := Map("hotstrings", Map("personal", Map("alpha", Map("enabled", true))))
		CategoryEnabled := Map("Hotstrings", true)
		HotstringCategoriesStd := MenuGroups.standard, HotstringCategoriesErgopti := MenuGroups.ergopti
		_FLAT_HOTSTRING_V1_CATS := [], _V1CatToV2CatMap := Map(), _LegacyTopCategoryMap := Map()
		_HS_RegisterLanguageMenuCategories()
		_HotstringExtensionPacks := [], PersonalFileControls.owners := Map()
		_ReadPersonalTomlCache := false, _HS_GrandTotalCache := -1
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
			try _ParseTomlGroupConfig_InvalidatePath(F.Path)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
			if _TomlUnreadableFiles.Has(F.Path)
				_TomlUnreadableFiles.Delete(F.Path)
			Features := Saved.Features, CategoryEnabled := Saved.Categories
			HotstringCategoriesStd := Saved.HadStd ? Saved.Standard : unset
			HotstringCategoriesErgopti := Saved.HadErgopti ? Saved.Ergopti : unset
			_ReadPersonalTomlCache := Saved.Model, _HS_GrandTotalCache := Saved.Total
			_PersonalTomlReadGeneration := Saved.Generation, _HSResolveGen := Saved.ResolveGen
			_TomlFileCache := Saved.Raw, _TomlFileSectionCounts := Saved.Counts, _TomlCountCache := Saved.Legacy
			HotstringGroupConfig := Saved.Groups, _HotstringExtensionPacks := Saved.Packs
			PersonalFileControls.owners := Saved.Adopted
			if Saved.HadPath
				ScriptInformation["PersonalTomlPath"] := Saved.Path
			else if ScriptInformation.Has("PersonalTomlPath")
				ScriptInformation.Delete("PersonalTomlPath")
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Extra in Saved.Extras
				%Name% := Extra.Present ? Extra.Value : unset
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

for _HGTP_Mode in ["writer-invalidate", "newer-total", "invalidate-after", "live"]
	Test("Hotstring tray total: " . _HGTP_Mode . " retains the current catalogue (hotstrings-grand-total-publication)",
		_HGTP_Case.Bind(_HGTP_Mode))
