; modules/keylogger/keylogger_prefetch_seed.ahk

; ==============================================================================
; MODULE: Metrics History Seed Provenance
; DESCRIPTION: Admit deltas only when consumed ledger changes preserve seeded history.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLPF_HistorySeedDayValid(Day) {
	if !(Day is String) || !RegExMatch(Day, "^\d{4}-\d{2}-\d{2}$")
		return false
	try {
		DateAdd(StrReplace(Day, "-"), 0, "Days")
		return true
	} catch ValueError {
		return false
	}
}

_KLPF_HistorySeedValid(Seed) {
	if !(Seed is Map)
		return false
	Version := Seed.Get("version", 0)
	Store := Seed.Get("store", 0)
	Ledgers := Seed.Get("ledgers", 0)
	if !(Version is Integer) || Version != 1 || !(Store is String)
			|| !(Ledgers is Map) || !_KLPF_HistorySeedDayValid(Seed.Get("day", 0))
		return false
	Normalized := ConfigTransitionNormalizeConfigDir(Store)
	if !(Normalized is String) || !(Normalized == Store)
		return false
	Prefix := Store . "by_device\"
	for LedgerPath, Receipt in Ledgers {
		if !(LedgerPath is String) || !(Receipt is Map)
			return false
		Path := StrReplace(LedgerPath, "/", "\")
		if !(SubStr(Path, 1, StrLen(Prefix)) == Prefix)
				|| !RegExMatch(SubStr(Path, StrLen(Prefix) + 1), "^(?!\.{1,2}\\)[^\\]+\\data\.sql$")
			return false
		Offset := Receipt.Get("offset", -1)
		Snapshot := Receipt.Get("snapshot", 0)
		if !(Offset is Integer) || Offset < 0 || !(Snapshot is Map)
				|| Snapshot.Get("ok", false) != true
			return false
		for Field in ["volume", "index_high", "index_low", "size", "write_high", "write_low"] {
			Value := Snapshot.Get(Field, -1)
			if !(Value is Integer) || Value < 0
				return false
		}
		if Snapshot["size"] < Offset
			return false
	}
	return true
}

/**
 * Captures the exact consumed ledger tuple without reopening source paths.
 * @param metrics_dir Absolute metrics store directory.
 * @param SnapshotDay Calendar boundary used by the associated full projection.
 * @returns {Map} Versioned, independently owned history checkpoint.
 */
KLPF_CaptureHistorySeed(metrics_dir, SnapshotDay) {
	Store := ConfigTransitionNormalizeConfigDir(metrics_dir)
	if !KLRCache.db || !(Store is String) || !_KLPF_HistorySeedDayValid(SnapshotDay)
		throw ValueError("History seed requires a live projection, absolute store and valid day.")
	if KLRCache.last_sizes.Count != KLRCache.ledger_snapshots.Count
		throw Error("History seed offsets and consumed identities disagree.")
	Ledgers := Map()
	for LedgerPath, Offset in KLRCache.last_sizes {
		Snapshot := KLRCache.ledger_snapshots.Get(LedgerPath, 0)
		if !(Snapshot is Map)
			throw Error("History seed is missing a consumed ledger identity.")
		Ledgers[LedgerPath] := Map("offset", Offset, "snapshot", Snapshot.Clone())
	}
	Seed := Map("version", 1, "store", Store, "day", SnapshotDay, "ledgers", Ledgers)
	if !_KLPF_HistorySeedValid(Seed)
		throw Error("History seed contains invalid consumed ledger metadata.")
	return Seed
}

/**
 * Determines whether a delivered history checkpoint can accept today's delta.
 * @param Seed Last successfully delivered full or admitted delta checkpoint.
 * @param Current Consumed tuple of the newly built projection.
 * @returns {Boolean} False requests a full snapshot; neither receipt is mutated.
 */
KLPF_HistorySeedAllowsDelta(Seed, Current) {
	if !_KLPF_HistorySeedValid(Seed) || !_KLPF_HistorySeedValid(Current)
		return false
	if !(Seed["store"] == Current["store"]) || !(Seed["day"] == Current["day"])
			|| Seed["ledgers"].Count != Current["ledgers"].Count
		return false
	for LedgerPath, Before in Seed["ledgers"] {
		After := Current["ledgers"].Get(LedgerPath, 0)
		if !(After is Map) || !KLR_LedgerFileIsSame(Before["snapshot"], After["snapshot"])
				|| After["offset"] < Before["offset"]
			return false
		if After["offset"] = Before["offset"] {
			; Equal byte boundaries do not prove that seeded historical rows survived
			; a same-file rewrite. Match the consumed modification receipt as well.
			if !KLR_LedgerSnapshotIsSame(Before["snapshot"], After["snapshot"])
				return false
			continue
		}
		Tail := KLR_ReadLedgerTail(LedgerPath, Before["offset"])
		if !Tail.Get("ok", false) || Tail.Get("end_offset", -1) != After["offset"]
				|| !KLR_LedgerSnapshotIsSame(Tail.Get("snapshot", 0), After["snapshot"])
			return false
		; Empty or unclassified SQL must not certify that historical rows survived.
		Dates := KLR_CacheAffectedDates(Map(LedgerPath, Tail))
		if Dates.Length = 0
			return false
		for Day in Dates {
			if !(Day == Current["day"])
				return false
		}
	}
	return true
}
