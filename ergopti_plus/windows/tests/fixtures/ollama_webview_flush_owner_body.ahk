; tests/fixtures/ollama_webview_flush_owner_body.ahk

; ==============================================================================
; MODULE: Ollama Locale Flush Child Fixture
; DESCRIPTION:
; Replaces a session at the actual missing-locale diagnostic boundary. Private
; native locale files distinguish normal reading from the diagnostic path;
; passive surfaces/controllers do not claim observed browser COM reentrancy.
; ==============================================================================

#Requires AutoHotkey v2.0

class _OWFL_Controller {
	Closed := 0
	Close() {
		this.Closed += 1
	}
}

class _OWFL_Gui {
	Destroyed := 0
	Destroy() {
		this.Destroyed += 1
	}
}

_OWFL_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_OWFL_Install(World, Successor := false) {
	global _OllamaWV_WebView, _OllamaWV_Controller, _OllamaWV_Gui
	global _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_MsgSub
	_OllamaWV_WebView := Successor ? World.NextView : World.OldView
	_OllamaWV_Controller := Successor ? World.NextController : World.OldController
	_OllamaWV_Gui := Successor ? World.NextGui : World.OldGui
	_OllamaWV_Queue := Successor ? World.NextQueue : World.OldQueue
	_OllamaWV_MsgSub := {}, _OllamaWV_Ready := false
}

_OWFL_Diagnostic(Text) {
	global _OWFL_World, _SharedDir
	World := _OWFL_World
	_OWFL_Require(InStr(Text, "i18n locale file not found: " . _SharedDir) == 1,
		"only the real private missing-locale path may trigger the controlled diagnostic")
	World.Diagnostics += 1
	if World.Mode == "locale-replace" {
		_OWFL_Require(World.Diagnostics == 1, "the actual locale diagnostic must occur once")
		OllamaWV_Close()
		_OWFL_Install(World, true)
	}
}

_OWFL_Run(Mode) {
	global _OWFL_World, _SharedDir, _I18nLocale
	global _OllamaWV_Epoch, _OllamaWV_WebView, _OllamaWV_Queue, _OllamaWV_Ready
	World := {Mode: Mode, Diagnostics: 0, OldView: {}, NextView: {},
		OldController: _OWFL_Controller(), NextController: _OWFL_Controller(),
		OldGui: _OWFL_Gui(), NextGui: _OWFL_Gui(),
		OldQueue: ["original.one", "original.two"], NextQueue: ["successor.one", "successor.two"]}
	_OWFL_World := World
	DirCreate(_SharedDir . "\data\locales")
	_OWFL_Require(!FileExist(_SharedDir . "\data\locales\missing.json"),
		"the diagnostic fixture must genuinely lack its private locale file")
	if Mode == "current-locale" {
		_I18nLocale := "fixture"
		FileAppend('{"label":"locale 😀"}', _SharedDir . "\data\locales\fixture.json", "UTF-8-RAW")
		Expected := 'window._i18n_strings={"label":"locale 😀"};if(typeof window.i18n_apply===' . "'function'"
			. ')window.i18n_apply(window._i18n_strings);'
		_OWFL_Require(OllamaWV_I18nApplyScript(_I18nLocale) == Expected,
			"the real locale reader must preserve the independently supplied UTF-8 payload")
	}
	_OllamaWV_Epoch := 91
	_OWFL_Install(World)
	if Mode == "entry-paused"
		Suspend(true)
	OllamaWV_FlushQueue(Mode == "stale-epoch" ? 90 : 91)
	ExpectedQueue := Mode == "locale-replace" ? World.NextQueue : World.OldQueue
	FileAppend("RECEIPT mode=" . Mode . " diagnostics=" . World.Diagnostics . " epoch=" . _OllamaWV_Epoch
		. " ready=" . _OllamaWV_Ready . " queue_preserved=" . (_OllamaWV_Queue == ExpectedQueue)
		. " queue_length=" . _OllamaWV_Queue.Length . " old_closed=" . World.OldController.Closed
		. " next_closed=" . World.NextController.Closed . "`n", "*", "UTF-8")
	if Mode == "locale-replace" {
		_OWFL_Require(World.Diagnostics == 1 && _OllamaWV_Epoch == 92,
			"the real diagnostic must close the original session before installing the successor")
		_OWFL_Require(_OllamaWV_Queue == World.NextQueue && _OllamaWV_Queue.Length == 2
			&& _OllamaWV_Queue[1] == "successor.one" && _OllamaWV_Queue[2] == "successor.two",
			"the predecessor locale flush must not discard the successor's actual pending queue")
		_OWFL_Require(!_OllamaWV_Ready && _OllamaWV_WebView == World.NextView,
			"the successor retains its exact page and unready state")
		_OWFL_Require(World.OldController.Closed == 1 && World.OldGui.Destroyed == 1
			&& World.NextController.Closed == 0 && World.NextGui.Destroyed == 0,
			"the admitted replacement owns its distinct passive native boundaries")
	} else if Mode == "stale-epoch" || Mode == "entry-paused" {
		_OWFL_Require(World.Diagnostics == 0 && !_OllamaWV_Ready && _OllamaWV_Queue == World.OldQueue
			&& _OllamaWV_Queue.Length == 2 && _OllamaWV_WebView == World.OldView
			&& _OllamaWV_Queue[1] == "original.one" && _OllamaWV_Queue[2] == "original.two",
			"an inadmissible flush must preserve its current queue without reading the locale")
	} else {
		_OWFL_Require(_OllamaWV_Ready && _OllamaWV_Queue.Length == 0
			&& _OllamaWV_WebView == World.OldView && _OllamaWV_Epoch == 91,
			"the current flush must retain ordinary ready/queue admission")
		_OWFL_Require(World.Diagnostics == (Mode == "current-fallback" ? 1 : 0),
			"only the genuinely absent locale should emit the diagnostic")
	}
	FileAppend("PASS ollama-flush-owner " . Mode . "`n", "*", "UTF-8")
}

; No deferred script is executed here. Critical is held through the synchronous
; queue assertions and final process exit, not a claim of native timer order.
Critical("On")
try {
	_OWFL_Run(A_Args[1])
	ExitApp(0)
} catch as Failure {
	FileAppend("FAIL ollama-flush-owner " . A_Args[1] . ": " . Failure.Message . "`n" . Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
