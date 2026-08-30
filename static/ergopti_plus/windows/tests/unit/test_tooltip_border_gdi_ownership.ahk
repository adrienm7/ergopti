; tests/unit/test_tooltip_border_gdi_ownership.ahk

; ==============================================================================
; MODULE: Tooltip border GDI ownership tests
; DESCRIPTION:
; Injects selection and deletion failures into the layered-border receipt so
; exceptional builds cannot leak selected bitmaps, pens, DCs, or screen DCs.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TBGO_Native {
	static Events := []
	static FailAt := ""

	static Reset(FailAt := "") {
		this.Events := []
		this.FailAt := FailAt
	}

	static SelectObject(DeviceContext, ObjectHandle) {
		this.Events.Push("select:" . DeviceContext . ":" . ObjectHandle)
		return this.FailAt == "select:" . ObjectHandle ? 0 : 900
	}

	static DeleteObject(ObjectHandle) {
		this.Events.Push("delete-object:" . ObjectHandle)
		return this.FailAt != "delete-object:" . ObjectHandle
	}

	static DeleteDC(DeviceContext) {
		this.Events.Push("delete-dc:" . DeviceContext)
		return this.FailAt != "delete-dc:" . DeviceContext
	}

	static ReleaseScreenDC(DeviceContext) {
		this.Events.Push("release-screen:" . DeviceContext)
		return this.FailAt != "release-screen:" . DeviceContext
	}
}

_TBGO_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}

_TBGO_FullReceipt() {
	Receipt := _TooltipBorderNewGdiReceipt()
	Receipt["screen_dc"] := 101
	Receipt["bitmap"] := 102
	Receipt["memory_dc"] := 103
	Receipt["old_bitmap"] := 104
	Receipt["bitmap_selected"] := true
	Receipt["pen"] := 105
	Receipt["old_pen"] := 106
	Receipt["pen_selected"] := true
	Receipt["old_brush"] := 107
	Receipt["brush_selected"] := true
	return Receipt
}





_TBGO_CompleteReceiptReleasesInDependencyOrder() {
	_TBGO_Native.Reset()
	Receipt := _TBGO_FullReceipt()
	AssertTrue(_TooltipBorderGdiRelease(Receipt, _TBGO_Native))
	AssertEqual("select:103:107,select:103:106,delete-object:105,select:103:104,delete-object:102,delete-dc:103,release-screen:101",
		_TBGO_Join(_TBGO_Native.Events),
		"selected stock brush, pen, bitmap, DC, and screen DC must unwind in order")
	AssertEqual(0, Receipt["pen"])
	AssertEqual(0, Receipt["bitmap"])
	AssertEqual(0, Receipt["memory_dc"])
	AssertEqual(0, Receipt["screen_dc"])
}
Test("tooltip border GDI: complete receipts release in reverse dependency order (tooltip-border-gdi-ownership)",
	_TBGO_CompleteReceiptReleasesInDependencyOrder)

_TBGO_RefusedDeleteRetainsTheExactDependencyTail() {
	_TBGO_Native.Reset("delete-object:105")
	Receipt := _TBGO_FullReceipt()
	AssertFalse(_TooltipBorderGdiRelease(Receipt, _TBGO_Native))
	AssertFalse(Receipt["brush_selected"])
	AssertFalse(Receipt["pen_selected"])
	AssertEqual(105, Receipt["pen"],
		"the refused pen and every dependency below it must remain owned")
	AssertTrue(Receipt["bitmap_selected"])
	AssertEqual(102, Receipt["bitmap"])
	AssertEqual(103, Receipt["memory_dc"])
	AssertEqual(101, Receipt["screen_dc"])
	_TBGO_Native.FailAt := ""
	AssertTrue(_TooltipBorderGdiRelease(Receipt, _TBGO_Native))
	AssertEqual("select:103:107,select:103:106,delete-object:105,delete-object:105,select:103:104,delete-object:102,delete-dc:103,release-screen:101",
		_TBGO_Join(_TBGO_Native.Events),
		"a retry must resume at the exact refused handle without re-restoring objects")
}
Test("tooltip border GDI: refused cleanup retains exact retry debt (tooltip-border-gdi-ownership)",
	_TBGO_RefusedDeleteRetainsTheExactDependencyTail)

_TBGO_PartialAllocationStillReleasesBothIndependentHandles() {
	_TBGO_Native.Reset()
	Receipt := _TooltipBorderNewGdiReceipt()
	Receipt["bitmap"] := 102
	Receipt["memory_dc"] := 103
	AssertTrue(_TooltipBorderGdiRelease(Receipt, _TBGO_Native))
	AssertEqual("delete-object:102,delete-dc:103",
		_TBGO_Join(_TBGO_Native.Events),
		"the partial-allocation branch must release both surviving siblings")
}
Test("tooltip border GDI: partial allocation cannot bypass cleanup (tooltip-border-gdi-ownership)",
	_TBGO_PartialAllocationStillReleasesBothIndependentHandles)

_TBGO_ReentrantBuildAdmissionIsBounded() {
	global _TooltipBorderGdiBusy
	OriginalBusy := _TooltipBorderGdiBusy
	_TooltipBorderGdiBusy := false
	try {
		AssertTrue(_TooltipBorderGdiTryBegin())
		AssertFalse(_TooltipBorderGdiTryBegin(),
			"a reentrant border build must not allocate a second native receipt")
	} finally {
		_TooltipBorderGdiEnd()
		_TooltipBorderGdiBusy := OriginalBusy
	}
}
Test("tooltip border GDI: reentrant builds cannot overlap ownership (tooltip-border-gdi-ownership)",
	_TBGO_ReentrantBuildAdmissionIsBounded)
