; tests/unit/infra/config/scope/test_personal_file_captions.ahk

; ==============================================================================
; MODULE: Personal File and Folder Captions
; DESCRIPTION:
; Personal file and folder captions keep the original literal domains,
; consume the genuine file and folder providers, and withdraw late
; observers before any foreign read.
; ==============================================================================

#Requires AutoHotkey v2.0





; Original literal donor vectors use the actual formatter and finished native Menu.
_HSCS_PersonalFileCaptionUnits(Units) {
	Storage := Buffer((Units.Length + 1) * 2, 0)
	for Index, Unit in Units
		NumPut("UShort", Unit, Storage, (Index - 1) * 2)
	Value := StrGet(Storage, Units.Length, "UTF-16")
	_HSCS_PersonalFileCaptionCheckUnits(Value, Units)
	return Value
}

_HSCS_PersonalFileCaptionCheckUnits(Value, Units) {
	AssertEqual(Units.Length, StrLen(Value), "literal transport must retain each original UTF-16 unit")
	for Index, Unit in Units
		AssertEqual(Unit, Ord(SubStr(Value, Index, 1)), "unit-by-unit original integer oracle " . Index)
}

_HSCS_PersonalFileCaptionScalars() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_personal_file_parent_caption_original.json", "UTF-8"))
	Root := _MR_GetManifestRoot(), Key := "hotstring_personal_file_caption", Original := Root[Key]
	Child := Menu(), Primary := false, CleanupFailures := []
	Attempt(Owner, Operation) {
		try Operation.Call()
		catch Any as Failure
			CleanupFailures.Push(Map("owner", Owner, "failure", Failure))
	}
	try {
		Receipt := MenuRenderer_PersonalFileCaptionPolicy()
		AssertTrue(Receipt is Map, "the actual finite declaration is admitted")
		for Vector in Corpus["receipts"] {
			Stem := Vector.Has("stem_units") ? _HSCS_PersonalFileCaptionUnits(Vector["stem_units"]) : Vector["stem"]
			Expected := Vector.Has("expected_units") ? _HSCS_PersonalFileCaptionUnits(Vector["expected_units"]) : Vector["expected"]
			Row := MenuRenderer_PersonalFileParentRow(Receipt, Stem, Vector["formatted_count"], Child)
			AssertTrue(Row is Map, "original literal scalar domain survives " . Vector["name"])
			AssertEqual(Expected, Row["label"], "frozen donor caption remains literal " . Vector["name"])
			AssertTrue(Row["submenu"] == Child, "the exact finished native owner remains attached")
		}
		AssertThrows(() => _HSCS_PersonalFileCaptionCheckUnits("a" . Chr(0xFFFD) . "b", Corpus["receipts"][8]["stem_units"]),
			"normalization cannot make both input and expected transport silently agree")
		for Changed in [Map("format", "%s [%s]"), Map("format", "%s (%s)", "foreign", true)] {
			Root[Key] := Changed
			AssertFalse(MenuRenderer_PersonalFileParentRow(Receipt, "late_label", "2", Child), "replacement cannot reuse an original receipt")
			ChangedReceipt := MenuRenderer_PersonalFileCaptionPolicy()
			if ChangedReceipt is Map {
				Different := MenuRenderer_PersonalFileParentRow(ChangedReceipt, "late_label", "2", Child)
				AssertTrue(Different is Map && Different["label"] != Corpus["receipts"][2]["expected"], "changed shared punctuation breaks the independent donor outcome")
			} else
				AssertFalse(ChangedReceipt, "foreign closed-field metadata refuses")
			Root[Key] := Original
		}
		for Invalid in [Map("format", "%s"), Map("format", "%s %d"), Map("format", 1)] {
			Root[Key] := Invalid
			AssertFalse(MenuRenderer_PersonalFileCaptionPolicy(), "invalid finite format refuses actual admission")
		}
		Root.Delete(Key)
		AssertFalse(MenuRenderer_PersonalFileParentRow(Receipt, "late_label", "2", Child), "actual source withdrawal refuses the old receiver")
		Root[Key] := Original
		Repaired := MenuRenderer_PersonalFileParentRow(Receipt, "late_label", "2", Child)
		AssertEqual(Corpus["receipts"][2]["expected"], Repaired["label"], "exact shared repair restores the original receiver")
	} catch Any as Failure {
		Primary := true
		throw Failure
	} finally {
		Attempt("policy", (*) => Root[Key] := Original)
		Attempt("owned_delete", (*) => Child.Delete())
		Attempt("owned_prune", (*) => MenuDispatcher_PruneMenu(Child))
		Attempt("cleanup_report", (*) => _TestPrint("# ERGOPTI_PERSONAL_CAPTION_SCALAR_CLEANUP primary_present=" . Primary . " secondary_count=" . CleanupFailures.Length))
		if !Primary && CleanupFailures.Length
			throw CleanupFailures[1]["failure"]
	}
}
Test("shared-personal-file-caption: original literal domain, real shared mutations and finished native child", _HSCS_PersonalFileCaptionScalars)


; The actual unavailable-file producer retains its physical source and late read order.
_HSCS_PersonalFileCaptionNative(Kind, CallTarget := "formatter") {
	global _SharedDir, _FmtCountCache
	global _ParseExtTomlSectionsCache, _TomlFileCache, _TomlUnreadableFiles
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_personal_file_parent_caption_original.json", "UTF-8"))
	Root := _MR_GetManifestRoot(), Key := "hotstring_personal_file_caption", Original := Root[Key]
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedSectionsCache := IsSet(_ParseExtTomlSectionsCache) ? _ParseExtTomlSectionsCache : unset
	SavedFileCache := IsSet(_TomlFileCache) ? _TomlFileCache : unset
	SavedUnreadableCache := IsSet(_TomlUnreadableFiles) ? _TomlUnreadableFiles : unset
	Directory := A_Temp . "\ergopti-caption-" . A_TickCount . "-" . Random(10000, 99999)
	DirectoryOwned := false, Menus := [], HadPrimary := false, CleanupFailures := []
	StemReads := 0, CountReads := 0, ChildObserved := false, ForeignReads := 0
	PoisonedRoot := false, PoisonedOwner := false
	CallOwner := CallTarget == "formatter" ? _MR_CaptionValues : MenuRenderer_PersonalFileParentRow
	Primary := Error("original late personal-file stem failure")
	Source := '[[alpha]]`n"abcd" = "first"`n[[beta]]`n"qwer" = "second"`n'
	ReadStem(This, *) {
		StemReads += 1
		ChildObserved := _MenuDispatchOwnerHandles.Count > Before[5].Count
		if Kind == "late_withdraw"
			Root.Delete(Key)
		if Kind == "root_has" {
			Object.Prototype.DefineProp.Call(Root, "Has", {Call: ForeignObserver})
			PoisonedRoot := true
		} else if Kind == "call_owner" {
			Object.Prototype.DefineProp.Call(CallOwner, "Call", {Call: ForeignObserver})
			PoisonedOwner := true
		}
		if Kind == "stem_throw"
			throw Primary
		return Stem
	}
	ReadCount(This, *) {
		CountReads += 1
		return ActualCount
	}
	ForeignObserver(This, *) {
		ForeignReads += 1
		return false
	}
	RepairPoison(*) {
		if PoisonedRoot {
			Object.Prototype.DeleteProp.Call(Root, "Has")
			PoisonedRoot := false
		}
		if PoisonedOwner {
			Object.Prototype.DeleteProp.Call(CallOwner, "Call")
			PoisonedOwner := false
		}
	}
	RestoreCounts(*) {
		global _FmtCountCache
		_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
	}
	RestoreSectionsCache(*) {
		global _ParseExtTomlSectionsCache
		_ParseExtTomlSectionsCache := IsSet(SavedSectionsCache) ? SavedSectionsCache : unset
	}
	RestoreFileCache(*) {
		global _TomlFileCache
		_TomlFileCache := IsSet(SavedFileCache) ? SavedFileCache : unset
	}
	RestoreUnreadableCache(*) {
		global _TomlUnreadableFiles
		_TomlUnreadableFiles := IsSet(SavedUnreadableCache) ? SavedUnreadableCache : unset
	}
	DeleteDirectory(*) {
		if DirectoryOwned && DirExist(Directory)
			DirDelete(Directory, true)
	}
	Attempt(Owner, Operation) {
		try Operation.Call()
		catch Any as Failure
			CleanupFailures.Push(Map("owner", Owner, "failure", Failure))
	}
	try {
		; The headless host omits tray startup; own every cache used by the real parser.
		_ParseExtTomlSectionsCache := Map(), _TomlFileCache := Map(), _TomlUnreadableFiles := Map()
		AssertFalse(DirExist(Directory), "fresh physical fixture directory has no foreign owner")
		DirectoryOwned := true
		DirCreate(Directory)
		Path := Directory . "\late_label.toml"
		Assert(FSWriteDurable(Path, Source))
		AssertEqual(Source, FSReadUtf8Exact(Path))
		Sections := _ParseExtTomlSections(Path), ActualCount := 0
		for Section in Sections
			ActualCount += Section["count"]
		AssertEqual(2, ActualCount, "genuine native parsing supplies the original physical count")
		AssertFalse(PersonalFileControls.ForPath(Path), "fresh source genuinely has no adopted metadata owner")
		SplitPath Path, , , , &Stem
		AssertEqual("late_label", Stem, "real filename supplies the frozen donor stem")
		Cleaner := Menu(), Menus.Push(Cleaner)
		try Cleaner.Delete()
		finally MenuDispatcher_PruneMenu(Cleaner)
		Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
			_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
		for Table in Tables
			Before.Push(Table.Clone())
		AssertFalse(Object.Prototype.HasOwnProp.Call(Root, "Has"), "original root has no own Has descriptor")
		AssertFalse(Object.Prototype.HasOwnProp.Call(CallOwner, "Call"), "original real entry has no own Call descriptor")
		_FmtCountCache := Map()
		TF := {path: Path, sections: [], stem: Stem, count: ActualCount}
		TF.DeleteProp("stem"), TF.DefineProp("stem", {Get: ReadStem})
		TF.DeleteProp("count"), TF.DefineProp("count", {Get: ReadCount})
		if Kind == "mapping"
			Root[Key] := Map("format", "%s [%s]")
		else if Kind == "missing"
			Root.Delete(Key)
		Caught := false
		try {
			try Row := _HS_TomlFileRow(TF)
			catch Any as Failure {
				Caught := true
				ObservedFailure := Failure
			}
		} finally RepairPoison()
		if Caught
			AssertTrue(Kind == "stem_throw" && ObservedFailure == Primary, "raw original late primary identity is preserved")
		AssertEqual(0, ForeignReads, "no newly installed foreign owner may run before refusal")
		if IsSet(Row) && Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
			Menus.Push(Row["submenu"])
		if Kind == "stem_throw" {
			AssertTrue(Caught)
			AssertEqual(1, StemReads), AssertEqual(0, CountReads, "failed stem cannot read native count")
		} else if Kind == "missing" {
			AssertFalse(Caught), AssertFalse(Row)
			AssertEqual(0, StemReads), AssertEqual(0, CountReads, "missing policy has no late native observations")
		} else {
			AssertFalse(Caught)
			AssertEqual(1, StemReads), AssertEqual(1, CountReads, "original successful late reads happen once and in order")
			AssertTrue(ChildObserved, "real child construction and dispatcher registration precede the late stem read")
			if Kind == "late_withdraw" || Kind == "root_has" || Kind == "call_owner"
				AssertFalse(Row, "source withdrawn by the original stem observer refuses after the original count read")
			else {
				AssertTrue(Row is Map)
				if Kind == "mapping"
					AssertTrue(Row["label"] != Corpus["receipts"][2]["expected"], "actual shared mapping change makes the independent donor outcome red")
				else
					AssertEqual(Corpus["receipts"][2]["expected"], Row["label"])
			}
		}
		if Kind == "missing" || Kind == "late_withdraw" || Kind == "stem_throw" || Kind == "root_has" || Kind == "call_owner" {
			for Index, Table in Tables {
				AssertEqual(Before[Index].Count, Table.Count, "refusal or primary releases every newly registered child")
				for Id, Owner in Before[Index]
					AssertTrue(Table.Has(Id) && Table[Id] == Owner, "unrelated dispatcher owners remain exact")
			}
		}
		AssertEqual(Source, FSReadUtf8Exact(Path), "presentation never rewrites the actual physical source")
		Root[Key] := Original
		if Kind == "mapping" || Kind == "missing" || Kind == "late_withdraw" || Kind == "root_has" || Kind == "call_owner" {
			TF.DeleteProp("stem"), TF.DefineProp("stem", {Get: (*) => Stem})
			Repaired := _HS_TomlFileRow(TF)
			if Repaired is Map && Repaired.Has("submenu") && Repaired["submenu"] is Menu
				Menus.Push(Repaired["submenu"])
			AssertTrue(Repaired is Map)
			AssertEqual(Corpus["receipts"][2]["expected"], Repaired["label"], "exact policy repair restores the same native producer")
			AssertEqual(Source, FSReadUtf8Exact(Path))
		}
	} catch Any as Failure {
		HadPrimary := true
		throw Failure
	} finally {
		Attempt("exact_original_observer_descriptors", RepairPoison)
		Attempt("policy", (*) => Root[Key] := Original)
		Attempt("count_cache", RestoreCounts)
		Attempt("sections_cache", RestoreSectionsCache)
		Attempt("file_cache", RestoreFileCache)
		Attempt("unreadable_cache", RestoreUnreadableCache)
		for Native in Menus {
			Attempt("exact_owned_menu", _HS_PersonalReleaseMenus.Bind([Native]))
			Attempt("exact_owned_prune", MenuDispatcher_PruneMenu.Bind(Native))
		}
		Attempt("exact_owned_directory", DeleteDirectory)
		Attempt("cleanup_report", (*) => _TestPrint("# ERGOPTI_PERSONAL_CAPTION_CLEANUP primary_present=" . HadPrimary . " secondary_count=" . CleanupFailures.Length))
		if !HadPrimary && CleanupFailures.Length
			throw CleanupFailures[1]["failure"]
	}
}
for _HSCS_CaptionNativeKind in ["valid", "mapping", "missing", "late_withdraw", "stem_throw"]
	Test("shared-personal-file-caption: genuine file consumer and donor causality " . _HSCS_CaptionNativeKind,
		_HSCS_PersonalFileCaptionNative.Bind(_HSCS_CaptionNativeKind))


_HSCS_PersonalFileCaptionCallOwners() {
	for Target in ["formatter", "parent"]
		_HSCS_PersonalFileCaptionNative("call_owner", Target)
}
Test("shared-personal-file-caption: genuine late stem observer withdraws root Has before any foreign read",
	_HSCS_PersonalFileCaptionNative.Bind("root_has"))
Test("shared-personal-file-caption: genuine late stem observer withdraws formatter and parent Call owners",
	_HSCS_PersonalFileCaptionCallOwners)


; The raw scalar observations remain native; shared DATA owns only both formats.
_HSCS_PersonalFolderCaptionProject(Receipt, FolderName, FolderTotal, Child) {
	return (Positive := FolderTotal > 0,
		Count := Positive ? FmtCount(FolderTotal) . "" : "",
		NameReceipt := FolderName . "",
		Owner := Receipt["parent"],
		Owner != MenuRenderer_PersonalFolderParentRow || Object.Prototype.HasOwnProp.Call(Owner, "Call")
			? false : Owner.Call(Receipt, Positive, NameReceipt, Count, Child))
}

_HSCS_PersonalFolderCaptionScalars() {
	global _SharedDir, _FmtCountCache
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_personal_folder_parent_caption_original.json", "UTF-8"))
	Root := _MR_GetManifestRoot(), Key := "hotstring_personal_folder_caption", Original := Root[Key]
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	Child := Menu(), HadPrimary := false, CleanupFailures := [], CountReads := 0, PermitCount := false
	Primary := Error("original positive folder count observer failure")
	ReadCache(This, Number) {
		CountReads += 1
		if !PermitCount
			throw Primary
		return Map.Prototype.Has.Call(This, Number)
	}
	RestoreCounts(*) {
		global _FmtCountCache
		_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
	}
	Attempt(Owner, Operation) {
		try Operation.Call()
		catch Any as Failure
			CleanupFailures.Push(Map("owner", Owner, "failure", Failure))
	}
	try {
		Receipt := MenuRenderer_PersonalFolderCaptionPolicy()
		AssertTrue(Receipt is Map, "the actual finite folder declaration is admitted")
		AssertEqual(17, Corpus["receipts"].Length, "all original handwritten vectors survive")
		for Vector in Corpus["receipts"] {
			CountReads := 0, PermitCount := Vector["fmt_count_called"]
			_FmtCountCache := Map()
			if PermitCount
				_FmtCountCache[Vector["total"]] := Vector["formatted_count"]
			_FmtCountCache.DefineProp("Has", {Call: ReadCache})
			FolderName := Vector.Has("folder_units") ? _HSCS_PersonalFileCaptionUnits(Vector["folder_units"]) : Vector["folder_name"]
			Expected := Vector.Has("expected_units") ? _HSCS_PersonalFileCaptionUnits(Vector["expected_units"]) : Vector["expected"]
			Row := _HSCS_PersonalFolderCaptionProject(Receipt, FolderName, Vector["total"], Child)
			AssertTrue(Row is Map, "original scalar domain survives " . Vector["name"])
			AssertEqual(Expected, Row["label"], "independent original donor remains literal " . Vector["name"])
			if Vector.Has("expected_units")
				_HSCS_PersonalFileCaptionCheckUnits(Row["label"], Vector["expected_units"])
			AssertEqual(PermitCount ? 1 : 0, CountReads, "only the original positive branch observes FmtCount")
			AssertTrue(Row["submenu"] == Child, "the exact finished native child remains attached")
		}
		AssertThrows(() => _HSCS_PersonalFileCaptionCheckUnits("a" . Chr(0xFFFD) . "b", Corpus["receipts"][14]["folder_units"]),
			"a shared UTF-16 conversion mistake cannot satisfy the frozen integer oracle")
		_FmtCountCache := Map(2, "2"), CountReads := 0, PermitCount := true
		_FmtCountCache.DefineProp("Has", {Call: ReadCache})
		AssertThrows(() => _HSCS_PersonalFolderCaptionProject(Receipt, {}, 2, Child), "object name is refused only by the original native outer concatenation")
		AssertEqual(1, CountReads, "positive count is observed before the invalid outer name")
		_FmtCountCache[2] := {}, CountReads := 0
		AssertThrows(() => _HSCS_PersonalFolderCaptionProject(Receipt, "x", 2, Child), "object count is refused by the original native inner concatenation")
		AssertEqual(1, CountReads)
		PermitCount := false, CountReads := 0, Caught := false
		try _HSCS_PersonalFolderCaptionProject(Receipt, {}, 2, Child)
		catch Any as Failure {
			Caught := true
			AssertTrue(Failure == Primary, "the original positive count primary precedes invalid name coercion")
		}
		AssertTrue(Caught), AssertEqual(1, CountReads)
		PermitCount := true, _FmtCountCache := Map(2, "2")
		for Changed in [Map("positive_format", "%s [%s]", "nonpositive_format", "%s"),
			Map("positive_format", "%s (%s)", "nonpositive_format", "%s zero")] {
			Root[Key] := Changed
			AssertFalse(_HSCS_PersonalFolderCaptionProject(Receipt, "Folder", 2, Child), "a replaced policy cannot reuse the original receipt")
			ChangedReceipt := MenuRenderer_PersonalFolderCaptionPolicy()
			AssertTrue(ChangedReceipt is Map, "a different valid shared mapping is genuinely admitted")
			PositiveRow := _HSCS_PersonalFolderCaptionProject(ChangedReceipt, "Folder", 2, Child)
			ZeroRow := _HSCS_PersonalFolderCaptionProject(ChangedReceipt, "Folder", 0, Child)
			AssertTrue(PositiveRow["label"] != Corpus["receipts"][3]["expected"] || ZeroRow["label"] != Corpus["receipts"][1]["expected"],
				"altering either shared selection mapping makes an independent original outcome red")
			Root[Key] := Original
		}
		for Invalid in [Map("positive_format", "%s", "nonpositive_format", "%s"),
			Map("positive_format", "%s (%s)", "nonpositive_format", "%s %s"),
			Map("positive_format", "%s (%s)"), Map("positive_format", 1, "nonpositive_format", "%s"),
			Map("positive_format", "%s (%s)", "nonpositive_format", "%s", "foreign", true)] {
			Root[Key] := Invalid
			AssertFalse(MenuRenderer_PersonalFolderCaptionPolicy(), "malformed closed optional suffix DATA refuses")
		}
		Root.Delete(Key)
		AssertFalse(_HSCS_PersonalFolderCaptionProject(Receipt, "Folder", 2, Child), "actual withdrawal refuses the retained receiver")
		Root[Key] := Original
		AssertEqual(Corpus["receipts"][3]["expected"], _HSCS_PersonalFolderCaptionProject(Receipt, "Folder", 2, Child)["label"], "exact original DATA repair restores the same receipt")
	} catch Any as Failure {
		HadPrimary := true
		throw Failure
	} finally {
		Attempt("policy", (*) => Root[Key] := Original)
		Attempt("count_cache", RestoreCounts)
		Attempt("owned_delete", (*) => Child.Delete())
		Attempt("owned_prune", (*) => MenuDispatcher_PruneMenu(Child))
		Attempt("cleanup_report", (*) => _TestPrint("# ERGOPTI_PERSONAL_FOLDER_SCALAR_CLEANUP primary_present=" . HadPrimary . " secondary_count=" . CleanupFailures.Length))
		if !HadPrimary && CleanupFailures.Length
			throw CleanupFailures[1]["failure"]
	}
}
Test("shared-personal-folder-caption: all original scalar vectors and native count-before-name coercion", _HSCS_PersonalFolderCaptionScalars)


; Exercise the genuine physical-file folder producer and its unchanged release path.
_HSCS_PersonalFolderCaptionNative(Kind) {
	global _SharedDir, _FmtCountCache
	global _ParseExtTomlSectionsCache, _TomlFileCache, _TomlUnreadableFiles
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\windows_personal_folder_parent_caption_original.json", "UTF-8"))
	Root := _MR_GetManifestRoot(), Key := "hotstring_personal_folder_caption", Original := Root[Key]
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedSectionsCache := IsSet(_ParseExtTomlSectionsCache) ? _ParseExtTomlSectionsCache : unset
	SavedFileCache := IsSet(_TomlFileCache) ? _TomlFileCache : unset
	SavedUnreadableCache := IsSet(_TomlUnreadableFiles) ? _TomlUnreadableFiles : unset
	Directory := A_Temp . "\ergopti-folder-caption-" . A_TickCount . "-" . Random(10000, 99999)
	DirectoryOwned := false, Menus := [], HadPrimary := false, CleanupFailures := []
	CountReads := 0, FormatReads := 0, ChildObserved := false, ForeignReads := 0
	PoisonedRoot := false, PoisonedOwner := false, Held := []
	CallOwner := Kind == "parent_call" ? MenuRenderer_PersonalFolderParentRow : _MR_CaptionValues
	Primary := Error("original late folder count failure")
	Source := '[[alpha]]`n"abcd" = "first"`n[[beta]]`n"qwer" = "second"`n'
	ReadCount(This, *) {
		CountReads += 1
		if CountReads == 2 {
			ChildObserved := false
			for Handle in _MenuDispatchOwnerHandles
				if !Before[5].Has(Handle) {
					Native := MenuFromHandle(Handle)
					if Native is Menu && TrayMenuItemCount(Native) > 0
						ChildObserved := true
				}
			if Kind == "valid_rows" {
				AssertEqual(2, Held.Length, "the actual folder and file child were allocated before late total")
				AssertEqual(1, TrayMenuItemCount(Held[1]), "actual folder frame is filled before _HS_NodeTotal observes count")
				AssertEqual(Held[2].Handle, TrayMenuSubmenuHandle(Held[1].Handle, 0), "real file child is already attached to the exact native folder")
			}
			if Kind == "late_withdraw"
				Root.Delete(Key)
			if Kind == "root_has" {
				Object.Prototype.DefineProp.Call(Root, "Has", {Call: ForeignObserver})
				PoisonedRoot := true
			} else if Kind == "formatter_call" || Kind == "parent_call" {
				Object.Prototype.DefineProp.Call(CallOwner, "Call", {Call: ForeignObserver})
				PoisonedOwner := true
			}
			if Kind == "total_throw"
				throw Primary
		}
		return ActualCount
	}
	ReadCache(This, Number) {
		FormatReads += 1
		if Kind == "format_throw" && FormatReads == 2
			throw Primary
		return Map.Prototype.Has.Call(This, Number)
	}
	ForeignObserver(This, *) {
		ForeignReads += 1
		return false
	}
	RepairPoison(*) {
		if PoisonedRoot {
			Object.Prototype.DeleteProp.Call(Root, "Has")
			PoisonedRoot := false
		}
		if PoisonedOwner {
			Object.Prototype.DeleteProp.Call(CallOwner, "Call")
			PoisonedOwner := false
		}
	}
	RestoreCounts(*) {
		global _FmtCountCache
		_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
	}
	RestoreSectionsCache(*) {
		global _ParseExtTomlSectionsCache
		_ParseExtTomlSectionsCache := IsSet(SavedSectionsCache) ? SavedSectionsCache : unset
	}
	RestoreFileCache(*) {
		global _TomlFileCache
		_TomlFileCache := IsSet(SavedFileCache) ? SavedFileCache : unset
	}
	RestoreUnreadableCache(*) {
		global _TomlUnreadableFiles
		_TomlUnreadableFiles := IsSet(SavedUnreadableCache) ? SavedUnreadableCache : unset
	}
	DeleteDirectory(*) {
		if DirectoryOwned && DirExist(Directory)
			DirDelete(Directory, true)
	}
	Attempt(Owner, Operation) {
		try Operation.Call()
		catch Any as Failure
			CleanupFailures.Push(Map("owner", Owner, "failure", Failure))
	}
	CollectKnownMenus(*) {
		for Native in Held
			Menus.Push(Native)
		if IsSet(Before) {
			for Handle in _MenuDispatchOwnerHandles
				if !Before[5].Has(Handle) {
					Native := MenuFromHandle(Handle)
					if Native is Menu
						Menus.Push(Native)
				}
		}
	}
	try {
		; The headless host omits tray startup; own every cache used by the real parser.
		_ParseExtTomlSectionsCache := Map(), _TomlFileCache := Map(), _TomlUnreadableFiles := Map()
		AssertFalse(DirExist(Directory), "fresh physical directory has no foreign owner")
		DirectoryOwned := true, DirCreate(Directory)
		Path := Directory . "\late_label.toml"
		Assert(FSWriteDurable(Path, Source)), AssertEqual(Source, FSReadUtf8Exact(Path))
		Sections := _ParseExtTomlSections(Path), ActualCount := 0
		for Section in Sections
			ActualCount += Section["count"]
		AssertEqual(2, ActualCount, "the actual TOML parser supplies the independent positive total")
		AssertFalse(PersonalFileControls.ForPath(Path), "the actual physical source has no adopted owner")
		TF := {path: Path, sections: [], stem: "late_label", count: ActualCount}
		TF.DeleteProp("count"), TF.DefineProp("count", {Get: ReadCount})
		Tree := Map("Folder", Map("tomls", [TF], "subfolders", Map()))
		Cleaner := Menu(), Menus.Push(Cleaner)
		try Cleaner.Delete()
		finally MenuDispatcher_PruneMenu(Cleaner)
		Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
			_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
		for Table in Tables
			Before.Push(Table.Clone())
		AssertFalse(Object.Prototype.HasOwnProp.Call(Root, "Has"), "actual root starts without a foreign Has descriptor")
		AssertFalse(Object.Prototype.HasOwnProp.Call(CallOwner, "Call"), "actual retained owner starts without a foreign Call descriptor")
		_FmtCountCache := Map(ActualCount, "2"), _FmtCountCache.DefineProp("Has", {Call: ReadCache})
		if Kind == "mapping"
			Root[Key] := Map("positive_format", "%s [%s]", "nonpositive_format", "%s")
		else if Kind == "missing"
			Root.Delete(Key)
		Rows := [], Caught := false
		try {
			if Kind == "valid_rows"
				Accepted := _HS_RenderTree(Tree, Rows, Held)
			else
				Accepted := _HS_RenderTree(Tree, Rows)
		} catch Any as Failure {
			Caught := true
			AssertTrue((Kind == "total_throw" || Kind == "format_throw") && Failure == Primary, "original late count/formatter primary identity survives production cleanup")
		}
		AssertEqual(0, ForeignReads, "late observer cannot invoke newly installed foreign Root.Has or Call before refusal")
		if Kind == "total_throw" || Kind == "format_throw"
			AssertTrue(Caught)
		else {
			AssertFalse(Caught)
			AssertEqual(Kind == "valid_rows" || Kind == "mapping", Accepted)
		}
		AssertEqual(Kind == "missing" ? 0 : 2, CountReads, "genuine file count precedes exactly one late _HS_NodeTotal read")
		AssertEqual(Kind == "missing" ? 0 : Kind == "total_throw" ? 1 : 2, FormatReads, "original positive count format is not evaluated before late total")
		if Kind != "missing"
			AssertTrue(ChildObserved, "real finished registered child exists before late total")
		if Kind == "valid_rows" || Kind == "mapping" {
			AssertEqual(1, Rows.Length)
			AssertTrue(Rows[1]["submenu"] is Menu), Menus.Push(Rows[1]["submenu"])
			AssertEqual(1, TrayMenuItemCount(Rows[1]["submenu"]), "returned exact folder keeps its finished child")
			if Kind == "mapping"
				AssertTrue(Rows[1]["label"] != Corpus["receipts"][3]["expected"], "changing only actual shared mapping makes the native donor result red")
			else
				AssertEqual(Corpus["receipts"][3]["expected"], Rows[1]["label"])
		} else {
			AssertEqual(0, Rows.Length, "no incomplete folder is published after source refusal or late primary")
			for Index, Table in Tables {
				AssertEqual(Before[Index].Count, Table.Count, "production refusal retired only the actual new unpublished children")
				for Id, Owner in Before[Index]
					AssertTrue(Table.Has(Id) && Table[Id] == Owner, "every foreign dispatcher identity remains exact")
			}
		}
		AssertEqual(Source, FSReadUtf8Exact(Path), "caption presentation never rewrites original physical source")
	} catch Any as Failure {
		HadPrimary := true
		throw Failure
	} finally {
		Attempt("original_observer_descriptors", RepairPoison)
		Attempt("policy", (*) => Root[Key] := Original)
		Attempt("count_cache", RestoreCounts)
		Attempt("sections_cache", RestoreSectionsCache)
		Attempt("file_cache", RestoreFileCache)
		Attempt("unreadable_cache", RestoreUnreadableCache)
		Attempt("exact_owned_capture", CollectKnownMenus)
		for Native in Menus {
			Attempt("exact_owned_menu", _HS_PersonalReleaseMenus.Bind([Native]))
			Attempt("exact_owned_prune", MenuDispatcher_PruneMenu.Bind(Native))
		}
		Attempt("exact_owned_directory", DeleteDirectory)
		Attempt("cleanup_report", (*) => _TestPrint("# ERGOPTI_PERSONAL_FOLDER_NATIVE_CLEANUP kind=" . Kind . " primary_present=" . HadPrimary . " secondary_count=" . CleanupFailures.Length))
		if !HadPrimary && CleanupFailures.Length
			throw CleanupFailures[1]["failure"]
	}
}
for _HSCS_FolderCaptionKind in ["valid_rows", "mapping", "missing", "late_withdraw", "total_throw", "format_throw", "root_has", "formatter_call", "parent_call"]
	Test("shared-personal-folder-caption: genuine filled folder, late total and original owner " . _HSCS_FolderCaptionKind,
		_HSCS_PersonalFolderCaptionNative.Bind(_HSCS_FolderCaptionKind))

; Every folder level returns row data; the retired mode that appended a level
; into a caller's Menu natively must stay refused before anything is allocated.
_HSCS_PersonalFolderRefusesParentMenu() {
	Parent := Menu(), Held := []
	try {
		Refused := false
		try _HS_RenderTree(Map("Folder", Map("tomls", [], "subfolders", Map())), Parent, Held)
		catch TypeError
			Refused := true
		AssertTrue(Refused, "a native parent menu in place of the row array is refused")
		AssertEqual(0, Held.Length, "the refusal allocates no folder menu")
		AssertEqual(0, TrayMenuItemCount(Parent), "the refused parent receives no row")
	} finally MenuDispatcher_PruneMenu(Parent)
}
Test("shared-personal-folder-caption: a folder level never appends into a native parent menu",
	_HSCS_PersonalFolderRefusesParentMenu)
