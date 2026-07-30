; tests/meta/test_nav_cluster_resets_both_buffers.ahk

; ==============================================================================
; MODULE: Regression — the whole navigation cluster invalidates both buffers
;         (nav-cluster-resets-both-buffers)
; DESCRIPTION:
; Type "bonjour ia", press Home, then type "." — and the engine fired ia -> IA
; with {BackSpace 3} at the START of the line, deleting three characters of
; unrelated text.
;
; ROOT CAUSE ENCODED: the prefix watcher enumerated the four arrows, Tab, Enter,
; Escape and Space as buffer-invalidating and stopped there. The engine's own
; module contract lists more: "Arrows / Home / End / PgUp / PgDn / Insert /
; Delete / Escape / mouse click / disruptive Ctrl combos reset the buffer". Four
; of the eight cursor keys were wired; Home, End, PgUp, PgDn, Insert and Delete
; were in neither the ResetVKs map nor the HSE_FeedReset chain. The invariant
; existed, was written down, and was applied at half its sites — the dominant
; N-of-M shape in this driver.
;
; Both halves matter and are asserted separately. Resetting only the preview
; would leave the engine expanding against text that is no longer left of the
; caret; resetting only the engine would leave the tooltip advertising an
; expansion that will not fire.
;
; The two groups differ in what they may promise. Pure cursor movement lands the
; caret somewhere unobservable but the next typed run starts fresh, so the
; boundary flag stays true — the treatment the arrows already had. Insert and
; Delete rewrite context without moving the caret, so they take the
; boundary-false reset the disruptive Ctrl combos take.
;
; SCOPE: source-level over the watcher's own VK tables. _OnPrefixKeyDown is an
; InputHook callback bound to a live hook and cannot be invoked headlessly.
; ==============================================================================

#Requires AutoHotkey v2.0

; Virtual-key codes named by the engine contract as buffer-invalidating, with
; the boundary flag each is entitled to promise.
;   true  — pure cursor movement: the caret moved somewhere unknown, but the
;           next typed run begins at a fresh word start.
;   false — context rewritten in place: nothing may be assumed about the text
;           now sitting to the left of the caret.
global _NCR_CURSOR_MOVERS := Map(
	0x1B, "Escape", 0x25, "Left", 0x26, "Up", 0x27, "Right", 0x28, "Down",
	0x21, "PgUp", 0x22, "PgDn", 0x23, "End", 0x24, "Home")

global _NCR_CONTEXT_REWRITERS := Map(0x2D, "Insert", 0x2E, "Delete")





; ==================================================================
; ==================================================================
; ======= 1/ The preview buffer resets for the whole cluster =======
; ==================================================================
; ==================================================================

; The ResetVKs map literal inside _OnPrefixKeyDown.
;
; Terminated on a line whose only content is ")", NOT on the first ")" found:
; the entries carry trailing comments that name the key ("; VK_PRIOR (PgUp)"),
; and stopping at the first paren truncated the map mid-way. That silently
; hid every entry below it — the scan reported keys as missing when they were
; present, and would equally have reported present keys as covered.
_NCR_ResetVkMapBody() {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	if (Body == "")
		return ""
	Collecting := false
	Out := ""
	for Line in StrSplit(Body, "`n", "`r") {
		if (!Collecting) {
			if InStr(Line, "static ResetVKs := Map(")
				Collecting := true
			continue
		}
		if (Trim(Line, " `t") == ")")
			return Out
		Out .= Line . "`n"
	}
	return ""
}

_NCR_PreviewResetsForEveryNavKey() {
	global _NCR_CURSOR_MOVERS, _NCR_CONTEXT_REWRITERS
	MapBody := _NCR_ResetVkMapBody()
	Assert(MapBody != "",
		"_OnPrefixKeyDown must still declare its ResetVKs map — without that landmark this guard measures nothing")

	for VK, Name in _NCR_CURSOR_MOVERS {
		Hex := Format("0x{:02X}", VK)
		Assert(InStr(MapBody, Hex) > 0,
			Name . " (" . Hex . ") must be in ResetVKs. It moves the caret, so the preview buffer no longer describes the text to its left, and the tooltip goes on offering an expansion anchored to a position the user has left")
	}
	for VK, Name in _NCR_CONTEXT_REWRITERS {
		Hex := Format("0x{:02X}", VK)
		Assert(InStr(MapBody, Hex) > 0,
			Name . " (" . Hex . ") must be in ResetVKs — it rewrites the document by an amount this watcher cannot observe")
	}

	; Backspace must stay OUT: it decrements both buffers rather than wiping
	; them, which is what keeps a suggestion alive after fixing a typo.
	Assert(InStr(MapBody, "0x08") == 0,
		"VK_BACK must NOT be in ResetVKs — backspace decrements the preview rather than wiping it, and wiping it is a separate regression this map has already had once")
}




; ==================================================================
; ==================================================================
; ======= 2/ The engine buffer resets for the same cluster ========
; ==================================================================
; ==================================================================

; The two reset branches, isolated so each key can be attributed to the right
; boundary-flag promise.
_NCR_BranchFor(Marker) {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	if (Body == "")
		return ""
	Start := InStr(Body, Marker)
	if (!Start)
		return ""
	Stop := InStr(Body, "HSE_FeedReset", , Start)
	return (Stop > 0) ? SubStr(Body, Start, Stop - Start) : ""
}

_NCR_EngineResetsForEveryNavKey() {
	global _NCR_CURSOR_MOVERS, _NCR_CONTEXT_REWRITERS
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Body != "", "_OnPrefixKeyDown() must exist in the driver source")

	; Every cursor mover must appear in a VK test that leads to a reset. The
	; comparison text is what the branch conditions are written in.
	for VK, Name in _NCR_CURSOR_MOVERS {
		Hex := Format("0x{:02X}", VK)
		Assert(RegExMatch(Body, "VK\s*==\s*" . Hex),
			Name . " (" . Hex . ") must be tested in _OnPrefixKeyDown's reset chain. Without it the ENGINE buffer survives the caret move, so the next expansion backspaces over whatever now sits at the new position — the tooltip half of the fix alone does not prevent the text corruption")
	}
	for VK, Name in _NCR_CONTEXT_REWRITERS {
		Hex := Format("0x{:02X}", VK)
		Assert(RegExMatch(Body, "VK\s*==\s*" . Hex),
			Name . " (" . Hex . ") must be tested in _OnPrefixKeyDown's reset chain — it rewrites context the engine buffer still claims to describe")
	}
}

; The boundary flag each group promises. Getting this wrong is silent: too
; permissive and an expansion fires where no word boundary exists; too strict
; and the first word after every arrow key stops expanding.
_NCR_BoundaryPromiseMatchesTheContract() {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Body != "", "_OnPrefixKeyDown() must exist")

	; Insert/Delete branch: reset with boundary FALSE.
	RewriteBranch := _NCR_BranchFor("VK == 0x2D")
	Assert(RewriteBranch != "", "the Insert/Delete branch must exist and reach a reset")
	Assert(InStr(Body, "HSE_FeedReset(false, true)") > 0,
		"Insert and Delete must reset with the boundary flag FALSE, like the disruptive Ctrl combos: they rewrite text in place without moving the caret, so nothing can be assumed about what now sits to its left")

	; Cursor movers: reset with boundary TRUE, the treatment the arrows had.
	Assert(InStr(Body, "HSE_FeedReset(true, true)") > 0,
		"the cursor movers must keep resetting with the boundary flag TRUE — the caret landed somewhere unknown, but the next typed run legitimately starts a fresh word")
}

; The contract this test is derived from must keep saying so, or the next reader
; has no way to know which keys belong in the cluster at all.
_NCR_EngineContractStillNamesTheCluster() {
	Src := _StripFullLineComments(_DriverSourceConcat())
	Assert(Src != "", "the driver source must be readable")
	Doc := _DriverDirConcat("lib/hotstrings")
	for Needle in ["Home", "End", "PgUp", "PgDn", "Insert", "Delete"]
		Assert(InStr(Doc, Needle) > 0,
			"the hotstring engine's documented buffer-invalidation contract must keep naming '" . Needle . "' — that list is the only statement of which keys belong to this cluster, and it is what revealed that only half of them were wired")
}


Test("meta nav-cluster-resets-both-buffers: the preview resets for every nav key",
	_NCR_PreviewResetsForEveryNavKey)
Test("meta nav-cluster-resets-both-buffers: the engine resets for every nav key",
	_NCR_EngineResetsForEveryNavKey)
Test("meta nav-cluster-resets-both-buffers: the boundary promise matches the contract",
	_NCR_BoundaryPromiseMatchesTheContract)
Test("meta nav-cluster-resets-both-buffers: the engine contract still names the cluster",
	_NCR_EngineContractStillNamesTheCluster)
