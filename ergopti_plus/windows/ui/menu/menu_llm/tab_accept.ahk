; ui/menu/menu_llm/tab_accept.ahk

; ==============================================================================
; MODULE: LLM Tray — Tab Accept + Nav hotkeys
; DESCRIPTION:
; Owns the slot-navigation hotkeys (nav_modifiers + an arrow, val_modifiers +
; 1..9, 0) that move the active slot when the tooltip shows multiple
; predictions. The physical Tab that accepts the visible prediction is an SC00F
; variant in platform/remap/tab.ahk: AutoHotkey looks the physical Tab up by
; its scan code once any SC00F hotkey exists, so a `Tab::` hotkey here never
; fired (llm-tab-accepts-visible-prediction).
;
; FEATURES & RATIONALE:
; 1. Tab outside a prediction: when no tooltip offers text, Tab passes through
;    to the active app — the user keeps the OS-native Tab behaviour everywhere
;    except when actively reviewing a prediction.
; 2. Cycle wraps around: Up past the first slot loops to the last, and Down
;    past the last loops back to the first — feels snappier than a hard stop
;    at the boundary.
; 3. Navigation is consumed: while the native owner routes a multi-slot
;    prediction, its chord moves the marker and never reaches the application,
;    like the macOS tooltip (handle_llm_keys). Up and Left step back, Down and
;    Right forward, as the shared label (↑/← and ↓/→) says, and so do the left
;    and right Shift+Tab the tooltip footer advertises (⇧G + Tab, ⇧D + Tab);
;    Windows had none of these but Up and Down, and they moved the caret
;    instead (llm-nav-left-right-windows). The hotkeys below perform the cycle
;    themselves; the native owner never cycles, so the order in which Windows
;    calls the two keyboard hooks cannot drop or double a press
;    (llm-tooltip-nav-consumed, llm-nav-cycle-windows).
; ==============================================================================

#Requires AutoHotkey v2.0

LLM_Menu_CommitNavModifier(Key, Raw, CommitFn := 0, ApplyFn := 0,
		RejectFn := 0, TransactionPort := 0) {
	if !(Key == "nav_modifiers" || Key == "val_modifiers")
		return false
	Context := Key == "nav_modifiers"
		? "the LLM navigation-modifier setting"
		: "the LLM validation-modifier setting"
	if !(Raw is String) || !LLM_Menu_IsValidModifierString(Raw) {
		if HasMethod(RejectFn, "Call")
			return RejectFn.Call(Context, Raw)
		return ConfigReportPersistenceFailure(Context, 0,
			"the modifier syntax is invalid")
	}
	MutateFn := (Candidate) => _LLM_Menu_SetCandidateValue(Candidate, Key,
		Trim(Raw))
	if !HasMethod(CommitFn, "Call")
		return _LLM_Menu_CommitNavMutation(Context, MutateFn, TransactionPort)
	if !HasMethod(ApplyFn, "Call")
		ApplyFn := _LLM_Menu_ApplyNavCommitted
	return CommitFn.Call(Context, MutateFn, ApplyFn)
}

_LLM_Menu_CommitNavMutation(Context, MutateFn, Port := 0) {
	ResolvedPort := Port is Map ? Port : Map()
	DefaultApply := (Args*) => _LLM_Menu_ApplyNavCommitted(Args*)
	DefaultPrepare := (Candidate) => _LLM_Menu_PrepareNavBindingCandidate(Candidate,
		ResolvedPort.Get("hotkey", 0), ResolvedPort.Get("hotif", 0),
		ResolvedPort.Get("log", 0), ResolvedPort.Get("reset", 0),
		ResolvedPort.Get("key_resolver", 0),
		ResolvedPort.Get("native_owner", 0))
	DefaultPublish := (CandidateFeatures, CandidateMenu, Owner) =>
		_LLM_Menu_PublishPreparedNavCandidate(CandidateFeatures,
			CandidateMenu, Owner)
	return LLM_Menu_CommitMutation(Context, MutateFn,
		ResolvedPort.Get("apply", DefaultApply),
		ResolvedPort.Get("writer", 0), ResolvedPort.Get("notify", 0),
		ResolvedPort.Get("acquire", 0), ResolvedPort.Get("settle", 0),
		ResolvedPort.Get("collect", 0), DefaultPrepare, DefaultPublish)
}





; ===============================================
; ===============================================
; ======= 1/ Navigation Chord Consumption =======
; ===============================================
; ===============================================

; The physical Tab that accepts a prediction is not declared here: see the
; module header and platform/remap/tab.ahk (8.5).
;
; These hotkeys own the cycle: while the native owner routes a multi-slot
; prediction, they move its marker and swallow the chord, so the caret never
; moves in the application behind the tooltip (macOS consumes the arrows the
; same way). Windows calls the most recently installed keyboard hook first, and
; AutoHotkey reinstalls its own around every SendInput, so this hook runs before
; or after the native owner's depending on what was typed last. The native owner
; therefore never cycles: its cycle routes are parked on a key no keyboard has
; (adapters/llm_nav_event_owner.ahk), and each press moves the marker exactly
; once in either order (llm-nav-cycle-windows). The wildcard lets one hotkey
; serve every configured modifier; the criterion demands the exact chord of the
; committed plan. #InputLevel 1 is the native routes' own level: both take
; physical input and AutoHotkey output above it. AutoHotkey resolves each arrow
; by scan code (SC148, SC150, SC14B, SC14D). Naming an arrow would lose
; to the registry emulation's dead-key reset on the same scan-code identity.
;
; Shift+Tab is the footer's other chord, whatever nav_modifiers holds: the left
; Shift steps back and the right one forward, as on macOS, with no other
; modifier. The physical Tab is its scan code, SC00F (platform/remap/tab.ahk).
; A side-specific Shift is the most specific SC00F hotkey under that Shift, so
; the hook resolves the chord here first and falls back to the Tab key's other
; owners, which keep every other Shift+Tab, when the criterion refuses it.
#InputLevel 1
#HotIf LLM_Menu_NavCycleChordIsOwned("Up")
*SC148:: LLM_Menu_NavCycleChord("Up")
#HotIf LLM_Menu_NavCycleChordIsOwned("Down")
*SC150:: LLM_Menu_NavCycleChord("Down")
#HotIf LLM_Menu_NavCycleChordIsOwned("Left")
*SC14B:: LLM_Menu_NavCycleChord("Left")
#HotIf LLM_Menu_NavCycleChordIsOwned("Right")
*SC14D:: LLM_Menu_NavCycleChord("Right")
#HotIf LLM_Menu_NavShiftTabIsOwned("LShift")
<+SC00F:: LLM_Menu_NavShiftTabCycle("LShift")
#HotIf LLM_Menu_NavShiftTabIsOwned("RShift")
>+SC00F:: LLM_Menu_NavShiftTabCycle("RShift")
#HotIf
#InputLevel 0

; Cycle routes of the committed plan (entries 1 and 2) by key, with the scan
; code the wildcard hotkey above resolves the key to and the slot step it moves.
global LLM_NAV_CYCLE_ROUTES := Map(
	"Up", Map("index", 1, "code", "sc0148", "delta", -1),
	"Down", Map("index", 2, "code", "sc0150", "delta", 1))

; Each arrow the hotkeys above consume, and the cycle route whose chord and step
; it shares: Left steps back like Up and Right forward like Down. The plan keeps
; only the two native cycle routes the DLL contract requires, so Left and Right
; never become native routes.
global LLM_NAV_CYCLE_KEYS := Map("Up", "Up", "Down", "Down",
	"Left", "Up", "Right", "Down")

; The Shift of each Shift+Tab navigation chord and the slot step it moves: the
; left one back (⇧G + Tab), the right one forward (⇧D + Tab).
global LLM_NAV_SHIFT_TAB_STEPS := Map("LShift", -1, "RShift", 1)

/**
 * The committed cycle route whose chord and step an arrow shares.
 * @param {String} Key - "Up", "Down", "Left" or "Right".
 * @returns {Map|Integer} The route, or 0 for another key or before this file's
 *     globals are assigned, since a #HotIf criterion is live before them.
 */
_LLM_Menu_NavCycleRoute(Key) {
	global LLM_NAV_CYCLE_ROUTES, LLM_NAV_CYCLE_KEYS
	if !IsSet(LLM_NAV_CYCLE_ROUTES) || !IsSet(LLM_NAV_CYCLE_KEYS)
			|| !LLM_NAV_CYCLE_KEYS.Has(Key)
		return 0
	return LLM_NAV_CYCLE_ROUTES[LLM_NAV_CYCLE_KEYS[Key]]
}

/**
 * The #HotIf of the hotkeys that consume the navigation chord: whether the
 * arrow press being resolved is the committed cycle chord, with exactly its
 * modifiers held, while the native owner routes a multi-slot prediction. Any
 * other modifier set, one slot, or an owner that is not routing leaves the key
 * to the application.
 * @param {String} Key - "Up", "Down", "Left" or "Right".
 * @param {Func} ModifierIsHeldFn - Test seam taking "Ctrl", "Alt", "Shift",
 *     "LWin" or "RWin"; the logical key state when omitted, which is what a
 *     hotkey without the wildcard would compare.
 * @returns {Boolean}
 */
LLM_Menu_NavCycleChordIsOwned(Key, ModifierIsHeldFn := 0) {
	global _LLM_Menu_NavHotkeysBound
	; A #HotIf criterion is live before this file's globals are assigned.
	if !IsSet(_LLM_Menu_NavHotkeysBound)
			|| !(_LLM_Menu_NavHotkeysBound is Array)
		return false
	Route := _LLM_Menu_NavCycleRoute(Key)
	if !(Route is Map)
		return false
	if _LLM_Menu_NavHotkeysBound.Length < Route["index"]
		return false
	Entry := _LLM_Menu_NavHotkeysBound[Route["index"]]
	if !(Entry is Map)
		return false
	; The route's physical identity is what the native plan committed: its
	; modifiers are the exact chord, and its key must be the route's own (Up or
	; Down), whose chord Left and Right share.
	if !RegExMatch(Entry.Get("physical_id", ""),
			"i)^([\^!+#]*)" . Route["code"] . "$", &Match)
		return false
	Chord := Match[1]
	if !HasMethod(ModifierIsHeldFn, "Call")
		ModifierIsHeldFn := GetKeyState
	for Symbol, Name in Map("^", "Ctrl", "!", "Alt", "+", "Shift") {
		if (InStr(Chord, Symbol) > 0) != (ModifierIsHeldFn.Call(Name) ? true : false)
			return false
	}
	WinHeld := ModifierIsHeldFn.Call("LWin") || ModifierIsHeldFn.Call("RWin")
	if (InStr(Chord, "#") > 0) != (WinHeld ? true : false)
		return false
	return LLM_TooltipNavCycleIsOwned()
}

/**
 * The action of the hotkeys that consume the navigation chord: moves the ▶
 * marker one slot, to the previous one for Up and Left and the next one for
 * Down and Right, wrapping around at both ends, and repaints the prediction in
 * place. The native owner never cycles, so this is the only cycle of the press
 * (llm-nav-cycle-windows).
 * @param {String} Key - "Up", "Down", "Left" or "Right".
 * @param {Func} SetActiveIdxFn - Test seam taking the target slot; the in-place
 *     repaint when omitted.
 * @returns {Integer} The slot the marker moved to, or 0 when none moved.
 * @throws {ValueError} For a key that does not cycle.
 */
LLM_Menu_NavCycleChord(Key, SetActiveIdxFn := 0) {
	Route := _LLM_Menu_NavCycleRoute(Key)
	if !(Route is Map)
		throw ValueError("A prediction cycle needs an arrow key.", -1, Key)
	return LLM_TooltipCycleActiveIdx(Route["delta"], SetActiveIdxFn)
}

/**
 * The Shift of the Shift+Tab navigation chord held right now: exactly one Shift
 * and no other modifier. Both Shifts together name no side, so that chord stays
 * the application's.
 * @param {Func} ModifierIsHeldFn - Test seam taking "LShift", "RShift", "Ctrl",
 *     "Alt", "LWin" or "RWin"; the logical key state when omitted.
 * @returns {String} "LShift", "RShift", or "" when no single Shift is the chord.
 */
LLM_Menu_NavShiftTabSide(ModifierIsHeldFn := 0) {
	if !HasMethod(ModifierIsHeldFn, "Call")
		ModifierIsHeldFn := GetKeyState
	for Name in ["Ctrl", "Alt", "LWin", "RWin"] {
		if ModifierIsHeldFn.Call(Name)
			return ""
	}
	Left := ModifierIsHeldFn.Call("LShift") ? true : false
	Right := ModifierIsHeldFn.Call("RShift") ? true : false
	if (Left == Right)
		return ""
	return Left ? "LShift" : "RShift"
}

/**
 * The #HotIf of the hotkeys that consume Shift+Tab: whether Side's Shift alone
 * is held with the Tab being resolved while the native owner routes a
 * multi-slot prediction. The Tab key's own owners keep the press
 * (platform/remap/tab.ahk): the navigation layer while it is held, the Kana
 * AltGr, which AutoHotkey does not count as a modifier, and the auto-repeat of
 * a press a Tab tap-hold owns.
 * @param {String} Side - "LShift" or "RShift".
 * @param {Func} ModifierIsHeldFn - Test seam of LLM_Menu_NavShiftTabSide.
 * @returns {Boolean}
 */
LLM_Menu_NavShiftTabIsOwned(Side, ModifierIsHeldFn := 0) {
	global LLM_NAV_SHIFT_TAB_STEPS, LayerEnabled
	; A #HotIf criterion is live before this file's globals are assigned.
	if !IsSet(LLM_NAV_SHIFT_TAB_STEPS) || !LLM_NAV_SHIFT_TAB_STEPS.Has(Side)
		return false
	if LLM_Menu_NavShiftTabSide(ModifierIsHeldFn) != Side
		return false
	if IsSet(LayerEnabled) && LayerEnabled
		return false
	if IsSet(TapHoldKanaAltGrHeld) && TapHoldKanaAltGrHeld()
		return false
	if IsSet(TapHoldPressIsOwned) && TapHoldPressIsOwned("tab")
		return false
	return LLM_TooltipNavCycleIsOwned()
}

/**
 * The action of the hotkeys that consume Shift+Tab: moves the ▶ marker one slot
 * back for the left Shift and forward for the right one, wrapping around, like
 * the arrows (LLM_TooltipCycleActiveIdx).
 * @param {String} Side - "LShift" or "RShift".
 * @param {Func} SetActiveIdxFn - Test seam taking the target slot; the in-place
 *     repaint when omitted.
 * @returns {Integer} The slot the marker moved to, or 0 when none moved.
 * @throws {ValueError} For another side.
 */
LLM_Menu_NavShiftTabCycle(Side, SetActiveIdxFn := 0) {
	global LLM_NAV_SHIFT_TAB_STEPS
	if !LLM_NAV_SHIFT_TAB_STEPS.Has(Side)
		throw ValueError("A Shift+Tab cycle needs the left or right Shift.", -1, Side)
	return LLM_TooltipCycleActiveIdx(LLM_NAV_SHIFT_TAB_STEPS[Side], SetActiveIdxFn)
}

/**
 * A tap-hold's Tab tapped under one Shift is the user's Shift+Tab: the
 * recommended AltGr taps Tab, and a Tab tap-hold emits its own. While the native
 * owner routes a multi-slot prediction it moves the marker like the physical
 * chord, and nothing is typed (llm-nav-left-right-windows).
 * @param {Func} ModifierIsHeldFn - Test seam of LLM_Menu_NavShiftTabSide.
 * @param {Func} SetActiveIdxFn - Test seam of LLM_Menu_NavShiftTabCycle.
 * @returns {Boolean} True when the tap was the navigation chord and is consumed.
 */
LLM_Menu_NavShiftTabTap(ModifierIsHeldFn := 0, SetActiveIdxFn := 0) {
	Side := LLM_Menu_NavShiftTabSide(ModifierIsHeldFn)
	if Side == "" || !LLM_Menu_NavShiftTabIsOwned(Side, ModifierIsHeldFn)
		return false
	LLM_Menu_NavShiftTabCycle(Side, SetActiveIdxFn)
	return true
}

; ── Slot navigation ──
; When the tooltip shows multiple predictions, the user can cycle the
; active slot with the configured modifier + an arrow. The empty
; nav_modifiers case (default) binds bare arrows — matches the HS
; default where llm_nav_modifiers = {}. val_modifiers + digit N (bare digits
; when val_modifiers is empty) is a consumed native jump that inserts slot N;
; a digit beyond the shown slots passes through, like HS. Both bindings
; re-render the tooltip in place so the ▶ marker moves without any flicker.
global _LLM_Menu_NavHotkeysBound := []
global _LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
global _LLM_Menu_NavActiveSlot := 0
; Stable function reference used as the HotIf predicate for nav/val hotkeys.
; A new lambda on each BindNavHotkeys() call would create a different function
; object, causing Hotkey(..., "Off") to target a different HotIf variant and
; never actually remove the old binding — duplicates would accumulate.
global _LLM_Nav_HotIfPred1 := (ThisHotkey) =>
	_LLM_Menu_NavVariantIsActive(1, ThisHotkey)
global _LLM_Nav_HotIfPred2 := (ThisHotkey) =>
	_LLM_Menu_NavVariantIsActive(2, ThisHotkey)

_LLM_Menu_NavSlotPredicate(Slot) {
	global _LLM_Nav_HotIfPred1, _LLM_Nav_HotIfPred2
	return Slot == 1 ? _LLM_Nav_HotIfPred1 : _LLM_Nav_HotIfPred2
}

_LLM_Menu_NavVariantIsActive(Slot, Spec) {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	PreviousCritical := Critical("On")
	try {
		if _LLM_Menu_NavActiveSlot != Slot
			return false
		NativeIdentity := _LLM_Menu_NavNativeIdentity(Spec)
		if NativeIdentity == "" || !(_LLM_Menu_NavHotkeysBound is Array)
			return false
		try Snapshot := LLM_Tooltip_GetAcceptSnapshot()
		catch
			return false
		if !IsObject(Snapshot) || !(Snapshot.Slots is Array)
			return false
		for Entry in _LLM_Menu_NavHotkeysBound {
			if !(Entry is Map) || Entry.Get("native_id", "") != NativeIdentity
				continue
			JumpIndex := Entry.Get("jump_idx", 0)
			return JumpIndex == 0 || (JumpIndex is Integer
				&& JumpIndex >= 1 && JumpIndex <= Snapshot.Slots.Length)
		}
		return false
	} finally Critical(PreviousCritical)
}

LLM_Menu_NavOwnsSpec(Spec) {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	PreviousCritical := Critical("On")
	try {
		NativeIdentity := _LLM_Menu_NavNativeIdentity(Spec)
		if NativeIdentity == ""
			return false
		if !(_LLM_Menu_NavActiveSlot == 1 || _LLM_Menu_NavActiveSlot == 2)
			return false
		if !(_LLM_Menu_NavHotkeysBound is Array)
			return false
		try Snapshot := LLM_Tooltip_GetAcceptSnapshot()
		catch
			return false
		if !IsObject(Snapshot)
			return false
		for Entry in _LLM_Menu_NavHotkeysBound {
			if !(Entry is Map)
				continue
			EntryIdentity := Entry.Get("native_id", "")
			if EntryIdentity == NativeIdentity
				return true
		}
		return false
	} finally Critical(PreviousCritical)
}

_LLM_Menu_NavNativeHotkey(Args*) {
	Hotkey(Args*)
}

_LLM_Menu_NavNativeHotIf(Args*) {
	HotIf(Args*)
}

_LLM_Menu_NavBindingRecord(Spec, Callback := 0, JumpIndex := 0) {
	return Map("spec", Spec, "callback", Callback, "jump_idx", JumpIndex,
		"native_id", "")
}

_LLM_Menu_NavPlanIsValid(Plan, MenuState) {
	Prefixes := _LLM_Menu_BuildNavModifierPrefixes(MenuState)
	if !(Prefixes is Map) || !(Plan is Array) || Plan.Length != 12
		return false
	NavPrefix := Prefixes["nav_prefix"]
	ValPrefix := Prefixes["val_prefix"]
	SeenSpec := Map()
	SeenNative := Map()
	SeenPhysical := Map()
	Loop Plan.Length {
		Index := A_Index
		if !Plan.Has(Index)
			return false
		Entry := Plan[Index]
		ExpectedJump := Index <= 2 ? 0 : Index - 2
		ExpectedSpec := Index == 1 ? "~" . NavPrefix . "Up"
			: Index == 2 ? "~" . NavPrefix . "Down"
			: ValPrefix . (Index == 12 ? "0" : String(Index - 2))
		if !(Entry is Map)
				|| Entry.Get("spec", "") !== ExpectedSpec
				|| !(Entry.Get("jump_idx", -1) is Integer)
				|| Entry.Get("jump_idx", -1) != ExpectedJump
				|| !HasMethod(Entry.Get("callback", 0), "Call")
				|| !_LLM_Menu_PlanEntryDescriptorIsValid(Entry)
			return false
		NativeId := Entry["native_id"]
		PhysicalId := Entry["physical_id"]
		if SeenSpec.Has(ExpectedSpec) || NativeId == ""
				|| SeenNative.Has(NativeId)
				|| SeenPhysical.Has(PhysicalId)
			return false
		SeenSpec[ExpectedSpec] := true
		SeenNative[NativeId] := true
		SeenPhysical[PhysicalId] := true
	}
	return true
}

_LLM_Menu_NavBindingIndex(Plan) {
	Index := Map()
	for Entry in Plan
		Index[Entry["native_id"]] := Entry
	return Index
}

_LLM_Menu_NavBindingUnion(Plans*) {
	Index := Map()
	for Plan in Plans {
		for Entry in Plan
			Index[Entry["native_id"]] := Entry
	}
	Merged := []
	for , Entry in Index
		Merged.Push(Entry)
	return Merged
}

_LLM_Menu_NavDisableIfPresent(Spec, HotkeyFn) {
	try HotkeyFn.Call(Spec, "Off")
	catch as Err {
		if !(Err is TargetError)
			return false
	}
	return true
}

_LLM_Menu_NavCloseHotIf(HotIfFn, ResetFn) {
	Loop 2 {
		try {
			HotIfFn.Call()
			return true
		} catch {
		}
	}
	try {
		ResetFn.Call()
		return true
	} catch as e {
		throw Error("Navigation HotIf reset could not be proven", -1,
			e.Message)
	}
}

_LLM_Menu_BuildNavBindingPlan(MenuState) {
	Prefixes := _LLM_Menu_BuildNavModifierPrefixes(MenuState)
	if !(Prefixes is Map)
		return false
	nav_prefix := Prefixes["nav_prefix"]
	val_prefix := Prefixes["val_prefix"]
	Plan := [
		_LLM_Menu_NavBindingRecord("~" . nav_prefix . "Up",
			(*) => _LLM_Nav_Cycle(-1)),
		_LLM_Menu_NavBindingRecord("~" . nav_prefix . "Down",
			(*) => _LLM_Nav_Cycle(1))
	]
	Loop 10 {
		Digit := (A_Index == 10) ? "0" : String(A_Index)
		Plan.Push(_LLM_Menu_NavBindingRecord(val_prefix . Digit,
			_LLM_Menu_MakeNavJump(A_Index), A_Index))
	}
	return Map("plan", Plan, "nav_prefix", nav_prefix,
		"val_prefix", val_prefix)
}

_LLM_Menu_RestoreNavBindingPlan(OldPlan, CandidatePlan, HotkeyFn) {
	OldIndex := _LLM_Menu_NavBindingIndex(OldPlan)
	Restored := true
	for Entry in CandidatePlan {
		if OldIndex.Has(Entry["native_id"])
			continue
		if !_LLM_Menu_NavDisableIfPresent(Entry["native_spec"], HotkeyFn)
			Restored := false
	}
	for Entry in OldPlan {
		try HotkeyFn.Call(Entry["native_spec"], Entry["callback"], "On")
		catch
			Restored := false
	}
	return Restored
}

_LLM_Menu_LogNavBindingFailure(Message, LogFn := 0) {
	if HasMethod(LogFn, "Call") {
		try LogFn.Call(Message)
		return
	}
	LoggerError("LLM", "{1}", Message)
}

_LLM_Menu_PrepareNavHotkeys(MenuState := 0, HotkeyFn := 0, HotIfFn := 0,
		LogFn := 0, ResetFn := 0, KeyResolverFn := 0,
		NativeOwnerPort := 0) {
	global _LLM_Menu, _LLM_Menu_NavSlotPlans, _LLM_Menu_NavActiveSlot
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_Menu_PrepareNavHotkeys(MenuState, HotkeyFn, HotIfFn,
			LogFn, ResetFn, KeyResolverFn, NativeOwnerPort)
		finally Critical(InheritedCritical)
	}

	ResolvedMenu := MenuState is Map ? MenuState : _LLM_Menu
	Built := _LLM_Menu_BuildNavBindingPlan(ResolvedMenu)
	if !(Built is Map) {
		_LLM_Menu_LogNavBindingFailure(
			"Navigation hotkeys rejected: invalid modifier configuration.",
			LogFn)
		return false
	}
	CandidatePlan := Built["plan"]
	; Resolves each chord's native spelling and physical identity from one
	; keyboard-layout snapshot, a digit by its digit-row key; the plan check
	; below refuses any entry left without them, and a duplicate physical owner
	; leaves the plan untouched.
	LayoutResolver := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(LayoutResolver, "Call")
			|| !_LLM_Menu_AttachPlanPhysicalIdentities(CandidatePlan,
				_LLM_Menu_NavDigitRowKey.Bind(LayoutResolver)) {
		_LLM_Menu_LogNavBindingFailure(
			"Navigation hotkeys rejected: physical ownership could not be resolved.",
			LogFn)
		return false
	}
	if !_LLM_Menu_NavPlanIsValid(CandidatePlan, ResolvedMenu) {
		_LLM_Menu_LogNavBindingFailure(
			"Navigation hotkeys rejected: invalid candidate owner.", LogFn)
		return false
	}
	if !(_LLM_Menu_NavActiveSlot == 0 || _LLM_Menu_NavActiveSlot == 1
			|| _LLM_Menu_NavActiveSlot == 2) {
		_LLM_Menu_LogNavBindingFailure(
			"Navigation hotkeys rejected: invalid active slot.", LogFn)
		return false
	}
	CandidateSlot := _LLM_Menu_NavActiveSlot == 1 ? 2 : 1
	if !_LLM_Menu_NavSlotPlans.Has(CandidateSlot)
		_LLM_Menu_NavSlotPlans[CandidateSlot] := []
	OldPlan := _LLM_Menu_NavSlotPlans[CandidateSlot]
	; Production navigation is owned at the keyboard-hook boundary. The legacy
	; Hotkey/HotIf transaction remains only as an injected compatibility seam for
	; its fault-atomicity tests; no production callback may suppress a digit and
	; then re-read a replacement tooltip record.
	UseNativeOwner := !HasMethod(HotkeyFn, "Call")
		&& !HasMethod(HotIfFn, "Call")
	if UseNativeOwner {
		NativeGeneration := LLM_NavEventOwner_PreparePlan(CandidatePlan,
			NativeOwnerPort)
		if !(NativeGeneration is Integer) || NativeGeneration <= 0 {
			_LLM_Menu_LogNavBindingFailure(
				"Navigation event owner rejected the candidate plan.", LogFn)
			return false
		}
		PreviousCritical := Critical("On")
		try _LLM_Menu_NavSlotPlans[CandidateSlot] := CandidatePlan
		finally Critical(PreviousCritical)
		return Map("slot", CandidateSlot, "plan", CandidatePlan,
			"native_owner", true,
			"native_generation", NativeGeneration)
	}
	SlotPredicate := _LLM_Menu_NavSlotPredicate(CandidateSlot)
	if !HasMethod(HotkeyFn, "Call")
		HotkeyFn := _LLM_Menu_NavNativeHotkey
	if !HasMethod(HotIfFn, "Call")
		HotIfFn := _LLM_Menu_NavNativeHotIf
	if !HasMethod(ResetFn, "Call")
		ResetFn := _LLM_Menu_NavNativeHotIf

	PreviousCritical := Critical("On")
	OpenAttempted := false
	Succeeded := false
	FailureDetail := ""
	AttemptedPlan := []
	Owner := 0
	ResetFailure := 0
	try {
		try {
			try {
				OpenAttempted := true
				HotIfFn.Call(SlotPredicate)
				for Entry in CandidatePlan {
					AttemptedPlan.Push(Entry)
					HotkeyFn.Call(Entry["native_spec"], Entry["callback"], "On")
				}
				CandidateIndex := _LLM_Menu_NavBindingIndex(CandidatePlan)
				for Entry in OldPlan {
					if !CandidateIndex.Has(Entry["native_id"])
							&& !_LLM_Menu_NavDisableIfPresent(
								Entry["native_spec"],
								HotkeyFn)
						throw Error("retired navigation variant could not be disabled")
				}
				Succeeded := true
			} catch as e {
				RollbackSelected := false
				try {
					HotIfFn.Call(SlotPredicate)
					RollbackSelected := true
				} catch {
				}
				Restored := RollbackSelected
					&& _LLM_Menu_RestoreNavBindingPlan(OldPlan,
						AttemptedPlan, HotkeyFn)
				FailureDetail := "Navigation hotkey transaction failed: " . e.Message
				if !Restored {
					FailureDetail .= "; restoring the previous generation was refused"
					_LLM_Menu_NavSlotPlans[CandidateSlot] :=
						_LLM_Menu_NavBindingUnion(OldPlan, AttemptedPlan)
				}
			}
		} finally {
			if OpenAttempted {
				try _LLM_Menu_NavCloseHotIf(HotIfFn, ResetFn)
				catch as e {
					ResetFailure := e
					Succeeded := false
					_LLM_Menu_NavSlotPlans[CandidateSlot] :=
						_LLM_Menu_NavBindingUnion(OldPlan, AttemptedPlan)
					FailureDetail := e.Message
				}
			}
			if Succeeded {
				Owner := Map("slot", CandidateSlot, "plan", CandidatePlan)
				_LLM_Menu_NavSlotPlans[CandidateSlot] := CandidatePlan
			}
		}
	} finally Critical(PreviousCritical)
	if IsObject(ResetFailure) {
		_LLM_Menu_LogNavBindingFailure(FailureDetail, LogFn)
		throw ResetFailure
	}
	if !Succeeded {
		_LLM_Menu_LogNavBindingFailure(FailureDetail, LogFn)
		return false
	}
	return Owner
}

_LLM_Menu_PrepareNavBindingCandidate(CandidateMenu, HotkeyFn := 0,
		HotIfFn := 0, LogFn := 0, ResetFn := 0, KeyResolverFn := 0,
		NativeOwnerPort := 0) {
	return _LLM_Menu_PrepareNavHotkeys(CandidateMenu, HotkeyFn, HotIfFn,
		LogFn, ResetFn, KeyResolverFn, NativeOwnerPort)
}

_LLM_Menu_PublishPreparedNavCandidate(CandidateFeatures, CandidateMenu,
		Owner) {
	global Features, _LLM_Menu, _LLM_Menu_NavHotkeysBound
	global _LLM_Menu_NavSlotPlans, _LLM_Menu_NavActiveSlot
	if !(CandidateFeatures is Map) || !(CandidateMenu is Map)
			|| !(Owner is Map) || !Owner.Has("slot") || !Owner.Has("plan")
		return false
	Slot := Owner["slot"]
	PreviousCritical := Critical("On")
	try {
		if !(Slot == 1 || Slot == 2)
				|| !_LLM_Menu_NavSlotPlans.Has(Slot)
				|| !(_LLM_Menu_NavSlotPlans[Slot] == Owner["plan"])
				|| !_LLM_Menu_NavPlanIsValid(Owner["plan"], CandidateMenu)
			return false
		if Owner.Get("native_owner", false) {
			Generation := Owner.Get("native_generation", 0)
			if !(Generation is Integer) || Generation <= 0
					|| !LLM_NavEventOwner_CommitPlan(Generation)
				return false
		}
		Features := CandidateFeatures
		_LLM_Menu := CandidateMenu
		_LLM_Menu_NavHotkeysBound := Owner["plan"]
		_LLM_Menu_NavActiveSlot := Slot
		return true
	} finally Critical(PreviousCritical)
}

LLM_Menu_BindNavHotkeys(MenuState := 0, HotkeyFn := 0, HotIfFn := 0,
		LogFn := 0, ResetFn := 0, KeyResolverFn := 0,
		NativeOwnerPort := 0) {
	Owner := _LLM_Menu_PrepareNavHotkeys(MenuState, HotkeyFn, HotIfFn,
		LogFn, ResetFn, KeyResolverFn, NativeOwnerPort)
	if !(Owner is Map)
		return false
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	global _LLM_Menu
	ResolvedMenu := MenuState is Map ? MenuState : _LLM_Menu
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_NavPlanIsValid(Owner["plan"], ResolvedMenu)
			return false
		if Owner.Get("native_owner", false) {
			Generation := Owner.Get("native_generation", 0)
			if !(Generation is Integer) || Generation <= 0
					|| !LLM_NavEventOwner_CommitPlan(Generation)
				return false
		}
		_LLM_Menu_NavHotkeysBound := Owner["plan"]
		_LLM_Menu_NavActiveSlot := Owner["slot"]
		return true
	} finally Critical(PreviousCritical)
}

_LLM_Menu_MakeNavJump(idx) {
	return (*) => _LLM_Nav_Jump(idx)
}





; ==========================================
; ==========================================
; ======= 2/ Slot Navigation Helpers =======
; ==========================================
; ==========================================

; The cycle callback of a plan bound as AutoHotkey hotkeys: moves the ▶ marker
; one slot through the public tooltip API, like the digit jumps below. The
; native owner never fires it, since its cycle routes are parked
; (LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES): the consuming *Up / *Down hotkeys
; cycle the prediction it routes through LLM_Menu_NavCycleChord instead.
_LLM_Nav_Cycle(delta) {
	slots := LLM_Tooltip_GetSlots()
	if (slots.Length <= 1)
		return
	LLM_Tooltip_SetActiveIdx(LLM_TooltipWrapSlot(LLM_Tooltip_GetActiveIdx(),
		delta, slots.Length))
}

_LLM_Nav_Jump(idx) {
	slots := LLM_Tooltip_GetSlots()
	if (idx > slots.Length)
		return
	LLM_Tooltip_SetActiveIdx(idx)
}
