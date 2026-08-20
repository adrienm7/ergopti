; tests/unit/test_terminal_hotstring_pacing.ahk

; ==============================================================================
; MODULE: Terminal Hotstring Pacing Tests
; DESCRIPTION:
; React/OpenTUI prompts can apply a compact ``{BackSpace N}`` sequence against
; one stale render. These tests exercise the sender boundary itself: deletion
; tokens stay explicit inside one SendEvent command, where SetKeyDelay paces
; them and BlockInput("Send") buffers physical typing for the whole transaction.
; This is behavioral coverage; merely seeing SetKeyDelay in source did not prove
; that AHK paced repeat-count expansions.
; ==============================================================================

#Requires AutoHotkey v2.0

global _THP_Events := []
global _THP_FailAtSend := 0
global _THP_SendCount := 0
global _THP_ScheduledCallback := 0
global _THP_ScheduledDelay := 0

_THP_Reset(FailAtSend := 0) {
	global _THP_Events, _THP_FailAtSend, _THP_SendCount
	_THP_Events := []
	_THP_FailAtSend := FailAtSend
	_THP_SendCount := 0
}

_THP_Emit(Payload) {
	global _THP_Events, _THP_FailAtSend, _THP_SendCount
	_THP_SendCount += 1
	_THP_Events.Push("send:" . Payload)
	return _THP_FailAtSend != _THP_SendCount
}

_THP_Delay(DelayMs, DurationMs) {
	global _THP_Events
	_THP_Events.Push("delay:" . DelayMs . ":" . DurationMs)
}

_THP_AssertEvents(Expected, Message) {
	global _THP_Events
	AssertEqual(Expected.Length, _THP_Events.Length, Message . " (event count)")
	for Index, ExpectedEvent in Expected
		AssertEqual(ExpectedEvent, _THP_Events[Index], Message . " (event " . Index . ")")
}

_THP_MultipleDeletesAreActuallyPaced() {
	_THP_Reset()
	AssertTrue(_HSE_SendTerminalPaced(
		3, "{Text}attention", 12, _THP_Emit, _THP_Delay, _THP_RecordBlock))
	_THP_AssertEvents([
		"block:Send", "delay:12:0",
		"send:{BackSpace}{BackSpace}{BackSpace}{Text}attention",
		"delay:" . A_KeyDelay . ":" . A_KeyDuration, "block:Default"
	], "explicit deletions must remain inside one input-protected SendEvent")
}
Test("terminal hotstrings: explicit deletions share one protected paced emission (terminal-stale-render)",
	_THP_MultipleDeletesAreActuallyPaced)

_THP_OneDeleteWaitsBeforeReplacement() {
	_THP_Reset()
	AssertEqual("{BackSpace}XGBoost", _HSE_BuildTerminalBurst(1, "XGBoost"),
		"the replacement must follow an explicit paced deletion token")
}
Test("terminal hotstrings: replacement follows the final explicit deletion",
	_THP_OneDeleteWaitsBeforeReplacement)

_THP_ZeroDeletesDoesNotInventLatency() {
	AssertEqual("payload", _HSE_BuildTerminalBurst(0, "payload"),
		"a text-only terminal transaction must not invent a deletion")
}
Test("terminal hotstrings: zero-delete burst contains only its payload",
	_THP_ZeroDeletesDoesNotInventLatency)

_THP_EmptyTailDoesNotWaitAfterLastDelete() {
	AssertEqual("{BackSpace}{BackSpace}", _HSE_BuildTerminalBurst(2, ""),
		"an empty tail must leave exactly the explicit deletion tokens")
}
Test("terminal hotstrings: empty tail contains only explicit deletions",
	_THP_EmptyTailDoesNotWaitAfterLastDelete)

_THP_FailedDeleteStopsTheTransaction() {
	_THP_Reset(1)
	AssertFalse(_HSE_SendTerminalPaced(
		3, "replacement", 4, _THP_Emit, _THP_Delay, _THP_RecordBlock))
	_THP_AssertEvents([
		"block:Send", "delay:4:0",
		"send:{BackSpace}{BackSpace}{BackSpace}replacement",
		"delay:" . A_KeyDelay . ":" . A_KeyDuration, "block:Default"
	], "a refused unified send must still restore delay and input protection")
}
Test("terminal hotstrings: refused unified send restores transaction state",
	_THP_FailedDeleteStopsTheTransaction)

_THP_FailedTailIsReported() {
	_THP_Reset(1)
	AssertFalse(_HSE_SendTerminalPaced(
		1, "replacement", 4, _THP_Emit, _THP_Delay, _THP_RecordBlock))
}
Test("terminal hotstrings: unified sender refusal is propagated",
	_THP_FailedTailIsReported)

_THP_SharedDelayKeepsMeasuredMargin() {
	DelayMs := TimingsGet("debounce", "terminal_hotstring_key_delay_ms")
	AssertTrue(DelayMs >= 20,
		"the shared terminal delay must stay safely above one 60 Hz render turn")
}
Test("terminal hotstrings: shared pacing delay keeps margin above measured threshold",
	_THP_SharedDelayKeepsMeasuredMargin)

_THP_RecordSchedule(Callback, DelayMs) {
	global _THP_ScheduledCallback, _THP_ScheduledDelay
	_THP_ScheduledCallback := Callback
	_THP_ScheduledDelay := DelayMs
	return true
}

_THP_RecordBlock(State) {
	global _THP_Events
	_THP_Events.Push("block:" . State)
	return true
}

_THP_TransactionStartsAfterCallbackWithFullEraseCount() {
	global _THP_ScheduledCallback, _THP_ScheduledDelay
	_THP_Reset()
	_THP_ScheduledCallback := 0
	_THP_ScheduledDelay := 0
	AssertTrue(_HSE_BeginTerminalTransaction(
		4, "{Text}attention", 50, _THP_Emit, _THP_Delay,
		_THP_RecordSchedule, _THP_RecordBlock))
	AssertEqual(50, _THP_ScheduledDelay)
	_THP_AssertEvents([], "dispatch must emit nothing before OnChar returns")
	AssertTrue(HasMethod(_THP_ScheduledCallback, "Call"))
	_THP_ScheduledCallback.Call()
	_THP_AssertEvents([
		"block:Send", "delay:50:0",
		"send:{BackSpace}{BackSpace}{BackSpace}{BackSpace}{Text}attention",
		"delay:" . A_KeyDelay . ":" . A_KeyDuration, "block:Default"
	], "the deferred transaction must erase the complete rendered trigger before replacement")
}
Test("terminal hotstrings: full edit starts after the completing callback returns",
	_THP_TransactionStartsAfterCallbackWithFullEraseCount)

_THP_RejectedScheduleReleasesInputWithoutSending() {
	global _THP_ScheduledCallback
	_THP_Reset()
	_THP_ScheduledCallback := 0
	RejectSchedule := (Callback, DelayMs) => false
	AssertFalse(_HSE_BeginTerminalTransaction(
		3, "replacement", 20, _THP_Emit, _THP_Delay,
		RejectSchedule, _THP_RecordBlock))
	_THP_AssertEvents([], "a refused timer must not acquire input protection or emit a partial edit")
}
Test("terminal hotstrings: rejected scheduling sends nothing and acquires no block",
	_THP_RejectedScheduleReleasesInputWithoutSending)
