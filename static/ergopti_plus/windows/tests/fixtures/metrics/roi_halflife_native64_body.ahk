; tests/fixtures/metrics/roi_halflife_native64_body.ahk

; ==============================================================================
; MODULE: ROI Half-Life Clock Child
; DESCRIPTION: OnHotstring is the sole writer of the private trigger map. Its
; real A_TickCount read and the timer's read use an explicit typed64 clock port.
; The future control captures an old timer sample, admits a newer real fire on a
; native timer, then resumes that older frame. No map values or SUT math are copied.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\roi_encryption_epoch_cutpoint.ahk

_RHL_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Source, Message, Values*) {
	global _RHL
	_RHL.Errors += 1
	FileAppend("error " . Source . " " . Format(Message, Values*) . "`n", _RHL.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	LoggerError(Source, Message, Values*)
}

LoggerInfo(Source, Message, Values*) {
	global _RHL
	FileAppend("info " . Source . " " . Format(Message, Values*) . "`n", _RHL.Log, "UTF-8")
}

_RHL_FocusPort(App, Title, TimeoutMs) {
	_RHL_Require(TimeoutMs == WI_FOCUS_TITLE_TIMEOUT_MS && !A_IsCritical,
		"The genuine focus owner must perform its bounded acquisition outside Critical.")
	return {ok: true, hwnd: 91, process_name: App, title: Title, class: "Fixture",
		failure_reason: "", timed_out: false}
}

_RHL_AcquireFocus(App, Title) {
	_RHL_Require(MF_RefreshFocus(true, _RHL_FocusPort.Bind(App, Title)),
		"The actual MF normalizer and publisher must admit the private fixture's full identity.")
	Snapshot := MF_GetFocusSnapshot()
	_RHL_Require(Snapshot.valid && Snapshot.hwnd == 91 && Snapshot.process_name == App && Snapshot.title == Title,
		"Only a complete genuinely published snapshot can admit the ROI producer.")
}

_RHL_Now(Producer) {
	global _RHL
	NativeNow := A_TickCount
	_RHL.LastNative := NativeNow
	if Producer == "KL_Roi_OnHotstring" {
		_RHL.PushReads += 1
		return _RHL.PushTick
	}
	_RHL_Require(Producer == "KL_Roi_HalflifeTick", "Only the two authenticated production clock sites can use this port.")
	_RHL.TickReads += 1
	; Retain this frame's first sample, but later reads see the advanced clock.
	Captured := _RHL.CurrentTick
	if !_RHL.Armed
		return Captured
	_RHL.Armed := false
	if A_IsCritical {
		; A native noninterruptible clock read legitimately prevents this cutpoint.
		; Do not force a yield or infer global clock/snapshot atomicity from it.
		_RHL.CutpointProtected := true
		return Captured
	}
	try {
		_RHL_Require(!A_IsCritical && !A_IsSuspended && _RHL.TickReads == 1
			&& KLRoi.trigger_last_use.Count == 1 && KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.Origin,
			"A real timer sample must precede the new fire without a policy or owner refusal.")
		_RHL.CapturedBeforeTimer := Captured
		SetTimer(_RHL.ActivityTimer, -1)
		Started := A_TickCount
		while !_RHL.ActivityDone && TickElapsed64(Started) < 2000
			Sleep(10)
		_RHL_Require(_RHL.ActivityDone && _RHL.ActivityCalls == 1,
			"The genuine newer fire must complete on a native timer before the retained sample returns.")
	} catch Any as Failure {
		_RHL.Failure := Failure
	}
	return Captured
}

_RHL_AdmitNewFire() {
	global _RHL
	try {
		_RHL_Require(!A_IsCritical && !A_IsSuspended && _RHL.CapturedBeforeTimer == _RHL.SampleTick,
			"The newer fire must interrupt the old sample on its actual native timer.")
		_RHL.ActivityCalls += 1
		_RHL.PushTick := _RHL.SampleTick + 500
		_RHL.CurrentTick := _RHL.PushTick
		KL_Roi_OnHotstring(_RHL.Trigger, 7, false)
		_RHL_Require(KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.PushTick
			&& KLRoi.session_fired_count == 2 && KLRoi.session_saved_chars == 14,
			"The real public producer, not a direct map assignment, must admit the future row.")
	} catch Any as Failure {
		_RHL.Failure := Failure
	} finally _RHL.ActivityDone := true
}

_RHL_ObserveTick() {
	global _RHL
	try {
		_RHL.TimerCalls += 1
		KLRoi.halflife_fn.Call()
	} catch Any as Failure {
		_RHL.Failure := Failure
	} finally _RHL.TickDone := true
}

_RHL_Observe(Stage) {
	global _RHL
	LastUse := KLRoi.trigger_last_use[_RHL.Trigger]
	Age := _RHL.SampleTick - LastUse
	RowDays := Keystats._pending_entries.Length ? Keystats._pending_entries[1].Get("days_since_use", -1) : -1
	FileAppend("RECEIPT roi-halflife64-owner stage=" . Stage . " mode=" . _RHL.Mode
		. " now=" . _RHL.SampleTick . " last_use=" . LastUse . " raw_age=" . Age
		. " rows=" . Keystats._pending_entries.Length . " days=" . RowDays
		. " fired=" . KLRoi.session_fired_count . " saved=" . KLRoi.session_saved_chars
		. " push_reads=" . _RHL.PushReads . " tick_reads=" . _RHL.TickReads
		. " timer_calls=" . _RHL.TimerCalls . " activity_calls=" . _RHL.ActivityCalls
		. " cutpoint_protected=" . _RHL.CutpointProtected
		. " native_tick=" . A_TickCount . " errors=" . _RHL.Errors . "`n", "*", "UTF-8")
}

_RHL_Exercise() {
	global _RHL
	Keystats.initialized := true
	Keystats.session_app := "roi-clock-fixture.exe"
	MetricsFilters.secure_field := false
	_RHL_AcquireFocus("roi-clock-fixture.exe", "private ROI fixture")
	_RHL_Require(!A_IsSuspended && KLRoi.trigger_last_use.Count == 0
		&& KLRoi.session_fired_count == 0 && Keystats._pending_entries.Length == 0,
		"Fresh real state, not historical persisted dates or a previous run, must own the fixture.")
	_RHL_Require(!MF_ShouldFilter() && !MF_ShouldFilterFor(Keystats.session_app, "private ROI fixture"),
		"The genuine public privacy predicates must admit this fixture before any business result.")
	_RHL.Origin := 1000
	_RHL.PushTick := _RHL.Origin
	_RHL.CurrentTick := _RHL.Origin
	DayMs := 86400000
	_RHL.SampleTick := _RHL.Origin + 31 * DayMs
	if _RHL.Mode == "days46"
		_RHL.SampleTick := _RHL.Origin + 46 * DayMs
	else if _RHL.Mode == "era31"
		_RHL.SampleTick := _RHL.Origin + 0x100000000 + 31 * DayMs
	else if _RHL.Mode == "future"
		_RHL.SampleTick := _RHL.Origin + 1000
	else
		_RHL_Require(_RHL.Mode == "days31", "The test must select one declared mode.")
	_RHL_Require(_RHL.SampleTick is Integer && _RHL.SampleTick > _RHL.Origin
		&& KLRoiConst.HALFLIFE_WARN_DAYS == 30 && KLRoiConst.ROI_SNAPSHOT_EVERY > 2,
		"Actual timing and snapshot constants must isolate one half-life event from periodic ROI snapshots.")
	KL_Roi_OnHotstring(_RHL.Trigger, 7, false)
	_RHL_Require(_RHL.PushReads == 1 && KLRoi.trigger_last_use.Count == 1
		&& KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.Origin
		&& KLRoi.session_saved_chars == 7 && KLRoi.session_fired_count == 1
		&& Keystats._pending_entries.Length == 0,
		"The genuine admitted public fire must own the exact full-width timestamp and savings.")
	_RHL_Require(KL_Roi_Start() && KLRoi.HasOwnProp("halflife_fn"),
		"The genuine public lifecycle must admit its actual timer identity.")
	; Run that genuine callback once now, with a native scheduling owner which
	; retains any exception before the business oracles. No simulated tick loop.
	_RHL.CurrentTick := _RHL.SampleTick
	_RHL.Armed := _RHL.Mode == "future"
	SetTimer(_RHL.TickTimer, -1)
	Started := A_TickCount
	while !_RHL.TickDone && TickElapsed64(Started) < 3000
		Sleep(10)
	if IsObject(_RHL.Failure)
		throw _RHL.Failure
	_RHL_Require(_RHL.TickDone && _RHL.TimerCalls == 1 && _RHL.TickReads >= 1 && _RHL.Errors == 0,
		"A real timer must settle without a hidden producer or privacy fallback error.")
	_RHL_Require(_RHL.PushReads == (_RHL.Mode == "future" && !_RHL.CutpointProtected ? 2 : 1)
		&& KLRoi.trigger_last_use.Count == 1,
		"Every map entry must still come from its genuine public producer.")
	_RHL_Observe("old-return")
	if _RHL.Mode == "future" {
		if _RHL.CutpointProtected {
			_RHL_Require(_RHL.ActivityCalls == 0 && !_RHL.ActivityDone
				&& _RHL.CapturedBeforeTimer == -1 && _RHL.PushReads == 1
				&& KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.Origin
				&& KLRoi.session_fired_count == 1 && KLRoi.session_saved_chars == 7,
				"A genuinely protected cutpoint must preserve the admitted initial fire without pretending an interruption occurred.")
		} else {
			_RHL_Require(_RHL.ActivityCalls == 1 && _RHL.ActivityDone
				&& _RHL.CapturedBeforeTimer == _RHL.SampleTick
				&& KLRoi.trigger_last_use[_RHL.Trigger] > _RHL.SampleTick,
				"An interruptible old sample requires the genuine native timer and newer real fire.")
		}
		_RHL_Require(Keystats._pending_entries.Length == 0,
			"A fire newer than the sampled timer cannot be reported as a stale trigger.")
	} else {
		_RHL_Require(Keystats._pending_entries.Length == 1,
			"Every admitted public trigger unused beyond the warning threshold must emit its half-life record.")
		Row := Keystats._pending_entries[1]
		ExpectedDays := Round((_RHL.SampleTick - _RHL.Origin) / DayMs, 1)
		_RHL_Require(Row["type"] == "trigger_halflife" && Row["trigger"] == _RHL.Trigger
			&& Row["app"] == Keystats.session_app && Row["days_since_use"] == ExpectedDays
			&& Row.Has("timestamp") && Row["timestamp"] != "" && Row["_event_id"] > 0,
			"The true central queue must preserve the trigger's complete monotonic age, not its 32-bit remainder.")
	}
	_RHL_Require(KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.PushTick
		&& _RHL.Errors == 0, "Publication cannot rewrite the admitted fire timestamp or hide an error.")
	_RHL_Observe("complete")
}

_RHL_NonpositiveUsage() {
	global _RHL
	SavedChars := KLRoi.session_saved_chars
	Fired := KLRoi.session_fired_count
	_RHL.PushTick += 500
	KL_Roi_OnHotstring(_RHL.Trigger, 0, false)
	_RHL_Require(KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.PushTick,
		"A zero-saving fire must refresh public last use.")
	_RHL.PushTick += 500
	KL_Roi_OnHotstring(_RHL.Trigger, -3, false)
	_RHL_Require(KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.PushTick,
		"A negative-saving fire must refresh public last use.")
	Private := "private-zero-saving-fixture"
	KL_Roi_OnHotstring(Private, 0, true)
	_RHL_Require(!KLRoi.trigger_last_use.Has(Private), "Private trigger names must remain absent.")
	_RHL_Require(KLRoi.session_fired_count == Fired + 3 && KLRoi.session_saved_chars == SavedChars,
		"All accepted fires count as usage without adding nonpositive savings.")
}

global _RHL_KeyWpm := 0

WPMWidget_Push(*) {
	global _RHL_KeyWpm
	_RHL_KeyWpm += 1
	return true
}

_RHL_RevokeInput(Mode, *) {
	switch Mode {
		case "pause": Suspend(true)
		case "capture": KL_Hook_InvalidateCapture()
		case "focus": MetricsFocusCache.generation += 1
	}
}

_RHL_Public() => false
_RHL_Private() => true
_RHL_NoShortcut(*) => ""
_RHL_NoErgo(*) => 0

_RHL_Type(Text, Private := false) {
	for Character in StrSplit(Text)
		KL_Hook_OnChar(0, Character, Private ? _RHL_Private : _RHL_Public, A_TickCount, _RHL_NoErgo)
}

_RHL_Key(vk, Private := false) {
	KL_Hook_OnKeyDown(0, vk, 0, Private ? _RHL_Private : _RHL_Public,
		A_TickCount, _RHL_NoShortcut, _RHL_NoErgo)
}

_RHL_ClearWords() {
	KLRoi.current_word := ""
	KLRoi.word_overflowed := false
	KLRoi.word_context := false
	KLRoi.word_counts := Map()
	KLRoi.word_counts_generation += 1
}

_RHL_Keys() {
	global _RHL, _RHL_KeyWpm
	Keystats.initialized := true
	Keystats.session_app := "roi-keys-fixture.exe"
	KLWatch.is_session_active := true
	KLWatch.session_started_at := A_TickCount
	KLWatch.last_authorized_tick := A_TickCount
	KLHook.last_tick := A_TickCount
	MetricsFilters.secure_field := false
	_RHL_AcquireFocus(Keystats.session_app, "ROI keys fixture")
	for Separator in [0x0D, 0x09] {
		_RHL_ClearWords()
		_RHL_Type("hello")
		_RHL_Key(Separator)
		_RHL_Type("world ")
		_RHL_Require(KLRoi.word_counts.Count == 2 && KLRoi.word_counts.Get("hello", 0) == 1
			&& KLRoi.word_counts.Get("world", 0) == 1, "Enter and Tab must separate genuine hook words.")
	}
	for Suffix in ["x", Chr(0x1F600)] {
		_RHL_ClearWords()
		_RHL_Type("hello")
		KL_Hook_OnChar(0, Suffix, _RHL_Public, A_TickCount, _RHL_NoErgo)
		_RHL_Key(0x08)
		_RHL_Type(" ")
		_RHL_Require(KLRoi.word_counts.Count == 1 && KLRoi.word_counts.Get("hello", 0) == 1,
			"Backspace must remove one entire Unicode codepoint through the real hook.")
	}
	_RHL_ClearWords()
	_RHL_Key(0x08)
	_RHL_Key(0x0D)
	_RHL_Require(KLRoi.word_counts.Count == 0, "Empty backspace must remain neutral.")
	Loop KLRoiConst.MAX_INPROGRESS_WORD_LEN + 1
		_RHL_Type("x")
	_RHL_Key(0x08)
	_RHL_Type("hello")
	_RHL_Key(0x0D)
	_RHL_Require(KLRoi.word_counts.Count == 0 && !KLRoi.word_overflowed,
		"A backspace must not turn an overflowed token into a fragment candidate.")
	_RHL_Type("world ")
	_RHL_Require(KLRoi.word_counts.Get("world", 0) == 1, "The next complete word must remain admissible.")
	_RHL_ClearWords()
	_RHL_Type("hello")
	Keystats.synth_active := true
	try {
		_RHL_Key(0x08)
		_RHL_Key(0x0D)
		_RHL_Key(0x09)
		_RHL_Type("x ")
	} finally Keystats.synth_active := false
	_RHL_Require(KLRoi.current_word == "" && KLRoi.word_counts.Count == 0,
		"Synthetic input retires the fragment without counting its output as a public word.")
	for Payload in ["^z", Chr(0x1F600)] {
		_RHL_ClearWords()
		Loop KLRoiConst.MAX_INPROGRESS_WORD_LEN - 1
			_RHL_Type("a")
		KL_Hook_OnChar(0, Payload, _RHL_Public, A_TickCount, _RHL_NoErgo)
		_RHL_Require(KLRoi.word_overflowed && StrLen(KLRoi.current_word) <= KLRoiConst.MAX_INPROGRESS_WORD_LEN,
			"A native multi-unit callback must respect the exact storage bound before publication.")
		_RHL_Type(" ")
		_RHL_Require(KLRoi.word_counts.Count == 0, "Overflow inside one callback must discard the entire word.")
	}
	_RHL_ClearWords()
	_RHL_Type("hello")
	KL_Hook_OnChar(0, "^.world ", _RHL_Public, A_TickCount, _RHL_NoErgo)
	_RHL_Require(KLRoi.word_counts.Count == 2 && KLRoi.word_counts.Get("hello^", 0) == 1
		&& KLRoi.word_counts.Get("world", 0) == 1,
		"Boundaries inside a single callback must split the candidate stream in order.")
	for Mode in ["pause", "capture", "focus"] {
		_RHL_ClearWords()
		_RHL_Type("hello")
		BeforeWpm := _RHL_KeyWpm
		try KL_Hook_OnChar(0, " ", _RHL_Public, A_TickCount, _RHL_RevokeInput.Bind(Mode))
		finally Suspend(false)
		_RHL_Require(KLRoi.current_word == "" && KLRoi.word_counts.Count == 0,
			"Ergonomic callout revocation retires the fragment and fences subsequent ROI: " . Mode)
		_RHL_Require(_RHL_KeyWpm == BeforeWpm,
			"Ergonomic callout revocation must fence subsequent WPM: " . Mode)
	}
	_RHL_ClearWords()
	_RHL_Type("hello")
	_RHL_Key(0x08, true)
	_RHL_Key(0x0D, true)
	_RHL_Key(0x09, true)
	_RHL_Type("x ", true)
	_RHL_Require(KLRoi.current_word == "" && KLRoi.word_counts.Count == 0,
		"Private input retires the fragment without counting or exposing its content.")
	_RHL_Type("world ")
	_RHL_Require(KLRoi.word_counts.Count == 1 && KLRoi.word_counts.Get("world", 0) == 1
		&& !KLRoi.word_counts.Has("helloworld"),
		"A fresh accepted word after the private gap cannot reuse its public prefix.")
	_RHL_Require(_RHL.Errors == 0, "No swallowed hook dependency error may qualify the assertions.")
}

_RHL_EncryptionEpoch() {
	global _RHL, KL_ENC_Enabled
	Keystats.initialized := true
	Keystats.session_app := "roi-clock-fixture.exe"
	MetricsFilters.secure_field := false
	MetricsFilters.encrypt := false, KL_ENC_Enabled := false
	_RHL_AcquireFocus(Keystats.session_app, "private ROI fixture")
	_RHL.PushTick := 1000
	KL_Roi_OnHotstring(_RHL.Trigger, 7, false)
	_RHL_Require(KLRoi.trigger_last_use.Count == 1 && _RHL.PushReads == 1,
		"Only the genuine producer may prepare the old trigger.")
	_RHL.CurrentTick := 1000 + 31 * 86400000
	_RHL_Require(KL_Roi_Start(), "The genuine lifecycle must own the half-life callback.")
	BeforeEpoch := KLRoiPrivacy.epoch
	State := _KRECP_Install(3)
	try KLRoi.halflife_fn.Call()
	finally _KRECP_Restore(State)
	_RHL_Require(State.Calls == 1 && KLRoiPrivacy.epoch == BeforeEpoch + 1
		&& !KLRoiPrivacy.blocked && _RHL.TickReads == 1,
		"The actual retained snapshot must cross ON and clean OFF at its post-snapshot preference lookup.")
	_RHL_Require(KLRoi.trigger_last_use.Count == 0 && Keystats._pending_entries.Length == 0
		&& KLRoi.session_saved_chars == 7 && KLRoi.session_fired_count == 1 && _RHL.Errors == 0,
		"The old half-life entry cannot acquire the new epoch at the actual central append.")
	FileAppend("RECEIPT roi-encryption-half-life cuts=" . State.Calls . " epoch=" . KLRoiPrivacy.epoch . "`n", "*", "UTF-8")
}

_RHL_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	KL_Roi_SetCanonicalPolicyKnown(true)
	global _RHL := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Trigger: "private-fixture-trigger",
		Origin: 0, PushTick: 0, SampleTick: 0, CurrentTick: 0, Armed: false, PushReads: 0, TickReads: 0,
		LastNative: 0, TimerCalls: 0, TickDone: false, CapturedBeforeTimer: -1,
		ActivityCalls: 0, ActivityDone: false, CutpointProtected: false, TickTimer: _RHL_ObserveTick, ActivityTimer: _RHL_AdmitNewFire,
		Failure: 0, Errors: 0}
	Primary := 0
	try {
		if _RHL.Mode == "keys"
			_RHL_Keys()
		else if _RHL.Mode == "encryption-epoch"
			_RHL_EncryptionEpoch()
		else {
			_RHL_Exercise()
			_RHL_NonpositiveUsage()
		}
	}
	catch Any as Failure
		Primary := Failure
	finally {
		try {
			SetTimer(_RHL.TickTimer, 0)
			SetTimer(_RHL.ActivityTimer, 0)
			_RHL_Require(KL_Roi_Stop() && !KLRoi.HasOwnProp("halflife_fn") && _RHL.Errors == 0,
				"The exact admitted native timer must retire through the real lifecycle owner.")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			_RHL.TickTimer := 0
			_RHL.ActivityTimer := 0
			Keystats.initialized := false
		}
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_RHL.Log)
			FileAppend("DIAG " . FileRead(_RHL.Log, "UTF-8") . "`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS roi-halflife64-owner " . _RHL.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_RHL_Main()
