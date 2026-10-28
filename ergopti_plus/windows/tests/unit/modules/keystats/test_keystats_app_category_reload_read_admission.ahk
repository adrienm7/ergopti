; tests/unit/modules/keystats/test_keystats_app_category_reload_read_admission.ahk

; ==============================================================================
; MODULE: App Category Reload Read Admission Regression
; DESCRIPTION:
; A real file read and public discovery occur in that order at the supported
; Reload reader boundary. New discovery differs from RAM pending before reload.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLACRA_Read(Receipt, App, Path) {
	Receipt["reads"] += 1
	Content := FileRead(Path, "UTF-8")
	Receipt["image"] := Content
	Receipt["before"] := KLAppCat.categories
	Receipt["before_has"] := KLAppCat.categories.Has(App)
	Receipt["before_dirty"] := KLAppCat.dirty
	Receipt["lookup"] := KL_AppCat_Get(App)
	Receipt["after_has"] := KLAppCat.categories.Has(App)
	Receipt["after_dirty"] := KLAppCat.dirty
	return Content
}

_KLACRA_AssertBytes(Path, Expected) {
	Actual := FileRead(Path, "RAW")
	AssertEqual(Expected.Size, Actual.Size)
	loop Expected.Size
		AssertEqual(NumGet(Expected, A_Index - 1, "UChar"), NumGet(Actual, A_Index - 1, "UChar"))
}

_KLACRA_Exercise(Mode, Path) {
	if Mode == "uninterrupted-disk-edit" {
		AssertEqual("unknown", KL_AppCat_Get("preexisting-pending.reload.exe"))
		AssertTrue(KLAppCat.dirty, "the positive control must begin with an older pending discovery")
		Edited := '{"audit.reload.exe":"disk edited","other.reload.exe":"neutral"}' . "`n"
		AssertTrue(FSWriteDurable(Path, Edited))
		AssertTrue(KL_AppCat_Reload(), "uninterrupted reload must adopt the user's actual disk edit")
		AssertEqual("disk edited", KL_AppCat_Get("audit.reload.exe"))
		AssertFalse(KLAppCat.categories.Has("preexisting-pending.reload.exe"),
			"reload may still discard discovery that was pending before this read began")
		AssertFalse(KLAppCat.dirty)
		return
	}
	App := Mode == "disk-collision" ? "on-disk.reload.exe" : "new-read.reload.exe"
	if Mode == "disk-collision" {
		Edited := '{"audit.reload.exe":"disk edited","other.reload.exe":"neutral",'
			. '"on-disk.reload.exe":"explicit disk category"}' . "`n"
		AssertTrue(FSWriteDurable(Path, Edited))
	}
	BeforeBytes := FileRead(Path, "RAW")
	Receipt := Map("reads", 0)
	Result := KL_AppCat_Reload(_KLACRA_Read.Bind(Receipt, App))
	AssertEqual(1, Receipt["reads"], "the real reader boundary must be reached once")
	AssertTrue(Receipt["image"] == FileRead(Path, "UTF-8"), "the admitted image must equal the unchanged real file")
	AssertFalse(Receipt["before_has"], "the observed app must be new after the file image was acquired")
	AssertFalse(Receipt["before_dirty"], "this is no discard of discovery pending before reload")
	AssertEqual("unknown", Receipt["lookup"], "the real Get must acknowledge the new discovery")
	AssertTrue(Receipt["after_has"] && Receipt["after_dirty"],
		"the real Get must admit both its runtime app key and deferred persistence obligation")
	_KLACRA_AssertBytes(Path, BeforeBytes)
	if Mode == "disk-collision" {
		AssertTrue(Result is Integer && Result == 1)
		AssertEqual("explicit disk category", KL_AppCat_Get(App),
			"a new unknown lookup must not overwrite the user's already captured disk category")
		AssertEqual("disk edited", KL_AppCat_Get("audit.reload.exe"))
		AssertFalse(KLAppCat.dirty, "the captured disk image already persists the newly observed app")
		return
	}
	AssertTrue(Result is Integer && (Result == 0 || Result == 1),
		"reload may admit a merged image or refuse a superseded read with a strict Boolean")
	AssertTrue(KLAppCat.categories.Has(App), "reload cannot erase discovery admitted after its real file read")
	AssertEqual("unknown", KLAppCat.categories[App])
	AssertTrue(KLAppCat.dirty, "new discovery must retain its ordinary persistence debt")
	KL_AppCat_DeferredSave()
	AssertFalse(KLAppCat.dirty, "the real deferred-save API must settle the retained discovery")
	Durable := JsonParse(FileRead(Path, "UTF-8"))
	AssertEqual("unknown", Durable[App])
	AssertEqual("productive", Durable["audit.reload.exe"])
	AssertEqual("neutral", Durable["other.reload.exe"])
}

_KLACRA_Case(Mode) {
	static Serial := 0
	PreviousCritical := Critical("On")
	Saved := Map()
	Properties := ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"]
	for Key in Properties
		if KLAppCat.HasOwnProp(Key)
			Saved[Key] := KLAppCat.%Key%
	Root := A_Temp . "\ergopti_appcat_reload_read_" . A_ScriptHwnd . "_" . ++Serial
	Path := Root . "\" . KLAppCatConst.FILE_NAME
	Owned := false, Primary := 0, CleanupError := 0
	FixtureTimer := (*) => 0
	try {
		AssertFalse(A_IsSuspended, "the fixture must not borrow a paused driver's state")
		AssertTrue(Saved.Get("write_owner", 0) is Integer && Saved.Get("write_owner", 0) == 0,
			"the fixture cannot replace a foreign category write owner")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		Original := '{"audit.reload.exe":"productive","other.reload.exe":"neutral"}' . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Original))
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
		KLAppCat.save_fn := FixtureTimer
		if KLAppCat.HasOwnProp("write_owner")
			KLAppCat.write_owner := 0
		if KLAppCat.HasOwnProp("store_model")
			KLAppCat.store_model := 0
		AssertTrue(KL_AppCat_Init(Root), "the existing public initializer admits a real private file")
		_KLACRA_Exercise(Mode, Path)
	} catch as Failure {
		Primary := Failure
	} finally {
		try SetTimer(FixtureTimer, 0)
		catch as Failure {
			CleanupError := Failure
		} finally {
			for Key in Properties {
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

for _KLACRA_Mode in ["uninterrupted-disk-edit", "during-read", "disk-collision"]
	Test("App category reload: " . _KLACRA_Mode . " retains post-read discovery ownership (app-category-reload-read-owner)",
		_KLACRA_Case.Bind(_KLACRA_Mode))
