; infra/hotstrings/personal_toml_io.ahk

; ==============================================================================
; MODULE: Personal TOML I/O
; DESCRIPTION:
; Owns all file I/O for personal_hotstrings.toml and personal_info.toml.
; Provides path resolution, TOML parsing (ReadPersonalToml, ReadPersonalInfoToml),
; serialisation (WritePersonalToml, WritePersonalInfoToml), file-bootstrap
; (EnsurePersonalInfoTomlFile), output normalisation (NormaliseOutput,
; EscapeTomlValue), and live hotstring reload (ReloadPersonalSection).
; The UI layer (ui/personal_toml_editor.ahk) depends on this module for all
; disk operations; no file access is performed directly in the GUI code.
; ==============================================================================






; ===============================
; ===============================
; ======= 1/ Path helpers =======
; ===============================
; ===============================

; Return the configured path to personal_hotstrings.toml.
PersonalTomlPath() {
	global ScriptInformation
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalTomlPath") {
		return ScriptInformation["PersonalTomlPath"]
	}
	return A_ScriptDir . "\..\hotstrings\personal_hotstrings.toml"
}

; Return the configured path to personal_info.toml.
PersonalInfoTomlPath() {
	global ScriptInformation
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalInfoTomlPath") {
		return ScriptInformation["PersonalInfoTomlPath"]
	}
	return A_ScriptDir . "\..\hotstrings\personal_info.toml"
}





; ==========================================
; ==========================================
; ======= 2/ TOML read / write layer =======
; ==========================================
; ==========================================

; Escape a value for inclusion inside a TOML double-quoted string. Newlines
; and tabs are normalised to {Enter} and {Tab} tokens (rather than the TOML
; escape sequences \n / \t) so that the saved file uses a single canonical
; representation matching what NormaliseOutput emits and what the runtime
; Send treats as a key press. This guarantees the on-disk format never
; mixes raw \n with {Enter} for the same kind of payload.
EscapeTomlValue(s) {
	s := StrReplace(s, "`r`n", "{Enter}")
	s := StrReplace(s, "`r", "{Enter}")
	s := StrReplace(s, "`n", "{Enter}")
	s := StrReplace(s, "`t", "{Tab}")
	return TOML_EscapeBasicStringContents(s)
}

; Mirrors HS normalise_output: bare CRLF/LF become {Enter}, bare tabs become
; {Tab}, and {alias} tokens are canonicalised to their proper AHK {Token}
; form. Keeping newline/tab handling here as well as in EscapeTomlValue means
; outputs read from any source (textarea, legacy TOML, paste) end up with the
; same tokenised representation before serialisation.
NormaliseOutput(s) {
	s := StrReplace(s, "`r`n", "{Enter}")
	s := StrReplace(s, "`r", "{Enter}")
	s := StrReplace(s, "`n", "{Enter}")
	s := StrReplace(s, "`t", "{Tab}")

	Aliases := Map(
		"esc", "Escape", "escape", "Escape",
		"bs", "BackSpace", "backspace", "BackSpace",
		"del", "Delete", "delete", "Delete",
		"return", "Enter", "enter", "Enter",
		"left", "Left", "right", "Right",
		"up", "Up", "down", "Down",
		"home", "Home", "end", "End",
		"tab", "Tab", "pgup", "PgUp",
		"pgdn", "PgDn", "ins", "Insert",
		"insert", "Insert", "space", "Space",
	)

	Result := ""
	i := 1
	n := StrLen(s)
	while i <= n {
		c := SubStr(s, i, 1)
		if (c == "{") {
			; Find closing brace
			j := InStr(s, "}", , i + 1)
			if j {
				Inner := SubStr(s, i + 1, j - i - 1)
				Lower := StrLower(Inner)
				if Aliases.Has(Lower) {
					Result .= "{" . Aliases[Lower] . "}"
				} else {
					; Capitalise first letter for unknown tokens
					Result .= "{" . StrUpper(SubStr(Inner, 1, 1)) . SubStr(Inner, 2) . "}"
				}
				i := j + 1
				continue
			}
		}
		Result .= c
		i++
	}
	return Result
}

global _ReadPersonalTomlCache := false

; Validate the full-model ordering contract and return one stable key for every
; extant section. Duplicate order tokens are benign input corruption and collapse
; to their first occurrence; missing order tokens are appended so serialization
; can never silently omit a section that is still present in the model.
_PersonalTomlCanonicalSectionOrder(Data, &Detail) {
	Detail := ""
	if !(Data is Map) {
		Detail := "candidate data is not a Map"
		return false
	}
	if !Data.Has("sections") or !(Data["sections"] is Map) {
		Detail := "candidate sections is not a Map"
		return false
	}
	if !Data.Has("sections_order") or !(Data["sections_order"] is Array) {
		Detail := "candidate sections_order is not an Array"
		return false
	}

	Sections := Data["sections"]
	SectionKeys := Map()
	for SectionKey, SectionData in Sections {
		if !(SectionKey is String) or (Trim(SectionKey) == "") {
			Detail := "candidate sections contains a non-string or empty key"
			return false
		}
		if !(SectionData is Map) {
			Detail := "candidate section '" . SectionKey . "' is not a Map"
			return false
		}
		CanonicalName := StrLower(Trim(SectionKey))
		if SectionKeys.Has(CanonicalName) {
			Detail := "candidate sections contains case-equivalent keys for '"
				. CanonicalName . "'"
			return false
		}
		SectionKeys[CanonicalName] := SectionKey
	}

	Order := []
	Seen := Map()
	for CandidateName in Data["sections_order"] {
		if !(CandidateName is String) or (Trim(CandidateName) == "") {
			Detail := "candidate sections_order contains a non-string or empty name"
			return false
		}
		CanonicalName := StrLower(Trim(CandidateName))
		if !SectionKeys.Has(CanonicalName) {
			Detail := "candidate sections_order references missing section '"
				. CandidateName . "'"
			return false
		}
		if Seen.Has(CanonicalName)
			continue
		Seen[CanonicalName] := true
		Order.Push(SectionKeys[CanonicalName])
	}
	for CanonicalName, SectionKey in SectionKeys {
		if Seen.Has(CanonicalName)
			continue
		Seen[CanonicalName] := true
		Order.Push(SectionKey)
	}
	return Order
}

; Parse personal_hotstrings.toml into a structured object:
;   .sections_order  — Array of section names in meta order (or file order if no meta)
;   .sections        — Map(name → {description, entries[]})
;   .meta_description — string
ReadPersonalToml() {
	global _ReadPersonalTomlCache
	if (_ReadPersonalTomlCache != false)
		return _ReadPersonalTomlCache

	FilePath := PersonalTomlPath()
	Result := Map(
		"sections_order", [],
		"sections", Map(),
		"meta_description", t("editor.hotstrings.meta_desc"),
	)
	if !FileExist(FilePath) {
		_ReadPersonalTomlCache := Result
		return Result
	}

	Q := Chr(34)
	EntryPattern :=
		'i)^' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
		. '\s*=\s*\{\s*output\s*=\s*' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
		. '\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)'
		. '\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)'
		. '(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?'
		. '(?:\s*,\s*priority\s*=\s*([0-9]+))?\s*\}'

	; Guarded. An unguarded FileRead here threw out of the boot loader (personal
	; hotstrings simply vanished for the session) and out of the menu handlers
	; that call this at click time. Worse, the empty Result it would otherwise
	; produce is indistinguishable from a user with no personal hotstrings — and
	; WritePersonalToml serializes from exactly that shape, so a transient lock
	; could be turned into permanent deletion by the next edit.
	;
	; The unreadable-file sentinel is the same one the config readers use, so the
	; writer can ask rather than guess.
	Raw := ""
	global _TomlUnreadableFiles
	try {
		Raw := FileRead(FilePath, "UTF-8")
	} catch as Err {
		_TomlUnreadableFiles[FilePath] := true
		try LoggerError("PersonalToml", "Cannot read '{1}': {2}. No personal hotstrings are loaded this session, and writes to this file are blocked so the empty result cannot replace its contents.", FilePath, Err.Message)
		return Result
	}
	; Lower the latch the catch above raises. It is keyed by PATH in a
	; process-wide Map, and the only other code that clears it is ReadTomlFile —
	; which is never reached for this path when every personal section is
	; disabled. So one transient boot lock blocked EVERY personal-hotstrings save
	; for the rest of the session, even though this very reader had since
	; succeeded and _ReadPersonalTomlCache held the user's real model. The reader
	; that raises the latch has to be the reader that lowers it.
	if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(FilePath))
		_TomlUnreadableFiles.Delete(FilePath)
	; Normalise to LF so every line ends cleanly — eliminates CRLF anchor bugs
	FileContent := StrReplace(Raw, "`r`n", "`n")
	FileContent := StrReplace(FileContent, "`r", "`n")

	; ── Extract sections_order directly from raw content ──
	MetaOrder := []
	MetaDescriptions := Map()

	if RegExMatch(FileContent, "m)^sections_order\s*=\s*\[([^\]]+)\]", &OM) {
		for Token in StrSplit(OM[1], ",") {
			Token := Trim(Token, " `t`n" . Q)
			if (Token != "") {
				MetaOrder.Push(StrLower(Token))
			}
		}
	}

	if RegExMatch(FileContent, "m)^description\s*=\s*" . Q . "([^" . Q . "]*)" . Q, &DM) {
		Result["meta_description"] := DM[1]
	}

	; ── Extract [_meta.sections] descriptions via multiline scan ──
	; Locate the [_meta.sections] block and read until next [ header
	if RegExMatch(FileContent, "m)^\[_meta\.sections\]\n((?:(?!\[).+\n?)*)", &MS) {
		DescBlock := MS[1]
		Pos := 1
		KPat := "m)^([A-Za-z0-9_]+)\s*=\s*" . Q . "((?:[^" . Q . "\\]|\\.)*)" . Q
		while RegExMatch(DescBlock, KPat, &KM, Pos) {
			MetaDescriptions[StrLower(KM[1])] := UnescapeTomlString(KM[2])
			Pos := KM.Pos + KM.Len
		}
	}

	; ── Single pass: collect [[section]] entries ──
	CurrentSection := ""
	LineIndex := 0
	FileSectionOrder := []

	loop parse, FileContent, "`n" {
		LineIndex++
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		; [[section]] header
		if (SubStr(Line, 1, 2) == "[[" and SubStr(Line, -1) == "]") {
			CurrentSection := StrLower(SubStr(Line, 3, StrLen(Line) - 4))
			if !Result["sections"].Has(CurrentSection) {
				FileSectionOrder.Push(CurrentSection)
				Result["sections"][CurrentSection] := Map(
					"description", MetaDescriptions.Has(CurrentSection)
						? MetaDescriptions[CurrentSection]
						: CurrentSection,
					"entries", [],
					"line_start", LineIndex,
				)
			}
			continue
		}
		; [simple] header — reset section context
		if (SubStr(Line, 1, 1) == "[") {
			CurrentSection := ""
			continue
		}
		if (CurrentSection == "") {
			continue
		}
		if !RegExMatch(Line, EntryPattern, &EM) {
			continue
		}
		Entry := Map(
			"trigger", UnescapeTomlString(EM[1]),
			"output", UnescapeTomlString(EM[2]),
			"is_word", (EM[3] == "true"),
			"auto_expand", (EM[4] == "true"),
			"is_case_sensitive", (EM[5] == "true"),
			"final_result", (EM[6] == "true"),
			"strict_case", (EM[7] == "true"),
			; Empty string means "inherit the source default" (no per-entry key)
			"priority", _ParseEntryPriority(Line, ""),
			"line_index", LineIndex,
		)
		Result["sections"][CurrentSection]["entries"].Push(Entry)
	}

	; ── Build final sections_order: meta order first, then unlisted sections ──
	Seen := Map()
	for _, SecName in MetaOrder {
		if Result["sections"].Has(SecName) and !Seen.Has(SecName) {
			Result["sections_order"].Push(SecName)
			Seen[SecName] := true
		}
	}
	for _, SecName in FileSectionOrder {
		if !Seen.Has(SecName) {
			Result["sections_order"].Push(SecName)
			Seen[SecName] := true
		}
	}
	_ReadPersonalTomlCache := Result
	return Result
}

_PersonalTomlCleanupStage(StagePath, DeleteFn := 0, WarnFn := 0) {
	Deleted := false
	Detail := "delete adapter returned false"
	try {
		if HasMethod(DeleteFn, "Call")
			Deleted := DeleteFn.Call(StagePath) ? true : false
		else
			Deleted := FSDelete(StagePath)
	} catch as Err {
		Detail := Err.Message
	}
	if Deleted
		return true
	try {
		if HasMethod(WarnFn, "Call")
			WarnFn.Call(StagePath, Detail)
		else
			LoggerWarn("PersonalToml",
				"Could not clean unpublished staging file '{1}': {2}",
				StagePath, Detail)
	} catch as WarnErr {
		try LoggerWarn("PersonalToml",
			"Could not report staging residue for '{1}': {2}",
			StagePath, WarnErr.Message)
	}
	return false
}

_PersonalTomlInvalidateCaches(FilePath) {
	global _ReadPersonalTomlCache, _HS_GrandTotalCache
	_ReadPersonalTomlCache := false
	_HS_GrandTotalCache := -1
	; This also evicts the raw-content _TomlFileCache, group config, section
	; counts and resolve memo shared by the engine and prefix watcher.
	try _ParseTomlGroupConfig_InvalidatePath(FilePath)
}

; Personal TOML used to own a private path-only lease. That serialized its two
; editors with each other, but it remained invisible to a process-wide terminal
; transition: a paths relocation or Reload could close admission for config.toml
; while this sibling writer still entered the directory being abandoned. Keep
; the compatibility names used by the editor tests, but make the shared config
; lease the sole owner registry for every durable configuration store.
_PersonalTomlWriteLeaseTryAcquire(FilePath, Kind := "writer") {
	return _ConfigWriteLeaseTryAcquire(FilePath, "personal-toml-" . Kind)
}

_PersonalTomlWriteLeaseRelease(Token) {
	return _ConfigWriteLeaseRelease(Token)
}

_PersonalTomlWriteLeaseOwns(Token, FilePath := unset) {
	if IsSet(FilePath)
		return _ConfigWriteLeaseOwns(Token, FilePath)
	return _ConfigWriteLeaseOwns(Token)
}

; This callback is invoked by _PersonalTomlWriteAtomic after the complete stage
; exists, in a short memory-only Critical span before the atomic rename. The
; exact owner remains held across the subsequent non-Critical filesystem call.
_PersonalTomlAuthorizeOwnedWrite(OwnerToken, FilePath, AuthorizeFn := 0) {
	if !_PersonalTomlWriteLeaseOwns(OwnerToken, FilePath)
		return false
	if !HasMethod(AuthorizeFn, "Call")
		return true
	Result := AuthorizeFn.Call()
	if !(Result is Integer) || Result == 0
		return false
	; A yielding/injected guard may have invalidated its own owner. Never let an
	; authorization sampled before that callback authorize a stale replacement.
	return _PersonalTomlWriteLeaseOwns(OwnerToken, FilePath)
}

_PersonalTomlOverrideFields() {
	static Fields := ["delay", "color", "priority", "show_tooltip"]
	return Fields
}

; The hotstring configuration window owns these [_meta] override fields, while
; the personal editor owns descriptions, order and entries. A full editor save
; must carry the sibling writer's fields forward rather than silently deleting
; them. Keep their TOML literals raw so booleans, numbers and escaped colors
; round-trip without inventing a second serializer.
_PersonalTomlCaptureOverrides(FilePath) {
	Captured := Map(
		"ok", true,
		"detail", "",
		"file", Map(),
		"sections", Map()
	)
	if !FileExist(FilePath)
		return Captured
	try Raw := FileRead(FilePath, "UTF-8")
	catch as Err {
		Captured["ok"] := false
		Captured["detail"] := Err.Message
		return Captured
	}

	Known := Map()
	for Field in _PersonalTomlOverrideFields()
		Known[Field] := true
	Scope := 0
	Normalized := StrReplace(StrReplace(Raw, "`r`n", "`n"), "`r", "`n")
	loop parse, Normalized, "`n" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "[_meta]") {
			Scope := Captured["file"]
			continue
		}
		if RegExMatch(Line, "i)^\[_meta\.sections\.([a-z0-9_]+)\]$", &Header) {
			SectionName := StrLower(Header[1])
			if !Captured["sections"].Has(SectionName)
				Captured["sections"][SectionName] := Map()
			Scope := Captured["sections"][SectionName]
			continue
		}
		if (SubStr(Line, 1, 1) == "[") {
			Scope := 0
			continue
		}
		if !(Scope is Map)
			continue
		if RegExMatch(Line, "i)^(delay|color|priority|show_tooltip)\s*=\s*(.+?)\s*$", &FieldMatch) {
			Field := StrLower(FieldMatch[1])
			if Known.Has(Field)
				Scope[Field] := Trim(FieldMatch[2])
		}
	}
	return Captured
}

_PersonalTomlAppendOverrides(Lines, Overrides) {
	if !(Overrides is Map)
		return 0
	Added := 0
	for Field in _PersonalTomlOverrideFields() {
		if !Overrides.Has(Field)
			continue
		Lines.Push(Field . " = " . Overrides[Field])
		Added += 1
	}
	return Added
}

; Writes a complete same-directory stage, then publishes it with one atomic,
; write-through rename. No failure before that final OS call can alter the
; durable target: even a partial stage write is isolated under a unique name.
_PersonalTomlWriteAtomic(FilePath, Content, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0, PublishFn := 0) {
	static STALE_TEMP_MS := 60000
	static WriteSeq := 0
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; The process-wide path owner supplies isolation. Do not inherit a caller's
		; Critical state into stale-temp cleanup, staging or atomic replacement.
		Critical("Off")
		try return _PersonalTomlWriteAtomic(FilePath, Content, WriterFn,
			ReplaceFn, DeleteFn, AuthorizeFn, PublishFn)
		finally Critical(InheritedCritical)
	}
	HasPublisher := !((PublishFn is Integer) && PublishFn == 0)
	if HasPublisher && !HasMethod(PublishFn, "Call") {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': the live-publication callback is not callable.",
			FilePath)
		return false
	}
	LocalSeq := ++WriteSeq
	StagePath := FilePath . "." . A_ScriptHwnd . "-" . LocalSeq . ".tmp"
	_TOML_ReapStaleTemps(FilePath, STALE_TEMP_MS)
	_PersonalTomlCleanupStage(StagePath, DeleteFn)

	Written := false
	try Written := HasMethod(WriterFn, "Call")
		? WriterFn.Call(StagePath, Content)
		: FSWriteDurable(StagePath, Content)
	catch as Err {
		try LoggerError("PersonalToml",
			"Writing staging file for '{1}' failed: {2}. The previous contents are intact.",
			FilePath, Err.Message)
		_PersonalTomlCleanupStage(StagePath, DeleteFn)
		return false
	}
	Written := (Written is Integer) && Written == 1
	if !Written {
		try LoggerError("PersonalToml",
			"Writing staging file for '{1}' was refused. The previous contents are intact.",
			FilePath)
		_PersonalTomlCleanupStage(StagePath, DeleteFn)
		return false
	}

	Authorized := true
	AuthorizeError := ""
	PreviousCritical := Critical("On")
	try {
		try Authorized := HasMethod(AuthorizeFn, "Call")
			? AuthorizeFn.Call() : true
		catch as Err {
			Authorized := false
			AuthorizeError := Err.Message
		}
		Authorized := (Authorized is Integer) && Authorized != 0
	} finally {
		Critical(PreviousCritical)
	}
	if !Authorized {
		if (AuthorizeError != "") {
			try LoggerError("PersonalToml",
				"Authorization before publishing '{1}' failed: {2}. The previous contents are intact.",
				FilePath, AuthorizeError)
		} else {
			try LoggerError("PersonalToml",
				"Authorization before publishing '{1}' was refused. The previous contents are intact.",
				FilePath)
		}
		_PersonalTomlCleanupStage(StagePath, DeleteFn)
		return false
	}

	; Filesystem filters and antivirus can block an atomic rename. The exact
	; global owner stays held, but Critical must not span this OS call.
	Replaced := false
	ReplaceError := ""
	try Replaced := HasMethod(ReplaceFn, "Call")
		? ReplaceFn.Call(StagePath, FilePath)
		: FSAtomicMoveReplace(StagePath, FilePath)
	catch as Err {
		Replaced := false
		ReplaceError := Err.Message
	}
	Replaced := (Replaced is Integer) && Replaced == 1
	if !Replaced {
		if (ReplaceError != "") {
			try LoggerError("PersonalToml",
				"Atomic replace of '{1}' failed: {2}. The previous contents are intact.",
				FilePath, ReplaceError)
		} else {
			try LoggerError("PersonalToml",
				"Atomic replace of '{1}' was refused. The previous contents are intact.",
				FilePath)
		}
		_PersonalTomlCleanupStage(StagePath, DeleteFn)
		return false
	}

	; Publish only the already-validated memory projection in a second short
	; Critical span. The durable replacement has completed and ownership remains.
	Published := !HasPublisher
	PublishError := ""
	if HasPublisher {
		PreviousCritical := Critical("On")
		try {
			try Published := PublishFn.Call()
			catch as Err {
				Published := false
				PublishError := Err.Message
			}
			Published := (Published is Integer) && Published == 1
		} finally Critical(PreviousCritical)
	}
	if !Published {
		if (PublishError != "") {
			try LoggerError("PersonalToml",
				"Atomic replacement of '{1}' succeeded, but live publication failed: {2}. Reload is required to project the durable value.",
				FilePath, PublishError)
		} else {
			try LoggerError("PersonalToml",
				"Atomic replacement of '{1}' succeeded, but live publication was refused. Reload is required to project the durable value.",
				FilePath)
		}
		return false
	}
	return true
}

; Own the complete read-modify-publish lifetime of a metadata patch. Acquiring
; the path lease after the read still permits a sibling editor to publish in
; between, leaving this transaction to overwrite it from a stale snapshot.
; The durable target is never opened for writing: the candidate goes through
; the same same-directory stage and atomic replacement as a full editor save.
_PersonalTomlCommitPatch(FilePath, BuildFn, ReaderFn := 0, WriterFn := 0,
		ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _PersonalTomlCommitPatch(FilePath, BuildFn, ReaderFn,
			WriterFn, ReplaceFn, DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !HasMethod(BuildFn, "Call") {
		try LoggerError("PersonalToml",
			"Refusing to patch '{1}': no candidate builder was provided.", FilePath)
		return false
	}

	OwnerToken := _PersonalTomlWriteLeaseTryAcquire(FilePath, "metadata-patch")
	if !(OwnerToken is Object) {
		try LoggerError("PersonalToml",
			"Refusing to patch '{1}': another personal TOML transaction is already in progress.",
			FilePath)
		return false
	}

	try {
		if !FileExist(FilePath) {
			try LoggerError("PersonalToml",
				"Refusing to patch '{1}': the durable source file does not exist.",
				FilePath)
			return false
		}

		; ReadTomlFile is cached, so eviction must happen after ownership and
		; before the read. Otherwise a prior consumer can make this patch rebuild
		; from bytes that are no longer authoritative on disk.
		_PersonalTomlInvalidateCaches(FilePath)
		try CurrentContent := HasMethod(ReaderFn, "Call")
			? ReaderFn.Call(FilePath) : ReadTomlFile(FilePath)
		catch as Err {
			try LoggerError("PersonalToml",
				"Reading '{1}' for a metadata patch failed: {2}. The previous contents are intact.",
				FilePath, Err.Message)
			return false
		}
		if TOML_UnreadableFile(FilePath) {
			try LoggerError("PersonalToml",
				"Refusing to patch '{1}': its current contents could not be read. The previous contents are intact.",
				FilePath)
			return false
		}
		if !(CurrentContent is String) {
			try LoggerError("PersonalToml",
				"Refusing to patch '{1}': its reader returned a non-string snapshot.",
				FilePath)
			return false
		}

		try CandidateContent := BuildFn.Call(CurrentContent)
		catch as Err {
			try LoggerError("PersonalToml",
				"Building a metadata patch for '{1}' failed: {2}. The previous contents are intact.",
				FilePath, Err.Message)
			return false
		}
		if !(CandidateContent is String) {
			try LoggerError("PersonalToml",
				"Refusing to patch '{1}': its builder returned non-string content.",
				FilePath)
			return false
		}

		return _PersonalTomlWriteAtomic(FilePath, CandidateContent,
			WriterFn, ReplaceFn, DeleteFn,
			_PersonalTomlAuthorizeOwnedWrite.Bind(
				OwnerToken, FilePath, AuthorizeFn))
	} finally {
		; A yielded stage writer can repopulate caches from the old durable
		; target. Invalidate again after every terminal outcome before ownership
		; is released, so no sibling inherits that stale snapshot.
		_PersonalTomlInvalidateCaches(FilePath)
		_PersonalTomlWriteLeaseRelease(OwnerToken)
	}
}

; Serialise the full TOML structure back to disk.
; Writes [_meta], [_meta.sections], then all [[section]] blocks.
_PersonalTomlPrioritiesAreValid(Data, CanonicalOrder, &Detail) {
	Detail := ""
	for SectionName in CanonicalOrder {
		Section := Data["sections"][SectionName]
		for EntryIndex, Entry in Section["entries"] {
			if !Entry.Has("priority") || Entry["priority"] == ""
				continue
			if HotstringsTryPriority(Entry["priority"], &Priority)
				continue
			Detail := "section '" . SectionName . "' entry " . EntryIndex
				. " has a priority outside the integer 0..100 domain"
			return false
		}
	}
	return true
}

WritePersonalToml(Data, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		AuthorizeFn := 0, ExistingOwner := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return WritePersonalToml(Data, WriterFn, ReplaceFn, DeleteFn,
			AuthorizeFn, ExistingOwner)
		finally Critical(InheritedCritical)
	}
	FilePath := PersonalTomlPath()
	BorrowedOwner := ExistingOwner is Object
	if BorrowedOwner {
		if !_PersonalTomlWriteLeaseOwns(ExistingOwner, FilePath) {
			try LoggerError("PersonalToml",
				"Refusing to write '{1}' through a stale logical owner.", FilePath)
			return false
		}
		OwnerToken := ExistingOwner
	} else {
		OwnerToken := _PersonalTomlWriteLeaseTryAcquire(FilePath, "writer")
	}
	if !(OwnerToken is Object) {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': another personal TOML transaction is already in progress.",
			FilePath)
		return false
	}
	try {
	CanonicalDetail := ""
	CanonicalOrder := _PersonalTomlCanonicalSectionOrder(Data, &CanonicalDetail)
	if !(CanonicalOrder is Array) {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': {2}.", FilePath, CanonicalDetail)
		return false
	}
	if !_PersonalTomlPrioritiesAreValid(Data, CanonicalOrder, &PriorityDetail) {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': {2}.", FilePath, PriorityDetail)
		return false
	}
	; Refuse while the file is flagged unreadable. Data is built from what
	; ReadPersonalToml returned, and a failed read returns an EMPTY model that
	; looks exactly like "this user has no personal hotstrings" — serializing it
	; would replace the whole file with an empty one. The flag is cleared by any
	; successful read of the same path, so this unblocks itself as soon as the
	; transient lock clears and something re-reads.
	if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(FilePath)) {
		try LoggerError("PersonalToml", "Refusing to write '{1}': it could not be read, so the model in memory is empty rather than the user's hotstrings. Reopen the editor once the file is readable.", FilePath)
		return false
	}
	PreservedOverrides := _PersonalTomlCaptureOverrides(FilePath)
	if !PreservedOverrides["ok"] {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': its metadata overrides could not be read ({2}). The previous contents are intact.",
			FilePath, PreservedOverrides["detail"])
		return false
	}
	_PersonalTomlInvalidateCaches(FilePath)
	; The helper above evicts this module's editor-model cache. The engine
	; loader (LoadHotstringsSection) and the prefix-watcher read personal hotstrings
	; through the raw-content _TomlFileCache, which they do NOT touch. Without this
	; eviction the next live rebuild (any tray hotstring toggle -> RebuildHotstringsLive)
	; re-reads the STALE boot-time file content and silently reverts the edit just
	; saved to disk. Drop the reader-shared caches (raw content, group config, section
	; counts, resolve memo) too so the on-disk truth wins on the next read.
	Q := Chr(34)
	Lines := []

	MetaDesc := Data.Has("meta_description") ? Data["meta_description"] : t("editor.hotstrings.meta_desc")
	Lines.Push("[_meta]")
	Lines.Push("description = " . Q . EscapeTomlValue(MetaDesc) . Q)

	; Build sections_order as a TOML inline array
	OrderParts := []
	for SecName in CanonicalOrder {
		OrderParts.Push(Q . EscapeTomlValue(SecName) . Q)
	}
	Lines.Push("sections_order = [" . ArrayJoin(OrderParts, ", ") . "]")
	_PersonalTomlAppendOverrides(Lines, PreservedOverrides["file"])

	Lines.Push("[_meta.sections]")
	for SecName in CanonicalOrder {
		if Data["sections"].Has(SecName) {
			Desc := Data["sections"][SecName]["description"]
			Lines.Push(EscapeTomlValue(SecName) . " = " . Q . EscapeTomlValue(Desc) . Q)
		}
	}
	for SecName in CanonicalOrder {
		if !Data["sections"].Has(SecName)
			continue
		SecKey := StrLower(SecName)
		if !PreservedOverrides["sections"].Has(SecKey)
			continue
		SectionOverrides := PreservedOverrides["sections"][SecKey]
		if !(SectionOverrides is Map) || SectionOverrides.Count == 0
			continue
		Lines.Push("[_meta.sections." . SecName . "]")
		_PersonalTomlAppendOverrides(Lines, SectionOverrides)
	}

	for SecName in CanonicalOrder {
		if !Data["sections"].Has(SecName) {
			continue
		}
		Sec := Data["sections"][SecName]
		Lines.Push("[[" . SecName . "]]")
		for E in Sec["entries"] {
			IsWord := E["is_word"] ? "true" : "false"
			AutoExp := E["auto_expand"] ? "true" : "false"
			IsCaseSens := E["is_case_sensitive"] ? "true" : "false"
			Final := E["final_result"] ? "true" : "false"
			Line := Q . EscapeTomlValue(E["trigger"]) . Q
			. " = { output = " . Q . EscapeTomlValue(E["output"]) . Q
			. ", is_word = " . IsWord
			. ", auto_expand = " . AutoExp
			. ", is_case_sensitive = " . IsCaseSens
			. ", final_result = " . Final
			if E.Has("strict_case") and E["strict_case"] {
				Line .= ", is_case_sensitive_strict = true"
			}
			; Individual collision-priority override — written only when set so
			; entries that inherit the source default stay free of the key
			if E.Has("priority") and E["priority"] != "" {
				Line .= ", priority = " . E["priority"]
			}
			Line .= " }"
			Lines.Push(Line)
		}
	}

	Content := ""
	for i, L in Lines {
		Content .= L . "`r`n"
	}

	return _PersonalTomlWriteAtomic(FilePath, Content,
		WriterFn, ReplaceFn, DeleteFn,
		_PersonalTomlAuthorizeOwnedWrite.Bind(
			OwnerToken, FilePath, AuthorizeFn))
	} finally {
		; A read can interrupt the O(entries) serialization/staging window and
		; repopulate every cache from the OLD durable target. Evict again after
		; the terminal replace attempt so a successful rename cannot leave that
		; stale snapshot authoritative for the rest of the process.
		_PersonalTomlInvalidateCaches(FilePath)
		if !BorrowedOwner
			_PersonalTomlWriteLeaseRelease(OwnerToken)
	}
}

global _ReadPersonalInfoTomlCache := false

; Read personal_info.toml and atomically populate personal-info Maps.
; Format:
;   [info]
;   FirstName = "Adrien"
;   …
;   [letters]
;   a = "StreetAddress"
;   …
; Missing file is silently skipped (defaults remain).
ReadPersonalInfoToml(FilePath) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	if (_ReadPersonalInfoTomlCache != false) {
		PersonalInformation := _ReadPersonalInfoTomlCache["info"].Clone()
		PersonalInformationLetters := _ReadPersonalInfoTomlCache["letters"].Clone()
		return
	}

	if !FileExist(FilePath) {
		return
	}

	global _TomlUnreadableFiles
	try {
		FileContent := FileRead(FilePath, "UTF-8")
	} catch as e {
		; Latch the failure the way the personal_hotstrings.toml sibling above
		; already does. The placeholder identity left in PersonalInformation
		; ("Prénom", "FR00 0000 …", "1234 5678 9012 3456", "1 99 99 99 999 999
		; 99") is byte-for-byte what a user who never filled the form produces,
		; so WritePersonalInfoToml cannot tell the two apart at write time — and
		; by then the transient lock has cleared, so every write-time re-check
		; would pass. Without the latch, opening the editor once and clicking OK
		; overwrites the user's real IBAN, card number and SSN with the shipped
		; placeholders, unrecoverably.
		if IsSet(_TomlUnreadableFiles)
			_TomlUnreadableFiles[FilePath] := true
		LoggerError("hotstrings", "Could not read personal info TOML '{1}': {2}. Writes to this file are blocked so the placeholder identity cannot replace its contents.", FilePath, e.Message)
		return
	}
	; The read succeeded: the in-memory identity is the user's again, so the
	; writer may run. Same lower-what-you-raise rule as ReadPersonalToml.
	if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(FilePath))
		_TomlUnreadableFiles.Delete(FilePath)
	NextInformation := PersonalInformation.Clone()
	NextLetters := Map()
	SawLetters := false
	FileContent := StrReplace(FileContent, "`r`n", "`n")
	FileContent := StrReplace(FileContent, "`r", "`n")
	CurrentSection := ""

	loop parse, FileContent, "`n" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		; Section header
		if RegExMatch(Line, "^\[([a-z_]+)\]$", &HM) {
			CurrentSection := HM[1]
			continue
		}
		; Key = "value" pair
		if RegExMatch(Line, 'i)^(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', &KM) {
			Key := KM[1]
			Val := UnescapeTomlString(KM[2])
			if (CurrentSection == "info") {
				if NextInformation.Has(Key)
					NextInformation[Key] := Val
			} else if (CurrentSection == "letters") {
				SawLetters := true
				if (StrLen(Key) != 1) {
					LoggerWarn("hotstrings", "Ignoring personal-info letter alias '{1}' because it is not one character.", Key)
					continue
				}
				if !NextInformation.Has(Val) {
					LoggerWarn("hotstrings", "Ignoring personal-info letter alias '{1}' because '{2}' is not an info key.", Key, Val)
					continue
				}
				if NextLetters.Has(Key) {
					LoggerWarn("hotstrings", "Ignoring duplicate personal-info letter alias '{1}'.", Key)
					continue
				}
				NextLetters[Key] := Val
			}
		}
	}
	PersonalInformation := NextInformation
	if SawLetters
		PersonalInformationLetters := NextLetters
	_ReadPersonalInfoTomlCache := Map(
		"info", PersonalInformation.Clone(),
		"letters", PersonalInformationLetters.Clone()
	)
}

_PersonalInfoSerializeCandidate(Information, Letters) {
	if !(Information is Map)
		throw TypeError("The personal-information candidate must be a Map.")
	if !(Letters is Map)
		throw TypeError("The personal-information letter aliases must be a Map.")

	Q := Chr(34)
	Lines := ["[info]"]
	for Key, Val in Information {
		if !(Key is String) || !RegExMatch(Key, "^[A-Za-z_][A-Za-z0-9_]*$")
			throw ValueError("Invalid personal-information key.")
		if !(Val is String)
			throw TypeError("Personal-information values must be strings.")
		Lines.Push(Key . " = " . Q . EscapeTomlValue(Val) . Q)
	}

	Lines.Push("[letters]")
	for Letter, Key in Letters {
		if !(Letter is String) || !RegExMatch(Letter, "^[A-Za-z0-9_]$")
			throw ValueError("Invalid personal-information letter alias.")
		if !(Key is String) || !Information.Has(Key)
			throw ValueError("A personal-information letter alias references an unknown field.")
		Lines.Push(Letter . " = " . Q . EscapeTomlValue(Key) . Q)
	}

	Content := ""
	for L in Lines
		Content .= L . "`r`n"
	return Content
}

_PersonalInfoAuthorizeCommit(AuthorizeFn := 0) {
	; GUI and WebView callbacks bypass Suspend, and the WebView bridge defers the
	; actual save through SetTimer. Re-check at the final rename, not only when
	; the message was received, so pause cannot land inside a yielded stage write.
	if A_IsSuspended
		return false
	if (AuthorizeFn is Integer) && AuthorizeFn == 0
		return true
	if !HasMethod(AuthorizeFn, "Call")
		return false
	Result := AuthorizeFn.Call()
	return (Result is Integer) && Result == 1
}

_PersonalInfoPublishCandidate(Information, Letters) {
	global PersonalInformation, PersonalInformationLetters
	PersonalInformation := Information
	PersonalInformationLetters := Letters
	; Personal-information maps feed the transient @ hotstrings. Advance the
	; decision generation in the same memory-only publication span so no preview
	; can observe the new maps under the preceding generation.
	HSE_AdvanceRuntimeDecisionGeneration()
	return true
}

; Owns validation, detached candidate construction, atomic durability and live
; publication for both personal-information editors. The global configuration
; lease is acquired before cloning live state, so neither a sibling writer nor
; a terminal path/reload transition can interleave with the transaction.
PersonalInfoCommitValues(FilePath, Values, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, AuthorizeFn := 0) {
	global PersonalInformation, PersonalInformationLetters
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return PersonalInfoCommitValues(FilePath, Values, WriterFn,
			ReplaceFn, DeleteFn, AuthorizeFn)
		finally Critical(InheritedCritical)
	}
	if !(FilePath is String) || FilePath == "" {
		try LoggerError("PersonalToml", "Refusing a personal-information save with an invalid path.")
		return false
	}
	if !(Values is Map) {
		try LoggerError("PersonalToml", "Refusing a personal-information save whose values are not a Map.")
		return false
	}
	if A_IsSuspended {
		try LoggerError("PersonalToml", "Refusing a personal-information save while the driver is suspended.")
		return false
	}
	if !((AuthorizeFn is Integer) && AuthorizeFn == 0)
			&& !HasMethod(AuthorizeFn, "Call") {
		try LoggerError("PersonalToml", "Refusing a personal-information save with a non-callable authorization guard.")
		return false
	}

	OwnerToken := _PersonalTomlWriteLeaseTryAcquire(FilePath, "personal-info-editor")
	if !(OwnerToken is Object) {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': another configuration transaction is already in progress.",
			FilePath)
		return false
	}
	try {
		if !IsSet(PersonalInformation) || !(PersonalInformation is Map)
				|| !IsSet(PersonalInformationLetters) || !(PersonalInformationLetters is Map) {
			try LoggerError("PersonalToml", "Refusing a personal-information save before its state is initialized.")
			return false
		}
		CandidateInformation := PersonalInformation.Clone()
		CandidateLetters := PersonalInformationLetters.Clone()
		for Key, Val in Values {
			if !(Key is String) || !CandidateInformation.Has(Key) {
				try LoggerError("PersonalToml", "Refusing a personal-information save containing an unknown field.")
				return false
			}
			if !(Val is String) {
				try LoggerError("PersonalToml",
					"Refusing a personal-information save whose field '{1}' is not a string.", Key)
				return false
			}
			CandidateInformation[Key] := Val
		}

		Committed := WritePersonalInfoToml(FilePath, CandidateInformation,
			CandidateLetters, WriterFn, ReplaceFn, DeleteFn,
			_PersonalInfoAuthorizeCommit.Bind(AuthorizeFn), OwnerToken,
			_PersonalInfoPublishCandidate.Bind(
				CandidateInformation, CandidateLetters))
		if Committed {
			; The publisher above runs in the atomic memory span. Notify tooltip and
			; watcher consumers only after the durable writer has restored Critical.
			HSE_InvalidateRuntimeDecisionProjection()
		}
		return Committed
	} finally {
		_PersonalTomlWriteLeaseRelease(OwnerToken)
	}
}

; Serialise one detached personal-information snapshot and atomically replace
; personal_info.toml. A one-argument compatibility call snapshots the current
; globals only after it owns the path (used by first-boot materialisation).
WritePersonalInfoToml(FilePath, Information := unset, Letters := unset,
		WriterFn := 0, ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0,
		ExistingOwner := 0, PublishFn := 0) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try {
			if IsSet(Information) {
				if IsSet(Letters)
					return WritePersonalInfoToml(FilePath, Information, Letters,
						WriterFn, ReplaceFn, DeleteFn, AuthorizeFn,
						ExistingOwner, PublishFn)
				return WritePersonalInfoToml(FilePath, Information, unset,
					WriterFn, ReplaceFn, DeleteFn, AuthorizeFn,
					ExistingOwner, PublishFn)
			}
			if IsSet(Letters)
				return WritePersonalInfoToml(FilePath, unset, Letters,
					WriterFn, ReplaceFn, DeleteFn, AuthorizeFn,
					ExistingOwner, PublishFn)
			return WritePersonalInfoToml(FilePath, unset, unset,
				WriterFn, ReplaceFn, DeleteFn, AuthorizeFn,
				ExistingOwner, PublishFn)
		} finally Critical(InheritedCritical)
	}
	BorrowedOwner := ExistingOwner is Object
	if BorrowedOwner {
		if !_PersonalTomlWriteLeaseOwns(ExistingOwner, FilePath) {
			try LoggerError("PersonalToml",
				"Refusing to write '{1}' through a stale logical owner.", FilePath)
			return false
		}
		OwnerToken := ExistingOwner
	} else {
		OwnerToken := _PersonalTomlWriteLeaseTryAcquire(FilePath, "personal-info-writer")
	}
	if !(OwnerToken is Object) {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': another configuration transaction is already in progress.",
			FilePath)
		return false
	}

	try {
		; Refuse while the file is flagged unreadable, exactly as
		; WritePersonalToml does for personal_hotstrings.toml. A failed read
		; leaves the compiled-in placeholder identity in memory; serializing it
		; would destroy the user's real identity after a transient boot lock.
		if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(FilePath)) {
			try LoggerError("PersonalToml", "Refusing to write '{1}': it could not be read, so the identity in memory is the shipped placeholder rather than the user's. Reopen the editor once the file is readable.", FilePath)
			return false
		}
		if !IsSet(Information)
			Information := PersonalInformation.Clone()
		if !IsSet(Letters)
			Letters := PersonalInformationLetters.Clone()
		try Content := _PersonalInfoSerializeCandidate(Information, Letters)
		catch as Err {
			try LoggerError("PersonalToml",
				"Refusing to serialize personal information for '{1}': {2}",
				FilePath, Err.Message)
			return false
		}

		Written := _PersonalTomlWriteAtomic(FilePath, Content,
			WriterFn, ReplaceFn, DeleteFn,
			_PersonalTomlAuthorizeOwnedWrite.Bind(
				OwnerToken, FilePath, AuthorizeFn), PublishFn)
		if !((Written is Integer) && Written == 1)
			return false
		return true
	} finally {
		; A yielded stage writer can repopulate this cache from the old target.
		; Always evict after the terminal outcome while the exact owner is held.
		_ReadPersonalInfoTomlCache := false
		if !BorrowedOwner
			_PersonalTomlWriteLeaseRelease(OwnerToken)
	}
}

; Make sure personal_info.toml exists at FilePath, materialising the in-memory
; defaults from PersonalInformation / PersonalInformationLetters when it does
; not. Called at script load so that renaming or deleting the file simply
; triggers a fresh re-creation on the next launch — same UX guarantee as
; EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk.
EnsurePersonalInfoTomlFile(FilePath) {
	if FileExist(FilePath) {
		return
	}
	try {
		Dir := RegExReplace(FilePath, "\\[^\\]+$", "")
		if (Dir != "" and !DirExist(Dir)) {
			DirCreate(Dir)
		}
		if WritePersonalInfoToml(FilePath) {
			try LoggerInfo("ErgoptiPlus", "Personal info file created from defaults at '{1}'.", FilePath)
		} else {
			try LoggerWarn("ErgoptiPlus", "Could not create personal info file at '{1}'.", FilePath)
		}
	} catch as e {
		try LoggerWarn("ErgoptiPlus", "Could not create personal info file at '{1}': {2}.",
			FilePath, e.Message)
	}
}

; Helper: join an Array of strings with a separator.
ArrayJoin(Arr, Sep) {
	Out := ""
	for i, v in Arr {
		Out .= (i > 1 ? Sep : "") . v
	}
	return Out
}

; Coalescing delay before the auxiliary near-miss catalogue is rebuilt.
; Negative-period SetTimer with the same function object RE-ARMS rather than
; queueing, so the webview save path — which reloads every edited section in a
; loop — pays for exactly ONE rebuild instead of one per section. The rebuild
; costs ~150 ms warm and far more on a cold TOML read, so it also belongs off
; the save handler's synchronous path: the editor window closes immediately and
; the analytics catalogue catches up a fraction of a second later.
global HS_PERSONAL_RELOAD_INDEX_DELAY_MS := 120
global PERSONAL_TOML_COMMIT_FAILED := 0
global PERSONAL_TOML_COMMIT_OK := 1
global PERSONAL_TOML_COMMIT_DEFERRED := 2

; Recursively detach the editor model before either filesystem I/O or live
; registration can yield. The native editor owns one mutable process-global Map;
; rejecting a nested writer is insufficient when that callback already mutated
; the Map the outer transaction planned to reload.
_PersonalTomlCloneDetached(Value) {
	if Value is Map {
		Copy := Map()
		for Key, Child in Value
			Copy[Key] := _PersonalTomlCloneDetached(Child)
		return Copy
	}
	if Value is Array {
		Copy := []
		for Child in Value
			Copy.Push(_PersonalTomlCloneDetached(Child))
		return Copy
	}
	return Value
}

; Resolve a caller's requested reload subset against the exact canonical order
; the durable writer uses. A zero sentinel means every section in the candidate.
_PersonalTomlResolveReloadSections(Data, RequestedSections, &Detail := "") {
	Detail := ""
	CanonicalOrder := _PersonalTomlCanonicalSectionOrder(Data, &Detail)
	if !(CanonicalOrder is Array)
		return false

	if (RequestedSections is Integer) && RequestedSections == 0
		return CanonicalOrder
	if !(RequestedSections is Array) {
		Detail := "requested reload sections is not an Array"
		return false
	}

	CanonicalNames := Map()
	for SectionName in CanonicalOrder
		CanonicalNames[StrLower(SectionName)] := SectionName
	RequestedNames := Map()
	for SectionName in RequestedSections {
		if !(SectionName is String) || Trim(SectionName) == "" {
			Detail := "requested reload sections contains a non-string or empty name"
			return false
		}
		CanonicalName := StrLower(Trim(SectionName))
		if !CanonicalNames.Has(CanonicalName) {
			Detail := "requested reload section '" . SectionName
				. "' is absent from the durable candidate"
			return false
		}
		RequestedNames[CanonicalName] := true
	}

	Resolved := []
	for SectionName in CanonicalOrder {
		if RequestedNames.Has(StrLower(SectionName))
			Resolved.Push(SectionName)
	}
	return Resolved
}

; Holds the latest whole-file candidate accepted while another publication owns
; the path. A full editor snapshot is safely coalescible: a newer generation
; contains every preceding edit and is the only candidate that should win.
_PersonalTomlLiveCommitState(Replacement := unset) {
	static State := {
		next_generation: 0,
		pending: false,
		owner_active: false,
		resync: false,
	}
	if IsSet(Replacement)
		State := Replacement
	return State
}

; Treat an injected suspend predicate as a test seam only. Production always
; samples A_IsSuspended at every boundary that can follow a yield.
_PersonalTomlRequestIsSuspended(SuspendFn := 0) {
	if (SuspendFn is Integer) && SuspendFn == 0
		return A_IsSuspended
	if !HasMethod(SuspendFn, "Call")
		return true
	try Result := SuspendFn.Call()
	catch as Err {
		try LoggerError("PersonalToml",
			"The personal-hotstring suspend predicate failed: {1}.",
			Err.Message)
		return true
	}
	return !(Result is Integer) || Result != 0
}

; Revalidate both authorities after every yielding boundary. Owning yesterday's
; path is not authority to publish into the registry selected by today's path.
_PersonalTomlRequestContextIsCurrent(Request, OwnerToken) {
	if !(Request is Object)
		return false
	if !_PersonalTomlWriteLeaseOwns(OwnerToken, Request.FilePath)
		return false
	try CurrentPath := PersonalTomlPath()
	catch
		return false
	if _ConfigWriteLeaseKey(CurrentPath)
			!= _ConfigWriteLeaseKey(Request.FilePath)
		return false
	return !_PersonalTomlRequestIsSuspended(Request.SuspendFn)
}

; Final stage authorization composes the live suspend/path owner with the
; caller's optional epoch predicate, then samples all three again after it.
_PersonalTomlAuthorizeLiveRequest(Request, OwnerToken) {
	if !_PersonalTomlRequestContextIsCurrent(Request, OwnerToken)
		return false
	AuthorizeFn := Request.AuthorizeFn
	if !((AuthorizeFn is Integer) && AuthorizeFn == 0) {
		if !HasMethod(AuthorizeFn, "Call")
			return false
		try Authorized := AuthorizeFn.Call()
		catch as Err {
			try LoggerError("PersonalToml",
				"The personal-hotstring publication predicate failed: {1}.",
				Err.Message)
			return false
		}
		if !(Authorized is Integer) || Authorized == 0
			return false
	}
	return _PersonalTomlRequestContextIsCurrent(Request, OwnerToken)
}

; A DEFERRED result is only an admission receipt. Its caller receives exactly
; one later terminal outcome, including coalescing and retry failures.
_PersonalTomlNotifyDeferredCompletion(Request, Result) {
	if !(Request is Object) || !Request.HasOwnProp("Deferred")
			|| !Request.Deferred
		return
	Request.Deferred := false
	CompletionFn := Request.CompletionFn
	Request.CompletionFn := 0
	if !HasMethod(CompletionFn, "Call")
		return
	try CompletionFn.Call(Result)
	catch as Err {
		try LoggerError("PersonalToml",
			"Reporting a deferred personal-hotstring publication failed: {1}.",
			Err.Message)
	}
}

; A retry obligation must retain the immutable durable candidate and its live
; reloader, never GUI controls captured by a one-shot completion callback.
_PersonalTomlResyncSnapshot(Request) {
	return {
		Generation: Request.Generation,
		FilePath: Request.FilePath,
		Candidate: Request.Candidate,
		ReloadSections: Request.ReloadSections,
		ReloadFn: Request.ReloadFn,
		HasInjectedReloader: Request.HasInjectedReloader,
		SuspendFn: Request.SuspendFn,
		CompletionFn: 0,
		Deferred: false,
	}
}

; Accept a complete candidate only behind the exact live owner that guarantees
; synchronous draining. A metadata writer or terminal barrier is not such an
; owner: those collisions fail immediately instead of creating orphaned work.
_PersonalTomlQueueLiveRequest(Request) {
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_DEFERRED
	if _PersonalTomlRequestIsSuspended(Request.SuspendFn)
		return PERSONAL_TOML_COMMIT_FAILED
	if !HasMethod(Request.CompletionFn, "Call") {
		try LoggerError("PersonalToml",
			"Refusing to defer a personal-hotstring save without a terminal completion callback.")
		return PERSONAL_TOML_COMMIT_FAILED
	}
	State := _PersonalTomlLiveCommitState()
	Superseded := false
	PreviousCritical := Critical("On")
	try {
		if !(State.owner_active is Object)
				|| !_PersonalTomlWriteLeaseOwns(
					State.owner_active, Request.FilePath)
			return PERSONAL_TOML_COMMIT_FAILED
		if (State.pending is Object) {
			if State.pending.Generation > Request.Generation
				return PERSONAL_TOML_COMMIT_FAILED
			Superseded := State.pending
		}
		Request.Deferred := true
		if !(State.pending is Object)
				|| State.pending.Generation <= Request.Generation
			State.pending := Request
	} finally Critical(PreviousCritical)
	if Superseded is Object
		_PersonalTomlNotifyDeferredCompletion(
			Superseded, PERSONAL_TOML_COMMIT_FAILED)
	return PERSONAL_TOML_COMMIT_DEFERRED
}

; Record only a request whose durable bytes may no longer match the live HSE
; registry. The owner/path checks make this a retry obligation, not a stale cache.
_PersonalTomlSetResyncOwned(Request, OwnerToken, NeedsResync := true) {
	State := _PersonalTomlLiveCommitState()
	PreviousCritical := Critical("On")
	try {
		if !_PersonalTomlWriteLeaseOwns(OwnerToken, Request.FilePath)
			return false
		if NeedsResync
			State.resync := _PersonalTomlResyncSnapshot(Request)
		else if (State.resync is Object)
				&& State.resync.Generation <= Request.Generation
			State.resync := false
		return true
	} finally Critical(PreviousCritical)
}

; Reload one durable candidate while retaining its exact path owner. A context
; check brackets every section because an injected or OS-backed reload can yield.
_PersonalTomlReloadRequestOwned(Request, OwnerToken) {
	global Features
	if !_PersonalTomlRequestContextIsCurrent(Request, OwnerToken)
		return false
	FeatureConfig := { TimeActivationSeconds: 0 }
	if (IsSet(Features) && Features.Has("hotstrings")
			&& Features["hotstrings"].Has("personal")
			&& Features["hotstrings"]["personal"].Has("autocorrection")) {
		FeatureConfig := Features["hotstrings"]["personal"]["autocorrection"]
	}
	ReloadHandler := Request.HasInjectedReloader
		? Request.ReloadFn : ReloadPersonalSection
	ReloadSucceeded := true
	TransitionStarted := false
	try {
		if !Request.HasInjectedReloader {
			HSE_BeginRegistryTransition()
			TransitionStarted := true
		}
		for SectionName in Request.ReloadSections {
			if !_PersonalTomlRequestContextIsCurrent(Request, OwnerToken) {
				ReloadSucceeded := false
				break
			}
			try ReloadHandler.Call(
				Request.Candidate, SectionName, FeatureConfig)
			catch as ReloadError {
				ReloadSucceeded := false
				try LoggerError("PersonalToml",
					"Live publication of personal-hotstring section '{1}' failed after its durable commit: {2}.",
					SectionName, ReloadError.Message)
				break
			}
			if !_PersonalTomlRequestContextIsCurrent(Request, OwnerToken) {
				ReloadSucceeded := false
				break
			}
		}
	} catch as ReloadError {
		ReloadSucceeded := false
		try LoggerError("PersonalToml",
			"Personal-hotstring live publication failed after its durable commit: {1}.",
			ReloadError.Message)
	} finally {
		if TransitionStarted
			try HSE_EndRegistryTransition()
	}
	_PersonalTomlSetResyncOwned(Request, OwnerToken, !ReloadSucceeded)
	return ReloadSucceeded
}


; Persist and publish one request under a lease already owned by the caller.
_PersonalTomlPublishRequestOwned(Request, OwnerToken) {
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_OK
	if !_PersonalTomlRequestContextIsCurrent(Request, OwnerToken)
		return PERSONAL_TOML_COMMIT_FAILED

	; A previous durable commit whose reload failed must be reconciled before a
	; newer write can make its failure impossible to diagnose. Retry once, owned,
	; with no timer; a persistent failure remains latched for the next user action.
	State := _PersonalTomlLiveCommitState()
	PreviousCritical := Critical("On")
	try PendingResync := State.resync
	finally Critical(PreviousCritical)
	if (PendingResync is Object)
			&& PendingResync.Generation != Request.Generation {
		if _ConfigWriteLeaseKey(PendingResync.FilePath)
				!= _ConfigWriteLeaseKey(Request.FilePath)
			return PERSONAL_TOML_COMMIT_FAILED
		if !_PersonalTomlReloadRequestOwned(PendingResync, OwnerToken)
			return PERSONAL_TOML_COMMIT_FAILED
	}

	if !WritePersonalToml(Request.Candidate, Request.WriterFn,
			Request.ReplaceFn, Request.DeleteFn,
			_PersonalTomlAuthorizeLiveRequest.Bind(Request, OwnerToken),
			OwnerToken)
		return PERSONAL_TOML_COMMIT_FAILED

	; The rename is durable but the path/suspend authority may have changed while
	; the OS call was in flight. Never project those bytes into the wrong live HSE.
	if !_PersonalTomlRequestContextIsCurrent(Request, OwnerToken) {
		_PersonalTomlSetResyncOwned(Request, OwnerToken)
		try LoggerError("PersonalToml",
			"The personal-hotstring file was committed, but its suspend/path authority changed before live reload; an owned resync was retained.")
		return PERSONAL_TOML_COMMIT_FAILED
	}

	if _PersonalTomlReloadRequestOwned(Request, OwnerToken)
		return PERSONAL_TOML_COMMIT_OK

	; Retry exactly once while the same owner is retained. A transient registry
	; error can self-heal; the originating action still reports FAILED because its
	; first live publication did not satisfy the contract.
	_PersonalTomlReloadRequestOwned(Request, OwnerToken)
	return PERSONAL_TOML_COMMIT_FAILED
}

; Claim an already-accepted same-path snapshot before releasing the owner. The
; pending read, token release and owner_active update are one atomic decision, so
; a terminal transition cannot enter between A and its admitted B successor.
_PersonalTomlClaimPendingOrRelease(OwnerToken, FilePath) {
	State := _PersonalTomlLiveCommitState()
	NextRequest := false
	RejectedRequest := false
	PreviousCritical := Critical("On")
	try {
		if (State.pending is Object)
				&& _ConfigWriteLeaseKey(State.pending.FilePath)
					== _ConfigWriteLeaseKey(FilePath) {
			NextRequest := State.pending
			State.pending := false
			return { Request: NextRequest, Rejected: false, Released: false }
		}
		RejectedRequest := State.pending
		State.pending := false
		Released := _PersonalTomlWriteLeaseRelease(OwnerToken)
		if Released
			State.owner_active := false
		return { Request: false, Rejected: RejectedRequest,
			Released: Released }
	} finally Critical(PreviousCritical)
}

; Persist one detached candidate and every already-admitted same-path successor
; under one lease. Only metadata claims are Critical; all I/O and reload work is
; explicitly non-Critical.
_PersonalTomlTryPublishRequest(Request) {
	global PERSONAL_TOML_COMMIT_FAILED
	if _PersonalTomlRequestIsSuspended(Request.SuspendFn) {
		_PersonalTomlNotifyDeferredCompletion(
			Request, PERSONAL_TOML_COMMIT_FAILED)
		return PERSONAL_TOML_COMMIT_FAILED
	}
	State := _PersonalTomlLiveCommitState()
	OwnerToken := false
	Superseded := false
	PreviousCritical := Critical("On")
	try {
		OwnerToken := _PersonalTomlWriteLeaseTryAcquire(
			Request.FilePath, "personal-hotstrings-live-publication")
		if OwnerToken is Object {
			State.owner_active := OwnerToken
			if (State.pending is Object)
					&& State.pending.Generation <= Request.Generation {
				Superseded := State.pending
				State.pending := false
			}
		}
	} finally Critical(PreviousCritical)
	if Superseded is Object
		_PersonalTomlNotifyDeferredCompletion(
			Superseded, PERSONAL_TOML_COMMIT_FAILED)
	if !(OwnerToken is Object) {
		return _PersonalTomlQueueLiveRequest(Request)
	}

	InitialGeneration := Request.Generation
	InitialResult := PERSONAL_TOML_COMMIT_FAILED
	CurrentRequest := Request
	OwnerReleased := false
	RejectedRequest := false
	ReleaseFailed := false
	try {
		loop {
			try CurrentResult := _PersonalTomlPublishRequestOwned(
				CurrentRequest, OwnerToken)
			catch as CommitError {
				CurrentResult := PERSONAL_TOML_COMMIT_FAILED
				try LoggerError("PersonalToml",
					"Personal-hotstring durable/live publication failed: {1}.",
					CommitError.Message)
			}
			if CurrentRequest.Generation == InitialGeneration
				InitialResult := CurrentResult
			; Report the terminal outcome while this same owner is still retained.
			; A callback-triggered successor is therefore admitted and claimed below
			; before a terminal transition can enter.
			_PersonalTomlNotifyDeferredCompletion(
				CurrentRequest, CurrentResult)

			Claim := _PersonalTomlClaimPendingOrRelease(
				OwnerToken, CurrentRequest.FilePath)
			if !(Claim.Request is Object) {
				OwnerReleased := Claim.Released
				if !OwnerReleased {
					CurrentResult := PERSONAL_TOML_COMMIT_FAILED
					if CurrentRequest.Generation == InitialGeneration
						InitialResult := CurrentResult
					try LoggerError("PersonalToml",
						"The personal-hotstring publication completed, but its exact path owner could not be released.")
				}
				RejectedRequest := Claim.Rejected
				if RejectedRequest is Object
					_PersonalTomlNotifyDeferredCompletion(
						RejectedRequest, PERSONAL_TOML_COMMIT_FAILED)
				break
			}
			CurrentRequest := Claim.Request
		}
	} finally {
		if !OwnerReleased {
			PreviousCritical := Critical("On")
			try {
				RejectedRequest := State.pending
				State.pending := false
				if _PersonalTomlWriteLeaseOwns(OwnerToken) {
					if _PersonalTomlWriteLeaseRelease(OwnerToken)
						State.owner_active := false
					else
						ReleaseFailed := true
				} else if State.owner_active == OwnerToken {
					State.owner_active := false
				}
			} finally Critical(PreviousCritical)
			if RejectedRequest is Object
				_PersonalTomlNotifyDeferredCompletion(
					RejectedRequest, PERSONAL_TOML_COMMIT_FAILED)
			if ReleaseFailed
				try LoggerError("PersonalToml",
					"The personal-hotstring path owner remained latched after its terminal publication outcome.")
		}
	}
	return InitialResult
}

PersonalTomlCommitAndReload(Data, RequestedSections := 0, WriterFn := 0,
		ReplaceFn := 0, DeleteFn := 0, AuthorizeFn := 0, ReloadFn := 0,
		CompletionFn := 0, SuspendFn := 0) {
	global PERSONAL_TOML_COMMIT_FAILED
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return PersonalTomlCommitAndReload(Data, RequestedSections,
			WriterFn, ReplaceFn, DeleteFn, AuthorizeFn, ReloadFn,
			CompletionFn, SuspendFn)
		finally Critical(InheritedCritical)
	}
	HasInjectedReloader := !((ReloadFn is Integer) && ReloadFn == 0)
	if HasInjectedReloader && !HasMethod(ReloadFn, "Call") {
		try LoggerError("PersonalToml",
			"Refusing a personal-hotstring transaction with a non-callable live reloader.")
		return PERSONAL_TOML_COMMIT_FAILED
	}
	if !((CompletionFn is Integer) && CompletionFn == 0)
			&& !HasMethod(CompletionFn, "Call") {
		try LoggerError("PersonalToml",
			"Refusing a personal-hotstring transaction with a non-callable completion callback.")
		return PERSONAL_TOML_COMMIT_FAILED
	}
	if !((SuspendFn is Integer) && SuspendFn == 0)
			&& !HasMethod(SuspendFn, "Call") {
		try LoggerError("PersonalToml",
			"Refusing a personal-hotstring transaction with a non-callable suspend predicate.")
		return PERSONAL_TOML_COMMIT_FAILED
	}
	if _PersonalTomlRequestIsSuspended(SuspendFn) {
		try LoggerWarn("PersonalToml",
			"Refusing a personal-hotstring save while the driver is suspended.")
		return PERSONAL_TOML_COMMIT_FAILED
	}

	; Pure memory only: take a stable candidate before a nested GUI callback can
	; mutate the native editor's shared model. Critical is off again before any
	; validation, filesystem operation or registry rebuild.
	PreviousCritical := Critical("On")
	try Candidate := _PersonalTomlCloneDetached(Data)
	finally Critical(PreviousCritical)
	FilePath := PersonalTomlPath()
	ReloadSections := _PersonalTomlResolveReloadSections(
		Candidate, RequestedSections, &ReloadDetail)
	if !(ReloadSections is Array) {
		try LoggerError("PersonalToml",
			"Refusing to write '{1}': {2}.", FilePath, ReloadDetail)
		return PERSONAL_TOML_COMMIT_FAILED
	}

	State := _PersonalTomlLiveCommitState()
	PreviousCritical := Critical("On")
	try {
		State.next_generation += 1
		Generation := State.next_generation
	} finally Critical(PreviousCritical)
	Request := {
		Generation: Generation,
		FilePath: FilePath,
		Candidate: Candidate,
		ReloadSections: ReloadSections,
		WriterFn: WriterFn,
		ReplaceFn: ReplaceFn,
		DeleteFn: DeleteFn,
		AuthorizeFn: AuthorizeFn,
		ReloadFn: ReloadFn,
		HasInjectedReloader: HasInjectedReloader,
		CompletionFn: CompletionFn,
		SuspendFn: SuspendFn,
		Deferred: false,
	}
	return _PersonalTomlTryPublishRequest(Request)
}

; Re-register all hotstrings in a given section from the current TOML data.
; Called after save so new/edited entries are immediately active.
ReloadPersonalSection(Data, SectionName, FeatureConfig) {
	if !Data["sections"].Has(SectionName) {
		return
	}
	; Respect the per-section enabled flag before registering anything live.
	; ApplyMasterGatesToFeatures already folds the Hotstrings master gate (and
	; any per-file sub-category gate) into this same "enabled" flag (see
	; infra/master_gates.ahk), so checking it here mirrors exactly what
	; _HS_RegisterPersonal already does at boot/full-rebuild time. Without this,
	; saving an edit in a section the tray checkbox still shows as disabled
	; silently activated it live (personal-hotstring-live-reload-ignores-gate).
	; FeatureConfig is NOT used for this check — the caller (_SaveData) always
	; passes the "autocorrection" sub-Map regardless of which section is being
	; saved, so this reads the real per-section node from Features directly.
	global Features
	SecKey := StrLower(SectionName)
	SectionEnabled := (IsSet(Features) and Features.Has("hotstrings")
		and Features["hotstrings"].Has("personal")
		and Features["hotstrings"]["personal"].Has(SecKey)
		and IsObject(Features["hotstrings"]["personal"][SecKey])
		and Features["hotstrings"]["personal"][SecKey].Has("enabled")
		and Features["hotstrings"]["personal"][SecKey]["enabled"])
	; Clear the section's OLD HSE group before re-registering. Without this the
	; fresh spec for an edited trigger lands as a dead duplicate BEHIND the
	; stale one (HSE's Seq tie-break favours the older/lower-Seq registration),
	; so a same-trigger edit could never take effect until a full Reload
	; (personal-hotstring-live-reload-stale-group). This Group string must stay
	; byte-identical to the one HSE_Register derives below from Options'
	; "Category"/"Section" (Meta.Category . "." . Meta.Section).
	Group := "personal." . SectionName
	; Resolve the expansion delay through the SAME cascade LoadHotstringsSection
	; uses at boot (toml_loader.ahk). This used to be a hardcoded 0, and 0 is a
	; legal value that DISABLES the time gate — so saving anything from the
	; editor silently removed the 0.75 s window every personal spec is registered
	; with at boot, for the rest of the session. The tooltip kept dequeueing its
	; row at the resolved delay while the engine had stopped enforcing it, so the
	; preview and the engine permanently disagreed about the expansion window.
	ResolvedDelay := 0
	try {
		Resolved := HotstringsResolve("personal", SectionName)
		if (Resolved.Delay != "")
			ResolvedDelay := Resolved.Delay
	} catch as DelayErr {
		try LoggerWarn("PersonalToml", "Could not resolve the expansion delay for section '{1}': {2}. Registering without a time gate.", SectionName, DelayErr.Message)
	}
	; Fence the complete clear + registration batch without holding Critical over
	; it. Hook/timer callbacks may run, but the matcher fails closed until the
	; outermost transition publishes a complete generation. This also invalidates
	; already-visible decisions before the first old Spec is removed.
	HSE_BeginRegistryTransition()
	try {
		HSE_ClearGroupForReload(Group)
		if !SectionEnabled {
			try LoggerDebug("PersonalToml", "ReloadPersonalSection: '{1}' is disabled — old registrations were removed and no live registration was published.", SectionName)
		} else {
			for E in Data["sections"][SectionName]["entries"] {
				Trigger := StrReplace(E["trigger"], "★", ScriptInformation["MagicKey"])
				Output := E["output"]
				Flags := ""
				if E["auto_expand"]
					Flags .= "*"
				if !E["is_word"]
					Flags .= "?"
				if E.Has("strict_case") and E["strict_case"]
					Flags .= "C"
				; Collision priority: the individual per-hotstring override when set,
				; otherwise the personal source default (50). Passing Category + Priority
				; mirrors the boot loader so a live editor reload registers personal
				; hotstrings at the same tier they get at startup.
				EntryPriority := (E.Has("priority") and E["priority"] != "")
					? E["priority"]
					: _HSE_SourcePriority("personal")
				Options := Map(
					"TimeActivationSeconds", ResolvedDelay,
					"FinalResult", E["final_result"],
					"Category", "personal",
					; Category + Section derive the same group cleared above.
					"Section", SectionName,
					"Priority", EntryPriority,
				)
				HSE_RegisterFromTomlFlags(
					E["is_case_sensitive"], Flags, Trigger, Output, Options)
			}
		}
	} finally {
		HSE_EndRegistryTransition()
	}
	; The engine registry has just been rewritten in place. The tooltip now asks
	; that registry directly, so this rebuild is no longer a correctness fence;
	; it refreshes only the auxiliary near-miss catalogue used by keylogger ROI.
	;
	; The resync belongs HERE rather than in the two save handlers: this is the
	; function that mutates the engine registry, so pairing the two makes the
	; guarantee hold for every caller instead of for the callers someone
	; remembered.
	global HS_PERSONAL_RELOAD_INDEX_DELAY_MS
	if IsSet(HotstringPrefixWatcherRebuildIndex) {
		try {
			SetTimer(HotstringPrefixWatcherRebuildIndex, -HS_PERSONAL_RELOAD_INDEX_DELAY_MS)
			try LoggerDebug("PersonalToml", "Preview-index resync armed after reloading '{1}'.", SectionName)
		} catch as ResyncErr {
			; A silent failure here would leave near-miss analytics stale, so it
			; must name itself even though live preview correctness is unaffected.
			try LoggerError("PersonalToml", "Could not arm the preview-index resync after reloading '{1}': {2}", SectionName, ResyncErr.Message)
		}
	}
}
