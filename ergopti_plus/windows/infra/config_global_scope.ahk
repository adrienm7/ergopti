; infra/config_global_scope.ahk

; ==============================================================================
; MODULE: Global Scoped Configuration
; DESCRIPTION:
; Composes existing detached file owners into the same admitted transaction.
; Credentials, unknown data and recommendation consent remain outside its writes.
; ==============================================================================

/** Applies the complete declared scope through one conditional file cohort. */
ConfigGlobalScopeApply(Mode, Options := unset) {
	global _SharedDir, ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ConfigGlobalScopeApply(Mode, IsSet(Options) ? Options : Map())
		finally Critical(InheritedCritical)
	}
	Selected := IsSet(Options) ? Options : Map()
	if !(Selected is Map)
		throw TypeError("Global scope options must be an owner map.")
	Owners := Map("action_parameter_domain", ConfigScopeActionParameterDomain)
	Plan := ManifestScopePlan("global", Mode, [], Owners)
	if Plan.presets.Length != 1 || Plan.presets[1].scope != "tap_holds"
			|| Plan.presets[1].preset != "tap_hold" || Plan.presets[1].mode != Mode
		throw Error("The global scope declares an unsupported separate-file owner.")
	if !_HCW_FlushNumericWrite(false)
		return Map("status", "refused", "scope", "global", "mode", Mode, "detail", "pending_numeric_write")
	Hotstrings := HotstringsScopeFiles(Selected)
	; The restore brings the recommended layer into a folder without layers.toml
	; (TapHoldScopeOwner), for the folder the caller names.
	Tap := TapHoldScopeOwner(Selected.Get("tap_hold_path", _TH_TapHoldConfigPath()),
		Selected.Get("tap_hold_defaults", _SharedDir . "\tap_hold\defaults.toml"), Mode,
		Selected.Get("layers_config_dir", ""))
	Files := GlobalScopeFiles(Selected.Get("path", ConfigurationFile), [Hotstrings, Tap])
	Operations() {
		Providers := Map("hotstrings", Hotstrings.Inventory.Bind(Hotstrings),
			"personal_shortcuts", PersonalShortcutScopePaths, "parameters", ConfigScopeActionParameterPaths)
		Inventory := ManifestScopeInventory("global", Providers, Owners)
		Rows := ManifestScopePlan("global", Mode, Inventory, Owners).operations
		; Supplements remain bounded by their real domain, not a global wildcard.
		for Row in GestureScopeResetOperations("gestures", Mode)
			Rows.Push(Row)
		for Row in _LLM_Menu_ScopeResetOperations("llm", Mode)
			Rows.Push(Row)
		for Row in ConfigIOShortcutScopeOperations("shortcuts", Mode)
			Rows.Push(Row)
		Seen := Map()
		for Row in Rows {
			Identity := Row.Section . "`n" . Row.Key
			if Seen.Has(Identity)
				throw Error("The global scope has overlapping configuration owners.")
			Seen[Identity] := true
		}
		return Rows
	}
	return ConfigScopeCommitOperations("global", Mode, Operations, Selected, Files)
}

; This composition has no lifecycle, backup, publication or recovery authority.
class GlobalScopeFiles {
	__New(ConfigPath, Owners) {
		this.paths := [], this.owners := Owners, this.admitted := Map()
		Normalized := _ConfigTransitionNormalizePath(ConfigPath)
		if !(Normalized is String)
			throw ValueError("The global configuration path is invalid.")
		Seen := Map(StrLower(Normalized), true)
		for Owner in Owners {
			for Path in Owner.paths {
				Normalized := _ConfigTransitionNormalizePath(Path)
				if !(Normalized is String) || Seen.Has(StrLower(Normalized))
					throw ValueError("Global file owners overlap or have an invalid path.")
				Seen[StrLower(Normalized)] := true
				this.admitted[StrLower(Normalized)] := true
				this.paths.Push(Path)
			}
		}
	}

	Build() {
		Candidates := [], Seen := Map()
		for Owner in this.owners {
			for Candidate in Owner.Build() {
				Normalized := _ConfigTransitionNormalizePath(Candidate.path)
				if !(Normalized is String) || !this.admitted.Has(StrLower(Normalized))
						|| Seen.Has(StrLower(Normalized))
					throw Error("A detached global candidate has no unique admitted owner.")
				Seen[StrLower(Normalized)] := true
				Candidates.Push(Candidate)
			}
		}
		if Seen.Count != this.admitted.Count
			throw Error("A global file owner did not return its complete detached inventory.")
		return Candidates
	}
}
