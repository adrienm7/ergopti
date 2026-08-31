; infra/toml/toml_helpers.ahk

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
; 4. Section-scoped batch write: ``TOML_BatchWrite`` rewrites every section
;    in one go (read once, modify in memory, write once). Comments are not
;    preserved because the file is fully driver-managed; section ORDER is
;    stable across writes.
; ==============================================================================

#Requires Autohotkey v2.0+

#Include ../number.ahk





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

; Parse a TOML file into Map<Section, Map<Key, Value>>. Values are coerced
; to AHK booleans / integers / strings / arrays of strings — anything more
; exotic falls through as a raw string. Returns an empty Map when the file
; is missing so callers can rely on ``.Has`` checks without a prior
; ``FileExist``.
; Multi-line arrays ( key = [\n  "a",\n  "b"\n] ) are fully supported.
ParseTomlFile(Path) {
		return _ParseTomlFileImpl(Path, true, true)
}

; Transactional candidate rendering must observe bytes only after its terminal
; owner is acquired. It therefore bypasses the boot/UI cache and deliberately
; does not replace that cache object; a refused Reload continues on the exact
; pre-transition in-memory state.
TOML_ParseFreshFile(Path) {
		return _ParseTomlFileImpl(Path, false, false)
}

_ParseTomlFileImpl(Path, UseCache, StoreCache, ProvidedContent := unset) {
		global _ParseTomlCache, _TomlReadFailures, _TomlUnreadableFiles
		if UseCache && _ParseTomlCache.Has(Path)
				return _ParseTomlCache[Path]
		Sections := Map()
		; Map.Delete raises on a missing key, so this must be guarded.
		if _TomlReadFailures.Has(Path)
				_TomlReadFailures.Delete(Path)
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
				_TomlReadFailures[Path] := true
				; Raise the STICKY sentinel too, exactly as ReadTomlFile does for the
				; same file. _TomlReadFailures is deleted at the top of the very next
				; parse of this path, so a lock that clears between the boot snapshot
				; and a deferred save is invisible to every writer that asks later —
				; and _IniCache, the widest reader of config.toml, is taken through
				; here. Only for an existing file: a missing one legitimately parses
				; empty, and flagging it would block the first save of a fresh install.
				if FileExist(Path)
						_TomlUnreadableFiles[Path] := true
				try LoggerError("TomlParse", "Cannot read '{1}': {2}. Reported as unreadable so writers refuse to rebuild from it.", Path, Err.Message)
				return Sections
		}
		; A successful read clears the sticky flag: what follows is the real file,
		; so anything derived from it is safe to persist again.
		if _TomlUnreadableFiles.Has(Path)
				_TomlUnreadableFiles.Delete(Path)
		if SubStr(Content, 1, 1) == Chr(0xFEFF)
				Content := SubStr(Content, 2)
		if (Content = "")
				return Sections

		Section     := ""
		PendingKey  := ""   ; key whose value spans multiple lines
		PendingVal  := ""   ; accumulated raw characters of the multi-line value

		loop parse, Content, "`n", "`r" {
				Line := Trim(A_LoopField)

				; --- Continuation of a multi-line array ---
				if (PendingKey != "") {
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
						if (SubStr(Stripped, 1, 1) == "[") {
								try LoggerWarn("TomlParse", "Unterminated multi-line array for key '{1}' in [{2}] - aborting array, resuming section parse.", PendingKey, Section)
								PendingKey := ""
								PendingVal := ""
								Section := Trim(RegExReplace(Line, "^\[+|\]+$", ""))
								if !Sections.Has(Section)
										Sections[Section] := Map()
								continue
						}
						PendingVal .= " " . Line
						; Count only unquoted brackets to detect the real terminator.
						Depth := _TOML_ArrayBracketDepth(PendingVal)
						if (Depth <= 0) {
								if !Sections.Has(Section)
										Sections[Section] := Map()
								Sections[Section][PendingKey] := TOML_CoerceValue(Trim(PendingVal))
								PendingKey := ""
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
						if !Sections.Has(Section)
								Sections[Section] := Map()
						continue
				}

				eq := InStr(Line, "=")
				if !eq
						continue
				key := Trim(SubStr(Line, 1, eq - 1))
				val := Trim(SubStr(Line, eq + 1))
				; Quoted key: "Foo.Enabled" → Foo.Enabled
				if (StrLen(key) >= 2 && SubStr(key, 1, 1) = '"' && SubStr(key, -1) = '"')
						key := SubStr(key, 2, StrLen(key) - 2)
				if (Section = "")
						continue

				; Strip an inline comment, quote-aware so a hash inside the string
				; stays data and a hash after the closing quote is still a comment.
				val := TOML_StripInlineComment(val)

				; A quoted ] on the opening line is data, not the array terminator.
				if (SubStr(val, 1, 1) = "["
						&& _TOML_ArrayBracketDepth(val) > 0) {
						PendingKey := key
						PendingVal := val
						continue
				}

				Sections[Section][key] := TOML_CoerceValue(val)
		}
		if (PendingKey != "")
				try LoggerWarn("TomlParse", "Unterminated multi-line array for key '{1}' reached EOF in [{2}] - the value is lost.", PendingKey, Section)
		if StoreCache
			_ParseTomlCache[Path] := Sections
		return Sections
}

; Return the net bracket depth outside double-quoted TOML strings. Backslash
; escapes are consumed only inside a string so an escaped quote cannot expose a
; data bracket to the structural scanner.
_TOML_ArrayBracketDepth(Value) {
		Depth := 0
		InString := false
		Escaped := false
		Loop Parse Value {
				Char := A_LoopField
				if Escaped {
						Escaped := false
						continue
				}
				if (InString and Char == "\") {
						Escaped := true
						continue
				}
				if (Char == '"') {
						InString := !InString
						continue
				}
				if !InString {
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
; Only the double quote opens a string, because that is the only string form
; TOML_CoerceValue understands. Tracking the apostrophe as well would break
; every unquoted value that legitimately contains one. A backslash escapes the
; next character, so an escaped quote does not end the string.
TOML_StripInlineComment(Line) {
		InQuote := false
		Escaped := false
		Loop Parse Line {
				if (Escaped) {
						Escaped := false
						continue
				}
				if (A_LoopField == "\" && InQuote) {
						Escaped := true
						continue
				}
				if (A_LoopField == '"') {
						InQuote := !InQuote
						continue
				}
				if (!InQuote && A_LoopField == "#")
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
 * Parses one plain decimal float only when AutoHotkey can represent it as a
 * finite IEEE-754 binary64 value. Float(String) otherwise returns +/-infinity,
 * which still passes AHK's numeric type checks and corrupts later arithmetic.
 */
TOML_TryParseFloat(Raw, &Value) {
		Value := ""
		if !RegExMatch(Raw, "^-?\d+\.\d+$")
				return false
		return NumberTryParseFiniteFloat(Raw, &Value)
}

/** Parses one bounded TOML integer or finite plain decimal float. */
TOML_TryParseNumber(Raw, &Value) {
		if TOML_TryParseInteger(Raw, &Value)
				return true
		return TOML_TryParseFloat(Raw, &Value)
}

TOML_CoerceValue(raw) {
		raw := Trim(raw)
		if (raw = "")
				return ""
		if (StrLower(raw) = "true")
				return true
		if (StrLower(raw) = "false")
				return false
		; Quoted string.
		if (SubStr(raw, 1, 1) = '"' && SubStr(raw, -1) = '"')
				return TOML_Unescape(SubStr(raw, 2, StrLen(raw) - 2))
		; Array of strings: [ "a", "b", ... ]
		if (SubStr(raw, 1, 1) = "[" && SubStr(raw, -1) = "]") {
				body := Trim(SubStr(raw, 2, StrLen(raw) - 2))
				out := []
				if (body = "")
						return out
				in_str := false
				escaped := false
				cur := ""
				loop parse, body {
						c := A_LoopField
						if escaped {
								escaped := false
						} else if (c = "\") {
								escaped := true
						} else if (c = '"') {
								in_str := !in_str
						}
						if (!in_str && c = ",") {
								out.Push(TOML_CoerceValue(Trim(cur)))
								cur := ""
								escaped := false
								continue
						}
						cur .= c
				}
				if (Trim(cur) != "")
						out.Push(TOML_CoerceValue(Trim(cur)))
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
	Result := ""
	Loop Parse, String(s) {
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
; key is missing. Coerces back to the closest AHK type — booleans become
; integers (1 / 0) so legacy callers that compare against ``true`` / ``1``
; keep working without changes.
TOML_Read(Path, Section, Key, Default := "") {
		Sections := ParseTomlFile(Path)
		if !Sections.Has(Section) || !Sections[Section].Has(Key)
				return Default
		v := Sections[Section][Key]
		if (v = true)
				return 1
		if (v = false)
				return 0
		return v
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

; Apply every (Section, Key, Value) update in one read-modify-write cycle.
; Preserves keys we did not touch and renders the complete result canonically
; (sorted sections/keys and stable spacing) before the one atomic replace.
; It must not call SaveFullConfig afterward: targeted writers persist before
; publishing their candidate globals, so a nested full save would serialize
; the stale live state back over the just-committed values.
; Delete scratch files left next to Path by a hard kill. Per-invocation names
; no longer overwrite each other, so nothing self-cleans any more; the age
; threshold is what keeps this a tidy-up rather than a new race — an
; unconditional sweep would delete a concurrent writer's live staging file.
_TOML_ReapStaleTemps(Path, MaxAgeMs) {
		SplitPath(Path, &Name, &Dir)
		if (Dir = "" or Name = "")
				return
		try {
				Loop Files, Dir . "\" . Name . ".*.tmp" {
						if (DateDiff(A_Now, A_LoopFileTimeModified, "Seconds") * 1000 >= MaxAgeMs)
								try FileDelete(A_LoopFileFullPath)
				}
		}
}

; A successful Write call is not proof that the complete canonical image
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

; Builds the same canonical image used by TOML_BatchWrite without publishing a
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
		SourceBytes)
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

TOML_BatchWrite(Path, Updates, ExactSectionPrefixes := []) {
		return _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write")
}

_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, Mode,
		ProvidedContent := unset) {
		if !(Mode is String) || (Mode != "write" && Mode != "build")
				throw ValueError("TOML_BatchWrite mode must be 'write' or 'build'")
		BuildOnly := Mode == "build"
		if !(ExactSectionPrefixes is Array)
				throw TypeError("ExactSectionPrefixes must be an Array")
		for _, Prefix in ExactSectionPrefixes {
				if !(Prefix is String) or Prefix = ""
						throw ValueError("ExactSectionPrefixes must contain non-empty strings")
		}
		if (!BuildOnly && Updates.Length = 0 and ExactSectionPrefixes.Length = 0)
				return true

		; A config save is a full read-modify-write plus a canonicalisation pass, and
		; it runs from menu callbacks — so a slow one blocks the tray menu while the
		; user watches. It had no segment at all; the cost showed up only as a menu
		; that felt stuck. Two QPC reads, gated by the profiler floor.
		_hpTomlWrite := HotPath_Now()

		Parsed := BuildOnly && IsSet(ProvidedContent)
			? _ParseTomlFileImpl(Path, false, false, ProvidedContent)
			: TOML_ParseFreshFile(Path)
		; Refuse to rebuild a file we could not read. Everything below serializes
		; ONLY what this parse returned and then moves the result over the original,
		; so proceeding on a failed read would replace the user's whole config with
		; the handful of keys in Updates. "I could not read it" must never be
		; allowed to mean "it was empty".
		if TOML_ReadFailed(Path) {
				try LoggerError("TomlWrite", "Refusing to write '{1}': the current contents could not be read, and rewriting from an unread file would discard every setting it holds.", Path)
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
						DropSection := false
						for _, Prefix in ExactSectionPrefixes {
								if (SecName = Prefix or InStr(SecName, Prefix . ".") = 1) {
										DropSection := true
										break
								}
						}
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

		; Sort sections alphabetically for stable, readable output
		SortedSections := []
		for sec in order
				SortedSections.Push(sec)
		SortedSections := SortArray(SortedSections)
		FirstSection := true
		for _, sec in SortedSections {
				if !FirstSection {
						EnsureTrailingBlankLines(5)
				}
				FirstSection := false
				body .= "[" . sec . "]`n"
				; Sort keys alphabetically within each section
				SortedKeys := []
				for k, v in Sections[sec]
						SortedKeys.Push(k)
				SortedKeys := SortArray(SortedKeys)
				for _, k in SortedKeys
						body .= TOML_RenderKey(k) . " = " . TOML_RenderValue(Sections[sec][k]) . "`n"
		}
		if BuildOnly {
				HotPath_LogIfSlow("Config.TomlBuild", _hpTomlWrite,
					Updates.Length . " update(s)")
				; Ordinary write mode opens its stage as UTF-8 (with BOM). Return the
				; identical byte image so the transition does not silently change the
				; repository's canonical encoding policy.
				return Map("status", "ok", "kind", "rendered",
					"content", Chr(0xFEFF) . body)
		}

		; Per-invocation scratch name. A fixed ``Path . ".tmp"`` made the staging
		; file a shared resource between every writer of the same target, and the
		; delete below is unconditional — so a save that interrupted another one
		; destroyed its live staging file, and whichever writer landed last decided
		; what the config ended up as. config.toml is written both from menu actions
		; and from timer-driven saves, so the two really can overlap. A_ScriptHwnd
		; rather than a GetCurrentProcessId DllCall: unique per process all the
		; same, and it keeps the OS-call purity ratchet at its baseline.
		static STALE_TEMP_MS := 60000  ; Older than this, a scratch file is debris from a hard kill
		static WriteSeq := 0
		WriteSeq += 1
		tmp := Path . "." . A_ScriptHwnd . "-" . WriteSeq . ".tmp"
		_TOML_ReapStaleTemps(Path, STALE_TEMP_MS)
		try FileDelete(tmp)
		f := 0
		try {
				f := FileOpen(tmp, "w", "UTF-8")
				if !f {
						global _ParseTomlCache
						if _ParseTomlCache.Has(Path)
								_ParseTomlCache.Delete(Path)
						; Logged, not merely returned. This branch fails without throwing, and
						; every caller that discarded the boolean turned it into a silent
						; no-op: the menu and the engine went on showing a state that never
						; reached disk, with nothing in the log to explain the next restart.
						try LoggerError("TomlWrite", "Cannot open the staging file for '{1}' — nothing was written and the change is NOT persisted.", Path)
						return false
				}
				f.Write(body)
				if !FSFlushFileBuffers(f)
						throw Error("FlushFileBuffers refused the staging handle")
				f.Close()
				f := 0
		} catch as Err {
				global _ParseTomlCache
				if _ParseTomlCache.Has(Path)
						_ParseTomlCache.Delete(Path)
				try LoggerError("TomlWrite", "Writing the staging file for '{1}' failed: {2}. The change is NOT persisted.", Path, Err.Message)
				return false
		} finally {
				if IsObject(f)
						try f.Close()
		}
		if !_TOML_StageMatches(tmp, body) {
				global _ParseTomlCache
				if _ParseTomlCache.Has(Path)
						_ParseTomlCache.Delete(Path)
				try LoggerError("TomlWrite", "The staging file for '{1}' did not match the complete canonical image. The previous contents are intact, so the change is NOT persisted.", Path)
				return false
		}
	; Publish only through the same-volume write-through adapter. The WAL may
	; promote immediately after this return, so a merely visible rename is not a
	; sufficient durability boundary.
	Moved := FSAtomicMoveReplace(tmp, Path)
	if !((Moved is Integer) && Moved == 1) {
		global _ParseTomlCache
		if _ParseTomlCache.Has(Path)
			_ParseTomlCache.Delete(Path)
		try LoggerError("TomlWrite", "Write-through atomic replace of '{1}' was refused. The previous contents are intact, so the change is NOT persisted.", Path)
		return false
	}

		; Invalidate the parse cache so the next ParseTomlFile call re-reads
		; the updated file rather than returning a stale snapshot.
		global _ParseTomlCache
		if _ParseTomlCache.Has(Path)
				_ParseTomlCache.Delete(Path)

		HotPath_LogIfSlow("Config.TomlWrite", _hpTomlWrite, Updates.Length . " update(s)")
		return true
}

TOML_RenderKey(k) {
		; Bare key: only A-Z / a-z / 0-9 / _ / -. Otherwise quote.
		if RegExMatch(k, "^[A-Za-z0-9_\-]+$")
				return k
		esc := TOML_EscapeBasicStringContents(k)
		return '"' . esc . '"'
}

TOML_RenderValue(v) {
		; TOML_Bool sentinel: boolean intent carried explicitly from the call site.
		; Must be checked before IsNumber() — TOML_Bool wraps true/false as integers
		; so IsNumber() would match them and emit "1"/"0" otherwise.
		if (v is TOML_Bool)
				return v.Value ? "true" : "false"
		; Arrays before numbers so nested array items iterate correctly.
		if (v is Array) {
				parts := []
				for s in v
						parts.Push(TOML_RenderString(String(s)))
				out := "["
				for i, p in parts
						out .= (i = 1 ? "" : ", ") . p
				out .= "]"
				return out
		}
		if IsNumber(v) {
				; Use %g format to strip floating-point noise (0.20000000000000001 → 0.2)
				if v is Float
						return Format("{:.10g}", v)
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
				; %APPDATA%\Ergopti\ which may not exist yet on a fresh install.
				try DirCreate(SubStr(FilePath, 1, InStr(FilePath, "\", , -1) - 1))

				; Migration: the previous compiled location was inside the bundle dir
				; (%LocalAppData%\Ergopti\bundle\paths.toml) which is wiped on every update.
				; If the new stable location is empty but the old bundle-dir copy is still
				; present (race window before the next bundle wipe), carry it over so the
				; user's ConfigDirPath is not silently lost.
				LegacyPath := A_AppData . "\..\Local\Ergopti\bundle\paths.toml"
				if (A_IsCompiled and FileExist(LegacyPath)) {
						try FileCopy(LegacyPath, FilePath)
						; Fall through — if the copy succeeded FilePath now exists and we read it below
				}

				if !FileExist(FilePath) {
						try {
								f := FileOpen(FilePath, "w", "UTF-8")
								if f {
										DefaultDir := StrReplace(EnvGet("USERPROFILE"), "\", "/") . "/.config/ergopti_plus/"
										f.Write("# Custom paths — auto-generated by ErgoptiPlus.`r`n")
										f.Write("# Edit this file to point to your personal configuration folder.`r`n")
										f.Write("# If absent or commented out, files are looked up in: " . DefaultDir . "`r`n")
										f.Write("`r`n")
										f.Write('# ConfigDirPath = "' . DefaultDir . '"`r`n')
										f.Close()
								}
						}
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
				Content := FileRead(FilePath, "UTF-8")
		} catch as Err {
				try LoggerError("TomlPaths", "Cannot read '{1}': {2}. Falling back to the default configuration directory for this session.", FilePath, Err.Message)
				return Result
		}
		loop parse, Content, "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#") {
						continue
				}
				Line := TOML_StripInlineComment(Line)
				if RegExMatch(Line, '^(\S+)\s*=\s*"(.*)"$', &Match) {
						Result[Match[1]] := StrReplace(Match[2], "/", "\")
				}
		}
		return Result
}
