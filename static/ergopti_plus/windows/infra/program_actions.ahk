; infra/program_actions.ahk

; User executable/argv actions own a native tree until strict terminal acknowledgement.
global _UserProgramEntries := Map()
global _UserProgramGeneration := 0
global _UserProgramPaused := false
global _UserProgramAcquiring := 0

ProgramActions_Available() {
	return IsSet(ShellRunner_SpawnTreeOwned) && IsSet(FSReadUtf8Exact)
		&& IsSet(TOML_ParseDocument) && IsSet(ProgramParameterParse)
}

ProgramActions_BindingSupported(Binding) {
	return (Binding is String) && RegExMatch(Binding, "^(gesture|keyboard|script|tap_key)__.+$")
}

_ProgramActions_BindingAction(Binding, &Section := "", &Slot := "") {
	global GestureAssignments, KeyboardShortcutAssignments, ScriptShortcutAssignments, TapKeyAssignments
	if !RegExMatch(Binding, "^(gesture|keyboard|script|tap_key)__(.+)$", &Parts)
		return ""
	Slot := Parts[2]
	switch Parts[1] {
		case "gesture":
			Section := "gestures"
			return IsSet(GestureAssignments) && (GestureAssignments is Map) ? GestureAssignments.Get(Slot, "") : ""
		case "keyboard":
			Section := "keyboard"
			return IsSet(KeyboardShortcutAssignments) && (KeyboardShortcutAssignments is Map) ? KeyboardShortcutAssignments.Get(Slot, "") : ""
		case "script":
			Section := "script_control"
			return IsSet(ScriptShortcutAssignments) && (ScriptShortcutAssignments is Map) ? ScriptShortcutAssignments.Get(Slot, "") : ""
		case "tap_key":
			Section := "tap_keys"
			return IsSet(TapKeyAssignments) && (TapKeyAssignments is Map) ? TapKeyAssignments.Get(Slot, "") : ""
	}
	return ""
}

_ProgramActions_Snapshot(Binding) {
	global ConfigurationFile, _UserProgramGeneration, _UserProgramPaused
	if !ProgramActions_Available() || !ProgramActions_BindingSupported(Binding)
		|| _UserProgramPaused || A_IsSuspended || ConfigWriteLeaseBusy() || !(ConfigurationFile is String)
		return false
	Scalar := GestureGetActionParameter(Binding, "run_program")
	Program := ProgramParameterParse(Scalar)
	if !(Program is Map) || !(_ProgramActions_BindingAction(Binding, &Section, &Slot) == "run_program")
		return false
	Content := FSReadUtf8Exact(ConfigurationFile)
	Document := TOML_ParseDocument(Content)
	Parameters := Document.Get("action_parameters", 0)
	Actions := Section == "gestures" ? Document.Get("gestures", 0) : Document.Get("shortcuts", Map()).Get(Section, 0)
	if !(Parameters is Map) || !(Actions is Map)
		|| !(Parameters.Get(GestureActionParameterKey(Binding, "run_program"), "") == Scalar)
		|| !(Actions.Get(Slot, "") == "run_program")
		return false
	return Map("binding", Binding, "scalar", Scalar, "source", Content,
		"path", ConfigurationFile, "generation", _UserProgramGeneration, "program", Program)
}

_ProgramActions_Admitted(Snapshot) {
	global ConfigurationFile, _UserProgramGeneration, _UserProgramPaused
	try {
		return !_UserProgramPaused && !A_IsSuspended && !ConfigWriteLeaseBusy()
			&& _UserProgramGeneration == Snapshot["generation"]
			&& ConfigurationFile == Snapshot["path"]
			&& GestureGetActionParameter(Snapshot["binding"], "run_program") == Snapshot["scalar"]
			&& _ProgramActions_BindingAction(Snapshot["binding"]) == "run_program"
			&& FSReadUtf8Exact(Snapshot["path"]) == Snapshot["source"]
	} catch {
		return false
	}
}

_ProgramActions_BeforeAdopt(Snapshot, *) {
	if !_ProgramActions_Admitted(Snapshot)
		throw Error("User program admission changed")
}

_ProgramActions_Done(Entry, ExitCode := unset, *) {
	global _UserProgramEntries, _UserProgramGeneration, _UserProgramPaused
	try {
		if _UserProgramEntries.Get(Entry["binding"], 0) != Entry
			return true
		Admitted := !Entry["cancelled"] && _ProgramActions_Admitted(Entry["snapshot"])
		; Canonical-source reads may pump messages. Recheck the current owner,
		; cancellation and pause after that read before reporting any completion.
		if _UserProgramEntries.Get(Entry["binding"], 0) != Entry
			return true
		if Admitted && !Entry["cancelled"] && !_UserProgramPaused && !A_IsSuspended
				&& _UserProgramGeneration == Entry["snapshot"]["generation"] {
			; Only a closed unsigned native status is diagnostic data. Executable,
			; argv, output and arbitrary malformed receipts remain private.
			if !IsSet(ExitCode) || !(ExitCode is Integer) || ExitCode < 0 || ExitCode > 0xFFFFFFFF {
				try LoggerError("UserProgram", "User program returned an invalid exit status.")
			} else if ExitCode != 0 {
				try LoggerError("UserProgram", "User program exited with status {1}.", ExitCode)
			}
		}
		if _UserProgramEntries.Get(Entry["binding"], 0) == Entry
			_UserProgramEntries.Delete(Entry["binding"])
	} catch {
		return false
	}
	return true
}

_ProgramActions_Retire(Entry) {
	global _UserProgramEntries
	Entry["cancelled"] := true
	try Receipt := Entry["handle"].terminate()
	catch
		return false
	if !(Receipt is Integer) || Receipt != 1
		return false
	if _UserProgramEntries.Get(Entry["binding"], 0) == Entry
		_UserProgramEntries.Delete(Entry["binding"])
	return true
}

ProgramActions_Run(Binding) {
	global _UserProgramEntries, _UserProgramAcquiring, _UserProgramGeneration
	PreviousCritical := Critical("On")
	try {
		if _UserProgramEntries.Count != 0 || IsObject(_UserProgramAcquiring)
			return false
		Acquisition := Map("generation", _UserProgramGeneration)
		_UserProgramAcquiring := Acquisition
	} finally Critical(PreviousCritical)
	try {
		Snapshot := _ProgramActions_Snapshot(Binding)
		if !(Snapshot is Map) || Acquisition["generation"] != _UserProgramGeneration
			return false
		Entry := Map("binding", Binding, "snapshot", Snapshot, "cancelled", false, "started", A_TickCount)
		Program := Snapshot["program"]
		Handle := ShellRunner_SpawnTreeOwned(Program["executable"], Program["arguments"],
			_ProgramActions_Done.Bind(Entry), , _ProgramActions_BeforeAdopt.Bind(Snapshot), 0, false, true)
		Entry["handle"] := Handle
		_UserProgramEntries[Binding] := Entry
		SetTimer(ProgramActions_Poll, TimingsGet("gestures", "aux_shell_cleanup_retry_ms"))
		try Started := Handle.start()
		catch
			Started := false
		if !(Started is Integer) || Started != 1 || !_ProgramActions_Admitted(Snapshot) {
			_ProgramActions_Retire(Entry)
			return false
		}
		return true
	} catch {
		if IsSet(Entry) && (Entry is Map) && Entry.Has("handle")
			_ProgramActions_Retire(Entry)
		return false
	} finally {
		PreviousCritical := Critical("On")
		try {
			if _UserProgramAcquiring == Acquisition
				_UserProgramAcquiring := 0
		} finally Critical(PreviousCritical)
	}
}

ProgramActions_Poll(*) {
	global _UserProgramEntries
	for _, Entry in _UserProgramEntries.Clone() {
		if Entry["cancelled"] || !_ProgramActions_Admitted(Entry["snapshot"])
			|| A_TickCount - Entry["started"] >= TimingsGet("gestures", "aux_shell_timeout_ms")
			_ProgramActions_Retire(Entry)
	}
	if _UserProgramEntries.Count == 0
		SetTimer(ProgramActions_Poll, 0)
}

ProgramActions_Stop(Pause := false) {
	global _UserProgramEntries, _UserProgramGeneration, _UserProgramPaused, _UserProgramAcquiring
	_UserProgramGeneration += 1
	_UserProgramPaused := Pause == true
	Receipt := !IsObject(_UserProgramAcquiring)
	for _, Entry in _UserProgramEntries.Clone()
		if !_ProgramActions_Retire(Entry)
			Receipt := false
	return Receipt
}
