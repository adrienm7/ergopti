; tests/fixtures/ollama_webview_close_owner_body.ahk

; ==============================================================================
; MODULE: Ollama Close Owner Child Fixture
; DESCRIPTION:
; Reenters the actual close owner at controlled native cleanup boundaries.
; Real private GUI HWNDs distinguish the retired surface from its successor;
; passive controllers, subscription destructors and profile retirement retain
; their exact receipts without claiming observed WebView COM reentrancy.
; ==============================================================================

#Requires AutoHotkey v2.0

class _OWCO_Controller {
	__New(World, Successor := false) {
		this.World := World, this.Successor := Successor, this.Closed := 0
	}
	Close() {
		World := this.World
		this.Closed += 1
		World.Events.Push(this.Successor ? "next-controller" : "old-controller")
		if !this.Successor && World.OldSubscriptionReleased != 1
			World.BadOrder := true
		if !this.Successor && (World.Mode == "reenter-controller" || World.Mode == "reenter-close-if-epoch")
			_OWCO_Reenter(World)
	}
}

class _OWCO_Subscription {
	__New(World, Successor := false) {
		this.World := World, this.Successor := Successor
	}
	__Delete() {
		World := this.World
		if this.Successor {
			World.NextSubscriptionReleased += 1
			World.Events.Push("next-subscription")
		} else {
			World.OldSubscriptionReleased += 1
			World.Events.Push("old-subscription")
			if World.Mode == "reenter-subscription"
				_OWCO_Reenter(World)
		}
	}
}

_OWCO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_OWCO_Count(World) {
	World.Callbacks += 1
}

_OWCO_Profile(Path) {
	global _OWCO_World
	_OWCO_World.RetiredPaths.Push(Path)
}

_OWCO_Install(World, Successor := false) {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView, _OllamaWV_MsgSub
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry, _OllamaWV_Udir, _OllamaWV_Queue, _OllamaWV_Ready, _OllamaWV_Epoch
	if Successor
		_OllamaWV_Epoch += 1
	_OllamaWV_Gui := Successor ? World.NextGui : World.OldGui
	_OllamaWV_Controller := Successor ? World.NextController : World.OldController
	_OllamaWV_WebView := Successor ? World.NextView : World.OldView
	_OllamaWV_OnCancel := Successor ? World.NextCallback : World.OldCallback
	_OllamaWV_OnRetry := Successor ? World.NextCallback : World.OldCallback
	_OllamaWV_Udir := Successor ? World.NextProfile : World.OldProfile
	_OllamaWV_Queue := [Successor ? "next.pending" : "old.pending"]
	_OllamaWV_Ready := true
	_OllamaWV_MsgSub := _OWCO_Subscription(World, Successor)
}

_OWCO_Reenter(World) {
	if World.Cleanup || World.Reentered
		return
	World.Reentered := true
	_OWCO_Install(World, true)
}

_OWCO_Receipt(World) {
	global _OllamaWV_WebView, _OllamaWV_Epoch, _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_Udir
	Current := !IsSet(_OllamaWV_WebView) ? "unset"
		: (_OllamaWV_WebView == World.NextView ? "successor" : "original")
	Profile := !IsSet(_OllamaWV_Udir) ? "unset" : (_OllamaWV_Udir == World.NextProfile ? "next" : "old")
	FileAppend("RECEIPT mode=" . World.Mode . " current=" . Current . " epoch=" . _OllamaWV_Epoch
		. " old_gui_live=" . DllCall("IsWindow", "Ptr", World.OldHwnd, "Int")
		. " next_gui_live=" . DllCall("IsWindow", "Ptr", World.NextHwnd, "Int")
		. " old_closed=" . World.OldController.Closed . " next_closed=" . World.NextController.Closed
		. " old_unsub=" . World.OldSubscriptionReleased . " next_unsub=" . World.NextSubscriptionReleased
		. " ready=" . _OllamaWV_Ready . " queued=" . _OllamaWV_Queue.Length . " profile=" . Profile
		. " retired_profiles=" . World.RetiredPaths.Length . " callbacks=" . World.Callbacks . "`n", "*", "UTF-8")
}

_OWCO_CheckClosed(World) {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView, _OllamaWV_MsgSub, _OllamaWV_Udir
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry, _OllamaWV_Ready, _OllamaWV_Queue
	_OWCO_Require(!IsSet(_OllamaWV_Gui) && !IsSet(_OllamaWV_Controller) && !IsSet(_OllamaWV_WebView)
		&& !IsSet(_OllamaWV_MsgSub) && !IsSet(_OllamaWV_Udir), "ordinary close must retire all active native slots")
	_OWCO_Require(World.OldController.Closed == 1 && World.OldSubscriptionReleased == 1,
		"ordinary close must release the admitted subscription and controller once")
	_OWCO_Require(!DllCall("IsWindow", "Ptr", World.OldHwnd, "Int"), "ordinary close must destroy its actual GUI")
	_OWCO_Require(!_OllamaWV_Ready && _OllamaWV_Queue.Length == 0, "ordinary close must retire readiness and queued scripts")
	_OWCO_Require(World.RetiredPaths.Length == 1 && World.RetiredPaths[1] == World.OldProfile,
		"ordinary close must delegate retirement of its exact captured profile once")
	_OWCO_Require(_OllamaWV_OnCancel == World.OldCallback && _OllamaWV_OnRetry == World.OldCallback,
		"close must preserve its established callback-selection policy")
}

_OWCO_CheckSuccessor(World) {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView, _OllamaWV_MsgSub
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry, _OllamaWV_Udir, _OllamaWV_Epoch, _OllamaWV_Ready, _OllamaWV_Queue
	_OWCO_Require(World.Reentered && World.OldController.Closed == 1 && World.OldSubscriptionReleased == 1,
		"the retired owner must finish its real close and unsubscribe despite controlled reentry")
	_OWCO_Require(!DllCall("IsWindow", "Ptr", World.OldHwnd, "Int"), "the retired GUI must be destroyed, not leaked")
	_OWCO_Require(DllCall("IsWindow", "Ptr", World.NextHwnd, "Int"), "old close must preserve the actual successor HWND")
	_OWCO_Require(IsSet(_OllamaWV_Gui) && _OllamaWV_Gui == World.NextGui
		&& IsSet(_OllamaWV_Controller) && _OllamaWV_Controller == World.NextController
		&& IsSet(_OllamaWV_WebView) && _OllamaWV_WebView == World.NextView,
		"old close must not clear or borrow successor globals after native callouts")
	_OWCO_Require(World.NextController.Closed == 0 && World.NextSubscriptionReleased == 0
		&& IsSet(_OllamaWV_MsgSub), "old cleanup cannot close or unsubscribe the successor")
	_OWCO_Require(_OllamaWV_OnCancel == World.NextCallback && _OllamaWV_OnRetry == World.NextCallback,
		"successor callback identities must survive the old close stack")
	_OWCO_Require(_OllamaWV_Epoch == 43 && _OllamaWV_Ready && _OllamaWV_Queue.Length == 1
		&& _OllamaWV_Queue[1] == "next.pending", "the new session must keep its published epoch, queue and readiness")
	_OWCO_Require(IsSet(_OllamaWV_Udir) && _OllamaWV_Udir == World.NextProfile
		&& World.RetiredPaths.Length == 1 && World.RetiredPaths[1] == World.OldProfile,
		"the old profile must retire while the successor profile remains current")
	OllamaWV_CloseIfEpoch(41)
	_OWCO_Require(_OllamaWV_Epoch == 43 && _OllamaWV_WebView == World.NextView
		&& World.NextController.Closed == 0 && DllCall("IsWindow", "Ptr", World.NextHwnd, "Int"),
		"a retained old close-if-epoch cannot retire the replacement")
}

_OWCO_Run(Mode, Directory) {
	global _OWCO_World, _OllamaWV_Epoch, _OllamaWV_WebView, _OllamaWV_MsgSub
	World := {Mode: Mode, Cleanup: false, Reentered: false, OldSubscriptionReleased: 0,
		NextSubscriptionReleased: 0, Events: [], RetiredPaths: [], BadOrder: false, Callbacks: 0,
		OldView: {}, NextView: {}, OldProfile: Directory . "\old-profile", NextProfile: Directory . "\next-profile"}
	_OWCO_World := World
	World.OldGui := Gui("+ToolWindow", "Retired private download fixture")
	World.NextGui := Gui("+ToolWindow", "Successor private download fixture")
	World.ForeignGui := Gui("+ToolWindow", "Unrelated private fixture")
	World.OldHwnd := World.OldGui.Hwnd, World.NextHwnd := World.NextGui.Hwnd
	World.ForeignHwnd := World.ForeignGui.Hwnd
	World.OldController := _OWCO_Controller(World), World.NextController := _OWCO_Controller(World, true)
	World.OldCallback := _OWCO_Count.Bind(World), World.NextCallback := _OWCO_Count.Bind(World)
	try {
		_OWCO_Require(DllCall("IsWindow", "Ptr", World.OldHwnd, "Int")
			&& DllCall("IsWindow", "Ptr", World.NextHwnd, "Int")
			&& DllCall("IsWindow", "Ptr", World.ForeignHwnd, "Int")
			&& World.OldHwnd != World.NextHwnd && World.NextHwnd != World.ForeignHwnd,
			"the controls require distinct genuine private native HWNDs before close")
		_OWCO_Require(World.OldCallback != World.NextCallback && World.OldView != World.NextView,
			"the controls require distinct retained session and callback identities")
		_OllamaWV_Epoch := 41
		_OWCO_Install(World)
		if Mode == "stale-close-if-epoch"
			OllamaWV_CloseIfEpoch(40)
		else if Mode == "current-close-if-epoch" || Mode == "reenter-close-if-epoch"
			OllamaWV_CloseIfEpoch(41)
		else
			OllamaWV_Close()
		if Mode == "repeat-close"
			OllamaWV_Close()
		_OWCO_Receipt(World)
		if InStr(Mode, "reenter-") == 1 {
			_OWCO_CheckSuccessor(World)
		} else if Mode == "stale-close-if-epoch" {
			_OWCO_Require(_OllamaWV_Epoch == 41 && _OllamaWV_WebView == World.OldView
				&& World.OldController.Closed == 0 && World.OldSubscriptionReleased == 0
				&& DllCall("IsWindow", "Ptr", World.OldHwnd, "Int"), "stale close must perform no native cleanup")
		} else {
			_OWCO_CheckClosed(World)
			_OWCO_Require(_OllamaWV_Epoch == (Mode == "repeat-close" ? 43 : 42), "close must retain its epoch contract")
		}
		_OWCO_Require(!World.BadOrder && World.Callbacks == 0, "subscription must retire before native close without invoking business callbacks")
		_OWCO_Require(DllCall("IsWindow", "Ptr", World.ForeignHwnd, "Int"), "cleanup must preserve an unrelated real HWND")
		FileAppend("PASS ollama-close-owner " . Mode . "`n", "*", "UTF-8")
	} finally {
		World.Cleanup := true
		_OllamaWV_MsgSub := unset
		World.OldGui.Destroy(), World.NextGui.Destroy(), World.ForeignGui.Destroy()
	}
}

Critical("On")
try {
	_OWCO_Run(A_Args[1], A_Args[2])
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL ollama-close-owner " . A_Args[1] . ": " . Failure.Message . "`n" . Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
