; tests/meta/test_personal_info_save_surfaces_failure.ahk

; ==============================================================================
; MODULE: Regression — a failed personal-information write must not be followed
;         by a Reload (personal-info-save-surfaces-failure)
; DESCRIPTION:
; _PiEdWeb_Save wrote the edited values into the in-memory PersonalInformation
; map, called WritePersonalInfoToml(...), THREW THE RESULT AWAY, logged "Saved
; personal information — reloading…" and called Reload(). On a read-only or
; locked personal_info.toml (mid-sync cloud folder, AV scanner, copied read-only
; profile) the writer catches the OSError and returns False — and the Reload then
; re-read the unchanged file, so the user's edits disappeared while every
; user-visible signal reported success.
;
; ROOT CAUSE ENCODED: the F-29 hardening — "a failed config write must be
; surfaced, and must not be followed by a Reload() that hides it" — was applied
; to _PathsEdWeb_Save and the structurally identical sibling was never triaged.
; Making the WRITER log was only half of it: a caller that ignores the result
; turns a reported failure back into a silent one.
;
; SCOPE: source-level — the personal-information editor creates a WebView2 host
; at open time and is outside the headless include graph.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Every caller branches on the transaction result =======
; ==================================================================
; ==================================================================

_PISF_SaveBranchesBeforeReload() {
	for FunctionName in ["_PiEdWeb_Save", "ProcessUserInput"] {
		Body := _DriverFuncBody(FunctionName)
		Assert(Body != "", FunctionName . " must exist in the driver source")
		Assert(InStr(Body, "InheritedCritical := A_IsCritical") > 0
			&& InStr(Body, 'Critical("Off")') > 0,
			FunctionName . " must defuse caller Critical before persistence, feedback and reload")

		GuardPos := InStr(Body, "if !PersonalInfoCommitValues")
		Assert(GuardPos > 0,
			FunctionName . " must branch on the shared admitted transaction — a direct writer call can publish RAM before durability and bypass the global terminal barrier")
		Assert(RegExMatch(Body,
			"PersonalInformation\s*\[[^\]]+\]\s*:=") == 0,
			FunctionName . " must never mutate PersonalInformation directly before the transaction commits")

		ReloadPos := InStr(Body, "_EditorReloadAfterCommit(")
		Assert(ReloadPos > 0,
			"prerequisite: " . FunctionName . " still reloads so the engine rebuilds its expansions")
		Assert(GuardPos < ReloadPos,
			"the persistence guard must precede reload in " . FunctionName)
		Assert(RegExMatch(Body,
			"if !PersonalInfoCommitValues[\s\S]{0,700}?return") > 0,
			FunctionName . " must return after a refused transaction")
		Assert(RegExMatch(Body,
			"if !PersonalInfoCommitValues[\s\S]{0,700}?LoggerError") > 0,
			FunctionName . " must log that the typed values remain unsaved")
		Assert(InStr(Body, "_PersonalInfoReportSaveFailure(") > 0,
			FunctionName . " must make the failure visible to the user")
	}
}
Test("meta personal-info-save: both editors use the admitted transaction and stop before reload",
	_PISF_SaveBranchesBeforeReload)





; ==================================================================
; ==================================================================
; ======= 2/ The writer really does report failure =================
; ==================================================================
; ==================================================================

; The branch above is only worth anything if the writer's contract holds: a
; boolean, false on failure, true on success. An implicit return would make the
; new guard fire on every successful save instead.
_PISF_WriterReportsBothOutcomes() {
	Body := _DriverFuncBody("WritePersonalInfoToml")
	Assert(Body != "", "WritePersonalInfoToml must exist in the driver source")
	Assert(RegExMatch(Body, "i)return\s+false") > 0,
		"WritePersonalInfoToml must return false when it refuses or fails, or its callers cannot branch on anything")
	Assert(RegExMatch(Body, "i)return\s+true") > 0,
		"WritePersonalInfoToml must return true on success — an implicit return is falsy in AHK v2, which would make a caller's `if !Write…` guard fire on every successful save")
}
Test("meta personal-info-save: the writer reports both outcomes explicitly",
	_PISF_WriterReportsBothOutcomes)

_PISF_TransactionOwnsBeforeCloneAndPublishesWithReplace() {
	Body := _DriverFuncBody("PersonalInfoCommitValues")
	Assert(Body != "", "PersonalInfoCommitValues must exist in the driver source")
	AcquirePos := InStr(Body, "_PersonalTomlWriteLeaseTryAcquire(")
	ClonePos := InStr(Body, "PersonalInformation.Clone(")
	WritePos := InStr(Body, "WritePersonalInfoToml(")
	PublishPos := InStr(Body, "_PersonalInfoPublishCandidate.Bind(")
	Assert(AcquirePos > 0 && ClonePos > AcquirePos,
		"the shared/global owner must be acquired before reading mutable live identity state")
	Assert(WritePos > ClonePos && PublishPos > WritePos,
		"one detached candidate must flow to atomic durability and its bound live publication")

	AtomicBody := _DriverFuncBody("_PersonalTomlWriteAtomic")
	Assert(AtomicBody != "", "the atomic personal TOML publisher must exist")
	ReplacePos := InStr(AtomicBody, "FSAtomicMoveReplace(StagePath, FilePath)")
	LivePos := InStr(AtomicBody, "PublishFn.Call(")
	Assert(ReplacePos > 0 && LivePos > ReplacePos,
		"live publication must follow the durable non-Critical replace")
	Assert(InStr(AtomicBody, "FSWriteDurable(StagePath, Content)") > 0,
		"the private stage must be flushed before the write-through atomic replace")
}
Test("meta personal-info-save: ownership precedes clone and replace precedes live publication",
	_PISF_TransactionOwnsBeforeCloneAndPublishesWithReplace)
