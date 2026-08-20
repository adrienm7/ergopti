; tests/unit/test_editor_global_barrier_behavior_20260813.ahk

; ==============================================================================
; MODULE: Editor Global Configuration Barrier Behaviour
; DESCRIPTION:
; Drives the real config.toml editor callbacks through injected durable and
; native seams. The regression proves a sibling terminal transition refuses
; before writer/candidate/native work, writer failures publish nothing, and a
; strict durable success publishes RAM before invoking post-commit UI actions.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../ui/editors.ahk

global _EGB20260813_WriteCalls := 0
global _EGB20260813_NotifyCalls := 0
global _EGB20260813_ReloadCalls := 0
global _EGB20260813_RebuildCalls := 0
global _EGB20260813_WriteResult := true
global _EGB20260813_Observed := []
global _EGB20260813_WriterCritical := []
global _EGB20260813_NotifyCritical := []
global _EGB20260813_ReloadCritical := []
global _EGB20260813_RebuildCritical := []
global _EGB20260813_MagicGui := false
global _EGB20260813_LinkGui := false

class _EGB20260813_Gui {
	Destroyed := 0
	DestroyCritical := -1

	Destroy() {
		this.Destroyed += 1
		this.DestroyCritical := A_IsCritical
	}
}

class _EGB20260813_ThrowingGui {
	Destroy() {
		throw Error("injected editor destroy failure")
	}
}

_EGB20260813_Reset(WriteResult := true) {
	global _EGB20260813_WriteCalls, _EGB20260813_NotifyCalls
	global _EGB20260813_ReloadCalls, _EGB20260813_RebuildCalls
	global _EGB20260813_WriteResult, _EGB20260813_Observed
	global _EGB20260813_WriterCritical, _EGB20260813_NotifyCritical
	global _EGB20260813_ReloadCritical, _EGB20260813_RebuildCritical
	global _EGB20260813_MagicGui, _EGB20260813_LinkGui
	_EGB20260813_WriteCalls := 0
	_EGB20260813_NotifyCalls := 0
	_EGB20260813_ReloadCalls := 0
	_EGB20260813_RebuildCalls := 0
	_EGB20260813_WriteResult := WriteResult
	_EGB20260813_Observed := []
	_EGB20260813_WriterCritical := []
	_EGB20260813_NotifyCritical := []
	_EGB20260813_ReloadCritical := []
	_EGB20260813_RebuildCritical := []
	_EGB20260813_MagicGui := _EGB20260813_Gui()
	_EGB20260813_LinkGui := _EGB20260813_Gui()
}

_EGB20260813_Writer(Path, Updates) {
	global _EGB20260813_WriteCalls, _EGB20260813_WriteResult
	global _EGB20260813_ReloadCalls, _EGB20260813_RebuildCalls
	global _EGB20260813_Observed, _EGB20260813_MagicGui, _EGB20260813_LinkGui
	global _EGB20260813_WriterCritical
	global ScriptInformation, Features, HSE_RepeatEnabled
	_EGB20260813_WriteCalls += 1
	_EGB20260813_WriterCritical.Push(A_IsCritical)
	Update := Updates[1]
	_EGB20260813_Observed.Push({
		section: Update.Section,
		key: Update.Key,
		magic: ScriptInformation["MagicKey"],
		trigger: Features["hotstrings"].Get("trigger_char", ""),
		link: Features["shortcuts"]["gpt"]["link"],
		repeat: HSE_RepeatEnabled,
		repeat_feature: Features["hotstrings"].Get("repeat_key_enabled", false),
		reloads: _EGB20260813_ReloadCalls,
		rebuilds: _EGB20260813_RebuildCalls,
		magic_destroyed: _EGB20260813_MagicGui.Destroyed,
		link_destroyed: _EGB20260813_LinkGui.Destroyed,
	})
	return _EGB20260813_WriteResult
}

_EGB20260813_Notify(Message, Options) {
	global _EGB20260813_NotifyCalls, _EGB20260813_NotifyCritical
	_EGB20260813_NotifyCalls += 1
	_EGB20260813_NotifyCritical.Push(A_IsCritical)
}

_EGB20260813_Reload() {
	global _EGB20260813_ReloadCalls, _EGB20260813_ReloadCritical
	_EGB20260813_ReloadCalls += 1
	_EGB20260813_ReloadCritical.Push(A_IsCritical)
	return 1
}

_EGB20260813_Rebuild() {
	global _EGB20260813_RebuildCalls, _EGB20260813_RebuildCritical
	_EGB20260813_RebuildCalls += 1
	_EGB20260813_RebuildCritical.Push(A_IsCritical)
	return 1
}

_EGB20260813_RefusingReload() {
	global _EGB20260813_ReloadCalls
	_EGB20260813_ReloadCalls += 1
	return false
}

_EGB20260813_ThrowingReload() {
	global _EGB20260813_ReloadCalls
	_EGB20260813_ReloadCalls += 1
	throw Error("injected reload failure")
}

_EGB20260813_RefusingRebuild() {
	global _EGB20260813_RebuildCalls
	_EGB20260813_RebuildCalls += 1
	return false
}

_EGB20260813_ThrowingRebuild() {
	global _EGB20260813_RebuildCalls
	_EGB20260813_RebuildCalls += 1
	throw Error("injected tray rebuild failure")
}

_EGB20260813_SaveState() {
	global ConfigurationFile, ScriptInformation, Features, HSE_RepeatEnabled
	Hotstrings := Features["hotstrings"]
	return {
		path: ConfigurationFile,
		magic: ScriptInformation["MagicKey"],
		trigger_had: Hotstrings.Has("trigger_char"),
		trigger: Hotstrings.Get("trigger_char", ""),
		link: Features["shortcuts"]["gpt"]["link"],
		repeat: HSE_RepeatEnabled,
		repeat_had: Hotstrings.Has("repeat_key_enabled"),
		repeat_feature: Hotstrings.Get("repeat_key_enabled", false),
	}
}

_EGB20260813_RestoreState(Saved) {
	global ConfigurationFile, ScriptInformation, Features, HSE_RepeatEnabled
	ConfigurationFile := Saved.path
	ScriptInformation["MagicKey"] := Saved.magic
	Hotstrings := Features["hotstrings"]
	if Saved.trigger_had
		Hotstrings["trigger_char"] := Saved.trigger
	else if Hotstrings.Has("trigger_char")
		Hotstrings.Delete("trigger_char")
	Features["shortcuts"]["gpt"]["link"] := Saved.link
	HSE_RepeatEnabled := Saved.repeat
	if Saved.repeat_had
		Hotstrings["repeat_key_enabled"] := Saved.repeat_feature
	else if Hotstrings.Has("repeat_key_enabled")
		Hotstrings.Delete("repeat_key_enabled")
}

_EGB20260813_SeedFixture() {
	global ConfigurationFile, ScriptInformation, Features, HSE_RepeatEnabled
	ConfigurationFile := A_Temp . "\ergopti_editor_global_barrier.toml"
	ScriptInformation["MagicKey"] := "★"
	Features["hotstrings"]["trigger_char"] := "★"
	Features["shortcuts"]["gpt"]["link"] := "https://old.example/"
	HSE_RepeatEnabled := false
	Features["hotstrings"]["repeat_key_enabled"] := false
}

_EGB20260813_AssertFixtureUnchanged() {
	global ScriptInformation, Features, HSE_RepeatEnabled
	global _EGB20260813_ReloadCalls, _EGB20260813_RebuildCalls
	global _EGB20260813_MagicGui, _EGB20260813_LinkGui
	AssertEqual("★", ScriptInformation["MagicKey"])
	AssertEqual("★", Features["hotstrings"]["trigger_char"])
	AssertEqual("https://old.example/", Features["shortcuts"]["gpt"]["link"])
	AssertFalse(HSE_RepeatEnabled)
	AssertFalse(Features["hotstrings"]["repeat_key_enabled"])
	AssertEqual(0, _EGB20260813_ReloadCalls)
	AssertEqual(0, _EGB20260813_RebuildCalls)
	AssertEqual(0, _EGB20260813_MagicGui.Destroyed)
	AssertEqual(0, _EGB20260813_LinkGui.Destroyed)
}





; ================================================
; ================================================
; ======= 1/ Refusal before candidate work =======
; ================================================
; ================================================

_EGB20260813_UnrelatedTerminalRefusesAllEditors() {
	global ConfigurationFile, _EGB20260813_WriteCalls, _EGB20260813_NotifyCalls
	global _EGB20260813_MagicGui, _EGB20260813_LinkGui
	Saved := _EGB20260813_SaveState()
	Barrier := false
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset()
		Barrier := _ConfigWriteTerminalTryAcquire(
			A_Temp . "\ergopti_editor_unrelated_terminal.toml")
		Assert(Barrier is Object)
		AssertFalse(ModifyMagicKey(_EGB20260813_MagicGui, "#",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertFalse(ModifyLink(_EGB20260813_LinkGui, "https://new.example/",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertFalse(ToggleRepeatKeyEnabled(
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Rebuild))
		AssertEqual(0, _EGB20260813_WriteCalls,
			"a sibling terminal transition must refuse before every editor writer")
		AssertEqual(3, _EGB20260813_NotifyCalls)
		_EGB20260813_AssertFixtureUnchanged()
	} finally {
		if Barrier is Object
			_ConfigWriteTerminalRelease(Barrier)
		_EGB20260813_RestoreState(Saved)
	}
}
Test("editor-global-barrier-20260813: unrelated terminal owner refuses all editors",
	_EGB20260813_UnrelatedTerminalRefusesAllEditors)

_EGB20260813_WriterFailurePublishesNoState() {
	global _EGB20260813_WriteCalls, _EGB20260813_NotifyCalls
	global _EGB20260813_WriteResult, _EGB20260813_MagicGui, _EGB20260813_LinkGui
	Saved := _EGB20260813_SaveState()
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset(false)
		AssertFalse(ModifyMagicKey(_EGB20260813_MagicGui, "#",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		_EGB20260813_WriteResult := "1"
		AssertFalse(ModifyLink(_EGB20260813_LinkGui, "https://new.example/",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload),
			"a string success lookalike must not publish editor state")
		_EGB20260813_WriteResult := false
		AssertFalse(ToggleRepeatKeyEnabled(
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Rebuild))
		AssertEqual(3, _EGB20260813_WriteCalls)
		AssertEqual(3, _EGB20260813_NotifyCalls)
		_EGB20260813_AssertFixtureUnchanged()
	} finally _EGB20260813_RestoreState(Saved)
}
Test("editor-global-barrier-20260813: writer failure leaves RAM and native seams unchanged",
	_EGB20260813_WriterFailurePublishesNoState)

_EGB20260813_ReloadFailuresStayContainedAndKeepEditorsOpen() {
	global ScriptInformation, Features
	global _EGB20260813_WriteCalls, _EGB20260813_ReloadCalls
	global _EGB20260813_MagicGui, _EGB20260813_LinkGui
	Saved := _EGB20260813_SaveState()
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset(true)
		AssertFalse(ModifyMagicKey(_EGB20260813_MagicGui, "#",
			_EGB20260813_Writer, _EGB20260813_Notify,
			_EGB20260813_RefusingReload))
		AssertEqual(0, _EGB20260813_MagicGui.Destroyed,
			"a refused reload must leave the magic-key editor available")
		AssertFalse(ModifyLink(_EGB20260813_LinkGui, "https://new.example/",
			_EGB20260813_Writer, _EGB20260813_Notify,
			_EGB20260813_ThrowingReload),
			"a throwing reload must be contained by the editor entry point")
		AssertEqual(0, _EGB20260813_LinkGui.Destroyed,
			"a throwing reload must leave the link editor available")
		AssertEqual(2, _EGB20260813_WriteCalls)
		AssertEqual(2, _EGB20260813_ReloadCalls)
		AssertEqual("#", ScriptInformation["MagicKey"],
			"post-commit refusal cannot erase the already-durable publication")
		AssertEqual("https://new.example/", Features["shortcuts"]["gpt"]["link"])
	} finally _EGB20260813_RestoreState(Saved)
}
Test("editor-global-barrier-20260813: reload false and throw stay contained with editor open",
	_EGB20260813_ReloadFailuresStayContainedAndKeepEditorsOpen)

_EGB20260813_RebuildFailuresStayContained() {
	global Features, HSE_RepeatEnabled
	global _EGB20260813_WriteCalls, _EGB20260813_RebuildCalls
	Saved := _EGB20260813_SaveState()
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset(true)
		AssertFalse(ToggleRepeatKeyEnabled(
			_EGB20260813_Writer, _EGB20260813_Notify,
			_EGB20260813_RefusingRebuild))
		AssertTrue(HSE_RepeatEnabled,
			"a refused rebuild follows an already-durable repeat toggle")
		AssertFalse(ToggleRepeatKeyEnabled(
			_EGB20260813_Writer, _EGB20260813_Notify,
			_EGB20260813_ThrowingRebuild),
			"a throwing rebuild must not escape the tray callback")
		AssertFalse(HSE_RepeatEnabled)
		AssertFalse(Features["hotstrings"]["repeat_key_enabled"])
		AssertEqual(2, _EGB20260813_WriteCalls)
		AssertEqual(2, _EGB20260813_RebuildCalls)
	} finally _EGB20260813_RestoreState(Saved)
}
Test("editor-global-barrier-20260813: rebuild false and throw stay contained",
	_EGB20260813_RebuildFailuresStayContained)

_EGB20260813_DestroyFailureStaysContained() {
	global ScriptInformation, _EGB20260813_ReloadCalls
	Saved := _EGB20260813_SaveState()
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset(true)
		AssertFalse(ModifyMagicKey(_EGB20260813_ThrowingGui(), "#",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload),
			"a native editor-destroy failure must not escape the InputHook handler")
		AssertEqual(1, _EGB20260813_ReloadCalls)
		AssertEqual("#", ScriptInformation["MagicKey"])
	} finally _EGB20260813_RestoreState(Saved)
}
Test("editor-global-barrier-20260813: editor destroy throw stays contained",
	_EGB20260813_DestroyFailureStaysContained)





; ============================================
; ============================================
; ======= 2/ Durable publication order =======
; ============================================
; ============================================

_EGB20260813_DurableSuccessPublishesAfterWriter() {
	global ScriptInformation, Features, HSE_RepeatEnabled
	global _EGB20260813_WriteCalls, _EGB20260813_Observed
	global _EGB20260813_ReloadCalls, _EGB20260813_RebuildCalls
	global _EGB20260813_MagicGui, _EGB20260813_LinkGui
	Saved := _EGB20260813_SaveState()
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset(true)
		AssertTrue(ModifyMagicKey(_EGB20260813_MagicGui, "#",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertTrue(ModifyLink(_EGB20260813_LinkGui, "https://new.example/",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertTrue(ToggleRepeatKeyEnabled(
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Rebuild))
		AssertEqual(3, _EGB20260813_WriteCalls)
		AssertEqual("★", _EGB20260813_Observed[1].magic,
			"the magic key must remain detached while its durable writer runs")
		AssertEqual("★", _EGB20260813_Observed[1].trigger)
		AssertEqual(0, _EGB20260813_Observed[1].magic_destroyed)
		AssertEqual(0, _EGB20260813_Observed[1].reloads)
		AssertEqual("https://old.example/", _EGB20260813_Observed[2].link,
			"the link must remain detached while its durable writer runs")
		AssertEqual(0, _EGB20260813_Observed[2].link_destroyed)
		AssertEqual(1, _EGB20260813_Observed[2].reloads)
		AssertFalse(_EGB20260813_Observed[3].repeat,
			"the repeat candidate must remain detached while its writer runs")
		AssertFalse(_EGB20260813_Observed[3].repeat_feature)
		AssertEqual(0, _EGB20260813_Observed[3].rebuilds)
		AssertEqual("#", ScriptInformation["MagicKey"])
		AssertEqual("#", Features["hotstrings"]["trigger_char"])
		AssertEqual("https://new.example/", Features["shortcuts"]["gpt"]["link"])
		AssertTrue(HSE_RepeatEnabled)
		AssertTrue(Features["hotstrings"]["repeat_key_enabled"])
		AssertEqual(2, _EGB20260813_ReloadCalls)
		AssertEqual(1, _EGB20260813_RebuildCalls)
		AssertEqual(1, _EGB20260813_MagicGui.Destroyed)
		AssertEqual(1, _EGB20260813_LinkGui.Destroyed)
	} finally _EGB20260813_RestoreState(Saved)
}
Test("editor-global-barrier-20260813: durable success publishes before native follow-up",
	_EGB20260813_DurableSuccessPublishesAfterWriter)

_EGB20260813_InheritedCriticalStopsAtEditorBoundary() {
	global _EGB20260813_WriterCritical, _EGB20260813_NotifyCritical
	global _EGB20260813_ReloadCritical, _EGB20260813_RebuildCritical
	global _EGB20260813_MagicGui, _EGB20260813_LinkGui
	Saved := _EGB20260813_SaveState()
	SavedCritical := A_IsCritical
	try {
		_EGB20260813_SeedFixture()
		_EGB20260813_Reset(true)
		Critical("On")
		AssertTrue(ModifyMagicKey(_EGB20260813_MagicGui, "#",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertTrue(A_IsCritical,
			"ModifyMagicKey must restore its caller's inherited Critical state")
		AssertTrue(ModifyLink(_EGB20260813_LinkGui, "https://new.example/",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertTrue(A_IsCritical,
			"ModifyLink must restore its caller's inherited Critical state")
		AssertTrue(ToggleRepeatKeyEnabled(_EGB20260813_Writer,
			_EGB20260813_Notify, _EGB20260813_Rebuild))
		AssertTrue(A_IsCritical,
			"ToggleRepeatKeyEnabled must restore its caller's Critical state")
		Critical("Off")

		AssertEqual(3, _EGB20260813_WriterCritical.Length)
		for State in _EGB20260813_WriterCritical
			AssertEqual(0, State,
				"editor writers must never inherit a caller's Critical state")
		AssertEqual(2, _EGB20260813_ReloadCritical.Length)
		for State in _EGB20260813_ReloadCritical
			AssertEqual(0, State,
				"post-commit editor reloads must run interruptibly")
		AssertEqual(1, _EGB20260813_RebuildCritical.Length)
		AssertEqual(0, _EGB20260813_RebuildCritical[1],
			"the post-commit tray rebuild must run interruptibly")
		AssertEqual(0, _EGB20260813_MagicGui.DestroyCritical)
		AssertEqual(0, _EGB20260813_LinkGui.DestroyCritical)

		_EGB20260813_Reset(false)
		Critical("On")
		AssertFalse(ModifyMagicKey(_EGB20260813_MagicGui, "$",
			_EGB20260813_Writer, _EGB20260813_Notify, _EGB20260813_Reload))
		AssertTrue(A_IsCritical,
			"a refused editor commit must also restore inherited Critical")
		Critical("Off")
		AssertEqual(1, _EGB20260813_NotifyCritical.Length)
		AssertEqual(0, _EGB20260813_NotifyCritical[1],
			"editor failure notification must run interruptibly")
	} finally {
		Critical(SavedCritical)
		_EGB20260813_RestoreState(Saved)
	}
}
Test("editor-global-barrier-20260813: user actions defuse inherited Critical "
	. "through post-commit UI (editor-postcommit-inherited-critical)",
	_EGB20260813_InheritedCriticalStopsAtEditorBoundary)
