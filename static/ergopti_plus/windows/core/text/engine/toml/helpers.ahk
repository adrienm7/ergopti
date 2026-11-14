; core/text/engine/toml/helpers.ahk

; ==============================================================================
; MODULE: TOML Helpers
; DESCRIPTION:
; Single-source-of-truth configuration backend. The driver used to spread its
; settings across an INI file (``ErgoptiPlus_Configuration.ini``) read via
; Win32 ``IniRead``/``IniWrite`` plus a hand-rolled TOML parser for the
; metrics-specific ``[shortcuts]`` section. Both files now live as one
; ``config.toml`` with section-scoped reads, writes and a batched mutator
; that mirrors the old ``IniBatchWrite`` semantics.
;
; FEATURES & RATIONALE:
; 1. Drop-in for IniRead/IniWrite: ``TOML_Read``/``TOML_Write`` keep the same
;    ``(value, path, section, key)`` argument order (with the path as second
;    arg for write, identical to the Win32 API) so the migration was a
;    near-mechanical search-and-replace.
; 2. Dotted-key tolerant: keys carrying a literal dot (``Foo.Enabled``) are
;    rendered as TOML quoted keys ("Foo.Enabled" = true) and unquoted
;    on read. The driver historically uses ``Feature.Enabled`` /
;    ``Feature.Letter`` strings that we keep untouched at call sites.
; 3. Cached parser: ``TOML_Parse`` reads the full file once into a nested
;    ``Map<Section, Map<Key, Value>>`` so that a startup with hundreds of
;    lookups never reopens the file. Mirrors ``ParseIniFile``'s shape so the
;    cache-aware accessor (``IniCacheGet``) keeps working.
; 4. Section-scoped batch write: owned assignment rows retain canonical
;    rendering while unmatched physical records and comments remain user data.
;    Detached candidates and ordinary publication share one qualified image;
;    changed unrepresentable namespaces refuse before any staging write.
; ==============================================================================

#Include ../../../../infra/phase_stats.ahk

#Requires Autohotkey v2.0+

#Include ../number.ahk
#Include ../source_text_codec.ahk
#Include ../../../fs/adapters/file_system.ahk
#Include inline_tables.ahk
#Include document.ahk
#Include config_snapshot.ahk
#Include refusals.ahk





; ============================
; ============================
; ======= 1/ Utilities =======
; ============================
; ============================

; Sentinel wrapper that carries boolean intent through TOML_RenderValue.
; AHK v2 has no distinct boolean type: `true` IS integer 1 and `false` IS 0,
; so IsNumber() matches both and the renderer would emit "1"/"0" instead of
; the TOML literals "true"/"false". Wrapping a value in TOML_Bool() before
; passing it to TOML_Write/TOML_BatchWrite marks it unambiguously as boolean.
class TOML_Bool {
	__New(v) {
		this.Value := v ? true : false
	}
}

; In-place alphabetical sort of a simple Array of strings via bubble sort.
; The arrays are at most a few hundred entries; O(n²) is fine.
SortArray(arr) {
		n := arr.Length
		loop n - 1 {
				i := A_Index
				loop n - i {
						j := A_Index
						if (StrCompare(arr[j], arr[j + 1]) > 0) {
								tmp := arr[j]
								arr[j] := arr[j + 1]
								arr[j + 1] := tmp
						}
				}
		}
		return arr
}





; =========================
; =========================
; ======= 2/ Reader =======
; =========================
; =========================

; Parse result cache: keyed by file path, invalidated by TOML_BatchWrite.
global _ParseTomlCache := Map()

; Active read generations are private and leave no tombstones after retirement.
; A nested read or invalidation revokes an older owner even when both observe
; an absent cache entry. Retain the cache Map identity across whole-map changes.
_TOML_ParseCacheOwners() {
	static Owners := Map()
	return Owners
}

_TOML_ParseCacheReadCurrent(Owner) {
	global _ParseTomlCache
	if !IsObject(Owner)
		return true
	Owners := _TOML_ParseCacheOwners()
	return Owners.Get(Owner.key, 0) == Owner && _ParseTomlCache == Owner.cache
}

; Every production invalidator uses this even when the cache key is absent.
_TOML_InvalidateParseCache(Path) {
	global _ParseTomlCache
	Key := _TOML_WriteRefusalKey(Path)
	Owners := _TOML_ParseCacheOwners()
	PreviousCritical := Critical("On")
	try {
		if Owners.Has(Key)
			Owners.Delete(Key)
		if _ParseTomlCache.Has(Path)
			_ParseTomlCache.Delete(Path)
	} finally Critical(PreviousCritical)
}

; Paths whose last parse could not READ the file, as opposed to reading an
; empty one. ParseTomlFile must stay non-throwing, and an empty Map cannot
; carry that distinction — so writers ask here before rebuilding a file from a
; parse that never saw its contents. Set and cleared on every parse attempt.
global _TomlReadFailures := Map()

; True when the last ParseTomlFile for this path failed to read it. Callers
; that REWRITE a file must check this: serializing a parse that read nothing
; turns an unreadable config into an empty one.
TOML_ReadFailed(Path) {
		global _TomlReadFailures
		return _TomlReadFailures.Has(Path)
}

; Paths whose last ReadTomlFile could not open an EXISTING file. The sibling of
; _TomlReadFailures above, and deliberately STICKY where that one is per-parse:
; _TomlReadFailures is cleared at the top of every ParseTomlFile, which means a
; lock that clears between a failed boot read and the deferred save is invisible
; to the writer — the re-parse succeeds and the write looks perfectly safe while
; the payload it was handed was already derived from nothing. Only a successful
; read of the SAME path clears an entry here.
global _TomlUnreadableFiles := Map()

; True when the last ReadTomlFile for this path could not read an EXISTING file.
; Callers that turn the returned content into in-memory state which is later
; serialized back must consult this: treating "" as "the file said nothing" and
; then persisting the resulting defaults destroys the real file.
TOML_UnreadableFile(Path) {
		global _TomlUnreadableFiles
		return _TomlUnreadableFiles.Has(Path)
}

; Session latch: an EXISTING config.toml could not be read during the boot
; apply, so the in-memory feature tree holds manifest DEFAULTS rather than the
; user's settings. SaveFullConfig honours it and refuses to serialize. Never
; cleared once set — nothing re-applies the config in-process, so the tree stays
; untrustworthy until the driver is restarted.
global _ConfigBootReadFailed := false
global _ConfigBootRejectedOverrides := 0
; "Section`nKey" -> reason, for each value the boot load ignored as outdated
; configuration. Full saves leave these on disk for the configuration cleanup.
global _ConfigBootOutdatedEntries := Map()

; Parse a TOML file into Map<Section, Map<Key, Value>>. Values are coerced
; to AHK booleans / integers / strings / arrays of strings — anything more
; exotic falls through as a raw string. Returns an empty Map when the file
; is missing so callers can rely on ``.Has`` checks without a prior
; ``FileExist``.
; Multi-line arrays ( key = [\n  "a",\n  "b"\n] ) are fully supported.
ParseTomlFile(Path) {
		Started := PhaseStats_Now()
		try return _ParseTomlFileImpl(Path, true, true)
		finally PhaseStats_Stop("toml.parse", Started)
}

; Transactional candidate rendering must observe bytes only after its terminal
; owner is acquired. It therefore bypasses the boot/UI cache and deliberately
; does not replace that cache object; a refused Reload continues on the exact
; pre-transition in-memory state.
TOML_ParseFreshFile(Path) {
		Started := PhaseStats_Now()
		try return _ParseTomlFileImpl(Path, false, false)
		finally PhaseStats_Stop("toml.parse", Started)
}

; Fresh, uncached parse that keeps ``true``/``false`` literals as TOML_Bool so
; a caller can render every value with its source type, exactly as the batch
; writer sees it. DiscardedArrays counts unterminated arrays the parse dropped;
; TOML_ReadFailed(Path) reports an unreadable file afterwards.
TOML_ParseFreshFileTyped(Path, &DiscardedArrays := 0) {
	return _ParseTomlFileImpl(Path, false, false, , true, &DiscardedArrays)
}

_ParseTomlFileImpl(Path, UseCache, StoreCache, ProvidedContent := unset,
		PreserveBooleanLiterals := false, &DiscardedArrays := 0, SectionFilter := 0) {
		global _ParseTomlCache, _TomlReadFailures, _TomlUnreadableFiles
		; Writers request this local diagnostic on fresh, uncached parses.
		DiscardedArrays := 0
		if PreserveBooleanLiterals && (UseCache || StoreCache)
				throw ValueError("Writer Boolean sentinels cannot use the reader cache")
		if IsObject(SectionFilter) && (UseCache || StoreCache)
				throw ValueError("A section-filtered parse cannot use the reader cache")
		Key := _TOML_WriteRefusalKey(Path)
		Owners := _TOML_ParseCacheOwners()
		PreviousCritical := Critical("On")
		try {
			if UseCache && _ParseTomlCache.Has(Path)
				return _ParseTomlCache[Path]
			Owner := !IsSet(ProvidedContent) || StoreCache
				? {key: Key, cache: _ParseTomlCache} : 0
			if IsObject(Owner)
				Owners[Owner.key] := Owner
			if _TomlReadFailures.Has(Path)
				_TomlReadFailures.Delete(Path)
		} finally Critical(PreviousCritical)
	try {
		Sections := Map()
		if !IsSet(ProvidedContent) && !FileExist(Path)
				return Sections
		Content := ""
		if IsSet(ProvidedContent) {
				if !(ProvidedContent is String)
						return Sections
				Content := ProvidedContent
		} else try {
				Content := FileRead(Path, "UTF-8")
		} catch as Err {
				; Record the failure instead of throwing: the fuzz corpus requires this
				; function never to raise, and every preference read would otherwise be
				; able to abort startup. But an empty Map here is indistinguishable from
				; a genuinely empty file, and TOML_BatchWrite SEEDS ITS REWRITE from it
				; — so without this flag "I could not read your config" silently became
				; "your config was empty" and the next write persisted that as truth.
				Present := FileExist(Path) != ""
				PreviousCritical := Critical("On")
				try {
					if _TOML_ParseCacheReadCurrent(Owner) {
						_TomlReadFailures[Path] := true
						if Present
							_TomlUnreadableFiles[Path] := true
					}
				} finally Critical(PreviousCritical)
				; Raise the STICKY sentinel too, exactly as ReadTomlFile does for the
				; same file. _TomlReadFailures is deleted at the top of the very next
				; parse of this path, so a lock that clears between the boot snapshot
				; and a deferred save is invisible to every writer that asks later —
				; and _IniCache, the widest reader of config.toml, is taken through
				; here. Only for an existing file: a missing one legitimately parses
				; empty, and flagging it would block the first save of a fresh install.
				try LoggerError("TomlParse", "Cannot read '{1}': {2}. Reported as unreadable so writers refuse to rebuild from it.", Path, Err.Message)
				return Sections
		}
		; A successful read clears the sticky flag: what follows is the real file,
		; so anything derived from it is safe to persist again.
		PreviousCritical := Critical("On")
		try {
			if _TOML_ParseCacheReadCurrent(Owner) && _TomlUnreadableFiles.Has(Path)
				_TomlUnreadableFiles.Delete(Path)
		} finally Critical(PreviousCritical)
		if SubStr(Content, 1, 1) == Chr(0xFEFF)
				Content := SubStr(Content, 2)
		if (Content = "")
				return Sections

		Section     := ""
		PendingKey  := ""   ; key whose value spans multiple lines
		HasPendingValue := false ; an empty quoted key is still a valid owner
		PendingVal  := ""   ; accumulated raw characters of the multi-line value
		PendingDepth := 0
		PendingQuote := ""
		PendingEscaped := false
		; A caller that reads only some sections (personal-file metadata reads the
		; [_meta] tables of a file holding hundreds of hotstrings) skips decoding
		; every other section's values; the line state that finds headers and
		; multi-line arrays runs exactly as in a full parse.
		SectionKept := true
		; Values decoded by this parse, published per parse for the boot budget.
		Decoded := 0

		loop parse, Content, "`n", "`r" {
				Line := Trim(A_LoopField)

				; --- Continuation of a multi-line array ---
				if HasPendingValue {
						; Drop any comment on this line before it is accumulated. Skipping
						; only whole-comment lines let a TRAILING comment on an element line
						; become part of the value, and it was then persisted as a real
						; array element on the next write.
						Line := TOML_StripInlineComment(Line)
						Stripped := Trim(Line)
						if (Stripped == "") {
								continue
						}
						; A section header while the array is still open means its closing ] was lost
						; (hand-edited file). Abort the array and re-process this line as a header, else
						; the parser swallows it and every following section into one PendingVal and
						; drops them all at EOF - silent whole-file-tail config loss
						; (toml-unterminated-array-recovery).
						if TOML_ArrayRecoveryHeader(Stripped) {
								DiscardedArrays += 1
								try LoggerWarn("TomlParse", "Unterminated multi-line array for key '{1}' in [{2}] - aborting array, resuming section parse.", PendingKey, Section)
								PendingKey := ""
								HasPendingValue := false
								PendingVal := ""
								Section := Trim(RegExReplace(Line, "^\[+|\]+$", ""))
								SectionKept := !IsObject(SectionFilter) || SectionFilter.Call(Section)
								if !Sections.Has(Section)
										Sections[Section] := Map()
								continue
						}
						PendingVal .= " " . Line
						; Count only unquoted brackets to detect the real terminator.
						PendingDepth := _TOML_ArrayScanFragment(" " . Line, PendingDepth,
								&PendingQuote, &PendingEscaped)
						if (PendingDepth <= 0) {
								if !Sections.Has(Section)
										Sections[Section] := Map()
								if SectionKept {
										Sections[Section][PendingKey] := TOML_CoerceValue(Trim(PendingVal),
												PreserveBooleanLiterals)
										Decoded += 1
								}
								PendingKey := ""
								HasPendingValue := false
								PendingVal := ""
						}
						continue
				}

				if (Line = "" || SubStr(Line, 1, 1) = "#")
						continue

				; Section header [name] — skip [[table-array]] headers (hotstrings TOML)
				if (SubStr(Line, 1, 1) = "[") {
						; Cut any trailing comment FIRST: the closing-bracket anchor below
						; cannot match once a comment follows, so the comment would become
						; part of the section name and every later read of that section
						; would miss — then the next write re-wraps the garbage in brackets.
						Header := TOML_StripInlineComment(Line)
						inner := RegExReplace(Header, "^\[+|\]+$", "")
						Section := Trim(inner)
						SectionKept := !IsObject(SectionFilter) || SectionFilter.Call(Section)
						if !Sections.Has(Section)
								Sections[Section] := Map()
						continue
				}

				eq := _TOML_AssignmentDelimiter(Line)
				if !eq
						continue
				; In a skipped section only an opening array changes the line state.
				if !SectionKept && SubStr(LTrim(SubStr(Line, eq + 1), " `t"), 1, 1) != "["
						continue
				key := TOML_DecodeKey(Trim(SubStr(Line, 1, eq - 1)))
				val := Trim(SubStr(Line, eq + 1))
				if (Section = "")
						continue

				; Strip an inline comment, quote-aware so a hash inside the string
				; stays data and a hash after the closing quote is still a comment.
				val := TOML_StripInlineComment(val)

				; A quoted ] on the opening line is data, not the array terminator.
				PendingQuote := ""
				PendingEscaped := false
				PendingDepth := (SubStr(val, 1, 1) = "[")
						? _TOML_ArrayScanFragment(val, 0, &PendingQuote, &PendingEscaped) : 0
				if (PendingDepth > 0) {
						PendingKey := key
						HasPendingValue := true
						PendingVal := val
						continue
				}

				; Whole-file writers must retain source Boolean intent before AHK
				; erases it into integer 0/1. Ordinary readers keep native values.
				if SectionKept {
						Sections[Section][key] := TOML_CoerceValue(val, PreserveBooleanLiterals)
						Decoded += 1
				}
		}
		; Detached compositions (workers, child fixtures) load this parser without the profiler.
		if IsSet(PerfCount)
				PerfCount("toml.flat_values", Decoded)
		if HasPendingValue {
				DiscardedArrays += 1
				try LoggerWarn("TomlParse", "Unterminated multi-line array for key '{1}' reached EOF in [{2}] - the value is lost.", PendingKey, Section)
		}
		if StoreCache {
			PreviousCritical := Critical("On")
			try {
				if _TOML_ParseCacheReadCurrent(Owner)
					_ParseTomlCache[Path] := Sections
			} finally Critical(PreviousCritical)
		}
		return Sections
	} finally {
		PreviousCritical := Critical("On")
		try {
			if IsObject(Owner) && Owners.Get(Owner.key, 0) == Owner
				Owners.Delete(Owner.key)
		} finally Critical(PreviousCritical)
	}
}

; The assignment separator belongs outside quoted keys. A value may itself
; contain equals signs, so stop at the first unquoted separator rather than
; splitting the entire line into a presumed pair.
_TOML_AssignmentDelimiter(Line) {
	KeyQuote := ""
	KeyEscaped := false
	Loop Parse Line {
		KeyChar := A_LoopField
		if KeyEscaped {
			KeyEscaped := false
		} else if KeyQuote == '"' && KeyChar == "\" {
			KeyEscaped := true
		} else if KeyQuote != "" {
			if KeyChar == KeyQuote
				KeyQuote := ""
		} else if KeyChar == '"' || (KeyChar == "'" && _TOML_IsLiteralStart(Line, A_Index)) {
			KeyQuote := KeyChar
		} else if KeyChar == "=" {
			return A_Index
		} else if KeyChar == "#" {
			return 0
		}
	}
	return 0
}

; Split only at the current array level. All three decoders consume these raw
; tokens and retain ownership of their distinct scalar coercion contracts.
TOML_SplitArrayElements(Body, Separator := ",", Strict := false) {
	Parts := []
	Current := ""
	Closers := []
	Quote := ""
	Escaped := false
	Loop Parse Body {
		Char := A_LoopField
		if Escaped {
			Escaped := false
		} else if Quote == '"' && Char == "\" {
			Escaped := true
		} else if Quote != "" {
			if Char == Quote
				Quote := ""
		} else if Char == '"' || (Char == "'" && _TOML_IsLiteralStart(Body, A_Index)) {
			Quote := Char
		} else {
			if Char == "[" || Char == "{"
				Closers.Push(Char == "[" ? "]" : "}")
			else if Char == "]" || Char == "}" {
				if Strict && (Closers.Length == 0 || Closers[Closers.Length] != Char)
					throw ValueError("Unbalanced TOML inline table member")
				if Closers.Length
					Closers.Pop()
			} else if Char == Separator && Closers.Length == 0 {
				Parts.Push(Trim(Current))
				Current := ""
				continue
			}
		}
		Current .= Char
	}
	if Strict && (Quote != "" || Escaped || Closers.Length)
		throw ValueError("Unterminated TOML inline table member")
	if Trim(Current) != ""
		Parts.Push(Trim(Current))
	else if Strict && Parts.Length
		throw ValueError("Empty TOML inline table member")
	return Parts
}

; Within an open array, value syntax wins over an ambiguous header such as
; [1], [true] or ["a"]. Recover only a complete section-shaped non-value.
TOML_ArrayRecoveryHeader(Line) {
	if !RegExMatch(Line, "^(\[{1,2})(.*?)(\]{1,2})$", &Match)
			|| StrLen(Match[1]) != StrLen(Match[3])
		return false
	Inner := Trim(Match[2])
	BasicQuoted := '"(?:[^"\\]|\\.)*"'
	Quoted := "(?:" . BasicQuoted . "|'[^']*')"
	Kind := TOML_LiteralKind(Inner)
	if RegExMatch(Inner, "^" . Quoted . "$") || (Kind != "unknown" && Kind != "string")
		return false
	; Preserve numeric/date value forms even where scalar coercion still returns
	; their raw text. Recovering them as headers would also lose array structure.
	if RegExMatch(Inner, "^(?:[+-]?(?:inf|nan)|[+-]?\d(?:_?\d)*(?:\.\d(?:_?\d)*)?(?:[eE][+-]?\d(?:_?\d)*)?|0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*|\d{4}-\d{2}-\d{2})$")
		return false
	Segment := "(?:[A-Za-z0-9_-]+|" . Quoted . ")"
	return !!RegExMatch(Inner, "^" . Segment . "(?:\s*\.\s*" . Segment . ")*$")
}

; Return the net bracket depth outside TOML strings. Backslash
; escapes are consumed only inside a basic string so an escaped quote cannot expose a
; data bracket to the structural scanner.
_TOML_ArrayBracketDepth(Value) {
		Quote := ""
		Escaped := false
		return _TOML_ArrayScanFragment(Value, 0, &Quote, &Escaped)
}

/**
 * Scans only the newly appended array fragment, retaining string state.
 * @param {String} Value The opening value or the space-prefixed continuation.
 * @param {Integer} Depth Bracket depth before this fragment.
 * @param {String} Quote Active string delimiter, updated by the scan.
 * @param {Integer} Escaped Whether a basic-string escape is pending.
 * @returns {Integer} Bracket depth after this fragment.
 */
_TOML_ArrayScanFragment(Value, Depth, &Quote, &Escaped) {
		Loop Parse Value {
				Char := A_LoopField
				if Escaped {
						Escaped := false
						continue
				}
				if (Quote == '"' and Char == "\") {
						Escaped := true
						continue
				}
				if Quote != "" {
						if Char == Quote
								Quote := ""
						continue
				}
				if Char == '"' || (Char == "'" && _TOML_IsLiteralStart(Value, A_Index)) {
						Quote := Char
						continue
				}
				if Quote == "" {
						if (Char == "[")
								Depth++
						else if (Char == "]")
								Depth--
				}
		}
		return Depth
}

; Cut a line at its first UNQUOTED ``#`` and trim what remains. This is the
; character-by-character scan the parser's comment always promised and never
; had: the old code skipped stripping entirely whenever a value began with a
; quote, so a trailing comment on a quoted value survived into the value — and
; because TOML_CoerceValue needs the LAST character to be a quote too, the
; whole line tail then fell through as raw text and was persisted on the next
; write. Both the header and the key/value paths route through here so the
; three parsers cannot drift apart again.
;
; Literal quotes open only at token boundaries, preserving apostrophes in legacy
; bare values. Backslashes escape characters only inside basic strings.
TOML_StripInlineComment(Line) {
		; With no comment marker, quoting cannot change the returned bytes
		if !InStr(Line, "#")
				return Trim(Line)
		Quote := ""
		Escaped := false
		Skip := 0
		Loop Parse Line {
				if Skip {
						Skip -= 1
						continue
				}
				if (Escaped) {
						Escaped := false
						continue
				}
				if (A_LoopField == "\" && SubStr(Quote, 1, 1) == '"') {
						Escaped := true
						continue
				}
				if Quote != "" {
						if SubStr(Line, A_Index, StrLen(Quote)) == Quote {
								Skip := StrLen(Quote) - 1
								if StrLen(Quote) == 3 {
										Position := A_Index
										while SubStr(Line, Position + Skip + 1, 1) == A_LoopField
												Skip += 1
								}
								Quote := ""
						}
						continue
				}
				if A_LoopField == '"' || (A_LoopField == "'" && _TOML_IsLiteralStart(Line, A_Index)) {
						Quote := A_LoopField
						; A triple delimiter owns hashes and embedded single quotes
						; until its matching triple, including physical newlines.
						if SubStr(Line, A_Index, 3) == Quote . Quote . Quote {
								Quote := Quote . Quote . Quote
								Skip := 2
						}
						continue
				}
				if A_LoopField == "#"
						return Trim(SubStr(Line, 1, A_Index - 1))
		}
		return Trim(Line)
}

/** Returns the source type of one TOML literal before AHK scalar coercion. */
TOML_LiteralKind(RawValue) {
		Literal := Trim(TOML_StripInlineComment(RawValue), " `t")
		Lower := StrLower(Literal)
		if (Lower == "true" || Lower == "false")
				return "boolean"
		if TOML_TryParseNumber(Literal, &NumberValue)
				return "number"
		; Literal strings carry the same string intent as basic strings. The
		; coercers already decode them without interpreting Windows backslashes.
		; Multiline literals also allow one or two quotes inside the body or
		; immediately before the closing triple, but never a closed-token tail.
		if RegExMatch(Literal, "^'[^']*'$")
				|| RegExMatch(Literal, "s)^'''(?:(?!''').)*'{3,5}$")
				return "string"
		if (StrLen(Literal) >= 2
		and SubStr(Literal, 1, 1) == '"'
		and SubStr(Literal, -1) == '"')
				return "string"
		if (StrLen(Literal) >= 2
		and SubStr(Literal, 1, 1) == "["
		and SubStr(Literal, -1) == "]")
				return "array"
		return "unknown"
}

/**
 * Parses one decimal integer only when its magnitude fits TOML's signed
 * 64-bit domain. AutoHotkey's Integer(String) wraps overflow modulo 2^64, so
 * conversion itself cannot be used as the range check.
 */
TOML_TryParseInteger(Raw, &Value) {
		return NumberTryParseSignedInteger(Raw, &Value)
}

/**
 * Parses one decimal or exponential float only when AutoHotkey represents a
 * finite IEEE-754 binary64 value. Float(String) otherwise returns +/-infinity,
 * which still passes AHK's numeric type checks and corrupts later arithmetic.
 */
TOML_TryParseFloat(Raw, &Value) {
		Value := ""
		if !RegExMatch(Raw, "^[+-]?\d+(?:\.\d+(?:[eE][+-]?\d+)?|[eE][+-]?\d+)$")
				return false
		return NumberTryParseFiniteFloat(Raw, &Value)
}

/** Parses one bounded TOML integer or finite decimal/exponential float. */
TOML_TryParseNumber(Raw, &Value) {
		if TOML_TryParseInteger(Raw, &Value)
				return true
		return TOML_TryParseFloat(Raw, &Value)
}

TOML_CoerceValue(raw, PreserveBooleanLiterals := false) {
		raw := Trim(raw)
		if StrLen(raw) >= 2 && SubStr(raw, 1, 1) == "'" && SubStr(raw, -1) == "'"
				return SubStr(raw, 2, StrLen(raw) - 2)
		if SubStr(raw, 1, 1) == "{"
				return TOML_ParseInlineTable(raw, (Value) => TOML_CoerceValue(Value, PreserveBooleanLiterals))
		if (raw = "")
				return ""
		if (StrLower(raw) = "true")
				return PreserveBooleanLiterals ? TOML_Bool(true) : true
		if (StrLower(raw) = "false")
				return PreserveBooleanLiterals ? TOML_Bool(false) : false
		; Quoted string.
		if (SubStr(raw, 1, 1) = '"' && SubStr(raw, -1) = '"')
				return TOML_Unescape(SubStr(raw, 2, StrLen(raw) - 2))
		; Array of strings: [ "a", "b", ... ]
		if (SubStr(raw, 1, 1) = "[" && SubStr(raw, -1) = "]") {
				body := Trim(SubStr(raw, 2, StrLen(raw) - 2))
				out := []
				if (body = "")
						return out
				for Token in TOML_SplitArrayElements(body)
						out.Push(TOML_CoerceValue(Token, PreserveBooleanLiterals))
				return out
		}
		if TOML_TryParseInteger(raw, &IntegerValue)
				return IntegerValue
		; Float literals: 0.25, -1.5, 3.14, etc.
		if TOML_TryParseFloat(raw, &FloatValue)
				return FloatValue
		return raw
}

/** Encodes contents for a TOML basic string without surrounding quotes. */
TOML_EscapeBasicStringContents(s) {
	; Preserve legacy coercion for non-String callers, while native Strings
	; must be admitted before any helper can truncate their original units.
	if !(s is String)
		s := String(s)
	SourceTextRequireUnicodeScalars(StrPtr(s), 0, StrLen(s))
	Result := ""
	Loop Parse, s {
		Char := A_LoopField
		Code := Ord(Char)
		switch Code {
			case 0x08: Result .= "\b"
			case 0x09: Result .= "\t"
			case 0x0A: Result .= "\n"
			case 0x0C: Result .= "\f"
			case 0x0D: Result .= "\r"
			case 0x22: Result .= '\"'
			case 0x5C: Result .= "\\"
			default:
				if (Code < 0x20 || Code == 0x7F)
					Result .= Format("\u{:04x}", Code)
				else
					Result .= Char
		}
	}
	return Result
}

/** Decodes contents from a TOML basic string without surrounding quotes. */
TOML_UnescapeBasicStringContents(s) {
	s := String(s)
	if !InStr(s, "\")
		return s
	Result := "", i := 1, n := StrLen(s)
	while (i <= n) {
		Char := SubStr(s, i, 1)
		if (Char != "\" || i == n) {
			Result .= Char
			i += 1
			continue
		}
		NextChar := SubStr(s, i + 1, 1)
		switch NextChar {
			case "b": Result .= Chr(8)
			case "t": Result .= "`t"
			case "n": Result .= "`n"
			case "f": Result .= Chr(12)
			case "r": Result .= "`r"
			case '"': Result .= '"'
			case "\": Result .= "\"
			case "u", "U":
				Digits := NextChar == "u" ? 4 : 8
				Hex := SubStr(s, i + 2, Digits)
				if (StrLen(Hex) == Digits && RegExMatch(Hex, "^[0-9A-Fa-f]+$")) {
					Code := Integer("0x" . Hex)
					if (Code == 0 || Code > 0x10FFFF
							|| (Code >= 0xD800 && Code <= 0xDFFF))
						throw ValueError("TOML string contains an unsupported Unicode scalar.")
					Result .= Chr(Code)
					i += 2 + Digits
					continue
				}
				; Preserve the legacy unknown-escape behavior for malformed input.
				Result .= NextChar
			default: Result .= NextChar
		}
		i += 2
	}
	return Result
}

TOML_Unescape(s) {
	return TOML_UnescapeBasicStringContents(s)
}





; =================================
; =================================
; ======= 3/ Single-key API =======
; =================================
; =================================

; Read a single key. Returns ``Default`` when the file, the section, or the
; key is missing. The parser already returns booleans as integer 1/0.
; Preserve its types directly: comparing quoted numeric text to true/false
; would coerce section names such as "001" to integer 1.
TOML_Read(Path, Section, Key, Default := "") {
		Sections := ParseTomlFile(Path)
		if !Sections.Has(Section) || !Sections[Section].Has(Key)
				return Default
		return Sections[Section][Key]
}

; Write a single (Section, Key, Value) triple. Atomic via .tmp + rename.
; Order matches Win32 ``IniWrite(Value, Path, Section, Key)`` so existing
; call sites stay symmetrical.
TOML_Write(Value, Path, Section, Key) {
		updates := [{ Section: Section, Key: Key, Value: Value }]
		return TOML_BatchWrite(Path, updates)
}





; ===============================
; ===============================
; ======= 4/ Batch writer =======
; ===============================
; ===============================

; Minimum age of an abandoned atomic-write stage: one minute tells it from a live
; writer, and the reapers also check producer ownership. Writers can run before the
; timing registry loads, so this copy is pinned to [adapters] stale_temp_age_ms by
; tools/test/test-keystats-timings-single-source.cjs.
StaleTempAgeMs() {
	return 60000
}

; Apply every (Section, Key, Value) update in one read-modify-write cycle.
; Renders explicitly owned rows canonically and retains foreign physical records
; and comments before the one atomic replace. A wholly owned, uncommented source
; keeps the existing complete canonical serializer and stable spacing.
; It must not call SaveFullConfig afterward: targeted writers persist before
; publishing their candidate globals, so a nested full save would serialize
; the stale live state back over the just-committed values.
; Delete scratch files left next to Path by a hard kill. Per-invocation names
; no longer overwrite each other. Require both age and a recognized dead owner;
; a slow active writer or an unrelated temporary file must never be targeted.
_TOML_ReapStaleTemps(Path, MaxAgeMs) {
		SplitPath(Path, &Name, &Dir)
		if (Dir = "" or Name = "")
				return
		try {
				Loop Files, Dir . "\" . Name . ".*.tmp" {
						if (DateDiff(A_Now, A_LoopFileTimeModified, "Seconds") * 1000 >= MaxAgeMs)
								&& FSAtomicTempOwnerIsGone(A_LoopFileName, Name)
								try FileDelete(A_LoopFileFullPath)
				}
		}
}

; A successful Write call is not proof that the complete qualified image
; reached the stage. Read it back exactly before any rename can make it live.
_TOML_StageMatches(Path, Expected, ReadFn := 0) {
	try {
		Actual := HasMethod(ReadFn, "Call")
			? ReadFn.Call(Path) : FileRead(Path, "UTF-8")
	} catch {
		return false
	}
	return (Actual is String) && StrCompare(Actual, Expected, true) == 0
}

; Builds the same qualified image used by TOML_BatchWrite without publishing a
; target. Multi-file transactions need the complete new bytes before their WAL
; can capture the old image; routing both modes through one renderer prevents a
; subtly different onboarding serializer from drifting from ordinary saves.
TOML_BuildUpdatedContent(Path, Updates, ExactSectionPrefixes := []) {
	SourcePresent := FileExist(Path) ? 1 : 0
	SourceBytes := SourcePresent ? FSReadUtf8Exact(Path) : ""
	if SourcePresent && !(SourceBytes is String)
		return Map("status", "error", "kind", "source_unreadable",
			"content", "")
	Result := _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "build",
		SourceBytes, SourcePresent)
	return _TOML_FinalizeBuildResult(Result, SourcePresent, SourceBytes)
}

_TOML_FinalizeBuildResult(Result, SourcePresent, SourceBytes) {
	if (Result is Map) && Result.Has("status") && Result.Has("kind")
			&& Result.Has("content") && (Result["status"] is String)
			&& (Result["kind"] is String) && (Result["status"] == "ok")
			&& (Result["kind"] == "rendered")
			&& (Result["content"] is String) {
		Result["source_present"] := SourcePresent
		Result["source_content"] := SourceBytes
		return Result
	}
	return Map("status", "error", "kind", "render_failed", "content", "")
}

; The setting a case twin refused in the latest write, "" otherwise. The writers
; answer a boolean, so the failure report reads the cause here, once.
global _TomlCaseTwinRefusal := ""

/**
 * Answers the setting a case twin refused in the latest write, and forgets it.
 * @returns {String} The setting's dotted name, or "" for any other outcome.
 */
TOML_TakeCaseTwinRefusal() {
	global _TomlCaseTwinRefusal
	Setting := _TomlCaseTwinRefusal
	_TomlCaseTwinRefusal := ""
	return Setting
}

TOML_BatchWrite(Path, Updates, ExactSectionPrefixes := [], AdmissionFn := 0) {
		return _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , false, AdmissionFn)
}

/** Builds a complete configuration-only semantic candidate without publication. */
TOML_BuildConfigUpdatedContent(Path, Updates, ExactSectionPrefixes := []) {
	SourcePresent := FileExist(Path) ? 1 : 0
	SourceBytes := SourcePresent ? FSReadUtf8Exact(Path) : ""
	if SourcePresent && !(SourceBytes is String)
		return Map("status", "error", "kind", "source_unreadable", "content", "")
	Result := _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "build",
		SourceBytes, SourcePresent, true)
	return _TOML_FinalizeBuildResult(Result, SourcePresent, SourceBytes)
}

/** Publishes semantic configuration effects, optionally bound to an exact held image. */
TOML_ConfigBatchWrite(Path, Updates, ExactSectionPrefixes := [], AdmissionFn := 0,
		ProvidedContent := unset, ProvidedPresence := unset) {
	Owner := _ConfigWriteLeaseCurrent(Path)
	Borrowed := _ConfigWriteLeaseOwns(Owner, Path)
	if !Borrowed
		Owner := _ConfigWriteLeaseTryAcquire(Path, "native-config-writer")
	if !(Owner is Object)
		return false
	NativeAdmission := () => _ConfigWriteLeaseOwns(Owner, Path) && _FSNativeAdmissionAccepted(AdmissionFn)
	try return _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write",
		ProvidedContent?, ProvidedPresence?, true, NativeAdmission)
	finally {
		if !Borrowed
			_ConfigWriteLeaseRelease(Owner)
	}
}

; Fresh source authority is checked independently of candidate equality. A
; concurrent writer cannot turn a stale candidate into an acknowledged no-op.
_TOML_WriteSourceMatches(Path, SourcePresent, SourceBytes) {
	return SourcePresent ? FSUtf8ExactMatches(Path, SourceBytes) : !FileExist(Path)
}

; Generic replacement owns exact native section identities. Keep this policy
; beside its caller; the sealed document codec also serves other write owners.
_TOML_ExactSectionDropped(Section, Prefixes) {
	for Prefix in Prefixes {
		if Section == Prefix || InStr(Section, Prefix . ".", true) == 1
			return true
	}
	return false
}

; A representable flat source can retire exactly owned lexical rows before the
; sealed renderer runs. Prove the original source first, then let ordinary
; admission verify the filtered source and the complete unchanged target model.
; Unrepresented namespaces retain their existing independent admission rules.
_TOML_AdmitExactPrefixCandidate(Source, Before, After, Candidate, Updates, Prefixes) {
	if !Prefixes.Length
		return TOML_AdmitWriterCandidate(Source, Before, After, Candidate, Updates, Prefixes)
	Document := TOML_ParseDocument(Source, , &Physical)
	if !TOML_SameValue(Document, _TOML_FlatDocument(Before))
		return TOML_AdmitWriterCandidate(Source, Before, After, Candidate, Updates, Prefixes)
	FilteredSource := SubStr(Source, 1, 1) == Chr(0xFEFF) ? Chr(0xFEFF) : ""
	for Record in Physical {
		if (Record.Kind == "header" || Record.Kind == "assignment")
				&& _TOML_ExactSectionDropped(Record.Section, Prefixes)
			continue
		FilteredSource .= Record.Text
	}
	FilteredBefore := Before.Clone()
	for Section in Before {
		if _TOML_ExactSectionDropped(Section, Prefixes)
			FilteredBefore.Delete(Section)
	}
	return TOML_AdmitWriterCandidate(FilteredSource, FilteredBefore, After, Candidate, Updates, [])
}

_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, Mode,
		ProvidedContent := unset, ProvidedPresence := unset, DocumentMode := false, AdmissionFn := 0, HeldFlushFn := 0) {
		if !(Mode is String) || (Mode != "write" && Mode != "build")
				throw ValueError("TOML_BatchWrite mode must be 'write' or 'build'")
		BuildOnly := Mode == "build"
		global _TomlCaseTwinRefusal
		_TomlCaseTwinRefusal := ""
		Refusal := TOML_WriteRefusal(Path)
		if (Refusal != "") {
				try LoggerError("TomlWrite", "Refusing TOML {1} for '{2}': writes to it are refused for this session ({3}). No file was changed.",
					Mode, Path, Refusal)
				return false
		}
		if !(ExactSectionPrefixes is Array)
				throw TypeError("ExactSectionPrefixes must be an Array")
		for _, Prefix in ExactSectionPrefixes {
				if Prefix is String
						SourceTextRequireUnicodeScalars(StrPtr(Prefix), 0, StrLen(Prefix))
				if !(Prefix is String) or Prefix = ""
						throw ValueError("ExactSectionPrefixes must contain non-empty strings")
		}
		; Native Map keys compare NUL-terminated identities. Validate original
		; update names before any lookup can alias a distinct shorter setting.
		for Update in Updates {
			for Name in [Update.Section, Update.Key] {
				if Name is String
					SourceTextRequireUnicodeScalars(StrPtr(Name), 0, StrLen(Name))
			}
		}
		if (!DocumentMode && !BuildOnly && Updates.Length = 0 and ExactSectionPrefixes.Length = 0)
				return FSNativeAcknowledge(AdmissionFn)

		; Keep logical schema/cache/refusal identity unchanged. Native I/O binds
		; one absolute target before any source read can yield and change cwd.
		SourcePath := Path
		if !BuildOnly {
			try SourcePath := FSResolveAbsolutePath(Path)
			catch as Err {
				try LoggerError("TomlWrite", "Cannot capture the native target for '{1}': {2}. No file was changed.", Path, Err.Message)
				return false
			}
		}

		; A config save is a full read-modify-write plus a canonicalisation pass, and
		; it runs from menu callbacks — so a slow one blocks the tray menu while the
		; user watches. It had no segment at all; the cost showed up only as a menu
		; that felt stuck. Two QPC reads, gated by the profiler floor.
		_hpTomlWrite := HotPath_Now()

		if IsSet(ProvidedPresence) && (!(ProvidedPresence is Integer)
				|| (ProvidedPresence != 0 && ProvidedPresence != 1))
				throw TypeError("Provided source presence must be Integer 0 or 1")
		SourcePresent := IsSet(ProvidedPresence) ? ProvidedPresence : (FileExist(SourcePath) ? 1 : 0)
		SourceBytes := IsSet(ProvidedContent) ? ProvidedContent
			: (SourcePresent ? FSReadUtf8Exact(SourcePath) : "")
		if !(SourceBytes is String) {
				global _TomlReadFailures, _TomlUnreadableFiles
				_TomlReadFailures[Path] := true
				if SourcePresent
						_TomlUnreadableFiles[Path] := true
				try LoggerError("TomlWrite", "Refusing TOML {1} for '{2}': its exact source image could not be read. No file was changed.", Mode, Path)
				return false
		}
		if DocumentMode {
			CandidateUpdates := Updates
			if !SourcePresent {
				; Genuine first-use absence has no schema metadata to preserve. The
				; native candidate owner stamps it through the ordinary renderer,
				; without changing caller updates or admitting a public READY brand.
				CandidateUpdates := Updates.Clone()
				ExplicitMetadata := false, MaterializesSource := false
				for Update in Updates {
					if !Update.HasOwnProp("Delete") || !Update.Delete
						MaterializesSource := true
					if (Update.Section == "_meta" && Update.Key == "schema_version")
							|| (Update.Section == "" && Update.Key == "_meta")
						ExplicitMetadata := true
				}
				if MaterializesSource && !ExplicitMetadata
					CandidateUpdates.Push({ Section: "_meta", Key: "schema_version", Value: ConfigMigrateCurrentVersion() })
			}
			try Admitted := TOML_BuildConfigDocumentCandidate(SourceBytes, CandidateUpdates, ExactSectionPrefixes)
			catch as Err {
				_TomlCaseTwinRefusal := Err.HasOwnProp("CaseTwinSetting") ? Err.CaseTwinSetting : ""
				try LoggerError("TomlWrite", "Refusing semantic configuration {1} for '{2}': {3}. No file was changed.", Mode, Path, Err.Message)
				return false
			}
		} else {
			Parsed := _ParseTomlFileImpl(Path, false, false, SourceBytes, true, &DiscardedArrays)
			; Refuse to rebuild a file we could not read. Everything below serializes
			; ONLY what this parse returned and then moves the result over the original,
			; so proceeding on a failed read would replace the user's whole config with
			; the handful of keys in Updates. "I could not read it" must never be
			; allowed to mean "it was empty".
			if TOML_ReadFailed(Path) {
					try LoggerError("TomlWrite", "Refusing to write '{1}': the current contents could not be read, and rewriting from an unread file would discard every setting it holds.", Path)
					return false
			}
			if DiscardedArrays {
					try LoggerError("TomlWrite", "Refusing TOML {1} for '{2}': parsing discarded {3} unterminated array(s). Repair the source before saving; no file was changed.", Mode, Path, DiscardedArrays)
					return false
			}
			; Deep-copy the parsed Map before mutating so candidate rendering and
			; publication share the same side-effect-free transformation.
			Sections := Parsed.Clone()
			for sec in Sections
					Sections[sec] := Sections[sec].Clone()
			; Track section order so the on-disk layout stays stable across writes.
			; ``ParseTomlFile`` already iterates the file in declaration order, so
			; ``for`` over the resulting Map preserves it; we rebuild the order
			; explicitly to make new sections deterministic.
			order := []
			for sec in Sections
					order.Push(sec)

			; Dynamic record namespaces need replace semantics: a merge-only write
			; retains records omitted by the caller and resurrects deleted profiles on
			; the next boot. Match only the exact section or a dot-delimited child so a
			; sibling such as ``user_profiles_backup`` remains untouched.
			if (ExactSectionPrefixes.Length > 0) {
					KeptOrder := []
					for _, SecName in order {
							DropSection := _TOML_ExactSectionDropped(SecName, ExactSectionPrefixes)
							if DropSection
									Sections.Delete(SecName)
							else
									KeptOrder.Push(SecName)
					}
					order := KeptOrder
			}

			for _, U in Updates {
					Sec := U.Section
					K := U.Key
					DeleteRequested := U.HasOwnProp("Delete")
						&& (U.Delete is Integer) && U.Delete == 1
					if U.HasOwnProp("Delete")
							&& (!(U.Delete is Integer)
								|| (U.Delete != 0 && U.Delete != 1))
							throw TypeError("Delete must be the Integer 0 or 1")
					; A neutral-value deletion must not create the missing section it
					; was meant to leave absent, especially in the boot full-save batch.
					if DeleteRequested && !Sections.Has(Sec)
							continue
					if !Sections.Has(Sec) {
							Sections[Sec] := Map()
							order.Push(Sec)
					}
					if DeleteRequested {
							if Sections[Sec].Has(K)
									Sections[Sec].Delete(K)
					} else {
							Sections[Sec][K] := U.Value
					}
			}

			body := ""

			EnsureTrailingBlankLines(count) {
					newline_run := 0
					i := StrLen(body)
					while (i > 0 && SubStr(body, i, 1) = "`n") {
							newline_run += 1
							i -= 1
					}
					current := newline_run > 0 ? (newline_run - 1) : 0
					while (current < count) {
							body .= "`n"
							newline_run += 1
							current += 1
					}
					while (current > count) {
							body := SubStr(body, 1, StrLen(body) - 1)
							newline_run -= 1
							current -= 1
					}
			}

			; Foreign table-array generations are not flat rendering destinations.
			; Admission below independently verifies their complete typed subtrees.
			try RenderingSections := _TOML_ForeignArrayRenderingSections(SourceBytes, Sections)
			catch as Err {
					try LoggerError("TomlWrite", "Refusing TOML {1}: source rendering admission failed. No file was changed.", Mode)
					return false
			}
			; Sort sections alphabetically for stable, readable output
			SortedSections := []
			for sec in RenderingSections
					SortedSections.Push(sec)
			SortedSections := SortArray(SortedSections)
			FirstSection := true
			for _, sec in SortedSections {
					if !FirstSection {
							EnsureTrailingBlankLines(TOML_ParseKeyPath(sec).Length > 1 ? 3 : 5)
					}
					FirstSection := false
					body .= "[" . sec . "]`n"
					; Sort keys alphabetically within each section
					SortedKeys := []
					for k, v in RenderingSections[sec]
							SortedKeys.Push(k)
					SortedKeys := SortArray(SortedKeys)
					for _, k in SortedKeys
							body .= TOML_RenderKey(k) . " = " . TOML_RenderValue(RenderingSections[sec][k]) . "`n"
			}
			try Admitted := _TOML_AdmitExactPrefixCandidate(SourceBytes, Parsed, Sections, Chr(0xFEFF) . body,
				Updates, ExactSectionPrefixes)
			catch as Err {
					try LoggerError("TomlWrite", "Refusing TOML {1} for '{2}': {3}. No file was changed.", Mode, Path, Err.Message)
					return false
			}
		}
		if !_TOML_WriteSourceMatches(SourcePath, SourcePresent, SourceBytes) {
				; Detached builds never own the live reader cache. An ordinary
				; write must retire its now-stale snapshot after actual source drift.
				if !BuildOnly {
						_TOML_InvalidateParseCache(Path)
				}
				try LoggerError("TomlWrite", "Refusing TOML {1} for '{2}': the source changed during candidate preparation. No file was changed.", Mode, Path)
				return false
		}
		if BuildOnly {
				HotPath_LogIfSlow("Config.TomlBuild", _hpTomlWrite,
					Updates.Length . " update(s)")
				; Return the byte image ordinary write mode would stage, so a transition
				; publishes exactly what a direct save would.
				return Map("status", "ok", "kind", "rendered",
					"content", Admitted["content"], "preserve_source", Admitted["preserve_source"])
		}

		; Admission may retain foreign physical records around canonical owned rows.
		; Both detached and ordinary modes publish this one qualified image.
		FinalCandidate := Admitted["content"]
		HasByteOrderMark := SubStr(FinalCandidate, 1, 1) == Chr(0xFEFF)
		body := HasByteOrderMark ? SubStr(FinalCandidate, 2) : FinalCandidate
		NativeNoop := Admitted["preserve_source"]
		SchemaAdmission := DocumentMode ? (NativeNoop ? ConfigMigrateBoot(Path, "capture_noop")
			: ConfigMigrateBoot(Path, "capture_write", FinalCandidate)) : 0
		if DocumentMode && !HasMethod(SchemaAdmission, "Call") {
			try LoggerError("TomlWrite", "Refusing configuration writer: genuine source schema admission was not captured.")
			return false
		}
		; These scalars come from this native writer's actual source/candidate,
		; not mutable public caches or a caller-provided registration receipt.
		FinalAdmission() {
			return _FSNativeAdmissionAccepted(AdmissionFn)
				&& (!DocumentMode || (NativeNoop ? SchemaAdmission.Call(SourceBytes, SourcePresent)
					: SchemaAdmission.Call(SourceBytes, SourcePresent, FinalCandidate)))
		}

		if Admitted["preserve_source"] {
				if !FSNativeAcknowledge(FinalAdmission) {
					try LoggerError("TomlWrite", "Refusing unchanged-source acknowledgment: genuine native admission was withdrawn.")
					return false
				}
				_TOML_InvalidateParseCache(Path)
				HotPath_LogIfSlow("Config.TomlBuild", _hpTomlWrite,
					"unchanged source namespaces; " . Updates.Length . " operation(s)")
				return true
		}

		; A qualified image already on disk needs no stage or atomic replacement.
		; Keep the generation acknowledgement while preserving its existing inode.
		if FileExist(SourcePath) && FSUtf8ExactMatches(SourcePath, FinalCandidate) {
				if !FSNativeAcknowledge(FinalAdmission) {
					try LoggerError("TomlWrite", "Refusing unchanged-image acknowledgment: genuine native admission was withdrawn.")
					return false
				}
				_TOML_InvalidateParseCache(Path)
				HotPath_LogIfSlow("Config.TomlBuild", _hpTomlWrite,
					"unchanged image; " . Updates.Length . " operation(s)")
				return true
		}

		; Exclusive creation and retained-handle publication protect this exact
		; candidate from foreign stage names through readback, rename and cleanup.
		static WriteSeq := 0
		WriteSeq += 1
		Suffix := "." . A_ScriptHwnd . "-" . WriteSeq . ".tmp"
		_TOML_ReapStaleTemps(SourcePath, StaleTempAgeMs())
		Stage := {handle: -1}
		Published := FSWriteReplaceOwned(SourcePath, FinalCandidate, Suffix, &StageDetail,
			_TOML_CreateHeldStage.Bind(Stage),
			_TOML_AdmitHeldStage.Bind(Stage, SourcePath, SourcePresent, SourceBytes, FinalCandidate),
			FinalAdmission, SourcePresent, &Publication, HeldFlushFn)
		if !((Published is Integer) && Published == 1) {
			_TOML_InvalidateParseCache(Path)
			if Publication is Object && Publication.renamed && !Publication.durable {
				_TOML_RecordPartialPublication(Path, Publication)
				try LoggerError("TomlWrite", "Native publication of '{1}' occurred but was not fully acknowledged ({2}). This session refuses further writes until restart.", Path, StageDetail)
			} else {
				try LoggerError("TomlWrite", "Owned staging/publication of '{1}' refused ({2}). No target was replaced.", Path, StageDetail)
			}
			return false
		}

		; Invalidate the parse cache so the next ParseTomlFile call re-reads
		; the updated file rather than returning a stale snapshot.
		_TOML_InvalidateParseCache(Path)

		HotPath_LogIfSlow("Config.TomlWrite", _hpTomlWrite, Updates.Length . " update(s)")
		return true
}

_TOML_CreateHeldStage(State, Folder, Name, Attributes) {
	Handle := _FSCreateHeldStage(Folder, Name, Attributes)
	State.handle := Handle
	return Handle
}

_TOML_ReadHeldStage(State, IgnoredPath) {
	_FSRewind(State.handle)
	return _FSReadUtf8ExactHandle(State.handle, 0, false)
}

; Native readback and the original exact-source witness run outside Critical.
; The final memory-only schema/lease predicate remains at the native rename.
_TOML_AdmitHeldStage(State, Path, SourcePresent, SourceBytes, Candidate) {
	return _TOML_StageMatches(Path, Candidate, _TOML_ReadHeldStage.Bind(State))
		&& _TOML_WriteSourceMatches(Path, SourcePresent, SourceBytes)
}

TOML_RenderKey(k) {
		if k is String
				SourceTextRequireUnicodeScalars(StrPtr(k), 0, StrLen(k))
		; Bare key: only A-Z / a-z / 0-9 / _ / -. Otherwise quote.
		if RegExMatch(k, "^[A-Za-z0-9_\-]+$")
				return k
		esc := TOML_EscapeBasicStringContents(k)
		return '"' . esc . '"'
}

TOML_RenderValue(v, Ancestors := unset) {
		; TOML_Bool sentinel: boolean intent carried explicitly from the call site.
		; Must be checked before IsNumber() — TOML_Bool wraps true/false as integers
		; so IsNumber() would match them and emit "1"/"0" otherwise.
		if (v is TOML_Bool)
				return v.Value ? "true" : "false"
		; Numeric-looking strings are still text. IsNumber and Boolean equality
		; accept digit strings and would otherwise discard their TOML type.
		if (v is String)
				return TOML_RenderString(v)
		; Arrays before numbers so nested array items iterate correctly.
		if (v is Array || v is Map) {
				if !IsSet(Ancestors)
						Ancestors := Map()
				if Ancestors.Has(v)
						throw ValueError("TOML collections cannot contain a reference cycle")
				Ancestors[v] := true
				try {
						parts := []
						if v is Map {
								for k, s in v {
										if !(k is String)
												throw TypeError("TOML inline table keys must be strings")
										parts.Push(TOML_RenderKey(k) . " = " . TOML_RenderValue(s, Ancestors))
								}
						} else {
								for s in v
										parts.Push(TOML_RenderValue(s, Ancestors))
						}
						out := v is Map ? "{" : "["
						for i, p in parts
								out .= (i = 1 ? "" : ", ") . p
						out .= v is Map ? "}" : "]"
						return out
				} finally Ancestors.Delete(v)
		}
		if IsNumber(v) {
				if v is Float {
						if !NumberTryParseFiniteFloat(v, &FiniteValue)
								throw ValueError("TOML serialization requires a finite Float")
						; Seventeen significant digits retain every binary64 value. A
						; whole-valued Float still needs a float-shaped TOML literal.
						Rendered := Format("{:.17g}", FiniteValue)
						return InStr(Rendered, ".") || InStr(Rendered, "e") ? Rendered : Rendered . ".0"
				}
				return String(v)
		}
		if (v = true)
				return "true"
		if (v = false)
				return "false"
		return TOML_RenderString(String(v))
}

TOML_RenderString(s) {
		return '"' . TOML_EscapeBasicStringContents(s) . '"'
}





; =================================
; =================================
; ======= 5/ Cache accessor =======
; =================================
; =================================

; Look up Section/Key in a parsed cache (the Map produced by
; ``ParseTomlFile``). Returns ``Default`` (defaulting to the underscore
; sentinel) when the cache, section, or key is absent or malformed. A config
; file may temporarily contain a scalar where a section Map is expected after
; a failed hand edit or migration; treat that exactly like a missing section so
; a preference read can never abort application startup. Callers compare
; against "_" to detect missing entries cheaply.
IniCacheGet(Cache, Section, Key, Default := "_") {
		if !(Cache is Map) or !Cache.Has(Section)
				return Default
		SectionCache := Cache[Section]
		if !(SectionCache is Map) or !SectionCache.Has(Key)
				return Default
		return SectionCache[Key]
}

; Read a Section/Key from a parsed cache as a boolean. This exists because
; ``IniCacheGet`` returns the stored value verbatim, and ``ParseTomlFile`` has
; already run it through ``TOML_CoerceValue`` — so a TOML ``true`` arrives as a
; real AHK boolean, NOT as the string "true". Comparing it with
; ``StrLower(v) == "true"`` is a legal, non-throwing, always-false expression,
; which is exactly how the onboarding wizard silently read every enabled
; setting as disabled. Every caller that wants a boolean out of a cache must
; come through here rather than rolling its own test.
;
; Accepts every shape the value can legitimately have on disk: a real boolean
; from the parser, the 1/0 the driver's own writers have emitted, and the
; literal strings from a hand-edited file. A missing key reads as false.
TomlCacheBool(Cache, Section, Key) {
		Value := IniCacheGet(Cache, Section, Key)
		if (Value == true or Value == 1)
				return true
		return (Type(Value) == "String" and StrLower(Trim(Value)) == "true")
}

; Resolve a configured path: trim whitespace, treat empty / underscore as
; "use the default", otherwise return the trimmed value.
ResolveConfigPath(RawValue, DefaultPath) {
		Trimmed := Trim(RawValue)
		if (Trimmed == "" or Trimmed == "_") {
				return DefaultPath
		}
		return Trimmed
}





; ====================================
; ====================================
; ======= 6/ paths.toml reader =======
; ====================================
; ====================================

; Reads a simple flat TOML file (Key = "value" pairs, ignores comments).
; Auto-generates the file with a header comment if it does not exist.
; Returns a Map of all parsed key-value pairs.
ReadPathsToml(FilePath) {
		Result := Map()

		if !FileExist(FilePath) {
				; Ensure the parent directory exists — in compiled mode FilePath lives in
				; %LOCALAPPDATA%\Ergopti\ which may not exist yet on a fresh install.
				try DirCreate(SubStr(FilePath, 1, InStr(FilePath, "\", , -1) - 1))

				if !FileExist(FilePath) {
						DefaultDir := StrReplace(AppFoldersDefaultConfigDir(), "\", "/")
						DefaultText := Chr(0xFEFF) . "# Custom paths — auto-generated by ErgoptiPlus.`r`n"
								. "# Edit this file to point to your personal configuration folder.`r`n"
								. "# If absent or commented out, files are looked up in: " . DefaultDir . "`r`n"
								. "`r`n# ConfigDirPath = " . Chr(34) . DefaultDir . Chr(34) . "`r`n"
						Created := false
						try Created := FSWriteCreateDurable(FilePath, DefaultText)
						if (Created is Integer) && Created == 1
								return Result
						; CREATE_NEW cannot adopt a concurrent locator. If another owner
						; won, consume that exact file through the ordinary reader below.
						if !FileExist(FilePath)
								return Result
				}
		}

		; Read as UTF-8 to match the writer (FileOpen(..., "UTF-8")) and every other
		; reader in this unit. A BOM-less paths.toml hand-saved as UTF-8 would otherwise
		; be decoded with the system codepage, turning a non-ASCII ConfigDirPath
		; (accented Windows home dir) into mojibake and silently losing the user's config.
		; Guarded. This runs during the auto-execute section, BEFORE the logger is
		; initialised and while hotkeys registered at parse time are already armed —
		; so an unguarded throw here aborts the boot mid-way and leaves a resident
		; half-driver with a subset of hotkeys live. A locked paths.toml (a sync
		; client, an AV scan) is exactly the transient condition that triggers it.
		;
		; Returning the empty Map falls back to the default config directory, which
		; is the same behaviour as a paths.toml that exists but sets nothing. That is
		; safe here BECAUSE this file only ever redirects where config is READ from:
		; nothing serializes back through it, so there is no defaults-over-real-file
		; hazard of the kind the config readers have.
		Content := ""
		try {
				; Retain one exact source image; lossy decoding can name another profile.
				Bytes := FileRead(FilePath, "RAW")
				Content := SourceTextDecodeExact(Bytes)
		} catch as Err {
				try LoggerError("TomlPaths", "Cannot read '{1}': {2}. Falling back to the default configuration directory for this session.", FilePath, Err.Message)
				return Result
		}
		; The locator is TOML too: decode quoted key identities and string escapes
		; through the same semantic owner as the rest of the configuration. A raw
		; line capture can redirect boot to a different profile or lose the override.
		for Key, Value in TOML_ParseDocument(Content) {
				if Value is String
						Result[Key] := StrReplace(Value, "/", "\")
		}
		return Result
}
