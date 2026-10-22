; tests/unit/modules/shortcuts/test_open_target_vectors.ahk

; ==============================================================================
; MODULE: copy_selected_path open-target corpus (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/shortcuts/open_target_vectors.json, which the
; macOS and Linux suites replay against _shared/lua/open_target too, through
; OpenTarget_Classify with the corpus's Windows environment, then checks that
; SearchPath (the copy_selected_path action outside Explorer) opens what the
; classifier names instead of searching for it.
;
; ROOT CAUSE ENCODED:
; SearchPath only knew drive paths, registry keys, scheme URLs and domain names
; whose last label is letters, so a selected IP address such as 192.168.1.1
; (or 10.0.0.1:8080/admin, localhost:3000, [::1]) was sent to the search
; engine instead of the browser (open-target-ip-address).
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Corpus replay ========
; =================================
; =================================

; @returns {Map} The decoded corpus.
_OTV_ReadCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\shortcuts\open_target_vectors.json"
	AssertTrue(FileExist(Path) != "", "the open-target corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; @returns {Map} What a vector expects on Windows.
_OTV_Expected(Vector) {
	return Vector.Has("windows") ? Vector["windows"] : Vector["expect"]
}

_OTV_ReplayCorpus() {
	Corpus := _OTV_ReadCorpus()
	Env := Corpus["env"]["windows"]
	EnvFn := (Name) => Env.Get(Name, "")
	Checked := 0
	Kinds := Map()
	for _, Vector in Corpus["vectors"] {
		Want := _OTV_Expected(Vector)
		Got := OpenTarget_Classify(Vector["text"], EnvFn)
		AssertEqual(Want["kind"], Got["kind"], Vector["id"] . ": kind")
		AssertTrue(Want["target"] == Got["target"],
			Vector["id"] . ": target '" . Got["target"] . "', expected '" . Want["target"] . "'")
		AssertTrue(Want.Get("reason", "") == Got["reason"], Vector["id"] . ": reason")
		Kinds[Got["kind"]] := true
		Checked += 1
	}
	AssertTrue(Checked >= 60, "expected at least 60 open-target vectors, found " . Checked)
	for _, Kind in ["url", "path", "registry", "search", "file_name", "empty"]
		AssertTrue(Kinds.Has(Kind), "the corpus must exercise the " . Kind . " kind on Windows")
}
Test("copy_selected_path: the classifier replays the shared open-target corpus (open-target-ip-address)",
	_OTV_ReplayCorpus)

; The Lua port's lists must be this port's lists: the JS gate compares the two
; files, this checks the Windows copy is the one the classifier reads.
_OTV_ListsAreTheClassifiers() {
	global OPEN_TARGET_FILE_EXTENSIONS, OPEN_TARGET_WINDOWS_SCHEMES
	AssertTrue(OPEN_TARGET_FILE_EXTENSIONS.Length >= 50, "the file-extension list must be loaded")
	AssertEqual("file_name", OpenTarget_Classify("x." . OPEN_TARGET_FILE_EXTENSIONS[1])["kind"])
	AssertEqual("url", OpenTarget_Classify(OPEN_TARGET_WINDOWS_SCHEMES[1] . ":")["kind"])
}
Test("copy_selected_path: the classifier reads its own vocabularies (open-target-ip-address)",
	_OTV_ListsAreTheClassifiers)





; ==============================================
; ==============================================
; ======= 2/ The action opens the target =======
; ==============================================
; ==============================================

; Runs SearchPath on Text with recording ports and the search feature stubbed.
; @returns {Map} Map("launches", [...], "reports", [...], "opened", Boolean).
_OTV_Dispatch(Text) {
	global Features
	Saved := Features
	Launches := [], Reports := []
	Launch := (Target, WorkingDir := "", Options := "") => Launches.Push(Target)
	Report := (Key, Target, Reason) => Reports.Push(Key)
	try {
		Features := Map("shortcuts", Map("search", Map(
			"search_engine", "https://search.invalid/",
			"search_engine_url_query", "https://search.invalid/?q=")))
		Opened := SearchPath(Text, Launch, Report)
	} finally Features := Saved
	return Map("launches", Launches, "reports", Reports, "opened", Opened)
}

_OTV_OpensAddress(Text, Expected) {
	Result := _OTV_Dispatch(Text)
	AssertTrue(Result["opened"], Text . " must be opened")
	AssertEqual(1, Result["launches"].Length, Text . " must launch exactly once")
	AssertTrue(Result["launches"][1] == Expected,
		Text . " must open " . Expected . ", not a web search: got " . Result["launches"][1])
	AssertEqual(0, Result["reports"].Length, Text . " reports nothing")
}
for _OTV_Index, _OTV_Case in [
	["192.168.1.1", "http://192.168.1.1"],
	["10.0.0.1:8080/admin", "http://10.0.0.1:8080/admin"],
	["localhost:3000", "http://localhost:3000"],
	["[::1]:8080", "http://[::1]:8080"],
	["ada@example.com", "mailto:ada@example.com"],
	["ms-settings:display", "ms-settings:display"]
]
	Test("copy_selected_path: opens a selected address " . _OTV_Index . " (open-target-ip-address)",
		_OTV_OpensAddress.Bind(_OTV_Case[1], _OTV_Case[2]))

_OTV_ReportsWhatItCannotOpen() {
	for _, Probe in [
		["notes.txt", "open_target.bare_file_name"],
		["C:\ergopti-open-target-missing-" . A_TickCount . "\x.txt", "open_target.missing_path"]
	] {
		Result := _OTV_Dispatch(Probe[1])
		AssertFalse(Result["opened"], Probe[1] . " is not opened")
		AssertEqual(0, Result["launches"].Length, Probe[1] . " must launch nothing, not even a search")
		AssertEqual(1, Result["reports"].Length, Probe[1] . " must be reported")
		AssertEqual(Probe[2], Result["reports"][1], Probe[1] . ": report key")
	}
}
Test("copy_selected_path: a target it cannot open is reported, never searched (open-target-missing-path-reported)",
	_OTV_ReportsWhatItCannotOpen)

_OTV_ExistingFolderOpens() {
	Result := _OTV_Dispatch("%SystemRoot%")
	AssertTrue(Result["opened"], "an existing folder named by a variable is opened")
	AssertTrue(Result["launches"][1] == '"' . EnvGet("SystemRoot") . '"',
		"the folder is expanded and quoted as one file")
}
Test("copy_selected_path: a variable path to an existing folder opens it (open-target-ip-address)",
	_OTV_ExistingFolderOpens)

_OTV_ReportKeysAreTranslated() {
	for _, Key in ["open_target.missing_path", "open_target.bare_file_name", "open_target.open_failed"] {
		Text := t(Key)
		AssertTrue(Text != Key && InStr(Text, "%s"), Key . " must be a translated message holding %s")
	}
}
Test("copy_selected_path: every report has its translated message (open-target-missing-path-reported)",
	_OTV_ReportKeysAreTranslated)
