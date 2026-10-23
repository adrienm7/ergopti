; tests/fixtures/ollama_webview_message_owner_body.ahk

; ==============================================================================
; MODULE: Ollama Message Owner Child Fixture
; DESCRIPTION:
; Calls the complete production module through its genuine message handler.
; Only logging and native controller/GUI boundaries are passive, so replacing
; globals during a payload read exposes actual session and callback selection.
; ==============================================================================

#Requires AutoHotkey v2.0

class _OWMB_Controller {
	__New(World, Successor := false) {
		this.World := World, this.Successor := Successor, this.Closed := 0
	}
	Close() {
		global _OllamaWV_OnCancel
		this.Closed += 1
		if !this.Successor && this.World.Mode == "cancel-callback-swap"
			_OllamaWV_OnCancel := _OWMB_Count.Bind(this.World, "NewCancel")
	}
}

class _OWMB_Gui {
	Destroyed := 0
	Destroy() {
		this.Destroyed += 1
	}
}

_OWMB_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_OWMB_Count(World, Name) {
	World.%Name% += 1
}

_OWMB_Install(World, Successor := false) {
	global _OllamaWV_WebView, _OllamaWV_Controller, _OllamaWV_Gui, _OllamaWV_Epoch
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry, _OllamaWV_MsgSub, _OllamaWV_Ready, _OllamaWV_Queue
	if Successor
		_OllamaWV_Epoch += 1
	_OllamaWV_WebView := Successor ? World.SecondView : World.FirstView
	_OllamaWV_Controller := Successor ? World.SecondController : World.FirstController
	_OllamaWV_Gui := Successor ? World.SecondGui : World.FirstGui
	_OllamaWV_OnCancel := _OWMB_Count.Bind(World, Successor ? "NewCancel" : "OldCancel")
	_OllamaWV_OnRetry := _OWMB_Count.Bind(World, Successor ? "NewRetry" : "OldRetry")
	_OllamaWV_MsgSub := {}, _OllamaWV_Ready := false
	_OllamaWV_Queue := [Successor ? "successor.pending" : "original.pending"]
}

_OWMB_Log() {
	global _OWMB_World
	if _OWMB_World.Mode == "logger-replacement" {
		OllamaWV_Close()
		_OWMB_Install(_OWMB_World, true)
	}
}

_OWMB_Read(World, *) {
	global _OllamaWV_Epoch
	World.Reads += 1
	if InStr(World.Mode, "replace-") == 1 {
		OllamaWV_Close()
		_OWMB_Install(World, true)
	} else if World.Mode == "pause-on-read" {
		Suspend(true)
	} else if World.Mode == "epoch-on-read" {
		_OllamaWV_Epoch += 1
	}
	return World.Message
}

_OWMB_Receipt(World) {
	global _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_Epoch
	Current := !IsSet(_OllamaWV_WebView) ? "unset"
		: (_OllamaWV_WebView == World.SecondView ? "successor" : "original")
	FileAppend("RECEIPT mode=" . World.Mode . " reads=" . World.Reads . " current=" . Current
		. " epoch=" . _OllamaWV_Epoch . " ready=" . _OllamaWV_Ready . " queued=" . _OllamaWV_Queue.Length
		. " old_closed=" . World.FirstController.Closed . " new_closed=" . World.SecondController.Closed
		. " old_retry=" . World.OldRetry . " new_retry=" . World.NewRetry
		. " old_cancel=" . World.OldCancel . " new_cancel=" . World.NewCancel . "`n", "*", "UTF-8")
}

_OWMB_Run(Mode) {
	global _OWMB_World
	global _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_Epoch
	World := {Mode: Mode, Reads: 0, OldCancel: 0, NewCancel: 0, OldRetry: 0, NewRetry: 0,
		FirstView: {}, SecondView: {}, FirstGui: _OWMB_Gui(), SecondGui: _OWMB_Gui()}
	_OWMB_World := World
	World.FirstController := _OWMB_Controller(World)
	World.SecondController := _OWMB_Controller(World, true)
	World.Message := Mode == "cancel-callback-swap" ? "cancel"
		: (RegExMatch(Mode, "(ready|retry|cancel)$", &Match) ? Match[1] : "retry")
	_OllamaWV_Epoch := 41
	_OWMB_Install(World)
	if Mode == "entry-paused"
		Suspend(true)
	Sender := Mode == "wrong-sender" ? {} : World.FirstView
	OllamaWV_OnWebMessage(Sender, {TryGetWebMessageAsString: _OWMB_Read.Bind(World)})
	_OWMB_Receipt(World)
	if InStr(Mode, "replace-") == 1 || Mode == "logger-replacement" {
		_OWMB_Require(World.Reads == 1 && World.FirstController.Closed == 1
			&& World.FirstGui.Destroyed == 1, "the actual getter must retire its original session")
		_OWMB_Require(IsSet(_OllamaWV_WebView), "a predecessor message must not close the installed successor")
		_OWMB_Require(_OllamaWV_WebView == World.SecondView && World.SecondController.Closed == 0
			&& World.SecondGui.Destroyed == 0, "the replacement session must retain its exact native owners")
		_OWMB_Require(!_OllamaWV_Ready && _OllamaWV_Queue.Length == 1
			&& _OllamaWV_Queue[1] == "successor.pending", "a predecessor ready message must not consume successor readiness")
		_OWMB_Require(World.NewRetry == 0 && World.NewCancel == 0
			&& World.OldRetry == 0 && World.OldCancel == 0, "a predecessor payload must not invoke either session callback")
	} else if Mode == "current-ready" {
		_OWMB_Require(World.Reads == 1 && _OllamaWV_Ready && _OllamaWV_Queue.Length == 0,
			"the current ready payload must reach the real queue owner")
	} else if Mode == "current-retry" {
		_OWMB_Require(World.Reads == 1 && World.OldRetry == 1 && World.NewRetry == 0,
			"the current retry payload must invoke exactly its admitted callback")
	} else if Mode == "current-cancel" || Mode == "cancel-callback-swap" {
		_OWMB_Require(World.Reads == 1 && World.FirstController.Closed == 1
			&& World.FirstGui.Destroyed == 1 && !IsSet(_OllamaWV_WebView), "current cancel must reach the real close owner")
		_OWMB_Require(World.OldCancel == 1 && World.NewCancel == 0,
			"cancel must invoke the callback captured before reentrant native teardown")
	} else {
		ExpectedReads := Mode == "wrong-sender" || Mode == "entry-paused" ? 0 : 1
		_OWMB_Require(World.Reads == ExpectedReads, "the guard must reject at the intended payload boundary")
		_OWMB_Require(World.OldRetry == 0 && World.NewRetry == 0
			&& World.FirstController.Closed == 0 && !_OllamaWV_Ready,
			"wrong, paused or retired payloads must not dispatch a current action")
	}
	FileAppend("PASS ollama-message-owner " . Mode . "`n", "*", "UTF-8")
}

; The real ready path may arm deferred script timers. Keeping this child thread
; critical through assertions and ExitApp prevents unrelated script execution;
; this fixture qualifies queue admission, not native WebView script delivery.
Critical("On")
try {
	_OWMB_Run(A_Args[1])
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL ollama-message-owner " . A_Args[1] . ": " . Failure.Message . "`n" . Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
