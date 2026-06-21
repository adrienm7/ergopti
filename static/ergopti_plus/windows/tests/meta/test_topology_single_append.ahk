; tests/meta/test_topology_single_append.ahk

; ==============================================================================
; MODULE: Topology Single Append Meta Test
; DESCRIPTION:
; Regression guard for HIGH-05: fix-topology-double-append.
;
; KL_Topo_Tick() used to emit two identical JSONL entries for every settled
; topology event (window_state_change, window_resize, window_move,
; monitor_focus_change):
;   1. A direct KL_AppendLog(KLTopo.pending_data) at the debounce branch.
;   2. A KL_Topo_LogEvent(change_type, KLTopo.pending_data) call that builds a
;      content-identical map and calls KL_AppendLog a second time.
;
; This doubled every write to today.log and data.sql, inflating all downstream
; topology metrics by 2x (move counts, resize distributions, monitor-focus KPIs,
; virtual-desktop heuristics). The fix removes the redundant direct KL_AppendLog
; and retains the single KL_Topo_LogEvent call, which already handles the "type"
; key assignment.
;
; This test asserts that the debounce block in KL_Topo_Tick contains exactly one
; path that logs the pending event — i.e., KL_Topo_LogEvent appears and the raw
; KL_AppendLog(KLTopo.pending_data) does NOT appear inside the same block.
;
; SCOPE: source introspection of modules/keylogger/keylogger_window_topology.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================================
; =========================================================
; ======= 1/ Source scan helpers ==========================
; =========================================================
; =========================================================

; Returns the substring inside the debounce block:
;   if (KLTopo.pending_ticks >= KLTopoConst.DEBOUNCE_TICKS) { ... }
; Starts AFTER the opening brace of that if-block.
_TSA_ExtractDebounceBody(Src) {
	Marker := "if (KLTopo.pending_ticks >= KLTopoConst.DEBOUNCE_TICKS) {"
	StartPos := InStr(Src, Marker)
	if (!StartPos)
		return ""
	; Walk from the opening brace to the matching closing brace.
	BracePos := StartPos + StrLen(Marker) - 1   ; position of the opening {
	depth := 0
	i := BracePos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, BracePos + 1, i - BracePos - 1)
		}
		i++
	}
	return SubStr(Src, BracePos)
}


; =======================================================
; =======================================================
; ======= 2/ Test implementations =======================
; =======================================================
; =======================================================

_TSA_CheckSingleAppend() {
	; Move-resilient: scan the keylogger module dir via the framework helper instead
	; of a pinned keylogger_window_topology.ahk read. The debounce block's opening
	; marker is unique to that file, so the block extractor stays scoped correctly.
	Src := _DriverDirConcat("modules/keylogger")
	Assert(Src != "", "modules/keylogger/keylogger_window_topology.ahk must be readable")

	DebounceBody := _TSA_ExtractDebounceBody(Src)
	Assert(DebounceBody != "",
		'Debounce block "if (KLTopo.pending_ticks >= KLTopoConst.DEBOUNCE_TICKS) {" must be present')

	; KL_Topo_LogEvent must be the single log call inside the debounce block.
	Assert(InStr(DebounceBody, "KL_Topo_LogEvent("),
		"KL_Topo_LogEvent must be called inside the debounce block")

	; The redundant direct KL_AppendLog(KLTopo.pending_data) must be absent.
	Assert(!InStr(DebounceBody, "KL_AppendLog(KLTopo.pending_data)"),
		"KL_AppendLog(KLTopo.pending_data) must NOT appear inside the debounce block — it duplicates the KL_Topo_LogEvent write (HIGH-05 fix-topology-double-append)")

	; The redundant type-key assignment must also be absent (KL_Topo_LogEvent
	; handles it internally via its own Map construction).
	Assert(!InStr(DebounceBody, 'KLTopo.pending_data["type"] := change_type'),
		'The inline KLTopo.pending_data["type"] := change_type assignment must be removed — KL_Topo_LogEvent sets "type" itself')
}


Test("meta fix-topology-double-append: debounce block emits exactly one topology event via KL_Topo_LogEvent",
	_TSA_CheckSingleAppend)
