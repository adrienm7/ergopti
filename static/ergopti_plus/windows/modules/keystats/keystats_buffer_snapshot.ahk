; modules/keystats/keystats_buffer_snapshot.ahk

; Detach one typing payload under its caller-owned RAM transaction. Context
; preparation can stage it without publishing or advancing an attempted flush.
#Requires AutoHotkey v2.0

_KL_DetachBufferSnapshot() {
	previous_critical := Critical("On")
	try {
		if (Keystats.buffer_events.Length = 0
			&& Keystats.session_clicks = 0
			&& Keystats.session_scrolls = 0 && Keystats.mouse_distance = 0)
			return false
		snap_events := Keystats.buffer_events
		snap_text := Keystats.buffer_text
		snap_rich := Keystats.rich_chunks
		snap_clicks := Keystats.session_clicks
		snap_scrolls := Keystats.session_scrolls
		snap_dist := Keystats.mouse_distance
		snap_last_time := Keystats.last_time
		snap_last_flush_time := Keystats.last_flush_time
		Snapshot := {
			EventId: KL_AllocEventId(),
			Events: snap_events,
			Text: snap_text,
			RichChunks: snap_rich,
			Clicks: snap_clicks,
			Scrolls: snap_scrolls,
			Distance: snap_dist,
			LastTime: snap_last_time,
			LastFlushTime: snap_last_flush_time,
			Pause: (snap_events.Length > 0) ? snap_events[1][2] : 0,
			App: Keystats.session_app,
			Title: Keystats.session_title,
			Url: Keystats.session_url,
			FieldRole: Keystats.session_field_role,
			Layout: Keystats.session_layout
		}
		Keystats.buffer_events    := []
		Keystats.buffer_text := ""
		Keystats.rich_chunks := []
		Keystats.last_time := 0
		Keystats.session_clicks := 0
		Keystats.session_scrolls := 0
		Keystats.mouse_distance := 0
		return Snapshot
	} finally Critical(previous_critical)
}
