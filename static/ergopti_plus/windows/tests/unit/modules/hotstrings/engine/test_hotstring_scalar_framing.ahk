; tests/unit/modules/hotstrings/engine/test_hotstring_scalar_framing.ahk

; ==============================================================================
; MODULE: Hotstring Scalar Framing Regressions
; DESCRIPTION:
; Drives the public engine and preview APIs with split UTF-16 observations.
; Completion framing must retain trigger capacity without inventing boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

_HSCF_WithEngine(Mode) {
	global HSE_MAX_BUFFER_LEN, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS, HSE_RepeatEnabled
	global HSE_Suppressed, _PrefixWatcherSuppressed, _PrefixLastKeyTick
	Saved := { Capacity: HSE_MAX_BUFFER_LEN, Words: HSE_WORD_TERMINATORS,
		Consumed: HSE_CONSUMED_DELIMITERS, Repeat: HSE_RepeatEnabled,
		Suppressed: HSE_Suppressed, PrefixSuppressed: _PrefixWatcherSuppressed, Tick: _PrefixLastKeyTick }
	try {
		HSE_TestReset()
		HSE_MAX_BUFFER_LEN := 3
		HSE_WORD_TERMINATORS := " " . Chr(0x1F600)
		HSE_CONSUMED_DELIMITERS := Chr(0x1F600)
		HSE_RepeatEnabled := true
		_HSCF_Run(Mode)
	} finally {
		HSE_MAX_BUFFER_LEN := Saved.Capacity
		HSE_WORD_TERMINATORS := Saved.Words
		HSE_CONSUMED_DELIMITERS := Saved.Consumed
		HSE_RepeatEnabled := Saved.Repeat
		HSE_TestReset()
		HSE_Suppressed := Saved.Suppressed
		_PrefixWatcherSuppressed := Saved.PrefixSuppressed
		_PrefixLastKeyTick := Saved.Tick
	}
}

_HSCF_Register(Trigger, Flags := "C") {
	return HSE_Register(Flags, Trigger, (*) => 0, { Replacement: "RESULT", OnlyText: true })
}

_HSCF_Feed(Text) {
	for Character in _TextCodepoints(Text)
		HSE_FeedChar(Character, true)
}

_HSCF_Run(Mode) {
	global HSE_Buffer, HSE_LastEndChar, HSE_LastMatch, HSE_StartIsWordBoundary
	global HSE_WORD_TERMINATORS, HSE_Suppressed
	Face := Chr(0x1F600), High := SubStr(Face, 1, 1), Low := SubStr(Face, 2, 1)
	if Mode == "capacity-pair" || Mode == "capacity-shared-high" {
		_HSCF_Register("abc")
		_HSCF_Feed("abc")
		AssertFalse(IsObject(HSE_FeedChar(High, true)), "a high half cannot complete the full-capacity END body")
		AssertEqual("abc" . High, HSE_Buffer, "the pending completion must not evict trigger text")
		AssertEqual("", HSE_LastEndChar)
		NextLow := Mode == "capacity-shared-high" ? SubStr(Chr(0x1F601), 2, 1) : Low
		Match := HSE_FeedChar(NextLow, true)
		if Mode == "capacity-shared-high" {
			AssertFalse(IsObject(Match), "sharing a high surrogate does not make another scalar a terminator")
			AssertEqual("", HSE_LastEndChar)
		} else {
			AssertTrue(IsObject(Match), "the completed delimiter must still reach the entire maximum-length body")
			AssertEqual("abc", Match.Trigger)
			AssertEqual("abc" . Face, HSE_Buffer)
			AssertEqual(Face, HSE_LastEndChar, "dispatch framing must contain both units")
			HSE_ApplyExpansion(Match, "R", HSE_LastEndChar)
			AssertEqual("R", HSE_Buffer, "the consumed completion is one complete scalar")
		}
		return
	}
	if Mode == "star-pair" {
		_HSCF_Register("q" . Face, "*C")
		_HSCF_Feed("q")
		AssertFalse(IsObject(HSE_FeedChar(High, true)))
		Match := HSE_FeedChar(Low, true)
		AssertTrue(IsObject(Match), "a complete supplementary STAR suffix must remain eligible")
		AssertEqual("q" . Face, Match.Trigger)
		AssertEqual("", HSE_LastEndChar)
		return
	}
	if Mode == "dead-key-chunk" {
		_HSCF_Register("qrt")
		_HSCF_Feed("qr")
		Match := HSE_FeedChar("t" . Face, true)
		AssertTrue(IsObject(Match), "a complete dead-key chunk must retain its body before the final scalar")
		AssertEqual("qrt", Match.Trigger)
		AssertEqual(Face, HSE_LastEndChar)
		AssertEqual("qrt" . Face, HSE_Buffer)
		return
	}
	if Mode == "discarded-orphan" {
		HSE_FeedChar(High, true)
		_HSCF_Feed("xyz")
		AssertEqual("xyz", HSE_Buffer)
		AssertFalse(HSE_StartIsWordBoundary, "a discarded high half must not impersonate an astral word boundary")
		return
	}
	if Mode == "orphan-before-expansion" {
		_HSCF_Register("qr")
		HSE_FeedChar(High, true)
		_HSCF_Feed("qr")
		AssertFalse(IsObject(HSE_FeedChar(" ", true)), "a predecessor half must not open a word through substring membership")
		return
	}
	if Mode == "orphan-before-repeat" || Mode == "orphan-repeat-body" {
		HSE_WORD_TERMINATORS := " ★"
		if Mode == "orphan-before-repeat"
			_HSCF_Feed(High . "a★")
		else
			_HSCF_Feed("a" . High . "★")
		AssertFalse(IsObject(HSE_TryRepeatKey("★")), "neither a repeated half nor its unknown predecessor may license doubling")
		return
	}
	if Mode == "suppressed-high" {
		_HSCF_Register("qr")
		_HSCF_Feed("qr")
		HSE_Suppressed := 1
		AssertFalse(IsObject(HSE_FeedChar(High)))
		AssertEqual("qr", HSE_Buffer, "suppressed synthetic text must not become pending physical framing")
		HSE_Suppressed := 0
		AssertFalse(IsObject(HSE_FeedChar(Low, true)), "a low half cannot complete a high that was never admitted")
		AssertEqual("", HSE_LastEndChar)
		return
	}
	if Mode == "preview-complete" || Mode == "preview-split" || Mode == "preview-high" {
		_HSCF_Register("qr")
		_HSCF_Feed("xy")
		Before := HSE_Buffer, BeforeEnd := HSE_LastEndChar, BeforeMatch := HSE_LastMatch
		BufferBefore := Mode == "preview-split" ? "qr" . High : "qr"
		Next := Mode == "preview-split" ? Low : (Mode == "preview-high" ? High : Face)
		Decision := HSE_PreviewNextDecision(BufferBefore, Next)
		AssertEqual(Before, HSE_Buffer, "preview must restore the actual live buffer")
		AssertEqual(BeforeEnd, HSE_LastEndChar)
		AssertEqual(BeforeMatch, HSE_LastMatch)
		if Mode == "preview-high"
			AssertFalse(IsObject(Decision), "preview cannot promise completion from a high half")
		else {
			AssertTrue(IsObject(Decision), "both complete and split scalar framing must reach the real preview oracle")
			AssertEqual("qr" . Face, Decision.BufferAfterCompletion)
			AssertEqual(Face, Decision.EndChar)
			AssertEqual(Next, Decision.Completion, "the public preview retains the caller's exact observation")
			AssertEqual("RESULT", Decision.Replacement)
		}
		return
	}
	throw Error("Unknown hotstring scalar framing vector.")
}

for _HSCF_Mode in ["capacity-pair", "capacity-shared-high", "star-pair", "dead-key-chunk", "discarded-orphan",
	"orphan-before-expansion", "orphan-before-repeat", "orphan-repeat-body", "suppressed-high", "preview-complete", "preview-split", "preview-high"]
	Test("HSE scalar framing: " . _HSCF_Mode . " keeps complete decisions (hse-scalar-framing)", _HSCF_WithEngine.Bind(_HSCF_Mode))

_HTEI_Engine(Mode) {
	global HSE_Terminators, _HotstringsTerminatorRecords, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global HSE_MAX_BUFFER_LEN, HSE_RepeatEnabled, HSE_Suppressed, _PrefixWatcherSuppressed, _PrefixLastKeyTick
	global HSE_Buffer, _MAX_BUFFER_LEN
	Saved := {terms: HSE_Terminators, owner: _HotstringsTerminatorRecords, word: HSE_WORD_TERMINATORS,
		consumed: HSE_CONSUMED_DELIMITERS, capacity: HSE_MAX_BUFFER_LEN, prefix_capacity: _MAX_BUFFER_LEN, repeat: HSE_RepeatEnabled,
		suppressed: HSE_Suppressed, prefix_suppressed: _PrefixWatcherSuppressed, tick: _PrefixLastKeyTick}
	; This qualified scope installs detached indexes before any real registry
	; publication and retains the host's exact indexes, buffer and generations.
	RegistryState := _HotstringRegistryScope()
	try {
		HSE_Terminators := Terminators()
		_HotstringsTerminatorRecords := 0
		UnicodeBoundary := InStr(Mode, "unicode-boundary-") == 1
		; Configure the actual detached factory; trigger validation belongs to its boot suite.
		if UnicodeBoundary
			HSE_Terminators.updateMagicKey(Chr(0xC9))
		Both := InStr(Mode, "consume-") == 1 || InStr(Mode, "noop-") == 1
		Source := '[hotstrings]`nterminators = [{key="upper",char="A",label="Upper",consume=true}'
			. (Both ? ',{key="lower",char="a",label="Lower",consume=false}' : "") . ']`n'
		if UnicodeBoundary
			Source := '[hotstrings]`nterminators = [{key="lower-unicode",char="é",label="Lower unicode",consume=false}]`n'
		AssertTrue(HotstringsTerminatorRecordsInit(Source))
		_MAX_BUFFER_LEN := 16
		HSE_RepeatEnabled := false
		Framing := InStr(Mode, "framing-") == 1
		Boundary := InStr(Mode, "boundary-") == 1 || InStr(Mode, "trim-boundary-") == 1
		HSE_MAX_BUFFER_LEN := Framing || InStr(Mode, "trim-boundary-") == 1 ? 2 : 16
		Lower := InStr(Mode, "lower") > 0
		End := Lower ? "a" : "A"
		if UnicodeBoundary {
			HSE_Register("*C", "xy", (*) => 0, {Replacement: "Z", OnlyText: true})
			HSE_FeedChar(Lower ? Chr(0xE9) : Chr(0xC9), true)
			HSE_FeedChar("x", true)
			UnicodeMatch := HSE_FeedChar("y", true)
			AssertEqual(Lower, IsObject(UnicodeMatch), "removing the Unicode magic slot cannot remove its case-distinct custom boundary")
			return
		}
		if InStr(Mode, "preview-") == 1 {
			AssertEqual(Lower ? "axy" : "xy", _PrefixWordTail(End . "xy"),
				"the real preview word tail must use exact delimiter identity")
			return
		}
		Noop := InStr(Mode, "noop-") == 1
		if Boundary {
			HSE_Register("*C", "xy", (*) => 0, {Replacement: "Z", OnlyText: true})
			HSE_FeedChar(End, true)
			HSE_FeedChar("x", true)
			BoundaryMatch := HSE_FeedChar("y", true)
			AssertEqual(!Lower, IsObject(BoundaryMatch), "a case-distinct preceding scalar cannot invent a word boundary")
			return
		}
		if !Framing
			Spec := HSE_Register("C", "xy", (*) => 0, {Replacement: Noop ? "xy" : "Z", OnlyText: true, FinalResult: Noop})
		HSE_FeedChar("x", true)
		HSE_FeedChar("y", true)
		Match := HSE_FeedChar(End, true)
		if Framing {
			AssertEqual(Lower ? "ya" : "xyA", HSE_Buffer,
				"only an actually configured completion scalar may own extra framing capacity")
			return
		}
		if InStr(Mode, "match-") == 1 {
			AssertEqual(!Lower, IsObject(Match), "the actual END matcher must keep A and a distinct")
			return
		}
		if Noop {
			AssertEqual(!Lower, IsObject(Match), "a retained unconsumed a makes an identity rule an actual no-op")
			return
		}
		AssertTrue(IsObject(Match), "both configured scalars must reach the real match owner")
		Plan := _HSE_ExpansionPlan(Match, "Z", End, false, false, "")
		HSE_ApplyExpansion(Match, "Z", End)
		AssertEqual(Lower ? "Za" : "Z", HSE_Buffer,
			"the actual expansion must retain the case-distinct unconsumed end scalar")
		AssertEqual(Lower ? "a" : "", Plan["tail"], "the actual dispatch plan must agree with the engine projection")
	} finally {
		; Drain only the qualified scope's detached projection, then restore the
		; exact host registry/buffer. Never clear a registry we did not create.
		try _HotstringRegistryScope(RegistryState)
		finally {
			HSE_Terminators := Saved.terms, _HotstringsTerminatorRecords := Saved.owner
			HSE_WORD_TERMINATORS := Saved.word, HSE_CONSUMED_DELIMITERS := Saved.consumed
			HSE_MAX_BUFFER_LEN := Saved.capacity, _MAX_BUFFER_LEN := Saved.prefix_capacity, HSE_RepeatEnabled := Saved.repeat
			HSE_Suppressed := Saved.suppressed, _PrefixWatcherSuppressed := Saved.prefix_suppressed, _PrefixLastKeyTick := Saved.tick
		}
	}
}
for _HTEI_Mode in ["match-upper", "match-lower", "consume-upper", "consume-lower", "framing-upper", "framing-lower", "noop-upper", "noop-lower", "boundary-upper", "boundary-lower", "trim-boundary-upper", "trim-boundary-lower", "unicode-boundary-upper", "unicode-boundary-lower", "preview-upper", "preview-lower"]
	Test("hotstring exact terminator identity: " . _HTEI_Mode, _HTEI_Engine.Bind(_HTEI_Mode))
