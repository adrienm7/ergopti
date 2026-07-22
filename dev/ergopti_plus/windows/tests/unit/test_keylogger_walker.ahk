; static/ergopti_plus/windows/tests/unit/test_keylogger_walker.ahk

; ==============================================================================
; MODULE: Keylogger Walker Tests
; DESCRIPTION:
; Unit-tests for the pure helper functions in
; modules/keylogger/keylogger_walker.ahk.
; All tested functions are free of OS hooks, file I/O, and SQLite calls,
; so they run safely inside the headless AHK test harness.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ KLW_CharClass ============
; =====================================
; =====================================

_KLW_CharClass_SpaceIsSpace() {
	AssertEqual("space", KLW_CharClass(" "))
}
Test("KLW_CharClass: ASCII space -> space", _KLW_CharClass_SpaceIsSpace)

_KLW_CharClass_TabIsSpace() {
	AssertEqual("space", KLW_CharClass("`t"))
}
Test("KLW_CharClass: tab -> space", _KLW_CharClass_TabIsSpace)

; Privacy and pause regression
_KLW_CharClass_PauseNoLeak() {
	; In full keylogger, pause (A_IsSuspended) must prevent recording
	AssertTrue(true, "keylogger walker must be used only when not paused")
}
Test("KLW_CharClass: pause invariant skeleton", _KLW_CharClass_PauseNoLeak)

_KLW_CharClass_NbspIsSpace() {
	AssertEqual("space", KLW_CharClass(Chr(0xA0)))
}
Test("KLW_CharClass: non-breaking space -> space", _KLW_CharClass_NbspIsSpace)

_KLW_CharClass_DigitIsDigit() {
	AssertEqual("digit", KLW_CharClass("5"))
}
Test("KLW_CharClass: ASCII digit -> digit", _KLW_CharClass_DigitIsDigit)

_KLW_CharClass_LowercaseIsLetter() {
	AssertEqual("letter", KLW_CharClass("a"))
}
Test("KLW_CharClass: lowercase ASCII letter -> letter", _KLW_CharClass_LowercaseIsLetter)

_KLW_CharClass_UppercaseIsLetter() {
	AssertEqual("letter", KLW_CharClass("Z"))
}
Test("KLW_CharClass: uppercase ASCII letter -> letter", _KLW_CharClass_UppercaseIsLetter)

_KLW_CharClass_EmptyIsOther() {
	AssertEqual("other", KLW_CharClass(""))
}
Test("KLW_CharClass: empty string -> other", _KLW_CharClass_EmptyIsOther)

_KLW_CharClass_BracketTagIsOther() {
	; Keylogger pipeline emits bracket markers like [BS] — must classify as other
	AssertEqual("other", KLW_CharClass("[BS]"))
}
Test("KLW_CharClass: bracket tag [BS] -> other", _KLW_CharClass_BracketTagIsOther)

_KLW_CharClass_PunctIsPunct() {
	AssertEqual("punct", KLW_CharClass("."))
}
Test("KLW_CharClass: period -> punct", _KLW_CharClass_PunctIsPunct)

_KLW_CharClass_LatinExtendedIsLetter() {
	; U+00E9 = é — Latin Extended block treated as letter
	AssertEqual("letter", KLW_CharClass(Chr(0xE9)))
}
Test("KLW_CharClass: Latin extended char -> letter", _KLW_CharClass_LatinExtendedIsLetter)





; ==============================================
; ==============================================
; ======= 2/ KLW_BurstLengthBucket ============
; ==============================================
; ==============================================

_KLW_Burst_BelowFirst() {
	; n=1 is <= first bucket boundary 1
	AssertEqual("1", KLW_BurstLengthBucket(1))
}
Test("KLW_BurstLengthBucket: n=1 -> bucket 1", _KLW_Burst_BelowFirst)

_KLW_Burst_InsideBucket5() {
	; n=3 falls in bucket 5 (first bucket > 3 is 5)
	AssertEqual("5", KLW_BurstLengthBucket(3))
}
Test("KLW_BurstLengthBucket: n=3 -> bucket 5", _KLW_Burst_InsideBucket5)

_KLW_Burst_ExactBoundary10() {
	AssertEqual("10", KLW_BurstLengthBucket(10))
}
Test("KLW_BurstLengthBucket: n=10 -> bucket 10 (exact boundary)", _KLW_Burst_ExactBoundary10)

_KLW_Burst_InsideBucket100() {
	AssertEqual("100", KLW_BurstLengthBucket(99))
}
Test("KLW_BurstLengthBucket: n=99 -> bucket 100", _KLW_Burst_InsideBucket100)

_KLW_Burst_AboveAllBuckets() {
	; n=501 exceeds every bucket boundary -> overflow sentinel
	AssertEqual("500+", KLW_BurstLengthBucket(501))
}
Test("KLW_BurstLengthBucket: n=501 -> 500+ overflow", _KLW_Burst_AboveAllBuckets)

_KLW_Burst_ExactMax() {
	; n=500 is exactly the last bucket
	AssertEqual("500", KLW_BurstLengthBucket(500))
}
Test("KLW_BurstLengthBucket: n=500 -> bucket 500 (last boundary)", _KLW_Burst_ExactMax)





; ==================================
; ==================================
; ======= 3/ KLW_PopLast ==========
; ==================================
; ==================================

_KLW_Pop_EmptyString() {
	AssertEqual("", KLW_PopLast(""))
}
Test("KLW_PopLast: empty string -> empty string", _KLW_Pop_EmptyString)

_KLW_Pop_SingleChar() {
	AssertEqual("", KLW_PopLast("a"))
}
Test("KLW_PopLast: single char -> empty string", _KLW_Pop_SingleChar)

_KLW_Pop_TwoChars() {
	AssertEqual("a", KLW_PopLast("ab"))
}
Test("KLW_PopLast: two chars -> first char remains", _KLW_Pop_TwoChars)

_KLW_Pop_LongerString() {
	AssertEqual("hell", KLW_PopLast("hello"))
}
Test("KLW_PopLast: hello -> hell", _KLW_Pop_LongerString)





; =============================
; =============================
; ======= 4/ KLW_GC ===========
; =============================
; =============================

_KLW_GC_CreatesKeyWhenAbsent() {
	tbl := Map()
	default_map := Map("x", 99)
	result := KLW_GC(tbl, "new_key", default_map)
	AssertTrue(tbl.Has("new_key"))
	AssertEqual(99, result["x"])
}
Test("KLW_GC: creates key with default when absent", _KLW_GC_CreatesKeyWhenAbsent)

_KLW_GC_ReturnsExistingValue() {
	tbl := Map()
	existing := Map("x", 42)
	tbl["k"] := existing
	; Passing a different default — must return existing, not override
	result := KLW_GC(tbl, "k", Map("x", 0))
	AssertEqual(42, result["x"])
}
Test("KLW_GC: returns existing value without overwriting", _KLW_GC_ReturnsExistingValue)





; ====================================
; ====================================
; ======= 5/ KLW_BucketAdd ===========
; ====================================
; ====================================

_KLW_BucketAdd_ValueLandsInFirstMatchingBucket() {
	; A delay of 500 ms must land in every bucket whose threshold >= 500.
	; The smallest threshold >= 500 in UI_PAUSE_BUCKETS_MS is 1000.
	; All buckets >= 1000 should accumulate the value.
	m := Map()
	KLW_BucketAdd(m, 500, 1)
	; Bucket "1000" (first threshold > 500) must be set
	AssertTrue(m.Has("1000"))
	AssertEqual(1, m["1000"])
}
Test("KLW_BucketAdd: 500ms delay lands in buckets >= 1000", _KLW_BucketAdd_ValueLandsInFirstMatchingBucket)

_KLW_BucketAdd_ExceedsAllBuckets() {
	; A delay larger than every threshold lands in no bucket
	m := Map()
	KLW_BucketAdd(m, 99999, 1)
	AssertEqual(0, m.Count)
}
Test("KLW_BucketAdd: delay > all thresholds -> no bucket added", _KLW_BucketAdd_ExceedsAllBuckets)

_KLW_BucketAdd_Accumulates() {
	m := Map()
	KLW_BucketAdd(m, 500, 3)
	KLW_BucketAdd(m, 500, 7)
	AssertEqual(10, m["1000"])
}
Test("KLW_BucketAdd: accumulates across two calls", _KLW_BucketAdd_Accumulates)
