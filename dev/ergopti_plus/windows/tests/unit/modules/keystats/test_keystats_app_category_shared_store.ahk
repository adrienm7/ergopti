; tests/unit/modules/keystats/test_keystats_app_category_shared_store.ahk

; ==============================================================================
; MODULE: App Category Shared Store Regressions
; DESCRIPTION:
; Windows keeps the document macOS and Linux share, in the same place: a flat
; string file is refused without being migrated, lost or overwritten, and the
; driver keeps classifying from its defaults.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLACSS_With(Callback) {
	static Serial := 0
	Saved := Map()
	Properties := ["categories", "file_path", "metrics_root", "dirty", "save_fn", "write_owner", "store_model"]
	for Key in Properties
		if KLAppCat.HasOwnProp(Key)
			Saved[Key] := KLAppCat.%Key%
	Root := A_Temp . "\ergopti_appcat_shared_" . A_ScriptHwnd . "_" . ++Serial
	Captured := []
	Timer := (*) => 0
	try {
		DirCreate(Root)
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.metrics_root := "", KLAppCat.dirty := false
		KLAppCat.save_fn := Timer, KLAppCat.write_owner := 0, KLAppCat.store_model := 0
		LoggerSetTestSink((Line) => Captured.Push(Line))
		Callback.Call(Root, Root . "\" . KLAppCatConst.FILE_NAME, Captured)
	} finally {
		LoggerClearTestSink()
		try SetTimer(Timer, 0)
		for Key in Properties {
			if Saved.Has(Key)
				KLAppCat.%Key% := Saved[Key]
			else if KLAppCat.HasOwnProp(Key)
				KLAppCat.DeleteProp(Key)
		}
		DirDelete(Root, true)
	}
}

_KLACSS_Logged(Captured, Text) {
	for Line in Captured
		if InStr(Line, "[KLAppCat]") && InStr(Line, Text)
			return true
	return false
}

_KLACSS_FlatFormIsRefused(Root, Path, Captured) {
	Flat := '{"code.exe":"my own label","private.exe":"mine"}' . "`n"
	AssertTrue(FSWriteCreateDurable(Path, Flat))
	AssertTrue(KL_AppCat_Init(Root), "a refused flat file must leave the driver working")
	AssertTrue(_KLACSS_Logged(Captured, "old flat string form"), "the refusal must be stated in the log")
	AssertEqual("productive", KL_AppCat_Get("code.exe"), "the refused file's labels are not read: the defaults classify")
	AssertEqual("unknown", KL_AppCat_Get("private.exe"), "a refused entry is not migrated")
	AssertEqual("unknown", KL_AppCat_Get("new.exe"), "a discovery still classifies")
	KL_AppCat_DeferredSave()
	AssertFalse(KLAppCat.dirty, "a refused store leaves no debt to retry")
	AssertEqual(Flat, FSReadUtf8Exact(Path), "a discovery never overwrites the refused file")
	KL_AppCat_Get("late.exe")
	AssertTrue(KL_AppCat_PrepareShutdown(), "a refused store must not block the exit")
	AssertEqual(Flat, FSReadUtf8Exact(Path), "the shutdown never overwrites the refused file")
	AssertFalse(KL_AppCat_Set("code.exe", "edit"), "an edit is refused while the file is")
	AssertTrue(KL_AppCat_EditorSnapshot("code.exe", Root) is Integer, "the editor gets no default from a refused file")
	AssertEqual(0, KL_AppCat_ProjectAt(Root, ["code.exe"]).Count, "the dashboard keeps rendering, without any edit")
	AssertEqual(Flat, FSReadUtf8Exact(Path), "every refused path leaves the file byte for byte")

	Replaced := '{"schema":"ergopti.app_categories","version":1,"apps":{"code.exe":{"type":"mine","score":2}}}'
	AssertTrue(FSWriteDurable(Path, Replaced))
	AssertTrue(KL_AppCat_Reload(), "a reload admits the replaced file")
	AssertEqual("mine", KL_AppCat_Get("code.exe"))
	AssertFalse(_KL_AppCat_StoreRefused(), "the refusal ends with the file that caused it")
	KL_AppCat_Get("after.exe")
	AssertTrue(KL_AppCat_Save(), "saving works again")
	AssertEqual("unknown", JsonParse(FSReadStrict(Path))["apps"]["after.exe"]["type"])
}
Test("App category store: a flat string file is refused and stays untouched (app-category-flat-refused)",
	_KLACSS_With.Bind(_KLACSS_FlatFormIsRefused))

_KLACSS_VersionedStringIsRefused(Root, Path, Captured) {
	AssertThrows(_KL_AppCat_DecodeStore.Bind('{"schema":"ergopti.app_categories","version":1,"apps":{"a.exe":"x"}}'),
		"a string entry is refused in the versioned layout too")
	AssertThrows(_KL_AppCat_DecodeStore.Bind('{"a.exe":{"type":"x","score":0},"b.exe":"y"}'),
		"a flat map with one string entry is refused whole")
}
Test("App category store: a string entry is refused in every layout (app-category-flat-refused)",
	_KLACSS_With.Bind(_KLACSS_VersionedStringIsRefused))

; The location is the root of the configuration folder, not the driver subfolder
; holding config.toml: macOS writes get_config_dir() .. FILE_NAME and Linux
; ConfigPaths.config(FILE_NAME), so a shared folder holds one file.
_KLACSS_Location(Root, Path, Captured) {
	global _ConfigDir
	AssertEqual(RTrim(_ConfigDir, "\"), KL_AppCat_StoreDir())
	Keystats := _DriverFuncBody("KL_Init")
	AssertContains(Keystats, "KL_AppCat_Init(KL_AppCat_StoreDir(), metrics_dir)")
	Producer := _DriverFuncBody("KLPF_BuildAndWriteToPath")
	AssertTrue(Producer != "" && InStr(Producer, "KL_AppCat_StoreDir()") > 0, "the worker reads the same store")

	Metrics := Root . "\metrics"
	Store := Root . "\store"
	DirCreate(Metrics), DirCreate(Store)
	Retired := Metrics . "\" . KLAppCatConst.FILE_NAME
	Old := '{"code.exe":"old label"}'
	AssertTrue(FSWriteCreateDurable(Retired, Old))
	AssertTrue(KL_AppCat_Init(Store, Metrics))
	AssertTrue(_KLACSS_Logged(Captured, "is no longer read"), "the file left behind must be stated, not silently ignored")
	AssertEqual(Old, FSReadUtf8Exact(Retired), "the file left behind stays untouched")
	AssertEqual("productive", KL_AppCat_Get("code.exe"), "the file left behind is not read")
	AssertTrue(FSStrictExists(Store . "\" . KLAppCatConst.FILE_NAME), "the first-run file lands in the store folder")
	AssertFalse(_KL_AppCat_StoreRefused())
	Snapshot := KL_AppCat_EditorSnapshot("code.exe", Metrics)
	AssertTrue(Snapshot is Map, "the dashboard of this metrics store may edit the store")
	AssertTrue(KL_AppCat_EditorSnapshot("code.exe", Store) is Integer, "a foreign metrics root may not")
	AssertTrue(KL_AppCat_CommitEdit(Snapshot, "Reviewed", 1))
	AssertEqual("Reviewed", JsonParse(FSReadStrict(Store . "\" . KLAppCatConst.FILE_NAME))["apps"]["code.exe"]["type"])
	AssertEqual(Old, FSReadUtf8Exact(Retired))
}
Test("App category store: it lives in the configuration root and only says the old file stays (app-category-location)",
	_KLACSS_With.Bind(_KLACSS_Location))

_KLACSS_UneditedRecordsAreNoOverride(Root, Path, Captured) {
	AssertTrue(KL_AppCat_Init(Root))
	KL_AppCat_Get("discovered.exe")
	AssertTrue(KL_AppCat_Save())
	Apps := ["code.exe", "discovered.exe"]
	AssertEqual(0, KL_AppCat_ProjectAt(Root, Apps).Count,
		"the first-run and discovered records say nothing about the history")
	AssertTrue(KL_AppCat_CommitEdit(KL_AppCat_EditorSnapshot("code.exe", Root), "productive", 1))
	Projected := KL_AppCat_ProjectAt(Root, Apps)
	AssertEqual(1, Projected.Count, "an edited score overrides")
	AssertEqual(1, Projected["code.exe"]["score"])
}
Test("App category store: first-run and discovered records override no history (app-category-unedited-no-override)",
	_KLACSS_With.Bind(_KLACSS_UneditedRecordsAreNoOverride))
