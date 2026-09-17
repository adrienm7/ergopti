; tests/unit/test_crash_mapping_payload_bounds.ahk

; ==============================================================================
; MODULE: Crash Mapping Payload Bounds Tests
; DESCRIPTION: Reject oversized UTF-8 data before allocating its encoded buffer.
; ==============================================================================

#Requires AutoHotkey v2.0

_CMPB_Allocate(Sizes, NativeClass, Bytes) {
	Sizes.Push(Bytes)
	return Buffer(Bytes, 0)
}

_CMPB_Check(Payload, Accepted) {
	global CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES, CRASH_REPORT_WORKER_FILE_MAP_WRITE
	global _CrashReportWorkerSerial
	SavedLimit := CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES
	SavedAllocator := _CrashReportMappingNative.GetOwnPropDesc("AllocatePayload")
	Sizes := []
	Mapping := 0
	View := 0
	try {
		; A small ceiling exercises the real boundary without large test buffers.
		CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES := 12
		_CrashReportMappingNative.DefineProp("AllocatePayload",
			{Call: _CMPB_Allocate.Bind(Sizes)})
		Rejected := false
		try Mapping := _CrashReportWorkerCreateMapping(Payload, ++_CrashReportWorkerSerial)
		catch ValueError
			Rejected := true
		AssertEqual(!Accepted, Rejected, "the UTF-8 byte ceiling must determine admission")
		if !Accepted {
			AssertEqual(0, Sizes.Length, "rejected payloads must not allocate an encoded buffer")
			AssertFalse(IsObject(Mapping))
			return
		}
		ExpectedBytes := StrPut(Payload, "UTF-8") - 1
		AssertEqual(12, ExpectedBytes, "accepted fixtures must reach the exact byte ceiling")
		AssertEqual(1, Sizes.Length)
		AssertEqual(ExpectedBytes + 1, Sizes[1], "encoding needs one additional terminator byte")
		AssertEqual(ExpectedBytes, Mapping["bytes"])
		View := _CrashReportMappingNative.MapView(Mapping["handle"],
			CRASH_REPORT_WORKER_FILE_MAP_WRITE, ExpectedBytes + 4)
		AssertTrue(View != 0, "the actual transport mapping must be readable")
		AssertEqual(ExpectedBytes, NumGet(View, 0, "UInt"))
		AssertEqual(Payload, StrGet(View + 4, ExpectedBytes, "UTF-8"),
			"the admitted bytes must preserve the complete multibyte payload")
	} finally {
		try {
			try {
				if View
					AssertTrue(_CrashReportMappingNative.UnmapView(View))
			} finally {
				if IsObject(Mapping)
					AssertTrue(_CrashReportWorkerCloseMapping(Mapping))
			}
		} finally {
			_CrashReportMappingNative.DefineProp("AllocatePayload", SavedAllocator)
			CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES := SavedLimit
		}
	}
}

for Spec in [["ascii", "abcdefghijkl", true], ["bmp", "éééééé", true],
	["astral", "😀😀😀", true], ["ascii-over", "abcdefghijklm", false],
	["astral-over", "😀😀😀😀", false], ["empty", "", false]]
	Test("crash mapping: payload boundary " . Spec[1] . " (crash-mapping-payload-bounds)",
		_CRWT_WithMappingDebtIsolated.Bind(_CMPB_Check.Bind(Spec[2], Spec[3])))
