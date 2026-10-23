; modules/llm/api_remote_backboard_exchange.ahk

; ==============================================================================
; MODULE: Backboard Exchange Ownership
; DESCRIPTION:
; Retains one public cancellation handle across assistant creation and message
; dispatch. Child transports keep their existing registry and native lifecycle;
; this owner closes the synchronous gap between them without another timer.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLMRemote_BackboardBegin(OnSuccess, OnFail, Kind) {
	global _LLM_Remote_BackboardExchanges, _LLM_Remote_AsyncCounter
	PreviousCritical := Critical("On")
	try {
		Id := ++_LLM_Remote_AsyncCounter
		Owner := Map("id", Id, "kind", Kind, "stage", 0, "success", OnSuccess, "failure", OnFail)
		_LLM_Remote_BackboardExchanges[Id] := Owner
		return Owner
	} finally Critical(PreviousCritical)
}

_LLMRemote_BackboardCurrent(Owner) {
	global _LLM_Remote_BackboardExchanges
	return Owner is Map && _LLM_Remote_BackboardExchanges.Has(Owner["id"])
		&& _LLM_Remote_BackboardExchanges[Owner["id"]] == Owner
}

_LLMRemote_BackboardStageCurrent(Owner, Stage) {
	return _LLMRemote_BackboardCurrent(Owner) && Owner["stage"] == Stage
}

_LLMRemote_BackboardDetachChild(Stage) {
	PreviousCritical := Critical("On")
	try {
		Entry := Stage.Get("child", 0)
		if Entry is Map && Entry.Get("backboard_stage", 0) == Stage {
			Entry.Delete("backboard_stage")
			Entry.Delete("backboard_exchange")
		}
		Stage["child"] := 0
	} finally Critical(PreviousCritical)
}

_LLMRemote_BackboardCancelChild(Id, Entry) {
	if !(Entry is Map)
		return
	PreviousCritical := Critical("On")
	try {
		if _LLMRemote_RequestOwns(Id, Entry) && !Entry["cancelled"]
			LLM_RemoteCancelAsync(Id)
	} finally Critical(PreviousCritical)
}

_LLMRemote_BackboardRetire(Owner, CancelChild := false) {
	global _LLM_Remote_BackboardExchanges
	Child := 0, ChildId := 0
	PreviousCritical := Critical("On")
	try {
		if !_LLMRemote_BackboardCurrent(Owner)
			return false
		_LLM_Remote_BackboardExchanges.Delete(Owner["id"])
		Stage := Owner["stage"]
		Owner["stage"] := 0
		Owner["success"] := 0, Owner["failure"] := 0
		if Stage is Map {
			Child := Stage.Get("child", 0), ChildId := Stage.Get("child_id", 0)
			_LLMRemote_BackboardDetachChild(Stage)
			Stage["owner"] := 0
		}
	} finally Critical(PreviousCritical)
	if CancelChild
		_LLMRemote_BackboardCancelChild(ChildId, Child)
	return true
}

_LLMRemote_BackboardSucceeded(Owner, Body, Usage := "") {
	Callback := Owner["success"]
	if _LLMRemote_BackboardRetire(Owner)
		_LLM_InvokeCallback(Callback, "on_success", Body, Usage)
}

_LLMRemote_BackboardFailed(Owner, Info := "") {
	Callback := Owner["failure"]
	if _LLMRemote_BackboardRetire(Owner, true)
		_LLM_InvokeCallback(Callback, "on_fail", Info)
}

_LLMRemote_BackboardStageSucceeded(Owner, Stage, Continuation, Body, Usage := "") {
	if !_LLMRemote_BackboardStageCurrent(Owner, Stage)
		return
	_LLMRemote_BackboardDetachChild(Stage)
	try Continuation.Call(Body, Usage)
	catch as Err {
		if _LLMRemote_BackboardStageCurrent(Owner, Stage)
			_LLMRemote_BackboardRetire(Owner, true)
		throw Err
	}
}

_LLMRemote_BackboardStageFailed(Owner, Stage, Continuation, Info := "") {
	if !_LLMRemote_BackboardStageCurrent(Owner, Stage)
		return
	_LLMRemote_BackboardDetachChild(Stage)
	try Continuation.Call(Info)
	catch as Err {
		if _LLMRemote_BackboardStageCurrent(Owner, Stage)
			_LLMRemote_BackboardRetire(Owner, true)
		throw Err
	}
}

; The optional native-dispatch context binds before any Send. An existing test
; transport keeps its seven-argument ABI and can bind only its exact callbacks.
_LLMRemote_BackboardBindChild(Owner, Stage, Id, Entry, OnSuccess, OnFail) {
	if !(Entry is Map) || Entry.Get("on_success", 0) != OnSuccess || Entry.Get("on_fail", 0) != OnFail
		return false
	Bound := false
	PreviousCritical := Critical("On")
	try {
		if _LLMRemote_RequestOwns(Id, Entry) && _LLMRemote_BackboardStageCurrent(Owner, Stage)
				&& (!(Stage["child"] is Map) || Stage["child"] == Entry) {
			Stage["child_id"] := Id, Stage["child"] := Entry
			Entry["backboard_exchange"] := Owner, Entry["backboard_stage"] := Stage
			Bound := true
		}
	} finally Critical(PreviousCritical)
	if !Bound
		_LLMRemote_BackboardCancelChild(Id, Entry)
	return Bound
}

_LLMRemote_BackboardPost(Owner, Resolved, Url, Payload, OnSuccess, OnFail, TimeoutMs, Kind) {
	global _LLM_Remote_PostBodyFn, _LLM_Remote_Async
	Stage := Map("owner", Owner, "child", 0, "child_id", 0)
	Success := _LLMRemote_BackboardStageSucceeded.Bind(Owner, Stage, OnSuccess)
	Failure := _LLMRemote_BackboardStageFailed.Bind(Owner, Stage, OnFail)
	PreviousCritical := Critical("On")
	try {
		if !_LLMRemote_BackboardCurrent(Owner)
			return Owner["id"]
		PreviousStage := Owner["stage"]
		if PreviousStage is Map
			PreviousStage["owner"] := 0
		Owner["stage"] := Stage
	} finally Critical(PreviousCritical)
	try {
		Post := _LLM_Remote_PostBodyFn
		if HasMethod(Post, "Call") {
			Id := Post.Call(Resolved, Url, Payload, Success, Failure, TimeoutMs, Kind)
			if _LLM_Remote_Async.Has(Id)
				_LLMRemote_BackboardBindChild(Owner, Stage, Id, _LLM_Remote_Async[Id], Success, Failure)
		} else
			LLM_RemotePostBody_Async(Resolved, Url, Payload, Success, Failure, TimeoutMs, Kind, Stage)
	} catch {
		if _LLMRemote_BackboardStageCurrent(Owner, Stage)
			_LLMRemote_BackboardFailed(Owner, _LLMRemote_FailInfo("dispatch"))
	}
	return Owner["id"]
}

; A successful child is removed BEFORE its callback, while the exchange must
; remain cancellable. Only actual transport cancellation without pending
; delivery retires the logical owner here; failures still reach their wrapper.
_LLMRemote_BackboardChildRetired(Id, Entry) {
	Owner := Entry.Get("backboard_exchange", 0), Stage := Entry.Get("backboard_stage", 0)
	if !(Stage is Map) || !_LLMRemote_BackboardStageCurrent(Owner, Stage)
			|| Stage.Get("child_id", 0) != Id || Stage.Get("child", 0) != Entry
		return
	Http := Entry.Get("http", 0)
	if Entry["cancelled"] || (Http is CurlAsyncRequest && Http.Aborted)
		_LLMRemote_BackboardRetire(Owner, true)
}

_LLMRemote_BackboardCancelAll(SpareKind) {
	global _LLM_Remote_BackboardExchanges
	Owners := []
	PreviousCritical := Critical("On")
	try {
		for Id, Owner in _LLM_Remote_BackboardExchanges {
			if SpareKind == "" || Owner["kind"] != SpareKind
				Owners.Push(Owner)
		}
	} finally Critical(PreviousCritical)
	for Owner in Owners
		_LLMRemote_BackboardRetire(Owner, true)
}
