; tests/support/hotstring_registry_scope.ahk

; ==============================================================================
; MODULE: Detached Hotstring Registry Scope
; DESCRIPTION:
; Shared by the suites that drive genuine hotstring publications (the cache
; publication and the terminator identity cases). It installs detached engine
; indexes before any real registry publication and restores the host's exact
; values, including their definedness, afterwards. It lives here rather than in
; one consumer so that retiring a consumer cannot delete it from under the
; others.
; ==============================================================================

#Requires AutoHotkey v2.0

; Installs detached engine indexes, or restores a snapshot it returned.
; @param Restore {Map|Integer} 0 to install; the returned snapshot to restore.
; @returns {Map} The host's saved values when installing.
_HotstringRegistryScope(Restore := 0) {
	global _PrefixInputHook, _PrefixVisibleFireDecisions, HS_PERSONAL_RELOAD_INDEX_DELAY_MS
	global HSE_MAX_BUFFER_LEN, HSE_WORD_TERMINATORS, HSE_RebuildInProgress, HSE_CONSUMED_DELIMITERS, HSE_PRIORITY_COMMON
	global HSE_PRIORITY_PACKAGE, HSE_PRIORITY_PERSONAL, HSE_Buffer, HSE_FinalNoOpPending, HSE_FinalNoOpFound
	global HSE_StartIsWordBoundary, HSE_StartIsLineStart, HSE_RegistryByLastChar, HSE_RegistryByGroup, HSE_DisabledGroups
	global HSE_SeqCounter, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration, HSE_RegistryTransitionDepth, HSE_StarSpecs
	global HSE_StarPrefixSetCI, HSE_StarPrefixSetCS, HSE_StarByTriggerCI, HSE_StarByTriggerCS, HSE_MaxStarTriggerLen
	global HSE_EndByTriggerCI, HSE_EndByTriggerCS, HSE_MaxEndTriggerLen, HSE_Suppressed, HSE_LastMatch
	global HSE_LastEndChar, HSE_RepeatEnabled, HSE_IdleResetSeconds, HSE_ClickResetsWord, HSE_CascadeMaxArrows
	global HSE_CASCADE_MIN_ARROWS, HSE_CASCADE_MAX_ARROWS, HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord
	global HSE_PersonalInfoCombosEnabled, HSE_TypoNbspStripped
	Names := ["HSE_MAX_BUFFER_LEN", "HSE_WORD_TERMINATORS", "HSE_RebuildInProgress", "HSE_CONSUMED_DELIMITERS", "HSE_PRIORITY_COMMON", "HSE_PRIORITY_PACKAGE", "HSE_PRIORITY_PERSONAL", "HSE_Buffer", "HSE_FinalNoOpPending", "HSE_FinalNoOpFound", "HSE_StartIsWordBoundary", "HSE_StartIsLineStart", "HSE_RegistryByLastChar", "HSE_RegistryByGroup", "HSE_DisabledGroups", "HSE_SeqCounter", "HSE_RegistryGeneration", "HSE_RuntimeDecisionGeneration", "HSE_RegistryTransitionDepth", "HSE_StarSpecs", "HSE_StarPrefixSetCI", "HSE_StarPrefixSetCS", "HSE_StarByTriggerCI", "HSE_StarByTriggerCS", "HSE_MaxStarTriggerLen", "HSE_EndByTriggerCI", "HSE_EndByTriggerCS", "HSE_MaxEndTriggerLen", "HSE_Suppressed", "HSE_LastMatch", "HSE_LastEndChar", "HSE_RepeatEnabled", "HSE_IdleResetSeconds", "HSE_ClickResetsWord", "HSE_CascadeMaxArrows", "HSE_CASCADE_MIN_ARROWS", "HSE_CASCADE_MAX_ARROWS", "HSE_ArrowResetsWord", "HSE_ShortcutResetsWord", "HSE_TapHoldResetsWord", "HSE_PersonalInfoCombosEnabled", "HSE_TypoNbspStripped"]
	if IsObject(Restore) {
		; Real section publications arm the auxiliary 120 ms index timer.
		; Its genuine callback returns before touching state while no watcher
		; exists. Drain it while our detached registry remains installed.
		Sleep(HS_PERSONAL_RELOAD_INDEX_DELAY_MS + 40)
		SetTimer(HotstringPrefixWatcherRebuildIndex, 0)
		for Name, State in Restore
			%Name% := State.had ? State.value : unset
		return
	}
	; This unit runner does not start a keyboard watcher. Fail before any
	; mutation if a host instead owns one: its prior timers are not ours.
	AssertTrue(!_PrefixInputHook, "The native case fixture requires the runner's inactive keyboard watcher")
	AssertTrue(_PrefixVisibleFireDecisions is Array && _PrefixVisibleFireDecisions.Length == 0,
		"No host registry projection may be retired by this fixture")
	Saved := Map()
	for Name in Names {
		Had := IsSet(%Name%)
		Saved[Name] := Had ? {had: true, value: %Name%} : {had: false}
	}
	; Install detached indexes before genuine native publications can mutate
	; buckets. Saving references alone would not preserve the host's maps.
	HSE_MAX_BUFFER_LEN := 256
	HSE_WORD_TERMINATORS := " `t`r`n.,;:?!" . Chr(0x27) . Chr(0x2019)
	HSE_RebuildInProgress := false
	HSE_CONSUMED_DELIMITERS := ""
	HSE_PRIORITY_COMMON := 10
	HSE_PRIORITY_PACKAGE := 30
	HSE_PRIORITY_PERSONAL := 50
	HSE_Buffer := ""
	HSE_FinalNoOpPending := false
	HSE_FinalNoOpFound := false
	HSE_StartIsWordBoundary := true
	HSE_StartIsLineStart := false
	HSE_RegistryByLastChar := Map()
	HSE_RegistryByGroup := Map()
	HSE_DisabledGroups := Map()
	HSE_SeqCounter := 0
	HSE_RegistryGeneration := 0
	HSE_RuntimeDecisionGeneration := 0
	HSE_RegistryTransitionDepth := 0
	HSE_StarSpecs := []
	HSE_StarPrefixSetCI := Map()
	HSE_StarPrefixSetCS := Map()
	HSE_StarByTriggerCI := Map()
	HSE_StarByTriggerCS := Map()
	HSE_MaxStarTriggerLen := 0
	HSE_EndByTriggerCI := Map()
	HSE_EndByTriggerCS := Map()
	HSE_MaxEndTriggerLen := 0
	HSE_Suppressed := 0
	HSE_LastMatch := ""
	HSE_LastEndChar := ""
	HSE_RepeatEnabled := true
	HSE_IdleResetSeconds := ""
	HSE_ClickResetsWord := ""
	HSE_CascadeMaxArrows := ""
	HSE_CASCADE_MIN_ARROWS := 1
	HSE_CASCADE_MAX_ARROWS := 10
	HSE_ArrowResetsWord := ""
	HSE_ShortcutResetsWord := ""
	HSE_TapHoldResetsWord := ""
	HSE_PersonalInfoCombosEnabled := true
	HSE_TypoNbspStripped := false
	return Saved
}
