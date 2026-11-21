; tests/unit/ai/servers/test_ollama_runtime_uninstall.ahk

; ==============================================================================
; MODULE: Managed Ollama Uninstall
; DESCRIPTION:
; Replays the shared uninstall vectors through the Windows port of the
; sequence, then drives the real file step on a scratch folder (models kept or
; removed, a link refused before anything goes) and the menu action's two
; questions over scripted ports. Nothing real is stopped or removed.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaUninstallVectors() {
	global _SharedDir, JSON_NULL
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\ollama_uninstall_vectors.json", "UTF-8"))
	AssertTrue(Corpus["cases"].Length >= 8, "the uninstall vectors are read")
	Refused := "", Calls := [], FilesFlag := "", Busy := false
	for Vector in Corpus["cases"] {
		Refused := Vector["refuse"] == JSON_NULL ? "" : Vector["refuse"]
		Calls := [], Results := [], FilesFlag := "", Busy := Vector["busy"] ? true : false
		Ports := Map("busy", () => Busy,
			"delete_models", Answer.Bind("models"), "stop", Answer.Bind("stop"), "remove_files", RemoveFiles)
		LLM_OllamaUninstallRun(Vector["remove_models"] ? true : false, Ports, (Result) => Results.Push(Result))
		AssertEqual(1, Results.Length, "one terminal result: " . Vector["id"])
		AssertEqual(_OllamaUninstallJoin(Vector["steps"]), _OllamaUninstallJoin(Calls), "steps run: " . Vector["id"])
		AssertEqual(_OllamaUninstallJoin(Vector["steps"]), _OllamaUninstallJoin(Results[1]["steps"]))
		AssertEqual(Vector["ok"] ? true : false, Results[1]["ok"] ? true : false, "outcome: " . Vector["id"])
		AssertEqual(Vector["message"], Results[1]["message"], "message: " . Vector["id"])
		if FilesFlag != ""
			AssertEqual(Vector["remove_models"] ? true : false, FilesFlag ? true : false)
	}

	Answer(Step, Done) {
		Calls.Push(Step)
		return Done.Call(Step != Refused)
	}

	RemoveFiles(RemoveModels, Done) {
		FilesFlag := RemoveModels
		return Answer("files", Done)
	}
}
Test("managed Ollama uninstall: replays the shared vectors (oll-11)", _OllamaUninstallVectors)

_OllamaUninstallJoin(Items) {
	Text := ""
	for Item in Items
		Text .= (Text == "" ? "" : ",") . Item
	return Text
}

_OllamaUninstallIncompletePorts() {
	Refused := false
	try LLM_OllamaUninstallRun(false, Map("busy", () => false), (*) => 0)
	catch TypeError
		Refused := true
	AssertTrue(Refused, "an incomplete port set is refused before anything runs")
}
Test("managed Ollama uninstall: refuses an incomplete port set (oll-11)", _OllamaUninstallIncompletePorts)

/** Builds a scratch managed root with a version, a receipt and a model blob. */
_OllamaUninstallScratchRoot() {
	Root := A_Temp . "\ergopti_oll11_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Root . "\versions\0.40.6\lib")
	FileAppend("exe", Root . "\versions\0.40.6\ollama.exe")
	FileAppend("{}", Root . "\receipt.json")
	DirCreate(Root . "\models\blobs")
	FileAppend("blob", Root . "\models\blobs\sha256-ab")
	return Root
}

_OllamaUninstallRemoveFiles(RemoveModels) {
	Root := _OllamaUninstallScratchRoot()
	Answers := []
	try {
		_LLM_OllamaUninstallRemoveFiles(RemoveModels, (Ok) => Answers.Push(Ok), Root)
		AssertEqual(1, Answers.Length)
		AssertTrue(Answers[1], "the managed files are removed")
		AssertFalse(DirExist(Root . "\versions"), "the runtime goes")
		AssertFalse(FileExist(Root . "\receipt.json"), "its receipt goes")
		if RemoveModels {
			AssertFalse(DirExist(Root), "the whole managed root goes with its models")
		} else {
			AssertTrue(FileExist(Root . "\models\blobs\sha256-ab") != "", "the kept models stay where they were")
		}
	} finally {
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("managed Ollama uninstall: keeps the models folder when asked (oll-11)", _OllamaUninstallRemoveFiles.Bind(false))
Test("managed Ollama uninstall: removes the models folder when asked (oll-11)", _OllamaUninstallRemoveFiles.Bind(true))

_OllamaUninstallRefusesLink() {
	Root := _OllamaUninstallScratchRoot()
	Outside := Root . "_outside"
	Answers := []
	try {
		DirCreate(Outside)
		FileAppend("keep", Outside . "\precious.txt")
		RunWait(A_ComSpec . ' /c mklink /J "' . Root . '\versions\link" "' . Outside . '"', , "Hide")
		AssertTrue(InStr(FileGetAttrib(Root . "\versions\link"), "L") > 0, "the fixture junction exists")
		_LLM_OllamaUninstallRemoveFiles(true, (Ok) => Answers.Push(Ok), Root)
		AssertEqual(1, Answers.Length)
		AssertFalse(Answers[1], "a link below the managed root refuses the removal")
		AssertTrue(FileExist(Root . "\versions\0.40.6\ollama.exe") != "", "nothing was removed")
		AssertTrue(FileExist(Outside . "\precious.txt") != "", "the link target is untouched")
	} finally {
		if DirExist(Root . "\versions\link")
			DirDelete(Root . "\versions\link")
		if DirExist(Root)
			DirDelete(Root, true)
		if DirExist(Outside)
			DirDelete(Outside, true)
	}
}
Test("managed Ollama uninstall: refuses a link below the managed root (oll-11)", _OllamaUninstallRefusesLink)

/**
 * Drives the menu action's two questions over scripted ports.
 * @param {String} Mode "cancel", "keep", "remove" or "busy".
 */
_OllamaUninstallMenu(Mode) {
	Questions := [], Calls := [], Notices := []
	Answers := Mode == "cancel" ? ["Cancel"] : ["OK", Mode == "keep" ? "No" : "Yes"]
	Confirm(Body, Title, Options) {
		Questions.Push(Title)
		return Answers[Questions.Length]
	}
	Step(Name, Done) {
		Calls.Push(Name)
		return Done.Call(true)
	}
	RemoveFiles(RemoveModels, Done) {
		Calls.Push(RemoveModels ? "files+models" : "files")
		return Done.Call(true)
	}
	Notify(Body, Title, Level) {
		Notices.Push(Level)
		return true
	}
	Ports := Map("busy", () => Mode == "busy", "delete_models", Step.Bind("models"), "stop", Step.Bind("stop"),
		"remove_files", RemoveFiles)
	Ran := LLM_Menu_OllamaUninstall(Confirm, Ports, Notify)
	if Mode == "cancel" {
		AssertFalse(Ran)
		AssertEqual(1, Questions.Length, "a refused first question asks nothing more")
		AssertEqual(0, Calls.Length, "a cancelled uninstall touches nothing")
		return
	}
	AssertTrue(Ran)
	AssertEqual(2, Questions.Length, "the models are asked about after the uninstall itself")
	Expected := Mode == "keep" ? "stop,files" : Mode == "remove" ? "models,stop,files+models" : ""
	AssertEqual(Expected, _OllamaUninstallJoin(Calls))
	AssertEqual(1, Notices.Length, "the outcome is told once")
	AssertEqual(Mode == "busy" ? "error" : "success", Notices[1])
}
for _OllamaUninstallMode in ["cancel", "keep", "remove", "busy"]
	Test("managed Ollama uninstall: menu action " . _OllamaUninstallMode . " (oll-11)",
		_OllamaUninstallMenu.Bind(_OllamaUninstallMode))
