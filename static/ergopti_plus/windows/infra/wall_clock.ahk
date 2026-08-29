; infra/wall_clock.ahk

; ==============================================================================
; MODULE: Wall-Clock Snapshot
; DESCRIPTION:
; Formats local timestamps with millisecond precision from one SYSTEMTIME
; snapshot. Reading A_Now and A_MSec separately can combine two different
; seconds when a callback is descheduled at a clock boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Returns the current local wall clock as YYYY-MM-DD HH:mm:ss<separator>mmm.
 * The optional capture port is a deterministic test seam returning the seven
 * lowercase SYSTEMTIME fields in a Map.
 * @param {String} MillisecondSeparator Separator before the millisecond field.
 * @param {Callable|Integer} CaptureFn Optional atomic clock capture port.
 * @returns {String} One coherent local timestamp.
 */
WallClockTimestamp(MillisecondSeparator := ":", CaptureFn := 0) {
	static TimeBuffer := Buffer(16, 0)
	static CachedSecondKey := -1
	static CachedSecondText := ""
	if !(MillisecondSeparator is String)
		throw TypeError("Millisecond separator must be a string.")
	Injected := HasMethod(CaptureFn, "Call")
	Sample := 0
	if Injected {
		Sample := CaptureFn.Call()
		if !(Sample is Map)
			throw TypeError("Wall-clock capture must return a Map.")
	}
	PreviousCritical := Critical("On")
	try {
		if Injected {
			for Field in ["year", "month", "day", "hour", "minute", "second",
					"millisecond"] {
				if !Sample.Has(Field) || !(Sample[Field] is Integer)
					throw TypeError("Wall-clock capture field must be an integer.",
						-1, Field)
			}
			Year := Sample["year"]
			Month := Sample["month"]
			Day := Sample["day"]
			Hour := Sample["hour"]
			Minute := Sample["minute"]
			Second := Sample["second"]
			Millisecond := Sample["millisecond"]
		} else {
			DllCall("Kernel32\GetLocalTime", "Ptr", TimeBuffer.Ptr)
			Year := NumGet(TimeBuffer, 0, "UShort")
			Month := NumGet(TimeBuffer, 2, "UShort")
			Day := NumGet(TimeBuffer, 6, "UShort")
			Hour := NumGet(TimeBuffer, 8, "UShort")
			Minute := NumGet(TimeBuffer, 10, "UShort")
			Second := NumGet(TimeBuffer, 12, "UShort")
			Millisecond := NumGet(TimeBuffer, 14, "UShort")
		}
		if (Year < 1601 || Year > 9999 || Month < 1 || Month > 12
				|| Day < 1 || Day > 31 || Hour < 0 || Hour > 23
				|| Minute < 0 || Minute > 59 || Second < 0 || Second > 59
				|| Millisecond < 0 || Millisecond > 999)
			throw ValueError("Wall-clock capture contains an out-of-range field.")
		SecondKey := Year * 10000000000 + Month * 100000000
			+ Day * 1000000 + Hour * 10000 + Minute * 100 + Second
		if (SecondKey != CachedSecondKey) {
			CachedSecondKey := SecondKey
			CachedSecondText := Format("{:04d}-{:02d}-{:02d} {:02d}:{:02d}:{:02d}",
				Year, Month, Day, Hour, Minute, Second)
		}
		return CachedSecondText . MillisecondSeparator
			. Format("{:03d}", Millisecond)
	} finally {
		Critical(PreviousCritical)
	}
}
