; tests/meta/test_editor_persist_before_publish.ahk

; ============================================================================== 
; MODULE: Editor persist-before-publish regression test
; DESCRIPTION:
; TOML writers return false on ordinary write failures. Editor callbacks must
; keep live state and reload/menu publication untouched until persistence wins.
; ============================================================================== 

#Requires AutoHotkey v2.0

_EPPP_EditorWritesBeforePublishingLiveState() {
	for _, Name in ["ModifyMagicKey", "ToggleRepeatKeyEnabled", "ModifyLink"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must remain present in ui/editors.ahk")
		Assert(InStr(Body, "_EditorWriteToml(") > 0,
			Name . " must enter through the shared editor transaction gateway")
	}
	Helper := _DriverFuncBody("_EditorWriteToml")
	Assert(Helper != "", "_EditorWriteToml must remain present")
	Assert(InStr(Helper, "ConfigCommitBuilt(") > 0,
		"editor persistence must claim the global barrier before candidate construction")
	Assert(InStr(Helper, "is Integer") > 0 && InStr(Helper, "MsgBox") > 0,
		"editor persistence must enforce strict success and surface failures")

	RepeatBody := _DriverFuncBody("ToggleRepeatKeyEnabled")
	RepeatBuilder := _DriverFuncBody("_EditorBuildRepeatKeyPlan")
	Assert(RepeatBuilder != "", "the repeat toggle must expose an owned candidate builder")
	Assert(InStr(RepeatBody, "HSE_RepeatEnabled") == 0,
		"the repeat callback must not read live state before barrier admission")
	Assert(InStr(RepeatBuilder, "Candidate := !HSE_RepeatEnabled") > 0,
		"the repeat candidate must be derived only inside ConfigCommitBuilt ownership")

	for _, Name in ["_EditorPublishMagicKey", "_EditorPublishRepeatKey", "_EditorPublishLink"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must remain an explicit post-durability publisher")
	}

	PostCommit := _DriverFuncBody("_EditorInvokePostCommitAction")
	Assert(PostCommit != "", "post-commit callbacks must share one guarded boundary")
	Assert(InStr(PostCommit, "catch as Err") > 0 && InStr(PostCommit, "LoggerError(") > 0,
		"post-commit callback exceptions must be caught and logged")
	Assert(InStr(PostCommit, "Result is Integer") > 0 && InStr(PostCommit, "Result == 1") > 0,
		"reload and rebuild callbacks must return strict Integer 1")
	Destroy := _DriverFuncBody("_EditorDestroyAfterCommit")
	Assert(Destroy != "" && InStr(Destroy, "catch as Err") > 0
		&& InStr(Destroy, "LoggerError(") > 0,
		"editor destruction must be guarded and logged")
	for _, Name in ["ModifyMagicKey", "ModifyLink"] {
		Body := _DriverFuncBody(Name)
		ReloadPos := InStr(Body, "_EditorReloadAfterCommit(")
		DestroyPos := InStr(Body, "_EditorDestroyAfterCommit(")
		Assert(ReloadPos > 0 && DestroyPos > ReloadPos,
			Name . " must leave its editor open until reload accepts")
	}
	Assert(InStr(_DriverFuncBody("ToggleRepeatKeyEnabled"),
		"_EditorRebuildAfterCommit(") > 0,
		"the repeat toggle must guard and validate its tray rebuild")
}

Test("ui editors: persistence succeeds before live state is published", _EPPP_EditorWritesBeforePublishingLiveState)
