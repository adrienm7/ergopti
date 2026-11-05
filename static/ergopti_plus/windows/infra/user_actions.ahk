; infra/user_actions.ahk

; ==============================================================================
; MODULE: User Actions
; DESCRIPTION:
; The run_command and open_path actions of Windows: the Windows half of
; _shared/lua/user_action_parameter.lua and the macOS and Linux user_actions.lua.
; _shared/tests/corpus/action_parameters/user_action_vectors.json pins the values.
;
; FEATURES & RATIONALE:
; 1. A command runs through cmd.exe, the shell every Windows has and the one the
;    examples of a Windows user are written for; a PowerShell line goes through
;    `powershell -Command`, or a run_program binding.
; 2. The command text reaches the inner cmd.exe by delayed expansion of a private
;    variable: the outer cmd.exe has finished parsing by then, so no quote or
;    metacharacter of the text can reach its redirections, and stdout and stderr
;    stay apart, which the job's single capture cannot do.
; 3. cmd.exe /c takes one line, so the lines of a script run one after the other,
;    joined by `&`. A block spread over several lines has to be written on one.
; 4. Windows paths have their own syntax, a drive letter or a UNC share, pinned by
;    the windows_path_vectors of the corpus. Whether the path exists is checked
;    when the action runs.
; 5. The command text is user configuration and may hold a secret: it is never
;    logged, and a failure's error line only reaches the user's own notification.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Parameters and spelling =======
; ==========================================
; ==========================================

global USER_ACTION_VERSION := 1
global USER_ACTION_MAX_COMMAND_BYTES := 4096
global USER_ACTION_MAX_PATH_BYTES := 4096
global USER_ACTION_NOTICE_LINE_BYTES := 200
global USER_ACTION_COMMAND_MODES := Map("hidden", true, "terminal", true)
global USER_ACTION_OUTPUTS := Map("none", true, "type", true, "copy", true)
; What a Windows file name cannot hold, the drive's own colon apart.
global USER_ACTION_PATH_FORBIDDEN := '[/:*?"<>|]'

; The UTF-8 size of a text, as the shared byte bounds count it.
_UserActionBytes(Text) {
	return StrPut(Text, "UTF-8") - 1
}

; Decodes a run_command value: versioned JSON with a closed key set, so a value
; written by a newer editor never runs half-read.
; @param {Any} Value The stored parameter.
; @returns {Map|Boolean} Map("command", "mode", "output"), or false.
UserActionParseCommand(Value) {
	global USER_ACTION_VERSION, USER_ACTION_MAX_COMMAND_BYTES, USER_ACTION_COMMAND_MODES, USER_ACTION_OUTPUTS
	if !(Value is String)
		return false
	try Data := JsonParse(Value)
	catch
		return false
	if !(Data is Map) || Data.Count != 4
		return false
	for Key in ["version", "command", "mode", "output"]
		if !Data.Has(Key)
			return false
	Version := Data["version"], Command := Data["command"], Mode := Data["mode"], Output := Data["output"]
	if !(Version is Integer) || Version != USER_ACTION_VERSION
		return false
	if !(Command is String) || !(Mode is String) || !(Output is String)
		return false
	if !RegExMatch(Command, "\S") || _UserActionBytes(Command) > USER_ACTION_MAX_COMMAND_BYTES
			|| RegExMatch(Command, "[\x00-\x08\x0B-\x1F\x7F]")
		return false
	if !USER_ACTION_COMMAND_MODES.Has(Mode) || !USER_ACTION_OUTPUTS.Has(Output)
		return false
	; A terminal window shows the output itself: nothing is captured to type or copy.
	if (Mode == "terminal" && Output != "none")
		return false
	return Map("command", Command, "mode", Mode, "output", Output)
}

; Decodes an open_path value: an absolute Windows path, as the native picker
; returns it, on a drive or a UNC share.
; @param {Any} Value The stored parameter.
; @returns {Map|Boolean} Map("path"), or false.
UserActionParsePath(Value) {
	global USER_ACTION_MAX_PATH_BYTES, USER_ACTION_PATH_FORBIDDEN
	if !(Value is String) || Value == "" || _UserActionBytes(Value) > USER_ACTION_MAX_PATH_BYTES
			|| RegExMatch(Value, "[\x00-\x1F\x7F]")
		return false
	if RegExMatch(Value, "^[A-Za-z]:\\", &Root)
		Rest := SubStr(Value, Root.Len + 1)
	else if RegExMatch(Value, "^\\\\[^\\]+\\[^\\]+(?:\\|$)", &Root)
		Rest := SubStr(Value, 3)
	else
		return false
	if RegExMatch(Rest, USER_ACTION_PATH_FORBIDDEN)
		return false
	for Component in StrSplit(Rest, "\")
		if (Component == "." || Component == "..")
			return false
	return Map("path", Value)
}

; The one canonical stored value of a command, valid or not: the editor hands an
; invalid spelling to its validator, which refuses it with the parameter's error.
; @param {String} Command The command text.
; @param {String} Mode "hidden" or "terminal".
; @param {String} Output "none", "type" or "copy".
; @returns {String}
UserActionSpellCommand(Command, Mode, Output) {
	global USER_ACTION_VERSION
	return '{"version":' . USER_ACTION_VERSION . ',"command":' . _UserActionJsonQuote(Command)
		. ',"mode":' . _UserActionJsonQuote(Mode) . ',"output":' . _UserActionJsonQuote(Output) . "}"
}

_UserActionJsonQuote(Text) {
	Text := StrReplace(StrReplace(Text, "\", "\\"), '"', '\"')
	return '"' . StrReplace(StrReplace(StrReplace(Text, "`n", "\n"), "`t", "\t"), "`r", "\r") . '"'
}

; What a menu shows for a stored path in its label's brackets: its last component,
; or the root itself. A command shows nothing: its text may hold a secret.
; @param {String} Value A stored open_path value.
; @returns {String} "" when the label keeps its configurable marker.
UserActionPathLabel(Value) {
	if !(UserActionParsePath(Value) is Map)
		return ""
	if RegExMatch(Value, "^[A-Za-z]:\\$")
		return Value
	return RegExMatch(Value, "([^\\]+)\\*$", &Last) ? Last[1] : Value
}





; ==========================
; ==========================
; ======= 2/ Effects =======
; ==========================
; ==========================

; The effects of the actions, replaced by recorders in the unit suite.
global _UserActionPorts := 0

_UserActionDefaultPorts() {
	static Ports := Map(
		"notify", (Text) => TrayTip(Text, "ErgoptiPlus", "Iconx Mute"),
		"copy", CB_Write,
		"type", (Text) => SendFinalResult(Text, true, true),
		"open_terminal", _UserActionOpenTerminal,
		"shell_open", _UserActionShellOpen)
	return Ports
}

_UserActionPort(Name) {
	global _UserActionPorts
	return ((_UserActionPorts is Map) ? _UserActionPorts : _UserActionDefaultPorts())[Name]
}

; A failure notice: the text may quote a path or the command's own error line, so
; it goes to the user alone, never to the log.
_UserActionNotify(Key, Values*) {
	Text := t(Key)
	for Index, Value in Values
		Text := StrReplace(Text, "{" . Index . "}", Value)
	return _UserActionPort("notify").Call(Text)
}

; cmd.exe /c takes one line: the lines of a script run one after the other.
; @param {String} Command The stored command text.
; @returns {String}
UserActionCommandLine(Command) {
	Lines := []
	for Line in StrSplit(Command, "`n", " `t") {
		if (Line != "")
			Lines.Push(Line)
	}
	Joined := ""
	for Index, Line in Lines
		Joined .= (Index > 1 ? " & " : "") . Line
	return Joined
}

_UserActionComSpec() {
	return A_WinDir . "\System32\cmd.exe"
}

; @param {String} Line The one command line. @returns {Boolean} Whether it opened.
_UserActionOpenTerminal(Line) {
	try {
		Run('"' . _UserActionComSpec() . '" /d /s /k "' . Line . '"', EnvGet("USERPROFILE"))
		return true
	} catch {
		; The exception's text quotes the command line.
		return false
	}
}

; @param {String} Path An existing file or folder. @returns {Boolean} Whether the shell took it.
_UserActionShellOpen(Path) {
	static SW_SHOWNORMAL := 1, SHELL_EXECUTE_OK_ABOVE := 32
	return DllCall("shell32\ShellExecuteW", "Ptr", 0, "Ptr", 0, "WStr", Path, "Ptr", 0, "Ptr", 0,
		"Int", SW_SHOWNORMAL, "Ptr") > SHELL_EXECUTE_OK_ABOVE
}





; ================================
; ================================
; ======= 3/ Run a command =======
; ================================
; ================================

; The hidden commands still running, by binding: a second press of a binding
; whose command is running starts nothing.
global _UserCommandEntries := Map()
global _UserCommandCounter := 0
global USER_COMMAND_VARIABLE := "ERGOPTI_USER_COMMAND"
global USER_COMMAND_OUT_VARIABLE := "ERGOPTI_USER_COMMAND_OUT"
global USER_COMMAND_ERR_VARIABLE := "ERGOPTI_USER_COMMAND_ERR"

; A copy of this process's environment with the command's private variables.
_UserCommandEnvironment(Added) {
	Source := DllCall("GetEnvironmentStringsW", "Ptr")
	if !Source
		throw OSError("The environment could not be read.")
	Rows := []
	try {
		At := Source
		while (Row := StrGet(At, "UTF-16")) != "" {
			Rows.Push(Row)
			At += (StrLen(Row) + 1) * 2
		}
	} finally DllCall("FreeEnvironmentStringsW", "Ptr", Source)
	for Name, Value in Added
		Rows.Push(Name . "=" . Value)
	Size := 2
	for Row in Rows
		Size += (StrLen(Row) + 1) * 2
	Block := Buffer(Size + 2, 0)
	At := Block.Ptr
	for Row in Rows {
		StrPut(Row, At, "UTF-16")
		At += (StrLen(Row) + 1) * 2
	}
	return Block
}

; The outer cmd.exe parses this line with the private variables unexpanded, so the
; command's own text cannot reach its redirections. chcp makes the inner cmd.exe
; print UTF-8 instead of the OEM code page.
_UserCommandShellLine() {
	global USER_COMMAND_VARIABLE, USER_COMMAND_OUT_VARIABLE, USER_COMMAND_ERR_VARIABLE
	Shell := _UserActionComSpec()
	; The redirections come first: after the command they leave a space that the
	; inner cmd.exe /s keeps as the end of the command's own text.
	return '"' . Shell . '" /d /v:on /s /c "chcp 65001 >nul & >"!' . USER_COMMAND_OUT_VARIABLE . '!" 2>"!'
		. USER_COMMAND_ERR_VARIABLE . '!" "' . Shell . '" /d /s /c "!' . USER_COMMAND_VARIABLE . '!""'
}

; Runs a run_command binding.
; @param {String} BindingId The binding whose parameter holds the command.
; @returns {Boolean} True when the command started.
UserActions_RunCommand(BindingId := "") {
	Fields := UserActionParseCommand(GestureGetActionParameter(BindingId, "run_command"))
	if !(Fields is Map) {
		LoggerWarn("UserActions", "run_command ignored for binding '{1}': no valid value is stored.", BindingId)
		return false
	}
	if A_IsSuspended
		return false
	Line := UserActionCommandLine(Fields["command"])
	if (Fields["mode"] == "terminal") {
		LoggerStart("UserActions", "Opening a console window for a run_command binding…")
		if _UserActionPort("open_terminal").Call(Line) {
			LoggerSuccess("UserActions", "The console window of a run_command binding opened.")
			return true
		}
		LoggerError("UserActions", "The console window of a run_command binding could not open.")
		_UserActionNotify("user_actions.terminal_unavailable")
		return false
	}
	return _UserCommandStart(BindingId, Line, Fields["output"])
}

_UserCommandStart(BindingId, Line, Output) {
	global _UserCommandEntries, _UserCommandCounter
	global USER_COMMAND_VARIABLE, USER_COMMAND_OUT_VARIABLE, USER_COMMAND_ERR_VARIABLE
	if _UserCommandEntries.Has(BindingId) {
		LoggerWarn("UserActions", "The command of binding '{1}' is still running: no second one was started.", BindingId)
		return false
	}
	Stem := A_Temp . "\ergopti_user_command_" . ProcessExist() . "_" . ++_UserCommandCounter
	Entry := Map("binding", BindingId, "output", Output, "out", Stem . ".out", "err", Stem . ".err",
		"started", A_TickCount, "stop_cause", "", "finished", false)
	_UserCommandEntries[BindingId] := Entry
	LoggerStart("UserActions", "Running the command of a run_command binding…")
	try {
		Environment := _UserCommandEnvironment(Map(USER_COMMAND_VARIABLE, Line,
			USER_COMMAND_OUT_VARIABLE, Entry["out"], USER_COMMAND_ERR_VARIABLE, Entry["err"]))
		; PrivateDiagnostics: the runner's own log lines must not quote this launch.
		Entry["handle"] := ShellRunner_SpawnTreeOwnedCommand(_UserActionComSpec(), _UserCommandShellLine(),
			Environment, EnvGet("USERPROFILE"), _UserCommandDone.Bind(Entry), , , 0, false, true)
		Started := Entry["handle"].start()
	} catch as Err {
		Started := false
		LoggerError("UserActions", "The command of a run_command binding could not start ({1}).", Type(Err))
	}
	if !(Started is Integer) || Started != 1 {
		LoggerError("UserActions", "The command of a run_command binding did not start.")
		_UserCommandFinish(Entry)
		return false
	}
	Entry["poll"] := _UserCommandPoll.Bind(Entry)
	TimerSetCallback(Entry["poll"], -TimingsGet("gestures", "aux_shell_cleanup_retry_ms"))
	return true
}

; Stops a command past its deadline or its output bound, while it runs: a command
; that prints without end must not fill the disk until the deadline.
_UserCommandPoll(Entry, *) {
	if Entry["finished"]
		return
	if (Entry["stop_cause"] == "") {
		if (A_TickCount - Entry["started"] >= TimingsGet("gestures", "run_command_timeout_ms"))
			Entry["stop_cause"] := "timeout"
		else if _UserCommandOutputOverflows(Entry)
			Entry["stop_cause"] := "overflow"
	}
	if (Entry["stop_cause"] != "") {
		; terminate() retires the completion callback, so its receipt finishes here.
		try Receipt := Entry["handle"].terminate()
		catch
			Receipt := false
		if (Receipt == 1) {
			_UserCommandReportStopped(Entry)
			_UserCommandFinish(Entry)
			return
		}
	}
	TimerSetCallback(Entry["poll"], -TimingsGet("gestures", "aux_shell_cleanup_retry_ms"))
}

_UserCommandOutputOverflows(Entry) {
	Limit := TimingsGet("limits", "user_action_output_bytes")
	for Path in [Entry["out"], Entry["err"]] {
		try Size := FileGetSize(Path)
		catch
			continue
		if (Size > Limit)
			return true
	}
	return false
}

_UserCommandReportStopped(Entry) {
	if (Entry["stop_cause"] == "timeout") {
		Seconds := Round(TimingsGet("gestures", "run_command_timeout_ms") / 1000)
		LoggerError("UserActions", "The command of a run_command binding was stopped after {1} seconds.", Seconds)
		_UserActionNotify("user_actions.command_timeout", Seconds)
	} else if (Entry["stop_cause"] == "overflow") {
		Limit := TimingsGet("limits", "user_action_output_bytes")
		LoggerError("UserActions", "The command of a run_command binding printed more than {1} bytes and was stopped.", Limit)
		_UserActionNotify("user_actions.command_output_too_large", Limit)
	}
}

; Reads a capture as strict UTF-8.
; @returns {String|Boolean} The text, "" for no file or no byte, false when it is not UTF-8.
_UserCommandRead(Path) {
	try Bytes := FSReadBytesStrict(Path)
	catch
		return ""
	if (Bytes.Size == 0)
		return ""
	if !HTTPIsValidUtf8(Bytes, Bytes.Size)
		return false
	; Valid UTF-8 can contain NUL, which this native text conversion would
	; silently truncate. Refuse the complete capture through the existing ABI.
	if DllCall("msvcrt\memchr", "Ptr", Bytes, "Int", 0, "UPtr", Bytes.Size, "CDecl Ptr")
		return false
	return StrGet(Bytes, Bytes.Size, "UTF-8")
}

; The first non-blank line of a process's error output, bounded, for a notice.
; @param {Any} Text The captured stderr.
; @param {Integer} Maximum Longest line kept, in bytes.
; @returns {String} "" when there is no such line.
UserActionFirstLine(Text, Maximum) {
	if !(Text is String)
		return ""
	for Line in StrSplit(Text, "`n", " `t`r") {
		if (Line == "")
			continue
		if (_UserActionBytes(Line) <= Maximum)
			return Line
		while (Line != "" && _UserActionBytes(Line) > Maximum)
			Line := SubStr(Line, 1, -1)
		; A cut must not leave half of a surrogate pair.
		if (Line != "" && (Ord(SubStr(Line, -1)) & 0xFC00) == 0xD800)
			Line := SubStr(Line, 1, -1)
		return Line . "…"
	}
	return ""
}

; The completion of a command that ran to its end.
_UserCommandDone(Entry, ExitCode := unset, *) {
	if Entry["finished"]
		return true
	try {
		if (Entry["stop_cause"] != "")
			_UserCommandReportStopped(Entry)
		else
			_UserCommandReport(Entry, ExitCode)
	} finally _UserCommandFinish(Entry)
	return true
}

_UserCommandReport(Entry, ExitCode) {
	global USER_ACTION_NOTICE_LINE_BYTES
	if _UserCommandOutputOverflows(Entry) {
		Entry["stop_cause"] := "overflow"
		_UserCommandReportStopped(Entry)
		return
	}
	if (ExitCode != 0) {
		LoggerError("UserActions", "The command of a run_command binding exited with code {1}.", ExitCode)
		Line := UserActionFirstLine(_UserCommandRead(Entry["err"]), USER_ACTION_NOTICE_LINE_BYTES)
		if (Line != "")
			_UserActionNotify("user_actions.command_failed_detail", ExitCode, Line)
		else
			_UserActionNotify("user_actions.command_failed", ExitCode)
		return
	}
	LoggerSuccess("UserActions", "The command of a run_command binding exited with code 0.")
	if (Entry["output"] != "none" && !A_IsSuspended)
		_UserCommandDeliver(_UserCommandRead(Entry["out"]), Entry["output"])
}

; The characters of a text as the typing limit counts them: a surrogate pair is one.
UserActionCodePoints(Text) {
	return StrLen(RegExReplace(Text, "s).", "x"))
}

; @param {String|Boolean} Text The captured stdout, false when it is not UTF-8.
; @param {String} Output "type" or "copy".
; @returns {Boolean} True when it was delivered.
_UserCommandDeliver(Text, Output) {
	if !(Text is String) {
		LoggerError("UserActions", "A run_command binding printed text that is not UTF-8: nothing to deliver.")
		_UserActionNotify("user_actions.output_not_text")
		return false
	}
	Value := RTrim(StrReplace(Text, "`r`n", "`n"), "`r`n")
	if (Value == "") {
		LoggerWarn("UserActions", "A run_command binding printed no text to deliver.")
		return false
	}
	if (Output == "copy") {
		Written := _UserActionPort("copy").Call(Value)
		if !Written
			LoggerError("UserActions", "The output of a run_command binding could not be copied.")
		return Written ? true : false
	}
	MaxTyped := SendKeysVocabulary()["text_max_code_points"]
	if (UserActionCodePoints(Value) > MaxTyped) {
		LoggerWarn("UserActions", "A run_command binding printed more than the {1} characters typed.", MaxTyped)
		_UserActionNotify("user_actions.output_too_long_to_type", MaxTyped)
		return false
	}
	Typed := _UserActionPort("type").Call(Value)
	if !Typed
		LoggerError("UserActions", "The output of a run_command binding could not be typed.")
	return Typed ? true : false
}

_UserCommandFinish(Entry) {
	global _UserCommandEntries
	Entry["finished"] := true
	if (_UserCommandEntries.Get(Entry["binding"], 0) == Entry)
		_UserCommandEntries.Delete(Entry["binding"])
	if Entry.Has("poll")
		TimerSetCallback(Entry["poll"], 0)
	for Path in [Entry["out"], Entry["err"]]
		if !FSDelete(Path)
			LoggerWarn("UserActions", "A capture of a run_command binding could not be deleted.")
}

; Stops every running command, as the program actions stop at a pause or a reload.
; @returns {Boolean} True once none is left.
UserActions_StopCommands() {
	global _UserCommandEntries
	Stopped := true
	for _, Entry in _UserCommandEntries.Clone() {
		try Receipt := Entry["handle"].terminate()
		catch
			Receipt := false
		if (Receipt == 1)
			_UserCommandFinish(Entry)
		else
			Stopped := false
	}
	return Stopped
}





; ==============================
; ==============================
; ======= 4/ Open a path =======
; ==============================
; ==============================

; Opens an open_path binding with its default application. A path that no longer
; exists is refused with a notice naming it.
; @param {String} BindingId The binding whose parameter holds the path.
; @returns {Boolean} True when the shell took it.
UserActions_OpenPath(BindingId := "") {
	Fields := UserActionParsePath(GestureGetActionParameter(BindingId, "open_path"))
	if !(Fields is Map) {
		LoggerWarn("UserActions", "open_path ignored for binding '{1}': no valid value is stored.", BindingId)
		return false
	}
	Path := Fields["path"]
	if !FileExist(Path) {
		LoggerWarn("UserActions", "open_path refused for binding '{1}': its stored path is missing.", BindingId)
		_UserActionNotify("user_actions.path_missing", Path)
		return false
	}
	LoggerStart("UserActions", "Opening the stored file or folder of an open_path binding…")
	if _UserActionPort("shell_open").Call(Path) {
		LoggerSuccess("UserActions", "The stored file or folder of an open_path binding opened.")
		return true
	}
	LoggerError("UserActions", "The shell refused the stored file or folder of an open_path binding.")
	_UserActionNotify("user_actions.path_open_failed", Path)
	return false
}
