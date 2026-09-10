; modules/keylogger/keylogger_reader_manifest_json.ahk

; ==============================================================================
; MODULE: Encoded Metrics Manifest
; DESCRIPTION: Keep time-series scalars encoded while preserving histogram merges.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Builds a complete manifest without re-encoding every time-series scalar.
 * @param db Open projection database, or zero for an empty manifest.
 * @param start_date Inclusive lower date bound, or an empty string.
 * @param end_date Inclusive upper date bound, or an empty string.
 * @param Index Receives date/application membership only, never partial metrics.
 * @returns {String} Complete manifest JSON; the ordinary Map cache is untouched.
 */
KLR_BuildManifestJson(db, start_date := "", end_date := "", &Index := unset) {
		Index := Map()
		if !db
				return "{}"
		Manifest := KLR_ReadManifestBase(db, start_date, end_date)
		Where := KLR_DateFilter(start_date, end_date)
		Hourly := KLR_EncodedTimeSeries(db, false, Where)
		Min5 := KLR_EncodedTimeSeries(db, true, Where)
		for Series in [Hourly, Min5]
				for Day, Apps in Series
						for App in Apps
								KLR_GetCell(Manifest, Day, App)
		KLR_AddLiveForegroundTime(Manifest, start_date, end_date)
		Output := "{"
		for Day, Apps in Manifest {
				Index[Day] := Map()
				Output .= (StrLen(Output) > 1 ? "," : "") . KL_JsonEncode(Day) . ":{"
				First := true
				for App, Cell in Apps {
						Index[Day][App] := true
						if App == "_system" {
								Output .= (First ? "" : ",") . KL_JsonEncode(App) . ":" . KL_JsonEncode(Cell)
								First := false
								continue
						}
						; These cells are owned locally, never borrowed from the Map cache.
						Cell.Delete("hourly")
						Cell.Delete("hourly_min5")
						Raw := KL_JsonEncode(Cell)
						HourJson := Hourly.Has(Day) ? Hourly[Day].Get(App, "{}") : "{}"
						MinJson := Min5.Has(Day) ? Min5[Day].Get(App, "{}") : "{}"
						Output .= (First ? "" : ",") . KL_JsonEncode(App) . ":"
								. SubStr(Raw, 1, StrLen(Raw) - 1) . ',"hourly":' . HourJson
								. ',"hourly_min5":' . MinJson . "}"
						First := false
				}
				Output .= "}"
		}
		return Output . "}"
}

KLR_EncodedTimeSeries(db, FiveMinute, Where, NormalizeHistogram := unset) {
		if !IsSet(NormalizeHistogram)
				NormalizeHistogram := KLR_MergeJsonNumberMap
		Key := FiveMinute ? "slot" : "hour"
		Field := FiveMinute ? "hourly_min5" : "hourly"
		Table := "agg_app_day_" . Field
		Label := FiveMinute ? "five-minute error buckets" : "hourly error buckets"
		Errors := Map()
		; Repeated bins often carry identical histograms. Retain successful unit
		; normalization only for this call; each destination owns its scaled counts.
		DecodedCache := Map()
		Sql := "SELECT date,app," . Key . " AS bin,e_buckets_json,COUNT(*) AS source_rows FROM " . Table
				. Where . (Where = "" ? " WHERE " : " AND ")
				. "e_buckets_json IS NOT NULL AND e_buckets_json != '' AND e_buckets_json != '{}'"
				. " GROUP BY date,app," . Key . ",e_buckets_json"
		for Row in SQLite_Query(db, Sql) {
				Day := Row["date"]
				App := Row["app"]
				if !Errors.Has(Day)
						Errors[Day] := Map()
				if !Errors[Day].Has(App)
						Errors[Day][App] := Map()
				Bins := Errors[Day][App]
				if !Bins.Has(Row["bin"])
						Bins[Row["bin"]] := Map()
				RawHistogram := Row["e_buckets_json"]
				if !DecodedCache.Has(RawHistogram) {
						Normalized := Map()
						; Rejected rows must keep their per-row diagnostic path.
						if !NormalizeHistogram.Call(Normalized, RawHistogram, Label)
								continue
						DecodedCache[RawHistogram] := Normalized
				}
				for Bucket, Count in DecodedCache[RawHistogram]
						KLR_BumpMap(Bins[Row["bin"]], Bucket, Count * Row["source_rows"])
		}
		; SUM yields SQLite numbers or NULL; only NULL needs normalization here.
		; Histogram coercion remains with the established AHK merge above.
		Sql := "SELECT date,app," . Key . " AS bin,json_object('c',COALESCE(SUM(c),0),"
				. "'e',COALESCE(SUM(e),0),'es',COALESCE(SUM(es),0)"
				. (FiveMinute ? "" : ",'em',COALESCE(SUM(em),0)") . ") AS payload FROM " . Table
				. Where . " GROUP BY date,app," . Key
		Output := Map()
		for Row in SQLite_Query(db, Sql) {
				Day := Row["date"]
				App := Row["app"]
				if !Output.Has(Day)
						Output[Day] := Map()
				Existing := Output[Day].Get(App, "")
				Histogram := Errors.Has(Day) && Errors[Day].Has(App)
						? Errors[Day][App].Get(Row["bin"], 0) : 0
				Raw := Row["payload"]
				Raw := SubStr(Raw, 1, StrLen(Raw) - 1) . ',"e_buckets":'
						. (Histogram is Map ? KL_JsonEncode(Histogram) : "{}") . "}"
				Output[Day][App] := Existing . (Existing != "" ? "," : "")
						. KL_JsonEncode(String(Row["bin"])) . ":" . Raw
		}
		for Day, Apps in Output
				for App, Raw in Apps
						Apps[App] := "{" . Raw . "}"
		return Output
}
