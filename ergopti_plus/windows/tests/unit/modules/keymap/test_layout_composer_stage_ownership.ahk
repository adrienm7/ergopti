; tests/unit/modules/keymap/test_layout_composer_stage_ownership.ahk
;
; ==============================================================================
; MODULE: Composer Declaration Stage Ownership Tests
; DESCRIPTION:
; Exercises fresh and existing public saves through verified installation and
; native file receipts. An occupied declaration stage must remain untouched.
; ==============================================================================

#Requires AutoHotkey v2.0

_LCH_FileReceipt(Path) {
	if !FileExist(Path)
		return "absent"
	Bytes := FSReadBytesStrict(Path)
	return Bytes.Size . ":" . CryptoSha256Bytes(Bytes)
}

_LCH_DeclarationStageOwnership(Existing, Foreign) {
	Dir := _LCH_TempDir()
	LocalDir := LayoutRegistry_LocalDir(Dir)
	Path := LayoutComposer_DeclarationPath(Dir)
	Stage := Path . LAYOUT_REGISTRY_PARTIAL_SUFFIX
	RecordPath := LocalDir . LayoutRegistry_Settings()["installed_file"]
	LayoutPath := LocalDir . LayoutRegistry_Composer()["id"] . ".keylayout"
	try {
		if Existing {
			Initial := []
			AssertTrue(LayoutComposer_Handle("composer_save",
				Map("declaration", _LCH_Declaration(), "keylayout", _LCH_Text(), "use", false),
				_LCH_Deps(Dir, Initial)))
			AssertEqual(1, _LCH_Pushed(Initial, "composerResult")["ok"], "the existing composition is genuinely installed")
			AssertEqual(_LCH_Text(), LayoutRegistry_ReadLocal(LayoutRegistry_Composer()["id"], LocalDir)["Text"])
		}
		SplitPath(Path, , &Parent)
		DirCreate(Parent)
		if Foreign
			AssertTrue(FSWriteCreateDurable(Stage, "foreign composer source é`r`n"))
		BeforeStage := _LCH_FileReceipt(Stage)
		BeforeDeclaration := _LCH_FileReceipt(Path)
		BeforeRecord := _LCH_FileReceipt(RecordPath)
		BeforeLayout := _LCH_FileReceipt(LayoutPath)
		Log := []
		AssertTrue(LayoutComposer_Handle("composer_save",
			Map("declaration", _LCH_Declaration(), "keylayout", _LCH_Text(), "use", false), _LCH_Deps(Dir, Log)))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertTrue(Result is Map, "the actual public composer must report its publication outcome")
		if Foreign {
			AssertEqual(BeforeStage, _LCH_FileReceipt(Stage), "the composer cannot borrow or remove a foreign declaration stage")
			AssertEqual(BeforeDeclaration, _LCH_FileReceipt(Path), "collision preserves the actual authored declaration")
			AssertEqual(BeforeRecord, _LCH_FileReceipt(RecordPath), "collision cannot publish a different installed record")
			AssertEqual(BeforeLayout, _LCH_FileReceipt(LayoutPath), "collision cannot replace the installed keylayout")
			AssertEqual(0, Result["ok"], "the genuine public save visibly refuses an unowned stage")
			AssertEqual(LAYOUT_COMPOSER_FAILURE_WRITE, Result["code"])
		} else {
			AssertEqual(1, Result["ok"], "the real collision-free composer save succeeds")
			AssertEqual("absent", _LCH_FileReceipt(Stage), "successful publication retires its own declaration stage")
			AssertEqual(_LCH_Declaration(), LayoutComposer_ReadDeclaration(Dir))
			AssertEqual(_LCH_Text(), LayoutRegistry_ReadLocal(LayoutRegistry_Composer()["id"], LocalDir)["Text"])
		}
		AssertEqual("", _LCH_Calls(Log), "saving without selection cannot request a select or reload")
	} finally DirDelete(Dir, true)
}
for Existing in [false, true]
	for Foreign in [false, true]
		Test("composer declaration ownership: existing=" . Existing . " collision=" . Foreign
			. " preserves native source (composer-stage-native-ownership)",
			_LCH_DeclarationStageOwnership.Bind(Existing, Foreign))

; A target can be readable while Windows refuses replacement. A refusal must
; retire this attempt's own stage so a later user retry can actually succeed.
_LCSR_Directory() {
	Root := A_Temp . "\ergopti_layout_stage_retry_" . A_TickCount . "_" . Random(100000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue(Created is Integer && Created == 1, "only an exclusively created root may enter cleanup custody")
	return Root . "\"
}

_LCSR_Composer() {
	Dir := _LCSR_Directory()
	Lock := 0
	try {
		Initial := []
		AssertTrue(LayoutComposer_Handle("composer_save", Map("declaration", _LCH_Declaration(),
			"keylayout", _LCH_Text(), "use", false), _LCH_Deps(Dir, Initial)))
		AssertEqual(1, _LCH_Pushed(Initial, "composerResult")["ok"], "initial real composer installation succeeds")
		Path := LayoutComposer_DeclarationPath(Dir)
		Stage := Path . LAYOUT_REGISTRY_PARTIAL_SUFFIX
		Before := _LCH_FileReceipt(Path)
		Changed := _LCH_Declaration() . "`n"
		Lock := FileOpen(Path, "r-wd", "UTF-8")
		AssertTrue(IsObject(Lock), "native read handle denies target replacement")
		First := []
		AssertTrue(LayoutComposer_Handle("composer_save", Map("declaration", Changed,
			"keylayout", _LCH_Text(), "use", false), _LCH_Deps(Dir, First)))
		FirstResult := _LCH_Pushed(First, "composerResult")
		AssertEqual(0, FirstResult["ok"], "the real sharing refusal reaches the public result")
		AssertEqual(LAYOUT_COMPOSER_FAILURE_WRITE, FirstResult["code"])
		AssertEqual(Before, _LCH_FileReceipt(Path), "the denied target remains byte exact")
		StageLeft := FileExist(Stage) != ""
		Lock.Close()
		Lock := 0
		Retry := []
		AssertTrue(LayoutComposer_Handle("composer_save", Map("declaration", Changed,
			"keylayout", _LCH_Text(), "use", false), _LCH_Deps(Dir, Retry)))
		Result := _LCH_Pushed(Retry, "composerResult")
		FileAppend("# layout-stage-refusal composer first_ok=" . FirstResult["ok"]
			. " stage_left=" . StageLeft . " retry_ok=" . Result["ok"] . "`n", "*")
		AssertEqual(1, Result["ok"], "a fresh user save succeeds after the actual target lock is released")
		AssertEqual(Changed, LayoutComposer_ReadDeclaration(Dir))
		AssertEqual("absent", _LCH_FileReceipt(Stage), "retry leaves no owned declaration stage")
		AssertEqual(_LCH_Text(), LayoutRegistry_ReadLocal(LayoutRegistry_Composer()["id"], LayoutRegistry_LocalDir(Dir))["Text"])
		AssertEqual("", _LCH_Calls(First) . _LCH_Calls(Retry), "save without selection cannot request runtime work")
	} finally {
		if IsObject(Lock)
			Lock.Close()
		DirDelete(Dir, true)
	}
}

_LCSR_Install(Family) {
	Dir := _LCSR_Directory()
	Lock := 0
	try {
		Entry := JsonParse(_LayoutCatalogueJson(LayoutCatalogue_Entry(_LCT_Index(), "ergol")))
		Text := _LCT_LayoutText("ergol")
		Initial := []
		LayoutCatalogue_InstallLocal(Entry, Dir, Text, (Args*) => Initial.Push(Args))
		AssertEqual(1, Initial.Length)
		AssertTrue(Initial[1][1], "initial genuine verified installation succeeds")
		AssertEqual(Text, LayoutRegistry_ReadLocal("ergol", Dir)["Text"])
		LayoutPath := Dir . "ergol.keylayout"
		RecordPath := Dir . LayoutRegistry_Settings()["installed_file"]
		Target := Family == "record" ? RecordPath : LayoutPath
		Stage := Target . LAYOUT_REGISTRY_PARTIAL_SUFFIX
		BeforeRecord := _LCH_FileReceipt(RecordPath)
		BeforeLayout := _LCH_FileReceipt(LayoutPath)
		Changed := Text . "`n<!-- native sharing refusal retry -->`n"
		Next := JsonParse(_LayoutCatalogueJson(Entry))
		Next["sha256"] := CryptoSha256(Changed)
		Next["size"] := StrPut(Changed, "UTF-8") - 1
		Next["version"] := "2.0.0"
		LayoutRegistry_Verify(Next, Changed)
		Lock := FileOpen(Target, "r-wd", "UTF-8")
		AssertTrue(IsObject(Lock), "native sharing handle is actually retained")
		First := []
		LayoutCatalogue_InstallLocal(Next, Dir, Changed, (Args*) => First.Push(Args))
		AssertEqual(1, First.Length, "refused public install finishes exactly once")
		AssertFalse(First[1][1], "native replacement refusal is reported")
		AssertEqual(Family == "record" ? LAYOUT_CATALOGUE_FAILURE_RECORD : LAYOUT_CATALOGUE_FAILURE_WRITE, First[1][2])
		AssertEqual(0, LayoutCatalogue_Busy(), "refused operation releases the actual catalogue lease")
		AssertEqual(BeforeRecord, _LCH_FileReceipt(RecordPath), "refused publication preserves the record bytes")
		if Family == "layout"
			AssertEqual(BeforeLayout, _LCH_FileReceipt(LayoutPath), "refused layout replacement preserves its bytes")
		StageLeft := FileExist(Stage) != ""
		LastGood := true
		try LayoutRegistry_ReadLocal("ergol", Dir)
		catch Error
			LastGood := false
		Lock.Close()
		Lock := 0
		Retry := []
		LayoutCatalogue_InstallLocal(Next, Dir, Changed, (Args*) => Retry.Push(Args))
		AssertEqual(1, Retry.Length, "fresh public retry settles exactly once")
		FileAppend("# layout-stage-refusal " . Family . " first_ok=" . First[1][1]
			. " stage_left=" . StageLeft . " last_good_readable=" . LastGood
			. " retry_ok=" . Retry[1][1] . "`n", "*")
		AssertTrue(Retry[1][1], "fresh install succeeds after native sharing denial is removed")
		AssertEqual(0, LayoutCatalogue_Busy())
		AssertEqual(Changed, LayoutRegistry_ReadLocal("ergol", Dir)["Text"])
		AssertEqual("2.0.0", LayoutCatalogue_ReadInstalled(Dir)["ergol"]["version"])
		AssertEqual("absent", _LCH_FileReceipt(Stage), "successful retry consumes its stage")
	} finally {
		if IsObject(Lock)
			Lock.Close()
		DirDelete(Dir, true)
	}
}

Test("composer declaration native refusal permits fresh retry (layout-stage-native-refusal-retry)", _LCSR_Composer)
for Family in ["layout", "record"]
	Test("layout native " . Family . " refusal permits fresh retry (layout-stage-native-refusal-retry)", _LCSR_Install.Bind(Family))
