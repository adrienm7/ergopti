; tests/unit/modules/llm/servers/test_local_server_ports.ahk

; ==============================================================================
; MODULE: Local Server Port Discovery Tests
; DESCRIPTION:
; Replays the shared machine-reading corpus (local_server_ports.json) through
; the AHK port of the policy, drives the Windows PowerShell scan through a fake
; spawn, and composes the scan with the actual LocalServersOwner sweep:
; - a server on a non-default port (8181 from oMLX's settings file) is found;
; - a server whose process does not run is not probed;
; - none answering, or none running, still publishes none.
;
; ROOT CAUSE ENCODED:
; The maintainer's oMLX listened on 8181, set in its app, while every driver
; probed the catalogue port only: "none answers" every sweep.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Shared Corpus ============
; =====================================
; =====================================

_LSP_Catalogue() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\modules\llm\local_servers.json", "UTF-8"))
}

_LSP_DescriptorIsValid(Id, Catalogue) {
	AssertTrue(LocalServerPortsDescriptor(Id, Catalogue["servers"][Id]["discovery"])["descriptor"] is Map)
}

_LSP_Replay(Vector, Catalogue) {
	Server := Catalogue["servers"][Vector["server"]]
	Verdict := LocalServerPortsDescriptor(Vector["server"], Server["discovery"])
	AssertTrue(Verdict["descriptor"] is Map, Verdict["problem"])
	Files := Vector["files"]
	Context := Map("os", Vector["os"], "home", "/Users/u", "decode_json", JsonParse,
		"read_file", (Path) => Files.Has(Path) ? Files[Path] : 0)
	Result := LocalServerPortsResolve(Vector["server"], Verdict["descriptor"], Server["base_url"],
		LocalServerPortsParseProcesses(Vector["ps"]), Context)
	if Result["needs_listeners"] {
		Listeners := 0
		if Vector.Has("lsof")
			Listeners := LocalServerPortsParseLsof(Vector["lsof"])
		if Vector.Has("ss")
			Listeners := LocalServerPortsParseSs(Vector["ss"])
		LocalServerPortsApplyListeners(Result, Listeners)
	}
	Expected := Vector["expected"]
	AssertEqual(Expected["running"] ? true : false, Result["running"] ? true : false, "running")
	if Expected.Has("pids") {
		Pids := "", Wanted := ""
		for Index, Pid in Result["pids"]
			Pids .= (Index > 1 ? "," : "") Pid
		for Index, Pid in Expected["pids"]
			Wanted .= (Index > 1 ? "," : "") Pid
		AssertEqual(Wanted, Pids, "pids")
	}
	if Expected["running"] {
		AssertEqual(Expected["source"], Result["source"], "source")
		AssertEqual(Expected["port"], Result["port"], "port")
		AssertEqual(Expected["base_url"], Result["base_url"], "base_url")
		AssertFalse(Result["needs_listeners"])
	}
}

_LSP_RegisterCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\local_server_ports.json", "UTF-8"))
	if Corpus["version"] != 1 || Corpus["cases"].Length != 17
		throw Error("The independent port discovery corpus requires explicit review.")
	Catalogue := _LSP_Catalogue()
	for Id in Catalogue["server_order"]
		Test("local server ports: catalogue descriptor is valid: " . Id, _LSP_DescriptorIsValid.Bind(Id, Catalogue))
	for Vector in Corpus["cases"]
		Test("local server ports corpus: " . Vector["name"], _LSP_Replay.Bind(Vector, Catalogue))
}
_LSP_RegisterCorpus()





; =====================================
; =====================================
; ======= 2/ Windows Scan =============
; =====================================
; =====================================

class _LSP_ScanFixture {
	__New(Files := Map()) {
		this.Spawns := []
		this.Timers := []
		this.Terminated := 0
		this.Results := 0
		this.Scanner := LocalServerPortScan(Map("spawn", ObjBindMethod(this, "Spawn"),
			"timer", ObjBindMethod(this, "Timer"), "read_file", (Path) => Files.Has(Path) ? Files[Path] : 0,
			"home", "C:\Users\u"))
	}

	Spawn(Executable, Args, OnDone) {
		Record := Map("executable", Executable, "args", Args, "on_done", OnDone)
		this.Spawns.Push(Record)
		Fixture := this
		return {start: (*) => true, terminate: (*) => (Fixture.Terminated += 1, true)}
	}

	Timer(Callback, Period) {
		this.Timers.Push(Map("callback", Callback, "period", Period))
		return true
	}

	Entries() {
		Catalogue := _LSP_Catalogue(), Entries := []
		for Id in Catalogue["server_order"]
			Entries.Push(Map("id", Id, "descriptor", LocalServerPortsDescriptor(Id, Catalogue["servers"][Id]["discovery"])["descriptor"],
				"base_url", Catalogue["servers"][Id]["base_url"]))
		return Entries
	}

	Scan() {
		AssertTrue(this.Scanner.Scan(this.Entries(), (Results) => this.Results := Results))
	}
}

_LSP_ScanFindsListeningPort() {
	Fixture := _LSP_ScanFixture()
	Fixture.Scan()
	AssertEqual(1, Fixture.Spawns.Length)
	AssertContains(Fixture.Spawns[1]["executable"], "powershell.exe")
	AssertTrue(Fixture.Timers.Length == 1 && Fixture.Timers[1]["period"] < 0, "the scan arms one deadline")
	Fixture.Spawns[1]["on_done"].Call(0, "P 900 C:\Program Files\Jan\Jan.exe`r`nP 4 System`r`nL 900 127.0.0.1 1338`r`nL 900 127.0.0.1 39291`r`n", "")
	AssertTrue(Fixture.Results is Map)
	AssertEqual("http://127.0.0.1:1338/v1", Fixture.Results["jan"]["base_url"])
	AssertEqual("listening", Fixture.Results["jan"]["source"])
	AssertFalse(Fixture.Results["omlx"]["running"], "a server whose process does not run is reported as such")
}
Test("local server ports: the Windows scan reads a running server's listening port", _LSP_ScanFindsListeningPort)

_LSP_ScanCommandLinePort() {
	Fixture := _LSP_ScanFixture()
	Fixture.Scan()
	Fixture.Spawns[1]["on_done"].Call(0, "P 700 C:\llama\llama-server.exe -m q.gguf --port 8181`r`n", "")
	AssertEqual("http://127.0.0.1:8181/v1", Fixture.Results["llamacpp"]["base_url"])
	AssertEqual("cli", Fixture.Results["llamacpp"]["source"])
}
Test("local server ports: the Windows scan reads a command-line port", _LSP_ScanCommandLinePort)

_LSP_ScanDeadline() {
	Fixture := _LSP_ScanFixture()
	Fixture.Scan()
	Fixture.Timers[1]["callback"].Call()
	AssertEqual(1, Fixture.Terminated, "an overdue scan is terminated")
	AssertEqual("default", Fixture.Results["omlx"]["source"], "an unread process list probes the catalogue port")
	Late := Fixture.Results
	Fixture.Spawns[1]["on_done"].Call(0, "P 700 llama-server --port 9999`r`n", "")
	AssertTrue(ObjPtr(Late) == ObjPtr(Fixture.Results), "a late answer cannot settle the scan twice")
}
Test("local server ports: the Windows scan is bounded by its deadline", _LSP_ScanDeadline)

; ROOT CAUSE ENCODED: a sweep without a process list went straight to the
; catalogue port, logged as an error, though a settings file still named the
; port the server listens on (omlx-ps-timeout-config).
_LSP_ScanUnlistedReadsConfig() {
	Fixture := _LSP_ScanFixture(Map("C:/Users/u/.fixture/settings.json", '{"server":{"port":8181}}'))
	Config := Map("os", ["windows"], "dir", "~/.fixture", "file", "settings.json", "port_key", "server.port")
	Descriptor := LocalServerPortsDescriptor("fixture", Map("process_names", ["fixture-server"],
		"config_files", [Config]))["descriptor"]
	AssertTrue(Descriptor is Map, "the fixture descriptor is valid")
	Entries := [Map("id", "fixture", "descriptor", Descriptor, "base_url", "http://127.0.0.1:8000/v1")]
	Fixture.Scanner.Scan(Entries, (Value) => Fixture.Results := Value)
	Fixture.Timers[1]["callback"].Call()
	AssertTrue(Fixture.Results is Map, "the overdue scan settles")
	AssertEqual("config", Fixture.Results["fixture"]["source"], "the settings file does not depend on the process list")
	AssertEqual("http://127.0.0.1:8181/v1", Fixture.Results["fixture"]["base_url"])
	AssertTrue(Fixture.Results["fixture"]["running"], "a server without a process list is probed")
}
Test("local server ports: a Windows scan without a process list still reads the settings port", _LSP_ScanUnlistedReadsConfig)





; =====================================
; =====================================
; ======= 3/ Owner Composition ========
; =====================================
; =====================================

class _LSP_OwnerFixture extends _LSO_Fixture {
	__New() {
		super.__New(true)
		this.Scans := []
		this.ScanResults := Map()
		Descriptor := Map("process_names", ["fixture-server"], "command_lines", [], "port_flags", [],
			"address_flags", [], "config_files", [])
		this.Native := LocalServersOwner(Map("order", this.Order, "servers", this.Servers,
			"models_owner", this.Transport, "poll_ms", 20,
			"clock", ObjBindMethod(this, "Clock"), "max_age", (*) => 1000,
			"entry", ObjBindMethod(this, "Entry"), "capture_source", ObjBindMethod(this, "CaptureSource"),
			"source_current", ObjBindMethod(this, "SourceCurrent"), "admit", ObjBindMethod(this, "Admission"),
			"apply", ObjBindMethod(this, "Persist"), "timer", ObjBindMethod(this, "QueueTimer"),
			"on_publish", ObjBindMethod(this, "Publish"), "on_error", ObjBindMethod(this, "NativeError"),
			"scan_ports", ObjBindMethod(this, "Scan"), "discovery", Map("lmstudio", Descriptor, "llamacpp", Descriptor)))
	}

	Scan(Entries, OnDone) {
		this.Scans.Push(Entries)
		OnDone.Call(this.ScanResults)
	}

	Stopped(Id) {
		return Map("id", Id, "running", false, "pids", [], "base_url", this.Servers[Id]["base_url"],
			"port", 0, "source", "", "detail", "no running process", "needs_listeners", false)
	}
}

_LSP_OwnerProbesScannedPort() {
	global LLM_LOCAL_SERVER_SCANS
	Saved := LLM_LOCAL_SERVER_SCANS
	Fixture := _LSP_OwnerFixture()
	try {
		Fixture.ScanResults["lmstudio"] := Map("id", "lmstudio", "running", true, "pids", [42],
			"base_url", "http://127.0.0.1:8181/custom/v1/", "port", 8181, "source", "config", "detail", "", "needs_listeners", false)
		Fixture.ScanResults["llamacpp"] := Fixture.Stopped("llamacpp")
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual(1, Fixture.Scans.Length)
		AssertEqual(1, Fixture.Requests.Length, "a server whose process does not run is not probed")
		Fixture.Complete(1, 200, '{"data":[{"id":"qwen3"}]}')
		AssertEqual(1, Fixture.Published.Length)
		AssertEqual("http://127.0.0.1:8181/custom/v1/", Fixture.Native.Result("lmstudio")["base_url"])
		Views := Fixture.Native.ServerViews()
		AssertEqual("lmstudio", Views[1]["id"])
		AssertEqual(8181, Views[1]["port"])
		AssertEqual("config", Views[1]["port_source"])
		AssertEqual("qwen3", Views[1]["models"][1])
		AssertEqual("not_running", Views[2]["reason"])
		AssertEqual("http://127.0.0.1:8181/custom/v1/", LLM_LOCAL_SERVER_SCANS["lmstudio"]["base_url"],
			"requests of an entry at the default address follow the scan")
	} finally {
		Fixture.Dispose()
		LLM_LOCAL_SERVER_SCANS := Saved
	}
}
Test("local server ports: the owner probes the scanned port only for running servers", _LSP_OwnerProbesScannedPort)

_LSP_OwnerNoneRunning() {
	global LLM_LOCAL_SERVER_SCANS
	Saved := LLM_LOCAL_SERVER_SCANS
	Fixture := _LSP_OwnerFixture()
	try {
		Fixture.ScanResults["lmstudio"] := Fixture.Stopped("lmstudio")
		Fixture.ScanResults["llamacpp"] := Fixture.Stopped("llamacpp")
		Done := []
		AssertTrue(Fixture.Native.Rescan((Changed) => Done.Push(Changed)))
		AssertEqual(0, Fixture.Requests.Length, "no running server, no probe")
		AssertEqual(1, Fixture.Published.Length, "a sweep without a running server still publishes")
		AssertEqual(1, Done.Length)
		AssertEqual(0, Fixture.Native.Detected().Length)
	} finally {
		Fixture.Dispose()
		LLM_LOCAL_SERVER_SCANS := Saved
	}
}
Test("local server ports: no running server publishes none", _LSP_OwnerNoneRunning)
