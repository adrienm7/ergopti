; tests/unit/modules/hotstrings/engine/test_hotstring_output_tokens.ahk

; ==============================================================================
; MODULE: Tokens of a Hotstring Output (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/output_token_vectors.json through
; SendInputParseOutput, which the macOS and Linux suites replay too, then fires
; entries through the loaders' one registrar and reads the exact burst.
;
; ROOT CAUSE ENCODED:
; No loader told the factories what an output was, so every TOML entry kept their
; default OnlyText = true and went out under {Text}: {Left} from the editor's own
; help line was typed as six characters, and so were the shipped {U+XXXX} symbols.
; ==============================================================================

#Requires AutoHotkey v2.0

_HOT_ReplayCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\hotstrings\output_token_vectors.json"
	AssertTrue(FileExist(Path) != "", "the output token corpus must exist at " . Path)
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	Checked := 0
	for _, Vector in Corpus["vectors"] {
		Parsed := SendInputParseOutput(Vector["output"])
		AssertEqual(Vector["text"], Parsed["text"], Vector["id"] . ": typed text")
		AssertEqual(Vector["has_keys"] ? true : false, Parsed["has_keys"] ? true : false,
			Vector["id"] . ": has_keys")
		AssertEqual(_HOT_ExpectedShape(Vector["tokens"]), _HOT_ActualShape(Parsed["tokens"]),
			Vector["id"] . ": tokens")
		Checked += 1
	}
	AssertTrue(Checked >= 40, "expected at least 40 output token vectors, found " . Checked)
}
Test("hotstring output: the grammar replays the shared corpus (hs-output-tokens)", _HOT_ReplayCorpus)

_HOT_ExpectedShape(Tokens) {
	Out := ""
	for _, Token in Tokens
		Out .= Token.Has("key") ? "<" . Token["key"] . "*" . Token["count"] . ">" : "[" . Token["text"] . "]"
	return Out
}

_HOT_ActualShape(Tokens) {
	Out := ""
	for _, Token in Tokens
		Out .= Token["kind"] == "key" ? "<" . Token["id"] . "*" . Token["count"] . ">" : "[" . Token["value"] . "]"
	return Out
}

global _HOT_Bursts := []

_HOT_Record(Keys) {
	global _HOT_Bursts
	_HOT_Bursts.Push(Keys)
	return 1
}

; Fires Typed on a clean engine holding one entry registered the way every loader
; registers it, and returns the one burst it sent.
_HOT_Fire(IsCaseSensitive, Flags, Trigger, Output, Typed, Options := 0) {
	global _AHK_SendInput, _HOT_Bursts
	_AHK_SendInput := _HOT_Record
	_HOT_Bursts := []
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	Opts := IsObject(Options) ? Options : Map()
	Opts["Priority"] := HSE_PRIORITY_COMMON
	HSE_RegisterFromTomlFlags(IsCaseSensitive, Flags, Trigger, Output, Opts)
	_HCA_Type(Typed)
	AssertEqual(1, _HOT_Bursts.Length, "'" . Typed . "' must fire exactly one burst")
	return _HOT_Bursts[1]
}

_HOT_LeftIsPressedImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary
	AssertEqual("{BackSpace 2}ab{Left}", _HOT_Fire(true, "*", "qq", "ab{left}", "qq"),
		"an immediate personal entry presses Left instead of typing it")
	AssertEqual("", HSE_Buffer, "the caret moved: the buffer must not hold text it cannot place")
	AssertEqual(false, HSE_StartIsWordBoundary ? true : false, "the next text starts nowhere known")
}
Test("hotstring output: an immediate {left} presses the key (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_LeftIsPressedImpl))

_HOT_EveryPromisedTokenImpl() {
	for Token, Ahk in Map("left", "Left", "RIGHT", "Right", "up", "Up", "down", "Down",
			"home", "Home", "end", "End", "enter", "Enter", "tab", "Tab",
			"backspace", "Backspace", "BackSpace", "Backspace", "delete", "Delete",
			"esc", "Escape", "Escape", "Escape")
		AssertEqual("{BackSpace 2}x{" . Ahk . "}", _HOT_Fire(true, "*", "qq", "x{" . Token . "}", "qq"),
			"{" . Token . "} is a key on the atomic path")
}
Test("hotstring output: every token the editor lists is pressed (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_EveryPromisedTokenImpl))

_HOT_RepeatImpl() {
	AssertEqual('{BackSpace 2}""{Left 2}', _HOT_Fire(true, "*", "qq", '""{Left 2}', "qq"), "a count repeats the key")
}
Test("hotstring output: {left 2} presses it twice (hs-output-tokens)", () => _HCA_Run(1, _HOT_RepeatImpl))

_HOT_TextIsNeverSendSyntaxImpl() {
	AssertEqual("{BackSpace 2}c{+}{+} {!}a {#}b {Asc 94}c{Left}",
		_HOT_Fire(true, "*", "qq", "c++ !a #b ^c{Left}", "qq"),
		"the text beside a token stays text: + is not Shift and ! is not Alt")
}
Test("hotstring output: text beside a token is not Send syntax (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_TextIsNeverSendSyntaxImpl))

_HOT_TerminatorImpl() {
	global HSE_Buffer
	AssertEqual("{BackSpace 3}ab{Left} ", _HOT_Fire(true, "", "qq", "ab{Left}", "qq "),
		"a terminator trigger presses Left and replays the terminator")
	AssertEqual("", HSE_Buffer, "the buffer is forgotten after a terminator trigger too")
	AssertEqual("{BackSpace 3}ab{Left}{!}", _HOT_Fire(true, "", "qq", "ab{Left}", "qq!"),
		"a replayed ! must stay a character, never an Alt press")
}
Test("hotstring output: a terminator trigger replays its character after the token (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_TerminatorImpl))

_HOT_CaseConformImpl() {
	AssertEqual("{BackSpace 2}AB{LEFT}", _HOT_Fire(false, "*", "qq", "ab{Left}", "QQ"),
		"the cased family conforms the text and keeps the key")
	AssertEqual("{BackSpace 2}Ab{Left}", _HOT_Fire(false, "*", "qq", "ab{Left}", "Qq"),
		"Title casing keeps the key")
}
Test("hotstring output: the case conform path keeps the token (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_CaseConformImpl))

_HOT_TextOnlyTokensImpl() {
	global HSE_Buffer
	AssertEqual("{BackSpace 2}{Text}" . Chr(0x27C3), _HOT_Fire(true, "*", "qq", "{U+27C3}", "qq"),
		"a shipped {U+XXXX} is the character")
	AssertEqual(Chr(0x27C3), HSE_Buffer, "a typed character stays in the buffer")
	AssertEqual("{BackSpace 2}{Text}{Left}", _HOT_Fire(true, "*", "qq", "{{}Left}", "qq"),
		"{{}Left} is how the six characters are written")
	AssertEqual("{Left}", HSE_Buffer, "and they are the buffer")
	AssertEqual("{BackSpace 2}{Text}x{foo}y", _HOT_Fire(true, "*", "qq", "x{foo}y", "qq"),
		"an unknown group is text, as documented")
	AssertEqual("x{foo}y", HSE_Buffer, "and it stays in the buffer")
}
Test("hotstring output: {U+XXXX}, {{} and unknown groups are text (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_TextOnlyTokensImpl))

_HOT_ExplicitOptionWinsImpl() {
	AssertEqual("{BackSpace 2}a{Tab}", _HOT_Fire(true, "*", "qq", "a{Tab}", "qq", Map("OnlyText", false)),
		"a caller that already speaks Send syntax is left alone")
	AssertEqual("{BackSpace 2}{Text}a{Tab}", _HOT_Fire(true, "*", "qq", "a{Tab}", "qq", Map("OnlyText", true)),
		"and so is one that asked for text")
}
Test("hotstring output: an explicit OnlyText is not reinterpreted (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_ExplicitOptionWinsImpl))

_HOT_CacheRowsImpl() {
	global _AHK_SendInput, _HOT_Bursts, ScriptInformation
	_AHK_SendInput := _HOT_Record
	_HOT_Bursts := []
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	; The cached row of a shipped typst symbol: flags, trigger, output, final, repeat,
	; is_case_sensitive, priority.
	_HsCacheRegisterRows("magickey.tokens", [["*C", "qq", "{U+2011}", false, false, true, ""]],
		{ TimeActivationSeconds: 0 }, 0)
	_HCA_Type("qq")
	AssertEqual(1, _HOT_Bursts.Length, "the cached row fires")
	AssertEqual("{BackSpace 2}{Text}" . Chr(0x2011), _HOT_Bursts[1], "the shipped symbol is typed, not its code")
}
Test("hotstring output: a cached shipped row decodes its code point (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_CacheRowsImpl))

_HOT_CascadeImpl() {
	global _HCA_Screen, _AHK_SendInput, _HOT_Bursts
	_AHK_SendInput := _HOT_Record
	_HOT_Bursts := []
	HSE_RegisterFromTomlFlags(true, "*?", "ab", "cd", Map("Priority", HSE_PRIORITY_COMMON))
	HSE_RegisterFromTomlFlags(true, "*?", "cd", "ef{Left}", Map("Priority", HSE_PRIORITY_COMMON))
	_HCA_Type("ab")
	AssertEqual("{BackSpace 2}{Text}cd", _HOT_Bursts[1], "a key token never joins a chain as a link")
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	_HOT_Bursts := []
	HSE_RegisterFromTomlFlags(true, "*?", "gh", "ij{Left}", Map("Priority", HSE_PRIORITY_COMMON))
	HSE_RegisterFromTomlFlags(true, "*?", "ij", "never", Map("Priority", HSE_PRIORITY_COMMON))
	_HCA_Type("gh")
	AssertEqual("{BackSpace 2}ij{Left}", _HOT_Bursts[1], "nor starts one")
}
Test("hotstring output: a key token takes no part in a cascade (hs-output-tokens)",
	() => _HCA_Run(3, _HOT_CascadeImpl))

_HOT_NotepadImpl() {
	global KLHook, HSE_Buffer, _AHK04_SendCalls
	HSE_RegistryClear()
	HSE_RegisterFromTomlFlags(true, "*", "ab", "x{Left}", Map("Priority", HSE_PRIORITY_COMMON))
	Registered := HSE_RegistryByLastChar["b"][1]
	KLHook.prev_app := "notepad.exe"
	OutputHostResolverPrimeForTest("notepad.exe")
	HSE_Buffer := "ab"
	_AHK04_SetSendVerdict(true)
	AssertEqual(true, HSE_DispatchMatch(Registered, ""), "the entry fires in Notepad")
	AssertEqual(1, _AHK04_SendCalls.Length, "one atomic burst, never the literal native edit")
	AssertEqual("{BackSpace 2}x{Left}", _AHK04_SendCalls[1].Args[1],
		"Notepad's native edit can only insert text, so a key token keeps the Send route")
	AssertEqual("", HSE_Buffer, "the caret moved")
}
Test("hotstring output: Notepad presses the token through the Send route (hs-output-tokens)",
	() => _AHK04_RunIsolated(_HOT_NotepadImpl))

_HOT_TerminalPayloadSource() {
	Source := FileRead(A_ScriptDir . "\..\infra\hotstrings\hotstring_dispatch.ahk", "UTF-8")
	Escape := InStr(Source, "EndCharPart := SendEscapeLiteral(EndCharPart)")
	Payload := InStr(Source, '"SendPayload", ReplacementPart . EndCharPart')
	AssertTrue(Escape > 0 and Payload > Escape,
		"the paced terminal owner replays the end character through the same escaped part as the atomic burst")
}
Test("hotstring output: the terminal owner escapes the replayed end character (hs-output-tokens)",
	_HOT_TerminalPayloadSource)

_HOT_PrivateImpl() {
	HSE_RegistryClear()
	HSE_RegisterFromTomlFlags(true, "*", "ab", "secret{Left}",
		Map("Priority", HSE_PRIORITY_COMMON, "IsPrivate", true))
	Spec := HSE_RegistryByLastChar["b"][1]
	AssertEqual(true, Spec.IsPrivate ? true : false, "a private entry keeps its marker through the token path")
	AssertEqual(false, Spec.OnlyText ? true : false, "and is a Send payload")
}
Test("hotstring output: a private entry stays private (hs-output-tokens)",
	() => _HCA_Run(1, _HOT_PrivateImpl))
