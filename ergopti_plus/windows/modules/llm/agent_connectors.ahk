; modules/llm/agent_connectors.ahk

; ==============================================================================
; MODULE: AI Agent Connectors (AHK)
; DESCRIPTION:
; Carries out the action the user accepted among the AI agent's candidates
; (modules/llm/agent_action.ahk), one function per action type, and lists the
; user's own tools, which the "shortcut" actions run.
;
; FEATURES & RATIONALE:
; 1. Calendar events and tasks go to Outlook through COM when it answers
;    (saved, like an entry the user typed), otherwise to an iCalendar file
;    (_shared/lua/llm/agent.lua's bytes) opened with the default handler, which
;    imports it into the calendar the user uses. The path taken is logged.
; 2. A mail is only ever a draft: an Outlook message displayed for review, or
;    a mailto: link opened with the default mail client. Nothing is sent.
; 3. The tools are the .ps1, .cmd and .ahk files of <config dir>/agent_tools/
;    (created when missing). One runs with the action's input as its only
;    argument, quoted for the Windows command line, never through a shell
;    string built from the input.
; 4. Every COM, file and process call goes through windows/adapters, behind a
;    seam the test suite replaces. A temporary file is deleted at the next
;    connector run, once the application that opened it has read it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Module State =======
; ===============================
; ===============================

; Outlook item kinds (OlItemType)
global LLM_AGENT_OUTLOOK_MAIL := 0
global LLM_AGENT_OUTLOOK_APPOINTMENT := 1
global LLM_AGENT_OUTLOOK_TASK := 3

; OlMeetingStatus olMeeting: an appointment with attendees
global LLM_AGENT_OUTLOOK_MEETING := 1

; The tool file kinds, by extension
global LLM_AGENT_TOOL_EXTENSIONS := Map("ps1", true, "cmd", true, "ahk", true)

; How long the tools list is reused before the folder is read again
global LLM_AGENT_TOOLS_TTL_MS := 600000

; Characters a .cmd tool cannot receive safely: cmd.exe expands % inside quotes
; and a quote or a line break ends the argument
global LLM_AGENT_CMD_UNSAFE := '["%\r\n]'

; The tools list: Map("names", Array, "paths", Map(Name -> Path), "tick", Integer)
global _LLM_AgentConnector_Tools := ""

; Temporary files written by earlier runs, deleted at the next one
global _LLM_AgentConnector_TempFiles := []

; Test seams, 0 in production. Com: (ProgId) => object or "". Open: (Target)
; opens a file or URI, throws on failure. Launch: (Argv) starts a program,
; throws on failure. Write: (Path, Text) => Boolean. Delete: (Path) => Boolean.
; List: (Dir) => Array of file paths. EnsureDir: (Dir). Id: () => Map("uid",
; "stamp").
global _LLM_AgentConnector_ComFn := 0
global _LLM_AgentConnector_OpenFn := 0
global _LLM_AgentConnector_LaunchFn := 0
global _LLM_AgentConnector_WriteFn := 0
global _LLM_AgentConnector_DeleteFn := 0
global _LLM_AgentConnector_ListFn := 0
global _LLM_AgentConnector_EnsureDirFn := 0
global _LLM_AgentConnector_IdFn := 0





; ============================
; ============================
; ======= 2/ Execution =======
; ============================
; ============================

/**
 * Carries out one validated action.
 * @param {Map} Action The accepted action.
 * @param {Map} Config The decoded agent.json.
 * @returns {Map} Map("ok", true, "path", How) or Map("ok", false, "reason", Why).
 */
LLM_AgentConnector_Execute(Action, Config) {
	_LLM_AgentConnector_DeleteEarlierFiles()
	try {
		switch Action["type"] {
			case "calendar", "reminder":
				How := _LLM_AgentConnector_Schedule(Action, Config)
			case "mail":
				How := _LLM_AgentConnector_Mail(Action)
			case "shortcut":
				How := _LLM_AgentConnector_Shortcut(Action, Config)
			default:
				throw ValueError("unknown action type " . String(Action["type"]))
		}
	} catch as Err {
		return Map("ok", false, "reason", Err.Message)
	}
	LoggerInfo("LLM", "AI agent connector: {1} carried out through {2}.", Action["type"], How)
	return Map("ok", true, "path", How)
}

; A calendar event or a task: Outlook when it answers, else an iCalendar file.
; @returns {String} "outlook" or "ics".
_LLM_AgentConnector_Schedule(Action, Config) {
	global LLM_AGENT_OUTLOOK_APPOINTMENT, LLM_AGENT_OUTLOOK_TASK, LLM_AGENT_OUTLOOK_MEETING
	Outlook := _LLM_AgentConnector_Outlook()
	if !IsObject(Outlook) {
		_LLM_AgentConnector_OpenIcs(Action, Config)
		return "ics"
	}
	if (Action["type"] == "calendar") {
		Item := Outlook.CreateItem(LLM_AGENT_OUTLOOK_APPOINTMENT)
		Item.Subject := Action["title"]
		; OLE automation dates built from the components, never a localized string
		Item.Start := LLM_Agent_OleDate(Action["start"])
		Item.End := LLM_Agent_OleDate(Action["end"])
		if Action.Has("location")
			Item.Location := Action["location"]
		if Action.Has("notes")
			Item.Body := Action["notes"]
		if Action.Has("attendees") && Action["attendees"].Length > 0 {
			; A meeting request is saved with its attendees, never sent
			Item.MeetingStatus := LLM_AGENT_OUTLOOK_MEETING
			for Address in Action["attendees"]
				Item.Recipients.Add(Address)
		}
	} else {
		Item := Outlook.CreateItem(LLM_AGENT_OUTLOOK_TASK)
		Item.Subject := Action["title"]
		if Action.Has("notes")
			Item.Body := Action["notes"]
		if Action.Has("due") {
			Due := LLM_Agent_OleDate(Action["due"])
			Item.DueDate := Due
			Item.ReminderSet := true
			Item.ReminderTime := Due
		}
	}
	Item.Save()
	return "outlook"
}

; A mail draft: an Outlook message shown for review, else a mailto: link.
; @returns {String} "outlook" or "mailto".
_LLM_AgentConnector_Mail(Action) {
	global LLM_AGENT_OUTLOOK_MAIL
	Outlook := _LLM_AgentConnector_Outlook()
	if !IsObject(Outlook) {
		_LLM_AgentConnector_Open(LLM_Agent_Mailto(Action))
		return "mailto"
	}
	Item := Outlook.CreateItem(LLM_AGENT_OUTLOOK_MAIL)
	if Action.Has("subject")
		Item.Subject := Action["subject"]
	Item.Body := Action["body"]
	if Action.Has("to") && Action["to"].Length > 0
		Item.To := _LLM_Agent_Join(Action["to"], "; ")
	; Displayed for the user to review and send: the agent never sends
	Item.Display()
	return "outlook"
}

; One of the user's tools, with the action's input as its only argument.
; @returns {String} "tool".
_LLM_AgentConnector_Shortcut(Action, Config) {
	global LLM_AGENT_CMD_UNSAFE
	Tools := LLM_AgentConnector_Tools(Config)
	if !Tools["paths"].Has(Action["name"])
		throw ValueError("the tool is no longer in the tools folder")
	Path := Tools["paths"][Action["name"]]
	SplitPath(Path, , , &Extension)
	Extension := StrLower(Extension)
	switch Extension {
		case "ps1":
			Argv := ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Path]
		case "ahk":
			Argv := [A_AhkPath, Path]
		default:
			Argv := [Path]
	}
	if Action.Has("input") {
		if (Extension == "cmd" && RegExMatch(Action["input"], LLM_AGENT_CMD_UNSAFE))
			throw ValueError("a .cmd tool cannot receive a quote, a percent sign or a line break")
		Argv.Push(Action["input"])
	}
	Launch := HasMethod(_LLM_AgentConnector_LaunchFn, "Call") ? _LLM_AgentConnector_LaunchFn : AL_LaunchArgvStrict
	Launch.Call(Argv)
	return "tool"
}

; Writes the action's iCalendar file to a private temp file and opens it.
_LLM_AgentConnector_OpenIcs(Action, Config) {
	global _LLM_AgentConnector_WriteFn, _LLM_AgentConnector_IdFn, _LLM_AgentConnector_TempFiles
	Id := HasMethod(_LLM_AgentConnector_IdFn, "Call") ? _LLM_AgentConnector_IdFn.Call() : _LLM_AgentConnector_NewId()
	Path := _LLM_Ollama_TempDir() . "\ergopti_agent_" . StrReplace(Id["uid"], "@", "_") . ".ics"
	Write := HasMethod(_LLM_AgentConnector_WriteFn, "Call") ? _LLM_AgentConnector_WriteFn : FSWrite
	if !Write.Call(Path, LLM_Agent_Ics(Config, Action, Id["uid"], Id["stamp"]))
		throw Error("the calendar file could not be written")
	; Deleted at the next run: the calendar application reads it after this returns
	_LLM_AgentConnector_TempFiles.Push(Path)
	_LLM_AgentConnector_Open(Path)
}

; Opens a file or a URI with its default handler.
_LLM_AgentConnector_Open(Target) {
	global _LLM_AgentConnector_OpenFn
	Open := HasMethod(_LLM_AgentConnector_OpenFn, "Call") ? _LLM_AgentConnector_OpenFn : AL_OpenStrict
	Open.Call(Target)
}

; @returns {Object|String} Outlook's automation object, "" when it does not answer.
_LLM_AgentConnector_Outlook() {
	global _LLM_AgentConnector_ComFn
	Com := HasMethod(_LLM_AgentConnector_ComFn, "Call") ? _LLM_AgentConnector_ComFn : AL_ComApplication
	Outlook := Com.Call("Outlook.Application")
	if !IsObject(Outlook)
		LoggerInfo("LLM", "AI agent connector: Outlook does not answer, the system's default handler is used.")
	return Outlook
}

; A fresh entry id ("<random hex>@ergopti") and the current UTC stamp.
; @returns {Map} Map("uid", "stamp").
_LLM_AgentConnector_NewId() {
	Stamp := A_NowUTC
	return Map(
		"uid", Format("{:08x}{:08x}", Random(0, 0xFFFFFFFF), Random(0, 0xFFFFFFFF)) . "@ergopti",
		"stamp", SubStr(Stamp, 1, 8) . "T" . SubStr(Stamp, 9, 6) . "Z")
}

; Deletes the temporary files of the earlier runs; a failure is logged.
_LLM_AgentConnector_DeleteEarlierFiles() {
	global _LLM_AgentConnector_TempFiles, _LLM_AgentConnector_DeleteFn
	if !_LLM_AgentConnector_TempFiles.Length
		return
	Delete := HasMethod(_LLM_AgentConnector_DeleteFn, "Call") ? _LLM_AgentConnector_DeleteFn : FSDelete
	Pending := _LLM_AgentConnector_TempFiles
	_LLM_AgentConnector_TempFiles := []
	for Path in Pending {
		if !Delete.Call(Path) {
			LoggerError("LLM", "AI agent connector: a temporary calendar file could not be deleted.")
			_LLM_AgentConnector_TempFiles.Push(Path)
		}
	}
}





; ========================
; ========================
; ======= 3/ Tools =======
; ========================
; ========================

/**
 * The user's tools: the .ps1, .cmd and .ahk files of the tools folder, named
 * by their file name without the extension, sorted, capped to max_tools. The
 * list is reused for LLM_AGENT_TOOLS_TTL_MS.
 * @param {Map} Config The decoded agent.json.
 * @param {Boolean} Force Whether to read the folder again now.
 * @param {Integer} NowTick Optional snapshot tick; defaults to the current clock.
 * @returns {Map} Map("names", Array, "paths", Map(Name -> Path)).
 */
LLM_AgentConnector_Tools(Config, Force := false, NowTick := unset) {
	Now := IsSet(NowTick) ? NowTick : A_TickCount
	global _LLM_AgentConnector_Tools, _LLM_AgentConnector_ListFn, _LLM_AgentConnector_EnsureDirFn
	global LLM_AGENT_TOOL_EXTENSIONS, LLM_AGENT_TOOLS_TTL_MS
	if !Force && (_LLM_AgentConnector_Tools is Map)
			&& TickElapsed(_LLM_AgentConnector_Tools["tick"], Now) < LLM_AGENT_TOOLS_TTL_MS
		return _LLM_AgentConnector_Tools
	Dir := LLM_AgentConnector_ToolsDir()
	Ensure := HasMethod(_LLM_AgentConnector_EnsureDirFn, "Call") ? _LLM_AgentConnector_EnsureDirFn
		: FSEnsureDirectoryStrict
	List := HasMethod(_LLM_AgentConnector_ListFn, "Call") ? _LLM_AgentConnector_ListFn : FSListDirectoryStrict
	Paths := Map()
	Sorted := ""
	try {
		Ensure.Call(Dir)
		for Path in List.Call(Dir) {
			SplitPath(Path, , , &Extension, &Name)
			if !LLM_AGENT_TOOL_EXTENSIONS.Has(StrLower(Extension)) || Name == "" || Paths.Has(Name)
				continue
			Paths[Name] := Path
			Sorted .= (Sorted == "" ? "" : "`n") . Name
		}
	} catch as Err {
		LoggerError("LLM", "AI agent: the tools folder could not be read: {1}.", Err.Message)
	}
	Names := []
	if (Sorted != "") {
		for Name in StrSplit(Sort(Sorted), "`n") {
			if (Names.Length >= Config["max_tools"])
				break
			Names.Push(Name)
		}
	}
	Kept := Map()
	for Name in Names
		Kept[Name] := Paths[Name]
	_LLM_AgentConnector_Tools := Map("names", Names, "paths", Kept, "tick", Now)
	LoggerDebug("LLM", "AI agent: {1} tool(s) in the tools folder.", Names.Length)
	return _LLM_AgentConnector_Tools
}

/**
 * The tool names the prompts and the action validation use.
 * @param {Map} Config The decoded agent.json.
 * @returns {Array}
 */
LLM_AgentConnector_ToolNames(Config) {
	return LLM_AgentConnector_Tools(Config)["names"].Clone()
}

/**
 * The folder of the user's tools.
 * @returns {String}
 */
LLM_AgentConnector_ToolsDir() {
	global _ConfigDir
	return RTrim(_ConfigDir, "\/") . "\agent_tools"
}
