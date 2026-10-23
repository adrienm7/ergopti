; modules/keystats/keystats_reader_frames.ahk

; ==============================================================================
; MODULE: Keystats Reader — Trusted Ledger Frames
; DESCRIPTION:
; Index canonical append-only ledgers from BOF before reading them backward.
; SQL literals may contain whole fake batch headers and COMMIT lines. SQLite's
; own completeness lexer distinguishes these from real framing boundaries.
;
; CONTRACT:
; Producers emit comments, PRAGMA, BEGIN, INSERT and COMMIT, never CREATE
; TRIGGER. Batch headers occur only between transactions; INSERT builders
; put line breaks only inside quoted values, never in the surrounding SQL.
; Each probe ends at a physical line boundary: line comments and doubled
; delimiters cannot straddle a probe boundary. The six
; states below belong to SQLite, rather than a second AHK SQL tokenizer.
;
; COST:
; One additional forward source read precedes newest-first replay. Each byte
; enters at most six native completeness probes. Frames use O(read chunks)
; memory; only an incomplete physical line is carried, with a fixed bound
; plus one read chunk while locating its next LF.
; Source receipts are checked on every read, including the final receipt.
; ==============================================================================

#Requires AutoHotkey v2.0+

; Each frame is [start byte, end byte, first trusted header byte or -1]. Replay
; reads exactly these spans, so one header per frame also survives tail trims
; and a checkpoint whose resume offset cuts a frame at that header.
_KLR_RebuildIndex(State, Ledger) {
	Limit := Ledger["end"]
	Index := Map("frames", [], "lexical", 1, "commit", 0,
		"read_bytes", 0, "probe_calls", 0, "probe_bytes", 0)
	try LoggerStart("KLReader", "Indexing {1} ledger byte(s) before newest-first metrics replay.", Limit)
	Pending := Buffer(0)
	Used := 0
	Cursor := 0
	while Cursor < Limit {
		Count := Min(KLRRebuild.chunk_bytes, Limit - Cursor)
		if Count <= 0
			throw KLRRebuildRefusal("the ledger frame read size must be positive")
		Read := _KLR_RebuildReadBytes(Ledger, Cursor, Count)
		Buf := Read["buffer"]
		Required := Used + Count
		; The next chunk may close a bounded carry at its first byte. Bound
		; the remaining incomplete line after locating LF, not this sum.
		if Pending.Size < Required
			Pending.Size := Min(KLRRebuildConst.MAX_FRAME_BYTES + Count, Max(Required, Max(1, Pending.Size * 2)))
		FSBufferMove(Pending.Ptr + Used, Buf, Count)
		Used := Required
		Cursor += Count
		Index["read_bytes"] += Count
		; Only the new chunk is searched. Initial continuation bytes cannot
		; contain LF; decode a valid prefix to recover its exact UTF-8 offset.
		Skip := 0
		while Skip < Count && (NumGet(Buf, Skip, "UChar") & 0xC0) = 0x80
			Skip += 1
		Text := Count > Skip ? StrGet(Buf.Ptr + Skip, Count - Skip, "UTF-8") : ""
		LastLf := InStr(Text, "`n", true, -1)
		ThroughLf := LastLf ? Skip + StrPut(SubStr(Text, 1, LastLf), "UTF-8") - 1 : 0
		Complete := ThroughLf ? Used - Count + ThroughLf : 0
		if Cursor = Limit
			Complete := Used
		if Complete {
			Start := Cursor - Used
			_KLR_RebuildFrameScan(StrGet(Pending, -Complete, "UTF-8"), Start, Start + Complete, Index)
			Used -= Complete
			if Used
				FSBufferMove(Pending, Pending.Ptr + Complete, Used)
		}
		if Used > KLRRebuildConst.MAX_FRAME_BYTES
			throw KLRRebuildRefusal("a ledger incomplete physical line exceeds the frame carry bound")
		_KLR_RebuildIndexNotify(State, Ledger, Index, Limit)
		; This is an explicit indexing phase, not an unbounded synchronous
		; SQLite replay. The worker still pumps messages after every read.
		Sleep(-1)
	}
	; A callback or writer could replace the source after the final read.
	_KLR_RebuildReadBytes(Ledger, Limit, 0)
	End := Index["commit"]
	Frames := Index["frames"]
	while Frames.Length && Frames[Frames.Length][1] >= End
		Frames.Pop()
	if Frames.Length {
		Last := Frames[Frames.Length]
		Last[2] := End
		if Last[3] >= End
			Last[3] := -1
	}
	Ledger["end"] := End
	Ledger["cursor"] := Min(Ledger["cursor"], End)
	Ledger["trimmed"] := true
	Ledger["frames"] := Frames
	Ledger["frame_cursor"] := Frames.Length
	Ledger["finished"] := Ledger["cursor"] = 0
	try LoggerSuccess("KLReader", "Indexed {1} ledger byte(s) into {2} replay frame(s).", Index["read_bytes"], Frames.Length)
}

; Scan complete physical lines. The final source fragment gets a virtual LF
; only for lexical probing; source offsets always exclude that virtual byte.
_KLR_RebuildFrameScan(Text, Start, End, Index) {
	Pattern := "m)^(\Q" . SubStr(KLRRebuildConst.BATCH_MARKER, 2) . "\E[^\n]*(?:\n|$)|COMMIT;[ \t]*(?:\n|$))"
	Position := 1
	Search := 1
	ByteCursor := Start
	First := -1
	while RegExMatch(Text, Pattern, &Match, Search) {
		Segment := SubStr(Text, Position, Match.Pos - Position)
		ByteCursor += _KLR_RebuildFrameState(Segment, Index)
		if Index["lexical"] = 1 {
			if SubStr(Match[0], 1, 2) = "--" {
				if First < 0
					First := ByteCursor
			} else
				Index["commit"] := ByteCursor + StrPut(Match[0], "UTF-8") - 1
		}
		; Keep the candidate in the next lexical segment: quoted fake header
		; lines must still affect SQLite's lexer exactly once.
		Position := Match.Pos
		Search := Match.Pos + Match.Len
	}
	Rest := SubStr(Text, Position)
	_KLR_RebuildFrameState(Rest . (SubStr(Rest, -1) = "`n" ? "" : "`n"), Index)
	Index["frames"].Push([Start, End, First])
}

; Native completeness probes recover the lexical state at a line boundary.
; The normal probe goes first, so ordinary ledgers require one native scan.
; A CREATE TRIGGER body is outside the producer contract and is refused rather
; than guessed; words resembling it inside captured text remain ordinary data.
; @returns {Integer} UTF-8 bytes in Text, excluding the synthetic state prefix.
_KLR_RebuildFrameState(Text, Index) {
	static Prefixes := ["", "'", '"', Chr(96), "[", "/*"]
	static Closers := [";", "';", '";', Chr(96) . ";", "];", "*/;"]
	Prefix := Prefixes[Index["lexical"]]
	Size := StrPut(Prefix . Text, "UTF-8") - 1
	Buf := Buffer(Size + 4, 0)
	StrPut(Prefix . Text, Buf, "UTF-8")
	for State, Closer in Closers {
		StrPut(Closer, Buf.Ptr + Size, 4, "UTF-8")
		Index["probe_calls"] += 1
		Index["probe_bytes"] += Size + StrLen(Closer)
		if SQLiteNativeIsComplete(Buf) {
			Index["lexical"] := State
			return Size - StrLen(Prefix)
		}
	}
	throw KLRRebuildRefusal("a ledger is outside the canonical statement framing contract")
}

; Index observations are deliberately separate from completed rollup rounds.
; They carry no database handle and never sample the injectable replay clock.
_KLR_RebuildIndexNotify(State, Ledger, Index, Limit) {
	if !HasMethod(KLRRebuild.index_observer, "Call")
		return
	KLRRebuild.index_observer.Call(Map("final", false, "phase", "indexing",
		"total_bytes", _KLR_RebuildTotalBytes(State), "done_bytes", _KLR_RebuildDoneBytes(State), "run_bytes", 0,
		"elapsed_ms", 0, "oldest_complete", State["oldest_complete"], "path", Ledger["path"],
		"indexed_bytes", Index["read_bytes"], "index_total_bytes", Limit,
		"frame_count", Index["frames"].Length, "probe_calls", Index["probe_calls"], "probe_bytes", Index["probe_bytes"]))
}
