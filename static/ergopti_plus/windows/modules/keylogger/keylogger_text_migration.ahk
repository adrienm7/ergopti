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

; A converted ledger is not durably complete until its posture marker commits.
; One delayed retry absorbs a transient AV/indexer lock without spinning forever
; on a permanently unwritable directory; the pending state survives for resume
; or the next posture sync when that retry also fails.
global KL_MIG_MARKER_RETRY_MS := 1000

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
		static stageBytesWritten := 0

		; Re-entrancy guard for KL_Mig_Slice.
		;
		; A slice does blocking file I/O, and AHK PUMPS MESSAGES during it — so the
		; one-shot KL_Mig_Tick this pass schedules can dispatch in the middle of a
		; slice already running. The inner slice can reach the end of the pass,
		; call _KL_Mig_Release (which sets writeFh back to "") and return into the
		; outer one, whose very next line is writeFh.Write(...). That surfaced as an
		; intermittent 'This value of type "String" has no method named "Write"'.
		static inSlice := false

		; Unconsumed input. Holds at most one statement plus the tail of the last
		; read, never the ledger.
		static buffer := ""
		static eof := false

		static scanned := 0
		static converted := 0

		; Native Suspend does not stop one-shot timers. Keep the open stream and
		; cursor resumable, but let lifecycle ownership disarm every migration timer
		; until the matching resume reactor schedules exactly one continuation.
		static paused := false
		static syncPending := false

		; Publishing data.sql and publishing its posture are one logical commit. If
		; the marker write fails after the ledger move, retain the known posture and
		; completion counters so a cheap marker-only retry can finish the transaction.
		static pendingMarker := ""
		static pendingMarkerScanned := 0
		static pendingMarkerConverted := 0
		static pendingMarkerAnnounceSuccess := false
		; The ledger move itself is resumable too. This Map exists from handle close
		; through publish/marker/log completion, keeping ingest fenced across every
		; yield in what used to be an unowned active=false window.
		static commitPending := 0

		; Deterministic seams for lifecycle/commit regression tests. Production uses
		; SetTimer, the filesystem adapter, and LoggerSuccess directly.
		static timer_fn := 0
		static marker_commit_fn := 0
		static success_fn := 0
		static flush_fn := 0
		static size_fn := 0
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

; Timer boundary shared by boot sync, slice continuation, marker retry, suspend,
; and tests. A false return never discards the associated pending state.
_KL_Mig_ArmTimer(callback, period) {
		if IsObject(KLMigration.timer_fn)
				return KLMigration.timer_fn.Call(callback, period)
		try {
				; Every migration continuation is a one-shot. -Abs(0) is AHK's
				; documented cancel form, so this site can never become a poller.
				SetTimer(callback, -Abs(period))
				return true
		} catch as err {
				try LoggerError("Keylogger", "At-rest migration could not schedule lifecycle work: {1}", err.Message)
				return false
		}
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
_KL_Mig_CommitMarker(path, posture) {
		static WriteSeq := 0
		if _KL_Mig_PauseRequested()
				return false
		WriteSeq += 1
		tmp := path . "." . A_ScriptHwnd . "-" . WriteSeq . ".marker.tmp"
		FSDelete(tmp)
		if !FSWrite(tmp, posture)
				return false
		if _KL_Mig_PauseRequested()
				return false
		if !FSMove(tmp, path, true) {
				FSDelete(tmp)
				return false
		}
		if _KL_Mig_PauseRequested()
				return false
		; A successful rename is necessary but the readback is the durable contract:
		; a malformed/empty marker must never suppress the next proof scan.
		written := FSRead(path)
		return (written is String) && (Trim(written) = posture)
}

KL_Mig_WriteMarker(posture) {
		if (posture != "on" && posture != "off")
				return false
		commit := IsObject(KLMigration.marker_commit_fn)
				? KLMigration.marker_commit_fn : _KL_Mig_CommitMarker
		try return commit.Call(KL_Mig_MarkerPath(), posture) ? true : false
		catch as err {
				try LoggerError("Keylogger", "At-rest migration marker commit threw: {1}", err.Message)
				return false
		}
}

_KL_Mig_LogSuccess(converted, scanned) {
		if IsObject(KLMigration.success_fn)
				return KLMigration.success_fn.Call(converted, scanned)
		try LoggerSuccess("Keylogger",
				"At-rest migration finished: {1} row(s) converted, {2} statement(s) scanned.",
				converted, scanned)
		return true
}

_KL_Mig_ClearPendingMarker() {
		KLMigration.pendingMarker := ""
		KLMigration.pendingMarkerScanned := 0
		KLMigration.pendingMarkerConverted := 0
		KLMigration.pendingMarkerAnnounceSuccess := false
		_KL_Mig_ArmTimer(KL_Mig_RetryMarker, 0)
}

; Preserve the already-published ledger's known posture after marker failure.
; Retrying this tiny commit is O(1); rescanning the ledger is only the crash
; recovery fallback when process memory can no longer carry this state.
_KL_Mig_RememberMarkerRetry(posture, converted, scanned, announceSuccess) {
		KLMigration.pendingMarker := posture
		KLMigration.pendingMarkerScanned := scanned
		KLMigration.pendingMarkerConverted := converted
		KLMigration.pendingMarkerAnnounceSuccess := announceSuccess
		if A_IsSuspended {
				KLMigration.paused := true
				return false
		}
		return _KL_Mig_ArmTimer(KL_Mig_RetryMarker, -KL_MIG_MARKER_RETRY_MS)
}

KL_Mig_RetryMarker() {
		posture := KLMigration.pendingMarker
		if (posture = "")
				return false
		if A_IsSuspended || KLMigration.paused {
				KL_Mig_OnSuspend()
				return false
		}

		; A setting change invalidates an older marker retry. Do not publish stale
		; posture over a ledger that now needs the reverse conversion.
		want := KL_Enc_IsEnabled() ? "on" : "off"
		if (posture != want) {
				KLMigration.syncPending := true
				_KL_Mig_ArmTimer(KL_Mig_SyncToPosture, -1)
				return false
		}
		if !KL_Mig_WriteMarker(posture) {
				try LoggerError("Keylogger",
						"At-rest migration marker retry failed; durable completion remains pending.")
				return false
		}

		converted := KLMigration.pendingMarkerConverted
		scanned := KLMigration.pendingMarkerScanned
		announceSuccess := KLMigration.pendingMarkerAnnounceSuccess
		_KL_Mig_ClearPendingMarker()
		if announceSuccess
				_KL_Mig_LogSuccess(converted, scanned)
		return true
}

; Called only after bootstrap has created a brand-new ledger. With no legacy
; rows present, the cipher flag is a trustworthy O(1) description of every
; local row that can subsequently be appended.
KL_Mig_RecordNewLedgerPosture() {
		posture := KL_Enc_IsEnabled() ? "on" : "off"
		if KL_Mig_WriteMarker(posture)
				return true
		_KL_Mig_RememberMarkerRetry(posture, 0, 0, false)
		try LoggerError("Keylogger",
				"Created data.sql but could not commit its initial posture marker; marker retry remains pending.")
		return false
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
		_KL_Mig_ArmTimer(KL_Mig_Tick, 0)
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

_KL_Mig_WriteStage(Content) {
		if !IsObject(KLMigration.writeFh) || !(Content is String)
				return false
		ExpectedBytes := StrPut(Content, "UTF-8") - 1
		try Written := KLMigration.writeFh.Write(Content)
		catch
				return false
		if (Written != ExpectedBytes)
				return false
		KLMigration.stageBytesWritten += Written
		return true
}

_KL_Mig_FlushStage() {
		if !IsObject(KLMigration.writeFh)
				return false
		FlushFn := IsObject(KLMigration.flush_fn)
				? KLMigration.flush_fn : FSFlushFileBuffers
		try return FlushFn.Call(KLMigration.writeFh) == true
		catch
				return false
}

_KL_Mig_StageSize(path) {
		SizeFn := IsObject(KLMigration.size_fn) ? KLMigration.size_fn : FSSize
		try return SizeFn.Call(path)
		catch
				return -1
}

; Publishes the converted ledger over the original with a single move - the one
; instant at which anything the user relies on changes.
_KL_Mig_Finish() {
		if !_KL_Mig_FlushStage()
				return _KL_Mig_Abort("the staging ledger could not be durably flushed")
		posture := (KLMigration.mode = KL_MIG_MODE_ENCRYPT) ? "on" : "off"
		KLMigration.commitPending := Map(
				"posture", posture,
				"source", KLMigration.sourcePath,
				"stage", KLMigration.stagePath,
				"scanned", KLMigration.scanned,
				"converted", KLMigration.converted,
				"expected_bytes", KLMigration.stageBytesWritten,
				"published", false,
				"marker_committed", false
		)
		_KL_Mig_Release()
		return _KL_Mig_ContinueFinish()
}

_KL_Mig_ContinueFinish() {
		if !(KLMigration.commitPending is Map)
				return false
		if _KL_Mig_PauseRequested()
				return false
		commit := KLMigration.commitPending
		; One move, and it is the only instant at which anything the user relies on
		; changes. Everything before it wrote to the staging file alone.
		if !commit["published"] {
				if (_KL_Mig_StageSize(commit["stage"]) != commit["expected_bytes"]
						|| !FSMove(commit["stage"], commit["source"], true)) {
						FSDelete(commit["stage"])
						KLMigration.commitPending := 0
						try LoggerError("Keylogger",
								"At-rest migration could not validate and publish the converted ledger - data.sql is unchanged.")
						return false
				}
		}
		commit["published"] := true
		if _KL_Mig_PauseRequested()
				return false
		if !commit["marker_committed"] && !KL_Mig_WriteMarker(commit["posture"]) {
				KLMigration.commitPending := 0
				_KL_Mig_RememberMarkerRetry(commit["posture"],
						commit["converted"], commit["scanned"], true)
				if !KLMigration.paused
						try LoggerError("Keylogger",
								"At-rest migration published data.sql but could not commit its posture marker; success remains pending.")
				return false
		}
		commit["marker_committed"] := true
		if _KL_Mig_PauseRequested()
				return false
		KLMigration.commitPending := 0
		_KL_Mig_LogSuccess(commit["converted"], commit["scanned"])
		return false
}

_KL_Mig_PauseRequested() {
		if KLMigration.paused
				return true
		if A_IsSuspended {
				KL_Mig_OnSuspend()
				return true
		}
		return false
}

; Converts up to KL_MIG_STATEMENTS_PER_SLICE statements.
; @return true when there is more to do, false once the pass has ended.
KL_Mig_Slice() {
		if (!KLMigration.active)
				return false
		if _KL_Mig_PauseRequested()
				return true
		; A tick that lands while a slice is already running must yield, not run a
		; second slice over the same handles. Returning true keeps the pass alive:
		; the slice already in flight will schedule the next tick itself.
		if (KLMigration.inSlice)
				return true
		KLMigration.inSlice := true
		try {
				return _KL_Mig_SliceBody()
		} finally {
				KLMigration.inSlice := false
		}
}

; The body of one slice. Split out so the re-entrancy guard above wraps every
; exit path, including the early returns for end-of-pass and abort.
_KL_Mig_SliceBody() {
		deviceIdLit := Keylogger._device_id_lit
		processed := 0
		while (processed < KL_MIG_STATEMENTS_PER_SLICE) {
				if _KL_Mig_PauseRequested()
						return true
				endPos := _KL_Mig_StatementEnd(KLMigration.buffer)
				if (!endPos) {
						if (KLMigration.eof) {
								; Whatever is left is a trailing comment or a partial line: it
								; carries no statement, so it is copied through verbatim.
								if _KL_Mig_PauseRequested()
										return true
				if (KLMigration.buffer != ""
						&& !_KL_Mig_WriteStage(KLMigration.buffer))
						return _KL_Mig_Abort("the staging ledger write was incomplete")
								KLMigration.buffer := ""
								if _KL_Mig_PauseRequested()
										return true
								return _KL_Mig_Finish()
						}
						if _KL_Mig_PauseRequested()
								return true
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
				; Suspend can interrupt the crypto call above. Put the statement back
				; before yielding so resume neither drops nor duplicates it.
				if _KL_Mig_PauseRequested() {
						KLMigration.buffer := statement . KLMigration.buffer
						return true
				}
				if !_KL_Mig_WriteStage(result["sql"])
						return _KL_Mig_Abort("the staging ledger write was incomplete")
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
		if _KL_Mig_PauseRequested()
				return false
		if KL_Mig_Slice() && !_KL_Mig_PauseRequested()
		_KL_Mig_ArmTimer(KL_Mig_Tick, -KL_MIG_SLICE_INTERVAL_MS)
		return true
}




; ==============================================================================
; ==============================================================================
; ======= 6/ Public API ========================================================
; ==============================================================================
; ==============================================================================

; Whether a pass is in flight. KL_IngestOnce defers while it is true.
KL_Mig_IsActive() {
		return KLMigration.active || (KLMigration.commitPending is Map)
}

; Native Suspend owns migration timers explicitly. Open handles and the cursor
; stay intact so a 20-minute proof scan resumes instead of restarting, while no
; read/write/marker callback remains armed during the pause.
KL_Mig_OnSuspend() {
		hasWork := KLMigration.active || KLMigration.syncPending
				|| (KLMigration.pendingMarker != "")
				|| (KLMigration.commitPending is Map)
		if !hasWork
				return false
		KLMigration.paused := true
		_KL_Mig_ArmTimer(KL_Mig_Tick, 0)
		_KL_Mig_ArmTimer(KL_Mig_RetryMarker, 0)
		_KL_Mig_ArmTimer(KL_Mig_SyncToPosture, 0)
		return true
}

; Resume exactly one owner. Priority mirrors durability: finish an active scan,
; then its pending marker commit, then a boot/config posture comparison.
KL_Mig_OnResume() {
		if A_IsSuspended || !KLMigration.paused
				return false
		callback := 0
		period := -1
		if (KLMigration.commitPending is Map) {
				callback := _KL_Mig_ContinueFinish
		} else if KLMigration.active {
				callback := KL_Mig_Tick
				period := -KL_MIG_SLICE_INTERVAL_MS
		} else if (KLMigration.pendingMarker != "") {
				callback := KL_Mig_RetryMarker
				period := -KL_MIG_MARKER_RETRY_MS
		} else if KLMigration.syncPending {
				callback := KL_Mig_SyncToPosture
		}
		if !IsObject(callback) {
				KLMigration.paused := false
				return false
		}
		if !_KL_Mig_ArmTimer(callback, period)
				return false
		KLMigration.paused := false
		return true
}

; Stops the pass. The original ledger was never touched, so this reverts
; nothing; the next attempt simply starts over, and the idempotent conversion
; makes that converge.
KL_Mig_Cancel() {
		wasActive := KLMigration.active
		stage := KLMigration.stagePath
		if wasActive {
				_KL_Mig_Release()
				FSDelete(stage)
				try LoggerInfo("Keylogger", "At-rest migration cancelled after {1} converted row(s).",
						KLMigration.converted)
		}
		if (KLMigration.commitPending is Map) {
				commit := KLMigration.commitPending
				if !commit["published"]
						FSDelete(commit["stage"])
				KLMigration.commitPending := 0
		}
		_KL_Mig_ClearPendingMarker()
		KLMigration.syncPending := false
		KLMigration.paused := false
		_KL_Mig_ArmTimer(KL_Mig_SyncToPosture, 0)
		return wasActive
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
		if A_IsSuspended {
				KLMigration.syncPending := true
				KLMigration.paused := true
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
		KLMigration.commitPending := 0
		KLMigration.sourcePath := Keylogger.data_sql_path
		KLMigration.stagePath := Keylogger.data_sql_path . KL_MIG_STAGING_SUFFIX
		KLMigration.buffer := ""
		KLMigration.eof := false
		KLMigration.scanned := 0
		KLMigration.converted := 0
		KLMigration.stageBytesWritten := 0

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
		if schedule && !_KL_Mig_ArmTimer(KL_Mig_Tick, -KL_MIG_SLICE_INTERVAL_MS)
				return _KL_Mig_Abort("the slice timer could not be scheduled")
		return true
}

; Owns the delayed boot comparison so Suspend can disarm and later replay it.
KL_Mig_RequestPostureSync(delayMs := 1) {
		KLMigration.syncPending := true
		if A_IsSuspended {
				KLMigration.paused := true
				return false
		}
		return _KL_Mig_ArmTimer(KL_Mig_SyncToPosture, -Abs(delayMs))
}

; Brings the ledger in line with the posture now in force, and ONLY when they
; disagree: a pass rewrites the whole ledger, so running one at every launch
; would rewrite a year of history to change nothing.
; @return Boolean True when a pass was started.
KL_Mig_SyncToPosture() {
		if A_IsSuspended || KLMigration.paused {
				KLMigration.syncPending := true
				KLMigration.paused := true
				return false
		}
		KLMigration.syncPending := false
		if (!Keylogger.initialized)
				return false
		; The cipher's own flag IS the posture in force — the config loader drives it
		; at boot and the menu drives it on a toggle. Reading it here rather than the
		; settings object keeps the ledger aligned with what actually encrypts.
		want := KL_Enc_IsEnabled() ? "on" : "off"
		if (KLMigration.pendingMarker != "") {
				if (KLMigration.pendingMarker = want) {
						KL_Mig_RetryMarker()
						return false
				}
				; The pending marker is the only trustworthy description of the ledger
				; after its move succeeded. If the setting flipped, force the reverse
				; pass even when an older on-disk marker happens to equal `want`.
				return KL_Mig_Start(want = "on" ? KL_MIG_MODE_ENCRYPT : KL_MIG_MODE_DECRYPT)
		}
		if (KL_Mig_ReadMarker() = want)
				return false
		return KL_Mig_Start(want = "on" ? KL_MIG_MODE_ENCRYPT : KL_MIG_MODE_DECRYPT)
}
