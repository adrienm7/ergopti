; gestures/adapters/touchpad_hid.ahk

; ==============================================================================
; MODULE: Precision Touchpad HID Contacts (pure)
; DESCRIPTION:
; Turns a Windows Precision Touchpad's HID input reports into contact frames
; and the live travel of a swipe, for the incremental tracker. Everything that
; needs the device (raw input, the preparsed descriptor, the HidP_* readers)
; lives in platform/system/raw_input.ahk; this file holds what can be wrong in ways a
; real touchpad would not reveal quickly, so synthetic reports can pin it.
;
; FEATURES & RATIONALE:
; 1. The layout comes from the descriptor's value capabilities: one finger per
;    link collection carrying X (Generic Desktop 0x30) and Y (0x31), the
;    Contact Count (Digitizer 0x54), and the logical-to-physical scale of X and
;    Y, which gives logical units per millimetre (centimetre or inch units,
;    with the HID unit exponent). A descriptor without a physical size has no
;    millimetres: the caller then fires incremental slots once, as Linux does.
; 2. The parser reads values through a seam (an object with Value and Tip),
;    which the adapter backs with HidP_GetUsageValue/HidP_GetUsages and the
;    tests with synthetic reports.
; 3. Hybrid reporting: a frame of N contacts may span several reports; the
;    first carries the contact count, the others count 0. Parallel reports
;    carry every finger at once; contacts beyond the count are padding.
; 4. Live travel follows the Linux decoder's rules 1 and 3: a finger count
;    becomes the swipe's only after it holds for finger_join_frames frames, and
;    only frames where those same contacts are down travel. A report is read
;    only up to the contacts its frame wants: each read is a HidP call.
; ==============================================================================

#Requires AutoHotkey v2.0

; HID usage pages and usages read from a Precision Touchpad (HID Usage
; Tables: Generic Desktop 0x01, Digitizer 0x0D), in one table.
global TOUCHPAD_HID := {page_desktop: 0x01, page_digitizer: 0x0D, touch_pad: 0x05,
	x: 0x30, y: 0x31, tip_switch: 0x42, contact_id: 0x51, contact_count: 0x54}

; The stride of HidP_GetValueCaps' array: HIDP_VALUE_CAPS is 72 bytes on both
; pointer sizes.
TouchpadHidValueCapsStride() => 72





; ======================================
; ======================================
; ======= 1/ Descriptor layout =========
; ======================================
; ======================================

; Decodes an array of HIDP_VALUE_CAPS, as HidP_GetValueCaps fills it.
; @param Caps {Buffer} The structures, back to back.
; @param Count {Integer} How many the call reported.
; @returns {Array} One Map per capability.
TouchpadHidDecodeValueCaps(Caps, Count) {
	if !(Caps is Buffer) || !(Count is Integer) || Count < 0 || Caps.Size < Count * TouchpadHidValueCapsStride()
		throw ValueError("The value capabilities do not fit their buffer.")
	Decoded := []
	loop Count {
		At := (A_Index - 1) * TouchpadHidValueCapsStride()
		IsRange := NumGet(Caps, At + 12, "UChar") != 0
		Decoded.Push(Map(
			"usage_page", NumGet(Caps, At, "UShort"),
			"report_id", NumGet(Caps, At + 2, "UChar"),
			"link_collection", NumGet(Caps, At + 6, "UShort"),
			"is_range", IsRange,
			"bit_size", NumGet(Caps, At + 18, "UShort"),
			"report_count", NumGet(Caps, At + 20, "UShort"),
			"units_exp", NumGet(Caps, At + 32, "UInt"),
			"units", NumGet(Caps, At + 36, "UInt"),
			"logical_min", NumGet(Caps, At + 40, "Int"),
			"logical_max", NumGet(Caps, At + 44, "Int"),
			"physical_min", NumGet(Caps, At + 48, "Int"),
			"physical_max", NumGet(Caps, At + 52, "Int"),
			; Range.UsageMin / Range.UsageMax, or NotRange.Usage twice.
			"usage_min", NumGet(Caps, At + 56, "UShort"),
			"usage_max", NumGet(Caps, IsRange ? At + 58 : At + 56, "UShort")))
	}
	return Decoded
}

; Whether a capability covers one usage of one page.
_TouchpadHidCapHas(Cap, Page, Usage) {
	return Cap["usage_page"] = Page && Cap["usage_min"] <= Usage && Usage <= Cap["usage_max"]
}

; Logical units per millimetre of an axis capability, or 0 when its physical
; size is not reported or not a length.
; @param Cap {Map} A decoded X or Y capability.
; @returns {Number}
TouchpadHidUnitsPerMm(Cap) {
	Logical := Cap["logical_max"] - Cap["logical_min"]
	Physical := Cap["physical_max"] - Cap["physical_min"]
	if (Logical <= 0 || Physical <= 0)
		return 0
	; HID unit: the low nibble is the system (1 SI linear, centimetres; 3
	; English linear, inches), the next one the length exponent, which must be 1.
	Units := Cap["units"]
	System := Units & 0xF
	if ((Units >> 4) & 0xF) != 1 || (Units & ~0xFF) != 0
		return 0
	if (System = 1)
		Millimetres := 10.0
	else if (System = 3)
		Millimetres := 25.4
	else
		return 0
	; The unit exponent is a 4-bit two's complement code (0xE is -2).
	Exponent := Cap["units_exp"] & 0xF
	if (Exponent >= 8)
		Exponent -= 16
	return Logical / (Physical * (10 ** Exponent) * Millimetres)
}

; Builds the contact layout of a touchpad from its input value capabilities.
; @param ValueCaps {Array} Decoded capabilities (TouchpadHidDecodeValueCaps).
; @returns {Map} fingers (Array of link collections, ascending), count_link,
;     units_x and units_y (logical units per millimetre, 0 when unknown).
; @throws {ValueError} When the descriptor has no contact count or no finger.
TouchpadHidBuildLayout(ValueCaps) {
	global TOUCHPAD_HID
	if !(ValueCaps is Array)
		throw TypeError("The layout needs the decoded value capabilities.")
	Xs := Map(), Ys := Map()
	CountLink := ""
	for Cap in ValueCaps {
		Link := Cap["link_collection"]
		if _TouchpadHidCapHas(Cap, TOUCHPAD_HID.page_desktop, TOUCHPAD_HID.x)
			Xs[Link] := Cap
		if _TouchpadHidCapHas(Cap, TOUCHPAD_HID.page_desktop, TOUCHPAD_HID.y)
			Ys[Link] := Cap
		if (CountLink = "" && _TouchpadHidCapHas(Cap, TOUCHPAD_HID.page_digitizer, TOUCHPAD_HID.contact_count))
			CountLink := Link
	}
	if (CountLink = "")
		throw ValueError("The touchpad descriptor reports no contact count.")
	Fingers := []
	; A Map enumerates integer keys in ascending order: the report order.
	for Link, Cap in Xs {
		if Ys.Has(Link)
			Fingers.Push(Link)
	}
	if !Fingers.Length
		throw ValueError("The touchpad descriptor reports no finger with X and Y.")
	First := Fingers[1]
	return Map("fingers", Fingers, "count_link", CountLink,
		"units_x", TouchpadHidUnitsPerMm(Xs[First]), "units_y", TouchpadHidUnitsPerMm(Ys[First]))
}





; ======================================
; ======================================
; ======= 2/ Reports and frames ========
; ======================================
; ======================================

; Reads one input report through the value seam.
; @param Layout {Map} From TouchpadHidBuildLayout.
; @param Reader {Object} Value(Page, Usage, Link) -> Integer or "" when the
;     report does not carry it; Tip(Link) -> Boolean.
; @param Wanted {Integer} Contacts still wanted by the frame in progress when
;     the report counts none (hybrid continuation), 0 for no frame. A report
;     that counts its contacts is read up to that count: the other collections
;     are padding, and each read is a HidP call on the hot path.
; @returns {Object} {count, contacts}: the report's contact count and one
;     {id, x, y, tip} per finger collection it carries, in layout order.
TouchpadHidReadReport(Layout, Reader, Wanted := -1) {
	global TOUCHPAD_HID
	Count := Reader.Value(TOUCHPAD_HID.page_digitizer, TOUCHPAD_HID.contact_count, Layout["count_link"])
	Contacts := []
	Limit := (Count != "" && Count > 0) ? Count : (Wanted < 0 ? Layout["fingers"].Length : Wanted)
	for Link in Layout["fingers"] {
		if (Contacts.Length >= Limit)
			break
		X := Reader.Value(TOUCHPAD_HID.page_desktop, TOUCHPAD_HID.x, Link)
		Y := Reader.Value(TOUCHPAD_HID.page_desktop, TOUCHPAD_HID.y, Link)
		if (X = "" || Y = "")
			continue
		Id := Reader.Value(TOUCHPAD_HID.page_digitizer, TOUCHPAD_HID.contact_id, Link)
		Contacts.Push({id: Id = "" ? Link : Id, x: X, y: Y, tip: Reader.Tip(Link) ? true : false})
	}
	return {count: Count = "" ? 0 : Count, contacts: Contacts}
}

; Collects reports into complete contact frames, parallel or hybrid.
class TouchpadHidFrameAssembler {
	__New() {
		this._expected := 0
		this._pending := []
	}

	; Contacts the frame in progress still wants from a continuation report.
	Wanted() {
		return this._expected - this._pending.Length
	}

	; Feeds one parsed report.
	; @param Report {Object} From TouchpadHidReadReport.
	; @returns {Array|String} The frame's contacts once complete, "" otherwise.
	Feed(Report) {
		if (Report.count > 0) {
			; A non-zero count starts a frame; an unfinished one is dropped.
			this._expected := Report.count
			this._pending := []
		} else if (this._expected = 0) {
			return ""
		}
		for Contact in Report.contacts {
			if (this._pending.Length >= this._expected)
				break
			this._pending.Push(Contact)
		}
		if (this._pending.Length < this._expected)
			return ""
		Frame := this._pending
		this._expected := 0
		this._pending := []
		return Frame
	}
}

; The swipe in progress, from successive frames: the held finger count and the
; travel its contacts covered together, in logical units.
class TouchpadLiveTravel {
	; @param StableFrames {Integer} Frames a count holds before it is the swipe's.
	__New(StableFrames) {
		if !(StableFrames is Integer) || StableFrames < 1
			throw ValueError("A finger count needs at least one frame to hold.")
		this._stable := StableFrames
		this._Reset()
	}

	_Reset() {
		this._touching := false
		this._count := 0, this._peak := 0
		this._run_count := 0, this._run_frames := 0, this._run_x := 0, this._run_y := 0
		this._travel_x := 0, this._travel_y := 0
		this._prev_x := "", this._prev_y := "", this._prev_key := ""
	}

	; Whether contacts are down.
	Touching() {
		return this._touching
	}

	; Feeds one complete frame.
	; @param Frame {Array} Contacts {id, x, y, tip}.
	; @returns {Boolean} True when the frame ended the touch (no contact down).
	Feed(Frame) {
		; The contact set's identity, in report order: a device keeps each
		; finger in its collection, and a reordering only skips one frame.
		SumX := 0, SumY := 0, Count := 0, Key := ""
		for Contact in Frame {
			if !Contact.tip
				continue
			SumX += Contact.x, SumY += Contact.y
			Count += 1
			Key .= Contact.id . ","
		}
		if (Count = 0) {
			Ended := this._touching
			this._Reset()
			return Ended
		}
		this._touching := true
		this._count := Count
		Cx := SumX / Count, Cy := SumY / Count
		if (Count != this._run_count) {
			this._run_count := Count, this._run_frames := 0
			this._run_x := Cx, this._run_y := Cy
		}
		this._run_frames += 1
		if (Count > this._peak && this._run_frames >= this._stable) {
			; Rule 1: the count is the swipe's once held; its travel starts
			; where the count started, since a brisk swipe moves from its first frame.
			this._peak := Count
			this._travel_x := Cx - this._run_x, this._travel_y := Cy - this._run_y
			this._prev_x := Cx, this._prev_y := Cy, this._prev_key := Key
		} else if (Count = this._peak) {
			; Rule 3: only frames where the same peak contacts are down travel;
			; a swapped finger moves the centroid without the hand moving.
			if (this._prev_x != "" && this._prev_key = Key) {
				this._travel_x += Cx - this._prev_x
				this._travel_y += Cy - this._prev_y
			}
			this._prev_x := Cx, this._prev_y := Cy, this._prev_key := Key
		} else {
			this._prev_x := "", this._prev_y := "", this._prev_key := ""
		}
		return false
	}

	; The swipe in progress, for a slot that acts while the fingers move.
	; @returns {Object|String} {fingers, dx, dy} in logical units, "" when none moves.
	Live() {
		if !this._touching || this._peak < 2 || this._count != this._peak
			return ""
		return {fingers: this._peak, dx: this._travel_x, dy: this._travel_y}
	}
}

; ======================================
; ======================================
; ======= 3/ Completed-swipe handoff ===
; ======================================
; ======================================

; Decides who owns a swipe when the touchpad settings also send its shortcut.
; The registry-mapped hotkey arrives once per recognised swipe, before or after
; the raw frames that already stepped: whichever comes first, a touch that
; acted while moving owns the swipe and its shortcut is swallowed; a touch
; that did not act lets the shortcut fire once (an incremental slot's at the
; touch's end, since the fingers may still earn steps).
class GestureSwipeHandoff {
	; @param WindowMs {Integer} How long after a touch ends its shortcut still
	;     belongs to it (the [gestures] incremental_handoff_ms timing).
	__New(WindowMs) {
		if !(WindowMs is Integer) || WindowMs <= 0
			throw ValueError("The swipe handoff needs a positive window.")
		this._window := WindowMs
		this._touching := false
		this._touch_fired := false
		this._last_end := ""
		this._last_fired := false
		this._pending := ""
	}

	; A touch began on a touchpad the tracker reads.
	TouchBegan() {
		if this._touching
			return
		this._touching := true
		this._touch_fired := false
	}

	; The touch in progress fired at least one incremental step.
	StepFired() {
		this._touch_fired := true
	}

	; The touch ended.
	; @param Now {Integer} A_TickCount.
	; @returns {String} The deferred slot to dispatch now, or "".
	TouchEnded(Now) {
		if !this._touching
			return ""
		this._touching := false
		this._last_end := Now
		this._last_fired := this._touch_fired
		Pending := this._pending
		this._pending := ""
		return this._touch_fired ? "" : Pending
	}

	; Whether a slot's shortcut waits for the touch's end.
	Pending() {
		return this._pending
	}

	; What to do with a swipe slot's shortcut now.
	; @param Slot {String} The slot the shortcut names.
	; @param Incremental {Boolean} Whether that slot is in incremental mode.
	; @param Now {Integer} A_TickCount.
	; @returns {String} "dispatch", "swallow" or "defer".
	Claim(Slot, Incremental, Now) {
		if this._touching {
			if this._touch_fired
				return "swallow"
			if !Incremental
				return "dispatch"
			this._pending := Slot
			return "defer"
		}
		if (this._last_end != "" && Now - this._last_end <= this._window)
			return this._last_fired ? "swallow" : "dispatch"
		return "dispatch"
	}
}
