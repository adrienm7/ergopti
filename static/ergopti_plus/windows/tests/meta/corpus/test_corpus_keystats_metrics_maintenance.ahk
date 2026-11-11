; tests/meta/corpus/test_corpus_keystats_metrics_maintenance.ahk

; ==============================================================================
; MODULE: Dashboard Export and Purge Corpus Consumer (Windows)
; DESCRIPTION:
; Replays keystats/metrics_maintenance_vectors.json, which the Linux suite
; replays through the shared Lua helper, through the Windows owners: the
; tombstone and the Export name of modules/keystats/keystats_maintenance.ahk,
; the events_system row builder, and the reader's schema loader, which installs
; _shared/data/db/purge_schema.sql.
;
; FEATURES & RATIONALE:
; 1. The three devices' ledgers replay in each of their six orders into a store
;    built by KLR_LoadSchema, the rows written by KL_BuildInsertSystem under the
;    device that owns them: whichever order a sync delivers them in, a purged row
;    never comes back and a later row survives.
; 2. The Windows tombstone takes its local timestamp from the journal clock
;    rather than from an epoch, so the vector's millis are checked on the shape
;    of KL_NowTimestamp, and its UTC instant on the vector's epoch.
; ==============================================================================

#Requires AutoHotkey v2.0

_CTMM_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\keystats\metrics_maintenance_vectors.json", "UTF-8"))
}

; The vector's epoch as the YYYYMMDDHH24MISS UTC stamp the tombstone takes.
_CTMM_UtcStamp(Epoch) {
	return DateAdd("19700101000000", Floor(Epoch), "Seconds")
}

_CTMM_Tombstone() {
	Corpus := _CTMM_Corpus()
	Vector := Corpus["tombstone"]
	LocalTs := KL_NowTimestamp()
	AssertTrue(RegExMatch(LocalTs, Vector["ts_pattern"]) > 0, "the journal clock stamps " . LocalTs)
	Millis := SubStr(LocalTs, -StrLen(Vector["millis"]))
	AssertTrue(RegExMatch(Millis, "^\.\d{3}$") > 0, "the millisecond suffix " . Millis . " has the shape of " . Vector["millis"])
	Entry := KL_MetricsTombstone(LocalTs, _CTMM_UtcStamp(Vector["epoch"]))
	AssertEqual("system_event", Entry["type"])
	AssertEqual(Vector["action"], Entry["action"])
	AssertEqual(Vector["utc"], Entry["utc"])
	Db := _WJFM_OpenMemory()
	SavedDevice := Keystats.device_id
	try {
		AssertTrue(KLR_LoadSchema(Db), "the reader schema loads")
		Keystats.device_id := "pc-device"
		AssertTrue(SQLite_Exec(Db, KL_BuildInsertSystem(Entry, 1)), "the tombstone row is written")
		Rows := SQLite_Query(Db, "SELECT action, date, ts, json_extract(metadata_json, '$.utc') AS utc FROM events_system WHERE id = 1;")
		AssertEqual(1, Rows.Length, "the tombstone row lands")
		AssertEqual(Vector["action"], Rows[1]["action"])
		AssertEqual(Vector["utc"], Rows[1]["utc"], "the row carries the UTC instant Linux rows are compared with")
		AssertEqual(LocalTs, Rows[1]["ts"])
		AssertTrue(RegExMatch(Rows[1]["date"], Vector["date_pattern"]) > 0, "the row's date " . Rows[1]["date"])
		AssertEqual(SubStr(LocalTs, 1, 10), Rows[1]["date"])
	} finally {
		Keystats.device_id := SavedDevice
		SQLite_Close(Db)
	}
}
Test("corpus: a purge writes the shared tombstone (corpus-metrics-maintenance)", _CTMM_Tombstone)

_CTMM_ExportName() {
	Export := _CTMM_Corpus()["export"]
	Name := KL_MetricsExportName(_CTMM_UtcStamp(_CTMM_Corpus()["tombstone"]["epoch"]))
	AssertEqual(Export["prefix"], SubStr(Name, 1, StrLen(Export["prefix"])))
	AssertEqual(Export["extension"], SubStr(Name, -StrLen(Export["extension"])))
	AssertTrue(RegExMatch(Name, Export["name_pattern"]) > 0, "the Export name " . Name)
	AssertEqual("VACUUM INTO 'x';", KeystatsQuery(Export["query"], Map("path", "x")), "the Export query")
}
Test("corpus: an Export is named as the shared vectors say (corpus-metrics-maintenance)", _CTMM_ExportName)

; Every order of Items, each order an Array.
_CTMM_Permutations(Items) {
	if Items.Length <= 1
		return [Items]
	Out := []
	for Index, Item in Items {
		Rest := []
		for Other, Value in Items
			if Other != Index
				Rest.Push(Value)
		for Tail in _CTMM_Permutations(Rest) {
			Order := [Item]
			Order.Push(Tail*)
			Out.Push(Order)
		}
	}
	return Out
}

; Replays the vector ledgers in one device order; returns the surviving rows.
_CTMM_Replay(Replay, Order) {
	Db := _WJFM_OpenMemory()
	SavedDevice := Keystats.device_id
	try {
		AssertTrue(KLR_LoadSchema(Db), "the reader schema loads")
		for Device in Replay["devices"]
			AssertTrue(SQLite_Exec(Db, KeystatsQuery("devices.upsert", Map("device_id", Device["device_id"],
				"name", Device["device_id"], "os", Device["os"], "os_version", "", "host_signature", "",
				"created_at", "", "updated_at", ""))), Device["device_id"])
		for Row in Replay["derived"]
			AssertTrue(SQLite_Exec(Db, "INSERT INTO " . Row["table"] . " (device_id, date) VALUES ("
				. SQLite_Q(Row["device_id"]) . ", " . SQLite_Q(Row["date"]) . ");"))
		for DeviceId in Order {
			Keystats.device_id := DeviceId
			for Row in Replay["ledgers"][DeviceId] {
				AssertEqual("events_system", Row["table"], "the vectors replay system rows only")
				Entry := Map("type", "system_event", "action", Row["action"], "timestamp", Row["ts"])
				if Row.Has("metadata_json")
					for Key, Value in JsonParse(Row["metadata_json"])
						Entry[Key] := Value
				AssertEqual(Row["date"], SubStr(Row["ts"], 1, 10), "the builder dates a row by its timestamp")
				AssertTrue(SQLite_Exec(Db, KL_BuildInsertSystem(Entry, Row["id"])), DeviceId . ":" . Row["id"])
			}
		}
		Raw := []
		for Row in SQLite_Query(Db, "SELECT device_id, id, action FROM events_system ORDER BY device_id, id;")
			Raw.Push(Row["device_id"] . ":" . Row["id"] . ":" . Row["action"])
		Derived := []
		for Row in SQLite_Query(Db, "SELECT device_id, date FROM agg_system_day ORDER BY device_id, date;")
			Derived.Push(Row["device_id"] . ":" . Row["date"])
		return Map("raw", Raw, "derived", Derived)
	} finally {
		Keystats.device_id := SavedDevice
		SQLite_Close(Db)
	}
}

_CTMM_AssertList(Expected, Actual, Label) {
	Joined(List) {
		Out := ""
		for Item in List
			Out .= (A_Index > 1 ? ", " : "") . Item
		return Out
	}
	AssertEqual(Joined(Expected), Joined(Actual), Label)
}

_CTMM_PurgeReplay() {
	Replay := _CTMM_Corpus()["replay"]
	Devices := []
	for Device in Replay["devices"]
		Devices.Push(Device["device_id"])
	Orders := _CTMM_Permutations(Devices)
	AssertEqual(6, Orders.Length, "the three ledgers replay in six orders")
	for Order in Orders {
		Label := ""
		for DeviceId in Order
			Label .= (A_Index > 1 ? " > " : "") . DeviceId
		Result := _CTMM_Replay(Replay, Order)
		_CTMM_AssertList(Replay["surviving"], Result["raw"], "raw rows, order " . Label)
		_CTMM_AssertList(Replay["surviving_derived"], Result["derived"], "derived rows, order " . Label)
	}
}
Test("corpus: a replayed purge keeps exactly the later rows in every order (corpus-metrics-maintenance)",
	_CTMM_PurgeReplay)
