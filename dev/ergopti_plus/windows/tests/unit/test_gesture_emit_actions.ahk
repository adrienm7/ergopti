; tests/unit/test_gesture_emit_actions.ahk

; ==============================================================================
; MODULE: Gesture Emit-Action Registration
; DESCRIPTION:
; The 62 actions whose behaviour the shared catalogue describes must all be
; registered, and the loop that registers them must bind each one's own values.
;
; WHAT THIS REPLACED:
; While those handlers were hand-written lambdas, a JS gate compared the
; catalogue's emit rows against the source text of the registry. That gate did
; its job — it made the data trustworthy enough to delete the code against — and
; then correctly reported it had nothing left to compare once the handlers became
; generated. Keeping it would have been circular: the code is generated FROM the
; catalogue, so of course the two agree.
;
; THE BUG THIS GUARDS AGAINST:
; The handlers are built in a loop. A closure created inside an AHK loop captures
; the LOOP VARIABLE, not a copy of it — so building them inline would give every
; action the values of the final iteration. All 62 would emit the same keystroke,
; while the registry still reported the right count, every existing test stayed
; green, and nothing anywhere errored. The emitters are therefore built by helper
; functions that take the values as parameters, which makes each closure's
; binding its own by construction, and the test below pins that construction.
;
; WHERE THIS STOPS, DELIBERATELY:
; It does not invoke a handler and observe the keystroke. AHK v2 resolves
; function names at compile time, so intercepting TextPressKey would mean adding
; a recorder seam to adapters/text_sender.ahk — a production change for
; testability that nothing else in this suite currently needs. Registration
; completeness and the binding construction are what is checked here; the
; catalogue-to-generated-file agreement is covered by the no-drift gate, which
; regenerates and diffs.
; ==============================================================================

#Requires AutoHotkey v2.0


_GEA_Join(Arr) {
	Out := ""
	for I, V in Arr {
		Out .= (I > 1 ? ", " : "") . V
		if (I >= 8) {
			Out .= ", …"
			break
		}
	}
	return Out
}





; ==================================================
; ==================================================
; ======= 1/ Every declared action registers =======
; ==================================================
; ==================================================

_GEA_DataIsPopulated() {
	Data := GestureEmitActionsData()
	Assert(Data.Count >= 50,
		"the generated emit data carries only " . Data.Count . " action(s). A near-empty table "
		. "would make every assertion here vacuous — and would mean 62 gestures silently do nothing.")
}
Test("gesture emit: the generated catalogue data is populated", _GEA_DataIsPopulated)


_GEA_AllDeclaredAreRegistered() {
	global GESTURE_ACTIONS
	Missing := []
	for Id, _Spec in GestureEmitActionsData() {
		if !GESTURE_ACTIONS.Has(Id)
			Missing.Push(Id)
	}
	Assert(Missing.Length == 0,
		"declared in the shared catalogue but absent from the registry: " . _GEA_Join(Missing)
		. ". They are registered at static-init from _generated/gesture_emit_actions.ahk — if that "
		. "include goes missing, each of these gestures becomes a silent no-op rather than an error.")
}
Test("gesture emit: every catalogue-declared action is registered", _GEA_AllDeclaredAreRegistered)


_GEA_EveryEntryHasACallableFn() {
	global GESTURE_ACTIONS
	Bad := []
	for Id, _Spec in GestureEmitActionsData() {
		if !GESTURE_ACTIONS.Has(Id)
			continue
		Entry := GESTURE_ACTIONS[Id]
		if !(Entry is Object) or !Entry.HasOwnProp("Fn") or !(Entry.Fn is Func)
			Bad.Push(Id)
	}
	Assert(Bad.Length == 0,
		"registered without a callable Fn: " . _GEA_Join(Bad)
		. ". execute_single() refuses an action it cannot call, so the gesture does nothing.")
}
Test("gesture emit: every registered action has a callable handler", _GEA_EveryEntryHasACallableFn)





; =========================================
; =========================================
; ======= 2/ The loop-capture guard =======
; =========================================
; =========================================

; Source-level, and pinning the ROOT CAUSE rather than a spelling: the emitters
; must be built by functions that receive the key and modifiers as parameters.
; Built inline in the loop instead, every closure would share one variable and
; all 62 actions would emit the last iteration's keystroke — with the count
; right, nothing thrown, and no other test able to see it.
_GEA_EmittersBuiltByParameterisedHelpers() {
	Src := _DriverDirConcat("modules/gestures")
	Assert(Src != "", "the gestures module source must be readable or this asserts nothing")

	Assert(InStr(Src, "_GestureMakeKeyEmitter(") > 0,
		"the key emitters must be built by a helper taking (Key, Mods) as parameters — a closure "
		. "created inline in the registration loop captures the loop VARIABLE, so every action "
		. "would emit the final iteration's keystroke")
	Assert(InStr(Src, "_GestureMakeSeqEmitter(") > 0,
		"the raw-sequence emitters must be built by a parameterised helper for the same reason")

	KeyBody := _DriverFuncBody("_GestureMakeKeyEmitter")
	Assert(KeyBody != "", "_GestureMakeKeyEmitter must exist in the driver source")
	Assert(InStr(KeyBody, "TextPressKey(Key, Mods)") > 0,
		"_GestureMakeKeyEmitter must emit through TextPressKey with its OWN parameters, not with "
		. "anything captured from the enclosing scope")

	SeqBody := _DriverFuncBody("_GestureMakeSeqEmitter")
	Assert(SeqBody != "", "_GestureMakeSeqEmitter must exist in the driver source")
	Assert(InStr(SeqBody, "SendFinalResult(Seq)") > 0,
		"_GestureMakeSeqEmitter must send its OWN parameter")
}
Test("gesture emit: emitters are built by parameterised helpers (loop-capture guard)", _GEA_EmittersBuiltByParameterisedHelpers)





; ====================================================
; ====================================================
; ======= 3/ No hand-written duplicate remains =======
; ====================================================
; ====================================================

; The point of the conversion was to stop spelling these keystrokes twice. A
; hand-written entry that reappears alongside the generated one wins or loses by
; Map-insertion order, which is not something anyone should have to reason about.
_GEA_NoHandWrittenDuplicates() {
	Src := _DriverDirConcat("modules/gestures")
	Dupes := []
	for Id, Spec in GestureEmitActionsData() {
		if !Spec.HasOwnProp("Key")
			continue
		Needle := '"' . Id . '", {'
		if InStr(Src, Needle)
			Dupes.Push(Id)
	}
	Assert(Dupes.Length == 0,
		"still written out by hand in the registry as well as generated: " . _GEA_Join(Dupes)
		. ". Two definitions of one action resolve by Map-insertion order; the catalogue is the "
		. "single source, so the hand-written copy must go.")
}
Test("gesture emit: no action is both generated and hand-written", _GEA_NoHandWrittenDuplicates)
