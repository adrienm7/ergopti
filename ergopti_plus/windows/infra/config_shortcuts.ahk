; infra/config_shortcuts.ahk

; ==============================================================================
; MODULE: Config Shortcuts (TOML section)
; DESCRIPTION:
; UI-shortcut preferences and per-feature privacy toggles, persisted as a
; ``[Metrics]`` section inside the unified AHK config at
; ``<config_dir>/ahk/config.toml``. All driver configuration (features,
; script settings, gestures, expert overrides) lives in this single file.
;
; SECTION LAYOUT inside autohotkey/config.toml:
;
;   [metrics]
;   enabled                    = true
;   private_filter_enabled     = true
;   system_auth_filter_enabled = true
;   disabled_apps              = ["chrome.exe", "firefox.exe"]
;
; FEATURES & RATIONALE:
; 1. Per-driver subfolder: ``<config_dir>/ahk/`` is auto-created on first
;    save. Disjoint from ``<config_dir>/hammerspoon/`` so the two drivers
;    never touch the same file.
; 2. Single writer: this file parses config.toml and routes targeted metrics
;    updates through ConfigCommitUpdates → TOML_BatchWrite. The canonical
;    writer preserves every untouched section and refuses to rebuild a file it
;    could not read.
; ==============================================================================

#Requires Autohotkey v2.0+





; ==================================
; ==================================
; ======= 1/ Path resolution =======
; ==================================
; ==================================

CS_GetTomlPath() {
		; Driver-specific subfolder under the user's resolved config dir.
		; Auto-created here so callers can read/write straight away without
		; worrying about ENOENT on a fresh install.
		global _ConfigDir
		base := (IsSet(_ConfigDir) && _ConfigDir != "") ? _ConfigDir : A_ScriptDir . "\"
		global _AhkSubDir
		dir := base . _AhkSubDir
		try DirCreate(dir)
		return dir . "config.toml"
}

; The single section we own inside config.toml. Other sections
; ([Script], [Shortcuts.ScriptControl], [Gestures], feature sections …) belong
; to other readers and are never touched from here.
global CS_SECTION := "metrics"





; =========================
; =========================
; ======= 2/ Reader =======
; =========================
; =========================

; Returns a Map of { section_name => Map(key => value) }. Values are
; strings, integers, booleans (1/0), or Arrays of strings.
; Comments (lines starting with #) and blank lines are skipped.
CS_Read(&Snapshot := 0, &SourcePath := "") {
		Snapshot := 0
		path := CS_GetTomlPath()
		SourcePath := path
		try {
				; Bootstrap, feature application and metrics must retain one native
				; source generation. A physical edit alone grants no new admission.
				Snapshot := ConfigTomlReadSnapshot(path)
		} catch as Err {
				global _ConfigBootReadFailed
				_ConfigBootReadFailed := true
				try LoggerError("ConfigShortcuts", "Cannot admit '{1}': {2}. Metrics settings stay at their in-memory defaults, and persistence is blocked so those defaults cannot be written over the real file.", path, Err.Message)
				return Map()
		}
		return Snapshot.Cache
}

; Truncate a value at the first '#' that sits OUTSIDE a quoted string, so an
; inline TOML comment (enabled = false # off) does not become part of the
; value. Quote/escape state is tracked from the raw character stream (same
; discipline as the array tokenizer below), so a '#' inside a quoted value or an
; escaped quote is preserved. Without this, "false # x" fell through to the bare-
; string fallback and coerced to a TRUTHY string, inverting the user's opt-out.
CS_StripInlineComment(s) {
		return TOML_StripInlineComment(s)
}

CS_CoerceValue(raw) {
		raw := Trim(raw)
		; Drop any inline comment first so `false # note` coerces to boolean false and
		; `[ "a" ] # note` is still recognised as an array (the trailing comment would
		; otherwise break the "]"-suffix check below and fall through to a bare string).
		raw := Trim(CS_StripInlineComment(raw))
		if StrLen(raw) >= 2 && SubStr(raw, 1, 1) == "'" && SubStr(raw, -1) == "'"
				return SubStr(raw, 2, StrLen(raw) - 2)
		if SubStr(raw, 1, 1) == "{"
				return TOML_ParseInlineTable(raw, CS_CoerceValue)
		if (raw = "")
				return ""
		; Booleans.
		if (StrLower(raw) = "true")
				return true
		if (StrLower(raw) = "false")
				return false
		; Quoted string.
		if (SubStr(raw, 1, 1) = '"' && SubStr(raw, -1) = '"')
				return CS_Unescape(SubStr(raw, 2, StrLen(raw) - 2))
		; Array of strings: [ "a", "b", ... ]
		if (SubStr(raw, 1, 1) = "[" && SubStr(raw, -1) = "]") {
				body := Trim(SubStr(raw, 2, StrLen(raw) - 2))
				out := []
				if (body = "")
						return out
				for Token in TOML_SplitArrayElements(body)
						out.Push(CS_CoerceElement(Token))
				return out
		}
		; Integer. Keep an overflowing TOML lexeme as a String so the typed
		; metrics boundary rejects it instead of accepting a modulo-2^64 alias.
		if TOML_TryParseInteger(raw, &IntegerValue)
				return IntegerValue
		; Bare string fallback.
		return raw
}

; Coerce a single array element that the tokenizer already extracted. A
; quoted element is unescaped EXACTLY ONCE here — we deliberately do NOT
; recurse into CS_CoerceValue for quoted strings, which would re-run the
; quote-detection + CS_Unescape pass and risk a second unescape. Non-quoted
; elements (bools, integers, bare strings) still flow through CS_CoerceValue.
CS_CoerceElement(token) {
		token := Trim(token)
		if (SubStr(token, 1, 1) = '"' && SubStr(token, -1) = '"')
				return CS_Unescape(SubStr(token, 2, StrLen(token) - 2))
		return CS_CoerceValue(token)
}

CS_Unescape(s) {
	return TOML_UnescapeBasicStringContents(s)
}






; =========================================
; =========================================
; ======= 4/ Public load + save API =======
; =========================================
; =========================================

; The primary boot loader already reports this exact source generation. A
; later metrics read must not report the same entry again, while a different
; file or a changed source still owns its own diagnostic.
_CS_OutdatedAlreadyReported(Snapshot, Path, Key) {
	global CS_SECTION, ConfigurationFile, _BootConfigSnapshot, _ConfigBootOutdatedEntries
	if !IsSet(ConfigurationFile) || ConfigurationFile == ""
			|| !IsSet(_BootConfigSnapshot) || !IsObject(_BootConfigSnapshot)
			|| !_BootConfigSnapshot.HasOwnProp("Source")
			|| !IsSet(_ConfigBootOutdatedEntries) || !(_ConfigBootOutdatedEntries is Map)
		return false
	return _ConfigWriteLeaseKey(Path) == _ConfigWriteLeaseKey(ConfigurationFile)
		&& Snapshot.Source == _BootConfigSnapshot.Source
		&& _ConfigBootOutdatedEntries.Has(CS_SECTION . "`n" . Key)
}

; Keep the complete semantic snapshot intact for cleanup and source admission.
; Only the metrics consumers receive the canonical effective values; re-decoding
; an outdated signed zero or quoted Boolean must never grant collection consent.
_CS_AdmitMetricsCache(Cache, Snapshot, Path) {
	global CS_SECTION
	if !Cache.Has(CS_SECTION)
		return Cache
	Effective := Cache.Clone()
	Effective[CS_SECTION] := Cache[CS_SECTION].Clone()
	for Row in Snapshot.Rows {
		if Row.Section != CS_SECTION
			continue
		if TomlConfigValueMatchesManifest(Row.Section, Row.Key, Row.Value,
				&ExpectedType, TOML_StripInlineComment(Row.Raw))
			continue
		TomlConfigExpectedType(Row.Section, Row.Key, &Entry)
		if !(Entry is Map) || !Entry.Has("path") || !Entry.Has("default")
			throw Error("An outdated metrics setting has no manifest default")
		Effective[CS_SECTION][Row.Key] := _ConfigTomlNativeValue(ManifestDefaultFor(Entry["path"]))
		if !_CS_OutdatedAlreadyReported(Snapshot, Path, Row.Key)
			LoggerWarn("ConfigShortcuts",
				"Ignoring outdated [{1}].{2} in '{3}'; keeping the manifest value for this {4} setting. Source bytes are unchanged.",
				CS_SECTION, Row.Key, Path, ExpectedType)
	}
	return Effective
}

; Populate MetricsShortcuts + MetricsFilters from disk and return their admitted
; cache to the widget reader. Missing settings keep their in-memory defaults.
_CS_RequireBoolean(Value, Key) {
		if !(Value is Integer) || (Value != 0 && Value != 1)
				throw TypeError("metrics." . Key . " must be a TOML boolean")
		return Value == 1
}

_CS_RequireString(Value, Key) {
		if !(Value is String)
				throw TypeError("metrics." . Key . " must be a TOML string")
		return Value
}

_CS_ValidateMetricsSection(Section) {
		Validated := Map()
		for Key in ["enabled",
				"private_filter_enabled", "secure_filter_enabled",
				"system_auth_filter_enabled", "encrypt"] {
				if Section.Has(Key)
						Validated[Key] := _CS_RequireBoolean(Section[Key], Key)
		}
		if Section.Has("disabled_apps")
				Validated["disabled_apps"] :=
						TomlConfigMetricsDisabledApps(Section["disabled_apps"])
		return Validated
}

CS_Load() {
		global CS_SECTION
		; Manifest first, disk second. Doing it here rather than in the class body
		; keeps the ordering explicit: a class static initialiser would run at an
		; unspecified point relative to the manifest include, and a privacy default
		; that depends on include order is one refactor away from flipping.
		MetricsFiltersApplyManifestDefaults()
		data := CS_Read(&Snapshot, &SourcePath)
		if IsObject(Snapshot)
				data := _CS_AdmitMetricsCache(data, Snapshot, SourcePath)
		if !data.Has(CS_SECTION) {
				return data
		}
		s := data[CS_SECTION]
		Validated := _CS_ValidateMetricsSection(s)

		; The cipher owns a second live subsystem. Commit that subsystem first;
		; after it returns, every remaining assignment below is non-throwing.
		if Validated.Has("encrypt")
				KL_Enc_SetEnabled(Validated["encrypt"])

		if Validated.Has("enabled")
				MetricsShortcuts.enabled := Validated["enabled"]

		; Canonical ids, shared with the macOS driver, which reads the same four
		; through Manifest.default_for("metrics.<id>").
		if Validated.Has("private_filter_enabled")
				MetricsFilters.private_browsing := Validated["private_filter_enabled"]
		if Validated.Has("secure_filter_enabled")
				MetricsFilters.secure_field := Validated["secure_filter_enabled"]
		if Validated.Has("system_auth_filter_enabled")
				MetricsFilters.system_auth := Validated["system_auth_filter_enabled"]
		if Validated.Has("encrypt")
				MetricsFilters.encrypt := Validated["encrypt"]

		if Validated.Has("disabled_apps")
				MetricsFilters.disabled_apps := Validated["disabled_apps"]
		return data
}

; Commit an explicit metrics candidate through the one atomic config.toml
; writer. PublishFn is invoked by the gateway before config ownership is
; released; callers must never perform the matching live swap after return.
CS_Save(Updates := unset, Context := "the metrics settings", WriterFn := 0,
		NotifyFn := 0, PublishFn := 0,
		FinalizeFn := 0, CompensateFn := 0) {
		global _SaveFullConfigReady, ConfigurationFile
		if !(IsSet(_SaveFullConfigReady) && _SaveFullConfigReady
				&& IsSet(ConfigurationFile) && ConfigurationFile != "") {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
						"the full-config writer is not initialized")
		}
		; Compatibility for callers migrated in the following subsystem commits.
		; SaveFullConfig is tri-state, so DEFERRED must be accepted explicitly.
		if !IsSet(Updates) {
				global CONFIG_SAVE_OK, CONFIG_SAVE_DEFERRED
				Result := SaveFullConfig()
				return Result = CONFIG_SAVE_OK || Result = CONFIG_SAVE_DEFERRED
		}

		return ConfigCommitUpdates(ConfigurationFile, Updates, Context, WriterFn, NotifyFn,
				PublishFn, FinalizeFn, CompensateFn)
}

CS_SaveBuilt(Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
		global _SaveFullConfigReady, ConfigurationFile
		if !(IsSet(_SaveFullConfigReady) && _SaveFullConfigReady
				&& IsSet(ConfigurationFile) && ConfigurationFile != "") {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
						"the full-config writer is not initialized")
		}
		return ConfigCommitBuilt(ConfigurationFile, Context, BuildFn,
				WriterFn, NotifyFn)
}
