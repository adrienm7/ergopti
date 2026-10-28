; modules/llm/local_server_port_scan.ahk

; ==============================================================================
; MODULE: Local Server Port Scan (Windows)
; DESCRIPTION:
; Reads the machine for the shared port policy (local_server_ports.ahk): one
; hidden PowerShell child lists the processes with their command lines
; (Win32_Process) and the listening TCP sockets with their owners
; (Get-NetTCPConnection, whose fields are not localized as netstat's states
; are). It runs asynchronously through ShellRunner and is bounded by
; local_server_port_scan_timeout_ms, so the input thread never waits on it.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Scan Owner ===============
; =====================================
; =====================================

; One line per process ("P pid command line") and per listening socket
; ("L pid address port"); a command line is folded onto one line.
global LLM_LOCAL_SERVER_SCAN_SCRIPT := "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
	. " Get-CimInstance Win32_Process | ForEach-Object { $c = if ($_.CommandLine) { $_.CommandLine } else { $_.Name };"
	. " 'P ' + $_.ProcessId + ' ' + ($c -replace '\s+', ' ') };"
	. " Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {"
	. " 'L ' + $_.OwningProcess + ' ' + $_.LocalAddress + ' ' + $_.LocalPort }"

/** Finds where each catalogue server runs and listens, asynchronously. */
class LocalServerPortScan {

	/**
	 * @param {Map} Options Optional test ports: spawn(executable, args, on_done)
	 * returning a handle with start() and terminate(), timer(callback, period),
	 * read_file(path), home.
	 */
	__New(Options := Map()) {
		if !(Options is Map)
			throw TypeError("Local server port scan options must be a Map.")
		for Name in ["spawn", "timer", "read_file"]
			if Options.Has(Name) && !HasMethod(Options[Name], "Call")
				throw TypeError("Local server port scan port must be callable.", -1, Name)
		this.Options := Options
	}

	/**
	 * Scans every entry and calls OnDone once with the results.
	 * @param {Array} Entries Map("id", "descriptor", "base_url") in catalogue order.
	 * @param {Func} OnDone Receives a Map: server id -> LocalServerPortsResolve result.
	 * @returns {Boolean} True; a failed reading still settles OnDone.
	 */
	Scan(Entries, OnDone) {
		if !(Entries is Array) || !HasMethod(OnDone, "Call")
			throw TypeError("Local server port scan requires entries and a completion observer.")
		try LoggerTrace("LLM.local_server_ports", "Scanning {1} local server process(es)…", Entries.Length)
		State := Map("settled", false, "handle", 0, "timer", 0)
		Finish := ObjBindMethod(this, "_Finish", Entries, OnDone, State)
		Executable := ShellRunner_WinPsPath()
		Args := ShellRunner_WinPsArgs("-Command", LLM_LOCAL_SERVER_SCAN_SCRIPT)
		Spawn := this.Options.Get("spawn", ShellRunner_Spawn)
		try {
			State["handle"] := Spawn.Call(Executable, Args, (ExitCode, Stdout, *) => Finish.Call(ExitCode == 0 ? Stdout : 0))
			Started := State["handle"].start()
		} catch as Err {
			try LoggerError("LLM.local_server_ports", "The process scan could not start: {1}", Err.Message)
			Started := false
		}
		if !Started {
			Finish.Call(0)
			return true
		}
		Deadline := TimingsGet("llm", "local_server_port_scan_timeout_ms")
		State["timer"] := ObjBindMethod(this, "_Expire", State, Finish, Deadline)
		this._Timer(State["timer"], -Deadline)
		return true
	}

	; One-shot by construction: the deadline must never become a repeating
	; poller on the keystroke thread, and the fast-timer inventory reads the
	; sign of the period where SetTimer is called.
	_Timer(Callback, DelayMs) {
		if this.Options.Has("timer")
			return this.Options["timer"].Call(Callback, -Abs(DelayMs))
		SetTimer(Callback, -Abs(DelayMs))
	}

	_Expire(State, Finish, Deadline) {
		if State["settled"]
			return
		try LoggerWarn("LLM.local_server_ports", "The process scan outlived its {1} ms deadline; terminating it.", Deadline)
		try State["handle"].terminate()
		Finish.Call(0)
	}

	_ReadFile(Path) {
		if this.Options.Has("read_file")
			return this.Options["read_file"].Call(Path)
		try return FileRead(Path, "UTF-8")
		catch
			return 0
	}

	_Finish(Entries, OnDone, State, Output) {
		if State["settled"]
			return
		State["settled"] := true
		if State["timer"]
			try SetTimer(State["timer"], 0)
		Results := Map()
		if !(Output is String) {
			try LoggerError("LLM.local_server_ports", "The process list is unreadable: local servers are probed at their catalogue port.")
			for Entry in Entries
				Results[Entry["id"]] := Map("id", Entry["id"], "running", true, "pids", [], "base_url", Entry["base_url"],
					"port", LocalServerPortsDefaultPort(Entry["base_url"]), "source", "default",
					"detail", "process list unreadable", "needs_listeners", false)
			return this._Report(Entries, Results, OnDone)
		}
		ProcessRows := "", ListenerRows := ""
		for Line in StrSplit(Output, "`n", "`r") {
			if SubStr(Line, 1, 2) == "P "
				ProcessRows .= SubStr(Line, 3) "`n"
			else if SubStr(Line, 1, 2) == "L "
				ListenerRows .= SubStr(Line, 3) "`n"
		}
		Processes := LocalServerPortsParseProcesses(ProcessRows)
		Listeners := LocalServerPortsParseListeners(ListenerRows)
		Home := StrReplace(this.Options.Get("home", EnvGet("USERPROFILE")), "\", "/")
		Context := Map("os", "windows", "home", Home, "read_file", ObjBindMethod(this, "_ReadFile"), "decode_json", JsonParse)
		for Entry in Entries {
			Result := LocalServerPortsResolve(Entry["id"], Entry["descriptor"], Entry["base_url"], Processes, Context)
			Results[Entry["id"]] := LocalServerPortsApplyListeners(Result, Listeners)
		}
		return this._Report(Entries, Results, OnDone)
	}

	_Report(Entries, Results, OnDone) {
		Summary := ""
		for Entry in Entries {
			Result := Results[Entry["id"]]
			if Result["running"] {
				Pids := ""
				for Index, Pid in Result["pids"]
					Pids .= (Index > 1 ? "," : "") Pid
				try LoggerDebug("LLM.local_server_ports", "Local server '{1}': pid {2}, port {3} from {4}{5}.", Entry["id"],
					Pids != "" ? Pids : "unknown", Result["port"], Result["source"],
					Result["detail"] != "" ? " (" Result["detail"] ")" : "")
			} else
				try LoggerDebug("LLM.local_server_ports", "Local server '{1}': not running ({2}): not probed.", Entry["id"], Result["detail"])
			Summary .= (Summary != "" ? ", " : "") Entry["id"] "=" (Result["running"] ? Result["port"] "/" Result["source"] : "off")
		}
		try LoggerInfo("LLM.local_server_ports", "Local server ports: {1}.", Summary != "" ? Summary : "no server")
		try LoggerDone("LLM.local_server_ports", "Local server process scan settled.")
		OnDone.Call(Results)
	}
}
