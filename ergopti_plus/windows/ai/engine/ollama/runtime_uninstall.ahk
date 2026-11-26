; ai/engine/ollama/runtime_uninstall.ahk

; ==============================================================================
; MODULE: Managed Ollama Uninstall
; DESCRIPTION:
; Uninstalls the Ollama Ergopti installed (OLL-11 of the 2026-11-20 managed
; Ollama campaign). The sequence ports _shared/ai/engine/ollama/
; runtime_uninstall.lua, which macOS and Linux run, and replays the same
; vectors (_shared/tests/corpus/llm/ollama_uninstall_vectors.json): nothing is
; removed while a download or an installation runs; the models go first,
; through the running daemon, only when the user chose so; then the daemon
; stops; then the managed root goes, its models folder kept unless removed.
; The first refusal ends the sequence and names its step.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Uninstall Sequence =======
; =====================================
; =====================================

; The locale key of the message each outcome shows, as the Lua module's MESSAGES.
global LLM_OLLAMA_UNINSTALL_MESSAGES := Map(
	"done", "ollama.uninstall.done",
	"done_models", "ollama.uninstall.done_models",
	"busy", "ollama.uninstall.reason_busy",
	"models", "ollama.uninstall.reason_models",
	"stop", "ollama.uninstall.reason_stop",
	"files", "ollama.uninstall.reason_files")

/**
 * The steps an uninstall runs, in order.
 * @param {Boolean} RemoveModels Whether the user chose to delete the models.
 * @returns {Array} Step names: "models", "stop", "files".
 */
LLM_OllamaUninstallPlan(RemoveModels) {
	return RemoveModels ? ["models", "stop", "files"] : ["stop", "files"]
}

/**
 * Runs one uninstall over the driver's ports.
 * @param {Boolean} RemoveModels Whether the user chose to delete the models.
 * @param {Map} Ports "busy" () => Boolean, "delete_models" (Done), "stop" (Done),
 *   "remove_files" (RemoveModels, Done); each Done receives the step's success.
 * @param {Func} OnDone Receives Map("ok", "step", "message", "steps") once.
 */
LLM_OllamaUninstallRun(RemoveModels, Ports, OnDone) {
	if !(RemoveModels is Integer) || (RemoveModels != true && RemoveModels != false)
		throw TypeError("The uninstall needs a Boolean model choice.")
	if !(Ports is Map) || !HasMethod(OnDone, "Call")
		throw TypeError("The uninstall needs its ports and its callback.")
	for Name in ["busy", "delete_models", "stop", "remove_files"]
		if !HasMethod(Ports.Get(Name, 0), "Call")
			throw TypeError("The uninstall is missing its " . Name . " port.")
	return _LLM_OllamaUninstallSequence(RemoveModels, Ports, OnDone).Start()
}

class _LLM_OllamaUninstallSequence {
	__New(RemoveModels, Ports, OnDone) {
		this.RemoveModels := RemoveModels
		this.Ports := Ports
		this.OnDone := OnDone
		this.Steps := LLM_OllamaUninstallPlan(RemoveModels)
		this.Index := 0
		this.Ran := []
		this.Finished := false
	}

	Start() {
		if this.Ports["busy"].Call() == true
			return this._Finish(false, "busy")
		return this._Advance()
	}

	_Advance() {
		this.Index += 1
		if this.Index > this.Steps.Length
			return this._Finish(true, "")
		Step := this.Steps[this.Index]
		this.Ran.Push(Step)
		Done := ObjBindMethod(this, "_Answered", Step, this.Index)
		try {
			if Step == "models"
				this.Ports["delete_models"].Call(Done)
			else if Step == "stop"
				this.Ports["stop"].Call(Done)
			else
				this.Ports["remove_files"].Call(this.RemoveModels, Done)
		} catch as Err {
			this._Finish(false, Step)
			throw Err
		}
		return true
	}

	_Answered(Step, Index, Ok) {
		if this.Finished || Index != this.Index
			return false
		if !(Ok is Integer) || Ok != true
			return this._Finish(false, Step)
		return this._Advance()
	}

	_Finish(Ok, Step) {
		global LLM_OLLAMA_UNINSTALL_MESSAGES
		if this.Finished
			return false
		this.Finished := true
		this.Index := this.Steps.Length + 1
		Key := Ok ? (this.RemoveModels ? "done_models" : "done") : Step
		this.OnDone.Call(Map("ok", Ok, "step", Step, "message", LLM_OLLAMA_UNINSTALL_MESSAGES[Key],
			"steps", this.Ran))
		return Ok
	}
}





; ================================
; ================================
; ======= 2/ Windows Ports =======
; ================================
; ================================

/**
 * Whether Ergopti's own Ollama runtime is published on this computer: a
 * directory lookup under the managed root (a version folder holding
 * ollama.exe), never a process launch. The bootstrap still verifies it. The
 * model page and the « Ollama d'Ergopti » rows read it.
 * @returns {Boolean}
 */
LLM_OllamaManagedRuntimePresent() {
	Loop Files AppFoldersManagedOllamaRoot() . "\versions\*", "D" {
		if FileExist(A_LoopFileFullPath . "\ollama.exe")
			return true
	}
	return false
}

/** A download or an installation of the managed runtime is running. */
_LLM_OllamaUninstallBusy() {
	global _LLM_ManagedBootstrap
	if LLM_Deps_IsChecking()
		return true
	Flow := _LLM_ManagedBootstrap
	return IsObject(Flow) && (IsObject(Flow.PullTask) || Flow.MenuPull is Map)
}

/**
 * Deletes every model the managed daemon lists, one after the other, through
 * the same DELETE /api/delete the model page uses. Needs the daemon ready.
 * @param {Func} Done Receives true once every listed model is deleted.
 */
_LLM_OllamaUninstallDeleteModels(Done) {
	if !LLM_Deps_IsReady() {
		LoggerError("LLM.managed", "The models cannot be deleted: Ergopti's Ollama is not running.")
		return Done.Call(false)
	}
	return LLM_OllamaListModels_Async(Listed, 0, true)

	Listed(Receipt) {
		if !(Receipt is Map) || Receipt.Get("ok", false) != true || !(Receipt.Get("names", 0) is Map) {
			LoggerError("LLM.managed", "The models to delete could not be listed.")
			return Done.Call(false)
		}
		Tags := []
		for Name in Receipt["names"]
			Tags.Push(Name)
		return Next(Tags, 1)
	}

	Next(Tags, Index) {
		if Index > Tags.Length {
			LoggerInfo("LLM.managed", "Deleted {1} model(s) of Ergopti's Ollama.", Tags.Length)
			return Done.Call(true)
		}
		return LLM_OllamaDeleteModel_Async(Tags[Index], Deleted.Bind(Tags, Index))
	}

	Deleted(Tags, Index, Ok) {
		if !(Ok is Integer) || Ok != true {
			LoggerError("LLM.managed", "The model '{1}' could not be deleted.", Tags[Index])
			return Done.Call(false)
		}
		return Next(Tags, Index + 1)
	}
}

/** Stops the managed daemon and its bootstrap; their native owners must settle. */
_LLM_OllamaUninstallStop(Done) {
	Stopped := LLM_Deps_Cancel()
	if !(Stopped is Integer) || Stopped != true
		LoggerError("LLM.managed", "Ergopti's Ollama did not stop; nothing is removed.")
	return Done.Call(Stopped is Integer && Stopped == true)
}

/**
 * Removes the managed root, its models folder kept unless the user removes
 * them. A link anywhere below it is refused before anything is removed: a
 * recursive delete would follow it out of the folder Ergopti owns.
 * @param {Boolean} RemoveModels Whether the models folder goes too.
 * @param {Func} Done Receives true once the files are gone.
 * @param {String} Root Managed root; the app folder's one by default.
 */
_LLM_OllamaUninstallRemoveFiles(RemoveModels, Done, Root := "") {
	if Root == ""
		Root := AppFoldersManagedOllamaRoot()
	if !DirExist(Root) {
		LoggerInfo("LLM.managed", "Ergopti's Ollama folder is already absent.")
		return Done.Call(true)
	}
	if InStr(FileGetAttrib(Root), "L") {
		LoggerError("LLM.managed", "Ergopti's Ollama folder is a link; nothing is removed.")
		return Done.Call(false)
	}
	Entries := []
	Loop Files Root . "\*", "FDR" {
		if InStr(A_LoopFileAttrib, "L") {
			LoggerError("LLM.managed", "A link sits in Ergopti's Ollama folder ({1}); nothing is removed.",
				A_LoopFileFullPath)
			return Done.Call(false)
		}
	}
	Loop Files Root . "\*", "FD" {
		if !RemoveModels && A_LoopFileName = "models"
			continue
		Entries.Push(Map("path", A_LoopFileFullPath, "directory", InStr(A_LoopFileAttrib, "D") > 0))
	}
	try {
		for Entry in Entries {
			if Entry["directory"]
				DirDelete(Entry["path"], true)
			else
				FileDelete(Entry["path"])
		}
		if RemoveModels
			DirDelete(Root, false)
	} catch as Err {
		LoggerError("LLM.managed", "Ergopti's Ollama files could not be removed: {1}.", Err.Message)
		return Done.Call(false)
	}
	LoggerInfo("LLM.managed", "Ergopti's Ollama files are removed (models {1}).", RemoveModels ? "removed" : "kept")
	return Done.Call(true)
}

/** @returns {Map} The real ports of an uninstall on this computer. */
_LLM_OllamaUninstallPorts() {
	return Map("busy", _LLM_OllamaUninstallBusy, "delete_models", _LLM_OllamaUninstallDeleteModels,
		"stop", _LLM_OllamaUninstallStop, "remove_files", _LLM_OllamaUninstallRemoveFiles)
}





; ==============================
; ==============================
; ======= 3/ Menu Action =======
; ==============================
; ==============================

/**
 * The « Uninstall Ergopti's Ollama… » row: asks first, then whether the
 * downloaded models go too, then runs the sequence and tells its outcome.
 * @param {Func} ConfirmFn Native question, Ui_MsgBox's signature.
 * @param {Map|Integer} Ports Ports of the sequence; the real ones when 0.
 * @param {Func|Integer} NotifyFn Receives (Body, Title, Level); the notifier when 0.
 * @returns {Boolean} True once the sequence ran.
 */
LLM_Menu_OllamaUninstall(ConfirmFn := Ui_MsgBox, Ports := 0, NotifyFn := 0) {
	if ConfirmFn.Call(t("ollama.uninstall.confirm_body"), t("ollama.uninstall.confirm_title"),
			"OKCancel Icon! Default2") != "OK"
		return false
	Choice := ConfirmFn.Call(t("ollama.uninstall.models_body"), t("ollama.uninstall.models_title"),
		"YesNoCancel Icon? Default2")
	if Choice != "Yes" && Choice != "No"
		return false
	if !(Ports is Map)
		Ports := _LLM_OllamaUninstallPorts()
	if !HasMethod(NotifyFn, "Call")
		NotifyFn := _LLM_OllamaUninstallNotify
	LoggerStart("LLM.managed", "Uninstalling Ergopti's Ollama (models {1})…", Choice == "Yes" ? "removed" : "kept")
	LLM_OllamaUninstallRun(Choice == "Yes", Ports, Told)
	return true

	Told(Result) {
		if Result["ok"] {
			LoggerSuccess("LLM.managed", "Ergopti's Ollama is uninstalled.")
			return NotifyFn.Call(t(Result["message"]), t("ollama.uninstall.done_title"), "success")
		}
		LoggerError("LLM.managed", "The uninstall of Ergopti's Ollama stopped at its '{1}' step.", Result["step"])
		return NotifyFn.Call(t(Result["message"]), t("ollama.uninstall.failed_title"), "error")
	}
}

_LLM_OllamaUninstallNotify(Body, Title, Level) {
	return NotifierSend(Body, Map("title", Title, "level", Level))
}
