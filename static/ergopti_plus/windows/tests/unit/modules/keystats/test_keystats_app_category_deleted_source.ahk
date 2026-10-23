; tests/unit/modules/keystats/test_keystats_app_category_deleted_source.ahk

; ==============================================================================
; MODULE: App Category Fresh Source Deletion Regressions
; DESCRIPTION:
; Qualifies phase-two edit APIs against real externally deleted store entries.
; A fresh edit may preserve a Get-owned discovery without reviving old RAM data.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLACDS_Case(Record, Pending) {
	static Serial := 0
	PreviousCritical := Critical("On")
	Saved := Map()
	for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"]
		if KLAppCat.HasOwnProp(Key)
			Saved[Key] := KLAppCat.%Key%
	Root := A_Temp . "\ergopti_appcat_deleted_" . A_ScriptHwnd . "_" . ++Serial
	Path := Root . "\" . KLAppCatConst.FILE_NAME
	Timer := (*) => 0
	Owned := false, Primary := 0, CleanupError := 0
	try {
		AssertTrue(Saved.Get("write_owner", 0) is Integer && Saved.Get("write_owner", 0) == 0,
			"the fixture cannot replace an admitted foreign writer")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		Deleted := Record ? '{"type":"old historical override","score":-1}' : '"old legacy category"'
		Original := '{"schema":"ergopti.app_categories","version":1,"apps":{'
			. '"audit.exe":"productive","removed.exe":' . Deleted . ',"other.exe":"neutral"}}' . "`n"
		Fresh := '{"schema":"ergopti.app_categories","version":1,"apps":{'
			. '"audit.exe":"productive","other.exe":"neutral"}}' . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Original))
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
		KLAppCat.save_fn := Timer
		if KLAppCat.HasOwnProp("write_owner")
			KLAppCat.write_owner := 0
		if KLAppCat.HasOwnProp("store_model")
			KLAppCat.store_model := 0
		AssertTrue(KL_AppCat_Init(Root), "the real phase-two decoder must admit the original mixed store")
		Admitted := KLAppCat.categories
		AssertTrue(Admitted.Has("removed.exe"), "the deleted entry must genuinely exist in admitted RAM first")
		if Pending
			AssertEqual("unknown", KL_AppCat_Get("new-discovery.exe"))
		AssertTrue(FSWriteDurable(Path, Fresh), "an independent writer must actually remove the old entry")
		Snapshot := KL_AppCat_EditorSnapshot("audit.exe", Root)
		AssertTrue(Snapshot is Map, "the new snapshot must read the real current image after deletion")
		Result := KL_AppCat_CommitEdit(Snapshot, "Révision 😀", 1.25)
		AssertTrue(KLAppCat.categories == Admitted, "publication preserves the admitted classifier identity")
		AssertFalse(KLAppCat.categories.Has("removed.exe"), "fresh publication cannot retain an externally deleted entry in RAM")
		Document := JsonParse(FSReadStrict(Path))
		AssertFalse(Document["apps"].Has("removed.exe"), "merging a new edit must not resurrect deleted canonical data")
		AssertTrue(Result is Integer && Result == 1, "the unrelated confirmed edit must really commit")
		AssertEqual("Révision 😀", KL_AppCat_Get("AUDIT.EXE"))
		AssertEqual("neutral", KL_AppCat_Get("other.exe"))
		AssertEqual(Pending, Document["apps"].Has("new-discovery.exe"),
			"only a real new discovery may survive merging with the fresh canonical image")
		if Pending
			AssertEqual("unknown", Document["apps"]["new-discovery.exe"])
		; Exercise the next real deferred-save obligation before reloading RAM.
		; Stale entries must not return through this second persistence path.
		AssertEqual("unknown", KL_AppCat_Get("later-discovery.exe"))
		AssertTrue(KL_AppCat_Save(), "the genuine discovery must still support an ordinary durable save")
		AssertFalse(JsonParse(FSReadStrict(Path))["apps"].Has("removed.exe"))
		AssertTrue(KL_AppCat_Reload())
		AssertFalse(KLAppCat.categories.Has("removed.exe"), "the real reload cannot recover a deleted record from stale RAM")
		AssertEqual("unknown", KL_AppCat_Get("later-discovery.exe"))
		AssertEqual("Révision 😀", KL_AppCat_Get("audit.exe"))
	} catch as Failure {
		Primary := Failure
	} finally {
		try SetTimer(Timer, 0)
		catch as Failure {
			CleanupError := Failure
		} finally {
			for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"] {
				if Saved.Has(Key)
					KLAppCat.%Key% := Saved[Key]
				else if KLAppCat.HasOwnProp(Key)
					KLAppCat.DeleteProp(Key)
			}
			Critical(PreviousCritical)
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

Test("App category fresh source: deleted record stays withdrawn (app-category-source-deletion)", _KLACDS_Case.Bind(true, false))
Test("App category fresh source: deleted legacy stays withdrawn (app-category-source-deletion)", _KLACDS_Case.Bind(false, false))
Test("App category fresh source: new discovery survives deleted record (app-category-source-deletion)", _KLACDS_Case.Bind(true, true))
Test("App category fresh source: new discovery survives deleted legacy (app-category-source-deletion)", _KLACDS_Case.Bind(false, true))
