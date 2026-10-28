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
