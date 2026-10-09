; tests/meta/test_space_tap_dispatch.ahk

#Requires AutoHotkey v2.0

_ST_AssertSpaceTapAtomic() {
	; Move-resilient: locate _SpaceTap() across the whole driver source via the
	; framework helper instead of a pinned modules path
	Body := _DriverFuncBody("_SpaceTap")
	Assert(Body != "", "_SpaceTap must exist in platform/remap/space.ahk")

	CritOnIdx := InStr(Body, 'Critical("On")')
	Assert(CritOnIdx > 0, "_SpaceTap must use Critical('On') to prevent mid-dispatch races (space-tap-dispatch-not-critical)")

	PressIdx := InStr(Body, 'TextPressKey("Space"')
	FeedIdx := InStr(Body, 'HSE_FeedChar(" ", true)')
	LlmIdx := InStr(Body, '_HSE_MirrorLiteralEditToLlm(0, " ")')
	DispatchIdx := InStr(Body, "HSE_DispatchMatch")
	EffectIdx := InStr(Body, "&CommittedScreenEffect", true, DispatchIdx)
	FinalizeIdx := InStr(Body, "_PrefixCommitPostFireEffect(CommittedScreenEffect)")
	RingIdx := InStr(Body, 'UpdateLastSentCharacter(" ")')
	SecondRingIdx := RingIdx > 0
		? InStr(Body, 'UpdateLastSentCharacter(" ")', true, RingIdx + 1) : 0

	Assert(PressIdx > CritOnIdx and FeedIdx > PressIdx,
		"the intercepted Space must reach the screen before HSE models it, so dispatch never backspaces an absent end character")
	Assert(LlmIdx > FeedIdx and DispatchIdx > LlmIdx and EffectIdx > DispatchIdx,
		"the same Space must join HSE and LLM state before dispatch publishes one canonical effect")
	Assert(FinalizeIdx > DispatchIdx,
		"a fired Space completion must finalize the prefix watcher from the dispatcher's canonical effect")
	Assert(RingIdx > FinalizeIdx and SecondRingIdx == 0,
		"only the literal no-fire Space branch may write Space to the output ring; dispatch owns fire output history")
	Assert(InStr(Body, "HSE_FeedBackspace") == 0,
		"a failed Space send must return before either buffer is fed, so no speculative rollback belongs in this path")
}

Test("tap_holds: _SpaceTap atomically commits screen, HSE, LLM and prefix state (space-tap-dispatch-not-critical)", _ST_AssertSpaceTapAtomic)
