; modules/shortcuts/workflows/editor_host.ahk

; ==============================================================================
; MODULE: User Workflows Editor Host (Windows)
; DESCRIPTION:
; The Windows answer to the « Workflows personnalisés… » window
; (_shared/ui/user_workflows, bridge hsWorkflows), the port of
; _shared/shortcuts/engine/workflows/editor_host.lua: its first data, a save
; checked by the model, a test run whose steps are pushed back for the
; highlight, Escape and Stop, the approval of an imported shell step, and the
; export and import of a workflow file. WorkflowsEditorOpen shows the page in
; a WebView2 window (WebViewHost), as the macOS and Linux hosts do.
;
; FEATURES & RATIONALE:
; 1. Every write is checked again here: the page's own check is a courtesy,
;    the store refuses what the model refuses. Messages are decoded lossless,
;    so a boolean the page sent is never read as the integer 1.
; 2. An imported workflow is stamped origin = "import" here, whatever its
;    file says, so a file can never claim to be local.
; 3. An approval is the shell digest of the workflow the user is looking at,
;    stored apart from workflows.json; an edit of a command asks again.
; 4. The page's strings are every "workflows." key of the locale, read from
;    the catalogue en.json declares, so a new key needs no second list here.
; 5. The window, its dialogs and the file I/O are ports, so the suite drives
;    the host with recorders.
; ==============================================================================

#Requires AutoHotkey v2.0

; The PNG file signature a picked image must start with.
global WORKFLOW_PNG_SIGNATURE := [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/**
 * One window's host.
 */
class WorkflowEditorHost {
	/**
	 * @param {Map} Ports "owner" (WorkflowOwner), "push" (FunctionName, Json)
	 *   calling window[FunctionName] in the page, "strings" () -> Map,
	 *   "actions" () -> Array of Map("id", "label"), "catalogue_json" () and
	 *   "vocabulary_json" () -> the shared files' text, "pick_save_file"
	 *   (DefaultName) and "pick_open_file" (Kind "workflows" or "png") -> a path the
	 *   user picked or "", "read_text" (Path) -> String or 0, "read_bytes"
	 *   (Path) -> Buffer or 0, "write_text" (Path, Text) -> Boolean, "close" ().
	 */
	__New(Ports) {
		_WorkflowRequirePorts(Ports, ["push", "strings", "actions", "catalogue_json", "vocabulary_json", "pick_save_file",
			"pick_open_file", "read_text", "read_bytes", "write_text", "close"], "A workflow editor host")
		if !(Ports.Get("owner", 0) is WorkflowOwner)
			throw TypeError("A workflow editor host needs the workflow owner.", -1)
		this.Ports := Ports
		this.Owner := Ports["owner"]
		this.Store := this.Owner.Store
	}

	Push(Name, Payload) {
		this.Ports["push"].Call(Name, (Payload is String) ? Payload : WorkflowJsonEncode(Payload))
	}

	; The approval state the page shows: id -> whether its shell commands are approved.
	ApprovedMap(Doc) {
		global JSON_TRUE, JSON_FALSE
		Approved := Map()
		for Workflow in Doc["workflows"] {
			Digest := WorkflowShellDigest(Workflow)
			Approved[Workflow["id"]] := Digest != "" && this.Store.Approval(Workflow["id"]) == Digest
				? JSON_TRUE : JSON_FALSE
		}
		return Approved
	}

	; A workflow of a page document by id, checked by the model, or 0.
	Find(Doc, Id) {
		if !(Doc is Map) || !(Doc.Get("workflows", 0) is Array)
			return 0
		for Workflow in Doc["workflows"]
			if (Workflow is Map) && Workflow.Get("id", "") == Id
				return Workflow
		return 0
	}

	Refused(Name, Refusal) {
		global JSON_FALSE
		this.Push(Name, Map("ok", JSON_FALSE, "reason", Refusal["reason"], "path", Refusal["path"]))
	}

	Ready() {
		global WORKFLOW_LOG
		Doc := this.Store.Load(&Refusal)
		if !IsObject(Doc) {
			LoggerError(WORKFLOW_LOG, "workflows.json is invalid ({1} at {2}): the editor opens empty.",
				Refusal["reason"], Refusal["path"])
			Doc := this.Store.Empty()
			Approved := Map()
		} else
			Approved := this.ApprovedMap(Doc)
		this.Push("initData", "{" . JsonStringLiteral("actions") . ":" . WorkflowJsonEncode(this.Ports["actions"].Call())
			. "," . JsonStringLiteral("approved") . ":" . WorkflowJsonEncode(Approved)
			. "," . JsonStringLiteral("catalogue") . ":" . this.Ports["catalogue_json"].Call()
			. "," . JsonStringLiteral("doc") . ":" . WorkflowJsonEncode(Doc)
			. "," . JsonStringLiteral("strings") . ":" . WorkflowJsonEncode(this.Ports["strings"].Call())
			. "," . JsonStringLiteral("timings") . ":" . WorkflowJsonEncode(Map("wait_max_ms", this.Store.Timings["wait_max_ms"]))
			. "," . JsonStringLiteral("vocabulary") . ":" . this.Ports["vocabulary_json"].Call() . "}")
		if IsObject(Refusal)
			this.Refused("onSaved", Refusal)
	}

	Save(Doc) {
		global WORKFLOW_LOG, JSON_TRUE
		if !this.Store.Save(Doc, &Refusal) {
			LoggerWarn(WORKFLOW_LOG, "The editor's workflows were refused ({1} at {2}).", Refusal["reason"], Refusal["path"])
			return this.Refused("onSaved", Refusal)
		}
		LoggerInfo(WORKFLOW_LOG, "Saved {1} workflow(s) from the editor.", Doc["workflows"].Length)
		this.Push("onSaved", Map("ok", JSON_TRUE, "approved", this.ApprovedMap(Doc)))
	}

	TestRun(Doc, Id) {
		Workflow := this.Find(Doc, Id)
		if !IsObject(Workflow)
			return this.Push("onRunEnd", Map("op", "failed", "reason", "step_failed"))
		Listener := Map("on_step", (Effect) => this.Push("onRunStep", Map("path", Effect["path"])),
			"on_end", (Outcome) => this.Push("onRunEnd", Outcome))
		Started := this.Owner.TestRun(Workflow, Listener, &Refusal)
		if IsObject(Refusal) {
			this.Refused("onSaved", Refusal)
			this.Push("onRunEnd", Map("op", "failed", "reason", "step_failed"))
		} else if !Started
			this.Push("onRunEnd", Map("op", "failed", "reason", "already_running"))
	}

	Approve(Doc, Id) {
		global WORKFLOW_LOG, JSON_TRUE
		Workflow := this.Find(Doc, Id)
		if !IsObject(Workflow) || !WorkflowValidate(Workflow, this.Store.Catalogue, this.Store.Timings)["ok"]
			return
		Digest := WorkflowShellDigest(Workflow)
		if Digest == ""
			return
		this.Store.Approve(Id, Digest)
		LoggerInfo(WORKFLOW_LOG, "The user approved the shell commands of workflow {1}.", Id)
		this.Push("onSaved", Map("ok", JSON_TRUE, "approved", this.ApprovedMap(Doc)))
	}

	Export(Doc) {
		global WORKFLOW_LOG
		Result := WorkflowValidateFile(Doc, this.Store.Catalogue, this.Store.Timings)
		if !Result["ok"]
			return this.Refused("onSaved", Result)
		Path := this.Ports["pick_save_file"].Call("workflows.json")
		if Path == ""
			return
		if !this.Ports["write_text"].Call(Path, WorkflowJsonEncode(Doc)) {
			LoggerError(WORKFLOW_LOG, "The workflow export could not be written.")
			return this.Refused("onSaved", Map("reason", "bad_type", "path", "/"))
		}
		LoggerInfo(WORKFLOW_LOG, "Exported {1} workflow(s).", Doc["workflows"].Length)
	}

	Import() {
		global WORKFLOW_LOG, JSON_TRUE
		Path := this.Ports["pick_open_file"].Call("workflows")
		if Path == ""
			return
		Text := this.Ports["read_text"].Call(Path)
		try Doc := JsonParseLossless((Text is String) ? Text : "")
		catch
			return this.Refused("onImported", Map("reason", "not_object", "path", "/"))
		Result := WorkflowValidateFile(Doc, this.Store.Catalogue, this.Store.Timings)
		if !Result["ok"]
			return this.Refused("onImported", Result)
		for Workflow in Doc["workflows"]
			Workflow["origin"] := "import"
		LoggerInfo(WORKFLOW_LOG, "Imported {1} workflow(s); their shell steps wait for an approval.", Doc["workflows"].Length)
		this.Push("onImported", Map("ok", JSON_TRUE, "workflows", Doc["workflows"]))
	}

	; A PNG for a screen step, read by the host as on macOS and Linux.
	PickImage() {
		global WORKFLOW_LOG, WORKFLOW_PNG_SIGNATURE, JSON_TRUE, JSON_FALSE
		Path := this.Ports["pick_open_file"].Call("png")
		if Path == ""
			return
		Bytes := this.Ports["read_bytes"].Call(Path)
		IsPng := (Bytes is Buffer) && Bytes.Size >= WORKFLOW_PNG_SIGNATURE.Length
		if IsPng
			for Index, Byte in WORKFLOW_PNG_SIGNATURE
				IsPng := IsPng && NumGet(Bytes, Index - 1, "UChar") == Byte
		if !IsPng {
			LoggerWarn(WORKFLOW_LOG, "The picked image is not a PNG file.")
			return this.Push("onImagePicked", Map("ok", JSON_FALSE, "reason", "bad_image"))
		}
		Encoded := CryptoBase64Encode(Bytes)
		if StrLen(Encoded) > this.Store.Catalogue["limits"]["image_base64_bytes"]
			return this.Push("onImagePicked", Map("ok", JSON_FALSE, "reason", "too_long"))
		SplitPath(Path, , , , &Stem)
		this.Push("onImagePicked", Map("ok", JSON_TRUE, "name", Stem, "data", Encoded))
	}

	/**
	 * Handles one page message.
	 * @param {Map} Message Decoded with JsonParseLossless.
	 */
	OnMessage(Message) {
		global WORKFLOW_LOG
		if !(Message is Map) || !(Message.Get("action", 0) is String) {
			LoggerWarn(WORKFLOW_LOG, "The workflow editor sent a message without an action.")
			return
		}
		Doc := Message.Get("doc", 0)
		Id := Message.Get("id", "")
		switch Message["action"], true {
			case "ready":
				return this.Ready()
			case "save":
				return this.Save(Doc)
			case "test_run":
				return this.TestRun(Doc, Id)
			case "stop":
				return this.Owner.AbortAll()
			case "approve_shell":
				return this.Approve(Doc, Id)
			case "export":
				return this.Export(Doc)
			case "import":
				return this.Import()
			case "pick_image":
				return this.PickImage()
			case "close":
				this.Owner.AbortAll()
				return this.Ports["close"].Call()
		}
		LoggerWarn(WORKFLOW_LOG, "The workflow editor sent an unknown action '{1}'.", Message["action"])
	}
}




; ===================================
; ===================================
; ======= 2/ Window =================
; ===================================
; ===================================

; Every "workflows." string of the active locale, keyed as en.json declares them.
_WorkflowEditorStrings() {
	global _SharedDir
	Path := _SharedDir . "\core\i18n\data\locales\en.json"
	Strings := Map()
	for Key in JsonParseShared(Path, FSReadStrict(Path))
		if SubStr(Key, 1, 10) == "workflows."
			Strings[Key] := t(Key)
	return Strings
}

; The parameterless actions this driver runs, for the « Ergopti action » step.
_WorkflowEditorActions() {
	global GESTURE_ACTION_CATALOGUE, GESTURE_ACTIONS
	Choices := []
	for Id, Entry in GESTURE_ACTION_CATALOGUE.Actions
		if Entry.Parameter == "" && GESTURE_ACTIONS.Has(Id) && Id != "none"
			Choices.Push(Map("id", Id, "label", t(Entry.LabelKey)))
	return Choices
}

_WorkflowEditorPickPath(Save, Kind) {
	Filter := Kind == "png" ? "PNG (*.png)" : "JSON (*.json)"
	Title := t(Save ? "workflows.editor.export" : Kind == "png" ? "workflows.editor.add_image" : "workflows.editor.import")
	; S16 asks before overwriting; 3 requires an existing file and path.
	return Ui_FileSelect(Save ? "S16" : 3, Save ? A_MyDocuments . "\" . Kind : A_MyDocuments, Title, Filter)
}

_WorkflowEditorReadText(Path) {
	global WORKFLOW_LOG
	try return FSReadStrict(Path)
	catch as Err {
		LoggerWarn(WORKFLOW_LOG, "A workflow file could not be read ({1}).", Type(Err))
		return 0
	}
}

_WorkflowEditorReadBytes(Path) {
	global WORKFLOW_LOG
	try return FSReadBytesStrict(Path)
	catch as Err {
		LoggerWarn(WORKFLOW_LOG, "A picked image could not be read ({1}).", Type(Err))
		return 0
	}
}

; The host's ports for one window: Window() is its WebViewHost.
_WorkflowEditorPorts(Window) {
	global _SharedDir
	return Map("owner", WorkflowsInit(),
		"push", (Name, Json) => Window.Call().Eval("if(window." . Name . ") window." . Name . "(" . Json . ")"),
		"strings", _WorkflowEditorStrings, "actions", _WorkflowEditorActions,
		"catalogue_json", () => FSReadStrict(_SharedDir . "\" . WorkflowCataloguePath()),
		"vocabulary_json", SendKeysVocabularyJson,
		"pick_save_file", (Name) => _WorkflowEditorPickPath(true, Name),
		"pick_open_file", (Kind) => _WorkflowEditorPickPath(false, Kind),
		"read_text", _WorkflowEditorReadText, "read_bytes", _WorkflowEditorReadBytes,
		"write_text", FSWrite, "close", () => Window.Call().Close())
}

/**
 * Opens « Workflows personnalisés… », or brings the open window forward. It is
 * configuration, so it works while paused, as from the menu.
 * @returns {Boolean} Whether a window is open.
 */
WorkflowsEditorOpen(*) {
	global WORKFLOW_LOG
	Window := { Host: 0 }
	Editor := WorkflowEditorHost(_WorkflowEditorPorts(() => Window.Host))
	LoggerInfo(WORKFLOW_LOG, "Opening the workflow editor.")
	Host := WebViewHost.TryOpen("user_workflows", Map("RunsWhilePaused", true, "LosslessJson", true,
		"OnMessage", (MessageHost, Message) => (Window.Host := MessageHost, Editor.OnMessage(Message))))
	return IsObject(Host)
}
