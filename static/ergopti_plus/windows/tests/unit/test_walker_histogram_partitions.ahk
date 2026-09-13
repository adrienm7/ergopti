; tests/unit/test_walker_histogram_partitions.ahk

; ==============================================================================
; MODULE: Walker Histogram Partition Tests
; DESCRIPTION:
; Interleaved flushes conserve each distribution inside its SQLite primary key.
; ==============================================================================

#Requires AutoHotkey v2.0

_WHP_IsolatedFlushes(Kind) {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	Expected := Map()
	Table := Kind == "bursts" ? "agg_app_day_burst"
		: Kind == "hourly" ? "agg_app_day_hourly" : "agg_app_day_hourly_min5"
	Column := Kind == "bursts" ? "length_buckets_json" : "e_buckets_json"
	Counter := Kind == "bursts" ? "count_total" : "e"
	SlotColumn := Kind == "hourly" ? "hour" : "slot"
	SlotSelect := Kind == "bursts" ? "'' AS slot_key" : SlotColumn . " AS slot_key"
	try {
		AssertTrue(KLR_LoadSchema(Db))
		loop 3 {
			BatchIndex := A_Index
			loop 2 {
				DeviceIndex := A_Index
				Device := "partition-device-" . DeviceIndex
				KLW_ResetBatch()
				for DayIndex, Day in ["2026-09-12", "2026-09-13"] {
					for AppIndex, App in ["first.exe", "second'quoted.exe"] {
						Slots := Kind == "bursts" ? [""]
							: Kind == "hourly" ? ["10", "11"] : ["10:00", "10:05"]
						for SlotIndex, Slot in Slots {
							Key := KL_JsonEncode([Device, Day, App, Slot])
							if !Expected.Has(Key)
								Expected[Key] := Map()
							; Distinct weights expose accidental cross-partition attribution.
							Weight := DeviceIndex * 1000 + DayIndex * 100 + AppIndex * 10 + SlotIndex
							Buckets := BatchIndex == 3 ? Map()
								: Map("100", Weight, String(200 + BatchIndex), BatchIndex)
							Total := 0
							for Bucket, Value in Buckets {
								Expected[Key][Bucket] := Expected[Key].Get(Bucket, 0) + Value
								Total += Value
							}
							Row := Map("date", Day, "app", App)
							if Kind == "bursts" {
								for Field in ["max_cpm", "max_chars", "inter_count", "inter_sum", "inter_sumsq"]
									Row[Field] := 0
								Row["count_total"] := Total
								Row["length_buckets"] := Buckets
							} else {
								Row[SlotColumn] := Slot
								Row["e"] := Total
								Row["em"] := 0
								Row["es"] := 0
								Row["e_buckets"] := Buckets
							}
							KLW.batch[Kind][Key] := Row
						}
					}
				}
				_WJFM_Flush(Db, Device)
				Rows := SQLite_Query(Db, "SELECT device_id,date,app," . SlotSelect
					. "," . Counter . " AS total," . Column . " AS payload FROM " . Table . ";")
				AssertEqual(Expected.Count, Rows.Length)
				for Row in Rows {
					Key := KL_JsonEncode([Row["device_id"], Row["date"], Row["app"], String(Row["slot_key"])])
					AssertTrue(Expected.Has(Key), "stored histogram identity must match a seeded partition")
					Actual := KL_JsonDecode(Row["payload"])
					AssertTrue(Actual is Map)
					AssertEqual(Expected[Key].Count, Actual.Count)
					Total := 0
					for Bucket, Value in Expected[Key] {
						AssertTrue(Actual.Has(Bucket), "earlier and disjoint buckets must survive")
						AssertEqual(Value, Actual[Bucket], "histogram counts must stay inside the complete primary key")
						Total += Value
					}
					AssertEqual(Total, Row["total"], "counter and distribution must conserve the same partition mass")
				}
			}
		}
		AssertEqual(Kind == "bursts" ? 8 : 16, Expected.Count)
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}

for Kind in ["hourly", "hourly_min5", "bursts"]
	Test("walker: " . Kind . " histogram flushes isolate complete identities (walker-histogram-partitions)",
		_WHP_IsolatedFlushes.Bind(Kind))
