; adapters/raw_input.ahk

; ==============================================================================
; MODULE: Raw Input HID Adapter (AutoHotkey)
; DESCRIPTION:
; The native half of the touchpad reader: registration of a HID top-level
; collection for WM_INPUT (RegisterRawInputDevices), the raw HID reports of one
; WM_INPUT, a device's preparsed descriptor, its value capabilities, and a
; report reader backed by HidP_GetUsageValue / HidP_GetUsages that
; modules/gestures/touchpad_hid.ahk parses through.
;
; FEATURES & RATIONALE:
; 1. RIDEV_INPUTSINK: the script's hidden window receives the touchpad while
;    another application has the focus, which a gesture needs.
; 2. RIDEV_DEVNOTIFY: arrival and removal (WM_INPUT_DEVICE_CHANGE) let the
;    owner forget a removed device's descriptor.
; 3. One growing receive buffer and the HidP entry points resolved once: a
;    report arrives about every 8 ms while fingers touch, so the hot path
;    allocates nothing and looks nothing up by name.
; 4. Fail fast: every Win32 or HidP failure throws with its code; the owner
;    decides what a failure means for the feature.
; ==============================================================================

#Requires AutoHotkey v2.0

global RAW_INPUT_WM_INPUT := 0x00FF
global RAW_INPUT_WM_INPUT_DEVICE_CHANGE := 0x00FE
global RAW_INPUT_RIDEV_REMOVE := 0x00000001
global RAW_INPUT_RIDEV_INPUTSINK := 0x00000100
global RAW_INPUT_RIDEV_DEVNOTIFY := 0x00002000
global RAW_INPUT_RID_INPUT := 0x10000003
global RAW_INPUT_RIDI_PREPARSEDDATA := 0x20000005
global RAW_INPUT_RIM_TYPEHID := 2
global RAW_INPUT_GIDC_REMOVAL := 2
global RAW_INPUT_HIDP_INPUT := 0
global RAW_INPUT_HIDP_STATUS_SUCCESS := 0x00110000
; The report does not carry that usage (another report id, or no such field).
global RAW_INPUT_HIDP_STATUS_USAGE_NOT_FOUND := 0xC0110004





; =====================================
; =====================================
; ======= 1/ Registration =============
; =====================================
; =====================================

; Registers (or removes) one HID top-level collection for WM_INPUT.
; @param UsagePage {Integer} Collection usage page.
; @param Usage {Integer} Collection usage.
; @param Flags {Integer} RIDEV_* flags.
; @param Hwnd {Integer} Target window; 0 with RIDEV_REMOVE.
; @throws {OSError} When Windows refuses the registration.
RawInput_Register(UsagePage, Usage, Flags, Hwnd) {
	Device := Buffer(8 + A_PtrSize, 0)
	NumPut("UShort", UsagePage, Device, 0)
	NumPut("UShort", Usage, Device, 2)
	NumPut("UInt", Flags, Device, 4)
	NumPut("Ptr", Hwnd, Device, 8)
	if !DllCall("User32\RegisterRawInputDevices", "Ptr", Device, "UInt", 1, "UInt", Device.Size, "Int")
		throw OSError(A_LastError, -1, "RegisterRawInputDevices")
}





; =====================================
; =====================================
; ======= 2/ Reports ==================
; =====================================
; =====================================

; Receives WM_INPUT payloads into one reused buffer.
class RawInputReceiver {
	__New() {
		this._buffer := Buffer(1024, 0)
		; RAWINPUTHEADER: dwType, dwSize, hDevice, wParam.
		this._header := 8 + 2 * A_PtrSize
	}

	; Reads the HID payload of one WM_INPUT.
	; @param LParam {Integer} The message's HRAWINPUT.
	; @returns {Object|String} {device, ptr, size, count}: the reports of a HID
	;     payload (count reports of size bytes from ptr), "" for another type.
	; @throws {OSError} When GetRawInputData fails.
	Read(LParam) {
		global RAW_INPUT_RID_INPUT, RAW_INPUT_RIM_TYPEHID
		Size := this._buffer.Size
		Got := DllCall("User32\GetRawInputData", "Ptr", LParam, "UInt", RAW_INPUT_RID_INPUT,
			"Ptr", this._buffer, "UInt*", &Size, "UInt", this._header, "UInt")
		if (Got = 0xFFFFFFFF) {
			; Too small: ask for the size, grow once, read again.
			Size := 0
			DllCall("User32\GetRawInputData", "Ptr", LParam, "UInt", RAW_INPUT_RID_INPUT,
				"Ptr", 0, "UInt*", &Size, "UInt", this._header, "UInt")
			if (Size = 0)
				throw OSError(A_LastError, -1, "GetRawInputData")
			this._buffer := Buffer(Size, 0)
			Got := DllCall("User32\GetRawInputData", "Ptr", LParam, "UInt", RAW_INPUT_RID_INPUT,
				"Ptr", this._buffer, "UInt*", &Size, "UInt", this._header, "UInt")
			if (Got = 0xFFFFFFFF)
				throw OSError(A_LastError, -1, "GetRawInputData")
		}
		if (NumGet(this._buffer, 0, "UInt") != RAW_INPUT_RIM_TYPEHID)
			return ""
		; RAWHID: dwSizeHid, dwCount, then the reports.
		return {device: NumGet(this._buffer, 8, "Ptr"),
			size: NumGet(this._buffer, this._header, "UInt"),
			count: NumGet(this._buffer, this._header + 4, "UInt"),
			ptr: this._buffer.Ptr + this._header + 8}
	}
}





; =====================================
; =====================================
; ======= 3/ Device descriptor ========
; =====================================
; =====================================

; A device's preparsed HID descriptor.
; @param Device {Integer} The raw input device handle.
; @returns {Buffer}
; @throws {OSError} When Windows cannot return it.
RawInput_PreparsedData(Device) {
	global RAW_INPUT_RIDI_PREPARSEDDATA
	Size := 0
	DllCall("User32\GetRawInputDeviceInfoW", "Ptr", Device, "UInt", RAW_INPUT_RIDI_PREPARSEDDATA,
		"Ptr", 0, "UInt*", &Size, "UInt")
	if (Size = 0)
		throw OSError(A_LastError, -1, "GetRawInputDeviceInfoW size")
	Data := Buffer(Size, 0)
	if (DllCall("User32\GetRawInputDeviceInfoW", "Ptr", Device, "UInt", RAW_INPUT_RIDI_PREPARSEDDATA,
		"Ptr", Data, "UInt*", &Size, "UInt") = 0xFFFFFFFF)
		throw OSError(A_LastError, -1, "GetRawInputDeviceInfoW")
	return Data
}

; The top-level collection and input sizes of a preparsed descriptor.
; @param Preparsed {Buffer}
; @returns {Map} usage_page, usage, input_report_length, input_value_caps.
; @throws {Error} When HidP_GetCaps fails.
RawInput_HidCaps(Preparsed) {
	global RAW_INPUT_HIDP_STATUS_SUCCESS
	; HIDP_CAPS is 64 bytes.
	Caps := Buffer(64, 0)
	Status := DllCall("Hid\HidP_GetCaps", "Ptr", Preparsed, "Ptr", Caps, "UInt")
	if (Status != RAW_INPUT_HIDP_STATUS_SUCCESS)
		throw Error(Format("HidP_GetCaps failed: 0x{1:08X}.", Status))
	return Map("usage", NumGet(Caps, 0, "UShort"), "usage_page", NumGet(Caps, 2, "UShort"),
		"input_report_length", NumGet(Caps, 4, "UShort"), "input_value_caps", NumGet(Caps, 48, "UShort"))
}

; The input value capabilities of a preparsed descriptor, raw.
; @param Preparsed {Buffer}
; @param Count {Integer} input_value_caps from RawInput_HidCaps.
; @param Got {VarRef} Receives how many structures Windows wrote.
; @returns {Buffer} HIDP_VALUE_CAPS structures (TouchpadHidDecodeValueCaps).
RawInput_HidValueCaps(Preparsed, Count, &Got) {
	global RAW_INPUT_HIDP_INPUT, RAW_INPUT_HIDP_STATUS_SUCCESS
	Caps := Buffer(Max(1, Count) * TouchpadHidValueCapsStride(), 0)
	Got := Count
	Status := DllCall("Hid\HidP_GetValueCaps", "Int", RAW_INPUT_HIDP_INPUT, "Ptr", Caps,
		"UShort*", &Got, "Ptr", Preparsed, "UInt")
	if (Status != RAW_INPUT_HIDP_STATUS_SUCCESS)
		throw Error(Format("HidP_GetValueCaps failed: 0x{1:08X}.", Status))
	return Caps
}





; =====================================
; =====================================
; ======= 4/ Report reader ============
; =====================================
; =====================================

; The production value seam of TouchpadHidReadReport: one device's descriptor
; and the report under the cursor. Point() moves it; nothing is allocated per
; report.
class RawInputHidReader {
	; @param Preparsed {Buffer} The device's preparsed descriptor.
	__New(Preparsed) {
		static Module := DllCall("Kernel32\LoadLibraryW", "Str", "hid.dll", "Ptr")
		if !Module
			throw OSError(A_LastError, -1, "hid.dll could not be loaded")
		this._get_value := DllCall("Kernel32\GetProcAddress", "Ptr", Module, "AStr", "HidP_GetUsageValue", "Ptr")
		this._get_usages := DllCall("Kernel32\GetProcAddress", "Ptr", Module, "AStr", "HidP_GetUsages", "Ptr")
		if !this._get_value || !this._get_usages
			throw OSError(A_LastError, -1, "GetProcAddress HidP")
		this._preparsed := Preparsed
		; Room for the pressed buttons one finger collection reports (tip,
		; confidence and a few vendor bits); HidP_GetUsages reports an excess
		; as BUFFER_TOO_SMALL, which Tip() throws.
		this._usage_slots := 16
		this._usages := Buffer(2 * this._usage_slots, 0)
		this._report := 0
		this._length := 0
	}

	; Points the reader at one report.
	Point(ReportPtr, Length) {
		this._report := ReportPtr
		this._length := Length
	}

	; @returns {Integer|String} The usage's value, "" when the report lacks it.
	Value(Page, Usage, Link) {
		global RAW_INPUT_HIDP_INPUT, RAW_INPUT_HIDP_STATUS_SUCCESS, RAW_INPUT_HIDP_STATUS_USAGE_NOT_FOUND
		Got := 0
		Status := DllCall(this._get_value, "Int", RAW_INPUT_HIDP_INPUT, "UShort", Page, "UShort", Link,
			"UShort", Usage, "UInt*", &Got, "Ptr", this._preparsed, "Ptr", this._report, "UInt", this._length, "UInt")
		if (Status = RAW_INPUT_HIDP_STATUS_SUCCESS)
			return Got
		if (Status = RAW_INPUT_HIDP_STATUS_USAGE_NOT_FOUND)
			return ""
		throw Error(Format("HidP_GetUsageValue(0x{1:X}, 0x{2:X}, {3}) failed: 0x{4:08X}.", Page, Usage, Link, Status))
	}

	; @returns {Boolean} Whether the finger collection's tip switch is down.
	Tip(Link) {
		global RAW_INPUT_HIDP_INPUT, RAW_INPUT_HIDP_STATUS_SUCCESS, RAW_INPUT_HIDP_STATUS_USAGE_NOT_FOUND
		global TOUCHPAD_HID
		Count := this._usage_slots
		Status := DllCall(this._get_usages, "Int", RAW_INPUT_HIDP_INPUT, "UShort", TOUCHPAD_HID.page_digitizer,
			"UShort", Link, "Ptr", this._usages, "UInt*", &Count, "Ptr", this._preparsed,
			"Ptr", this._report, "UInt", this._length, "UInt")
		if (Status = RAW_INPUT_HIDP_STATUS_USAGE_NOT_FOUND)
			return false
		if (Status != RAW_INPUT_HIDP_STATUS_SUCCESS)
			throw Error(Format("HidP_GetUsages({1}) failed: 0x{2:08X}.", Link, Status))
		loop Count {
			if (NumGet(this._usages, (A_Index - 1) * 2, "UShort") = TOUCHPAD_HID.tip_switch)
				return true
		}
		return false
	}
}
