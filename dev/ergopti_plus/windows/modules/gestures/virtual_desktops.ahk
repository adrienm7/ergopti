; modules/gestures/virtual_desktops.ahk

; ==============================================================================
; MODULE: Virtual Desktop Navigation (AHK)
; DESCRIPTION:
; The desktop_prev_wrap / desktop_next_wrap actions: one virtual desktop left or
; right, wrapping from the last desktop to the first and from the first to the
; last. The plain desktop_prev / desktop_next actions stay the Ctrl+Win+Arrow
; rows of the shared catalogue, because Windows itself stops at both ends.
;
; FEATURES & RATIONALE:
; 1. One rule for the three drivers. DesktopNavigationTarget ports
;    _shared/lua/desktop_navigation (the macOS and Linux drivers' rule) and the
;    unit suite replays _shared/tests/corpus/desktop_navigation/vectors.json
;    against it.
; 2. The position comes from the registry Explorer keeps: VirtualDesktopIDs
;    lists every desktop GUID in order, CurrentVirtualDesktop names the active
;    one. Windows 11 keeps the current desktop next to the list; Windows 10
;    keeps it under the session's own SessionInfo key. No undocumented COM
;    interface is involved, so no Windows build can break the call itself.
; 3. The jump is Ctrl+Win+Arrow repeated: Windows offers no documented way to
;    name the desktop to switch to, and the keystroke is the one the plain
;    actions already send (read from the generated catalogue rows, not spelled
;    again here).
; 4. Fail fast on a read the rule cannot place: a current desktop missing from
;    the list is a failed read, never a position to guess. The action then
;    moves one desktop without wrapping and says why in the log.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Index maths (pure) ========
; ======================================
; ======================================

; The desktop one step lands on. Port of _shared/lua/desktop_navigation.
; @param {Integer} Index 0-based position of the current desktop.
; @param {Integer} Count Number of desktops (at least 1).
; @param {String} Direction "prev" or "next".
; @param {Boolean} Wrap True to go to the other end from an edge.
; @returns {Integer} 0-based target; equal to Index when the step stays.
; @throws {ValueError} On an input the rule cannot place.
DesktopNavigationTarget(Index, Count, Direction, Wrap) {
	if !(Count is Integer) || (Count < 1)
		throw ValueError("DesktopNavigationTarget: the desktop count must be a whole number >= 1, got " . String(Count))
	if !(Index is Integer) || (Index < 0) || (Index >= Count)
		throw ValueError("DesktopNavigationTarget: index " . String(Index) . " is outside the " . Count . " desktop(s)")
	if (Direction == "prev")
		Step := -1
	else if (Direction == "next")
		Step := 1
	else
		throw ValueError("DesktopNavigationTarget: unknown direction '" . String(Direction) . "'")
	if !(Wrap is Integer) || (Wrap != 0 && Wrap != 1)
		throw ValueError("DesktopNavigationTarget: wrap must be a boolean, got " . String(Wrap))
	Target := Index + Step
	if (Target >= 0 && Target < Count)
		return Target
	if !Wrap
		return Index
	return Mod(Target + Count, Count)
}

; The signed number of single steps from the current desktop to the target.
; @returns {Integer} Negative towards the first desktop, 0 to stay.
DesktopNavigationSteps(Index, Count, Direction, Wrap) {
	return DesktopNavigationTarget(Index, Count, Direction, Wrap) - Index
}





; ============================================
; ============================================
; ======= 2/ Reading the desktop state =======
; ============================================
; ============================================

; Registry locations Explorer keeps its virtual desktops in. A function, not a
; global, so include order cannot matter.
; @returns {Object} { List, Session } key paths; Session takes the session id.
VirtualDesktopRegistryKeys() {
	static Keys := {
		List: "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops",
		Session: "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\{1}\VirtualDesktops",
	}
	return Keys
}

; A desktop id is a 16-byte GUID, which RegRead returns as 32 hex digits.
VirtualDesktopIdHexLength() {
	return 32
}

; The position of the current desktop among the listed ones.
; @param {String} IdsHex VirtualDesktopIDs as RegRead returns it ("" when
;   Explorer never listed a second desktop).
; @param {String} CurrentId CurrentVirtualDesktop as RegRead returns it ("" when
;   the value is absent).
; @returns {Object} { Index, Count } with a 0-based Index.
; @throws {ValueError} When the list is malformed or does not hold the current desktop.
VirtualDesktopStateFrom(IdsHex, CurrentId) {
	IdLength := VirtualDesktopIdHexLength()
	; Explorer writes the list only once a second desktop exists: an absent list
	; is the single desktop every session starts with.
	if (IdsHex = "")
		return { Index: 0, Count: 1 }
	if Mod(StrLen(IdsHex), IdLength) != 0
		throw ValueError("VirtualDesktopIDs holds " . StrLen(IdsHex) . " hex digits, not whole desktop ids")
	Count := StrLen(IdsHex) // IdLength
	if (Count = 1)
		return { Index: 0, Count: 1 }
	if (StrLen(CurrentId) != IdLength)
		throw ValueError("the current desktop id is unreadable ('" . CurrentId . "')")
	loop Count {
		if (SubStr(IdsHex, (A_Index - 1) * IdLength + 1, IdLength) = CurrentId)
			return { Index: A_Index - 1, Count: Count }
	}
	throw ValueError("the current desktop is not among the " . Count . " listed desktops")
}

; Reads the current desktop's position and the desktop count from the registry.
; @param {String} ListKey Key holding VirtualDesktopIDs (and, on Windows 11,
;   CurrentVirtualDesktop). Defaults to Explorer's own key.
; @param {String} SessionKey Windows 10 key holding CurrentVirtualDesktop, with
;   {1} standing for the session id. Defaults to Explorer's own key.
; @returns {Object} { Index, Count } with a 0-based Index.
; @throws {Error} When the registry does not give a position.
VirtualDesktopReadState(ListKey := "", SessionKey := "") {
	Keys := VirtualDesktopRegistryKeys()
	if (ListKey = "")
		ListKey := Keys.List
	if (SessionKey = "")
		SessionKey := Keys.Session
	if !Reg_TryRead(ListKey, "VirtualDesktopIDs", &IdsHex)
		IdsHex := ""
	if !Reg_TryRead(ListKey, "CurrentVirtualDesktop", &CurrentId) {
		SessionId := SystemControl().SessionId()
		if !Reg_TryRead(Format(SessionKey, SessionId), "CurrentVirtualDesktop", &CurrentId)
			CurrentId := ""
	}
	return VirtualDesktopStateFrom(IdsHex, CurrentId)
}





; ==================================
; ==================================
; ======= 3/ The wrap action =======
; ==================================
; ==================================

; Moves one desktop in a direction, wrapping at the edges.
; @param {String} Direction "prev" or "next".
; @param {Func} ReadState Test seam: returns { Index, Count }; the registry
;   reader when omitted.
; @param {Func} Press Test seam: presses (Key, Mods); TextPressKey when omitted.
; @returns {Integer} The number of Ctrl+Win+Arrow presses sent.
GestureDesktopNavigateWrap(Direction, ReadState := 0, Press := 0) {
	ReadFn := HasMethod(ReadState, "Call") ? ReadState : VirtualDesktopReadState
	PressFn := HasMethod(Press, "Call") ? Press : TextPressKey
	if (Direction != "prev" && Direction != "next")
		throw ValueError("GestureDesktopNavigateWrap: unknown direction '" . String(Direction) . "'")
	Rows := GestureEmitActionsData()
	try {
		State := ReadFn()
		Steps := DesktopNavigationSteps(State.Index, State.Count, Direction, true)
	} catch as Err {
		LoggerWarn("gestures", "Cannot wrap the virtual desktops ({1}) — moving one desktop without wrapping.", Err.Message)
		Step := Rows[Direction == "next" ? "desktop_next" : "desktop_prev"]
		PressFn(Step.Key, Step.Mods)
		return 1
	}
	if (Steps = 0) {
		LoggerDebug("gestures", "A single virtual desktop — nothing to wrap to.")
		return 0
	}
	Step := Rows[Steps > 0 ? "desktop_next" : "desktop_prev"]
	if (Abs(Steps) > 1)
		LoggerDebug("gestures", "Wrapping from desktop {1} to desktop {2} of {3}.",
			State.Index + 1, State.Index + Steps + 1, State.Count)
	loop Abs(Steps)
		PressFn(Step.Key, Step.Mods)
	return Abs(Steps)
}
