; tests/unit/modules/llm/actions/test_llm_agent_tools_native64_ttl.ahk

; ==============================================================================
; MODULE: Agent Tools Native64 Cache Lifetime Tests
; DESCRIPTION:
; The public cache reads a real private tools directory through its existing
; enumeration port. Controlled full-width ticks model long gaps between reads;
; no tool is executed and no physical multi-day waiting is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_ATTL_List(State, Directory) {
	try {
		AssertEqual(State.Directory, Directory, "Only the exact private tools directory may be enumerated.")
		State.Reads += 1
		return FSListDirectoryStrict(Directory)
	} catch Any as Failure {
		if !IsObject(State.Failure)
			State.Failure := Failure
		throw Failure
	}
}

_ATTL_Read(State, Config, Force, Now) {
	Snapshot := LLM_AgentConnector_Tools(Config, Force, Now)
	if IsObject(State.Failure)
		throw State.Failure
	AssertTrue(Snapshot is Map && Snapshot["names"] is Array && Snapshot["paths"] is Map,
		"The actual public cache must return its declared snapshot shape.")
	return Snapshot
}

_ATTL_Exercise(Mode, State) {
	global LLM_AGENT_TOOLS_TTL_MS
	Config := LLM_Agent_Config()
	AssertTrue(Config["max_tools"] is Integer && Config["max_tools"] >= 1)
	AssertTrue(LLM_AGENT_TOOLS_TTL_MS is Integer && LLM_AGENT_TOOLS_TTL_MS > 1)
	Start := 0x100000000 + 1000
	OldPath := State.Directory . "\old.ps1"
	NewPath := State.Directory . "\new.cmd"
	AssertTrue(FSWriteCreateDurable(OldPath, "; private discovery fixture`n"))
	Initial := _ATTL_Read(State, Config, false, Start)
	AssertEqual(1, State.Reads, "The initial snapshot must actually enumerate the private directory.")
	AssertEqual(1, Initial["names"].Length)
	AssertEqual("old", Initial["names"][1])
	AssertEqual(OldPath, Initial["paths"]["old"])
	AssertEqual(Start, Initial["tick"])

	AssertEqual(1, FSDeleteStrict(OldPath))
	AssertTrue(FSWriteCreateDurable(NewPath, "rem private discovery fixture`n"))
	ActualFiles := FSListDirectoryStrict(State.Directory)
	AssertEqual(1, ActualFiles.Length)
	AssertEqual(NewPath, ActualFiles[1], "The independent native directory image must contain only B.")
	if Mode == "boundary" {
		Cached := _ATTL_Read(State, Config, false, Start + LLM_AGENT_TOOLS_TTL_MS - 1)
		AssertEqual(1, State.Reads, "A snapshot strictly before its TTL remains cached.")
		AssertEqual("old", Cached["names"][1])
		Now := Start + LLM_AGENT_TOOLS_TTL_MS
		Force := false
	} else if Mode == "long-gap" {
		Now := Start + 0x100000001
		Force := false
	} else {
		AssertEqual("force", Mode)
		Now := Start + 1
		Force := true
	}
	Current := _ATTL_Read(State, Config, Force, Now)
	_TestPrint("# AGENT_TOOLS64_RECEIPT mode=" . Mode . " age=" . (Now - Start)
		. " ttl=" . LLM_AGENT_TOOLS_TTL_MS . " reads=" . State.Reads
		. " names=" . Current["names"].Length . " has_old=" . Current["paths"].Has("old")
		. " has_new=" . Current["paths"].Has("new") . " tick=" . Current["tick"])
	AssertEqual(2, State.Reads, "An expired or explicitly forced public read must enumerate B.")
	AssertEqual(1, Current["names"].Length)
	AssertEqual("new", Current["names"][1], "The prompt inventory must publish the current file name.")
	AssertFalse(Current["paths"].Has("old"), "A removed tool must leave the executable inventory.")
	AssertEqual(NewPath, Current["paths"]["new"])
	AssertEqual(Now, Current["tick"], "The refreshed inventory must retain the observed native64 sample.")
}

_ATTL_Case(Mode) {
	global _ConfigDir, _LLM_AgentConnector_Tools, _LLM_AgentConnector_ListFn, _LLM_AgentConnector_EnsureDirFn
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	Extras := ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_LOGGER_PATH_DATE", "_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED",
		"_LOGGER_ERROR_ENABLED", "_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
	SavedExtras := Map(), Saved := 0, Claimed := false, Root := "", Primary := 0
	PreviousCritical := Critical("On")
	try {
		SavedLogger := _TLOG_CaptureLoggerState()
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached.")
		for Name in Extras
			SavedExtras[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
		Saved := {ConfigDir: _ConfigDir, Tools: _LLM_AgentConnector_Tools,
			List: _LLM_AgentConnector_ListFn, Ensure: _LLM_AgentConnector_EnsureDirFn}
		Claimed := true
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Critical("Off")
		CandidateRoot := _FSWL_Path() . ".agent-tools64"
		FSCreateDirectoryExclusiveStrict(CandidateRoot)
		Root := CandidateRoot
		State := {Directory: Root . "\agent_tools", Reads: 0, Failure: 0}
		FSCreateDirectoryExclusiveStrict(State.Directory)
		Observer := _ATTL_List.Bind(State)
		Critical("On")
		_ConfigDir := Root . "\", _LLM_AgentConnector_Tools := ""
		_LLM_AgentConnector_ListFn := Observer, _LLM_AgentConnector_EnsureDirFn := 0
		Critical("Off")
		_ATTL_Exercise(Mode, State)
	} catch Any as Failure {
		Primary := Failure
	}
	try {
		if Root != "" && DirExist(Root)
			DirDelete(Root, true)
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally {
		Critical("On")
		try {
			if Claimed {
				_ConfigDir := Saved.ConfigDir, _LLM_AgentConnector_Tools := Saved.Tools
				_LLM_AgentConnector_ListFn := Saved.List, _LLM_AgentConnector_EnsureDirFn := Saved.Ensure
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Item in SavedExtras
					%Name% := Item.Present ? Item.Value : unset
			}
		} finally Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _ATTL_Mode in ["boundary", "long-gap", "force"]
	Test("LLM agent tools: " . _ATTL_Mode . " respects native64 cache age (agent-tools-native64-ttl-owner)",
		_ATTL_Case.Bind(_ATTL_Mode))
