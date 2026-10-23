; tests/fixtures/ollama_webview_delivery_reentrancy_body.ahk

; ==============================================================================
; MODULE: Ollama Delivery Reentrancy Child Fixture
; DESCRIPTION:
; Real timer delivery and native pause/GUI retirement with passive script ports.
; Observer callbacks append, pause or replace the private session. No browser
; JavaScript or complete suspend teardown is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_ODR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

class _ODR_Controller {
	Closed := 0
	Close() {
		this.Closed += 1
	}
}

class _ODR_Promise {
	onSettled(Ok, Fail) {
		Ok.Call("null")
	}
}

class _ODR_View {
	Scripts := []
	World := 0
	ExecuteScriptAsync(Script) {
		global _OllamaWV_Delivery
		this.Scripts.Push(Script)
		World := this.World
		if this == World.OldView && this.Scripts.Length == 1 {
			World.Observed += 1
			if World.Mode == "replace" {
				World.OldDelivery := _OllamaWV_Delivery
				OllamaWV_Close()
				_ODR_Install(World.NextView, World.NextController, World.NextGui)
				OllamaWV_EvalJS("window.successor();")
				OllamaWV_FlushQueue()
			} else {
				if World.Mode == "pause"
					Suspend(true)
				OllamaWV_AddLog("late")
				if World.Mode == "append" {
					OllamaWV_OnResume()
					OllamaWV_OnResume()
				}
			}
		}
		return _ODR_Promise()
	}
}

_ODR_Install(View, Controller, Window) {
	global _OllamaWV_WebView, _OllamaWV_Controller, _OllamaWV_Gui
	_OllamaWV_WebView := View, _OllamaWV_Controller := Controller, _OllamaWV_Gui := Window
}

_ODR_AsyncError(Failure, Mode) {
	global _ODR_World
	if IsObject(_ODR_World)
		_ODR_World.Error := Failure
	return 1
}

_ODR_Pump(World, Count) {
	Started := A_TickCount
	while (World.Mode == "replace" ? World.NextView.Scripts.Length : World.OldView.Scripts.Length) < Count {
		if IsObject(World.Error)
			throw World.Error
		if TickElapsed(Started) > 2000
			throw Error("The private reentrant FIFO did not drain.")
		Sleep(10)
	}
	Sleep(50)
	if IsObject(World.Error)
		throw World.Error
}

_ODR_Check(Scripts, Expected) {
	_ODR_Require(Scripts.Length == Expected.Length, "the actual native admission count must be exact")
	for Index, Script in Expected
		_ODR_Require(Scripts[Index] == Script, "the actual native admission FIFO must retain item " . Index)
}

_ODR_Main() {
	global _ODR_World, _SharedDir, _I18nLocale, _OllamaWV_Epoch, _OllamaWV_Delivery
	World := {Mode: A_Args[1], OldView: _ODR_View(), NextView: _ODR_View(),
		OldController: _ODR_Controller(), NextController: _ODR_Controller(),
		OldGui: Gui("+ToolWindow", "Private old delivery owner"),
		NextGui: Gui("+ToolWindow", "Private next delivery owner"), Observed: 0, Error: 0}
	_ODR_World := World
	World.OldHwnd := World.OldGui.Hwnd, World.NextHwnd := World.NextGui.Hwnd
	World.OldView.World := World, World.NextView.World := World
	World.OldGui.Show("NA x-32000 y-32000 w80 h40")
	World.NextGui.Show("NA x-32000 y-32000 w80 h40")
	Primary := 0, CleanupError := 0
	try {
		_SharedDir := A_Args[2] . "\shared", _I18nLocale := "fixture"
		DirCreate(_SharedDir . "\data\locales")
		FileAppend('{"label":"fixture"}', _SharedDir . "\data\locales\fixture.json", "UTF-8-RAW")
		Locale := OllamaWV_I18nApplyScript(_I18nLocale)
		_OllamaWV_Epoch += 1
		_ODR_Install(World.OldView, World.OldController, World.OldGui)
		OllamaWV_EvalJS("window.original();")
		OllamaWV_FlushQueue()
		if World.Mode == "pause" {
			_ODR_Pump(World, 1)
			_ODR_Require(A_IsSuspended && World.Observed == 1,
				"the actual first native observer must pause before the next admission")
			_ODR_Require(World.OldView.Scripts.Length == 1,
				"pause during an accepted item must retain later work unsent")
			Suspend(false)
			OllamaWV_OnResume()
		}
		_ODR_Pump(World, World.Mode == "replace" ? 2 : 3)
		_ODR_Require(World.Observed == 1, "the old native observer must execute exactly once")
		_ODR_Require(_OllamaWV_Delivery is Map && _OllamaWV_Delivery["pending"].Length == 0
			&& _OllamaWV_Delivery["head"] == 1 && _OllamaWV_Delivery["prefix"] == "",
			"the drained current record must release consumed strings and array slots")
		if World.Mode == "replace" {
			_ODR_Check(World.OldView.Scripts, [Locale])
			_ODR_Require(World.OldDelivery["pending"].Length == 1
				&& World.OldDelivery["pending"][1] == "window.original();",
				"retirement cannot mutate the unsent array of the returning old observer")
			_ODR_Check(World.NextView.Scripts, [Locale, "window.successor();"])
			_ODR_Require(World.OldController.Closed == 1 && World.NextController.Closed == 0
				&& !DllCall("IsWindow", "Ptr", World.OldHwnd, "Int"),
				"the old drain cannot retire its newly admitted successor")
		} else _ODR_Check(World.OldView.Scripts, [Locale, "window.original();", 'addLog("late")'])
		FileAppend("RECEIPT mode=" . World.Mode . " observed=" . World.Observed
			. " old_scripts=" . World.OldView.Scripts.Length . " next_scripts=" . World.NextView.Scripts.Length
			. " old_closed=" . World.OldController.Closed . " next_closed=" . World.NextController.Closed
			. "`n", "*", "UTF-8")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			Suspend(false)
			OllamaWV_Close()
			Sleep(50)
			_ODR_Require(!IsObject(World.Error), "retired delivery timers must not publish asynchronous failures")
		} catch as Failure {
			CleanupError := Failure
		}
		try {
			if DllCall("IsWindow", "Ptr", World.OldHwnd, "Int")
				World.OldGui.Destroy()
			if DllCall("IsWindow", "Ptr", World.NextHwnd, "Int")
				World.NextGui.Destroy()
		} catch as Failure {
			if !IsObject(CleanupError)
				CleanupError := Failure
		}
		World.OldView.World := 0, World.NextView.World := 0
		OnError(_ODR_AsyncError, 0)
		_ODR_World := 0
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

Persistent(true)
global _ODR_World := 0
OnError(_ODR_AsyncError)
try {
	_ODR_Main()
	_OCSD_Finish()
	FileAppend("PASS ollama-delivery-reentrancy " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch as Failure {
	try _OCSD_Finish()
	FileAppend("FAIL ollama-delivery-reentrancy: " . Failure.Message . "`n" . Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
