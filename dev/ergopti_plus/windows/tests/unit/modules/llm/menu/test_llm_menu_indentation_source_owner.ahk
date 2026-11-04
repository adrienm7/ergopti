; tests/unit/modules/llm/menu/test_llm_menu_indentation_source_owner.ahk

; ==============================================================================
; MODULE: LLM Indentation Source Ownership Tests
; DESCRIPTION:
; The actual native callback retains its admitted source through a real
; canonical publication, including an external edit at the terminal writer.
; ==============================================================================

#Requires AutoHotkey v2.0

; Optional arguments let the old caller execute its fresh read, rather than
; fail with an argument-count error before the actual persistence boundary.
_LMT_IndentSuccessorWrite(Mode, Seen, Path, Updates, Content := unset, Presence := unset) {
	Seen["calls"] += 1
	Seen["witness"] := IsSet(Content) && IsSet(Presence)
	if Seen["witness"] {
		AssertEqual(1, Presence)
		AssertEqual(Seen["initial"], Content, "the native writer receives the exact admitted image")
	}
	AssertTrue(_ConfigWriteLeaseOwns(_ConfigWriteLeaseCurrent(Path), Path), "the real borrowed lease owns this write")
	if Mode == "edited"
		AssertTrue(FSWriteDurable(Path, Seen["successor"]))
	else if Mode == "deleted"
		FileDelete(Path)
	Result := TOML_ConfigBatchWrite(Path, Updates, [], 0, Content?, Presence?)
	Seen["native_ack"] := Result is Integer && Result == 1
	return Result
}

_LMT_IndentSuccessor(Mode) {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls, _MenuDispatchCallbacks
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	Path := _LMT_InfoBarPrivatePath()
	Previous := _LMT_InstallFixture(Path), PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	Built := 0
	try {
		Suspend(false)
		_LLM_Menu["enabled"] := true
		_LLM_Menu["n_predictions"] := 3
		_LLM_Menu["pred_indent"] := 1
		_LLM_Menu["show_all_at_once"] := false
		_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
		; The helper boots genuine absence once. Materialize A through the real
		; semantic writer, without rewriting any already-prepared boot image.
		AssertTrue(TOML_ConfigBatchWrite(Path, [
			{Section: "llm", Key: "enabled", Value: TOML_Bool(true)},
			{Section: "llm.models", Key: "selected", Value: "ollama"},
			{Section: "llm.profiles", Key: "num_predictions", Value: 3},
			{Section: "llm.display", Key: "pred_indent", Value: 1},
			{Section: "llm.display", Key: "streaming_multi", Value: TOML_Bool(true)},
			{Section: "private", Key: "future", Value: 42}]))
		Initial := FSReadUtf8Exact(Path)
		AssertFalse(_LLM_Menu_IndentSnapshot()["blocked"], "the actual runtime and source admit the choice")
		Successor := TOML_BuildConfigDocumentCandidate(Initial, [
			{Section: "llm.display", Key: "pred_indent", Value: 6},
			{Section: "private", Key: "future", Value: 900}], [])["content"]
		AssertEqual(6, TOML_ParseDocument(Successor)["llm"]["display"]["pred_indent"], "B is valid changed indentation")
		Seen := Map("calls", 0, "initial", Initial, "successor", Successor)
		Writer := _LMT_IndentSuccessorWrite.Bind(Mode, Seen)
		Command := _LMT_IndentObservedCommit.Bind(Writer, Seen)
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, (*) => false, Command)
		Child := _LMT_IndentChild(Built)
		State := DllCall("GetMenuState", "Ptr", Built.Handle, "UInt", Child.Position, "UInt", 0x400, "UInt")
		AssertTrue(State != 0xFFFFFFFF && !(State & 0x3), "the held native menu is actually enabled")
		Id := DllCall("GetMenuItemID", "Ptr", Child.Handle, "Int", 10, "UInt")
		AssertTrue(_MenuDispatchCallbacks.Has(Id), "the real choice owns its native dispatcher")
		Callback := _MenuDispatchCallbacks[Id]
		MenuBefore := _LLM_Menu, EngineBefore := _LLM_Engine
		_LMT_ApplyCalls := 0
		Written := Callback.Call()
		AssertEqual(Mode == "current", Written, "a successor cannot become the authority of the old click")
		AssertEqual(1, Seen["calls"], "the external change occurs at the actual terminal writer boundary")
		AssertEqual(Mode == "current", Seen["native_ack"], "the canonical publisher supplies the real receipt")
		AssertFalse(ConfigWriteLeaseBusy() || _ConfigWriteTerminalIsActive(), "success and refusal release the lease")
		if Mode == "current" {
			Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual(3, Document["llm"]["display"]["pred_indent"])
			AssertEqual(3, _LLM_Menu["pred_indent"])
			AssertEqual(42, Document["private"]["future"])
			AssertEqual(1, _LMT_ApplyCalls, "a confirmed native update still applies once")
		} else {
			AssertTrue(Seen["witness"], "both content and presence reach the terminal writer")
			AssertTrue(_LLM_Menu == MenuBefore && _LLM_Engine == EngineBefore, "refusal preserves exact live objects")
			AssertEqual(1, _LLM_Menu["pred_indent"])
			AssertEqual(1, _LLM_Engine["pred_indent"])
			AssertEqual(0, _LMT_ApplyCalls, "an unconfirmed write cannot apply runtime changes")
			if Mode == "edited"
				AssertEqual(Successor, FSReadUtf8Exact(Path), "B's changed indentation and foreign field remain byte-exact")
			else
				AssertEqual(0, FSStrictExists(Path), "a stale click cannot recreate an externally deleted file")
			AssertFalse(Callback.Call(), "the withdrawn source is refused before another write")
			AssertEqual(1, Seen["calls"])
		}
		Temps := 0
		Loop Files Path . ".*.tmp"
			Temps += 1
		AssertEqual(0, Temps, "the real publisher leaves no abandoned stage")
	} finally {
		try {
			if IsObject(Built)
				_CTC_ReleaseMenu(Built)
			if FileExist(Path)
				FileDelete(Path)
		} finally {
			for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache]
				if Store.Has(Path)
					Store.Delete(Path)
			Suspend(SavedSuspend)
			_LLM_Engine := PreviousEngine
			_LMT_RestoreFixture(Previous)
		}
	}
}
for _LMTIndentSourceMode in ["current", "edited", "deleted"]
	Test("LLM display: indentation " . _LMTIndentSourceMode . " source retains writer authority (llm-indent-source-owner)",
		_LMT_IndentSuccessor.Bind(_LMTIndentSourceMode))
