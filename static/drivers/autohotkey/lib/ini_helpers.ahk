; static/drivers/autohotkey/lib/ini_helpers.ahk

; ==============================================================================
; MODULE: INI Helpers
; DESCRIPTION:
; Pure helpers for reading the ErgoptiPlus configuration file. Extracted from
; ErgoptiPlus.ahk so they can be ``#Include``-d from the test runner without
; bootstrapping the rest of the driver.
;
; FEATURES & RATIONALE:
; 1. ``ParseIniFile`` reads the entire file once into a nested Map so that
;    repeated lookups via ``IniCacheGet`` are O(1) — at startup the original
;    code did ~475 ``IniRead`` calls (one ``FileOpen`` each).
; 2. ``IniCacheGet`` exposes a sentinel-based « value or default » lookup;
;    the underscore sentinel is the documented "key absent" marker so callers
;    can distinguish a real empty-string value from a missing entry.
; 3. ``ResolveConfigPath`` centralises the « expand environment + fall back to
;    the bundled default » logic that several config callers used to duplicate.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Parser and accessors =======
; ============================================
; ============================================

; Read the entire INI file into Map[Section][Key]=Value. Missing files return
; an empty Map so callers can rely on ``Has`` checks without a prior
; ``FileExist``. Lines without an equals sign and lines outside any section
; are silently skipped, mirroring the behaviour of the Win32 INI APIs.
ParseIniFile(Path) {
	Sections := Map()
	if !FileExist(Path) {
		return Sections
	}
	CurrentSection := ""
	loop read Path {
		Line := Trim(A_LoopReadLine)
		if (SubStr(Line, 1, 1) == "[") {
			; Section header: [SectionName]
			CurrentSection := SubStr(Line, 2, StrLen(Line) - 2)
			if !Sections.Has(CurrentSection) {
				Sections[CurrentSection] := Map()
			}
		} else if (CurrentSection != "" and InStr(Line, "=")) {
			EqPos := InStr(Line, "=")
			Key := Trim(SubStr(Line, 1, EqPos - 1))
			Val := SubStr(Line, EqPos + 1)
			Sections[CurrentSection][Key] := Val
		}
	}
	return Sections
}

; Look up Section/Key in a parsed cache. Returns ``Default`` (defaulting to
; the underscore sentinel) when either the section or the key is absent.
; Callers compare against ``"_"`` to detect missing entries cheaply.
IniCacheGet(Cache, Section, Key, Default := "_") {
	if Cache.Has(Section) and Cache[Section].Has(Key) {
		return Cache[Section][Key]
	}
	return Default
}

; Resolve a configured path: trim whitespace, treat empty / underscore as
; "use the default", otherwise return the trimmed value. Centralised so the
; semantics of "blank ⇒ default" are honoured everywhere.
ResolveConfigPath(RawValue, DefaultPath) {
	Trimmed := Trim(RawValue)
	if (Trimmed == "" or Trimmed == "_") {
		return DefaultPath
	}
	return Trimmed
}




; ==============================================
; ==============================================
; ======= 2/ Batch writer =======
; ==============================================
; ==============================================

; Apply a batch of (Section, Key, Value) updates to an INI file in a single
; read-modify-write cycle. ``Updates`` is an Array of ``{Section, Key, Value}``
; objects. Preserves every line we do not touch (comments, blank lines, key
; ordering) by rewriting the file line-by-line; new keys are appended to the
; end of their section, new sections are appended to the end of the file.
;
; Replacing 50+ sequential ``IniWrite`` calls with one ``IniBatchWrite`` goes
; from 50+ FileOpen/Write/Close round-trips through Win32
; ``WritePrivateProfileString`` to exactly two (one read, one write).
IniBatchWrite(Path, Updates) {
	if Updates.Length == 0 {
		return true
	}

	; Load existing lines (or synthesise an empty file).
	Lines := []
	if FileExist(Path) {
		loop read Path {
			Lines.Push(A_LoopReadLine)
		}
	}

	; Bucket the updates by section so we can apply them with one pass over
	; each section. ``Pending[Section]`` maps Key -> Value for unmatched keys.
	Pending := Map()
	for _, U in Updates {
		Sec := U.Section
		if !Pending.Has(Sec) {
			Pending[Sec] := Map()
		}
		Pending[Sec][U.Key] := U.Value
	}

	; Walk the file tracking the current section. Replace existing keys in
	; place; at the end of each section, flush any remaining pending keys.
	Out := []
	CurrentSection := ""
	SectionEndIndex := Map()  ; SectionName -> index in Out where a blank line was last emitted
	idx := 0
	for _, Line in Lines {
		Trimmed := Trim(Line)
		if (SubStr(Trimmed, 1, 1) == "[" and SubStr(Trimmed, -1) == "]") {
			; Entering a new section — flush pending keys for the previous one.
			_IniFlushPending(Out, CurrentSection, Pending)
			CurrentSection := SubStr(Trimmed, 2, StrLen(Trimmed) - 2)
			Out.Push(Line)
			continue
		}
		if (CurrentSection != "" and InStr(Line, "=")
				and Pending.Has(CurrentSection)) {
			EqPos := InStr(Line, "=")
			Key := Trim(SubStr(Line, 1, EqPos - 1))
			if Pending[CurrentSection].Has(Key) {
				Val := Pending[CurrentSection][Key]
				Out.Push(Key . "=" . Val)
				Pending[CurrentSection].Delete(Key)
				continue
			}
		}
		Out.Push(Line)
	}
	; Flush pending keys for the final section, then append any section that
	; never existed in the original file.
	_IniFlushPending(Out, CurrentSection, Pending)
	for Sec, KVs in Pending {
		if KVs.Count == 0 {
			continue
		}
		Out.Push("[" . Sec . "]")
		for K, V in KVs {
			Out.Push(K . "=" . V)
		}
	}

	; Single write. Use UTF-8 with BOM so downstream ``IniRead`` (Win32) sees
	; the same encoding it would after a plain ``IniWrite`` call.
	Blob := ""
	for _, Ln in Out {
		Blob .= Ln . "`r`n"
	}
	try {
		f := FileOpen(Path, "w", "UTF-8")
		if !f {
			return false
		}
		f.Write(Blob)
		f.Close()
	} catch {
		return false
	}
	return true
}

_IniFlushPending(Out, SectionName, Pending) {
	if (SectionName == "" or !Pending.Has(SectionName)) {
		return
	}
	KVs := Pending[SectionName]
	if KVs.Count == 0 {
		return
	}
	; Backtrack past trailing blank lines so new keys stay inside the section.
	while (Out.Length > 0 and Trim(Out[Out.Length]) == "") {
		Trailing := Out.Pop()
	}
	for K, V in KVs {
		Out.Push(K . "=" . V)
	}
	KVs.Clear()
	Out.Push("")  ; preserve a blank line between sections
}
