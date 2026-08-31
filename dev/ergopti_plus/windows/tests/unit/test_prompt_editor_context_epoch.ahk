; static/ergopti_plus/windows/tests/unit/test_prompt_editor_context_epoch.ahk

; ==============================================================================
; MODULE: Prompt Editor Context Epoch Regression Tests
; DESCRIPTION:
; Exercises the real prompt-editor scheduler boundary with deterministic hooks.
; A WebView message owns the immutable edit-id/epoch pair last painted into the
; page. Re-pointing the singleton editor must invalidate every queued save,
; cancel and init callback from the prior page, including a prior edit of the
; same profile id. This prevents AHK-29 from combining old form values with a
; newer mutable host identity and then closing the newer editor.
; ==============================================================================

#Requires AutoHotkey v2.0

global _PEC_Deferred     := []
global _PEC_Persisted    := []
global _PEC_Closed       := []
global _PEC_Evaluated    := []

class _PEC_WebMessageArgs {
	__New(Json) {
		this.Json := Json
	}

	TryGetWebMessageAsString() {
		return this.Json
	}
}

_PEC_Post(Json) {
	_PromptEdWeb_OnWebMessage(0, _PEC_WebMessageArgs(Json))
}

_PEC_SaveMessage(EditId, Epoch, Name, Batch, Prompt) {
	return '{"action":"save","edit_id":' . _PromptEdWeb_JsStr(EditId)
		. ',"epoch":' . Epoch
		. ',"name":' . _PromptEdWeb_JsStr(Name)
		. ',"batch":' . (Batch ? "true" : "false")
		. ',"prompt":' . _PromptEdWeb_JsStr(Prompt) . '}'
}

_PEC_SaveRawMessage(EditId, Epoch, NameLiteral, BatchLiteral, PromptLiteral) {
	return '{"action":"save","edit_id":' . _PromptEdWeb_JsStr(EditId)
		. ',"epoch":' . Epoch
		. ',"name":' . NameLiteral
		. ',"batch":' . BatchLiteral
		. ',"prompt":' . PromptLiteral . '}'
}

_PEC_CancelMessage(EditId, Epoch) {
	return '{"action":"cancel","edit_id":' . _PromptEdWeb_JsStr(EditId)
		. ',"epoch":' . Epoch . '}'
}

_PEC_Queue(Callback) {
	global _PEC_Deferred
	_PEC_Deferred.Push(Callback)
}

_PEC_Persist(EditId, Name, Batch, Prompt) {
	global _PEC_Persisted
	_PEC_Persisted.Push(Map(
		"edit_id", EditId,
		"name", Name,
		"batch", Batch,
		"prompt", Prompt
	))
	return true
}

_PEC_RefusePersist(EditId, Name, Batch, Prompt) {
	return false
}

_PEC_PersistThenRepoint(EditId, Name, Batch, Prompt) {
	_PEC_Persist(EditId, Name, Batch, Prompt)
	_PromptEdWeb_BeginContext(_PEC_Profile("profile_b", "Profile B"))
	return true
}

_PEC_Close(EditId, Epoch) {
	global _PEC_Closed
	_PEC_Closed.Push(Map("edit_id", EditId, "epoch", Epoch))
}

_PEC_Eval(Js) {
	global _PEC_Evaluated
	_PEC_Evaluated.Push(Js)
}

_PEC_Profile(Id, Label) {
	return Map(
		"id", Id,
		"label", Label,
		"system_single", "Prompt for " . Label,
		"batch", false
	)
}

_PEC_InstallFixture() {
	global _PromptEdWeb_DeferHook, _PromptEdWeb_PersistHook
	global _PromptEdWeb_CloseHook, _PromptEdWeb_EvalHook
	global _PromptEdWeb_IsEdit, _PromptEdWeb_EditId
	global _PromptEdWeb_InitName, _PromptEdWeb_InitPrompt, _PromptEdWeb_InitBatch
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_EpochSerial
	global _LLM_Menu
	global _PEC_Deferred, _PEC_Persisted, _PEC_Closed, _PEC_Evaluated

	Previous := Map(
		"defer_hook", _PromptEdWeb_DeferHook,
		"persist_hook", _PromptEdWeb_PersistHook,
		"close_hook", _PromptEdWeb_CloseHook,
		"eval_hook", _PromptEdWeb_EvalHook,
		"is_edit", _PromptEdWeb_IsEdit,
		"edit_id", _PromptEdWeb_EditId,
		"init_name", _PromptEdWeb_InitName,
		"init_prompt", _PromptEdWeb_InitPrompt,
		"init_batch", _PromptEdWeb_InitBatch,
		"context_epoch", _PromptEdWeb_ContextEpoch,
		"epoch_serial", _PromptEdWeb_EpochSerial,
		"llm_menu", _LLM_Menu
	)

	_PromptEdWeb_DeferHook   := _PEC_Queue
	_PromptEdWeb_PersistHook := _PEC_Persist
	_PromptEdWeb_CloseHook   := _PEC_Close
	_PromptEdWeb_EvalHook    := _PEC_Eval
	_PromptEdWeb_IsEdit      := false
	_PromptEdWeb_EditId      := ""
	_PromptEdWeb_InitName    := ""
	_PromptEdWeb_InitPrompt  := ""
	_PromptEdWeb_InitBatch   := false
	_PromptEdWeb_ContextEpoch := 0
	_PromptEdWeb_EpochSerial  := 0
	_LLM_Menu := Map(
		"user_profiles", [
			_PEC_Profile("profile_a", "Profile A"),
			_PEC_Profile("profile_b", "Profile B"),
			_PEC_Profile("same_profile", "Initial same profile")
		],
		"profile_id", "profile_a"
	)
	_PEC_Deferred  := []
	_PEC_Persisted := []
	_PEC_Closed    := []
	_PEC_Evaluated := []
	return Previous
}

_PEC_RestoreFixture(Previous) {
	global _PromptEdWeb_DeferHook, _PromptEdWeb_PersistHook
	global _PromptEdWeb_CloseHook, _PromptEdWeb_EvalHook
	global _PromptEdWeb_IsEdit, _PromptEdWeb_EditId
	global _PromptEdWeb_InitName, _PromptEdWeb_InitPrompt, _PromptEdWeb_InitBatch
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_EpochSerial
	global _LLM_Menu

	_PromptEdWeb_DeferHook    := Previous["defer_hook"]
	_PromptEdWeb_PersistHook  := Previous["persist_hook"]
	_PromptEdWeb_CloseHook    := Previous["close_hook"]
	_PromptEdWeb_EvalHook     := Previous["eval_hook"]
	_PromptEdWeb_IsEdit       := Previous["is_edit"]
	_PromptEdWeb_EditId       := Previous["edit_id"]
	_PromptEdWeb_InitName     := Previous["init_name"]
	_PromptEdWeb_InitPrompt   := Previous["init_prompt"]
	_PromptEdWeb_InitBatch    := Previous["init_batch"]
	_PromptEdWeb_ContextEpoch := Previous["context_epoch"]
	_PromptEdWeb_EpochSerial  := Previous["epoch_serial"]
	_LLM_Menu                  := Previous["llm_menu"]
}

_PEC_QueuedContextACannotAffectContextB() {
	global _PromptEdWeb_EditId, _PromptEdWeb_ContextEpoch
	global _LLM_Menu
	global _PEC_Deferred, _PEC_Persisted, _PEC_Closed, _PEC_Evaluated

	Previous := _PEC_InstallFixture()
	try {
		ContextA := _PromptEdWeb_BeginContext(_PEC_Profile("profile_a", "Profile A"))
		_PEC_Post(_PEC_SaveMessage(ContextA.EditId, ContextA.Epoch,
			"Visible A", true, "Visible prompt A"))
		_PromptEdWeb_OnNavigationCompleted(0, 0)
		_PEC_Post(_PEC_CancelMessage(ContextA.EditId, ContextA.Epoch))
		AssertEqual(3, _PEC_Deferred.Length,
			"the fixture must hold A's save, deferred init and cancel callbacks")

		ContextB := _PromptEdWeb_BeginContext(_PEC_Profile("profile_b", "Profile B"))
		Assert(ContextB.Epoch > ContextA.Epoch,
			"re-pointing the singleton must allocate a newer display epoch")

		_PEC_Deferred[1].Call()
		AssertEqual(0, _PEC_Persisted.Length,
			"a queued A save executed after switching to B must not reach persistence (AHK-29)")
		AssertEqual("Profile A", _LLM_Menu["user_profiles"][1]["label"],
			"a stale callback must be rejected before mutating A's in-memory profile")
		AssertEqual("profile_b", _PromptEdWeb_EditId,
			"rejecting A's save must leave B as the active edit target")
		AssertEqual(ContextB.Epoch, _PromptEdWeb_ContextEpoch,
			"rejecting A's save must not alter B's epoch")

		_PEC_Deferred[2].Call()
		AssertEqual(0, _PEC_Evaluated.Length,
			"A's deferred init must not repaint the page after B became current")
		_PEC_Deferred[3].Call()
		AssertEqual(0, _PEC_Closed.Length,
			"A's queued cancel must not close B's editor")

		_PEC_Deferred := []
		_PEC_Post('{"action":"save","name":"Context-free payload",'
			. '"batch":false,"prompt":"Must be rejected"}')
		AssertEqual(0, _PEC_Deferred.Length,
			"a save without the page-owned edit id and epoch must be rejected before deferral")

		AssertTrue(_PromptEdWeb_PushInit(ContextB.EditId, ContextB.Epoch),
			"the current B context must still be allowed to initialize its page")
		AssertEqual(1, _PEC_Evaluated.Length,
			"only B's init payload may cross the WebView boundary")
		AssertContains(_PEC_Evaluated[1], '"edit_id":"profile_b"',
			"the init payload must carry B's immutable edit id")
		AssertContains(_PEC_Evaluated[1], '"epoch":' . ContextB.Epoch,
			"the init payload must carry B's immutable display epoch")

		_PEC_Deferred := []
		_PEC_Post(_PEC_SaveMessage(ContextB.EditId, ContextB.Epoch,
			"Saved B", false, "Saved prompt B"))
		AssertEqual(1, _PEC_Deferred.Length,
			"B's save must cross the same deferred boundary as A's")
		_PEC_Deferred[1].Call()
		AssertEqual(1, _PEC_Persisted.Length,
			"the current B payload must persist exactly once")
		AssertEqual("profile_b", _PEC_Persisted[1]["edit_id"],
			"persistence must use the callback-bound id instead of a mutable global")
		AssertEqual("Saved prompt B", _PEC_Persisted[1]["prompt"],
			"the current page's form values must reach B")
		AssertEqual("Saved B", _LLM_Menu["user_profiles"][2]["label"],
			"the real in-memory apply path must target B by the callback-bound id")
		AssertEqual("Saved prompt B", _LLM_Menu["user_profiles"][2]["system_single"],
			"the real in-memory apply path must commit B's visible prompt")
		AssertEqual(1, _PEC_Closed.Length,
			"only the current B completion may close the editor")
		AssertEqual(ContextB.Epoch, _PEC_Closed[1]["epoch"],
			"the close must retain B's epoch through persistence")
		AssertEqual(0, A_IsCritical,
			"the short context/apply transaction must restore the caller's Critical state")
	} finally {
		_PEC_RestoreFixture(Previous)
	}
}

Test("prompt-editor: queued A callbacks cannot mutate or close B (AHK-29)",
	_PEC_QueuedContextACannotAffectContextB)

_PEC_ContextSwitchDuringPersistenceCannotCloseNewEditor() {
	global _PromptEdWeb_PersistHook, _PromptEdWeb_EditId, _PromptEdWeb_ContextEpoch
	global _LLM_Menu
	global _PEC_Deferred, _PEC_Persisted, _PEC_Closed

	Previous := _PEC_InstallFixture()
	try {
		ContextA := _PromptEdWeb_BeginContext(_PEC_Profile("profile_a", "Profile A"))
		_PromptEdWeb_PersistHook := _PEC_PersistThenRepoint
		_PEC_Post(_PEC_SaveMessage(ContextA.EditId, ContextA.Epoch,
			"Saved A", true, "Saved prompt A"))
		AssertEqual(1, _PEC_Deferred.Length,
			"A's save must cross the deferred persistence boundary")

		_PEC_Deferred[1].Call()
		AssertEqual(1, _PEC_Persisted.Length,
			"the current A save may persist before the singleton is re-pointed")
		AssertEqual("Saved A", _LLM_Menu["user_profiles"][1]["label"],
			"the callback-bound A values must commit to A, never to the later B context")
		AssertEqual("profile_b", _PromptEdWeb_EditId,
			"the persistence seam must leave B as the active editor context")
		Assert(_PromptEdWeb_ContextEpoch > ContextA.Epoch,
			"the persistence seam must advance the display epoch before save completion")
		AssertEqual(0, _PEC_Closed.Length,
			"an A completion that yielded into context B must not close B (AHK-29)")
	} finally {
		_PEC_RestoreFixture(Previous)
	}
}

Test("prompt-editor: context switch during persistence cannot close the new editor (AHK-29)",
	_PEC_ContextSwitchDuringPersistenceCannotCloseNewEditor)

_PEC_EpochRejectsOldSaveWhenProfileIdMatches() {
	global _LLM_Menu
	global _PEC_Deferred, _PEC_Persisted, _PEC_Closed

	Previous := _PEC_InstallFixture()
	try {
		OldContext := _PromptEdWeb_BeginContext(_PEC_Profile("same_profile", "First display"))
		_PEC_Post(_PEC_SaveMessage(OldContext.EditId, OldContext.Epoch,
			"Stale values", false, "Stale prompt"))
		NewContext := _PromptEdWeb_BeginContext(_PEC_Profile("same_profile", "Second display"))
		AssertEqual(OldContext.EditId, NewContext.EditId,
			"the adversarial vector must reopen the same profile id")
		Assert(NewContext.Epoch > OldContext.Epoch,
			"the two displays must remain distinguishable by epoch")

		_PEC_Deferred[1].Call()
		AssertEqual(0, _PEC_Persisted.Length,
			"matching edit ids must not let an old display epoch persist")
		AssertEqual("Initial same profile", _LLM_Menu["user_profiles"][3]["label"],
			"matching edit ids must not let an old epoch mutate the current profile")
		AssertEqual(0, _PEC_Closed.Length,
			"matching edit ids must not let an old display epoch close the new display")
	} finally {
		_PEC_RestoreFixture(Previous)
	}
}

Test("prompt-editor: epoch distinguishes repeated edits of one id (AHK-29)",
	_PEC_EpochRejectsOldSaveWhenProfileIdMatches)

_PEC_FailedPersistenceDoesNotPublishCandidate() {
	global _PromptEdWeb_PersistHook, _LLM_Menu
	global _PEC_Deferred, _PEC_Closed
	Previous := _PEC_InstallFixture()
	try {
		Context := _PromptEdWeb_BeginContext(
			_PEC_Profile("profile_a", "Profile A"))
		_PromptEdWeb_PersistHook := _PEC_RefusePersist
		_PEC_Post(_PEC_SaveMessage(Context.EditId, Context.Epoch,
			"Rejected A", true, "Rejected prompt A"))
		_PEC_Deferred[1].Call()
		AssertEqual("Profile A", _LLM_Menu["user_profiles"][1]["label"],
			"a refused durable writer must not publish the detached profile")
		AssertEqual("Prompt for Profile A",
			_LLM_Menu["user_profiles"][1]["system_single"])
		AssertEqual(0, _PEC_Closed.Length,
			"a failed save must leave the editor open for retry")
	} finally _PEC_RestoreFixture(Previous)
}
Test("prompt-editor: failed persistence keeps candidate detached "
	. "(prompt-editor-detached-failed-writer)",
	_PEC_FailedPersistenceDoesNotPublishCandidate)

_PEC_SavePayloadRejectsMalformedScalars() {
	global _PEC_Deferred, _PEC_Persisted, _LLM_Menu
	Previous := _PEC_InstallFixture()
	try {
		Context := _PromptEdWeb_BeginContext(
			_PEC_Profile("profile_a", "Profile A"))
		InvalidPayloads := [
			Map("name", "42", "batch", "true", "prompt", _PromptEdWeb_JsStr("Valid prompt")),
			Map("name", _PromptEdWeb_JsStr(""), "batch", "true", "prompt", _PromptEdWeb_JsStr("Valid prompt")),
			Map("name", _PromptEdWeb_JsStr("Valid name"), "batch", '"true"', "prompt", _PromptEdWeb_JsStr("Valid prompt")),
			Map("name", _PromptEdWeb_JsStr("Valid name"), "batch", '"false"', "prompt", _PromptEdWeb_JsStr("Valid prompt")),
			Map("name", _PromptEdWeb_JsStr("Valid name"), "batch", "2", "prompt", _PromptEdWeb_JsStr("Valid prompt")),
			Map("name", _PromptEdWeb_JsStr("Valid name"), "batch", "-1", "prompt", _PromptEdWeb_JsStr("Valid prompt")),
			Map("name", _PromptEdWeb_JsStr("Valid name"), "batch", "true", "prompt", "42"),
			Map("name", _PromptEdWeb_JsStr("Valid name"), "batch", "true", "prompt", _PromptEdWeb_JsStr(""))
		]
		for Invalid in InvalidPayloads {
			_PEC_Deferred := []
			_PEC_Post(_PEC_SaveRawMessage(Context.EditId, Context.Epoch,
				Invalid["name"], Invalid["batch"], Invalid["prompt"]))
			AssertEqual(0, _PEC_Deferred.Length,
				"a malformed save scalar must be rejected before deferral")
			AssertEqual(0, _PEC_Persisted.Length,
				"a rejected save scalar must not reach persistence")
			AssertEqual("Profile A", _LLM_Menu["user_profiles"][1]["label"],
				"a rejected save scalar must preserve the live profile")
		}

		_PEC_Post(_PEC_SaveMessage(Context.EditId, Context.Epoch,
			"Valid batch", true, "Valid prompt"))
		AssertEqual(1, _PEC_Deferred.Length,
			"a true Boolean batch payload must remain deferrable")
		_PEC_Deferred[1].Call()
		AssertEqual(true, _PEC_Persisted[1]["batch"],
			"the true Boolean value must survive the bridge unchanged")

		_PEC_Deferred := []
		_PEC_Post(_PEC_SaveMessage(Context.EditId, Context.Epoch,
			"Valid parallel", false, "Another valid prompt"))
		AssertEqual(1, _PEC_Deferred.Length,
			"a false Boolean batch payload must remain deferrable")
		_PEC_Deferred[1].Call()
		AssertEqual(false, _PEC_Persisted[2]["batch"],
			"the false Boolean value must survive the bridge unchanged")
	} finally _PEC_RestoreFixture(Previous)
}
Test("prompt-editor: save payload rejects malformed scalar fields",
	_PEC_SavePayloadRejectsMalformedScalars)
