; modules/keylogger/keylogger_text_migration.ahk

; ==============================================================================
; MODULE: Typed-Text At-Rest Migration (AutoHotkey)
; DESCRIPTION:
; Windows counterpart of {linux,macos}/modules/keylogger/text_migration.lua.
; Converts the typed-text columns of rows that were ALREADY stored before the
; at-rest setting changed: ticking the box encrypted only what was written from
; that point on, so a machine with a year of logs enabled a setting that left
; every earlier row in clear. Unticking it had the mirror defect.
;
; WHY THIS ONE REWRITES A FILE AND THE OTHER TWO REWRITE A DATABASE:
; This driver never opens db.sqlite. Its store on disk is data.sql, an
; append-only ledger of INSERT statements, and db.sqlite is a disposable cache
; the launcher rebuilds from it in tmpdir on demand. Rewriting the database
; would therefore protect nothing: the next rebuild would restore the plaintext
; straight out of data.sql. The ledger IS the data at rest, so the ledger is
; what gets converted.
;
; WHY IT IS SAFE TO REWRITE AN APPEND-ONLY FILE:
; The converted ledger is built beside the original and published with a single
; move. Until that move the original is untouched, so an interruption at any
; point - crash, reload, power loss - leaves data.sql exactly as it was, and the
; abandoned staging file is discarded on the next attempt. The ingest tick is
; held off for the duration (KL_Mig_IsActive), so no append can be lost in the
; window between the last read and the move; today.log keeps buffering meanwhile,
; exactly as it already does during a typing burst.
;
; PERFORMANCE:
; The ledger is streamed one statement at a time, never loaded whole, and a
; bounded number of statements is converted per timer slice so the keyboard hook
; keeps running. The key is derived once and cached by keylogger_text_cipher.
; ==============================================================================

; ==============================================================================
; ==============================================================================
; ======= 1/ Constants =========================================================
; ==============================================================================
; ==============================================================================

; The statement shape this migration recognises. Anything else in the ledger -
; comments, PRAGMA, BEGIN/COMMIT, every other events_* INSERT - is copied
; through byte for byte.
global KL_MIG_INSERT_MARKER := "INSERT OR IGNORE INTO events_typing "

; The columns a conversion may rewrite, with the suffix each one's IV input
; carries. MUST match KL_BuildInsertTyping and the shared Lua plan
; (_shared/lua/keylogger/text_migration.lua): the IV is not stored, it is
; recomputed from the row identity, so a suffix that drifts produces rows that
; decrypt to garbage. The aggregates are deliberately absent - the dashboard
; computes over them, and an encrypted blob in one would break every query while
; protecting nothing.
global KL_MIG_COLUMNS := [["text", ""], ["events_json", "j"]]

; The two directions a pass can run in.
global KL_MIG_MODE_ENCRYPT := "encrypt"
global KL_MIG_MODE_DECRYPT := "decrypt"

; Suffix of the staging ledger built beside the original.
global KL_MIG_STAGING_SUFFIX := ".migrating"

; Name of the file recording which posture the ledger has been fully converted
; to. Without it every launch would rewrite the whole ledger to change nothing.
global KL_MIG_MARKER_FILE := "encrypt_migrated.txt"

; Statements converted per timer slice, and the gap between slices. Each value
; costs one AES call, so a slice is short; the gap is what returns the message
; queue to the keyboard hook between them.
global KL_MIG_STATEMENTS_PER_SLICE := 200
global KL_MIG_SLICE_INTERVAL_MS := 25

; Characters pulled from the ledger per read. Large enough that a 100 MB file is
; not read a statement at a time, small enough that memory stays flat.
global KL_MIG_READ_CHUNK_CHARS := 65536

; Delay before the boot-time posture check. Deferred so the comparison - and the
; rewrite it may start - never lands on the boot critical path.
global KL_MIG_BOOT_DELAY_MS := 3000




; ==============================================================================
; ==============================================================================
; ======= 2/ State =============================================================
; ==============================================================================
; ==============================================================================

class KLMigration {
		; Whether a pass is in flight. Read by KL_IngestOnce, which defers while it
		; is true so no append can be lost between the last read and the move.
		static active := false

		static mode := ""
		static sourcePath := ""
		static stagePath := ""
		static readFh := ""
		static writeFh := ""

		; Unconsumed input. Holds at most one statement plus the tail of the last
		; read, never the ledger.
		static buffer := ""
		static eof := false

		static scanned := 0
		static converted := 0
}




; ==============================================================================
; ==============================================================================
; ======= 3/ SQL Tokenising ====================================================
; ==============================================================================
; ==============================================================================

; Returns the position of the `;` that ends the first statement in `s`, or 0
; when `s` does not contain a complete one yet.
; Quoting is tracked because the typed text this ledger carries can contain a
; semicolon, a double-dash, or an escaped quote - splitting on a bare `;` would
; cut a statement in half and corrupt the row.
_KL_Mig_StatementEnd(s) {
		i := 1
		n := StrLen(s)
		inString := false
		while (i <= n) {
				c := SubStr(s, i, 1)
				if (inString) {
						if (c = "'") {
								; '' inside a literal is an escaped quote, not its end.
								if (SubStr(s, i + 1, 1) = "'") {
										i += 2
										continue
								}
								inString := false
						}
						i += 1
						continue
				}
				if (c = "'") {
						inString := true
						i += 1
						continue
				}
				; A -- comment runs to end of line. It is copied through like everything
				; else, but its content must not be parsed: a comment holding an odd
				; number of quotes would otherwise flip the literal state for the rest of
				; the file.
				if (c = "-" && SubStr(s, i + 1, 1) = "-") {
						nl := InStr(s, "`n", , i)
						if (!nl)
								return 0
						i := nl + 1
						continue
				}
				if (c = ";")
						return i
				i += 1
		}
		return 0
}

; Returns the position of the `)` closing the `(` at `openPos`, or 0.
_KL_Mig_MatchingParen(s, openPos) {
		i := openPos + 1
		n := StrLen(s)
		depth := 1
		inString := false
		while (i <= n) {
				c := SubStr(s, i, 1)
				if (inString) {
						if (c = "'") {
								if (SubStr(s, i + 1, 1) = "'") {
										i += 2
										continue
								}
								inString := false
						}
						i += 1
						continue
				}
				if (c = "'")
						inString := true
				else if (c = "(")
						depth += 1
				else if (c = ")") {
						depth -= 1
						if (depth = 0)
								return i
				}
				i += 1
		}
		return 0
}

; Splits a VALUES tuple body into its fields, keeping each one's exact text.
; Commas inside a quoted literal are part of the typed text, not separators.
_KL_Mig_SplitTuple(inner) {
		fields := []
		start := 1
		i := 1
		n := StrLen(inner)
		depth := 0
		inString := false
		while (i <= n) {
				c := SubStr(inner, i, 1)
				if (inString) {
						if (c = "'") {
								if (SubStr(inner, i + 1, 1) = "'") {
										i += 2
										continue
								}
								inString := false
						}
						i += 1
						continue
				}
				if (c = "'")
						inString := true
				else if (c = "(")
						depth += 1
				else if (c = ")")
						depth -= 1
				else if (c = "," && depth = 0) {
						fields.Push(SubStr(inner, start, i - start))
						start := i + 1
				}
				i += 1
		}
		fields.Push(SubStr(inner, start))
		return fields
}

; 1-based index of `name` in a column-name list, or 0.
_KL_Mig_IndexOf(columns, name) {
		for index, column in columns {
				if (Trim(column) = name)
						return index
		}
		return 0
}

; Strips the quotes off a SQL literal and unescapes its doubled quotes.
_KL_Mig_Unquote(literal) {
		inner := SubStr(literal, 2, StrLen(literal) - 2)
		return StrReplace(inner, "''", "'")
}




; ==============================================================================
; ==============================================================================
; ======= 4/ Statement Conversion ==============================================
; ==============================================================================
; ==============================================================================

; Converts one statement.
; @param sql          String One complete statement, terminator included.
; @param deviceIdLit  String The LOCAL device id, already SQL-quoted.
; @param mode         String KL_MIG_MODE_ENCRYPT or KL_MIG_MODE_DECRYPT.
; @return Map ok / sql / changed. ok=false means the crypto failed and the
;   caller must abandon the pass rather than write anything: the original file
;   is still intact at that point, so nothing is lost.
KL_Mig_ConvertStatement(sql, deviceIdLit, mode) {
		unchanged := Map("ok", true, "sql", sql, "changed", false)
		failed    := Map("ok", false, "sql", sql, "changed", false)

		markerPos := InStr(sql, KL_MIG_INSERT_MARKER)
		if (!markerPos)
				return unchanged

		columnsOpen := InStr(sql, "(", , markerPos)
		if (!columnsOpen)
				return failed
		columnsClose := _KL_Mig_MatchingParen(sql, columnsOpen)
		if (!columnsClose)
				return failed
		columns := StrSplit(SubStr(sql, columnsOpen + 1, columnsClose - columnsOpen - 1), ",", " `t`r`n")

		valuesPos := InStr(sql, "VALUES", , columnsClose)
		if (!valuesPos)
				return failed
		valuesOpen := InStr(sql, "(", , valuesPos)
		if (!valuesOpen)
				return failed
		valuesClose := _KL_Mig_MatchingParen(sql, valuesOpen)
		if (!valuesClose)
				return failed

		fields := _KL_Mig_SplitTuple(SubStr(sql, valuesOpen + 1, valuesClose - valuesOpen - 1))
		; A tuple that does not line up with the column list is a statement this
		; parser does not understand. Rewriting it blind could put an envelope in the
		; wrong column, so the pass stops instead.
		if (fields.Length != columns.Length)
				return failed

		deviceIndex := _KL_Mig_IndexOf(columns, "device_id")
		idIndex     := _KL_Mig_IndexOf(columns, "id")
		if (!deviceIndex || !idIndex)
				return failed

		; A row imported from another device belongs to that device's key domain:
		; this machine could not decrypt it, and encrypting it would lock its owner
		; out of its own data.
		if (Trim(fields[deviceIndex]) != deviceIdLit)
				return unchanged

		rowId := Trim(fields[idIndex])
		changed := false
		for _, spec in KL_MIG_COLUMNS {
				columnIndex := _KL_Mig_IndexOf(columns, spec[1])
				if (!columnIndex)
						continue
				raw := Trim(fields[columnIndex])
				; Only a quoted literal holds text. NULL and numerics are left alone.
				if (StrLen(raw) < 2 || SubStr(raw, 1, 1) != "'" || SubStr(raw, -1) != "'")
						continue
				value := _KL_Mig_Unquote(raw)
				if (value = "")
						continue

				wrapped := KL_Enc_IsEncrypted(value)
				if (mode = KL_MIG_MODE_ENCRYPT) {
						; Already an envelope: wrapping it again would make it undecryptable
						; in one pass. This is what makes a restarted migration converge.
						if (wrapped)
								continue
						converted := KL_Enc_Encrypt(Keylogger.device_id, rowId . spec[2], value)
						; KL_Enc_Encrypt returns the plaintext untouched when the toggle is
						; off, so only the envelope marker proves anything happened.
						if (converted = "" || !KL_Enc_IsEncrypted(converted))
								return failed
				} else {
						if (!wrapped)
								continue
						converted := KL_Enc_Decrypt(value)
						; An envelope never wraps an empty value, so an empty result means the
						; decryption failed. Writing it would erase the row for good.
						if (converted = "")
								return failed
				}
				fields[columnIndex] := KL_SqlStr(converted)
				changed := true
		}

		if (!changed)
				return unchanged

		rebuilt := ""
		for index, field in fields
				rebuilt .= (index = 1 ? "" : ",") . field
		return Map("ok", true,
				"sql", SubStr(sql, 1, valuesOpen) . rebuilt . SubStr(sql, valuesClose),
				"changed", true)
}




; ==============================================================================
; ==============================================================================
; ======= 5/ Ledger Rewrite ====================================================
; ==============================================================================
; ==============================================================================

; Path of the file recording the posture the ledger is fully converted to.
KL_Mig_MarkerPath() {
		return Keylogger.by_device_dir . KL_MIG_MARKER_FILE
}

; Reads that marker: "on", "off", or "" when no pass has ever completed.
KL_Mig_ReadMarker() {
		try {
				if FSExists(KL_Mig_MarkerPath())
						return Trim(FSRead(KL_Mig_MarkerPath()))
		}
		return ""
}

; Records the posture the ledger is now fully converted to.
; Written through the same adapter that reads it, so the two agree on encoding:
; a writer that emits a byte-order mark and a reader that does not strip one
; would compare "﻿on" against "on" and rewrite the whole ledger at every
; single launch.
KL_Mig_WriteMarker(posture) {
		FSWrite(KL_Mig_MarkerPath(), posture)
}

; Releases the handles and drops the staging file. The original ledger has not
; been touched at this point, so this is always a clean abandonment.
_KL_Mig_Release() {
		if IsObject(KLMigration.readFh)
				try KLMigration.readFh.Close()
		if IsObject(KLMigration.writeFh)
				try KLMigration.writeFh.Close()
		KLMigration.readFh := ""
		KLMigration.writeFh := ""
		KLMigration.buffer := ""
		KLMigration.active := false
		SetTimer(KL_Mig_Tick, 0)
}

_KL_Mig_Abort(reason) {
		stage := KLMigration.stagePath
		_KL_Mig_Release()
		FSDelete(stage)
		try LoggerError("Keylogger",
				"At-rest migration stopped after {1} row(s): {2}. data.sql is unchanged and still readable.",
				KLMigration.converted, reason)
		return false
}

; Publishes the converted ledger over the original with a single move - the one
; instant at which anything the user relies on changes.
_KL_Mig_Finish() {
		posture := (KLMigration.mode = KL_MIG_MODE_ENCRYPT) ? "on" : "off"
		source := KLMigration.sourcePath
		stage  := KLMigration.stagePath
		scanned := KLMigration.scanned
		converted := KLMigration.converted
		_KL_Mig_Release()
		; One move, and it is the only instant at which anything the user relies on
		; changes. Everything before it wrote to the staging file alone.
		if !FSMove(stage, source, true) {
				FSDelete(stage)
				try LoggerError("Keylogger",
						"At-rest migration could not publish the converted ledger - data.sql is unchanged.")
				return false
		}
		KL_Mig_WriteMarker(posture)
		try LoggerSuccess("Keylogger",
				"At-rest migration finished: {1} row(s) converted, {2} statement(s) scanned.",
				converted, scanned)
		return false
}

; Converts up to KL_MIG_STATEMENTS_PER_SLICE statements.
; @return true when there is more to do, false once the pass has ended.
KL_Mig_Slice() {
		if (!KLMigration.active)
				return false

		deviceIdLit := Keylogger._device_id_lit
		processed := 0
		while (processed < KL_MIG_STATEMENTS_PER_SLICE) {
				endPos := _KL_Mig_StatementEnd(KLMigration.buffer)
				if (!endPos) {
						if (KLMigration.eof) {
								; Whatever is left is a trailing comment or a partial line: it
								; carries no statement, so it is copied through verbatim.
								if (KLMigration.buffer != "")
										KLMigration.writeFh.Write(KLMigration.buffer)
								KLMigration.buffer := ""
								return _KL_Mig_Finish()
						}
						chunk := ""
						try chunk := KLMigration.readFh.Read(KL_MIG_READ_CHUNK_CHARS)
						if (chunk = "") {
								KLMigration.eof := true
								continue
						}
						KLMigration.buffer .= chunk
						continue
				}

				statement := SubStr(KLMigration.buffer, 1, endPos)
				KLMigration.buffer := SubStr(KLMigration.buffer, endPos + 1)
				result := KL_Mig_ConvertStatement(statement, deviceIdLit, KLMigration.mode)
				if (!result["ok"])
						return _KL_Mig_Abort("a row could not be converted")
				KLMigration.writeFh.Write(result["sql"])
				KLMigration.scanned += 1
				if (result["changed"])
						KLMigration.converted += 1
				processed += 1
		}
		return true
}

KL_Mig_Tick() {
		; Re-armed as a ONE-SHOT rather than left running as a periodic timer: a
		; repeating sub-second timer is a permanent stall inserted into typing, and
		; this one only has work to do while a pass is in flight.
		if KL_Mig_Slice()
				SetTimer(KL_Mig_Tick, -KL_MIG_SLICE_INTERVAL_MS)
}




; ==============================================================================
; ==============================================================================
; ======= 6/ Public API ========================================================
; ==============================================================================
; ==============================================================================

; Whether a pass is in flight. KL_IngestOnce defers while it is true.
KL_Mig_IsActive() {
		return KLMigration.active
}

; Stops the pass. The original ledger was never touched, so this reverts
; nothing; the next attempt simply starts over, and the idempotent conversion
; makes that converge.
KL_Mig_Cancel() {
		if (!KLMigration.active)
				return
		stage := KLMigration.stagePath
		_KL_Mig_Release()
		FSDelete(stage)
		try LoggerInfo("Keylogger", "At-rest migration cancelled after {1} converted row(s).",
				KLMigration.converted)
}

; Starts a pass over the ledger.
; @param mode String KL_MIG_MODE_ENCRYPT or KL_MIG_MODE_DECRYPT.
; @param schedule Boolean Arm the slice timer. A test drives KL_Mig_Slice itself.
; @return Boolean True when a pass is now in flight.
KL_Mig_Start(mode, schedule := true) {
		KL_Mig_Cancel()
		if (mode != KL_MIG_MODE_ENCRYPT && mode != KL_MIG_MODE_DECRYPT) {
				try LoggerError("Keylogger", "At-rest migration: unknown mode '{1}'.", mode)
				return false
		}
		if (Keylogger.device_id = "" || Keylogger.data_sql_path = "")
				return false
		if !FSExists(Keylogger.data_sql_path)
				return false
		if (mode = KL_MIG_MODE_ENCRYPT && !KL_Enc_IsAvailable()) {
				try LoggerError("Keylogger",
						"At-rest migration requested but no key can be derived - data.sql left unchanged.")
				return false
		}

		KLMigration.mode := mode
		KLMigration.sourcePath := Keylogger.data_sql_path
		KLMigration.stagePath := Keylogger.data_sql_path . KL_MIG_STAGING_SUFFIX
		KLMigration.buffer := ""
		KLMigration.eof := false
		KLMigration.scanned := 0
		KLMigration.converted := 0

		; A staging file left by an interrupted attempt describes a ledger that has
		; since moved on. Start clean rather than resume it.
		FSDelete(KLMigration.stagePath)
		KLMigration.readFh := FSOpenRead(KLMigration.sourcePath)
		KLMigration.writeFh := FSOpenWrite(KLMigration.stagePath)
		if (!IsObject(KLMigration.readFh) || !IsObject(KLMigration.writeFh)) {
				try LoggerError("Keylogger", "At-rest migration cannot open the ledger - data.sql is unchanged.")
				_KL_Mig_Release()
				return false
		}

		KLMigration.active := true
		try LoggerStart("Keylogger", "At-rest migration ({1}) over data.sql...", mode)
		if (schedule)
				SetTimer(KL_Mig_Tick, -KL_MIG_SLICE_INTERVAL_MS)
		return true
}

; Brings the ledger in line with the posture now in force, and ONLY when they
; disagree: a pass rewrites the whole ledger, so running one at every launch
; would rewrite a year of history to change nothing.
; @return Boolean True when a pass was started.
KL_Mig_SyncToPosture() {
		if (!Keylogger.initialized)
				return false
		; The cipher's own flag IS the posture in force — the config loader drives it
		; at boot and the menu drives it on a toggle. Reading it here rather than the
		; settings object keeps the ledger aligned with what actually encrypts.
		want := KL_Enc_IsEnabled() ? "on" : "off"
		if (KL_Mig_ReadMarker() = want)
				return false
		return KL_Mig_Start(want = "on" ? KL_MIG_MODE_ENCRYPT : KL_MIG_MODE_DECRYPT)
}
