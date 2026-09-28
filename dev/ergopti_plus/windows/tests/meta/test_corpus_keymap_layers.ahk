; static/ergopti_plus/windows/tests/meta/test_corpus_keymap_layers.ahk

; ==============================================================================
; MODULE: Layer-File Corpus Consumer (AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/keymap_layers/vectors.json through the AHK
; loader (platform/remap/layers_loader.ahk), which reads the shipped registry
; and vocabulary at run time exactly as the driver will. The JS gate and the
; macOS and Linux suites replay the same vectors through their own loaders, so
; a file accepted, rejected or resolved differently on Windows fails here.
;
; COVERAGE:
; 1. Every vector: the sorted error signatures and the resolved layers equal
;    the hand-written expectation, and `ok` is exactly "no error".
; 2. The user's layers.toml: an absent file is no layer; a present one is read
;    from the configuration folder under the vocabulary's file name; one that
;    exists but cannot be read is an error, never an empty layer.
; 3. Shipped data fails fast: a registry or vocabulary missing what the loader
;    reads throws instead of loading nothing.
; ==============================================================================

#Requires AutoHotkey v2.0

; Floor: a corpus that stopped being read would otherwise pass with nothing replayed.
global KL_CORPUS_MIN_VECTORS := 25





; ==================================
; ==================================
; ======= 1/ Corpus and data =======
; ==================================
; ==================================

; Two levels up from tests/ (windows/tests/ -> windows/ -> ergopti_plus/) where _shared/ lives.
_KLCorpus_SharedDir() => A_ScriptDir . "\..\..\_shared"

; THROWS when the corpus is missing or malformed: a cross-driver contract that
; can be deleted without the suite noticing is not a contract.
_KLCorpus_Load() {
	Path := _KLCorpus_SharedDir() . "\tests\corpus\keymap_layers\vectors.json"
	if !FileExist(Path)
		throw Error("keymap_layers corpus not found at '" . Path . "' — a missing corpus must fail this suite, never skip it")
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	if !(Corpus is Map) || !Corpus.Has("vectors") || !(Corpus["vectors"] is Array)
		throw Error("keymap_layers corpus did not parse into a vectors list")
	return Corpus
}

; Case-sensitive insertion sort: the error signatures carry layer ids whose case matters.
_KLCorpus_Sorted(List) {
	Out := []
	for Item in List {
		Index := Out.Length + 1
		while (Index > 1 && StrCompare(Out[Index - 1], Item, true) > 0)
			Index -= 1
		Out.InsertAt(Index, Item)
	}
	return Out
}

_KLCorpus_Join(List) {
	Text := ""
	for Item in List
		Text .= (A_Index == 1 ? "" : ", ") . Item
	return "[" . Text . "]"
}

_KLCorpus_Signatures(Result) {
	Signatures := []
	for Err in Result["errors"]
		Signatures.Push(KeymapLayers_ErrorSignature(Err))
	return _KLCorpus_Sorted(Signatures)
}

; Compares one vector's answer with its expectation; returns "" or the mismatches.
_KLCorpus_Replay(Vec, Ctx) {
	Id := Vec["id"]
	if Vec.Has("file") {
		Result := KeymapLayers_Load(Vec["os"], Ctx, FileRead(_KLCorpus_SharedDir() . "\keymap\" . Vec["file"], "UTF-8"))
	} else if (Vec["toml"] is String) {
		Result := KeymapLayers_Load(Vec["os"], Ctx, Vec["toml"])
	} else {
		; JSON null: the file is absent. The JS gate rejects any other type.
		Result := KeymapLayers_Load(Vec["os"], Ctx)
	}
	Problems := ""
	Actual := _KLCorpus_Join(_KLCorpus_Signatures(Result))
	Expected := _KLCorpus_Join(_KLCorpus_Sorted(Vec["expected"]["errors"]))
	if (Actual !== Expected)
		Problems .= "`n  " . Id . ": errors " . Actual . ", expected " . Expected
	ErrorCount := Result["errors"].Length
	if (Result["ok"] != (ErrorCount == 0))
		Problems .= "`n  " . Id . ": ok is " . Result["ok"] . " with " . ErrorCount . " error(s)"
	ExpectedLayers := Vec["expected"]["layers"]
	for LayerId, Bindings in Result["layers"] {
		if !ExpectedLayers.Has(LayerId) {
			Problems .= "`n  " . Id . ": layer '" . LayerId . "' is loaded but not expected"
			continue
		}
		ExpectedBindings := ExpectedLayers[LayerId]
		for Code, Resolution in Bindings {
			Text := KeymapLayers_FormatResolution(Resolution)
			Want := ExpectedBindings.Has(Code) ? ExpectedBindings[Code] : "(nothing)"
			if (Text !== Want)
				Problems .= "`n  " . Id . ": " . LayerId . "." . Code . " resolves to " . Text . ", expected " . Want
		}
		for Code in ExpectedBindings {
			if !Bindings.Has(Code)
				Problems .= "`n  " . Id . ": " . LayerId . "." . Code . " is not loaded, expected " . ExpectedBindings[Code]
		}
	}
	for LayerId in ExpectedLayers {
		if !Result["layers"].Has(LayerId)
			Problems .= "`n  " . Id . ": layer '" . LayerId . "' is expected but not loaded"
	}
	return Problems
}





; =======================================
; =======================================
; ======= 2/ Every vector replays =======
; =======================================
; =======================================

_KLCorpus_EveryVectorReplays() {
	global KL_CORPUS_MIN_VECTORS
	Corpus := _KLCorpus_Load()
	Ctx := KeymapLayers_LoadContext(_KLCorpus_SharedDir())
	Vectors := Corpus["vectors"]
	AssertTrue(Vectors.Length >= KL_CORPUS_MIN_VECTORS,
		"only " . Vectors.Length . " keymap_layers vectors (floor " . KL_CORPUS_MIN_VECTORS . ")")
	Problems := ""
	for Vec in Vectors
		Problems .= _KLCorpus_Replay(Vec, Ctx)
	AssertEqual("", Problems, "the AHK layer loader disagrees with the cross-driver corpus")
}
Test("keymap_layers corpus  --  every vector replays through the AHK loader", _KLCorpus_EveryVectorReplays)





; =========================================
; =========================================
; ======= 3/ The user's layers.toml =======
; =========================================
; =========================================

_KLCorpus_TempConfigDir() => A_Temp . "\ergopti_keymap_layers_test_" . ProcessExist()

_KLCorpus_AbsentUserFileIsNoLayer() {
	Ctx := KeymapLayers_LoadContext(_KLCorpus_SharedDir())
	Dir := _KLCorpus_TempConfigDir()
	DirCreate(Dir)
	try {
		if FileExist(Dir . "\layers.toml")
			FileDelete(Dir . "\layers.toml")
		Result := KeymapLayers_LoadUserFile(Ctx, Dir . "\")
		AssertEqual(Dir . "\layers.toml", Result["path"], "layers.toml lives at the root of the configuration folder")
		AssertTrue(Result["ok"], "an absent layers.toml must load cleanly")
		AssertEqual(0, Result["layers"].Count, "an absent layers.toml is no layer")
	} finally {
		DirDelete(Dir, true)
	}
}
Test("keymap_layers  --  an absent layers.toml is no layer and no error", _KLCorpus_AbsentUserFileIsNoLayer)

_KLCorpus_PresentUserFileResolves() {
	Ctx := KeymapLayers_LoadContext(_KLCorpus_SharedDir())
	Dir := _KLCorpus_TempConfigDir()
	DirCreate(Dir)
	try {
		FileAppend('[_meta]`nschema_version = 1`n`n[layers.nav.all]`n"KeyQ" = "sel_doc_start"`n', Dir . "\layers.toml", "UTF-8")
		Result := KeymapLayers_LoadUserFile(Ctx, Dir)
		AssertTrue(Result["ok"], "a valid layers.toml must load cleanly")
		AssertEqual("keystroke:ctrl+shift+Home", KeymapLayers_FormatResolution(Result["layers"]["nav"]["KeyQ"]))
	} finally {
		DirDelete(Dir, true)
	}
}
Test("keymap_layers  --  a present layers.toml resolves for Windows", _KLCorpus_PresentUserFileResolves)

_KLCorpus_UnreadableUserFileIsAnError() {
	Ctx := KeymapLayers_LoadContext(_KLCorpus_SharedDir())
	Dir := _KLCorpus_TempConfigDir()
	DirCreate(Dir)
	try {
		Path := Dir . "\layers.toml"
		FileAppend('[_meta]`nschema_version = 1`n`n[layers.nav.all]`n"KeyQ" = "sel_doc_start"`n', Path, "UTF-8")
		; A handle that shares nothing makes every other open fail, as a file
		; another program holds locked does.
		Lock := FileOpen(Path, "rw -rwd")
		try {
			Result := KeymapLayers_LoadUserFile(Ctx, Dir)
		} finally {
			Lock.Close()
		}
		AssertFalse(Result["ok"], "an unreadable layers.toml must not report ok")
		AssertEqual(1, Result["errors"].Length, "an unreadable layers.toml is exactly one error")
		AssertEqual("file_unreadable||||", KeymapLayers_ErrorSignature(Result["errors"][1]))
		AssertEqual(0, Result["layers"].Count, "an unreadable layers.toml binds nothing")
	} finally {
		DirDelete(Dir, true)
	}
}
Test("keymap_layers  --  an unreadable layers.toml is an error, not an empty layer", _KLCorpus_UnreadableUserFileIsAnError)





; ==========================================
; ==========================================
; ======= 4/ Shipped data fails fast =======
; ==========================================
; ==========================================

_KLCorpus_BrokenShippedDataThrows() {
	Sections := TOML_ParseFreshFile(_KLCorpus_SharedDir() . "\keymap\layer_actions.toml")
	Registry := JsonParse(FileRead(_KLCorpus_SharedDir() . "\data\keycodes\physical_keys.json", "UTF-8"))
	AssertThrows(() => KeymapLayers_NewContext(Map(), Sections), "a registry without keys must throw")
	WithoutMeta := Map()
	for Name, Section in Sections {
		if (Name !== "_meta")
			WithoutMeta[Name] := Section
	}
	AssertThrows(() => KeymapLayers_NewContext(Registry, WithoutMeta), "a vocabulary without [_meta] must throw")
	AssertThrows(() => KeymapLayers_LoadContext(A_Temp . "\no_such_shared_dir"), "a missing _shared folder must throw")
	Ctx := KeymapLayers_NewContext(Registry, Sections)
	AssertThrows(() => KeymapLayers_Load("beos", Ctx), "an OS the vocabulary does not know must throw")
}
Test("keymap_layers  --  broken shipped data throws instead of loading nothing", _KLCorpus_BrokenShippedDataThrows)
