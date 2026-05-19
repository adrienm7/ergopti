; lib/sqlite3.ahk

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




; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

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




; ====================================
; ====================================
; ======= 3/ Open / Close =======
; ====================================
; ====================================

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

SQLite_LastError(db) {
    if !db
        return ""
    p := DllCall(SQLiteConst.DLL . "\sqlite3_errmsg",
        "Ptr", db, "Ptr")
    return SQLite_Utf8ToStr(p)
}




; ===================================
; ===================================
; ======= 4/ Exec (no rows) =======
; ===================================
; ===================================

SQLite_Exec(db, sql) {
    ; winsqlite3.dll's sqlite3_exec entry point access-violates when
    ; called from AHK no matter how we shape the parameters (verified
    ; against several well-formed signatures). The standard prepare /
    ; step / finalize loop works fine, so we drive the multi-statement
    ; script ourselves: prepare consumes one statement at a time and
    ; returns a tail pointer to the leftover SQL.
    if !db
        return false
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
            try LoggerError("sqlite3", "sqlite3_prepare_v2 failed (rc=%d): %s", rc, SQLite_LastError(db))
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
            DllCall(SQLiteConst.DLL . "\sqlite3_finalize", "Ptr", pstmt)
        }
        if (!ptail || ptail = cur)
            break
        cur := ptail
    }
    return true
}




; ====================================================
; ====================================================
; ======= 5/ Query (rows → Array of Maps) =======
; ====================================================
; ====================================================

; Run a SELECT and return Array<Map> where each Map has column_name → value.
; Numeric columns come back as Number, text as String, NULL as "".
SQLite_Query(db, sql) {
    out := []
    if !db
        return out
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
        return out

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
    DllCall(SQLiteConst.DLL . "\sqlite3_finalize", "Ptr", pstmt)
    return out
}




; ============================================
; ============================================
; ======= 6/ Quote helper =======
; ============================================
; ============================================

; Single-quote a string for safe SQL embedding. We never use parameter
; binding in this codebase — the queries are static and the only user
; data injected is the YYYY-MM-DD date and the app process name, both
; of which we sanitise here.
SQLite_Q(s) {
    s := String(s)
    s := StrReplace(s, "'", "''")
    return "'" . s . "'"
}
