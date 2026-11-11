; modules/keystats/keystats_maintenance.ahk

; ==============================================================================
; MODULE: Dashboard Export and Purge (Windows)
; DESCRIPTION:
; The writer side of the typing dashboard's Export and Purge. The KL_* journal
; owner is the single metrics writer: a request first drains the typing buffer
; and reads today.log to its end, so its flush has settled, then acts.
;
; FEATURES & RATIONALE:
; 1. A Purge appends a dated tombstone (events_system, action 'metrics_purge')
;    through the journal like any other row, so it reaches data.sql, the
;    append-only ledger every device replays. _shared/data/db/purge_schema.sql
;    applies it in SQLite while any ledger replays, so a sibling device never
;    brings a purged row back (maintainer decision 2026-11-06). The receipt is
;    the tombstone read back from the replayed reader image.
; 2. Rows store their instant in UTC with the offset they were recorded at
;    (maintainer decision KMD-1): the tombstone row does too, through the
;    events_system builder, and carries the same UTC instant, milliseconds
;    included, under metadata utc, which purge_schema.sql compares rows with.
; 3. An Export is a VACUUM INTO copy of the reader image (query
;    export.vacuum_into) into the user's Downloads folder, taken after the
;    flush settles. Names and the tombstone match the macOS and Linux helper
;    (_shared/lua/keystats/metrics_maintenance.lua) and the shared vectors.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include keystats_local_time.ahk





; =============================
; =============================
; ======= 1/ Constants ========
; =============================
; =============================

class KLMaintenance {
	static TOMBSTONE_ACTION := "metrics_purge"
	static EXPORT_PREFIX := "ergopti-metrics-"
	static EXPORT_EXTENSION := ".sqlite"
	; True while one Export or Purge owns the writer.
	static active := false
}





; ===========================
; ===========================
; ======= 2/ Helpers ========
; ===========================
; ===========================

; Names the Export copy taken at one local instant.
; @param Stamp {String} A YYYYMMDDHH24MISS local time.
; @returns {String} The file name.
KL_MetricsExportName(Stamp) {
	return KLMaintenance.EXPORT_PREFIX . FormatTime(Stamp, "yyyy-MM-dd_HH-mm-ss") . KLMaintenance.EXPORT_EXTENSION
}

; Builds the tombstone journal entry of a purge taken now.
; @param LocalTs {String} The local "YYYY-MM-DD HH:MM:SS.mmm" journal timestamp.
; @returns {Map} A system_event entry for KL_AppendLog; its utc is the UTC
;   instant of LocalTs, milliseconds kept, the ts its events_system row stores.
KL_MetricsTombstone(LocalTs) {
	return Map("type", "system_event", "action", KLMaintenance.TOMBSTONE_ACTION, "timestamp", LocalTs,
		"utc", KL_TimestampFromLocal(LocalTs)["ts"])
}

; Drains the typing buffer and reads today.log to its end.
; @returns {Boolean} True once the writer has settled.
KL_SettleMetricsWriter() {
	KL_FlushBuffer()
	loop KeystatsConst.MAINTENANCE_INGEST_PASSES {
		Result := KL_IngestOnce(true)
		if !Result["ok"] {
			LoggerError("Keystats", "Metrics writer did not settle: {1}.", Result.Get("reason", "unknown"))
			return false
		}
		if Result["eof"]
			return true
	}
	LoggerError("Keystats", "Metrics writer still had journal rows after {1} ingest passes.",
		KeystatsConst.MAINTENANCE_INGEST_PASSES)
	return false
}





; ===================================
; ===================================
; ======= 3/ Writer Request =========
; ===================================
; ===================================

; Runs one dashboard Export or Purge through the single owning writer.
; @param Kind {String} "export" or "purge".
; @param MetricsDir {String} The metrics folder the reader replays.
; @returns {Map} ok {Boolean} and path {String} (the Export copy, else "").
KL_RunMetricsMaintenance(Kind, MetricsDir) {
	Refused := Map("ok", false, "path", "")
	if (Kind != "export" && Kind != "purge") || KLMaintenance.active
		return Refused
	KLMaintenance.active := true
	LoggerStart("Keystats", "Metrics {1} requested; waiting for the writer to settle.", Kind)
	HadImage := KLRCache.db != 0
	db := 0
	try {
		Tombstone := 0
		if (Kind = "purge") {
			Tombstone := KL_MetricsTombstone(KL_NowTimestamp())
			if !KL_AppendLog(Tombstone)
				throw Error("the journal refused the tombstone")
		}
		if !KL_SettleMetricsWriter()
			throw Error("the writer did not settle")
		db := KLR_BuildDatabase(MetricsDir)
		if !db
			throw Error("the reader image could not be built")
		Path := ""
		if (Kind = "purge") {
			Rows := SQLite_Query(db, "SELECT count(*) AS n FROM events_system WHERE action="
				. SQLite_Q(KLMaintenance.TOMBSTONE_ACTION) . " AND ts=" . SQLite_Q(Tombstone["utc"]) . ";")
			if (Rows.Length != 1 || Rows[1]["n"] < 1)
				throw Error("the tombstone is not in the replayed ledger")
		} else {
			Folder := EnvGet("USERPROFILE")
			if (Folder = "" || !DirExist(Folder . "\Downloads"))
				throw Error("the Downloads folder does not exist")
			Path := Folder . "\Downloads\" . KL_MetricsExportName(A_Now)
			if !SQLite_Exec(db, KeystatsQuery("export.vacuum_into", Map("path", Path)))
				throw Error("VACUUM INTO refused the copy")
		}
		LoggerSuccess("Keystats", "Metrics {1} done.", Kind)
		return Map("ok", true, "path", Path)
	} catch as err {
		LoggerError("Keystats", "Metrics {1} refused; the store is unchanged: {2}.", Kind, err.Message)
		return Refused
	} finally {
		; The resident process keeps no image it did not already own.
		if db && !HadImage
			KLR_ResetCache()
		KLMaintenance.active := false
	}
}
