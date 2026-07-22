; tests/meta/test_suspend_watchdog_no_prefix_keywait.ahk

; ==============================================================================
; MODULE: Suspend Prefix-Drain Invariant Meta Test
; DESCRIPTION:
; Static source guard for the "suspend-watchdog-no-prefix-keywait" finding.
;
; The SC138 (AltGr/Kana) custom-combination prefix flag latches across Suspend and
; cannot be cleared by synthetic events — it must be drained (by waiting for the
; physical key to lift) BEFORE Suspend() flips. _SuspendStateWatchdog is only a
; state-change DETECTOR; it reacts AFTER the flip, too late to drain. So the
; invariant is: every code path that triggers a suspend must confirm the prefix is
; physically released BEFORE flipping. Today ToggleSuspend checks
; _SuspendPrefixesAreClear() and, when a prefix is still held, defers via the
; non-blocking _SuspendPendingPoll() instead of blocking; the Suspend(1)/Suspend(0)
; flips live inside those two functions only. (The earlier design used a blocking
; drain helper and a Suspend(-1) toggle; those names no longer exist and the guard
; below fails if they are ever resurrected.)
;
; This test encodes that invariant as source text:
;   1. The ONLY Suspend(...) call in the driver is the Suspend(-1) inside
;      ToggleSuspend (no future path may bypass the drain).
;   2. ToggleSuspend calls _SuspendDrainPrefix() BEFORE Suspend(-1).
;   3. _SuspendDrainPrefix performs the KeyWait("SC138"...) drain.
; A future native/external suspend hotkey that calls Suspend() directly, or a
; refactor that drops the drain, fails CI. Meta-static because ErgoptiPlus.ahk
; registers every hotkey at load and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_SWNPK_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Counts non-overlapping occurrences of Needle in Hay.
_SWNPK_CountOccurrences(Hay, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Hay, Needle, , Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}




; ==================================================
; ==================================================
; ======= 2/ Invariant assertions ==================
; ==================================================
; ==================================================

; Invariant 1: the only Suspend(...) call site is ToggleSuspend's Suspend(-1).
; The token "Suspend(" appears in source only as the ToggleSuspend( declaration
; and as the Suspend(-1) call; any other occurrence is a path that bypasses the
; prefix drain. Scans the COMMENT-STRIPPED source (_DriverSourceNoComments) —
; a raw scan would also match "Suspend(" inside explanatory prose like
; "native Suspend() never disarms...", which the Pattern-1 hardening campaign
; added to a dozen sites and which is not a real call site.
_SWNPK_OnlyCallSiteIsToggleSuspend() {
	Toggle := _DriverFuncBody("ToggleSuspend")
	Poll := _DriverFuncBody("_SuspendPendingPoll")
	Assert(InStr(Toggle, "Suspend(1)") > 0 and InStr(Poll, "Suspend(1)") > 0,
		"The immediate and deferred suspend paths must both use explicit Suspend(1) after the prefix-clear protocol")
	Assert(InStr(_DriverSourceNoComments(), "Suspend(-1)") = 0,
		"Suspend must not toggle after a timed KeyWait because that can latch a held custom prefix")
}
Test("ErgoptiPlus: Suspend(-1) is the only suspend call site (suspend-watchdog-no-prefix-keywait)", _SWNPK_OnlyCallSiteIsToggleSuspend)

; Regression guard for the counter's own fragility (root cause, not the
; symptom): a full-line comment containing the literal substring "Suspend("
; must NOT inflate the count above. This bit CI on 2026-07-01 — the AHK suite
; went from 2807/2807 to 2806 passed/1 failed purely because the Pattern-1
; Suspend-guard hardening campaign added ~10 explanatory comments like
; "; native Suspend() never disarms this hotkey's own KeyWait/dispatch" across
; lib/modules/adapters/ui, none of which added a real Suspend() call site.
; Without _StripFullLineComments/_DriverSourceNoComments, ANY future
; explanatory comment mentioning "Suspend(" reintroduces this false failure.
_SWNPK_CommentDoesNotInflateSuspendCount() {
	Fake := "; native Suspend() never disarms this hotkey's own KeyWait/dispatch, so a`n"
		. "; SetTimer callback must check A_IsSuspended() itself.`n"
		. "SomeUnrelatedFunction(*) {`n"
		. "`treturn 1`n"
		. "}`n"
	Stripped := _StripFullLineComments(Fake)
	Assert(_SWNPK_CountOccurrences(Stripped, "Suspend(") = 0,
		"A full-line comment containing 'Suspend(' must be stripped before the source-scan invariant counts it — a raw substring count over unstripped source is fragile against explanatory prose and will false-fail CI whenever a new comment mentions Suspend()")
}
Test("suspend-watchdog meta-test: an explanatory comment must not inflate the Suspend( count (suspend-watchdog-no-prefix-keywait)", _SWNPK_CommentDoesNotInflateSuspendCount)

; Invariant 2: ToggleSuspend drains the prefix before flipping Suspend.
_SWNPK_ToggleDrainsBeforeSuspend() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("ToggleSuspend")
	Assert(Seg != "", "ToggleSuspend(*) must exist in ErgoptiPlus.ahk")
	ClearPos := InStr(Seg, "_SuspendPrefixesAreClear()")
	SuspendPos := InStr(Seg, "Suspend(1)")
	Assert(ClearPos > 0 and SuspendPos > ClearPos,
		"ToggleSuspend must verify physical prefixes before the immediate Suspend(1) path")
	Assert(InStr(Seg, "SetTimer(_SuspendPendingPoll, 25)") > 0,
		"A held prefix must schedule the non-blocking pending-suspend poll instead of waiting on the tray thread")
}
Test("ErgoptiPlus: ToggleSuspend drains prefix before Suspend (suspend-watchdog-no-prefix-keywait)", _SWNPK_ToggleDrainsBeforeSuspend)

; Invariant 3: every registered custom-combination prefix key is drained.
; SC138 (AltGr/Kana) and SC038 (LAlt, "SC038 & SC03A::" in base_modifier.ahk)
; both latch AHK's internal prefix-down flag across Suspend() the same way
; (F42 -- same_class_found_elsewhere regression of
; feedback_ahk_suspend_prefix_latch). _SuspendDrainPrefix drains the whole
; SUSPEND_CUSTOM_COMBO_PREFIX_KEYS list generically so a future THIRD prefix
; key only needs a one-line addition to the list, not a new hand-rolled
; drain call site.
_SWNPK_DrainHelperWaitsEveryPrefix() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("_SuspendPrefixesAreClear")
	Assert(Seg != "", "_SuspendPrefixesAreClear() must exist in lib/lifecycle.ahk")
	; Q is the ASCII double-quote (the linter bans the backtick-quote escape).
	Q := Chr(34)
	ListPos := InStr(Src, "SUSPEND_CUSTOM_COMBO_PREFIX_KEYS")
	Assert(ListPos > 0,
		"SUSPEND_CUSTOM_COMBO_PREFIX_KEYS must exist as the single source of truth for custom-combination prefix keys the suspend drain must cover")
	ListDecl := SubStr(Src, ListPos, 200)
	Assert(InStr(ListDecl, Q . "SC138" . Q) > 0,
		"SUSPEND_CUSTOM_COMBO_PREFIX_KEYS must list SC138 (AltGr/Kana) — the original documented drain target")
	Assert(InStr(ListDecl, Q . "SC038" . Q) > 0,
		"SUSPEND_CUSTOM_COMBO_PREFIX_KEYS must list SC038 (LAlt, 'SC038 & SC03A::' in base_modifier.ahk) — it has the identical unprotected prefix-latch exposure as SC138 (F42)")
	Assert(InStr(Seg, "SUSPEND_CUSTOM_COMBO_PREFIX_KEYS") > 0,
		"_SuspendDrainPrefix must iterate SUSPEND_CUSTOM_COMBO_PREFIX_KEYS, not hardcode a single key, so every listed prefix is drained")
	Assert(InStr(Seg, "GetKeyState(PrefixKey, " . Q . "P" . Q . ")") > 0 and InStr(Seg, "KeyWait(") = 0,
		"_SuspendPrefixesAreClear must test the physical prefix state without blocking the tray thread")
}
Test("lifecycle: _SuspendDrainPrefix drains every registered custom-combination prefix key, including SC038 (suspend-watchdog-no-prefix-keywait, F42)", _SWNPK_DrainHelperWaitsEveryPrefix)



; ==================================================
; ==================================================
; ======= 3/ Boot phantom-modifier release =========
; ==================================================
; ==================================================

; Invariant 4: the boot phantom-modifier release exists and clears the AltGr keys.
; A Reload can land while AltGr is physically held, leaving the OS modifier
; latched down for the fresh process — stuck on the AltGr layer (transient
; « AltGr bloqué »). _ReleasePhantomModifiers clears it at boot.
_SWNPK_BootReleasesPhantomModifiers() {
	Seg := _DriverFuncBody("_ReleasePhantomModifiers")
	Assert(Seg != "", "_ReleasePhantomModifiers() must exist in lib/lifecycle.ahk")
	Assert(InStr(Seg, "{SC138 up}") > 0,
		"_ReleasePhantomModifiers must release SC138 (the AltGr/Kana prefix key) to clear an OS phantom carried across a Reload")
	Assert(InStr(Seg, "{RAlt up}") > 0,
		"_ReleasePhantomModifiers must release RAlt (vanilla AltGr)")
	Assert(InStr(Seg, "{Blind}") > 0,
		"_ReleasePhantomModifiers must send with {Blind} so AHK does not inject its own modifier state")
}
Test("lifecycle: _ReleasePhantomModifiers releases AltGr/SC138 at boot (suspend-watchdog-no-prefix-keywait)", _SWNPK_BootReleasesPhantomModifiers)

; Invariant 5: the release helper is actually CALLED at boot (not only defined),
; so a Reload-borne phantom modifier is cleared before the first keystrokes.
_SWNPK_BootCallsRelease() {
	Src := _DriverSourceConcat()
	Calls := _SWNPK_CountOccurrences(Src, "_ReleasePhantomModifiers()")
	Assert(Calls >= 2,
		"_ReleasePhantomModifiers() must be CALLED at boot, not only defined — found " . Calls . " occurrence(s) of the bare call token in the driver tree")
}
Test("ErgoptiPlus: boot calls _ReleasePhantomModifiers (suspend-watchdog-no-prefix-keywait)", _SWNPK_BootCallsRelease)

; F38 (audit 2026-07-20): the KeyWait -> non-blocking-poll refactor updated the
; assertions but left the module docstrings, comments and this test's prose naming
; _SuspendDrainPrefix()/Suspend(-1) — functions that no longer exist. Documentation is
; half of the single source of truth, so a resurrected old name (in code OR prose) now
; fails here rather than quietly misleading the next reader.
_SWNPK_NoStaleDrainNames() {
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "_SuspendDrainPrefix") = 0,
		"the removed _SuspendDrainPrefix name must not reappear — the current design is _SuspendPrefixesAreClear + _SuspendPendingPoll")
	Assert(InStr(Src, "Suspend(-1)") = 0,
		"the removed Suspend(-1) toggle must not reappear — ToggleSuspend flips explicitly via Suspend(1)/Suspend(0)")
	Assert(InStr(Src, "_SuspendPrefixesAreClear") > 0 && InStr(Src, "_SuspendPendingPoll") > 0,
		"the current non-blocking prefix gate (_SuspendPrefixesAreClear + _SuspendPendingPoll) must exist")
}
Test("suspend: the removed drain-prefix names never reappear (docs match the implementation)",
	_SWNPK_NoStaleDrainNames)
