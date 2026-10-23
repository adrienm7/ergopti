; tests/unit/modules/keylogger/test_keylogger_app_category_set_owner.ahk

; ==============================================================================
; MODULE: App Category Write Ownership Regression
; DESCRIPTION:
; Uses the existing save boundary with its real atomic filesystem producer.
; A pending save must exclude edits, reload and shutdown without losing discovery.
; ==============================================================================

_KLACSO_Write(Receipt, Path, Content) {
	Receipt["calls"] += 1
	Receipt["set"] := KL_AppCat_Set("audit.exe", "must refuse")
	Receipt["after_set"] := _KL_AppCat_SnapshotContent()
	Receipt["reload"] := KL_AppCat_Reload()
	KLAppCat.dirty := false
	Receipt["shutdown"] := KL_AppCat_PrepareShutdown()
	Receipt["discovery"] := KL_AppCat_Get("during-save.exe")
	KL_WriteAtomic(Path, Content)
	Receipt["completed"] := true
}

_KLACSO_Case() {
	static Serial := 0
	PreviousCritical := Critical("On")
	HadSaveFn := KLAppCat.HasOwnProp("save_fn")
	HadWriteOwner := KLAppCat.HasOwnProp("write_owner")
	HadStoreModel := KLAppCat.HasOwnProp("store_model")
	Saved := { Categories: KLAppCat.categories, Path: KLAppCat.file_path,
		Dirty: KLAppCat.dirty, SaveFn: HadSaveFn ? KLAppCat.save_fn : 0,
		WriteOwner: HadWriteOwner ? KLAppCat.write_owner : 0,
		StoreModel: HadStoreModel ? KLAppCat.store_model : 0 }
	Root := A_Temp . "\ergopti_appcat_owner_" . A_ScriptHwnd . "_" . ++Serial
	Path := Root . "\" . KLAppCatConst.FILE_NAME
	Owned := false, Primary := 0, CleanupError := 0
	FixtureTimer := (*) => 0
	try {
		AssertTrue(Saved.WriteOwner is Integer && Saved.WriteOwner == 0,
			"the fixture cannot replace an active foreign category writer")
		FSCreateDirectoryExclusiveStrict(Root)
		Owned := true
		Original := '{"audit.exe":"productive","other.exe":"neutral"}' . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Original))
		KLAppCat.categories := Map(), KLAppCat.file_path := ""
		KLAppCat.dirty := false, KLAppCat.save_fn := FixtureTimer
		if HadWriteOwner
			KLAppCat.write_owner := 0
		if HadStoreModel
			KLAppCat.store_model := 0
		AssertTrue(KL_AppCat_Init(Root))
		Admitted := KLAppCat.categories
		Before := _KL_AppCat_SnapshotContent()
		Receipt := Map("calls", 0, "completed", false)
		Result := KL_AppCat_Save(_KLACSO_Write.Bind(Receipt))
		AssertEqual(1, Receipt["calls"], "the real save must enter its existing writer boundary once")
		AssertTrue(Receipt["completed"], "the writer must complete the real atomic filesystem publication")
		AssertTrue(Receipt["after_set"] == Before, "the refused edit cannot publish its RAM category")
		AssertTrue(Receipt["set"] is Integer && Receipt["set"] == 0,
			"a reentrant explicit edit must refuse before changing the pending save")
		AssertTrue(Receipt["reload"] is Integer && Receipt["reload"] == 0,
			"reload cannot replace the pending writer's admitted map")
		AssertTrue(Receipt["shutdown"] is Integer && Receipt["shutdown"] == 0,
			"a clean map cannot authorize shutdown while its detached writer remains active")
		AssertTrue(Result is Integer && Result == 0, "the discovery must retain a nonterminal save receipt")
		AssertTrue(KLAppCat.categories == Admitted, "the same admitted map must retain the discovery")
		AssertTrue(KLAppCat.dirty, "the discovery remains owned by deferred persistence")
		AssertEqual("unknown", Receipt["discovery"])
		AssertFalse(JsonParse(FSReadStrict(Path)).Has("during-save.exe"),
			"the actual first filesystem image predates the discovery")
		AssertTrue(KL_AppCat_Save(), "the released writer must permit a real durable retry")
		AssertFalse(KLAppCat.dirty)
		AssertTrue(KL_AppCat_Reload(), "the actual loader must admit the durable retry")
		AssertEqual("productive", KL_AppCat_Get("audit.exe"))
		AssertEqual("unknown", KL_AppCat_Get("during-save.exe"))
	} catch as Failure {
		Primary := Failure
	} finally {
		try SetTimer(FixtureTimer, 0)
		finally {
			KLAppCat.categories := Saved.Categories, KLAppCat.file_path := Saved.Path
			KLAppCat.dirty := Saved.Dirty
			if HadWriteOwner
				KLAppCat.write_owner := Saved.WriteOwner
			if HadStoreModel
				KLAppCat.store_model := Saved.StoreModel
			if HadSaveFn
				KLAppCat.save_fn := Saved.SaveFn
			else if KLAppCat.HasOwnProp("save_fn")
				KLAppCat.DeleteProp("save_fn")
			Critical(PreviousCritical)
		}
		if Owned {
			try DirDelete(Root, true)
			catch as Failure {
				CleanupError := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

Test("App category write owner: reentrant edit and shutdown refuse while discovery survives durable retry (app-category-set-owner)",
	_KLACSO_Case)
