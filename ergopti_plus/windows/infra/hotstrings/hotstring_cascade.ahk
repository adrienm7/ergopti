; infra/hotstrings/hotstring_cascade.ahk

; ==============================================================================
; MODULE: Hotstring Cascade
; DESCRIPTION:
; Lets the text a hotstring produced complete further hotstrings, up to the
; number of arrows the user chose (hotstrings.cascade_max_arrows, default 3):
; 1 is a single expansion (``a`` giving ``b``, no cascading), 2 allows ``a``
; giving ``b`` giving ``c``. With ``fb`` giving ``facebook`` and ``facebook``
; giving ``Facebook``, typing ``fb`` and a space ends on ``Facebook`` from 2.
;
; FEATURES & RATIONALE:
; 1. The chain is resolved BEFORE anything is sent, on a virtual copy of the
;    engine buffer, and HSE_DispatchMatch sends ONE burst for the whole chain:
;    the first trigger is erased (plus any typed text a later link reaches
;    back over) and the last link's text is typed. This is the in-engine
;    re-feed the SendInput contract needs (hotstring-output-is-final): nothing
;    is typed twice, no keystroke can land between two bursts, and no output
;    ever comes back through the prefix watcher as typed input.
; 2. Each link is chosen by the SAME matcher a typed key goes through
;    (HSE_FindMatchAtEnd) and decided by the same preflight
;    (_HSE_PrepareDispatchDecision), so a link can never fire in a case or word
;    context where a typed trigger would not.
; 3. Guards: a spec fires at most once per chain (``ab`` giving ``xab`` ends
;    there), a FinalResult link ends the chain, and the arrow count bounds it.
;    Only plain literal text takes part: a replacement carrying Send syntax, a
;    raw callback and a private (personal information) hotstring are not links,
;    because the text left on screen is not known or must not be composed.
; 4. The end character that completed the first hotstring is carried through
;    the whole chain, whatever its delimiter's "consumed" choice, so a chain
;    gives the same text either way: an end-character link takes it as its own
;    terminator, and a link that would swallow it (a star link whose trigger
;    reaches it) ends the chain. It is typed once after the final text, unless
;    its delimiter is consumed, in which case it is swallowed once, exactly as
;    for a typed key. macOS and Linux follow the same rule.
; 5. A link whose reference character (the one before its expander) was
;    produced by an earlier link is inside any expansion delay, as on macOS and
;    Linux; one that reaches back into typed text keeps its delay.
; ==============================================================================

#Requires AutoHotkey v2.0

; The generated config-key constants; #Include skips a file the entry script
; already loaded, so a unit harness that loads this file alone still resolves them.
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk





; ======================================
; ======================================
; ======= 1/ The Setting =============
; ======================================
; ======================================

; Whether a value is a valid hotstrings.cascade_max_arrows: a whole number from
; HSE_CASCADE_MIN_ARROWS to HSE_CASCADE_MAX_ARROWS (hotstring_engine_main.ahk).
; Same rule as the shared Lua engine's valid_cascade_max_arrows.
; @param Value {Any} Candidate read from config.toml or the menu.
; @returns {Boolean}
HSE_ValidCascadeMaxArrows(Value) {
	return (Value is Integer) and Value >= HSE_CASCADE_MIN_ARROWS and Value <= HSE_CASCADE_MAX_ARROWS
}

; The arrow count in force: the published value, or the manifest default before
; the loader ran (unit harness, early boot).
; @returns {Integer}
HSE_CascadeMaxArrowsCurrent() {
	global HSE_CascadeMaxArrows
	return HSE_CascadeMaxArrows == ""
		? ManifestDefaultFor(ConfigKey.HOTSTRINGS_CASCADE_MAX_ARROWS)
		: HSE_CascadeMaxArrows
}





; ====================================
; ====================================
; ======= 2/ The Chain ===============
; ====================================
; ====================================

; The identity of a rule for the same-spec guard: the same trigger (case aside)
; and the same completion kind are one spec, whichever source registered it.
; @param Spec {Object} A registered hotstring spec.
; @returns {String}
_HSE_CascadeKey(Spec) {
	return StrLower(Spec.Trigger) . "`n"
		. ((Spec.HasOwnProp("Star") and Spec.Star) ? "star" : "end")
}

; Whether a spec can be a link of a cascade: a literal text replacement that is
; not private, not a raw callback and not the repeat rule.
; @param Spec {Object} A registered hotstring spec.
; @returns {Boolean}
_HSE_IsCascadeLink(Spec) {
	if !IsObject(Spec) or !Spec.HasOwnProp("Replacement")
		return false
	if (Spec.HasOwnProp("RawCallback") and Spec.RawCallback)
		return false
	if (Spec.HasOwnProp("IsPrivate") and Spec.IsPrivate)
		return false
	; The magic key's repeat rule (a★ giving aa) is a keystroke feature, not a
	; registered hotstring; macOS and Linux do not chain it either.
	if (Spec.HasOwnProp("IsRepeat") and Spec.IsRepeat)
		return false
	return !Spec.HasOwnProp("OnlyText") or Spec.OnlyText
}

; Resolves the chain a first decision starts, on a virtual buffer, and returns
; the net edit. Reads and restores the matcher's globals under Critical so a
; physical keystroke can never observe the virtual buffer.
; @param Spec {Object} The first (matched) spec.
; @param Prepared {Object} The first spec's decision (_HSE_PrepareDispatchDecision).
; @param EndChar {String} The end character that completed the match, "" for a star trigger.
; @param GateTick {Integer} The tick the expansion-delay gate is measured at.
; @returns {Object|String} ``{Replacement, ExtraUnits, ExtraCodepoints, Steps}``
;   where Replacement replaces the first trigger plus ExtraUnits more code units
;   of typed text, or "" when nothing chains.
_HSE_PlanCascade(Spec, Prepared, EndChar, GateTick) {
	global HSE_Buffer, HSE_LastEndChar, HSE_TypoNbspStripped
	MaxArrows := HSE_CascadeMaxArrowsCurrent()
	if (MaxArrows < 2 or !Prepared.OnlyText or !_HSE_IsCascadeLink(Spec))
		return ""
	if (Spec.HasOwnProp("FinalResult") and Spec.FinalResult)
		return ""

	PreviousCritical := Critical("On")
	SavedBuffer := HSE_Buffer
	SavedEndChar := HSE_LastEndChar
	SavedTypo := HSE_TypoNbspStripped
	try {
		Original := HSE_Buffer
		OriginalLength := StrLen(Original)
		StripLength := Spec.Length + StrLen(EndChar) + (HSE_TypoNbspStripped ? 1 : 0)
		Stable := OriginalLength >= StripLength ? OriginalLength - StripLength : 0
		; Carried through the chain even when its delimiter is consumed: the
		; consumption is applied once, by the caller, after the last link.
		Emitted := EndChar
		Virtual := SubStr(Original, 1, Stable) . Prepared.Replacement . Emitted
		Seen := Map(_HSE_CascadeKey(Spec), true)
		Last := Spec
		Steps := 1
		while (Steps < MaxArrows and !(Last.HasOwnProp("FinalResult") and Last.FinalResult)) {
			HSE_Buffer := Virtual
			Link := HSE_FindMatchAtEnd(SubStr(Virtual, -1))
			LinkEndChar := HSE_LastEndChar
			LinkTypo := HSE_TypoNbspStripped
			HSE_Buffer := SavedBuffer
			if (Link == "" or !_HSE_IsCascadeLink(Link) or Seen.Has(_HSE_CascadeKey(Link)))
				break
			; A link that would swallow the carried end character ends the chain.
			if (LinkEndChar != Emitted)
				break
			LinkEmitted := LinkEndChar
			; The reference character is the one before the expander; when an
			; earlier link produced it, the link is inside any expansion delay.
			ExpanderUnits := LinkEndChar != ""
				? StrLen(LinkEndChar) + (LinkTypo ? 1 : 0)
				: _TextTailCodeUnits(Virtual, 1)
			GateSpec := Link
			if (StrLen(Virtual) - ExpanderUnits > Stable and Link.HasOwnProp("TimeActivationSeconds")
					and Link.TimeActivationSeconds > 0) {
				GateSpec := Link.Clone()
				GateSpec.DeleteProp("TimeActivationSeconds")
			}
			Decision := _HSE_PrepareDispatchDecision(GateSpec, Virtual, LinkEndChar, LinkTypo, , GateTick)
			if !IsObject(Decision) or !Decision.OnlyText
				break
			LinkStrip := Link.Length + StrLen(LinkEndChar) + (LinkTypo ? 1 : 0)
			if (StrLen(Virtual) < LinkStrip)
				break
			Kept := StrLen(Virtual) - LinkStrip
			Virtual := SubStr(Virtual, 1, Kept) . Decision.Replacement . LinkEmitted
			Stable := Min(Stable, Kept)
			Seen[_HSE_CascadeKey(Link)] := true
			Last := Link
			Steps += 1
		}
		if (Steps == 1)
			return ""
		FirstKept := OriginalLength >= StripLength ? OriginalLength - StripLength : 0
		ExtraUnits := FirstKept - Stable
		ExtraText := SubStr(Original, Stable + 1, ExtraUnits)
		try LoggerDebug("HSE", "Cascade resolved {1} link(s).", Steps)
		return {
			Replacement: SubStr(Virtual, Stable + 1, StrLen(Virtual) - Stable - StrLen(Emitted)),
			ExtraUnits: ExtraUnits,
			ExtraCodepoints: _TextCodepointLength(ExtraText),
			Steps: Steps
		}
	} finally {
		HSE_Buffer := SavedBuffer
		HSE_LastEndChar := SavedEndChar
		HSE_TypoNbspStripped := SavedTypo
		Critical(PreviousCritical)
	}
}
