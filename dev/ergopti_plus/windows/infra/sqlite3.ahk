; infra/sqlite3.ahk

; ==============================================================================
; MODULE: SQLite3 wrapper (winsqlite3.dll)
; DESCRIPTION:
; Minimal AHK v2 wrapper around the SQLite C API exposed by winsqlite3.dll
; (shipped with every Windows 10/11 install under System32). Used by the
; metrics dashboard pipeline to project data.sql into the JSON shape the
; HTML pages consume.
;
; FEATURES & RATIONALE:
; 1. Read-only OK / read-write OK / :memory: OK — a single SQLite_Open()
;    handles all three.
; 2. SQLite_Exec runs a multi-statement script in one call. We use it to
;    load schema.sql + data.sql into an in-memory database without any
;    statement-by-statement loop.
; 3. SQLite_Query returns an Array of Maps (one per row) — straight
;    consumable by the JSON encoder (KL_JsonEncode) without further
;    massage.
; 4. Errors are surfaced via Logger.error from a single chokepoint
;    (_check) rather than via thrown exceptions, mirroring the rest of
;    the keylogger pipeline (failures must not nuke the script).
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class SQLiteConst {
		static OK         := 0
		static ROW        := 100
		static DONE       := 101
		static OPEN_RO    := 0x01
		static OPEN_RW    := 0x02
		static OPEN_CRT   := 0x04
		static OPEN_MEM   := 0x80
		static TYPE_INT   := 1
		static TYPE_FLT   := 2
		static TYPE_TXT   := 3
		static TYPE_BLOB  := 4
		static TYPE_NULL  := 5
		; Vendored sqlite.org official x64 build (public domain). Resolved
		; via the global ``_VendorDir`` so the compiled exe can read it from the
		; per-version LocalAppData bundle dir rather than from next to the .exe.
		; We do NOT use Windows' winsqlite3.dll: Microsoft documents it as OS-
		; internal and every third-party DllCall path through it either
		; access-violated or hard-crashed the AHK process.
		static DLL        := _VendorDir . "\sqlite3.dll"
		static UTF8_PAGE  := 65001
}

_SQLite_ProgressYield(user_data) {
		Sleep(-1)
		return 0
}

global _SQLite_ProgressCb := CallbackCreate(_SQLite_ProgressYield, "C", 1)

SQLite_ClearProgressHandler(db, YieldOps) {
		if (YieldOps > 0)
				DllCall(SQLiteConst.DLL . "\sqlite3_progress_handler",
						"Ptr", db, "Int", 0, "Ptr", 0, "Ptr", 0)
}

SQLite_FinalizeStatement(pstmt) {
		if !pstmt
				return SQLiteConst.OK
		return DllCall(SQLiteConst.DLL . "\sqlite3_finalize", "Ptr", pstmt, "Int")
}





; ============================================
; ============================================
; ======= 2/ String marshaling helpers =======
; ============================================
; ============================================

; UTF-8 in / UTF-16 out across the FFI boundary. SQLite is UTF-8 native
; and the AHK strings are UTF-16; without explicit conversion we would
; corrupt every non-ASCII character (NBSP, accented letters, …).

SQLite_StrToUtf8(s, &buf) {
		; Encode `s` to UTF-8 + NUL into a Buffer; expose the Buffer back via
		; the &buf out-parameter so it stays alive until the SQLite call returns.
		n := StrPut(s, "UTF-8")
		buf := Buffer(n, 0)
		StrPut(s, buf, "UTF-8")
		return buf.Ptr
}

SQLite_Utf8ToStr(ptr) {
		if !ptr
				return ""
		return StrGet(ptr, "UTF-8")
}





; ===============================
; ===============================
; ======= 3/ Open / Close =======
; ===============================
; ===============================

SQLite_Open(path, flags := 0) {
		; flags = 0 → defaults to OPEN_RW | OPEN_CRT (rebuild semantics).
		if (flags = 0)
				flags := SQLiteConst.OPEN_RW | SQLiteConst.OPEN_CRT
		n := StrPut(path, "UTF-8")
		p_buf := Buffer(n, 0)
		StrPut(path, p_buf, "UTF-8")
		pdb := 0
		rc := DllCall(SQLiteConst.DLL . "\sqlite3_open_v2",
				"Ptr",  p_buf.Ptr,
				"Ptr*", &pdb,
				"Int",  flags,
				"Ptr",  0,
				"Int")
		if (rc != SQLiteConst.OK) {
				if pdb
						DllCall(SQLiteConst.DLL . "\sqlite3_close_v2", "Ptr", pdb)
				return 0
		}
		return pdb
}

SQLite_Close(db) {
		if !db
				return
		DllCall(SQLiteConst.DLL . "\sqlite3_close_v2", "Ptr", db)
}

; Clone a live in-memory database into a private candidate.  Callers may mutate
; the candidate freely and publish it only after every input has validated;
; sqlite3_backup copies the complete schema/data image without serialising it
; through SQL text or exposing a half-applied update to readers.
SQLite_CloneMemory(source_db, before_call := 0, close_fn := 0) {
		if !source_db
				return 0

		; `candidate` and `backup` stay owned by this function until the success
		; flag / zeroing operation explicitly transfers or releases each handle.
		; The optional callbacks are deterministic fault-injection seams for the
		; ownership test; production callers use the real DllCall/SQLite_Close path.
		candidate := 0
		backup := 0
		clone_succeeded := false
		try {
				candidate := SQLite_Open(":memory:")
				if !candidate
						return 0
				main_ptr := SQLite_StrToUtf8("main", &main_buf)
				if IsObject(before_call)
						before_call.Call("backup_init")
				backup := DllCall(SQLiteConst.DLL . "\sqlite3_backup_init",
						"Ptr", candidate,
						"Ptr", main_ptr,
						"Ptr", source_db,
						"Ptr", main_ptr,
						"Ptr")
				if !backup
						return 0

				if IsObject(before_call)
						before_call.Call("backup_step")
				step_rc := DllCall(SQLiteConst.DLL . "\sqlite3_backup_step",
						"Ptr", backup, "Int", -1, "Int")
				if IsObject(before_call)
						before_call.Call("backup_finish")
				finish_rc := DllCall(SQLiteConst.DLL . "\sqlite3_backup_finish",
						"Ptr", backup, "Int")
				; sqlite3_backup_finish always destroys the backup object once the call
				; returns, including when its result reports an SQLite error.
				backup := 0
				if (step_rc != SQLiteConst.DONE || finish_rc != SQLiteConst.OK)
						return 0

				clone_succeeded := true
				return candidate
		} catch as err {
				try LoggerError("sqlite3", "In-memory database clone failed: {1}", err.Message)
				return 0
		} finally {
				; A throw before the normal finish returns leaves the backup owned here.
				; Cleanup is best-effort and must never replace the fail-closed result.
				if backup {
						try {
								if IsObject(before_call)
										before_call.Call("cleanup_finish")
								DllCall(SQLiteConst.DLL . "\sqlite3_backup_finish",
										"Ptr", backup, "Int")
						} catch as cleanup_err {
								try LoggerError("sqlite3", "In-memory database clone could not finish its failed backup: {1}", cleanup_err.Message)
						}
				}
				if (candidate && !clone_succeeded) {
						try {
								if IsObject(close_fn)
										close_fn.Call(candidate)
								else
										SQLite_Close(candidate)
						} catch as cleanup_err {
								try LoggerError("sqlite3", "In-memory database clone could not close its failed candidate: {1}", cleanup_err.Message)
						}
				}
		}
}

SQLite_IsAutocommit(db) {
		if !db
				return false
		return DllCall(SQLiteConst.DLL . "\sqlite3_get_autocommit",
				"Ptr", db, "Int") != 0
}

SQLite_LastError(db) {
		if !db
				return ""
		p := DllCall(SQLiteConst.DLL . "\sqlite3_errmsg",
				"Ptr", db, "Ptr")
		return SQLite_Utf8ToStr(p)
}





; =================================
; =================================
; ======= 4/ Exec (no rows) =======
; =================================
; =================================

SQLite_Exec(db, sql, YieldOps := 0) {
		; winsqlite3.dll's sqlite3_exec entry point access-violates when
		; called from AHK no matter how we shape the parameters (verified
		; against several well-formed signatures). The standard prepare /
		; step / finalize loop works fine, so we drive the multi-statement
		; script ourselves: prepare consumes one statement at a time and
		; returns a tail pointer to the leftover SQL.
		if !db
				return false

		if (YieldOps > 0)
				DllCall(SQLiteConst.DLL . "\sqlite3_progress_handler", "Ptr", db, "Int", YieldOps, "Ptr", _SQLite_ProgressCb, "Ptr", 0)

		n := StrPut(sql, "UTF-8")
		sql_buf := Buffer(n, 0)
		StrPut(sql, sql_buf, "UTF-8")

		cur  := sql_buf.Ptr
		end_ := cur + n - 1   ; exclude the trailing NUL.
		pstmt_buf := Buffer(8, 0)
		ptail_buf := Buffer(8, 0)
		while (cur < end_) {
				NumPut("Ptr", 0, pstmt_buf, 0)
				NumPut("Ptr", 0, ptail_buf, 0)
				rc := DllCall(SQLiteConst.DLL . "\sqlite3_prepare_v2",
						"Ptr",  db,
						"Ptr",  cur,
						"Int",  -1,
						"Ptr",  pstmt_buf.Ptr,
						"Ptr",  ptail_buf.Ptr,
						"Int")
				pstmt := NumGet(pstmt_buf, 0, "Ptr")
				ptail := NumGet(ptail_buf, 0, "Ptr")
				if (rc != SQLiteConst.OK) {
						; Surface the SQLite error so callers can diagnose schema mismatches
						; rather than silently receiving an empty result set.
						try LoggerError("sqlite3", "sqlite3_prepare_v2 failed (rc={1}): {2}", rc, SQLite_LastError(db))
						SQLite_ClearProgressHandler(db, YieldOps)
						return false
				}
				if pstmt {
						; Drive the statement to completion. Most schema/INSERT
						; statements step once and return DONE; SELECTs would loop.
						Loop {
								step_rc := DllCall(SQLiteConst.DLL . "\sqlite3_step",
										"Ptr", pstmt, "Int")
								if (step_rc != SQLiteConst.ROW)
										break
						}
						; A terminal code other than DONE (e.g. CONSTRAINT on a CHECK/
						; UNIQUE violation) means the row was rejected. The loop above only
						; ever checked "!= ROW", so a CONSTRAINT/ERROR code was previously
						; treated identically to a clean DONE — the row silently vanished
						; with zero trace (F20).
						if (step_rc != SQLiteConst.DONE) {
								try LoggerError("sqlite3", "sqlite3_step failed (rc={1}): {2}", step_rc, SQLite_LastError(db))
								SQLite_FinalizeStatement(pstmt)
								SQLite_ClearProgressHandler(db, YieldOps)
								return false
						}
						finalize_rc := SQLite_FinalizeStatement(pstmt)
						if (finalize_rc != SQLiteConst.OK) {
								try LoggerError("sqlite3", "sqlite3_finalize failed (rc={1}): {2}", finalize_rc, SQLite_LastError(db))
								SQLite_ClearProgressHandler(db, YieldOps)
								return false
						}
				}
				if (!ptail || ptail = cur) {
						try LoggerError("sqlite3", "sqlite3_prepare_v2 made no forward progress.")
						SQLite_ClearProgressHandler(db, YieldOps)
						return false
				}
				cur := ptail
		}

		SQLite_ClearProgressHandler(db, YieldOps)

		return true
}





; ===============================================
; ===============================================
; ======= 5/ Query (rows → Array of Maps) =======
; ===============================================
; ===============================================

; Run a SELECT and return Array<Map> where each Map has column_name → value.
; Numeric columns come back as Number, text as String, NULL as "".
SQLite_Query(db, sql, YieldOps := 0) {
		out := []
		if !db
				return out

		if (YieldOps > 0)
				DllCall(SQLiteConst.DLL . "\sqlite3_progress_handler", "Ptr", db, "Int", YieldOps, "Ptr", _SQLite_ProgressCb, "Ptr", 0)

		n := StrPut(sql, "UTF-8")
		sql_buf := Buffer(n, 0)
		StrPut(sql, sql_buf, "UTF-8")
		pstmt_buf := Buffer(8, 0)
		rc := DllCall(SQLiteConst.DLL . "\sqlite3_prepare_v2",
				"Ptr", db,
				"Ptr", sql_buf.Ptr,
				"Int", -1,
				"Ptr", pstmt_buf.Ptr,
				"Ptr", 0,
				"Int")
		pstmt := NumGet(pstmt_buf, 0, "Ptr")
		if (rc != SQLiteConst.OK || !pstmt) {
				SQLite_ClearProgressHandler(db, YieldOps)
				return out
		}

		; Cache column names once — sqlite3_column_name returns a UTF-8 ptr
		; whose lifetime is tied to the statement, so it is safe to reuse
		; across step() calls.
		col_count := DllCall(SQLiteConst.DLL . "\sqlite3_column_count",
				"Ptr", pstmt, "Int")
		col_names := []
		Loop col_count {
				idx := A_Index - 1
				np := DllCall(SQLiteConst.DLL . "\sqlite3_column_name",
						"Ptr", pstmt, "Int", idx, "Ptr")
				col_names.Push(SQLite_Utf8ToStr(np))
		}

		while (true) {
				rc := DllCall(SQLiteConst.DLL . "\sqlite3_step",
						"Ptr", pstmt, "Int")
				if (rc != SQLiteConst.ROW)
						break
				row := Map()
				Loop col_count {
						idx  := A_Index - 1
						ctype := DllCall(SQLiteConst.DLL . "\sqlite3_column_type",
								"Ptr", pstmt, "Int", idx, "Int")
						switch ctype {
								case SQLiteConst.TYPE_INT:
										row[col_names[A_Index]] := DllCall(SQLiteConst.DLL . "\sqlite3_column_int64",
												"Ptr", pstmt, "Int", idx, "Int64")
								case SQLiteConst.TYPE_FLT:
										row[col_names[A_Index]] := DllCall(SQLiteConst.DLL . "\sqlite3_column_double",
												"Ptr", pstmt, "Int", idx, "Double")
								case SQLiteConst.TYPE_NULL:
										row[col_names[A_Index]] := ""
								default:
										tp := DllCall(SQLiteConst.DLL . "\sqlite3_column_text",
												"Ptr", pstmt, "Int", idx, "Ptr")
										row[col_names[A_Index]] := SQLite_Utf8ToStr(tp)
						}
				}
				out.Push(row)
		}
		SQLite_FinalizeStatement(pstmt)

		SQLite_ClearProgressHandler(db, YieldOps)

		return out
}

; Stream a SELECT one row at a time instead of allocating its complete result
; set.  The metrics reader uses this for cold-cache walker reconstruction:
; a months-long events_typing history can contain hundreds of thousands of
; rows, and SQLite_Query would first duplicate all of them as AHK Maps before
; the walker got a chance to consume a single one.  `consumer` receives one
; Map per row and may return false to stop early.  The return value is the
; number of delivered rows, or -1 when preparing/stepping/calling the consumer
; failed.
SQLite_EachRow(db, sql, consumer, YieldEvery := 0) {
		if !db || !IsObject(consumer)
				return -1

		n := StrPut(sql, "UTF-8")
		sql_buf := Buffer(n, 0)
		StrPut(sql, sql_buf, "UTF-8")
		pstmt_buf := Buffer(8, 0)
		rc := DllCall(SQLiteConst.DLL . "\sqlite3_prepare_v2",
				"Ptr", db,
				"Ptr", sql_buf.Ptr,
				"Int", -1,
				"Ptr", pstmt_buf.Ptr,
				"Ptr", 0,
				"Int")
		pstmt := NumGet(pstmt_buf, 0, "Ptr")
		if (rc != SQLiteConst.OK || !pstmt)
				return -1

		col_count := DllCall(SQLiteConst.DLL . "\sqlite3_column_count",
				"Ptr", pstmt, "Int")
		col_names := []
		Loop col_count {
				idx := A_Index - 1
				np := DllCall(SQLiteConst.DLL . "\sqlite3_column_name",
						"Ptr", pstmt, "Int", idx, "Ptr")
				col_names.Push(SQLite_Utf8ToStr(np))
		}

		delivered := 0
		ok := true
		while (true) {
				rc := DllCall(SQLiteConst.DLL . "\sqlite3_step", "Ptr", pstmt, "Int")
				if (rc != SQLiteConst.ROW)
						break
				row := Map()
				Loop col_count {
						idx := A_Index - 1
						ctype := DllCall(SQLiteConst.DLL . "\sqlite3_column_type",
								"Ptr", pstmt, "Int", idx, "Int")
						switch ctype {
								case SQLiteConst.TYPE_INT:
										row[col_names[A_Index]] := DllCall(SQLiteConst.DLL . "\sqlite3_column_int64",
												"Ptr", pstmt, "Int", idx, "Int64")
								case SQLiteConst.TYPE_FLT:
										row[col_names[A_Index]] := DllCall(SQLiteConst.DLL . "\sqlite3_column_double",
												"Ptr", pstmt, "Int", idx, "Double")
								case SQLiteConst.TYPE_NULL:
										row[col_names[A_Index]] := ""
								default:
										tp := DllCall(SQLiteConst.DLL . "\sqlite3_column_text",
												"Ptr", pstmt, "Int", idx, "Ptr")
										row[col_names[A_Index]] := SQLite_Utf8ToStr(tp)
						}
				}
				try keep_going := consumer.Call(row)
				catch {
						ok := false
						break
				}
				delivered += 1
				if (keep_going = false)
						break
				if (YieldEvery > 0 && Mod(delivered, YieldEvery) = 0)
						Sleep(-1)
		}
		SQLite_FinalizeStatement(pstmt)
		if (rc != SQLiteConst.DONE && rc != SQLiteConst.ROW)
				ok := false
		return ok ? delivered : -1
}





; ===============================
; ===============================
; ======= 6/ Quote helper =======
; ===============================
; ===============================

; Single-quote a string for safe SQL embedding. We never use parameter
; binding in this codebase — the queries are static and the only user
; data injected is the YYYY-MM-DD date and the app process name, both
; of which we sanitise here.
SQLite_Q(s) {
		s := String(s)
		s := StrReplace(s, "'", "''")
		return "'" . s . "'"
}
