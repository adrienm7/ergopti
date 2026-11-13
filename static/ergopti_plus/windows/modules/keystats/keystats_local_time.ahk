; modules/keystats/keystats_local_time.ahk

; ==============================================================================
; MODULE: Metrics Row Time - UTC Instant and Recorded Offset (Windows)
; DESCRIPTION:
; A raw metrics row stores its instant in UTC (`ts`) and the local UTC offset in
; force when it was recorded (`utc_offset_min`), on every OS (maintainer
; decision KMD-1 of 11 November 2026). This is the Windows port of
; _shared/metrics/engine/local_time.lua: the writer converts the journal's local
; stamp into that pair, and the walker reads a row in the local time the user
; lived, ts plus its offset.
;
; FEATURES & RATIONALE:
; 1. The conversion asks Windows for the active zone's rules of the stamp's own
;    year (the dynamic time zone), so a row ingested after a daylight-saving
;    change keeps the offset of the instant it was recorded at. In the repeated
;    hour of a fall-back the local reading is ambiguous and the system's choice
;    is kept, as macOS keeps os.time()'s.
; 2. A timestamp keeps its fractional seconds as written, so a converted value
;    sorts and compares like the original.
; 3. A row recorded before the column existed has no offset: a Linux row then
;    held UTC and is read with the reading device's current offset, a macOS or
;    Windows row held local time already.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\adapters\system_time_zone.ahk





; ===========================
; ===========================
; ======= 1/ Calendar =======
; ===========================
; ===========================

; Splits a "YYYY-MM-DD HH:MM:SS[.fff]" metrics timestamp.
; @param Ts {String} The timestamp.
; @returns {Map|Integer} year, month, day, hour, min, sec (Integers) and fraction
;   (the text after the seconds), or 0 when Ts is no metrics timestamp.
KL_TimestampFields(Ts) {
	if !(Ts is String) || !RegExMatch(Ts, "^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(.*)$", &Found)
		return 0
	return Map("year", Integer(Found[1]), "month", Integer(Found[2]), "day", Integer(Found[3]),
		"hour", Integer(Found[4]), "min", Integer(Found[5]), "sec", Integer(Found[6]), "fraction", Found[7])
}

; The YYYYMMDDHH24MISS stamp of split timestamp fields.
_KL_FieldsStamp(Fields) {
	return Format("{:04d}{:02d}{:02d}{:02d}{:02d}{:02d}", Fields["year"], Fields["month"], Fields["day"],
		Fields["hour"], Fields["min"], Fields["sec"])
}

; Formats a YYYYMMDDHH24MISS stamp as a metrics timestamp ending in Fraction.
_KL_StampTimestamp(Stamp, Fraction) {
	return FormatTime(Stamp, "yyyy-MM-dd HH:mm:ss") . Fraction
}

; A SYSTEMTIME (16 bytes, eight WORDs) holding a YYYYMMDDHH24MISS stamp.
_KL_StampSystemTime(Stamp) {
	Time := Buffer(16, 0)
	NumPut("UShort", Integer(SubStr(Stamp, 1, 4)), "UShort", Integer(SubStr(Stamp, 5, 2)), "UShort", 0,
		"UShort", Integer(SubStr(Stamp, 7, 2)), "UShort", Integer(SubStr(Stamp, 9, 2)),
		"UShort", Integer(SubStr(Stamp, 11, 2)), "UShort", Integer(SubStr(Stamp, 13, 2)), "UShort", 0, Time)
	return Time
}

; The YYYYMMDDHH24MISS stamp a SYSTEMTIME holds.
_KL_SystemTimeStamp(Time) {
	return Format("{:04d}{:02d}{:02d}{:02d}{:02d}{:02d}", NumGet(Time, 0, "UShort"), NumGet(Time, 2, "UShort"),
		NumGet(Time, 6, "UShort"), NumGet(Time, 8, "UShort"), NumGet(Time, 10, "UShort"), NumGet(Time, 12, "UShort"))
}





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

; The local UTC offset, in minutes east of UTC, in force at a UTC instant here.
; @param UtcStamp {String} The instant as a YYYYMMDDHH24MISS UTC time.
; @returns {Integer} The offset.
KL_UtcOffsetAt(UtcStamp) {
	LocalTime := NativeZoneLocalFromUtc(NativeDynamicTimeZone(), _KL_StampSystemTime(UtcStamp), UtcStamp)
	return DateDiff(_KL_SystemTimeStamp(LocalTime), UtcStamp, "Minutes")
}

; The offset in force now, the one an older Linux row is read with.
; @returns {Integer} Minutes east of UTC.
KL_CurrentUtcOffset() {
	return KL_UtcOffsetAt(A_NowUTC)
}

; A local timestamp as its UTC instant and the offset in force then: what the
; writer stores for a journal entry, which is stamped in local time.
; @param LocalTs {String} Local "YYYY-MM-DD HH:MM:SS[.fff]".
; @returns {Map} ts (UTC, same fraction) and utc_offset_min (Integer).
KL_TimestampFromLocal(LocalTs) {
	Fields := KL_TimestampFields(LocalTs)
	if !Fields
		throw ValueError("not a metrics timestamp: " . String(LocalTs))
	LocalStamp := _KL_FieldsStamp(Fields)
	Utc := NativeZoneUtcFromLocal(NativeDynamicTimeZone(), _KL_StampSystemTime(LocalStamp), LocalTs)
	UtcStamp := _KL_SystemTimeStamp(Utc)
	return Map("ts", _KL_StampTimestamp(UtcStamp, Fields["fraction"]),
		"utc_offset_min", DateDiff(LocalStamp, UtcStamp, "Minutes"))
}

; A timestamp moved by whole minutes, its fraction kept.
; @param Ts {String} "YYYY-MM-DD HH:MM:SS[.fff]".
; @param Minutes {Integer} The shift.
; @returns {String} The shifted timestamp, "" when Ts is no metrics timestamp.
KL_TimestampShift(Ts, Minutes) {
	Fields := KL_TimestampFields(Ts)
	if !Fields
		return ""
	return _KL_StampTimestamp(DateAdd(_KL_FieldsStamp(Fields), Minutes, "Minutes"), Fields["fraction"])
}

; The local time a row's user lived: its UTC `ts` plus its recorded offset. A
; row without one keeps its legacy reading: a Linux row held UTC and takes
; LegacyOffset (the reading device's current offset), any other held local time.
; Mirrors local_time.local_ts.
; @param Ts {String} The row's ts.
; @param Offset {Integer|String} The row's utc_offset_min, "" for NULL.
; @param LegacyUtc {Boolean} Whether an offset-less row of its device held UTC.
; @param LegacyOffset {Integer|String} The offset such a row is read with.
; @returns {String} The local timestamp, "" when Ts is no timestamp.
KL_RowLocalTimestamp(Ts, Offset, LegacyUtc := false, LegacyOffset := "") {
	if !KL_TimestampFields(Ts)
		return ""
	if (Offset = "") {
		if !LegacyUtc
			return Ts
		Offset := LegacyOffset
	}
	if !IsInteger(Offset)
		throw TypeError("a row's offset must be whole minutes, got " . String(Offset))
	return KL_TimestampShift(Ts, Integer(Offset))
}
