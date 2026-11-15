; tests/unit/modules/gestures/test_touchpad_hid.ahk

; ==============================================================================
; MODULE: Precision Touchpad HID Contacts Tests
; DESCRIPTION:
; Synthetic Precision Touchpad descriptors and reports through the parser's
; seams (modules/gestures/touchpad_hid.ahk): HIDP_VALUE_CAPS structures built
; byte by byte, the layout and millimetre scale they give, parallel and hybrid
; reports, and the live travel the incremental tracker steps on. No touchpad
; is needed; the adapter's HidP_GetUsageValue reader is the one part left to
; the maintainer's real touchpad.
;
; ROOT CAUSE ENCODED:
; Windows saw no finger travel: the Precision Touchpad settings hand the driver
; each swipe finished. These pin the reader that now follows the fingers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ Synthetic descriptors ===========
; ============================================
; ============================================

; One synthetic value capability, as HidP_GetValueCaps writes it.
_TPH_Cap(Page, Usage, Link, LogicalMax := 0, PhysicalMax := 0, Units := 0, UnitsExp := 0) {
	return Map("page", Page, "usage", Usage, "link", Link, "logical_max", LogicalMax,
		"physical_max", PhysicalMax, "units", Units, "units_exp", UnitsExp)
}

; Writes capabilities as back-to-back HIDP_VALUE_CAPS structures.
_TPH_CapsBuffer(Caps) {
	Buf := Buffer(Caps.Length * TouchpadHidValueCapsStride(), 0)
	for Index, Cap in Caps {
		At := (Index - 1) * TouchpadHidValueCapsStride()
		NumPut("UShort", Cap["page"], Buf, At)
		NumPut("UChar", 1, Buf, At + 2)
		NumPut("UShort", Cap["link"], Buf, At + 6)
		NumPut("UShort", 16, Buf, At + 18)
		NumPut("UShort", 1, Buf, At + 20)
		NumPut("UInt", Cap["units_exp"], Buf, At + 32)
		NumPut("UInt", Cap["units"], Buf, At + 36)
		NumPut("Int", 0, Buf, At + 40)
		NumPut("Int", Cap["logical_max"], Buf, At + 44)
		NumPut("Int", 0, Buf, At + 48)
		NumPut("Int", Cap["physical_max"], Buf, At + 52)
		NumPut("UShort", Cap["usage"], Buf, At + 56)
	}
	return Buf
}

; A five-finger Precision Touchpad of 100 x 65 mm (centimetres, exponent -2):
; X 0..3200 over 10.00 cm is 32 units per mm, Y 0..2000 over 6.50 cm about 30.8.
_TPH_PadCaps(Fingers := 5, PhysicalX := 1000, PhysicalY := 650) {
	Caps := [_TPH_Cap(0x0D, 0x54, 0), _TPH_Cap(0x0D, 0x56, 0)]
	loop Fingers {
		Link := A_Index
		Caps.Push(_TPH_Cap(0x0D, 0x51, Link, 15))
		Caps.Push(_TPH_Cap(0x01, 0x30, Link, 3200, PhysicalX, 0x11, 0x0E))
		Caps.Push(_TPH_Cap(0x01, 0x31, Link, 2000, PhysicalY, 0x11, 0x0E))
	}
	return TouchpadHidDecodeValueCaps(_TPH_CapsBuffer(Caps), Caps.Length)
}

; The value seam: a report is a contact count and one Map per finger link.
class _TPH_Reader {
	__New() {
		this.count := 0
		this.links := Map()
	}

	; Loads one report: Count, then [link, id, x, y, tip] per finger carried.
	Load(Count, Fingers*) {
		this.count := Count
		this.links := Map()
		for Finger in Fingers
			this.links[Finger[1]] := Finger
		return this
	}

	Point(*) {
	}

	Value(Page, Usage, Link) {
		if (Page = 0x0D && Usage = 0x54)
			return this.count
		if !this.links.Has(Link)
			return ""
		Finger := this.links[Link]
		if (Page = 0x0D && Usage = 0x51)
			return Finger[2]
		if (Page = 0x01 && Usage = 0x30)
			return Finger[3]
		if (Page = 0x01 && Usage = 0x31)
			return Finger[4]
		return ""
	}

	Tip(Link) {
		return this.links.Has(Link) && this.links[Link][5]
	}
}

_TPH_DecodesCapabilities() {
	Caps := _TPH_PadCaps(2)
	AssertEqual(8, Caps.Length, "two count caps and three per finger")
	X := Caps[4]
	AssertEqual(0x01, X["usage_page"], "page")
	AssertEqual(0x30, X["usage_min"], "usage")
	AssertEqual(0x30, X["usage_max"], "a non-range cap names one usage")
	AssertEqual(1, X["link_collection"], "link collection")
	AssertEqual(3200, X["logical_max"], "logical maximum")
	AssertEqual(1000, X["physical_max"], "physical maximum")
	AssertEqual(0x11, X["units"], "centimetres")
	AssertEqual(0x0E, X["units_exp"], "exponent code")
	AssertThrows(() => TouchpadHidDecodeValueCaps(Buffer(10, 0), 1), "a buffer too short")
}
Test("touchpad hid: value capabilities decode from their structures (raw-touchpad)", _TPH_DecodesCapabilities)

_TPH_LayoutAndMillimetres() {
	Layout := TouchpadHidBuildLayout(_TPH_PadCaps())
	AssertEqual(5, Layout["fingers"].Length, "five finger collections")
	AssertEqual(1, Layout["fingers"][1], "in link order")
	AssertEqual(0, Layout["count_link"], "the contact count's collection")
	AssertEqual(32.0, Layout["units_x"], "32 logical units per mm along x")
	AssertTrue(Abs(Layout["units_y"] - 2000 / 65) < 1e-9, "about 30.8 along y")
	; Inches: 4000 units over 4.00 in (exponent -2) is 101.6 mm.
	Inch := Map("logical_min", 0, "logical_max", 4000, "physical_min", 0, "physical_max", 400,
		"units", 0x13, "units_exp", 0x0E)
	AssertTrue(Abs(TouchpadHidUnitsPerMm(Inch) - 4000 / 101.6) < 1e-9, "inch units")
	; No physical size, or not a length: no millimetres.
	NoSize := TouchpadHidBuildLayout(_TPH_PadCaps(3, 0, 0))
	AssertEqual(0, NoSize["units_x"], "no physical size")
	Inch["units"] := 0x1001
	AssertEqual(0, TouchpadHidUnitsPerMm(Inch), "a unit that is not a length")
	; Not a touchpad: no contact count, or no finger with X and Y.
	AssertThrows(() => TouchpadHidBuildLayout([_TPH_PadCaps()[4]]), "no contact count")
	AssertThrows(() => TouchpadHidBuildLayout([_TPH_PadCaps()[1]]), "no finger")
}
Test("touchpad hid: the layout and its millimetres come from the descriptor (raw-touchpad)", _TPH_LayoutAndMillimetres)





; ============================================
; ============================================
; ======= 2/ Reports and frames ==============
; ============================================
; ============================================

_TPH_ParallelReport() {
	Layout := TouchpadHidBuildLayout(_TPH_PadCaps())
	Reader := _TPH_Reader().Load(3, [1, 7, 100, 200, true], [2, 8, 300, 210, true], [3, 9, 500, 220, true],
		[4, 0, 0, 0, false], [5, 0, 0, 0, false])
	Report := TouchpadHidReadReport(Layout, Reader)
	AssertEqual(3, Report.count, "contact count")
	AssertEqual(3, Report.contacts.Length, "collections beyond the count are padding, not read")
	AssertEqual(2, TouchpadHidReadReport(Layout, _TPH_Reader().Load(0, [1, 1, 5, 5, true], [2, 2, 6, 6, true]), 2).contacts.Length,
		"a continuation reads what its frame still wants")
	AssertEqual(0, TouchpadHidReadReport(Layout, _TPH_Reader().Load(0, [1, 1, 5, 5, true]), 0).contacts.Length,
		"a stray continuation reads nothing")
	AssertEqual(8, Report.contacts[2].id, "contact identifier")
	AssertEqual(300, Report.contacts[2].x, "x")
	AssertTrue(Report.contacts[3].tip, "tip down")
	Frame := TouchpadHidFrameAssembler().Feed(Report)
	AssertTrue(IsObject(Frame), "a parallel report is a whole frame")
	AssertEqual(3, Frame.Length, "three contacts")
	; Read without the count limit, the padding is still dropped by the frame.
	Padded := {count: 3, contacts: [Report.contacts[1], Report.contacts[2], Report.contacts[3], {id: 0, x: 0, y: 0, tip: false}]}
	AssertEqual(3, TouchpadHidFrameAssembler().Feed(Padded).Length, "padding beyond the count is dropped")
}
Test("touchpad hid: a parallel report is one frame (raw-touchpad)", _TPH_ParallelReport)

_TPH_HybridReports() {
	; Two fingers per report: a four-contact frame spans two reports, the
	; second with a count of 0.
	Layout := TouchpadHidBuildLayout(_TPH_PadCaps(2))
	Assembler := TouchpadHidFrameAssembler()
	Reader := _TPH_Reader()
	First := Assembler.Feed(TouchpadHidReadReport(Layout, Reader.Load(4, [1, 1, 10, 10, true], [2, 2, 20, 10, true])))
	AssertEqual("", First, "half a frame is not a frame")
	Second := Assembler.Feed(TouchpadHidReadReport(Layout, Reader.Load(0, [1, 3, 30, 10, true], [2, 4, 40, 10, true])))
	AssertTrue(IsObject(Second), "the second report completes it")
	AssertEqual(4, Second.Length, "four contacts")
	AssertEqual(4, Second[4].id, "in report order")
	; A count-0 report with no frame pending is a stray, and a new count drops
	; an unfinished frame.
	AssertEqual("", Assembler.Feed(TouchpadHidReadReport(Layout, Reader.Load(0, [1, 1, 10, 10, true]))), "stray report")
	Assembler.Feed(TouchpadHidReadReport(Layout, Reader.Load(3, [1, 1, 10, 10, true], [2, 2, 20, 10, true])))
	Restart := Assembler.Feed(TouchpadHidReadReport(Layout, Reader.Load(1, [1, 5, 50, 10, true])))
	AssertTrue(IsObject(Restart) && Restart.Length = 1 && Restart[1].id = 5, "a new count restarts the frame")
}
Test("touchpad hid: hybrid reports assemble one frame (raw-touchpad)", _TPH_HybridReports)

; One frame of tip contacts {id, x, y}.
_TPH_Frame(Contacts*) {
	Frame := []
	for Contact in Contacts
		Frame.Push({id: Contact[1], x: Contact[2], y: Contact[3], tip: Contact.Length < 4 || Contact[4]})
	return Frame
}

; Three fingers at a horizontal offset, all moved by Dx.
_TPH_Three(Dx, Dy := 0) {
	return _TPH_Frame([1, 100 + Dx, 500 + Dy], [2, 300 + Dx, 510 + Dy], [3, 500 + Dx, 520 + Dy])
}

_TPH_LiveTravelHoldsTheCount() {
	Travel := TouchpadLiveTravel(2)
	; Fingers land one at a time: one, two, then three.
	Travel.Feed(_TPH_Frame([1, 100, 500]))
	Travel.Feed(_TPH_Frame([1, 100, 500], [2, 300, 510]))
	Travel.Feed(_TPH_Frame([1, 100, 500], [2, 300, 510]))
	AssertEqual(2, Travel.Live().fingers, "a held pair")
	Travel.Feed(_TPH_Three(0))
	AssertFalse(IsObject(Travel.Live()), "the third finger has not held yet")
	Travel.Feed(_TPH_Three(30))
	Live := Travel.Live()
	AssertEqual(3, Live.fingers, "three fingers once held two frames")
	AssertEqual(30, Live.dx, "travel starts where the count started")
	Travel.Feed(_TPH_Three(90, -12))
	Live := Travel.Live()
	AssertEqual(90, Live.dx, "travel accumulates")
	AssertEqual(-12, Live.dy, "both axes")
	; A swapped finger moves the centroid without the hand moving.
	Travel.Feed(_TPH_Frame([1, 190, 488], [2, 390, 498], [4, 900, 508]))
	AssertEqual(90, Travel.Live().dx, "a swapped contact set travels nothing")
	; Two fingers lift: the frame is no swipe of the peak count.
	Travel.Feed(_TPH_Frame([1, 190, 488]))
	AssertFalse(IsObject(Travel.Live()), "fewer fingers than the peak do not travel")
	AssertTrue(Travel.Touching(), "still touching")
	AssertTrue(Travel.Feed(_TPH_Frame([1, 190, 488, false])), "the lift frame ends the touch")
	AssertFalse(Travel.Touching(), "no contact down")
	AssertFalse(Travel.Feed(_TPH_Frame([1, 190, 488, false])), "a second lift ends nothing")
	AssertThrows(() => TouchpadLiveTravel(0), "a count must hold at least one frame")
}
Test("touchpad hid: live travel holds the finger count and its contacts (raw-touchpad)", _TPH_LiveTravelHoldsTheCount)





; ============================================
; ============================================
; ======= 3/ Completed-swipe handoff =========
; ============================================
; ============================================

_TPH_HandoffOwnsASteppedSwipe() {
	Handoff := GestureSwipeHandoff(300)
	; Nothing seen: the shortcut fires.
	AssertEqual("dispatch", Handoff.Claim("swipe_3_left", true, 1000), "no touch seen")
	; Shortcut during a touch that stepped: swallowed.
	Handoff.TouchBegan()
	Handoff.StepFired()
	AssertEqual("swallow", Handoff.Claim("swipe_3_left", true, 1010), "the touch stepped")
	AssertEqual("", Handoff.TouchEnded(1020), "nothing deferred")
	; Shortcut after a touch that stepped, within the window: swallowed.
	AssertEqual("swallow", Handoff.Claim("swipe_3_left", true, 1300), "late shortcut of a stepped touch")
	AssertEqual("dispatch", Handoff.Claim("swipe_3_left", true, 1321), "past the window it is a new swipe")
	; An incremental slot's shortcut during a touch that has not stepped waits
	; for its end, and fires then once.
	Handoff.TouchBegan()
	AssertEqual("defer", Handoff.Claim("swipe_3_left", true, 2000), "may still step")
	AssertEqual("swipe_3_left", Handoff.Pending(), "pending")
	AssertEqual("swipe_3_left", Handoff.TouchEnded(2050), "fires once at the end")
	AssertEqual("", Handoff.Pending(), "no longer pending")
	; ...but not when the touch stepped after all.
	Handoff.TouchBegan()
	AssertEqual("defer", Handoff.Claim("swipe_3_right", true, 3000), "deferred")
	Handoff.StepFired()
	AssertEqual("", Handoff.TouchEnded(3010), "the steps own the swipe")
	; An x1 slot's shortcut fires at once during a touch that did not step.
	Handoff.TouchBegan()
	AssertEqual("dispatch", Handoff.Claim("swipe_3_up", false, 4000), "x1 during a still touch")
	Handoff.StepFired()
	AssertEqual("swallow", Handoff.Claim("swipe_3_up", false, 4010), "any slot of a stepped touch")
	Handoff.TouchEnded(4020)
	AssertThrows(() => GestureSwipeHandoff(0), "a window must be positive")
}
Test("touchpad hid: a touch that stepped owns its swipe's shortcut (raw-touchpad)", _TPH_HandoffOwnsASteppedSwipe)
