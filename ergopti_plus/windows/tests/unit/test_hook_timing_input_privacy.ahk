; tests/unit/test_hook_timing_input_privacy.ahk

; ==============================================================================
; MODULE: Hook Timing Input Privacy Tests
; DESCRIPTION: Latency warnings retain timing without recording key identities.
; ==============================================================================

#Requires AutoHotkey v2.0

_HTIP_Check(IsDown) {
	global _TH_TapHoldTrackState, _TH_TapHoldScToKeyId, _TH_TapHoldVkToKeyId
	global _KS_PhysicalInputGeneration, _KS_LastPhysicalKeyVk, _KS_LastPhysicalKeySc
	global _KS_LastPhysicalKeyEpoch, _KS_LastPhysicalKeySources
	global _HOTPATH_SLOW_MS_BY_SEGMENT, _LOGGER_WARN_ENABLED, _LOGGER_TEST_SINK
	Names := ["_TH_TapHoldTrackState", "_TH_TapHoldScToKeyId", "_TH_TapHoldVkToKeyId",
		"_KS_PhysicalInputGeneration", "_KS_LastPhysicalKeyVk", "_KS_LastPhysicalKeySc",
		"_KS_LastPhysicalKeyEpoch", "_KS_LastPhysicalKeySources",
		"_HOTPATH_SLOW_MS_BY_SEGMENT", "_LOGGER_WARN_ENABLED", "_LOGGER_TEST_SINK"]
	Saved := Map()
	for Name in Names
		Saved[Name] := %Name%
	SavedSubscribers := HookDispatcher._subscribers
	Seen := []
	Lines := []
	Event := IsDown ? HookDispatcherConst.EVT_KB_DOWN : HookDispatcherConst.EVT_KB_UP
	Label := IsDown ? "Hook.KeyDown" : "Hook.KeyUp"
	try {
		AssertFalse(A_IsSuspended, "the isolated callback fixture requires an unsuspended test process")
		_TH_TapHoldTrackState := Map()
		_TH_TapHoldScToKeyId := Map()
		_TH_TapHoldVkToKeyId := Map()
		_KS_LastPhysicalKeySources := Map()
		HookDispatcher._subscribers := Map(Event, [(Args*) => Seen.Push(Args)])
		; Force the warning branch without sleeping, injecting keys or increasing
		; CPU load. Production thresholds are restored after the isolated sample.
		_HOTPATH_SLOW_MS_BY_SEGMENT := Map(Label, -1)
		_LOGGER_WARN_ENABLED := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		if IsDown
			HookDispatcher._OnKeyDown(0, 0x41, 0x1E)
		else
			HookDispatcher._OnKeyUp(0, 0x41, 0x1E)
		AssertEqual(1, Seen.Length, "privacy must not suppress the underlying input dispatch")
		AssertEqual(0x41, Seen[1][2])
		AssertEqual(0x1E, Seen[1][3])
		Samples := 0
		for Line in Lines {
			if !InStr(Line, "Slow " . Label . ":")
				continue
			Samples += 1
			AssertFalse(RegExMatch(Line, "i)\b(?:vk|sc)\d+\b"),
				"timing diagnostics must not persist the physical key identity")
			AssertTrue(InStr(Line, " ms"), "the diagnostic must retain its elapsed time")
		}
		AssertEqual(1, Samples, "an absent warning must not satisfy the privacy assertion")
	} finally {
		HookDispatcher._subscribers := SavedSubscribers
		for Name, Value in Saved
			%Name% := Value
	}
}

for IsDown in [true, false]
	Test("hook timing: input identity stays private down=" . IsDown . " (hook-timing-input-privacy)",
		_HTIP_Check.Bind(IsDown))
