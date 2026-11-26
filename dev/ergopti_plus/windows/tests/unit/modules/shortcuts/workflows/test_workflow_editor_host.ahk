; tests/unit/modules/shortcuts/workflows/test_workflow_editor_host.ahk

; ==============================================================================
; MODULE: User Workflows Editor Host (Windows)
; DESCRIPTION:
; Drives modules/shortcuts/workflows/editor_host.ahk over recording ports, as
; _shared/tests/lua/workflows/workflow_editor_host_contract.lua drives the
; shared host on macOS and Linux: the first data the page gets, a save
; checked by the model, an import stamped « import » whatever its file says,
; an approval bound to the shell digest, a PNG picked by the host, and a test
; run whose steps are pushed back.
;
; ROOT CAUSE ENCODED:
; « Workflows personnalisés… » had no Windows host: the shared page could not
; open, save or test a workflow there.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Harness =========================
; ============================================
; ============================================

; A host over the runner harness's owner and recording window ports.
_TWFE_Host(Files, Picks := 0, Reads := 0) {
	H := _TWFR_Harness(Files)
	World := H.World
	World.Pushed := []
	World.Written := Map()
	World.Closed := 0
	Host := WorkflowEditorHost(Map("owner", H.Owner,
		"push", (Name, Json) => World.Pushed.Push(Map("name", Name, "json", Json)),
		"strings", () => Map("workflows.editor.save", "Save"),
		"actions", () => [Map("id", "select_all", "label", "Select all")],
		"catalogue_json", () => '{"schema_version":1}', "vocabulary_json", () => '{"keys":[]}',
		"pick_save_file", (Name) => (Picks is Map) ? Picks.Get("save", "") : "",
		"pick_open_file", (Kind) => (Picks is Map) ? Picks.Get(Kind, "") : "",
		"read_text", (Path) => (Reads is Map) ? Reads.Get(Path, 0) : 0,
		"read_bytes", (Path) => (Reads is Map) ? Reads.Get(Path, 0) : 0,
		"write_text", (Path, Text) => (World.Written[Path] := Text, true),
		"close", () => World.Closed += 1))
	return { Host: Host, World: World, Owner: H.Owner }
}

; The JSON of the last push of a page function, decoded lossless.
_TWFE_Last(World, Name) {
	Found := 0
	for Push in World.Pushed
		if Push["name"] == Name
			Found := Push
	AssertTrue(IsObject(Found), "the host pushed " . Name)
	return JsonParseLossless(Found["json"])
}

_TWFE_Message(Json) {
	return JsonParseLossless(Json)
}




; ============================================
; ============================================
; ======= 2/ Messages ========================
; ============================================
; ============================================

_TWFE_ReadySendsTheFirstData() {
	global JSON_FALSE
	T := _TWFE_Host(_TWFR_File('[{"kind":"shell","command":"ver"}]', "import"))
	T.Host.OnMessage(_TWFE_Message('{"action":"ready"}'))
	Data := _TWFE_Last(T.World, "initData")
	AssertEqual("wf_1", Data["doc"]["workflows"][1]["id"], "the page gets the saved workflows")
	AssertTrue(Data["approved"]["wf_1"] == JSON_FALSE, "an unapproved import shows as such, as a JSON boolean")
	AssertEqual("Save", Data["strings"]["workflows.editor.save"], "the page gets its strings")
	AssertEqual("select_all", Data["actions"][1]["id"], "the page gets the actions a step can run")
	AssertEqual(600000, Data["timings"]["wait_max_ms"], "the page gets the wait bound of the registry")
	AssertEqual(1, Data["catalogue"]["schema_version"], "the catalogue is the shared file, verbatim")
}
Test("workflows editor: ready sends the saved workflows and the page data (workflow-editor-host)",
	_TWFE_ReadySendsTheFirstData)

_TWFE_SaveIsCheckedAgain() {
	global JSON_TRUE, JSON_FALSE
	T := _TWFE_Host(Map())
	T.Host.OnMessage(_TWFE_Message('{"action":"save","doc":{"schema_version":1,"workflows":[{"id":"a",'
		. '"name":"A","origin":"local","steps":[{"kind":"wait","duration_ms":true}]}]}}'))
	Saved := _TWFE_Last(T.World, "onSaved")
	AssertTrue(Saved["ok"] == JSON_FALSE, "a boolean duration is refused, never read as 1")
	AssertEqual("bad_type", Saved["reason"], "the refusal is the model's")
	AssertEqual("/workflows/0/steps/0/duration_ms", Saved["path"], "at the model's pointer")
	AssertFalse(T.World.Files.Has("C:\cfg\workflows.json"), "a refused document never reaches the disk")
	T.Host.OnMessage(_TWFE_Message('{"action":"save","doc":' . SubStr(_TWFR_File("[]")["C:\cfg\workflows.json"], 1) . '}'))
	AssertTrue(_TWFE_Last(T.World, "onSaved")["ok"] == JSON_TRUE, "a valid document is saved")
	AssertTrue(T.World.Files.Has("C:\cfg\workflows.json"), "and written")
}
Test("workflows editor: a save is checked again by the model (workflow-editor-host)", _TWFE_SaveIsCheckedAgain)

_TWFE_ImportIsStamped() {
	global JSON_TRUE
	File := _TWFR_File('[{"kind":"shell","command":"ver"}]')["C:\cfg\workflows.json"]
	T := _TWFE_Host(Map(), Map("workflows", "C:\in\shared.json"), Map("C:\in\shared.json", File))
	T.Host.OnMessage(_TWFE_Message('{"action":"import"}'))
	Imported := _TWFE_Last(T.World, "onImported")
	AssertTrue(Imported["ok"] == JSON_TRUE, "a valid file is imported")
	AssertEqual("import", Imported["workflows"][1]["origin"], "an import is stamped « import » whatever its file says")
	T.World.Written := Map()
	T.Host.OnMessage(_TWFE_Message('{"action":"export","doc":' . File . '}'))
	AssertTrue(T.World.Written.Count == 0, "an export the user cancelled writes nothing")
}
Test("workflows editor: an import is stamped import (workflow-editor-host)", _TWFE_ImportIsStamped)

_TWFE_ApprovalIsTheDigest() {
	global JSON_TRUE
	File := _TWFR_File('[{"kind":"shell","command":"ver"}]', "import")
	T := _TWFE_Host(File)
	T.Host.OnMessage(_TWFE_Message('{"action":"approve_shell","id":"wf_1","doc":' . File["C:\cfg\workflows.json"] . '}'))
	Saved := _TWFE_Last(T.World, "onSaved")
	AssertTrue(Saved["approved"]["wf_1"] == JSON_TRUE, "the approved workflow shows as approved")
	Workflow := T.Owner.Store.Find("wf_1")
	AssertEqual(WorkflowShellDigest(Workflow), T.Owner.Store.Approval("wf_1"), "the approval is the shell digest")
	AssertFalse(InStr(T.World.Files["C:\cfg\workflows.json"], "approv"), "workflows.json carries no approval")
}
Test("workflows editor: an approval is the shell digest, kept apart (workflow-editor-host)", _TWFE_ApprovalIsTheDigest)

_TWFE_PickImageNeedsAPng() {
	global JSON_TRUE, JSON_FALSE
	Png := Buffer(9, 0)
	for Index, Byte in WORKFLOW_PNG_SIGNATURE
		NumPut("UChar", Byte, Png, Index - 1)
	NotPng := Buffer(9, 0x41)
	T := _TWFE_Host(Map(), Map("png", "C:\img\send button.png"), Map("C:\img\send button.png", Png))
	T.Host.OnMessage(_TWFE_Message('{"action":"pick_image"}'))
	Picked := _TWFE_Last(T.World, "onImagePicked")
	AssertTrue(Picked["ok"] == JSON_TRUE, "a PNG is accepted")
	AssertEqual("send button", Picked["name"], "its name is the file's stem")
	AssertEqual(CryptoBase64Encode(Png), Picked["data"], "its data is the base64 of its bytes")
	T := _TWFE_Host(Map(), Map("png", "C:\img\x.png"), Map("C:\img\x.png", NotPng))
	T.Host.OnMessage(_TWFE_Message('{"action":"pick_image"}'))
	Refused := _TWFE_Last(T.World, "onImagePicked")
	AssertTrue(Refused["ok"] == JSON_FALSE && Refused["reason"] == "bad_image", "a file without the PNG signature is refused")
}
Test("workflows editor: a picked image must be a PNG (workflow-editor-host)", _TWFE_PickImageNeedsAPng)

_TWFE_TestRunPushesItsSteps() {
	T := _TWFE_Host(Map())
	Doc := _TWFR_File('[{"kind":"notify","text":"a"},{"kind":"wait","duration_ms":5}]')["C:\cfg\workflows.json"]
	T.Host.OnMessage(_TWFE_Message('{"action":"test_run","id":"wf_1","doc":' . Doc . '}'))
	Paths := ""
	for Push in T.World.Pushed
		if Push["name"] == "onRunStep"
			Paths .= JsonParseLossless(Push["json"])["path"] . ","
	AssertEqual("1,2,", Paths, "each running step is pushed for the highlight")
	T.Host.OnMessage(_TWFE_Message('{"action":"stop"}'))
	AssertEqual("aborted", _TWFE_Last(T.World, "onRunEnd")["op"], "Stop ends the test run")
	T.Host.OnMessage(_TWFE_Message('{"action":"close"}'))
	AssertEqual(1, T.World.Closed, "Close closes the window")
}
Test("workflows editor: a test run pushes its steps and stops (workflow-editor-host)", _TWFE_TestRunPushesItsSteps)
