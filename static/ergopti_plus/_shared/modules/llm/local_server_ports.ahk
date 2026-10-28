; _shared/modules/llm/local_server_ports.ahk

; ==============================================================================
; MODULE: Local Server Port Discovery Policy
; DESCRIPTION:
; The AutoHotkey port of _shared/lua/llm/local_server_ports.lua, replayed on the
; same corpus (_shared/tests/corpus/llm/local_server_ports.json). A catalogue
; server is probed only while its process runs, at the port of its command
; line, else of its settings file, else one its process listens on, and only
; then at the catalogue default, reported as such. Pure: the driver reads the
; process list and the listening sockets asynchronously and injects them.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Descriptor ===============
; =====================================
; =====================================

/** @returns {Boolean} Whether Value is an Array of non-empty strings. */
_LocalServerPortsStringList(Value) {
	if !(Value is Array)
		return false
	for Item in Value
		if !(Item is String) || Item == ""
			return false
	return true
}

/**
 * Validates the discovery object of one catalogue server.
 * @param {String} Id Server id.
 * @param {Any} Raw The server's "discovery" object of local_servers.json.
 * @returns {Map} Map("descriptor", Map|0, "reason", String).
 */
LocalServerPortsDescriptor(Id, Raw) {
	if !(Raw is Map)
		return Map("descriptor", 0, "reason", "server '" Id "' has no discovery object")
	Lists := Map()
	for Key in ["process_names", "command_lines", "port_flags", "address_flags"] {
		Value := Raw.Get(Key, [])
		if !_LocalServerPortsStringList(Value)
			return Map("descriptor", 0, "reason", "server '" Id "' discovery." Key " is not a list of strings")
		Lists[Key] := Value
	}
	if Lists["process_names"].Length + Lists["command_lines"].Length == 0
		return Map("descriptor", 0, "reason", "server '" Id "' declares no process name nor command line")
	Configs := []
	RawConfigs := Raw.Get("config_files", [])
	if !(RawConfigs is Array)
		return Map("descriptor", 0, "reason", "server '" Id "' discovery.config_files is not a list")
	for Index, Config in RawConfigs {
		Valid := (Config is Map) && _LocalServerPortsStringList(Config.Get("os", 0)) && Config["os"].Length > 0
			&& (Config.Get("dir", 0) is String) && Config["dir"] != ""
			&& (Config.Get("file", 0) is String) && Config["file"] != ""
			&& (Config.Get("port_key", 0) is String) && RegExMatch(Config["port_key"], "^\w[\w.]*$")
			&& (!Config.Has("dir_file") || ((Config["dir_file"] is String) && Config["dir_file"] != ""))
		if Valid
			for OsName in Config["os"]
				if !(OsName == "macos" || OsName == "linux" || OsName == "windows")
					Valid := false
		if !Valid
			return Map("descriptor", 0, "reason", "server '" Id "' discovery.config_files[" Index "] is malformed")
		Configs.Push(Config)
	}
	Lists["config_files"] := Configs
	return Map("descriptor", Lists, "reason", "")
}





; =====================================
; =====================================
; ======= 2/ Machine Readings =========
; =====================================
; =====================================

/** @returns {Array} Map("pid", Integer, "command", String) rows of "pid command" lines. */
LocalServerPortsParseProcesses(Text) {
	Processes := []
	for Line in StrSplit(Text, "`n", "`r") {
		if RegExMatch(Line, "^\s*(\d+)\s+(.*?)\s*$", &Match) && Match[2] != ""
			Processes.Push(Map("pid", Integer(Match[1]), "command", Match[2]))
	}
	return Processes
}

/** @returns {Map|Integer} Map("host", String, "port", Integer) of "host:port", else 0. */
_LocalServerPortsSplitAddress(Address) {
	if !RegExMatch(Address, "^(.*):(\d+)$", &Match)
		return 0
	Port := Integer(Match[2])
	if Port < 1 || Port > 65535
		return 0
	return Map("host", Match[1], "port", Port)
}

/** @returns {Array} Map("pid", "host", "port") rows of "pid host port" lines (Windows scan). */
LocalServerPortsParseListeners(Text) {
	Listeners := []
	for Line in StrSplit(Text, "`n", "`r") {
		if !RegExMatch(Line, "^\s*(\d+)\s+(\S+)\s+(\d+)\s*$", &Match)
			continue
		Port := Integer(Match[3])
		if Port >= 1 && Port <= 65535
			Listeners.Push(Map("pid", Integer(Match[1]), "host", Match[2], "port", Port))
	}
	return Listeners
}

/** @returns {Array} Rows of lsof -F pn output (macOS corpus readings). */
LocalServerPortsParseLsof(Text) {
	Listeners := [], Pid := 0
	for Line in StrSplit(Text, "`n", "`r") {
		Tag := SubStr(Line, 1, 1), Value := SubStr(Line, 2)
		if Tag == "p" && RegExMatch(Value, "^\d+$")
			Pid := Integer(Value)
		else if Tag == "n" && Pid {
			RegExMatch(Value, "^\S+", &Word)
			Address := Word ? _LocalServerPortsSplitAddress(Word[0]) : 0
			if Address is Map
				Listeners.Push(Map("pid", Pid, "host", Address["host"], "port", Address["port"]))
		}
	}
	return Listeners
}

/** @returns {Array} Rows of ss -Hltnp output (Linux corpus readings). */
LocalServerPortsParseSs(Text) {
	Listeners := []
	for Line in StrSplit(Text, "`n", "`r") {
		Columns := []
		Position := 1
		while RegExMatch(Line, "\S+", &Word, Position) {
			Columns.Push(Word[0])
			Position := Word.Pos + Word.Len
		}
		Address := Columns.Length >= 4 ? _LocalServerPortsSplitAddress(Columns[4]) : 0
		if !(Address is Map)
			continue
		Position := 1
		while RegExMatch(Line, "pid=(\d+)", &Owner, Position) {
			Listeners.Push(Map("pid", Integer(Owner[1]), "host", Address["host"], "port", Address["port"]))
			Position := Owner.Pos + Owner.Len
		}
	}
	return Listeners
}





; =====================================
; =====================================
; ======= 3/ Resolution ===============
; =====================================
; =====================================

/**
 * Tells whether a command line runs one of the descriptor's processes: a
 * process name is the executable's file name (".exe" optional) at the start of
 * the line or after a path separator, followed by a space or the end; a
 * command line fragment matches as a substring. Both ignore case.
 */
LocalServerPortsMatches(Descriptor, Command) {
	for Name in Descriptor["process_names"] {
		for Form in [Name, Name ".exe"] {
			Start := 1
			while Found := InStr(Command, Form, false, Start) {
				Before := Found == 1 ? "" : SubStr(Command, Found - 1, 1)
				After := SubStr(Command, Found + StrLen(Form), 1)
				if (Before == "" || Before == "/" || Before == "\") && (After == "" || After == " ")
					return true
				Start := Found + 1
			}
		}
	}
	for Fragment in Descriptor["command_lines"]
		if InStr(Command, Fragment, false)
			return true
	return false
}

/** @returns {Integer} A TCP port, else 0. */
_LocalServerPortsValid(Value) {
	if (Value is Integer) && Value >= 1 && Value <= 65535
		return Value
	if (Value is String) && RegExMatch(Value, "^\d{1,5}$") && Integer(Value) >= 1 && Integer(Value) <= 65535
		return Integer(Value)
	return 0
}

/** @returns {Map|Integer} Map("port", "flag") from "--port N", "--port=N" or "--address [host]:N". */
_LocalServerPortsFromCommand(Descriptor, Command) {
	Tokens := []
	Position := 1
	while RegExMatch(Command, "\S+", &Word, Position) {
		Tokens.Push(Word[0])
		Position := Word.Pos + Word.Len
	}
	for Index, Token in Tokens {
		for Kind in ["port_flags", "address_flags"] {
			for Flag in Descriptor[Kind] {
				Value := ""
				if Token == Flag && Index < Tokens.Length
					Value := Tokens[Index + 1]
				else if SubStr(Token, 1, StrLen(Flag) + 1) == Flag "="
					Value := SubStr(Token, StrLen(Flag) + 2)
				if Kind == "address_flags"
					Value := RegExMatch(Value, ":(\d+)$", &Tail) ? Tail[1] : ""
				Port := _LocalServerPortsValid(Value)
				if Port
					return Map("port", Port, "flag", Flag)
			}
		}
	}
	return 0
}

/** Expands a leading "~" against the home folder. */
_LocalServerPortsExpand(Path, Home) {
	if Path == "~"
		return Home
	if SubStr(Path, 1, 2) == "~/"
		return Home SubStr(Path, 2)
	return Path
}

/** @returns {Map} Map("port", Integer, "path", String, "problem", String) of one settings file. */
_LocalServerPortsFromConfig(Config, Context) {
	Dir := _LocalServerPortsExpand(Config["dir"], Context["home"])
	if Config.Has("dir_file") {
		Pointer := Context["read_file"].Call(_LocalServerPortsExpand(Config["dir_file"], Context["home"]))
		Moved := (Pointer is String) ? Trim(Pointer, " `t`r`n") : ""
		if Moved != ""
			Dir := _LocalServerPortsExpand(Moved, Context["home"])
	}
	Path := RTrim(Dir, "/") "/" Config["file"]
	Raw := Context["read_file"].Call(Path)
	if !(Raw is String)
		return Map("port", 0, "path", Path, "problem", "")
	try Root := Context["decode_json"].Call(Raw)
	catch
		return Map("port", 0, "path", Path, "problem", "malformed JSON")
	if !(Root is Map)
		return Map("port", 0, "path", Path, "problem", "malformed JSON")
	Node := Root
	for Key in StrSplit(Config["port_key"], ".")
		Node := (Node is Map) ? Node.Get(Key, "") : ""
	if Node == ""
		return Map("port", 0, "path", Path, "problem", "")
	Port := _LocalServerPortsValid(Node)
	return Map("port", Port, "path", Path, "problem", Port ? "" : Config["port_key"] " is not a TCP port")
}

/** Replaces the port, and when given the host, of a catalogue base URL. */
LocalServerPortsWithPort(BaseUrl, Port, Host := "") {
	if !RegExMatch(BaseUrl, "^(https?://)(\[[^\]]+\]|[^/:]+)(?::\d+)?(.*)$", &Match)
		throw ValueError("Catalogue base_url has no host.", -1, BaseUrl)
	return Match[1] (Host != "" ? Host : Match[2]) ":" Port Match[3]
}

/** @returns {Integer} The catalogue default port of a base URL. */
LocalServerPortsDefaultPort(BaseUrl) {
	if !RegExMatch(BaseUrl, "^https?://[^/]*?:(\d+)", &Match) || !_LocalServerPortsValid(Match[1])
		throw ValueError("Catalogue base_url names no port.", -1, BaseUrl)
	return Integer(Match[1])
}

/**
 * Resolves one server from the process list and its settings files.
 * @param {Map} Context Map("os", "home", "read_file", "decode_json").
 * @returns {Map} id, running, pids, base_url, port, source, detail, needs_listeners.
 */
LocalServerPortsResolve(Id, Descriptor, BaseUrl, Processes, Context) {
	Result := Map("id", Id, "running", false, "pids", [], "base_url", BaseUrl,
		"port", LocalServerPortsDefaultPort(BaseUrl), "source", "", "detail", "", "needs_listeners", false)
	Cli := 0
	for Process in Processes {
		if LocalServerPortsMatches(Descriptor, Process["command"]) {
			Result["pids"].Push(Process["pid"])
			if !(Cli is Map)
				Cli := _LocalServerPortsFromCommand(Descriptor, Process["command"])
		}
	}
	if Result["pids"].Length == 0 {
		Result["detail"] := "no running process"
		return Result
	}
	Result["running"] := true
	if Cli is Map {
		Result["port"] := Cli["port"], Result["source"] := "cli", Result["detail"] := Cli["flag"]
		Result["base_url"] := LocalServerPortsWithPort(BaseUrl, Cli["port"])
		return Result
	}
	Problems := []
	for Config in Descriptor["config_files"] {
		Applies := false
		for OsName in Config["os"]
			Applies := Applies || OsName == Context["os"]
		if !Applies
			continue
		Read := _LocalServerPortsFromConfig(Config, Context)
		if Read["port"] {
			Result["port"] := Read["port"], Result["source"] := "config", Result["detail"] := Read["path"]
			Result["base_url"] := LocalServerPortsWithPort(BaseUrl, Read["port"])
			return Result
		}
		Problems.Push(Read["path"] ": " (Read["problem"] != "" ? Read["problem"] : "no port"))
	}
	Result["needs_listeners"] := true
	Detail := ""
	for Index, Problem in Problems
		Detail .= (Index > 1 ? "; " : "") Problem
	Result["detail"] := Detail
	return Result
}

/**
 * Completes a result that needs listening ports, then falls back to the
 * catalogue default: with several ports the default wins when the process
 * listens on it, else the lowest.
 * @param {Array|Integer} Listeners Parsed rows, or 0 when unread.
 */
LocalServerPortsApplyListeners(Result, Listeners) {
	if !Result["needs_listeners"]
		return Result
	Result["needs_listeners"] := false
	Owned := Map(), Hosts := Map(), Ports := []
	for Pid in Result["pids"]
		Owned[Pid] := true
	if Listeners is Array {
		for Listener in Listeners {
			if !Owned.Has(Listener["pid"])
				continue
			if !Hosts.Has(Listener["port"]) {
				Ports.Push(Listener["port"])
				Hosts[Listener["port"]] := []
			}
			Hosts[Listener["port"]].Push(Listener["host"])
		}
	}
	Reason := Result["detail"]
	if Ports.Length == 0 {
		Result["source"] := "default"
		Result["detail"] := ((Listeners is Array) ? "no listening port" : "listening ports unread")
			. (Reason != "" ? "; " Reason : "")
		return Result
	}
	; Hosts is a Map keyed by port: its enumeration is in ascending port order
	Sorted := []
	for Port in Hosts
		Sorted.Push(Port)
	Chosen := Sorted[1]
	for Port in Sorted
		if Port == Result["port"]
			Chosen := Port
	OnlyV6 := true
	for Bound in Hosts[Chosen]
		if !(Bound == "[::1]" || Bound == "::1")
			OnlyV6 := false
	Listed := ""
	for Index, Port in Sorted
		Listed .= (Index > 1 ? "," : "") Port
	Result["port"] := Chosen, Result["source"] := "listening", Result["detail"] := "listening on " Listed
	Result["base_url"] := LocalServerPortsWithPort(Result["base_url"], Chosen, OnlyV6 ? "[::1]" : "")
	return Result
}
