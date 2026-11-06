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
