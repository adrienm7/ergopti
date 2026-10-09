; modules/updater/schedule.ahk

; ==============================================================================
; MODULE: Updater / Automatic-Check Schedule
; DESCRIPTION:
; Decides when an automatic update check is due from the wall clock, the
; persisted check record and the shared timing (_shared/modules/updater/
; defaults.json, generated as UpdateScheduleData() in _generated/update_schedule.ahk).
;
; FEATURES & RATIONALE:
; 1. Port of the canonical JavaScript (_shared/modules/updater/schedule.js).
;    tests/unit/test_updater_schedule_vectors.ahk replays the shared
;    _shared/modules/updater/schedule_vectors.json with the Lua port, so the
;    three drivers agree on catch-up after a power-off, a clock moved back,
;    failure backoff, jitter and the snap of a retired interval.
; 2. Integer arithmetic only: the jitter fold stays below 2^36, so JavaScript,
;    LuaJIT and AHK compute the same value exactly.
; 3. Fail fast: malformed generated timing throws on first use instead of
;    degrading to a guessed cadence.
; ==============================================================================



; =====================================
; ===== 1.1) Timing ===================
; =====================================

global _UpdateScheduleTiming := 0

; Largest prime below 2^31, the modulus of the jitter fold.
global UPDATE_SCHEDULE_HASH_MODULUS := 2147483647
global UPDATE_SCHEDULE_HASH_MULTIPLIER := 31
global UPDATE_SCHEDULE_NEVER_CODE := "never"

; The persisted check record, in the order sanitizing reports dropped fields.
global UPDATE_SCHEDULE_STATE_FIELDS := [
	["last_check_at", "time"],
	["last_success_at", "time"],
	["failures", "count"],
	["seed", "seed"],
	["last_notified_tag", "tag"]
]

; Reported when the stored record is not a Map at all.
global UPDATE_SCHEDULE_WHOLE_RECORD := "check_state"

_UpdateSchedule_IsCount(Value) {
	return (Value is Integer) && Value >= 0
}

; Validates one timing Map; returns true or throws a ValueError naming the
; first problem.
UpdateSchedule_ValidateTiming(Timing) {
	global UPDATE_SCHEDULE_NEVER_CODE
	if !(Timing is Map)
		throw ValueError("Update schedule timing must be a Map")
	Presets := Timing.Get("check_interval_presets", 0)
	if !(Presets is Array) || Presets.Length < 2
		throw ValueError("Update schedule: check_interval_presets needs at least two presets")
	Codes := Map()
	Previous := 0
	for Index, Preset in Presets {
		Code := (Preset is Map) ? Preset.Get("code", "") : ""
		if !(Code is String) || !RegExMatch(Code, "^[a-z0-9]+\z")
			throw ValueError("Update schedule: preset #" . Index . " has no valid code")
		if Codes.Has(Code)
			throw ValueError("Update schedule: preset code " . Code . " is declared twice")
		Codes[Code] := true
		Seconds := Preset.Get("seconds", "")
		if !_UpdateSchedule_IsCount(Seconds)
			throw ValueError("Update schedule: preset " . Code . " must be a whole number of seconds")
		Last := (Index == Presets.Length)
		if (Last != (Code == UPDATE_SCHEDULE_NEVER_CODE))
			throw ValueError("Update schedule: the never preset must be the last one")
		if (Last != (Seconds == 0))
			throw ValueError("Update schedule: only the last preset may be 0 seconds")
		if !Last {
			if (Seconds <= Previous)
				throw ValueError("Update schedule: presets must be ordered from the shortest to the longest")
			Previous := Seconds
		}
	}
	DefaultFound := false
	for _, Preset in Presets
		if (Preset["seconds"] == Timing.Get("default_check_interval_sec", -1))
			DefaultFound := true
	if !DefaultFound
		throw ValueError("Update schedule: default_check_interval_sec must be one of the presets")
	if !_UpdateSchedule_IsCount(Timing.Get("boot_check_delay_sec", ""))
		throw ValueError("Update schedule: boot_check_delay_sec must be a whole number of seconds")
	Jitter := Timing.Get("jitter_percent", "")
	if !_UpdateSchedule_IsCount(Jitter) || Jitter > 100
		throw ValueError("Update schedule: jitter_percent must be 0 to 100")
	if !_UpdateSchedule_IsCount(Timing.Get("jitter_max_sec", ""))
		throw ValueError("Update schedule: jitter_max_sec must be a whole number of seconds")
	Backoff := Timing.Get("failure_backoff_sec", 0)
	if !(Backoff is Array) || Backoff.Length == 0
		throw ValueError("Update schedule: failure_backoff_sec must list positive whole seconds")
	for _, Seconds in Backoff
		if !_UpdateSchedule_IsCount(Seconds) || Seconds == 0
			throw ValueError("Update schedule: failure_backoff_sec must list positive whole seconds")
	Reevaluate := Timing.Get("reevaluate_sec", "")
	if !_UpdateSchedule_IsCount(Reevaluate) || Reevaluate == 0
		throw ValueError("Update schedule: reevaluate_sec must be positive")
	Key := Timing.Get("state_storage_key", "")
	if !(Key is String) || Key == ""
		throw ValueError("Update schedule: state_storage_key must name the check record")
	return true
}

; Returns the validated shared timing, built once from the generated data.
UpdateSchedule_Timing() {
	global _UpdateScheduleTiming
	if IsObject(_UpdateScheduleTiming)
		return _UpdateScheduleTiming
	Timing := UpdateScheduleData()
	UpdateSchedule_ValidateTiming(Timing)
	_UpdateScheduleTiming := Timing
	return _UpdateScheduleTiming
}

; Returns the frequency presets in display order, never last (Maps with code
; and seconds; the caller must not mutate them).
UpdateSchedule_Presets() {
	return UpdateSchedule_Timing()["check_interval_presets"]
}



; =====================================
; ===== 1.2) Presets ==================
; =====================================

; Returns the code of the preset equal to Seconds, or "" when none is.
UpdateSchedule_PresetCode(Seconds) {
	for _, Preset in UpdateSchedule_Presets()
		if (Preset["seconds"] == Seconds)
			return Preset["code"]
	return ""
}

; Snaps a saved interval to the nearest preset by ratio (a tie takes the
; longer preset). Returns { Seconds, Code, Snapped }.
UpdateSchedule_SnapInterval(Seconds) {
	if !_UpdateSchedule_IsCount(Seconds)
		throw ValueError("An update-check interval must be a whole number of seconds")
	Presets := UpdateSchedule_Presets()
	if (Seconds == 0) {
		Never := Presets[Presets.Length]
		return { Seconds: 0, Code: Never["code"], Snapped: false }
	}
	Longest := Presets[Presets.Length - 1]
	Best := Presets[1]
	if (Seconds >= Longest["seconds"]) {
		Best := Longest
	} else if (Seconds > Best["seconds"]) {
		loop Presets.Length - 1 {
			Preset := Presets[A_Index]
			; ratio(p) = max(p, s) / min(p, s), compared by cross-multiplication.
			Candidate := Max(Preset["seconds"], Seconds) * Min(Best["seconds"], Seconds)
			Current := Max(Best["seconds"], Seconds) * Min(Preset["seconds"], Seconds)
			if (Candidate <= Current)
				Best := Preset
		}
	}
	return { Seconds: Best["seconds"], Code: Best["code"], Snapped: Best["seconds"] != Seconds }
}



; =====================================
; ===== 1.3) State record ==============
; =====================================

; Keeps the valid fields of a stored check record. "" is the Storage port's
; missing value. Returns { State: Map, Dropped: Array of field names }.
UpdateSchedule_SanitizeState(Raw) {
	global UPDATE_SCHEDULE_STATE_FIELDS, UPDATE_SCHEDULE_WHOLE_RECORD
	State := Map()
	Dropped := []
	if (Raw is String) && Raw == ""
		return { State: State, Dropped: Dropped }
	if !(Raw is Map) {
		Dropped.Push(UPDATE_SCHEDULE_WHOLE_RECORD)
		return { State: State, Dropped: Dropped }
	}
	for _, Entry in UPDATE_SCHEDULE_STATE_FIELDS {
		Field := Entry[1]
		if !Raw.Has(Field)
			continue
		Value := Raw[Field]
		switch Entry[2] {
			case "time", "count": Valid := _UpdateSchedule_IsCount(Value)
			case "seed": Valid := (Value is String) && Value != ""
			default: Valid := (Value is String)
		}
		if Valid
			State[Field] := Value
		else
			Dropped.Push(Field)
	}
	return { State: State, Dropped: Dropped }
}

; Returns the record after one check completed; State is not modified.
UpdateSchedule_RecordCheck(State, Now, Ok) {
	global UPDATE_SCHEDULE_STATE_FIELDS
	Next := Map()
	for _, Entry in UPDATE_SCHEDULE_STATE_FIELDS
		if State.Has(Entry[1])
			Next[Entry[1]] := State[Entry[1]]
	Next["last_check_at"] := Now
	if Ok {
		Next["last_success_at"] := Now
		Next["failures"] := 0
	} else {
		Next["failures"] := Next.Get("failures", 0) + 1
	}
	return Next
}



; =====================================
; ===== 1.4) Due time =================
; =====================================

; Deterministic per-install jitter for one period, in [0, span].
UpdateSchedule_JitterSeconds(Seed, Anchor, Interval) {
	global UPDATE_SCHEDULE_HASH_MODULUS, UPDATE_SCHEDULE_HASH_MULTIPLIER
	Timing := UpdateSchedule_Timing()
	Span := Min((Interval * Timing["jitter_percent"]) // 100, Timing["jitter_max_sec"])
	if (Span <= 0)
		return 0
	Text := Seed . ":" . Format("{:d}", Anchor)
	Bytes := Buffer(StrPut(Text, "UTF-8"))
	Length := StrPut(Text, Bytes, "UTF-8") - 1
	Hash := 0
	loop Length
		Hash := Mod(Hash * UPDATE_SCHEDULE_HASH_MULTIPLIER + NumGet(Bytes, A_Index - 1, "UChar"),
			UPDATE_SCHEDULE_HASH_MODULUS)
	return Mod(Hash, Span + 1)
}

; When the next automatic check is due. Times are epoch seconds; StartedAt is
; the driver start or the last wake. Returns { DueAt, Reason }, DueAt "" for
; never.
UpdateSchedule_NextDue(Now, StartedAt, Interval, State) {
	Timing := UpdateSchedule_Timing()
	if !(Interval > 0)
		return { DueAt: "", Reason: "never" }
	Earliest := StartedAt + Timing["boot_check_delay_sec"]
	if !State.Has("last_check_at")
		return { DueAt: Earliest, Reason: "first_check" }
	Last := State["last_check_at"]
	if (Last > Now)
		return { DueAt: Earliest, Reason: "clock_moved_back" }
	Failures := State.Get("failures", 0)
	if (Failures > 0) {
		Backoff := Timing["failure_backoff_sec"]
		Candidate := Last + Min(Backoff[Min(Failures, Backoff.Length)], Interval)
		Reason := "retry_after_failure"
	} else {
		Candidate := Last + Interval + UpdateSchedule_JitterSeconds(State.Get("seed", ""), Last, Interval)
		Reason := "scheduled"
	}
	if (Candidate < Earliest)
		return { DueAt: Earliest, Reason: "catch_up" }
	return { DueAt: Candidate, Reason: Reason }
}

; Seconds to wait before re-evaluating: never past the due time, never longer
; than reevaluate_sec, so a timer that slept through a suspend is corrected.
UpdateSchedule_DelayUntil(DueAt, Now) {
	return Max(0, Min(DueAt - Now, UpdateSchedule_Timing()["reevaluate_sec"]))
}
