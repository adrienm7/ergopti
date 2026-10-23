; tests/unit/ui/tooltip/test_tooltip_native64_deadlines.ahk

; ==============================================================================
; MODULE: Tooltip Native64 Deadline Tests
; DESCRIPTION:
; Direct production deadline decisions with explicit native-domain snapshots.
; The logical elapsed interval does not claim physical uptime or GUI rendering.
; ==============================================================================

#Requires AutoHotkey v2.0

_TD64_DeadlineCase(Operation, Scenario) {
	Origin := 0x100000000 + 1000
	Item := { Text: "deadline row", ExpireOriginTick: Origin, ExpireDurationMs: 1000 }
	Items := [Item]
	Now := Origin + Scenario.Age
	switch Operation {
		case "filter":
			Live := _TooltipFilterUnexpiredDeadlineItems(Items, Now)
			AssertEqual(Scenario.Expired ? 0 : 1, Live.Length,
				"Filtering must discard an expired native64 deadline")
			if !Scenario.Expired
				AssertTrue(Live[1] == Item, "A live row retains its original identity")
		case "admission":
			AssertEqual(!Scenario.Expired, _TooltipAbsoluteDeadlinesStillLive(Items, Now),
				"Publication must reject an expired native64 deadline")
		case "timer-bounds":
			Bounds := _TooltipLifecycleDeadlineBounds({ DeadlineItems: Items }, Now)
			AssertEqual(Scenario.Expired, Bounds.Expired,
				"A full counter era must not revive the native64 lifecycle plan")
			AssertEqual(Scenario.Remaining, Bounds.EarliestMs)
			AssertEqual(Scenario.Remaining, Bounds.LatestMs)
		default:
			throw ValueError("Unknown native64 deadline test operation")
	}
	AssertEqual(1, Items.Length, "Deadline decisions do not mutate the input array")
	AssertTrue(Items[1] == Item, "Deadline decisions retain the original input owner")
	AssertEqual(Origin, Item.ExpireOriginTick, "The native origin is never truncated")
	AssertEqual(1000, Item.ExpireDurationMs)
}

for _TD64_Operation in ["filter", "admission", "timer-bounds"] {
	for _TD64_Case in [
		{ Label: "before", Age: 999, Expired: false, Remaining: 1 },
		{ Label: "exact", Age: 1000, Expired: true, Remaining: 0 },
		{ Label: "long-gap", Age: 0x100000001, Expired: true, Remaining: 0 }
	] {
		Test("Tooltip deadline: " . _TD64_Operation . " " . _TD64_Case.Label
			. " honors the native clock (tooltip-deadline-native64-owner)",
			_TD64_DeadlineCase.Bind(_TD64_Operation, _TD64_Case))
	}
}
