; modules/keylogger/keylogger_sql.ahk

; ==============================================================================
; MODULE: Keylogger - SQL Builders
; DESCRIPTION:
; Type-specific INSERT statement builders for every keylogger event kind. Mirrors the macOS sqlite_writer module.
;
; Extracted from keylogger.ahk (audit F1) and #Include'd in place by it. Pure
; definitions only - AHK resolves these symbols across the whole compilation
; unit, so the include position does not affect behaviour.
; ==============================================================================

; Only INSERT statements are emitted from AHK. They go straight into
; data.sql; no SQLite is opened on the AHK side. The launcher rebuilds
; db.sqlite from data.sql on demand.

KL_SqlStr(s) {
    if (s = "" && !IsNumber(s))
        return "''"
    s := String(s)
    s := StrReplace(s, "'", "''")
    return "'" . s . "'"
}

KL_SqlNum(n) {
    if (n = "" || !IsNumber(n))
        return "NULL"
    if (n = true)
        return "1"
    if (n = false)
        return "0"
    return String(n)
}

KL_SqlNullable(s) {
    if (s = "")
        return "NULL"
    return KL_SqlStr(s)
}

KL_SqlJson(obj) {
    if !IsSet(obj) || obj = ""
        return "'{}'"
    return KL_SqlStr(KL_JsonEncode(obj))
}

KL_AllocEventId() {
    id := Keylogger.next_event_id
    Keylogger.next_event_id := id + 1
    return id
}

; Assigns the identity before JSONL publication. Reusing an already-reserved id
; is essential for typing/output snapshots and for replay after SQL committed
; but the journal offset did not.
KL_AssignStableEventId(entry) {
	if !(entry is Map)
		throw TypeError("A keylogger event must be a Map.")
	if entry.Has("_event_id") {
		if !(entry["_event_id"] is Integer) or entry["_event_id"] <= 0
			throw ValueError("A keylogger event id must be a positive integer.")
		return entry["_event_id"]
	}
	id := KL_AllocEventId()
	entry["_event_id"] := id
	return id
}

KL_BuildInsertTyping(e, id) {
    ts := e["timestamp"]

    ; text and events_json are the only columns holding what the user literally
    ; typed, so they are the only ones encrypted; the aggregates stay in clear.
    ; A "" return with non-empty input means encryption is on but could not run —
    ; the row is dropped rather than storing the plaintext the user asked to
    ; protect. Empty input legitimately returns "" and must NOT be treated as a
    ; failure.
    rawText := KL_GetMap(e, "text", "")
    rawJson := KL_JsonEncode(KL_GetMap(e, "events", ""))
    if (rawJson = "")
        rawJson := "{}"
    encText := KL_Enc_Encrypt(Keylogger.device_id, id, rawText)
    encJson := KL_Enc_Encrypt(Keylogger.device_id, id . "j", rawJson)
    if (rawText != "" && encText = "") || (rawJson != "" && encJson = "") {
        LoggerError("Keylogger", "At-rest encryption failed - typing event {1} dropped rather than stored in clear.", id)
        return ""
    }

    return Format(
        "INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, title, url, field_role, layout, document_path, is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, mouse_distance_px, pause_before_ms, battery_level, audio_volume, wpm, text, rich_text, events_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11}, {12}, {13}, {14}, {15}, {16}, {17}, {18}, {19}, {20}, {21}, {22});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlNullable(KL_GetMap(e, "title", "")),
        KL_SqlNullable(KL_GetMap(e, "url", "")),
        KL_SqlNullable(KL_GetMap(e, "field_role", "")),
        KL_SqlNullable(KL_GetMap(e, "layout", "")),
        KL_SqlNullable(KL_GetMap(e, "document_path", "")),
        KL_SqlNum(KL_GetMap(e, "is_fullscreen", 0)),
        KL_SqlNum(KL_GetMap(e, "in_meeting", 0)),
        KL_SqlNum(KL_GetMap(e, "mouse_clicks", 0)),
        KL_SqlNum(KL_GetMap(e, "mouse_scrolls", 0)),
        KL_SqlNum(KL_GetMap(e, "mouse_distance_px", 0)),
        KL_SqlNum(KL_GetMap(e, "pause_before_ms", 0)),
        KL_SqlNum(KL_GetMap(e, "battery_level", "")),
        KL_SqlNum(KL_GetMap(e, "audio_volume", "")),
        KL_SqlNum(KL_GetMap(e, "wpm", 0)),
        KL_SqlStr(encText),
        KL_SqlNullable(KL_GetMap(e, "rich_text", "")),
        KL_SqlStr(encJson)
    )
}

KL_BuildInsertAppSwitch(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_app_switch (device_id, id, ts, date, prev_app, next_app, duration_ms) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlNullable(KL_GetMap(e, "prev_app", "")),
        KL_SqlNullable(KL_GetMap(e, "next_app", "")),
        KL_SqlNum(KL_GetMap(e, "duration_ms", 0))
    )
}

KL_BuildInsertWindowSwitch(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_window_switch (device_id, id, ts, date, app, prev_title, next_title, duration_ms) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlNullable(KL_GetMap(e, "prev_title", "")),
        KL_SqlNullable(KL_GetMap(e, "next_title", "")),
        KL_SqlNum(KL_GetMap(e, "duration_ms", 0))
    )
}

KL_BuildInsertShortcut(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_shortcut (device_id, id, ts, date, app, key) VALUES ({1}, {2}, {3}, {4}, {5}, {6});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlStr(KL_GetMap(e, "key", ""))
    )
}

KL_BuildInsertSystem(e, id) {
    ts   := e["timestamp"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "action")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "action", "")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertHotstring(e, id, kind) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_hotstring (device_id, id, ts, date, app, kind, trigger, replacement, h_type, net_saved_chars) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlStr(kind),
        KL_SqlStr(KL_GetMap(e, "trigger", "")),
        KL_SqlStr(KL_GetMap(e, "replacement", "")),
        KL_SqlNullable(KL_GetMap(e, "h_type", "")),
        KL_SqlNum(KL_GetMap(e, "net_saved_chars", ""))
    )
}

; Mirrors _builders.llm in the macOS sqlite_writer.lua sibling. `kind` is
; supplied by the caller (KL_BuildInserts), not read off the event, so the
; llm_generation / llm_suggested / llm_dismissed / llm_accepted event types
; can all funnel through one builder while writing the CHECK-constraint-
; compatible kind value ('generation'/'suggested'/'dismissed'/'accepted').
KL_LlmAccountingFields() {
    static Fields := ["prompt_tokens", "completion_tokens", "total_tokens", "est_cost_usd"]
    return Fields
}

KL_BuildInsertLlm(e, id, kind) {
    ts := e["timestamp"]
    Columns := ["device_id", "id", "ts", "date", "app", "kind", "context",
        "predictions_json", "prediction", "all_predictions_json", "chosen_index",
        "deletes", "deleted_text", "net_saved_chars", "count"]
    Values := [Keylogger._device_id_lit, id, KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")), KL_SqlStr(kind),
        KL_SqlNullable(KL_GetMap(e, "context", "")),
        KL_SqlJson(KL_GetMap(e, "predictions", "")),
        KL_SqlNullable(KL_GetMap(e, "prediction", "")),
        KL_SqlJson(KL_GetMap(e, "all_predictions", "")),
        KL_SqlNum(KL_GetMap(e, "chosen_index", "")), KL_SqlNum(KL_GetMap(e, "deletes", "")),
        KL_SqlNullable(KL_GetMap(e, "deleted_text", "")),
        KL_SqlNum(KL_GetMap(e, "net_saved_chars", "")), KL_SqlNum(KL_GetMap(e, "count", ""))]
    for Field in KL_LlmAccountingFields() {
        Columns.Push(Field)
        Values.Push(KL_SqlNum(KL_GetMap(e, Field, "")))
    }
    return "INSERT OR IGNORE INTO events_llm (" . KL_JoinArray(Columns, ", ")
        . ") VALUES (" . KL_JoinArray(Values, ", ") . ");"
}

KL_BuildInsertSession(e, id, kind) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_session (device_id, id, ts, date, kind, duration_ms) VALUES ({1}, {2}, {3}, {4}, {5}, {6});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(kind),
        KL_SqlNum(KL_GetMap(e, "duration_ms", ""))
    )
}

KL_GetMap(m, key, default := "") {
    if (m is Map && m.Has(key))
        return m[key]
    return default
}

; Wraps the typing builder's result: an empty string means at-rest encryption
; failed, and the row is dropped (empty list) rather than stored in clear.
KL_TypingRow(sql) {
    return (sql = "") ? [] : [sql]
}

KL_BuildInserts(entry) {
    EventType := entry["type"]
	; Output transactions reserve ids at their real screen-order boundary. A
	; detached typing flush can publish after the accepted completion that
	; interrupted it, but its lower reserved id still replays first. Every other
	; producer receives the same stable identity at KL_AppendLog publication.
	id := KL_AssignStableEventId(entry)
    switch EventType {
        case "typing":              return KL_TypingRow(KL_BuildInsertTyping(entry, id))
        case "app_switch":          return [KL_BuildInsertAppSwitch(entry, id)]
        case "window_switch":       return [KL_BuildInsertWindowSwitch(entry, id)]
        case "shortcut":            return [KL_BuildInsertShortcut(entry, id)]
        case "system_event":        return [KL_BuildInsertSystem(entry, id)]
        case "hotstring":           return [KL_BuildInsertHotstring(entry, id, "fired")]
        case "hotstring_suggested": return [KL_BuildInsertHotstring(entry, id, "suggested")]
        case "hotstring_dismissed":          return [KL_BuildInsertHotstring(entry, id, "dismissed")]
        case "hotstring_near_miss", "manual_typed_known_trigger":   return [KL_BuildInsertHotstring(entry, id, EventType)]
        case "llm_generation":      return [KL_BuildInsertLlm(entry, id, "generation")]
        ; Routed to events_system, NOT events_llm: that table's CHECK constraint
        ; does not admit a failure kind, so the naive route would trade a silent
        ; drop for a rejected insert. This mirrors the macOS twin. Without the
        ; case the event fell through to the "unknown type — skip" default, so
        ; the one event class whose entire purpose is to answer "are predictions
        ; silently dropping?" was itself silently dropped: written to today.log,
        ; never present in data.sql, invisible on the dashboard.
        case "llm_generation_failed": return [KL_BuildInsertSystem(entry, id)]
        case "llm_suggested":       return [KL_BuildInsertLlm(entry, id, "suggested")]
        case "llm_dismissed":       return [KL_BuildInsertLlm(entry, id, "dismissed")]
        case "llm_accepted":        return [KL_BuildInsertLlm(entry, id, "accepted")]
        case "session_start":       return [KL_BuildInsertSession(entry, id, "session_start")]
        case "session_end":         return [KL_BuildInsertSession(entry, id, "session_end")]
        case "idle_start":          return [KL_BuildInsertSession(entry, id, "idle_start")]
        case "idle_end":            return [KL_BuildInsertSession(entry, id, "idle_end")]
        case "ergo_event":              return [KL_BuildInsertErgoEvent(entry, id)]
        case "window_resize", "window_move", "window_state_change", "monitor_focus_change",
             "virtual_desktop_switch": return [KL_BuildInsertWindowTopoEvent(entry, id)]
        case "mouse_click", "mouse_drag", "mouse_scroll",
             "mouse_idle_park":     return [KL_BuildInsertMouseEvent(entry, id)]
        case "volume_change", "screen_recording_start",
             "screen_recording_end": return [KL_BuildInsertAvEvent(entry, id)]
        case "network_change", "internet_up", "internet_down", "vpn_connected",
             "vpn_disconnected": return [KL_BuildInsertNetworkEvent(entry, id)]
        case "clipboard_copy", "clipboard_paste",
             "paste_burst": return [KL_BuildInsertClipboardEvent(entry, id)]
        case "roi_snapshot", "new_trigger_candidate",
             "trigger_halflife": return [KL_BuildInsertRoiEvent(entry, id)]
    }
    ; Unknown type — silently skip; future schemas may handle it on replay.
    return []
}

KL_BuildInsertWindowTopoEvent(e, id) {
    ts   := e["timestamp"]
    EventType := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_window_topo (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertErgoEvent(e, id) {
    ts   := e["timestamp"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "kind" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_ergo (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "kind", "")),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertMouseEvent(e, id) {
    ts   := e["timestamp"]
    EventType := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_mouse (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertAvEvent(e, id) {
    ts   := e["timestamp"]
    EventType := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_av (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertNetworkEvent(e, id) {
    ts   := e["timestamp"]
    EventType := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_network (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertClipboardEvent(e, id) {
    ts   := e["timestamp"]
    EventType := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_clipboard (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertRoiEvent(e, id) {
    ts   := e["timestamp"]
    EventType := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_roi (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}
