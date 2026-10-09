; tests/unit/test_webview_range_stage_owner.ahk

; ==============================================================================
; MODULE: WebView Range Stage Ownership Tests
; DESCRIPTION: Replacement and closure retire private range results precisely.
; ==============================================================================

#Requires AutoHotkey v2.0

_WRSO_Lifecycle(Mode, View, Lines, Unhandled, Failure) {
	First := _CTU_NewPath()
	Second := _CTU_NewPath()
	Entry := Map("epoch", 51, "webview", View)
	KLWV.windows := Map("typing", Entry)
	try {
		AssertTrue(FSWrite(First, "{}"))
		AssertTrue(FSWrite(Second, "{}"))
		AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", First))
		First := Entry["range_stage"]["stage"]
		AssertTrue(FSExists(First))
		if Mode = "close"
			KLWV_Close("typing")
		else {
			AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 43, "ok", Second))
			Second := Entry["range_stage"]["stage"]
			AssertTrue(FSExists(Second))
		}
		AssertFalse(FSExists(First), "the retired range must not retain its private file")
	} finally {
		KLWV_RetireRangeStage(Entry)
		FSDelete(First)
		FSDelete(Second)
	}
}
for Mode in ["close", "replace"]
	Test("WebView range stage: " . Mode . " retires ownership (range-stage-owner)",
		_WVSO_WithFixture.Bind(_WRSO_Lifecycle.Bind(Mode)))

_WRSO_Acknowledge(Mode, View, Lines, Unhandled, Failure) {
	First := _CTU_NewPath()
	Second := _CTU_NewPath()
	Entry := Map("epoch", 51, "webview", View)
	KLWV.windows := Map("typing", Entry)
	try {
		AssertTrue(FSWrite(First, "{}"))
		AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", First))
		OldOwner := Entry["range_stage"]
		First := OldOwner["stage"]
		AssertContains(View.Scripts[1], "range_consumed")
		AssertContains(View.Scripts[1], OldOwner["token"])
		if Mode = "stale-ack" || Mode = "stale-native" {
			AssertTrue(FSWrite(Second, "{}"))
			AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", Second))
			Second := Entry["range_stage"]["stage"]
			AssertFalse(OldOwner["token"] == Entry["range_stage"]["token"])
			if Mode = "stale-native"
				KLWV_RangeScriptSettled("typing", 51, Entry, 42, OldOwner, false)
			else {
				Message := KL_JsonEncode(Map("action", "range_consumed", "token", OldOwner["token"]))
				KLWV_OnWebMessage("typing", 51, View, {TryGetWebMessageAsString: (*) => Message})
			}
			AssertTrue(FSExists(Second), "an old generation cannot retire a reused request id")
			AssertEqual(0, View.Messages.Length, "an old native error cannot fail the newer request")
		} else if Mode = "invalid" {
			AssertFalse(KLWV_ConsumeRangeStage("typing", 51, Entry, '{"token":[]}'))
			AssertFalse(KLWV_ConsumeRangeStage("typing", 51, Entry, "{"))
			AssertTrue(FSExists(First))
		}
		Owner := Entry["range_stage"]
		Message := KL_JsonEncode(Map("action", "range_consumed", "token", Owner["token"]))
		Args := {TryGetWebMessageAsString: (*) => Message}
		if Mode = "wrong-sender" {
			KLWV_OnWebMessage("typing", 51, {}, Args)
			AssertTrue(FSExists(First))
		} else if Mode = "wrong-epoch" {
			KLWV_OnWebMessage("typing", 50, View, Args)
			AssertTrue(FSExists(First))
		} else if Mode = "pause"
			Suspend(true)
		KLWV_OnWebMessage("typing", 51, View, Args)
		AssertFalse(Entry.Has("range_stage"))
		AssertFalse(FSExists(Owner["stage"]))
		KLWV_OnWebMessage("typing", 51, View, Args)
		AssertFalse(Entry.Has("range_stage"), "duplicate consumption remains inert")
	} finally {
		KLWV_RetireRangeStage(Entry)
		FSDelete(First)
		FSDelete(Second)
	}
}
for Mode in ["consume", "stale-ack", "stale-native", "invalid", "wrong-sender", "wrong-epoch", "pause"]
	Test("WebView range stage: " . Mode . " acknowledgement (range-stage-owner)",
		_WVSO_WithFixture.Bind(_WRSO_Acknowledge.Bind(Mode)))
