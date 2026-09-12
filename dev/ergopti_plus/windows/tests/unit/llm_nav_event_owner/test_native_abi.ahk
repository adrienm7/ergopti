; tests/unit/llm_nav_event_owner/test_native_abi.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — No-Hook Native ABI
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 5/ No-hook native ABI =======
; =====================================
; =====================================

_LNEO_NativeEvent(Vk, Sc, Modifiers, Kind, Injected := 0,
		ExtraInfo := 0) {
	return Map(
		"vk", Vk, "sc", Sc, "modifiers", Modifiers,
		"kind", Kind, "injected", Injected, "extra_info", ExtraInfo)
}

_LNEO_AssertNativePassWithoutReceipt(Result, Context) {
	AssertTrue(Result is Map, Context . ": dispatch must return an ABI Map")
	AssertEqual(_LNEO_DISPOSITION_PASS, Result["disposition"],
		Context . ": rejected input must pass through")
	AssertEqual(0, Result["receipt_created"],
		Context . ": rejected input must not reserve a receipt")
}

_LNEO_RealNativeAbiRoundTripDoesNotStartHook() {
	global _LNEO_EVENT_UP
	State := _LNEO_NewNativeState()
	OwnerToken := 0xA707
	try {
		AssertTrue(_LLM_NavEventOwnerNativeStop(),
			"native ABI reset must be harmless before Start")
		Built := _LLM_Menu_BuildNavBindingPlan(
			Map("nav_modifiers", "ctrl", "val_modifiers", "alt"))
		AssertTrue(Built is Map,
			"the ABI test must use the real production plan builder")
		Plan := Built["plan"]
		AssertTrue(_LLM_Menu_AttachPlanPhysicalIdentities(Plan,
			_LNEO_ResolveUsPhysicalKey.Bind(State)),
			"the ABI test must attach deterministic US physical descriptors")
		AssertEqual(12, Plan.Length,
			"the native marshaling subject must contain every production route")

		Generation := _LLM_NavEventOwnerNativePreparePlan(Plan)
		AssertTrue(Generation is Integer && Generation > 0,
			"native plan marshaling must return a nonzero generation")
		AssertTrue(_LLM_NavEventOwnerNativeCommitPlan(Generation),
			"the exact marshaled generation must commit")
		Ticket := _LLM_NavEventOwnerNativeBeginSwap(0, OwnerToken, 7, 1)
		AssertTrue(Ticket is Integer && Ticket > 0,
			"the native owner ABI must stage a nonzero swap ticket")
		AssertTrue(_LLM_NavEventOwnerNativeCommitSwap(Ticket),
			"the staged owner must commit without starting the hook")
		AssertEqual(1, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"the native owner snapshot must initially expose index one")

		DigitDown := _LNEO_NativeEvent(0x37, 0x008, 0x02, 1)
		DigitDecision := _LLM_NavEventOwnerNativeTestDispatch(DigitDown)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			DigitDecision["disposition"],
			"a physical Alt+7 down must be atomically suppressed")
		AssertEqual(1, DigitDecision["receipt_created"],
			"suppression must reserve its receipt before returning")
		DigitUp := _LNEO_NativeEvent(0x37, 0x008, 0x02, _LNEO_EVENT_UP)
		DigitUpDecision := _LLM_NavEventOwnerNativeTestDispatch(DigitUp)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			DigitUpDecision["disposition"],
			"the matching key-up must balance a suppressed key-down")
		AssertEqual(0, DigitUpDecision["receipt_created"],
			"the balancing key-up must not create a second receipt")
		DigitReceipt := _LLM_NavEventOwnerNativePollReceipt()
		AssertEqual(DigitDecision["seq"], DigitReceipt["seq"],
			"Poll must return the exact reserved sequence")
		AssertEqual(OwnerToken, DigitReceipt["owner_token"],
			"the receipt must retain the exact native owner token")
		AssertEqual(7, DigitReceipt["target_idx"],
			"Alt+7 must marshal as one-based target seven")
		AssertEqual(7, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"native semantic state must advance before AHK completion")
		AssertTrue(_LLM_NavEventOwnerNativeCompleteReceipt(
			DigitReceipt["seq"], OwnerToken, 7),
			"completion must marshal sequence, token, and applied index")

		ArrowDecision := _LLM_NavEventOwnerNativeTestDispatch(
			_LNEO_NativeEvent(0x26, 0x148, 0x01, 1))
		AssertEqual(_LNEO_DISPOSITION_PASS, ArrowDecision["disposition"],
			"Ctrl+Up navigation must remain pass-through")
		AssertEqual(1, ArrowDecision["receipt_created"],
			"a pass-through arrow must still own one navigation receipt")
		ArrowReceipt := _LLM_NavEventOwnerNativePollReceipt()
		AssertEqual(6, ArrowReceipt["target_idx"],
			"Ctrl+Up must cycle owner index seven to six")
		AssertTrue(_LLM_NavEventOwnerNativeCompleteReceipt(
			ArrowReceipt["seq"], OwnerToken, 6),
			"the pass-through arrow receipt must complete exactly once")

		SendLevelBase := 0xFFC3D44D
		LowDown := _LNEO_NativeEvent(0x31, 0x002, 0x02, 1, 1,
			SendLevelBase - 1)
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(LowDown),
			"SendLevel equal to InputLevel")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(
				_LNEO_NativeEvent(0x31, 0x002, 0x02,
					_LNEO_EVENT_UP, 1, SendLevelBase - 1)),
			"keyup after fail-open SendLevel")
		AssertEqual(6, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"ineligible injection must leave native owner state unchanged")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(
				_LNEO_NativeEvent(0x31, 0x002, 0x02, 1, 2)),
			"lower-integrity injected keydown")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(
				_LNEO_NativeEvent(0x31, 0x002, 0x02,
					_LNEO_EVENT_UP, 2)),
			"lower-integrity injected keyup")
		AssertEqual(6, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"lower-integrity input must never navigate the native owner")

		HighDown := _LNEO_NativeEvent(0x31, 0x002, 0x02, 1, 1,
			SendLevelBase - 2)
		HighDecision := _LLM_NavEventOwnerNativeTestDispatch(HighDown)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			HighDecision["disposition"],
			"SendLevel above InputLevel must be eligible")
		AssertEqual(1, HighDecision["receipt_created"],
			"eligible injected input must reserve a receipt")
		HighUp := _LNEO_NativeEvent(0x31, 0x002, 0x02,
			_LNEO_EVENT_UP, 1, SendLevelBase - 2)
		AssertEqual(_LNEO_DISPOSITION_SUPPRESS,
			_LLM_NavEventOwnerNativeTestDispatch(HighUp)["disposition"],
			"eligible injected key-up must balance suppression")
		HighReceipt := _LLM_NavEventOwnerNativePollReceipt()
		AssertEqual(1, HighReceipt["target_idx"],
			"eligible injected Alt+1 must navigate to one")
		AssertTrue(_LLM_NavEventOwnerNativeCompleteReceipt(
			HighReceipt["seq"], OwnerToken, 1))
		AssertEqual(0,
			_LLM_NavEventOwnerNativePendingForToken(OwnerToken),
			"all native receipts must be released after exact completion")
		AssertTrue(_LLM_NavEventOwnerNativeClaimOwner(OwnerToken, 1),
			"the real ABI must atomically claim exact owner index one")
		AssertEqual(0, _LLM_NavEventOwnerNativeGetOwner(OwnerToken),
			"successful native acceptance must clear the active owner")
		_LNEO_AssertNativePassWithoutReceipt(
			_LLM_NavEventOwnerNativeTestDispatch(DigitDown),
			"navigation after native acceptance claim")
		AssertEqual(0, _LLM_NavEventOwnerNativePollReceipt(),
			"duplicate polling after completion must be idempotently empty")
	} finally {
		try _LLM_NavEventOwnerNativeStop()
		finally _LLM_NavEventOwnerNativeUnload()
	}
}

Test("LLM nav event owner: real ABI round-trip never calls native Start",
	_LNEO_RealNativeAbiRoundTripDoesNotStartHook)




