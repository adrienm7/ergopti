; tests/unit/modules/hotstrings/engine/test_hotstring_cascade.ahk

; ==============================================================================
; MODULE: Hotstring cascade (hotstring-cascade)
; DESCRIPTION:
; With hotstrings.cascade_max_arrows above 1 the text a hotstring produced may
; complete further hotstrings: « chatg » gives « chatgpt » and « chatgpt » gives
; « ChatGPT », so typing « chatg » ends on « ChatGPT » from 2 arrows. The chain is
; resolved before anything is sent, so the whole chain is ONE SendInput burst
; and the engine buffer follows the screen. Pinned: 1 arrow is today's
; behaviour, 2 and 3 arrows, the same-spec guard, a FinalResult link, a link that
; reaches back into typed text, an end character that is replayed, a private
; link, a replacement with Send syntax, and Backspace over the chained output.
; The same scenarios are pinned on macOS (test_hotstring_cascade.lua) and Linux
; (test_hotstring_cascade.lua).
;
; SCOPE:
;   Headless (CI): the real engine and dispatcher with a virtual screen that
;   applies the injected burst, so the final document is asserted.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Headless harness =======
; ===================================
; ===================================

global _HCA_Screen := ""
global _HCA_Bursts := 0
global _HCA_Levels := []

; Applies one injected burst to the virtual screen: {BackSpace N}, {Text}...
_HCA_ApplyBurst(Keys) {
	global _HCA_Screen, _HCA_Bursts, _HCA_Levels
	_HCA_Bursts += 1
	_HCA_Levels.Push(A_SendLevel)
	Pos := 1
	while (Pos <= StrLen(Keys)) {
		if RegExMatch(Keys, "^\{BackSpace (\d+)\}", &Backspace, Pos) {
			Count := Integer(Backspace[1])
			loop Count
				_HCA_Screen := SubStr(_HCA_Screen, 1, StrLen(_HCA_Screen) - _TextTailCodeUnits(_HCA_Screen, 1))
			Pos += StrLen(Backspace[0])
		} else if (SubStr(Keys, Pos, 6) == "{Text}") {
			_HCA_Screen .= SubStr(Keys, Pos + 6)
			break
		} else {
			_HCA_Screen .= SubStr(Keys, Pos)
			break
		}
	}
}

_HCA_SendInput(Keys) {
	_HCA_ApplyBurst(Keys)
	return 1
}

; Runs Callback on a clean engine with the send primitive on the virtual screen
; and the cascade at Arrows arrows.
_HCA_Run(Depth, Callback) {
	_AHK04_RunIsolated(_HCA_Body.Bind(Depth, Callback))
}

_HCA_Body(Depth, Callback) {
	global _AHK_SendInput, _SendHook, _HotstringRegistrar, _HCA_Screen, _HCA_Bursts, _HCA_Levels
	global HSE_CascadeMaxArrows
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	SavedDepth := HSE_CascadeMaxArrows
	SavedLevel := A_SendLevel
	_HCA_Screen := ""
	_HCA_Bursts := 0
	_HCA_Levels := []
	_SendHook := 0
	_HotstringRegistrar := 0
	_AHK_SendInput := _HCA_SendInput
	HSE_CascadeMaxArrows := Depth
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	try
		Callback.Call()
	finally {
		SendLevel(SavedLevel)
		_AHK_SendInput := SavedInput
		_SendHook := SavedHook
		_HotstringRegistrar := SavedRegistrar
		HSE_CascadeMaxArrows := SavedDepth
		HSE_RegistryClear()
		HSE_HardReset()
	}
}

; Types Text the way the prefix watcher sees it: the character reaches the screen,
; is timed, is fed to the engine, and the match it completes is dispatched.
_HCA_Type(Text) {
	global _HCA_Screen
	for Char in StrSplit(Text) {
		_HCA_Screen .= Char
		AppState_TouchLastSentKey(Char)
		Match := HSE_FeedChar(Char, true)
		if !IsObject(Match)
			continue
		Effect := 0
		HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect)
	}
}

_HCA_Register(Flags, Trigger, Text, Extra := 0) {
	Opts := Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON)
	if IsObject(Extra)
		for Key, Value in Extra
			Opts[Key] := Value
	CreateHotstring(Flags, Trigger, Text, Opts)
}

; The maintainer's example: chatg gives chatgpt, chatgpt gives ChatGPT.
_HCA_RegisterChatGpt() {
	_HCA_Register("*?", "chatg", "chatgpt")
	_HCA_Register("*?C", "chatgpt", "ChatGPT")
}

_HCA_RegisterThree() {
	_HCA_Register("*?", "ab", "cd")
	_HCA_Register("*?", "cd", "ef")
	_HCA_Register("*?", "ef", "gh")
}





; ============================================
; ============================================
; ======= 2/ Headless regression tests =======
; ============================================
; ============================================

_HCA_DepthZeroImpl() {
	global _HCA_Screen, _HCA_Bursts
	_HCA_RegisterChatGpt()
	_HCA_Type("chatg")
	AssertEqual("chatgpt", _HCA_Screen, "one arrow keeps today's behaviour: the output is final")
	AssertEqual(1, _HCA_Bursts, "one keystroke, one burst")
	AssertEqual("chatgpt", HSE_Buffer, "the buffer follows the screen")
}

_HCA_DepthZero() {
	_HCA_Run(1, _HCA_DepthZeroImpl)
}

_HCA_DepthOneImpl() {
	global _HCA_Screen, _HCA_Bursts
	_HCA_RegisterChatGpt()
	_HCA_Type("chatg")
	AssertEqual("ChatGPT", _HCA_Screen, "two arrows complete chatgpt from the output of chatg")
	AssertEqual(1, _HCA_Bursts, "the whole chain is ONE burst: nothing is typed twice")
	AssertEqual("ChatGPT", HSE_Buffer, "the buffer follows the chain")
}

_HCA_DepthOne() {
	_HCA_Run(2, _HCA_DepthOneImpl)
}

_HCA_DepthBoundsImpl(Depth, Expected) {
	global _HCA_Screen, _HCA_Bursts
	_HCA_RegisterThree()
	_HCA_Type("ab")
	AssertEqual(Expected, _HCA_Screen, Depth . " arrows allow exactly that many expansions")
	AssertEqual(1, _HCA_Bursts, "one burst whatever the arrow count")
}

_HCA_DepthOneOfThree() {
	_HCA_Run(2, _HCA_DepthBoundsImpl.Bind(2, "ef"))
}

_HCA_DepthTwoOfThree() {
	_HCA_Run(3, _HCA_DepthBoundsImpl.Bind(3, "gh"))
}

; A replacement that ends with its own trigger fires once per chain.
_HCA_SelfTriggerImpl() {
	global _HCA_Screen, _HCA_Bursts
	_HCA_Register("*?", "qz", "qz qz")
	_HCA_Type("qz")
	AssertEqual("qz qz", _HCA_Screen, "the same spec never fires twice in one chain")
	AssertEqual(1, _HCA_Bursts, "one burst")
}

_HCA_SelfTrigger() {
	_HCA_Run(6, _HCA_SelfTriggerImpl)
}

; The same rule in another case is the same spec.
_HCA_SelfTriggerCaseImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "qz", "xQZ")
	_HCA_Type("qz")
	AssertEqual("xQZ", _HCA_Screen, "QZ is the rule that just fired, case aside")
}

_HCA_SelfTriggerCase() {
	_HCA_Run(6, _HCA_SelfTriggerCaseImpl)
}

; A FinalResult link ends the chain, and a FinalResult first hotstring starts none.
_HCA_FinalResultImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "ab", "cd", Map("FinalResult", true))
	_HCA_Register("*?", "cd", "ef")
	_HCA_Type("ab")
	AssertEqual("cd", _HCA_Screen, "nothing may chain off a final result")
}

_HCA_FinalResult() {
	_HCA_Run(4, _HCA_FinalResultImpl)
}

_HCA_FinalLinkImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "ab", "cd")
	_HCA_Register("*?", "cd", "ef", Map("FinalResult", true))
	_HCA_Register("*?", "ef", "gh")
	_HCA_Type("ab")
	AssertEqual("ef", _HCA_Screen, "cd fired, ef is the final link: gh never")
}

_HCA_FinalLink() {
	_HCA_Run(4, _HCA_FinalLinkImpl)
}

; A later link may reach back over text typed before the first trigger.
_HCA_ReachBackImpl() {
	global _HCA_Screen, _HCA_Bursts
	_HCA_Register("*?", "ab", "cd")
	_HCA_Register("*?", "xcd", "YZ")
	_HCA_Type("xab")
	AssertEqual("YZ", _HCA_Screen, "xcd is completed by the first output and erases the typed x too")
	AssertEqual(1, _HCA_Bursts, "one burst")
	AssertEqual("YZ", HSE_Buffer, "the buffer follows the screen")
}

_HCA_ReachBack() {
	_HCA_Run(2, _HCA_ReachBackImpl)
}

; An end-character hotstring chains into another end-character one with the same
; end character, replayed once.
_HCA_EndCharImpl() {
	global _HCA_Screen, _HCA_Bursts
	_HCA_Register("?", "ab", "cd")
	_HCA_Register("?", "cd", "ef")
	_HCA_Type("ab ")
	AssertEqual("ef ", _HCA_Screen, "the same space ends the second link and is replayed once")
	AssertEqual(1, _HCA_Bursts, "one burst")
	AssertEqual("ef ", HSE_Buffer, "the buffer follows the screen")
}

_HCA_EndChar() {
	_HCA_Run(2, _HCA_EndCharImpl)
}

_HCA_EndCharDepthZeroImpl() {
	global _HCA_Screen
	_HCA_Register("?", "ab", "cd")
	_HCA_Register("?", "cd", "ef")
	_HCA_Type("ab ")
	AssertEqual("cd ", _HCA_Screen, "one arrow leaves the second link to the next end character")
}

_HCA_EndCharDepthZero() {
	_HCA_Run(1, _HCA_EndCharDepthZeroImpl)
}

; A link that would swallow the replayed end character ends the chain instead.
_HCA_SwallowedEndCharImpl() {
	global _HCA_Screen
	_HCA_Register("?", "ab", "cd")
	_HCA_Register("*?", "cd ", "X")
	_HCA_Type("ab ")
	AssertEqual("cd ", _HCA_Screen, "a link may not swallow the end character the user typed")
}

_HCA_SwallowedEndChar() {
	_HCA_Run(2, _HCA_SwallowedEndCharImpl)
}

; A private (personal information) hotstring never takes part.
_HCA_PrivateImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "ab", "cd")
	_HCA_Register("*?", "cd", "ef", Map("IsPrivate", true))
	_HCA_Type("ab")
	AssertEqual("cd", _HCA_Screen, "a private link is not composed into another hotstring's output")
}

_HCA_Private() {
	_HCA_Run(2, _HCA_PrivateImpl)
}

_HCA_PrivateFirstImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "ab", "cd", Map("IsPrivate", true))
	_HCA_Register("*?", "cd", "ef")
	_HCA_Type("ab")
	AssertEqual("cd", _HCA_Screen, "a private hotstring starts no chain")
}

_HCA_PrivateFirst() {
	_HCA_Run(2, _HCA_PrivateFirstImpl)
}

; Send syntax leaves text the engine cannot describe: not a link.
_HCA_SendSyntaxImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "ab", "cd")
	_HCA_Register("*?", "cd", "ef{Left}", Map("OnlyText", false))
	_HCA_Type("ab")
	AssertEqual("cd", _HCA_Screen, "a replacement with Send syntax takes no part in a chain")
}

_HCA_SendSyntax() {
	_HCA_Run(2, _HCA_SendSyntaxImpl)
}

; Backspace over the chained output unwinds one character of the FINAL text,
; and retyping chains again.
_HCA_BackspaceImpl() {
	global _HCA_Screen
	_HCA_RegisterChatGpt()
	_HCA_Type("chatg")
	AssertEqual("ChatGPT", HSE_Buffer, "the buffer must hold the chained output")
	HSE_FeedBackspace(true, true)
	_HCA_Screen := SubStr(_HCA_Screen, 1, StrLen(_HCA_Screen) - 1)
	AssertEqual("ChatGP", HSE_Buffer, "a Backspace erases one character of the final text")
	_HCA_Type("T")
	AssertEqual("ChatGPT", _HCA_Screen, "retyping the erased character leaves the document as it was")
}

_HCA_Backspace() {
	_HCA_Run(2, _HCA_BackspaceImpl)
}

; The setting: a valid arrow count is a whole number from 1 to 10; the default is 3.
_HCA_SettingImpl() {
	AssertTrue(HSE_ValidCascadeMaxArrows(1), "1 is a single expansion")
	AssertTrue(HSE_ValidCascadeMaxArrows(10), "10 is the longest chain")
	AssertTrue(HSE_ValidCascadeMaxArrows(3), "a whole number in range is valid")
	AssertFalse(HSE_ValidCascadeMaxArrows(0), "zero arrows is not a chain")
	AssertFalse(HSE_ValidCascadeMaxArrows(11), "ten is the longest chain")
	AssertFalse(HSE_ValidCascadeMaxArrows(-1), "a negative count is refused")
	AssertFalse(HSE_ValidCascadeMaxArrows(1.5), "a fraction is refused")
	AssertFalse(HSE_ValidCascadeMaxArrows("2"), "a string is refused")
	AssertEqual(3, ManifestDefaultFor("hotstrings.cascade_max_arrows"),
		"three arrows is the manifest default")
	AssertEqual(HSE_CASCADE_MIN_ARROWS, 1)
	AssertEqual(HSE_CASCADE_MAX_ARROWS, 10)
}

_HCA_Setting() {
	_HCA_SettingImpl()
}

; The setter persists the whole number under [hotstrings] and publishes it to the
; engine at once; an invalid depth is never written.
global _HCA_Writes := []

_HCA_Writer(Path, Updates) {
	global _HCA_Writes
	_HCA_Writes.Push(Updates[1])
	return true
}

_HCA_SetterPersistsAndPublishes() {
	global Features, HSE_CascadeMaxArrows, _HCA_Writes
	Hotstrings := Features["hotstrings"]
	HadLeaf := Hotstrings.Has("cascade_max_arrows")
	SavedLeaf := HadLeaf ? Hotstrings["cascade_max_arrows"] : ""
	SavedDepth := HSE_CascadeMaxArrows
	try {
		_HCA_Writes := []
		AssertTrue(SetHotstringsCascadeMaxArrows(2, _HCA_Writer, (*) => 0, (*) => 1))
		AssertEqual(2, HSE_CascadeMaxArrows, "the engine reads the new depth at once")
		AssertEqual(1, _HCA_Writes.Length)
		AssertEqual("hotstrings", _HCA_Writes[1].Section)
		AssertEqual("cascade_max_arrows", _HCA_Writes[1].Key)
		AssertEqual(2, _HCA_Writes[1].Value)
		AssertFalse(SetHotstringsCascadeMaxArrows(0, _HCA_Writer, (*) => 0, (*) => 1),
			"zero arrows are never written")
		AssertFalse(SetHotstringsCascadeMaxArrows(11, _HCA_Writer, (*) => 0, (*) => 1),
			"more than ten arrows are never written")
		AssertFalse(SetHotstringsCascadeMaxArrows(1.5, _HCA_Writer, (*) => 0, (*) => 1),
			"a fractional depth is never written")
		AssertEqual(1, _HCA_Writes.Length)
		AssertEqual(2, HSE_CascadeMaxArrowsCurrent(), "a refused depth leaves the published one")
	} finally {
		HSE_CascadeMaxArrows := SavedDepth
		if HadLeaf
			Hotstrings["cascade_max_arrows"] := SavedLeaf
		else if Hotstrings.Has("cascade_max_arrows")
			Hotstrings.Delete("cascade_max_arrows")
	}
}

; The loader (infra/feature_state.ahk) is not part of the headless suite, so its
; reader _FeatureStateCascadeMaxArrows cannot be called here. Its rule is the
; engine's HSE_ValidCascadeMaxArrows, checked on the cases the reader must accept
; or fall back from, while the source pins that the loader restates the same rule
; and reads the arrow-count leaf through the generated constants.
_HCA_LoaderReadsTheDepth() {
	global HSE_CascadeMaxArrows
	AssertTrue(HSE_ValidCascadeMaxArrows(5), "a stored whole number is kept")
	AssertTrue(HSE_ValidCascadeMaxArrows(1), "1 stays 1")
	AssertFalse(HSE_ValidCascadeMaxArrows(0), "0 is outdated configuration")
	AssertFalse(HSE_ValidCascadeMaxArrows(11), "11 is outdated configuration")
	AssertFalse(HSE_ValidCascadeMaxArrows(-2), "a negative count is outdated configuration")
	AssertFalse(HSE_ValidCascadeMaxArrows("deep"), "a string is outdated configuration")
	AssertFalse(HSE_ValidCascadeMaxArrows(1.5), "a fraction is outdated configuration")
	Saved := HSE_CascadeMaxArrows
	try {
		HSE_CascadeMaxArrows := ""
		AssertEqual(3, HSE_CascadeMaxArrowsCurrent(), "before the loader ran the engine reads the manifest default")
	} finally HSE_CascadeMaxArrows := Saved
	Source := FileRead(A_ScriptDir . "\..\infra\feature_state.ahk", "UTF-8")
	AssertTrue(InStr(Source, "_FeatureStateCascadeMaxArrows(") > 0
		&& InStr(Source, "ConfigLeaf.CASCADE_MAX_ARROWS") > 0
		&& InStr(Source, "(Raw is Integer) and Raw >= 1 and Raw <= 10") > 0,
		"the loader reads the arrow-count leaf and restates the engine's validity rule")
}

; The Space tap-hold completes a trigger from its level-2 hotkey thread (see
; hotstring-output-is-final): a cascaded burst must still go out ONCE, at level 0,
; so it can never come back through the prefix watcher and cascade a second time.
_HCA_Level2ThreadImpl() {
	global _HCA_Screen, _HCA_Bursts, _HCA_Levels
	_HCA_RegisterChatGpt()
	SendLevel(2)
	_HCA_Type("chatg")
	AssertEqual("ChatGPT", _HCA_Screen, "the chain completes from a level-2 thread")
	AssertEqual(1, _HCA_Bursts, "one burst: the output is never fed back as typed input")
	AssertEqual(0, _HCA_Levels[1], "the burst goes out at level 0, not the caller's level 2")
}

_HCA_Level2Thread() {
	_HCA_Run(3, _HCA_Level2ThreadImpl)
}

; A consumed delimiter still lets the end-character chain run, then swallows the
; end character once: the chain is the same, only the trailing space is dropped.
_HCA_ConsumedEndCharImpl() {
	global _HCA_Screen, _HCA_Bursts, HSE_CONSUMED_DELIMITERS
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	HSE_CONSUMED_DELIMITERS := " "
	try {
		_HCA_Register("?", "ab", "cd")
		_HCA_Register("?", "cd", "ef")
		_HCA_Type("ab ")
		AssertEqual("ef", _HCA_Screen, "the chain ran and the consumed space is swallowed once")
		AssertEqual(1, _HCA_Bursts, "one burst")
		AssertEqual("ef", HSE_Buffer, "the buffer follows the screen")
	} finally HSE_CONSUMED_DELIMITERS := SavedConsumed
}

_HCA_ConsumedEndChar() {
	_HCA_Run(3, _HCA_ConsumedEndCharImpl)
}

; A word-start-only link never fires in the middle of a word: facebook ends with
; ok, but the chain does not turn it into faceboOK.
_HCA_WordStartLinkImpl() {
	global _HCA_Screen
	_HCA_Register("*?", "fb", "facebook")
	_HCA_Register("*", "ok", "OK", Map("OnlyText", true))
	_HCA_Type("fb")
	AssertEqual("facebook", _HCA_Screen, "a word-start-only link does not fire inside facebook")
}

_HCA_WordStartLink() {
	_HCA_Run(3, _HCA_WordStartLinkImpl)
}

; The shared corpus (_shared/tests/corpus/hotstrings/cascade_vectors.json): the
; same rules, keystrokes and expected text on the three drivers.
_HCA_CorpusVectors() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\cascade_vectors.json"
	if !FileExist(Path)
		throw Error("shared corpus not found at '" . Path . "'")
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	if !(Corpus is Map) or !Corpus.Has("vectors") or Corpus["vectors"].Length = 0
		throw Error("shared corpus 'cascade_vectors.json' has no vectors")
	return Corpus["vectors"]
}

_HCA_ReplayVector(Vector) {
	global _HCA_Screen, _HCA_Bursts, HSE_CONSUMED_DELIMITERS, HSE_WORD_TERMINATORS
	for Rule in Vector["rules"] {
		Flags := (Rule["auto"] ? "*" : "") . (Rule["word_start"] ? "" : "?")
			. (Rule.Has("case_sensitive") and Rule["case_sensitive"] ? "C" : "")
		_HCA_Register(Flags, Rule["trigger"], Rule["replacement"])
	}
	EndChar := Vector["end_char"]
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	SavedTerminators := HSE_WORD_TERMINATORS
	try {
		if (EndChar != "") {
			if !InStr(HSE_WORD_TERMINATORS, EndChar)
				HSE_WORD_TERMINATORS .= EndChar
			HSE_CONSUMED_DELIMITERS := Vector["end_char_consumed"] ? EndChar : ""
		}
		_HCA_Type(Vector["typed"] . EndChar)
		AssertEqual(Vector["expect_buffer"], HSE_Buffer, Vector["id"] . ": " . Vector["description"])
		AssertEqual(Vector["expect_buffer"], _HCA_Screen, Vector["id"] . ": the screen follows the buffer")
		AssertEqual(Vector["expect_expansions"], _HCA_Bursts, Vector["id"] . ": one burst for the whole chain")
	} finally {
		HSE_CONSUMED_DELIMITERS := SavedConsumed
		HSE_WORD_TERMINATORS := SavedTerminators
	}
}

_HCA_ReplaysTheCorpus() {
	for Vector in _HCA_CorpusVectors()
		_HCA_Run(Vector["max_arrows"], _HCA_ReplayVector.Bind(Vector))
}

Test("hotstring cascade: one arrow is today's behaviour, the output is final (hotstring-cascade)",
	_HCA_DepthZero)
Test("hotstring cascade: two arrows give ChatGPT from chatg in one burst (hotstring-cascade)",
	_HCA_DepthOne)
Test("hotstring cascade: two arrows stop after one more link (hotstring-cascade)",
	_HCA_DepthOneOfThree)
Test("hotstring cascade: three arrows go two links further (hotstring-cascade)",
	_HCA_DepthTwoOfThree)
Test("hotstring cascade: a replacement ending with its own trigger cannot loop (hotstring-cascade)",
	_HCA_SelfTrigger)
Test("hotstring cascade: the same-spec guard folds case (hotstring-cascade)",
	_HCA_SelfTriggerCase)
Test("hotstring cascade: a FinalResult first hotstring starts no chain (hotstring-cascade)",
	_HCA_FinalResult)
Test("hotstring cascade: a FinalResult link ends the chain (hotstring-cascade)",
	_HCA_FinalLink)
Test("hotstring cascade: a later link reaches back over the typed text (hotstring-cascade)",
	_HCA_ReachBack)
Test("hotstring cascade: an end-character link chains and replays the end character once (hotstring-cascade)",
	_HCA_EndChar)
Test("hotstring cascade: one arrow leaves the end-character chain to the next key (hotstring-cascade)",
	_HCA_EndCharDepthZero)
Test("hotstring cascade: a link that would swallow the end character ends the chain (hotstring-cascade)",
	_HCA_SwallowedEndChar)
Test("hotstring cascade: a private link is never composed (hotstring-cascade)",
	_HCA_Private)
Test("hotstring cascade: a private first hotstring starts no chain (hotstring-cascade)",
	_HCA_PrivateFirst)
Test("hotstring cascade: a replacement with Send syntax is not a link (hotstring-cascade)",
	_HCA_SendSyntax)
Test("hotstring cascade: Backspace unwinds the final text, retyping restores it (hotstring-cascade)",
	_HCA_Backspace)
Test("hotstring cascade: the arrow count is a whole number from 1 to 10, default 3 (hotstring-cascade)",
	_HCA_Setting)
Test("hotstring cascade: the setter persists and publishes the arrow count (hotstring-cascade)",
	(*) => _HICR_WithFixture(_HCA_SetterPersistsAndPublishes))
Test("hotstring cascade: the loader reads the arrow count or the default (hotstring-cascade)",
	_HCA_LoaderReadsTheDepth)
Test("hotstring cascade: from the Space tap-hold's level-2 thread the chain is one level-0 burst (hotstring-cascade)",
	_HCA_Level2Thread)
Test("hotstring cascade: a consumed delimiter lets the chain run and is swallowed once (hotstring-cascade)",
	_HCA_ConsumedEndChar)
Test("hotstring cascade: a word-start-only link does not fire in the middle of a word (hotstring-cascade)",
	_HCA_WordStartLink)
Test("hotstring cascade: the shared cascade_vectors corpus (hotstring-cascade)",
	_HCA_ReplaysTheCorpus)
