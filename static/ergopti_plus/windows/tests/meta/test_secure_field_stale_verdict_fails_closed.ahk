; tests/meta/test_secure_field_stale_verdict_fails_closed.ahk

; ==============================================================================
; MODULE: Secure-field Expired-verdict Fail-closed Guard
; DESCRIPTION:
; SFD_IsSecureField caches one verdict keyed by the focused window handle. On a
; key match it used to return that verdict unconditionally — including long
; after SFD_FIELD_CACHE_TTL_MS had elapsed, and while the refreshing UIA probe
; was still in flight.
;
; That key does not identify what the verdict describes. Chromium and Electron
; host every field of a page behind one Chrome_RenderWidgetHostHWND — the very
; control class this detector exists to protect — so ControlGetFocus returns the
; same handle for a plain input and for the password box next to it. Type in the
; plain one, get {secure: false} cached; click into the password box and every
; character typed there was sent to the LLM as context for the rest of the
; window.
;
; ROOT CAUSE ENCODED: an expired verdict IS an unknown, and unknown must fail
; closed here exactly like an inconclusive native probe — the module header
; states the policy ("sending unknown focused-field content to an LLM is
; irreversible"). The shipped guard asserted that invariant on the
; first-classification branch only, so its sibling branch stayed uncovered.
;
; SCOPE: one source-structural guard (always meaningful) plus one behavioural
; guard that drives the real detector when the session has a focused control.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ The cached verdict needs freshness =======
; =====================================================
; =====================================================

_SFSV_CachedVerdictIsGuardedByFreshness() {
	Lookup := _DriverFuncBody("SFD_TryGetCachedVerdict")
	Assert(Lookup != "", "SFD_TryGetCachedVerdict() must exist")
	Assert(InStr(Lookup, "SFD_FIELD_CACHE_TTL_MS") > 0,
		"every cached verdict must expire at the configured TTL")
	Assert(InStr(Lookup, 'Secure := true') > 0,
		"a cache miss or expired verdict must leave the caller fail-closed")
	Assert(InStr(Lookup, 'focus_tracking_active') > 0
		and InStr(Lookup, 'verdict_generation') > 0
		and InStr(Lookup, 'element_id') > 0,
		"a negative cache hit must require the live invalidator, focus generation and UIA RuntimeId")

	Caller := _DriverFuncBody("SFD_IsSecureField")
	Assert(Caller != "" and InStr(Caller, "SFD_TryGetCachedVerdict(") > 0,
		"SFD_IsSecureField must route every cache hit through the focused-element lookup")
}





; ================================================
; ================================================
; ======= 2/ The detector behaves that way =======
; ================================================
; ================================================

; Drives the real function. The positive control runs FIRST and deliberately
; asserts the opposite outcome, so the guard below cannot be satisfied by a
; detector that has degenerated into `return true`.
_SFSV_ExpiredVerdictFailsClosedAtRuntime() {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS

	SFD_FIELD_CACHE["secure"]       := false
	SFD_FIELD_CACHE["at"]           := A_TickCount
	SFD_FIELD_CACHE["hwnd"]         := 81
	SFD_FIELD_CACHE["focus_generation"] := 4
	SFD_FIELD_CACHE["verdict_generation"] := 4
	SFD_FIELD_CACHE["element_id"] := "field:plain"
	SFD_FIELD_CACHE["focus_tracking_active"] := true
	Secure := true
	Assert(SFD_TryGetCachedVerdict(81, 4, "field:plain", &Secure) and !Secure,
		"a fresh verdict for the exact focused element must still authorise prediction")

	SFD_FIELD_CACHE["secure"]       := false
	SFD_FIELD_CACHE["at"]           := A_TickCount - (SFD_FIELD_CACHE_TTL_MS * 5)
	Secure := false
	Assert(!SFD_TryGetCachedVerdict(81, 4, "field:plain", &Secure) and Secure,
		"an EXPIRED cached verdict is an unknown and must fail closed exactly like an inconclusive native probe — serving the stale value lets a password field inherit the non-secure verdict of a sibling field on the same HWND")
}


Test("meta secure-field: a cached verdict is served only while it is fresh",
	_SFSV_CachedVerdictIsGuardedByFreshness)
Test("meta secure-field: an expired cached verdict fails closed at runtime",
	_SFSV_ExpiredVerdictFailsClosedAtRuntime)





; =============================================================
; =============================================================
; ======= 3/ Cache identity follows the focused element =======
; =============================================================
; =============================================================

_SFSV_SiblingFieldsDoNotShareFreshNegativeVerdicts() {
	global SFD_FIELD_CACHE

	SFD_FIELD_CACHE["hwnd"] := 71
	SFD_FIELD_CACHE["secure"] := false
	SFD_FIELD_CACHE["at"] := A_TickCount
	SFD_FIELD_CACHE["focus_generation"] := 9
	SFD_FIELD_CACHE["verdict_generation"] := 9
	SFD_FIELD_CACHE["element_id"] := "field:plain"
	SFD_FIELD_CACHE["focus_tracking_active"] := true

	Secure := true
	Assert(SFD_TryGetCachedVerdict(71, 9, "field:plain", &Secure)
		and !Secure,
		"a fresh negative verdict may be reused for the exact focused element")
	Assert(!SFD_TryGetCachedVerdict(71, 10, "", &Secure) and Secure,
		"a sibling field sharing the same HWND must fail closed after focus invalidation")
	Assert(!SFD_TryGetCachedVerdict(71, 9, "field:password", &Secure) and Secure,
		"a different UIA RuntimeId must never inherit a fresh negative verdict")
}

Test("secure-field: fresh negative cache is focused-element scoped (AHK-051)",
	_SFSV_SiblingFieldsDoNotShareFreshNegativeVerdicts)





; ============================================================
; ============================================================
; ======= 4/ Native monotonic verdict and backoff ages =======
; ============================================================
; ============================================================

; Both production writers sample A_TickCount, which is GetTickCount64 in the
; supported AHK runtime. A full DWORD cycle must not resurrect either entry.
; Only the real writers and lookups run here: no focus query, hook or UIA worker.
_SFSV_Native64FieldAge(AgeMs, ExpectedHit, Positive := false) {
	global SFD_FIELD_CACHE
	Saved := SFD_FIELD_CACHE
	try {
		SFD_FIELD_CACHE := Map("focus_generation", 7,
			"focus_tracking_active", true)
		Before := A_TickCount
		SFD_CommitFieldVerdict(81, Positive, 7, "field:owned")
		After := A_TickCount
		Origin := SFD_FIELD_CACHE["at"]
		Assert(Origin >= Before and Origin <= After,
			"the actual verdict writer must publish an unmasked native timestamp")
		Secure := !Positive
		Hit := SFD_TryGetCachedVerdict(81, 7, "field:owned", &Secure,
			Origin + AgeMs)
		AssertEqual(ExpectedHit, Hit,
			"verdict freshness must use the complete literal elapsed duration")
		AssertEqual(ExpectedHit ? Positive : true, Secure,
			"a miss must remain unknown; an admitted verdict must retain its value")
		AssertEqual(Origin, SFD_FIELD_CACHE["at"],
			"the lookup must not refresh its producer's timestamp")
	} finally {
		SFD_FIELD_CACHE := Saved
	}
}

_SFSV_Native64HostileAge(AgeMs, ExpectedHit) {
	global SFD_UIA_HOSTILE_CACHE, SFD_UIA_HOSTILE_TTL_MS
	Saved := SFD_UIA_HOSTILE_CACHE
	try {
		SFD_UIA_HOSTILE_CACHE := Map()
		Before := A_TickCount
		_SFD_MarkUiaHostile("owned-native64.exe")
		After := A_TickCount
		Entry := SFD_UIA_HOSTILE_CACHE["owned-native64.exe"]
		Assert(Entry.Tick >= Before and Entry.Tick <= After,
			"the actual backoff writer must publish an unmasked native timestamp")
		AssertEqual(SFD_UIA_HOSTILE_TTL_MS, Entry.DurationMs,
			"the actual writer must retain the authoritative backoff duration")
		Hit := _SFD_UiaProcessIsHostile("owned-native64.exe", Entry.Tick + AgeMs)
		AssertEqual(ExpectedHit, Hit,
			"backoff freshness must use the complete literal elapsed duration")
		AssertEqual(ExpectedHit, SFD_UIA_HOSTILE_CACHE.Has("owned-native64.exe"),
			"only expired entries may be retired")
		if ExpectedHit
			Assert(SFD_UIA_HOSTILE_CACHE["owned-native64.exe"] == Entry,
				"a fresh lookup must preserve the exact producer-owned entry")
	} finally {
		SFD_UIA_HOSTILE_CACHE := Saved
	}
}

_SFSV_Native64IdentityControls() {
	global SFD_FIELD_CACHE
	Saved := SFD_FIELD_CACHE
	try {
		SFD_FIELD_CACHE := Map("focus_generation", 7,
			"focus_tracking_active", true)
		SFD_CommitFieldVerdict(81, false, 7, "field:owned")
		Origin := SFD_FIELD_CACHE["at"]
		for Identity in [[82, 7, "field:owned"], [81, 8, "field:owned"],
				[81, 7, "field:sibling"], [81, 7, ""]] {
			Secure := false
			Assert(!SFD_TryGetCachedVerdict(Identity[1], Identity[2],
				Identity[3], &Secure, Origin + 1) and Secure,
				"a fresh clock cannot authorise a different focused-element identity")
		}
		SFD_FIELD_CACHE["focus_tracking_active"] := false
		Assert(!SFD_TryGetCachedVerdict(81, 7, "field:owned", &Secure,
			Origin + 1) and Secure, "a negative verdict requires the live invalidator")
	} finally {
		SFD_FIELD_CACHE := Saved
	}
}

_SFSV_Native64DefaultAndAbsentControls() {
	global SFD_FIELD_CACHE, SFD_UIA_HOSTILE_CACHE
	SavedField := SFD_FIELD_CACHE
	SavedHostile := SFD_UIA_HOSTILE_CACHE
	try {
		SFD_FIELD_CACHE := Map("focus_generation", 7,
			"focus_tracking_active", true)
		SFD_UIA_HOSTILE_CACHE := Map()
		SFD_CommitFieldVerdict(81, false, 7, "field:owned")
		Secure := true
		Assert(SFD_TryGetCachedVerdict(81, 7, "field:owned", &Secure) and !Secure,
			"omitting the optional clock must preserve the fresh native verdict")
		_SFD_MarkUiaHostile("owned-native64.exe")
		Assert(_SFD_UiaProcessIsHostile("owned-native64.exe"),
			"omitting the optional clock must preserve native backoff admission")
		Assert(!_SFD_UiaProcessIsHostile("", "not a clock")
			and !_SFD_UiaProcessIsHostile("absent.exe", "not a clock"),
			"an absent owner must refuse before trying to validate an unused clock")
		Assert(!SFD_TryGetCachedVerdict(82, 7, "field:owned", &Secure,
			"not a clock") and Secure, "a different HWND must refuse before clock use")
	} finally {
		SFD_FIELD_CACHE := SavedField
		SFD_UIA_HOSTILE_CACHE := SavedHostile
	}
}

for Spec in [[0, true], [999, true], [1000, false], [1001, false],
		[0x100000000, false], [0x100000000 + 999, false],
		[0x200000000, false]] {
	Test("secure-field-native64: negative verdict age " . Spec[1],
		_SFSV_Native64FieldAge.Bind(Spec[1], Spec[2]))
}
for AgeMs in [0x100000000, 0x100000000 + 999, 0x200000000]
	Test("secure-field-native64: positive verdict long gap " . AgeMs,
		_SFSV_Native64FieldAge.Bind(AgeMs, false, true))
Test("secure-field-native64: fresh positive verdict retains conservative authority",
	_SFSV_Native64FieldAge.Bind(1, true, true))
for Spec in [[0, true], [29999, true], [30000, false], [30001, false],
		[0x100000000, false], [0x100000000 + 29999, false],
		[0x200000000, false]] {
	Test("secure-field-native64: hostile backoff age " . Spec[1],
		_SFSV_Native64HostileAge.Bind(Spec[1], Spec[2]))
}
Test("secure-field-native64: focused identity controls remain fail-closed",
	_SFSV_Native64IdentityControls)
Test("secure-field-native64: native defaults and absent-owner controls",
	_SFSV_Native64DefaultAndAbsentControls)


; Native sampling order is a source policy, not a claim that these passive
; fixtures simulate a timer interleaving. Masked executable assignments prevent
; comments or strings from serving as the required origin and verdict captures.
_SFSV_Native64SnapshotGuard(Owner, Body) {
	if Body == ""
		return false
	Code := _DriverMaskNonCode(&Body)
	ClockPos := RegExMatch(Code,
		'(?m)^\s*(\w+) := IsSet\(NowTick\) \? NowTick : A_TickCount\s*$', &Clock)
	if !ClockPos
		return false
	ClockName := Clock[1]
	if _SFSV_Native64AssignmentCount(Code, ClockName) != 1
		return false
	if Owner == "SFD_TryGetCachedVerdict" {
		for Field in ["hwnd", "at", "secure", "focus_tracking_active",
				"verdict_generation", "element_id"] {
			CapturePos := RegExMatch(Body,
				'(?m)^\s*(\w+) := SFD_FIELD_CACHE\["' . Field . '"\]\s*$', &Capture)
			if (!CapturePos or CapturePos >= ClockPos
					or !RegExMatch(SubStr(Code, CapturePos, Capture.Len),
						'^\s*\w+ := SFD_FIELD_CACHE\[\s*\]\s*$')
					or _SFSV_Native64AssignmentCount(Code, Capture[1]) != 1)
				return false
		}
		return !InStr(SubStr(Code, ClockPos), "SFD_FIELD_CACHE[")
	}
	if Owner != "_SFD_UiaProcessIsHostile"
		return false
	EntryPos := RegExMatch(Code,
		'(?m)^\s*(\w+) := SFD_UIA_HOSTILE_CACHE\[ProcName\]\s*$', &Entry)
	if (!EntryPos or EntryPos >= ClockPos
			or _SFSV_Native64AssignmentCount(Code, Entry[1]) != 1)
		return false
	for Field in ["Tick", "DurationMs"] {
		CapturePos := RegExMatch(Code,
			'(?m)^\s*(\w+) := ' . Entry[1] . '\.' . Field . '\s*$', &Capture)
		if (!CapturePos or CapturePos >= ClockPos
				or _SFSV_Native64AssignmentCount(Code, Capture[1]) != 1
				or InStr(SubStr(Code, ClockPos), Entry[1] . "." . Field))
			return false
	}
	return true
}

_SFSV_Native64AssignmentCount(Code, Name) {
	Count := 0
	Pos := 1
	while Found := RegExMatch(Code, '(?im)^\s*' . Name . ' :=', &Assignment, Pos) {
		Count += 1
		Pos := Found + Assignment.Len
	}
	return Count
}

_SFSV_Native64SnapshotOrder(Owner) {
	Body := _DriverFuncBody(Owner)
	Assert(Body != "", "the actual secure-field lookup owner must be present")
	Assert(_SFSV_Native64SnapshotGuard(Owner, Body),
		"each accepted origin, verdict and identity must be local before native sampling")
}

_SFSV_Native64SnapshotSpoofRefusal(Owner) {
	Body := _DriverFuncBody(Owner)
	Assert(_SFSV_Native64SnapshotGuard(Owner, Body),
		"the executable positive control must satisfy the snapshot policy")
	Renamed := RegExReplace(Body, '\b(CacheAt|Started)\b', "OwnedOrigin")
	Renamed := RegExReplace(Renamed, '\bEntry\b', "OwnedEntry")
	Assert(_SFSV_Native64SnapshotGuard(Owner, Renamed),
		"a coherent local rename must preserve the structural policy")
	Pattern := Owner == "SFD_TryGetCachedVerdict"
		? '(?m)^\s*\w+ := SFD_FIELD_CACHE\["at"\]\s*$'
		: '(?m)^\s*\w+ := \w+\.Tick\s*$'
	Pos := RegExMatch(Body, Pattern, &Capture)
	Assert(Pos > 0, "the origin capture must be uniquely present before mutation")
	for Replacement in ["; " . Trim(Capture[0]),
			"/* " . Trim(Capture[0]) . " */",
			"IgnoredOrigin := " . Chr(39) . Trim(Capture[0]) . Chr(39)] {
		Spoof := SubStr(Body, 1, Pos - 1) . Replacement
			. SubStr(Body, Pos + Capture.Len)
		Assert(!_SFSV_Native64SnapshotGuard(Owner, Spoof),
			"non-executable origin text must not satisfy the sampling-order guard")
	}
}

for Owner in ["SFD_TryGetCachedVerdict", "_SFD_UiaProcessIsHostile"] {
	Test("secure-field-native64: capture before native sampling " . Owner,
		_SFSV_Native64SnapshotOrder.Bind(Owner))
	Test("secure-field-native64: non-code cannot fabricate origin " . Owner,
		_SFSV_Native64SnapshotSpoofRefusal.Bind(Owner))
}

_SFSV_Native64CriticalRestored() {
	global SFD_FIELD_CACHE, SFD_UIA_HOSTILE_CACHE
	SavedField := SFD_FIELD_CACHE
	SavedHostile := SFD_UIA_HOSTILE_CACHE
	SavedCritical := A_IsCritical
	try {
		for CriticalState in [0, 17] {
			Critical(CriticalState)
			SFD_FIELD_CACHE := Map("focus_generation", 7,
				"focus_tracking_active", true)
			SFD_UIA_HOSTILE_CACHE := Map()
			SFD_CommitFieldVerdict(81, false, 7, "field:owned")
			Origin := SFD_FIELD_CACHE["at"]
			Secure := true
			for AgeMs in [0, 1000] {
				SFD_TryGetCachedVerdict(81, 7, "field:owned", &Secure, Origin + AgeMs)
				AssertEqual(CriticalState, A_IsCritical,
					"verdict lookup must restore the caller's critical state on every result")
			}
			AssertThrows(() => _SFSV_Native64InvalidFieldClock(),
				"an invalid admitted clock must retain the canonical fail-fast policy")
			AssertEqual(CriticalState, A_IsCritical,
				"verdict lookup failure must preserve the caller's critical state")
			_SFD_UiaProcessIsHostile("absent.exe")
			AssertEqual(CriticalState, A_IsCritical,
				"absent backoff ownership must restore the caller's critical state")
			_SFD_MarkUiaHostile("owned-native64.exe")
			Entry := SFD_UIA_HOSTILE_CACHE["owned-native64.exe"]
			for AgeMs in [0, 30000] {
				_SFD_UiaProcessIsHostile("owned-native64.exe", Entry.Tick + AgeMs)
				AssertEqual(CriticalState, A_IsCritical,
					"backoff admission and retirement must restore the caller's critical state")
			}
			_SFD_MarkUiaHostile("owned-native64.exe")
			AssertThrows(() => _SFD_UiaProcessIsHostile("owned-native64.exe", "invalid"),
				"invalid backoff clocks must not be hidden as successful lookups")
			AssertEqual(CriticalState, A_IsCritical,
				"backoff failure must preserve the caller's critical state")
		}
	} finally {
		SFD_FIELD_CACHE := SavedField
		SFD_UIA_HOSTILE_CACHE := SavedHostile
		Critical(SavedCritical)
	}
}

_SFSV_Native64InvalidFieldClock() {
	Secure := true
	return SFD_TryGetCachedVerdict(81, 7, "field:owned", &Secure, "invalid")
}

_SFSV_Native64RenewalOwnership() {
	global SFD_UIA_HOSTILE_CACHE
	Saved := SFD_UIA_HOSTILE_CACHE
	try {
		SFD_UIA_HOSTILE_CACHE := Map()
		_SFD_MarkUiaHostile("owned-native64.exe")
		First := SFD_UIA_HOSTILE_CACHE["owned-native64.exe"]
		_SFD_MarkUiaHostile("owned-native64.exe")
		Renewed := SFD_UIA_HOSTILE_CACHE["owned-native64.exe"]
		Assert(First != Renewed and Renewed.Tick >= First.Tick,
			"the real renewal producer must replace its entry with a monotonic origin")
		Assert(_SFD_UiaProcessIsHostile("owned-native64.exe", Renewed.Tick + 29999)
			and SFD_UIA_HOSTILE_CACHE["owned-native64.exe"] == Renewed,
			"a fresh renewed entry retains its exact ownership identity")
	} finally {
		SFD_UIA_HOSTILE_CACHE := Saved
	}
}

Test("secure-field-native64: native critical state survives results and failures",
	_SFSV_Native64CriticalRestored)
Test("secure-field-native64: actual backoff renewal replaces its owned entry",
	_SFSV_Native64RenewalOwnership)

; AHK local identifiers are case-insensitive. A differently cased assignment
; still changes the captured scalar, so it must violate the unique-local policy.
_SFSV_Native64MixedCaseDuplicateRefusal(Owner) {
	Body := _DriverFuncBody(Owner)
	Assert(Body != "" and _SFSV_Native64SnapshotGuard(Owner, Body),
		"the real executable owner must provide the positive snapshot control")
	Code := _DriverMaskNonCode(&Body)
	ClockPos := RegExMatch(Code,
		'(?m)^\s*(\w+) := IsSet\(NowTick\) \? NowTick : A_TickCount\s*$', &Clock)
	Assert(ClockPos > 0, "native sampling must be uniquely located before mutation")
	Aliases := [Clock[1]]
	if Owner == "SFD_TryGetCachedVerdict" {
		for Field in ["hwnd", "at", "secure", "focus_tracking_active",
				"verdict_generation", "element_id"] {
			Pos := RegExMatch(Body,
				'(?m)^\s*(\w+) := SFD_FIELD_CACHE\["' . Field . '"\]\s*$', &Capture)
			Assert(Pos > 0, "each actual verdict capture must exist before mutation")
			Aliases.Push(Capture[1])
		}
	} else {
		Pos := RegExMatch(Code,
			'(?m)^\s*(\w+) := SFD_UIA_HOSTILE_CACHE\[ProcName\]\s*$', &Entry)
		Assert(Pos > 0, "the actual hostile entry capture must exist before mutation")
		Aliases.Push(Entry[1])
		for Field in ["Tick", "DurationMs"] {
			Pos := RegExMatch(Code,
				'(?m)^\s*(\w+) := ' . Entry[1] . '\.' . Field . '\s*$', &Capture)
			Assert(Pos > 0, "each actual backoff capture must exist before mutation")
			Aliases.Push(Capture[1])
		}
	}
	Unexpected := ""
	UnexpectedCount := 0
	for Alias in Aliases {
		Alternate := StrUpper(Alias)
		Assert(!(Alternate == Alias) and Alternate = Alias,
			"the actual duplicate must differ in spelling but retain AHK identifier equality")
		Duplicate := SubStr(Body, 1, ClockPos - 1)
			. "`n`t" . Alternate . " := 0`n"
			. SubStr(Body, ClockPos)
		if _SFSV_Native64SnapshotGuard(Owner, Duplicate) {
			UnexpectedCount += 1
			Unexpected .= (Unexpected == "" ? "" : ", ") . Alternate
		}
	}
	AssertEqual(0, UnexpectedCount,
		"all mixed-case assignments must fail unique-local admission; wrongly accepted: " . Unexpected)
}

for Owner in ["SFD_TryGetCachedVerdict", "_SFD_UiaProcessIsHostile"]
	Test("secure-field-native64: mixed-case duplicates cannot replace captures " . Owner,
		_SFSV_Native64MixedCaseDuplicateRefusal.Bind(Owner))
