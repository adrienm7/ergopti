; tests/unit/modules/keylogger/test_keylogger_app_category_set_durability.ahk

; ==============================================================================
; MODULE: App Category Explicit-Set Durability Regressions
; DESCRIPTION:
; Exercises the public two-argument setter with an actual replace-denying lock.
; A refused explicit edit must preserve both durable bytes and admitted RAM.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLACSD_AssertBytes(Path, Expected) {
	Actual := FileRead(Path, "RAW")
	AssertEqual(Expected.Size, Actual.Size, "a refused edit must preserve the original byte count")
	loop Expected.Size
		AssertEqual(NumGet(Expected, A_Index - 1, "UChar"), NumGet(Actual, A_Index - 1, "UChar"),
			"a refused edit must preserve every original byte")
}

_KLACSD_Case(PendingDiscovery) {
	static Serial := 0
	PreviousCritical := Critical("On")
	HadSaveFn := KLAppCat.HasOwnProp("save_fn")
	HadWriteOwner := KLAppCat.HasOwnProp("write_owner")
	HadStoreModel := KLAppCat.HasOwnProp("store_model")
	Saved := { Categories: KLAppCat.categories, Path: KLAppCat.file_path,
		Dirty: KLAppCat.dirty, SaveFn: HadSaveFn ? KLAppCat.save_fn : 0,
		WriteOwner: HadWriteOwner ? KLAppCat.write_owner : 0,
		StoreModel: HadStoreModel ? KLAppCat.store_model : 0 }
	Root := A_Temp . "\ergopti_appcat_set_" . A_ScriptHwnd . "_" . ++Serial
	Path := Root . "\" . KLAppCatConst.FILE_NAME
	Owned := false, Locked := 0, Primary := 0, CleanupError := 0
	FixtureTimer := (*) => 0
	try {
		AssertTrue(Saved.WriteOwner is Integer && Saved.WriteOwner == 0,
			"the fixture cannot replace an active foreign category writer")
		FSCreateDirectoryExclusiveStrict(Root)
		Owned := true
		Original := '{"audit.exe":"productive","other.exe":"neutral"}' . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Original), "the private original must be durably created")
		OriginalBytes := FileRead(Path, "RAW")
		; The original timer stays parked under Critical. Any retry from this
		; scenario must target only its own callback, never a prior fixture's timer.
		KLAppCat.categories := Map(), KLAppCat.file_path := ""
		KLAppCat.dirty := false, KLAppCat.save_fn := FixtureTimer
		if HadStoreModel
			KLAppCat.store_model := 0
		if HadWriteOwner
			KLAppCat.write_owner := 0
		AssertTrue(KL_AppCat_Init(Root), "the real category loader must admit the original")
		if PendingDiscovery {
			AssertEqual("unknown", KL_AppCat_Get("pending.exe"), "the real discovery API owns its pending metadata")
			AssertTrue(KLAppCat.dirty)
		}
		Admitted := KLAppCat.categories
		BeforeContent := _KL_AppCat_SnapshotContent()
		; Read sharing still permits byte verification. Denying write/delete
		; prevents the real atomic replacement, including its native retry.
		Locked := FileOpen(Path, "r-wd")
		AssertTrue(IsObject(Locked), "the real destination lock must be held during the edit")
		Result := KL_AppCat_Set("AUDIT.EXE", "Révision 😀")
		AssertTrue(KLAppCat.categories == Admitted, "a refused edit must preserve the admitted Map identity")
		AssertTrue(_KL_AppCat_SnapshotContent() == BeforeContent,
			"a refused edit cannot publish its category or lose a pending discovery")
		AssertEqual(PendingDiscovery, KLAppCat.dirty, "refusal preserves prior dirty ownership")
		AssertTrue(FSReadStrict(Path) == Original, "the replace-denying lock preserves exact original text")
		_KLACSD_AssertBytes(Path, OriginalBytes)
		AssertTrue(Result is Integer && Result == 0, "a refused explicit edit must return strict false")
		Locked.Close(), Locked := 0

		Result := KL_AppCat_Set("AUDIT.EXE", "Révision 😀")
		AssertTrue(Result is Integer && Result == 1, "the same real edit must succeed after releasing the lock")
		AssertEqual("Révision 😀", KL_AppCat_Get("audit.exe"), "Get retains its public String contract")
		AssertFalse(KLAppCat.dirty, "successful explicit persistence includes the current discovery snapshot")
		AssertTrue(KL_AppCat_Reload(), "the real loader must reopen the newly durable category")
		AssertEqual("Révision 😀", KL_AppCat_Get("AUDIT.EXE"), "the complete Unicode edit must survive reload")
		AssertEqual("neutral", KL_AppCat_Get("other.exe"), "an unrelated category remains durable")
		if PendingDiscovery
			AssertEqual("unknown", KL_AppCat_Get("pending.exe"), "a pending discovery must survive the accepted edit")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Locked)
				Locked.Close()
		} catch as Failure {
			CleanupError := Failure
		} finally {
			try SetTimer(FixtureTimer, 0)
			finally {
				KLAppCat.categories := Saved.Categories, KLAppCat.file_path := Saved.Path
				KLAppCat.dirty := Saved.Dirty
				if HadStoreModel
					KLAppCat.store_model := Saved.StoreModel
				else if KLAppCat.HasOwnProp("store_model")
					KLAppCat.DeleteProp("store_model")
				if HadWriteOwner
					KLAppCat.write_owner := Saved.WriteOwner
				if HadSaveFn
					KLAppCat.save_fn := Saved.SaveFn
				else if KLAppCat.HasOwnProp("save_fn")
					KLAppCat.DeleteProp("save_fn")
				Critical(PreviousCritical)
			}
		}
		if Owned {
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

Test("App category explicit set: locked original refuses RAM publication before durable retry (app-category-set-durability)",
	_KLACSD_Case.Bind(false))
Test("App category explicit set: locked original preserves pending discovery before durable retry (app-category-set-durability)",
	_KLACSD_Case.Bind(true))
