; tests/meta/test_personal_save_rebuilds_preview_index.ahk

; ==============================================================================
; MODULE: Regression - a live personal reload must resync the preview index
;         (personal-save-leaves-preview-index-stale)
; DESCRIPTION:
; Saving from the personal-hotstring editor re-registered the ENGINE in place
; and left the tooltip's PREVIEW index holding whatever the last full rebuild
; had put there. Typing "zz" advertised the pre-edit expansion while typing the
; final character emitted the new one. Deleting a trigger was worse: the preview
; kept offering it, and _PreviewEngineWouldFire fails OPEN for a trigger it can
; no longer find in the registry.
;
; ROOT CAUSE ENCODED: the two sides are rebuilt by different code, and only one
; of them was on the save path. RebuildHotstringsLive already pairs its registry
; rewrite with a preview-index rebuild; the editor path was the sibling that was
; forgotten. The pairing is therefore asserted on the function that MUTATES the
; registry, not on the two save handlers that happen to call it today - a fix
; scoped to the callers would have to be repeated for every caller added later,
; which is the exact shape of the bug.
;
; SCOPE: source-introspective. HotstringPrefixWatcherRebuildIndex early-returns
; whenever _PrefixInputHook is 0, which it always is under the headless harness
; (the watcher's InputHook is never started there), so the resync cannot be
; observed by running it - only the wiring can be asserted. The one runtime
; assertion below covers the coalescing constant, which IS reachable.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Whoever rewrites the registry resyncs the index =======
; ==================================================================
; ==================================================================

; Every function whose body CALLS Token, excluding Token's own definition.
; Derived from source so a second live-reload path added tomorrow joins the
; guard below the day it is written, rather than the day someone remembers it.
_PSR_EnclosingFunctions(Token) {
	Names := []
	Seen := Map()
	Owner := RegExReplace(Token, "\($", "")
	Current := ""
	for Line in StrSplit(_DriverSourceNoComments(), "`n", "`r") {
		if RegExMatch(Line, "^([A-Za-z_][A-Za-z0-9_]*)\([^\r\n]*\)\s*\{", &DefM)
			Current := DefM[1]
		if !InStr(Line, Token)
			continue
		if (Current == "" or Current == Owner)
			continue
		if Seen.Has(Current)
			continue
		Seen[Current] := true
		Names.Push(Current)
	}
	return Names
}

; The live-reload path clears an HSE group and re-registers into it, which is
; precisely "the engine registry now says something the preview index does not".
_PSR_EveryGroupReloadResyncsThePreviewIndex() {
	Callers := _PSR_EnclosingFunctions("HSE_ClearGroupForReload(")
	; Non-vacuity floor: the live-reload path exists. A scan that stopped
	; matching would otherwise make the loop below unable to fail.
	Assert(Callers.Length >= 1,
		"the scan must find at least one function that clears an HSE group for reload (found " . Callers.Length . ") - a scan that matches nothing passes every assertion below")

	for Name in Callers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Assert(InStr(Body, "HotstringPrefixWatcherRebuildIndex") > 0,
			Name . " rewrites the engine registry in place, so it must also resync the tooltip's preview index. Without it the editor's Save left the tooltip advertising the pre-edit expansion while the engine emitted the new one, and a deleted trigger kept being previewed because _PreviewEngineWouldFire fails open for a trigger it cannot find in the registry")
	}
}

; The reload must still BE a reload. If it stopped clearing and re-registering,
; the guard above would keep passing while guarding nothing at all.
_PSR_ReloadStillRewritesTheRegistry() {
	Body := _DriverFuncBody("ReloadPersonalSection")
	Assert(Body != "", "ReloadPersonalSection() must exist in the driver source")
	Assert(InStr(Body, "HSE_ClearGroupForReload") > 0,
		"ReloadPersonalSection must still clear the stale HSE group before re-registering")
	Assert(InStr(Body, "HSE_RegisterFromTomlFlags") > 0,
		"ReloadPersonalSection must still re-register the section's entries - if it stopped, the pairing guard above would be policing a function that no longer touches the registry")
}





; ============================================================
; ============================================================
; ======= 2/ The resync coalesces instead of repeating =======
; ============================================================
; ============================================================

; The webview save reloads every edited section in a loop, and a full index
; rebuild costs ~150 ms warm (far more on a cold TOML read). A one-shot timer
; re-armed by each iteration collapses that into a single rebuild; a POSITIVE
; period would instead install a repeating rebuild that churns the index for the
; rest of the session, which is why the sign is pinned and not just the call.
_PSR_ResyncIsAOneShotTimer() {
	Body := _DriverFuncBody("ReloadPersonalSection")
	Assert(RegExMatch(Body, "SetTimer\(\s*HotstringPrefixWatcherRebuildIndex\s*,\s*-") > 0,
		"the preview-index resync must be armed as a ONE-SHOT timer (negative period). A positive period installs a repeating full rebuild that re-reads every hotstring TOML forever, and a synchronous call would make the webview save pay the rebuild once per edited section")
}

; The coalescing delay must be a real, positive delay: zero or a negative
; constant would flip the sign of the negative period above and turn the
; one-shot into a repeating timer.
_PSR_CoalescingDelayIsPositive() {
	global HS_PERSONAL_RELOAD_INDEX_DELAY_MS
	Assert(IsSet(HS_PERSONAL_RELOAD_INDEX_DELAY_MS),
		"the resync coalescing delay must be a named constant, not a magic number at the call site")
	Assert(HS_PERSONAL_RELOAD_INDEX_DELAY_MS > 0,
		"the coalescing delay must be strictly positive: SetTimer is called with its NEGATION, so a zero or negative constant silently turns the one-shot resync into a repeating rebuild")
}


Test("personal-save-preview-index: every live registry reload resyncs the preview index",
	_PSR_EveryGroupReloadResyncsThePreviewIndex)
Test("personal-save-preview-index: the live reload still rewrites the engine registry",
	_PSR_ReloadStillRewritesTheRegistry)
Test("personal-save-preview-index: the resync is armed as a coalescing one-shot timer",
	_PSR_ResyncIsAOneShotTimer)
Test("personal-save-preview-index: the coalescing delay constant is positive",
	_PSR_CoalescingDelayIsPositive)
