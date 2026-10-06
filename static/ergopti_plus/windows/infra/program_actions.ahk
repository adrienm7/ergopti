; infra/program_actions.ahk

; User executable/argv actions own a native tree until strict terminal acknowledgement.
global _UserProgramEntries := Map()
global _UserProgramGeneration := 0
global _UserProgramPaused := false
global _UserProgramAcquiring := 0
global _UserProgramPollOwner := 0

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
		if _UserProgramEntries.Count == 0
			_ProgramActions_StopPoll()
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
	if _UserProgramEntries.Count == 0
		_ProgramActions_StopPoll()
	return true
}

; One exact bound callback owns timeout/source retirement between native completions.
; SetFn is an internal regression seam; production always uses TimerSetCallback.
_ProgramActions_EnsurePoll(SetFn := 0) {
	global _UserProgramPollOwner
	PreviousCritical := Critical("On")
	try {
		if !IsObject(_UserProgramPollOwner) {
			if !HasMethod(SetFn, "Call")
				SetFn := TimerSetCallback
			Owner := Map("active", false, "acquiring", false, "scheduled", false,
				"cancelled", false, "early", false, "set", SetFn)
			Owner["callback"] := ProgramActions_Poll.Bind(Owner)
			_UserProgramPollOwner := Owner
		} else
			Owner := _UserProgramPollOwner
		if Owner["cancelled"] || Owner["acquiring"]
			return false
		if Owner["active"]
			return true
		Owner["early"] := false
		Owner["acquiring"] := true
		Owner["scheduled"] := true
		Receipt := false
		try {
			RetryMs := TimingsGet("gestures", "aux_shell_cleanup_retry_ms")
			if !(RetryMs is Integer) || RetryMs <= 0
				throw ValueError("User program cleanup requires a positive integer period")
			Receipt := Owner["set"].Call(Owner["callback"], -RetryMs)
		}
		catch Any {
			Receipt := false
		} finally Owner["acquiring"] := false
		if !(Receipt is Integer) || Receipt != 1 || Owner["cancelled"] || Owner["early"]
			|| _UserProgramPollOwner != Owner {
			_ProgramActions_StopPoll(Owner)
			return false
		}
		return true
	} finally Critical(PreviousCritical)
}

_ProgramActions_StopPoll(ExpectedOwner := 0) {
	global _UserProgramPollOwner
	Owner := IsObject(ExpectedOwner) ? ExpectedOwner : _UserProgramPollOwner
	if !IsObject(Owner)
		return true
	Owner["cancelled"] := true
	try Receipt := Owner["set"].Call(Owner["callback"], 0)
	catch Any
		return false
	if !(Receipt is Integer) || Receipt != 1
		return false
	Owner["scheduled"] := false
	if Owner["active"] || Owner["acquiring"]
		return false
	if _UserProgramPollOwner != Owner
		return false
	_UserProgramPollOwner := 0
	return true
}

ProgramActions_Run(Binding) {
	global _UserProgramEntries, _UserProgramAcquiring, _UserProgramGeneration, _UserProgramPollOwner
	PreviousCritical := Critical("On")
	try {
		if _UserProgramEntries.Count != 0 || IsObject(_UserProgramAcquiring) || IsObject(_UserProgramPollOwner)
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
		if !_ProgramActions_EnsurePoll() {
			_ProgramActions_Retire(Entry)
			return false
		}
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

ProgramActions_Poll(Owner := 0, *) {
	global _UserProgramEntries, _UserProgramPollOwner, _UserProgramPaused
	if !IsObject(Owner)
		Owner := _UserProgramPollOwner
	if !IsObject(Owner) || _UserProgramPollOwner != Owner
		return false
	if Owner["acquiring"] {
		Owner["early"] := true
		return false
	}
	if Owner["active"]
		return false
	Owner["active"] := true
	Owner["scheduled"] := false
	try {
		for _, Entry in _UserProgramEntries.Clone() {
			if Owner["cancelled"] || Entry["cancelled"] || !_ProgramActions_Admitted(Entry["snapshot"])
				|| A_TickCount - Entry["started"] >= TimingsGet("gestures", "aux_shell_timeout_ms")
				_ProgramActions_Retire(Entry)
		}
	} finally {
		Owner["active"] := false
		if _UserProgramEntries.Count == 0
			_ProgramActions_StopPoll(Owner)
		else if !_ProgramActions_EnsurePoll()
			ProgramActions_Stop(_UserProgramPaused)
	}
	return true
}

ProgramActions_Stop(Pause := false) {
	global _UserProgramEntries, _UserProgramGeneration, _UserProgramPaused, _UserProgramAcquiring
	_UserProgramGeneration += 1
	_UserProgramPaused := Pause == true
	Receipt := !IsObject(_UserProgramAcquiring)
	for _, Entry in _UserProgramEntries.Clone()
		if !_ProgramActions_Retire(Entry)
			Receipt := false
	if _UserProgramEntries.Count != 0 {
		; A refused physical retirement still needs a callback to retry its exact handle.
		_ProgramActions_EnsurePoll()
		return false
	}
	if !_ProgramActions_StopPoll()
		Receipt := false
	return Receipt
}
