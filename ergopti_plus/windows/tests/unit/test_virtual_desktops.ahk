; tests/unit/test_virtual_desktops.ahk

; ==============================================================================
; MODULE: Virtual desktop navigation, plain and wrapping (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/desktop_navigation/vectors.json, the corpus the
; macOS and Linux suites replay too, against DesktopNavigationTarget; reads the
; desktop state from registry values shaped like Explorer's (Windows 10 and
; Windows 11 locations) under a private test key; and drives the
; desktop_prev_wrap / desktop_next_wrap action with a scripted desktop state
; and a recording key press.
;
; ROOT CAUSE ENCODED:
; Windows offered only desktop_prev / desktop_next, which press Ctrl+Win+Arrow
; and stop at the first and last desktop: nothing could go from the last
; desktop to the first. The wrapping actions read the position Explorer keeps
; and press Ctrl+Win+Arrow once per desktop back across the row.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ The shared index maths ==========
; ============================================
; ============================================

; @returns {Map} The decoded corpus.
_VDT_Corpus() {
	global _SharedDir
	AssertTrue(IsSet(_SharedDir), "the harness must expose _SharedDir")
	Path := _SharedDir . "\tests\corpus\desktop_navigation\vectors.json"
	AssertTrue(FileExist(Path) != "", "the desktop navigation corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_VDT_ReplayCorpus() {
	Corpus := _VDT_Corpus()
	Checked := 0
	for _, Vector in Corpus["vectors"] {
		Target := DesktopNavigationTarget(Vector["index"], Vector["count"], Vector["direction"], Vector["wrap"])
		AssertEqual(Vector["target"], Target, Vector["id"])
		AssertEqual(Vector["target"] - Vector["index"],
			DesktopNavigationSteps(Vector["index"], Vector["count"], Vector["direction"], Vector["wrap"]),
			Vector["id"] . " steps")
		Checked += 1
	}
	AssertTrue(Checked >= 20, "expected at least 20 vectors, found " . Checked)
}
Test("desktop navigation: the index maths replay the shared corpus", _VDT_ReplayCorpus)

; One invalid vector per call, so the refused call reads a parameter. A
; closure never sees a for-loop variable: built in the loop, it threw an
; UnsetError that AssertThrows accepted whatever DesktopNavigationTarget did.
; @param Vector {Map} One entry of the corpus "invalid" list.
_VDT_RefusesInvalidRead(Vector) {
	AssertThrows(() => DesktopNavigationTarget(Vector["index"], Vector["count"],
		Vector["direction"], Vector["wrap"]), Vector["id"] . " must be refused")
}

_VDT_RefusesInvalidReads() {
	Corpus := _VDT_Corpus()
	Refused := 0
	for _, Vector in Corpus["invalid"] {
		_VDT_RefusesInvalidRead(Vector)
		Refused += 1
	}
	AssertTrue(Refused >= 7, "expected at least 7 invalid inputs, found " . Refused)
}
Test("desktop navigation: every invalid read is refused", _VDT_RefusesInvalidReads)

_VDT_WrapsAtTheLastDesktop() {
	AssertEqual(0, DesktopNavigationTarget(3, 4, "next", true), "the last desktop wraps to the first")
	AssertEqual(3, DesktopNavigationTarget(3, 4, "next", false), "and stays put without wrapping")
	AssertEqual(3, DesktopNavigationTarget(0, 4, "prev", true), "the first desktop wraps to the last")
	AssertEqual(0, DesktopNavigationTarget(0, 4, "prev", false), "and stays put without wrapping")
}
Test("desktop navigation: wrap at the last desktop goes to the first, plain does not", _VDT_WrapsAtTheLastDesktop)





; ============================================
; ============================================
; ======= 2/ The registry state ==============
; ============================================
; ============================================

; A desktop GUID as RegRead returns it: 32 hex digits.
_VDT_Id(N) {
	return Format("{:032X}", N)
}

_VDT_StateFromValues() {
	State := VirtualDesktopStateFrom("", "")
	AssertEqual(0, State.Index, "no list: the single desktop every session starts with")
	AssertEqual(1, State.Count)
	State := VirtualDesktopStateFrom(_VDT_Id(7), "")
	AssertEqual(0, State.Index, "one listed desktop needs no current id")
	AssertEqual(1, State.Count)
	State := VirtualDesktopStateFrom(_VDT_Id(1) . _VDT_Id(2) . _VDT_Id(3), _VDT_Id(3))
	AssertEqual(2, State.Index, "the current desktop is the third listed")
	AssertEqual(3, State.Count)
	State := VirtualDesktopStateFrom(_VDT_Id(10) . _VDT_Id(11), StrLower(_VDT_Id(10)))
	AssertEqual(0, State.Index, "hex digits compare without case")
}
Test("virtual desktops: the position comes from the listed ids", _VDT_StateFromValues)

_VDT_StateRefusesAFailedRead() {
	AssertThrows(() => VirtualDesktopStateFrom(_VDT_Id(1) . "ABC", _VDT_Id(1)),
		"a list that is not whole ids must be refused")
	AssertThrows(() => VirtualDesktopStateFrom(_VDT_Id(1) . _VDT_Id(2), _VDT_Id(9)),
		"a current desktop missing from the list must be refused")
	AssertThrows(() => VirtualDesktopStateFrom(_VDT_Id(1) . _VDT_Id(2), ""),
		"several desktops and no current one must be refused")
}
Test("virtual desktops: a failed read is refused, never placed", _VDT_StateRefusesAFailedRead)

_VDT_ReadsBothRegistryLayouts() {
	Root := "HKCU\Software\ErgoptiTests\VirtualDesktops_" . A_TickCount
	ListKey := Root . "\List"
	SessionKey := Root . "\SessionInfo\{1}\VirtualDesktops"
	SessionId := 0
	AssertTrue(DllCall("ProcessIdToSessionId", "UInt", DllCall("GetCurrentProcessId", "UInt"),
		"UInt*", &SessionId), "the test must know its session")
	try {
		RegWrite(_VDT_Id(1) . _VDT_Id(2) . _VDT_Id(3), "REG_BINARY", ListKey, "VirtualDesktopIDs")
		; Windows 10: the current desktop is under the session's own key only.
		RegWrite(_VDT_Id(2), "REG_BINARY", Format(SessionKey, SessionId), "CurrentVirtualDesktop")
		State := VirtualDesktopReadState(ListKey, SessionKey)
		AssertEqual(1, State.Index, "Windows 10 layout")
		AssertEqual(3, State.Count)
		; Windows 11: the current desktop sits next to the list, and wins.
		RegWrite(_VDT_Id(3), "REG_BINARY", ListKey, "CurrentVirtualDesktop")
		State := VirtualDesktopReadState(ListKey, SessionKey)
		AssertEqual(2, State.Index, "Windows 11 layout")
	} finally {
		AssertTrue(Reg_DeleteKey("HKCU\Software\ErgoptiTests"), "the private test key must be removed")
	}
}
Test("virtual desktops: reads the Windows 10 and Windows 11 registry layouts", _VDT_ReadsBothRegistryLayouts)





; ============================================
; ============================================
; ======= 3/ The actions =====================
; ============================================
; ============================================

; Runs the wrap action against a scripted state and returns the keys pressed.
; @param {String} Direction "prev" or "next".
; @param {Object|String} State { Index, Count }, or "fail" for an unreadable one.
; @returns {Array} "Key:Mod+Mod" for each press.
_VDT_Presses(Direction, State) {
	Pressed := []
	ReadState := (*) => (IsObject(State) ? State : _VDT_Throw())
	Press := (Key, Mods) => Pressed.Push(Key . ":" . _VDT_JoinMods(Mods))
	Count := GestureDesktopNavigateWrap(Direction, ReadState, Press)
	AssertEqual(Pressed.Length, Count, "the action must report the presses it sent")
	return Pressed
}

_VDT_Throw() {
	throw Error("CurrentVirtualDesktop is unreadable")
}

_VDT_JoinMods(Mods) {
	Out := ""
	for I, Modifier in Mods
		Out .= (I > 1 ? "+" : "") . Modifier
	return Out
}

_VDT_Join(Values) {
	Out := ""
	for I, Value in Values
		Out .= (I > 1 ? ", " : "") . Value
	return Out
}

_VDT_WrapActionPresses() {
	Left := "Left:Ctrl+Win"
	Right := "Right:Ctrl+Win"
	AssertEqual(_VDT_Join([Left, Left, Left]), _VDT_Join(_VDT_Presses("next", { Index: 3, Count: 4 })),
		"next from the last of four desktops walks back three to the first")
	AssertEqual(_VDT_Join([Right, Right, Right]), _VDT_Join(_VDT_Presses("prev", { Index: 0, Count: 4 })),
		"prev from the first of four desktops walks on three to the last")
	AssertEqual(Right, _VDT_Join(_VDT_Presses("next", { Index: 1, Count: 4 })),
		"away from the edge a wrapping step is one press")
	AssertEqual(Left, _VDT_Join(_VDT_Presses("prev", { Index: 1, Count: 2 })))
	AssertEqual("", _VDT_Join(_VDT_Presses("next", { Index: 0, Count: 1 })),
		"a single desktop has nowhere to wrap to")
}
Test("virtual desktops: desktop_*_wrap walk across the row at the edge", _VDT_WrapActionPresses)

_VDT_UnreadableStateMovesOneDesktop() {
	AssertEqual("Right:Ctrl+Win", _VDT_Join(_VDT_Presses("next", "fail")),
		"without a readable position the step is the plain one")
	AssertEqual("Left:Ctrl+Win", _VDT_Join(_VDT_Presses("prev", "fail")))
}
Test("virtual desktops: an unreadable state moves one desktop without wrapping", _VDT_UnreadableStateMovesOneDesktop)

_VDT_ActionsAreRegistered() {
	global GESTURE_ACTIONS
	for _, Id in ["desktop_prev_wrap", "desktop_next_wrap", "desktop_prev", "desktop_next"]
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " must be a registered action")
	; The plain pair stays the catalogue's Ctrl+Win+Arrow row: Windows itself
	; stops at the first and last desktop, so it never wraps.
	AssertEqual("Right", GESTURE_ACTIONS["desktop_next"].Key)
	AssertEqual("Ctrl+Win", _VDT_JoinMods(GESTURE_ACTIONS["desktop_next"].Mods))
	AssertEqual("Left", GESTURE_ACTIONS["desktop_prev"].Key)
	AssertFalse(GESTURE_ACTIONS["desktop_next_wrap"].HasOwnProp("Key"),
		"the wrap is not one keystroke a tap-hold could replay")
}
Test("virtual desktops: plain and wrapping actions are both registered", _VDT_ActionsAreRegistered)
