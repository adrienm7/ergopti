; adapters/system_time_zone.ahk

; Windows active time-zone offset, independent of the wall clock's second.
#Requires AutoHotkey v2.0

; Returns signed minutes east of UTC, or "" when Windows cannot supply a bias.
NativeTimeZoneOffsetMinutesEast() {
	try {
		; TIME_ZONE_INFORMATION is 172 bytes on both Win32 and Win64:
		; Bias at 0, StandardBias at 84, DaylightBias at 168.
		Info := Buffer(172, 0)
		State := DllCall("Kernel32\GetTimeZoneInformation", "Ptr", Info, "UInt")
		if State == 0
			Adjustment := 0 ; TIME_ZONE_ID_UNKNOWN: no seasonal adjustment
		else if State == 1
			Adjustment := NumGet(Info, 84, "Int")
		else if State == 2
			Adjustment := NumGet(Info, 168, "Int")
		else
			return ""
		; Windows Bias is minutes UTC minus local, the opposite of ISO offsets.
		return -(NumGet(Info, 0, "Int") + Adjustment)
	} catch {
		return ""
	}
}

; The active dynamic time zone (DYNAMIC_TIME_ZONE_INFORMATION, 432 bytes), whose
; year-specific rules the conversions below apply.
; @returns {Buffer} The zone.
; @throws {OSError} When Windows cannot read the active zone.
NativeDynamicTimeZone() {
	Zone := Buffer(432, 0)
	if DllCall("Kernel32\GetDynamicTimeZoneInformation", "Ptr", Zone, "UInt") = 0xFFFFFFFF
		throw OSError(A_LastError, -1, "the active time zone is unreadable")
	return Zone
}

; A UTC SYSTEMTIME as the zone's local SYSTEMTIME, under that year's rules.
; @param Zone {Buffer} NativeDynamicTimeZone().
; @param UtcTime {Buffer} SYSTEMTIME (16 bytes).
; @param What {String} The instant, named in the error.
; @returns {Buffer} The local SYSTEMTIME.
; @throws {OSError} When Windows has no local time for the instant.
NativeZoneLocalFromUtc(Zone, UtcTime, What) {
	LocalTime := Buffer(16, 0)
	if !DllCall("Kernel32\SystemTimeToTzSpecificLocalTimeEx", "Ptr", Zone, "Ptr", UtcTime, "Ptr", LocalTime, "Int")
		throw OSError(A_LastError, -1, "the UTC instant " . What . " has no local time")
	return LocalTime
}

; A local SYSTEMTIME of the zone as its UTC SYSTEMTIME, under that year's rules.
; @param Zone {Buffer} NativeDynamicTimeZone().
; @param LocalTime {Buffer} SYSTEMTIME (16 bytes).
; @param What {String} The local timestamp, named in the error.
; @returns {Buffer} The UTC SYSTEMTIME.
; @throws {OSError} When Windows has no instant for the local time.
NativeZoneUtcFromLocal(Zone, LocalTime, What) {
	Utc := Buffer(16, 0)
	if !DllCall("Kernel32\TzSpecificLocalTimeToSystemTimeEx", "Ptr", Zone, "Ptr", LocalTime, "Ptr", Utc, "Int")
		throw OSError(A_LastError, -1, "the local timestamp " . What . " has no instant")
	return Utc
}
