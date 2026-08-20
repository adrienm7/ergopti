; tests/meta/test_personal_shortcuts_atomic_bootstrap.ahk

; ==============================================================================
; MODULE: Personal Shortcuts Atomic Bootstrap Regression
; DESCRIPTION:
; A failed/truncated first-use write was swallowed, and both runtime entry points
; opened Notepad anyway. The generator also deleted the live forwarding stub
; before appending its replacement, exposing a missing or partial #Include to a
; concurrent Reload. A first hardening pass still omitted the process-wide
; configuration lease, so a path relocation could begin while that verified
; stage was pending. Pin the whole cause: global admission, exact-owner
; revalidation, verified atomic publication, explicit status at every caller,
; and fail-fast boot when the include chain is unsafe.
; ==============================================================================

#Requires AutoHotkey v2.0

_PSAB_GeneratorPublishesVerifiedStages() {
	Ensure := _StripFullLineComments(_DriverFuncBody("EnsurePersonalShortcutsFile"))
	Publish := _StripFullLineComments(_DriverFuncBody("_PersonalShortcutsPublishFile"))
	Assert(Ensure != "" and Publish != "",
		"personal-shortcuts generator and publication helper must remain source-visible")
	Assert(InStr(Ensure, 'Critical("Off")') > 0,
		"the generator must defuse inherited Critical before directory and file I/O")
	Assert(InStr(Ensure, "_PersonalShortcutsPublishFile(Path,") > 0
		and InStr(Ensure, "WriterFn, ReplaceFn, ReadFn, true") > 0,
		"the user-owned source must use create-only atomic publication")
	Assert(InStr(Ensure, "_PersonalShortcutsPublishFile(StubPath,") > 0,
		"the forwarding stub must use the same verified publication primitive")
	Assert(InStr(Ensure, "FileAppend(") == 0 and InStr(Ensure, "FileDelete(") == 0,
		"the generator must never delete/truncate a live AHK source before replacement")

	Write := InStr(Publish, "FSWriteDurable(StagePath, Content)")
	Read := InStr(Publish, "FSRead(StagePath)", true, Write)
	Verify := InStr(Publish, "Observed != Content", true, Read)
	Create := InStr(Publish, "FSAtomicMoveCreate(StagePath, Path)", true, Verify)
	Replace := InStr(Publish, "FSAtomicMoveReplace(StagePath, Path)", true, Verify)
	Assert(Write > 0 and Read > Write and Verify > Read
		and Create > Verify and Replace > Verify,
		"the full stage must be durable and byte-verified before an atomic create/replace")
	Assert(InStr(Publish, "A_ScriptHwnd") > 0
		and InStr(Publish, "StageSequence") > 0,
		"concurrent processes/calls must not share one clobberable .stage pathname")
}
Test("personal shortcuts: generated AHK files publish atomically "
	. "(personal-shortcuts-delete-append-and-silent-failure)",
	_PSAB_GeneratorPublishesVerifiedStages)

_PSAB_PublicationOwnsTheConfigBoundary() {
	Publish := _StripFullLineComments(
		_DriverFuncBody("_PersonalShortcutsPublishFile"))
	Assert(Publish != "",
		"the personal-shortcuts publication helper must remain source-visible")
	Acquire := InStr(Publish, "_ConfigWriteLeaseTryAcquire(")
	Write := InStr(Publish, "FSWriteDurable(StagePath, Content)", true, Acquire)
	Verify := InStr(Publish, "Observed != Content", true, Write)
	Authorize := InStr(Publish,
		"_ConfigWriteLeaseOwns(OwnerToken, Path)", true, Verify)
	Replace := InStr(Publish,
		"FSAtomicMoveReplace(StagePath, Path)", true, Authorize)
	Release := InStr(Publish,
		"_ConfigWriteLeaseRelease(OwnerToken)", true, Replace)
	Assert(Acquire > 0 and Write > Acquire and Verify > Write
		and Authorize > Verify and Replace > Authorize and Release > Replace,
		"every generated AHK writer must retain one exact config owner from before staging through final replacement and release it afterward")
	Assert(InStr(Publish, "finally", true, Replace) > Replace,
		"exceptions and early refusals must release the exact personal-shortcuts owner")
	Assert(InStr(Publish, 'Critical("On")') == 0,
		"the lease, never Critical, must span personal-shortcuts filesystem I/O")
}
Test("personal shortcuts: atomic publisher participates in the global config barrier "
	. "(personal-shortcuts-global-barrier-sibling-omission)",
	_PSAB_PublicationOwnsTheConfigBoundary)

_PSAB_EveryCallerConsumesFailure() {
	Menu := _StripFullLineComments(_DriverFuncBody("OpenPersonalShortcuts"))
	Gesture := _StripFullLineComments(_DriverFuncBody("GestureEditPersonalShortcuts"))
	for Spec in [
		{ body: Menu, name: "OpenPersonalShortcuts" },
		{ body: Gesture, name: "GestureEditPersonalShortcuts" }
	] {
		Gate := InStr(Spec.body, "if !EnsurePersonalShortcutsFile(Path, false)")
		RunPos := InStr(Spec.body, "Run(", true, Gate)
		Assert(Gate > 0 and RunPos > Gate,
			Spec.name . " must refuse the editor launch when bootstrap failed")
		Assert(InStr(Spec.body, "ConfigReportPersistenceFailure(", true, Gate) > Gate,
			Spec.name . " must surface the refused output instead of returning silently")
	}

	Src := _DriverSourceNoComments()
	BootGate := InStr(Src,
		'if !EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"])', true)
	BootAbort := InStr(Src, "ExitApp(1)", true, BootGate)
	PersonalInclude := InStr(Src,
		"#Include *i _generated/personal_shortcuts.ahk", true, BootGate)
	Assert(BootGate > 0 and BootAbort > BootGate
		and PersonalInclude > BootAbort,
		"boot must abort before reaching the personal #Include when its safe chain is unavailable")
}
Test("personal shortcuts: boot/menu/gesture consume generator failure "
	. "(personal-shortcuts-delete-append-and-silent-failure)",
	_PSAB_EveryCallerConsumesFailure)
