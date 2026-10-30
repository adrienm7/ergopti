; modules/keystats/keystats_sql.ahk

; ==============================================================================
; MODULE: Keystats - SQL Builders
; DESCRIPTION:
; Type-specific INSERT statement builders for every keystats event kind. Mirrors the macOS sqlite_writer module.
; A statement the three drivers share is rendered from the catalogue
; (_shared/data/db/queries.sql) by name; the others are Windows spellings.
;
; Extracted from keystats.ahk (audit F1) and #Include'd in place by it. Pure
; definitions only - AHK resolves these symbols across the whole compilation
; unit, so the include position does not affect behaviour.
; ==============================================================================

#Include keystats_hotstring_units.ahk
#Include ../../_generated/keystats_queries.ahk

; Only INSERT statements are emitted from AHK. They go straight into
; data.sql; no SQLite is opened on the AHK side. The launcher rebuilds
; db.sqlite from data.sql on demand.

; Delegates to the driver's one literal encoder, which keeps NUL and CR exact.
KL_SqlStr(s) {
    return SQLite_Q(s)
}

KL_SqlJson(obj) {
    if !IsSet(obj) || obj = ""
        return "'{}'"
    return KL_SqlStr(KL_JsonEncode(obj))
}

KL_AllocEventId() {
    id := Keystats.next_event_id
    Keystats.next_event_id := id + 1
    return id
}

; Assigns the identity before JSONL publication. Reusing an already-reserved id
; is essential for typing/output snapshots and for replay after SQL committed
; but the journal offset did not.
KL_AssignStableEventId(entry) {
	if !(entry is Map)
		throw TypeError("A keystats event must be a Map.")
	if entry.Has("_event_id") {
		if !(entry["_event_id"] is Integer) or entry["_event_id"] <= 0
			throw ValueError("A keystats event id must be a positive integer.")
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

; The four columns every event shares, for a catalogue statement's typed slots.
; @param e {Map} Journal entry.
; @param id {Integer} Stable event id.
; @returns {Map} Slot values, extended by the caller.
KL_EventSlots(e, id) {
    ts := String(e["timestamp"])
    return Map("device_id", Keystats.device_id, "id", id, "ts", ts, "date", SubStr(ts, 1, 10))
}

; An empty text is an absent value: a nullable slot renders it as NULL.
KL_SlotNullableText(Slots, Name, Value) {
    if (Value != "")
        Slots[Name] := String(Value)
}

; A journal number that is empty or not a number is an absent value.
KL_SlotNullableNumber(Slots, Name, Value) {
    if (Value != "" && IsNumber(Value))
        Slots[Name] := Value
}

; A slot the catalogue declares NOT NULL takes 0 for a duration the journal lost.
KL_NumberOrZero(Value) {
    return (Value != "" && IsNumber(Value)) ? Value : 0
}

KL_BuildInsertAppSwitch(e, id) {
    Slots := KL_EventSlots(e, id)
    KL_SlotNullableText(Slots, "prev_app", KL_GetMap(e, "prev_app", ""))
    KL_SlotNullableText(Slots, "next_app", KL_GetMap(e, "next_app", ""))
    Slots["duration_ms"] := KL_NumberOrZero(KL_GetMap(e, "duration_ms", 0))
    return KeystatsQuery("events.app_switch", Slots)
}

KL_BuildInsertWindowSwitch(e, id) {
    Slots := KL_EventSlots(e, id)
    Slots["app"] := String(KL_GetMap(e, "app", "Unknown"))
    KL_SlotNullableText(Slots, "prev_title", KL_GetMap(e, "prev_title", ""))
    KL_SlotNullableText(Slots, "next_title", KL_GetMap(e, "next_title", ""))
    Slots["duration_ms"] := KL_NumberOrZero(KL_GetMap(e, "duration_ms", 0))
    return KeystatsQuery("events.window_switch", Slots)
}

KL_BuildInsertShortcut(e, id) {
    Slots := KL_EventSlots(e, id)
    Slots["app"] := String(KL_GetMap(e, "app", "Unknown"))
    Slots["key"] := String(KL_GetMap(e, "key", ""))
    return KeystatsQuery("events.shortcut", Slots)
}

KL_BuildInsertSystem(e, id) {
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "action")
            meta[k] := v
    }
    Slots := KL_EventSlots(e, id)
    Slots["action"] := String(KL_GetMap(e, "action", ""))
    Slots["metadata_json"] := KL_JsonEncode(meta)
    return KeystatsQuery("events.system", Slots)
}

KL_BuildInsertHotstring(e, id, kind) {
    Slots := KL_EventSlots(e, id)
    Slots["app"] := String(KL_GetMap(e, "app", "Unknown"))
    Slots["kind"] := String(kind)
    Slots["trigger"] := String(KL_GetMap(e, "trigger", ""))
    Slots["replacement"] := String(KL_GetMap(e, "replacement", ""))
    KL_SlotNullableText(Slots, "h_type", KL_GetMap(e, "h_type", ""))
    KL_SlotNullableNumber(Slots, "net_saved_chars", KL_GetMap(e, "net_saved_chars", ""))
    Sql := KeystatsQuery("events.hotstring", Slots)
    return Sql . (kind = "fired" ? KLHotstringUnits.DeclarationSql(Keystats.device_id) : "")
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

; A missing predictions list stores the '{}' this driver has always stored.
KL_JsonOrEmptyObject(Value) {
    return (Value = "") ? "{}" : KL_JsonEncode(Value)
}

KL_BuildInsertLlm(e, id, kind) {
    Slots := KL_EventSlots(e, id)
    Slots["app"] := String(KL_GetMap(e, "app", "Unknown"))
    Slots["kind"] := String(kind)
    KL_SlotNullableText(Slots, "context", KL_GetMap(e, "context", ""))
    KL_SlotNullableText(Slots, "prediction", KL_GetMap(e, "prediction", ""))
    KL_SlotNullableText(Slots, "deleted_text", KL_GetMap(e, "deleted_text", ""))
    Slots["predictions_json"] := KL_JsonOrEmptyObject(KL_GetMap(e, "predictions", ""))
    Slots["all_predictions_json"] := KL_JsonOrEmptyObject(KL_GetMap(e, "all_predictions", ""))
    for Name in ["chosen_index", "deletes", "net_saved_chars", "count"]
        KL_SlotNullableNumber(Slots, Name, KL_GetMap(e, Name, ""))
    for Field in KL_LlmAccountingFields()
        KL_SlotNullableNumber(Slots, Field, KL_GetMap(e, Field, ""))
    return KeystatsQuery("events.llm", Slots)
}

KL_BuildInsertSession(e, id, kind) {
    Slots := KL_EventSlots(e, id)
    Slots["kind"] := String(kind)
    KL_SlotNullableNumber(Slots, "duration_ms", KL_GetMap(e, "duration_ms", ""))
    return KeystatsQuery("events.session", Slots)
}

KL_GetMap(m, key, default := "") {
    if (m is Map && m.Has(key))
        return m[key]
    return default
}

; An empty builder result is a refused conversion, not an absent event. Abort
; the ingest batch so its journal offset cannot acknowledge an omitted row.
KL_TypingRow(sql) {
    if (sql = "")
        throw Error("Typing SQL conversion failed; journal retry required.")
    return [sql]
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
        Keystats._device_id_lit, id,
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
        Keystats._device_id_lit, id,
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
        Keystats._device_id_lit, id,
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
        Keystats._device_id_lit, id,
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
        Keystats._device_id_lit, id,
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
        Keystats._device_id_lit, id,
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
        Keystats._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(EventType),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}
