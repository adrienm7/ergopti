#Requires AutoHotkey v2.0
#SingleInstance Off
; Source-backed Windows reproduction, audited SHA 213d65af24d2aa4845ba47743c9bab6787b61964.
; Real cipher/JSON/query code and exact SQL/migration function extractions.
; Native crypto ports are inert recording boundaries; no user files, clipboard,
; registry, secret store or actual encryption provider are accessed.
#Include /workspace/ergopti/static/ergopti_plus/windows/infra/json.ahk
#Include /workspace/ergopti/static/ergopti_plus/windows/modules/keystats/keystats_json.ahk
#Include /workspace/ergopti/static/ergopti_plus/windows/_generated/keystats_queries.ahk
#Include /workspace/ergopti/static/ergopti_plus/windows/modules/keystats/keystats_text_cipher.ahk

KL_BuildInsertTyping(e, id) {
    ts := e["timestamp"]

    ; text and events_json are the only columns holding what the user literally
    ; typed, so they are the only ones encrypted; the aggregates stay in clear.
    ; A "" return with non-empty input means encryption is on but could not run —
    ; conversion is refused rather than storing the plaintext the user asked to
    ; protect. Empty input legitimately returns "" and must NOT be treated as a
    ; failure.
    rawText := KL_GetMap(e, "text", "")
    rawJson := KL_JsonEncode(KL_GetMap(e, "events", ""))
    if (rawJson = "")
        rawJson := "{}"
    encText := KL_Enc_Encrypt(Keystats.device_id, id, rawText)
    encJson := KL_Enc_Encrypt(Keystats.device_id, id . "j", rawJson)
    if (rawText != "" && encText = "") || (rawJson != "" && encJson = "") {
        LoggerError("Keystats", "At-rest encryption failed - typing event {1} requires conversion retry.", id)
        return ""
    }

    Slots := KL_EventSlots(e, id)
    Slots["app"] := String(KL_GetMap(e, "app", "Unknown"))
    for Name in ["app_category", "title", "url", "field_role", "layout", "document_path", "rich_text"]
        KL_SlotNullableText(Slots, Name, KL_GetMap(e, Name, ""))
    for Name in ["is_fullscreen", "in_meeting", "mouse_clicks", "mouse_scrolls", "mouse_distance_px"]
        Slots[Name] := KL_NumberOrZero(KL_GetMap(e, Name, 0))
    KL_SlotNullableNumber(Slots, "pause_before_ms", KL_GetMap(e, "pause_before_ms", 0))
    KL_SlotNullableNumber(Slots, "battery_level", KL_GetMap(e, "battery_level", ""))
    KL_SlotNullableNumber(Slots, "audio_volume", KL_GetMap(e, "audio_volume", ""))
    KL_SlotNullableNumber(Slots, "wpm", KL_GetMap(e, "wpm", 0))
    Slots["text"] := String(encText)
    Slots["events_json"] := String(encJson)
    return KeystatsQuery("events.typing", Slots)
}

KL_GetMap(m, key, default := "") {
    if (m is Map && m.Has(key))
        return m[key]
    return default
}

KL_EventSlots(e, id) {
    ts := String(e["timestamp"])
    return Map("device_id", Keystats.device_id, "id", id, "ts", ts, "date", SubStr(ts, 1, 10))
}

KL_SlotNullableText(Slots, Name, Value) {
    if (Value != "")
        Slots[Name] := String(Value)
}

KL_SlotNullableNumber(Slots, Name, Value) {
    if (Value != "" && IsNumber(Value))
        Slots[Name] := Value
}

KL_NumberOrZero(Value) {
    return (Value != "" && IsNumber(Value)) ? Value : 0
}

KL_SqlStr(s) {
    return SQLite_Q(s)
}

SQLite_Q(s) {
		; RegExReplace walks the stored length, past an embedded NUL.
		s := RegExReplace(String(s), "'", "''")
		s := RegExReplace(s, "\r", "'||char(13)||'")
		s := RegExReplace(s, "\x00", "'||char(0)||'")
		return "'" . s . "'"
}

_KL_Mig_StatementStart(s) {
		RegExMatch(s, "s)\A(?:[\x00\x09-\x0D\x20]++|--[^\n]*+(?:\n|\z)"
				. "|/\*(?:[^*]++|\*(?!/))*+(?:\*/|\z))*+", &Prefix)
		return Prefix.Len[0] + 1
}

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

_KL_Mig_IndexOf(columns, name) {
		for index, column in columns {
				if (Trim(column) = name)
						return index
		}
		return 0
}

_KL_Mig_Unquote(literal) {
		if !(literal is String) || RegExMatch(literal, "[\x00\r]")
				throw ValueError("Migration requires a canonical SQLite text literal.")
		; Derive the two joins from their one production encoder. Each expression
		; is two empty quoted segments around the exact control-byte join.
		static nulExpression := SQLite_Q(Chr(0)), crExpression := SQLite_Q(Chr(13))
		static nulJoin := SubStr(nulExpression, 3, StrLen(nulExpression) - 4)
		static crJoin := SubStr(crExpression, 3, StrLen(crExpression) - 4)
		position := 1, length := StrLen(literal), value := ""
		loop {
				if (SubStr(literal, position, 1) != "'")
						throw ValueError("Migration requires a quoted SQLite text segment.")
				start := position + 1
				finish := InStr(literal, "'", true, start)
				; A doubled quote belongs to this segment, not to a control join.
				while finish && SubStr(literal, finish + 1, 1) = "'"
						finish := InStr(literal, "'", true, finish + 2)
				if !finish
						throw ValueError("Migration cannot decode an unfinished SQLite text segment.")
				value .= StrReplace(SubStr(literal, start, finish - start), "''", "'")
				position := finish + 1
				if position > length
						return value
				if (SubStr(literal, position, StrLen(nulJoin)) == nulJoin) {
						value .= Chr(0)
						position += StrLen(nulJoin)
				} else if (SubStr(literal, position, StrLen(crJoin)) == crJoin) {
						value .= Chr(13)
						position += StrLen(crJoin)
				} else {
						throw ValueError("Migration cannot decode an unsupported SQLite text expression.")
				}
		}
}

KL_Mig_ConvertStatement(sql, deviceIdLit, mode) {
		unchanged := Map("ok", true, "sql", sql, "changed", false)
		failed    := Map("ok", false, "sql", sql, "changed", false)

		markerPos := _KL_Mig_StatementStart(sql)
		if (SubStr(sql, markerPos, StrLen(KL_MIG_INSERT_MARKER)) != KL_MIG_INSERT_MARKER)
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
				; SQLite_Q carries NUL as a join, never inside the SQL statement.
				if RegExMatch(raw, "\x00")
						return failed
				; NULL and numeric scalars carry no text to encrypt. Every other
				; expression must decode exactly or the original ledger stays intact.
				if (raw = "NULL" || IsNumber(raw))
						continue
				try value := _KL_Mig_Unquote(raw)
				catch
						return failed
				if (StrLen(value) = 0)
						continue

				wrapped := KL_Enc_IsEncrypted(value)
				if (mode = KL_MIG_MODE_ENCRYPT) {
						; Already an envelope: wrapping it again would make it undecryptable
						; in one pass. This is what makes a restarted migration converge.
						if (wrapped)
								continue
						converted := KL_Enc_Encrypt(Keystats.device_id, rowId . spec[2], value)
						; KL_Enc_Encrypt returns the plaintext untouched when the toggle is
						; off, so only the envelope marker proves anything happened.
						if (StrLen(converted) = 0 || !KL_Enc_IsEncrypted(converted))
								return failed
				} else {
						if (!wrapped)
								continue
						converted := KL_Enc_Decrypt(value)
						; An envelope never wraps an empty value, so an empty result means the
						; decryption failed. Writing it would erase the row for good.
						if (StrLen(converted) = 0)
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

global KL_MIG_INSERT_MARKER := "INSERT OR IGNORE INTO events_typing "

global KL_MIG_COLUMNS := [["text", ""], ["events_json", "j"]]

global KL_MIG_MODE_ENCRYPT := "encrypt"

global KL_MIG_MODE_DECRYPT := "decrypt"

global Keystats := {device_id: "fixture-device"}
global NativeEncryptCalls := 0
global KL_ENC_KeyBuffer := Buffer(32, 0)
KL_Enc_SetEnabled(true)
for Index, Text in ["ordinary synthetic fixture", "ergopti-enc-v1:SENTINEL-PRIVATE-CONTENT"] {
    Before := NativeEncryptCalls
    Entry := Map("type", "typing", "timestamp", "2026-11-04 12:00:00.000", "text", Text, "events", [])
    Sql := KL_BuildInsertTyping(Entry, Index)
    Retained := InStr(Sql, Text, true) > 0
    Print("case=" Index " literal_in_sql=" Retained " native_encrypt_calls=" (NativeEncryptCalls-Before))
    Check(Retained == (Index == 2), "SQL literal disposition")
    Check(NativeEncryptCalls-Before == (Index==1 ? 2 : 1), "native text-vs-JSON encryption count")
    if Index == 2 {
        ConvertedOn := KL_Mig_ConvertStatement(Sql, "'fixture-device'", KL_MIG_MODE_ENCRYPT)
        ConvertedOff := KL_Mig_ConvertStatement(Sql, "'fixture-device'", KL_MIG_MODE_DECRYPT)
        Print("encrypt migration ok=" ConvertedOn["ok"] " changed=" ConvertedOn["changed"])
        Print("decrypt migration ok=" ConvertedOff["ok"])
        Check(ConvertedOn["ok"] && !ConvertedOn["changed"], "marker literal bypasses encrypt migration")
        Check(!ConvertedOff["ok"], "marker literal refuses decrypt migration")
        Check(KL_Enc_Decrypt(Text) == "", "Windows malformed prefix decrypt returns empty")
    }
}
Print("PASS: reproduced current prefix-collision defect using real SQL/cipher/migration owners; native crypto mocked.")
ExitApp(0)
Print(Message) {
    FileAppend(Message "`n", "*")
}
Check(Ok, Label) {
    if !Ok
        throw Error("probe failed: " Label)
}
LoggerDebug(Args*) {
}
LoggerError(Args*) {
}
LoggerWarn(Args*) {
}
CryptoSha256(Data) {
    return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
CryptoPbkdf2Sha256(Args*) {
    throw Error("unexpected PBKDF2: fixture installs only synthetic cached bytes")
}
CryptoAesCbc(Key, Iv, Ptr, Size, Encrypt) {
    global NativeEncryptCalls
    if !Encrypt
        throw Error("unexpected native decrypt: malformed prefix must refuse before crypto")
    NativeEncryptCalls += 1
    Bytes := Buffer(16, 65)
    Bytes.UsedSize := 16
    return Bytes
}
CryptoBase64Encode(Bytes) {
    return "QUFBQUFBQUFBQUFBQUFBQQ=="
}
CryptoBase64Decode(Text) {
    throw Error("unexpected native base64 decode")
}
