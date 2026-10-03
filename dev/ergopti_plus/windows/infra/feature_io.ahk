; infra/feature_io.ahk

; ==============================================================================
; MODULE: Feature I/O (v2-native)
; DESCRIPTION:
; v2-native feature locator + write/batch for the tray menu, replacing the
; v1->v2 path translator (infra/path_translator.ahk). Given a canonical v2 manifest
; path (e.g. "layout.ergopti_base", "shortcuts.gpt", "shortcuts.gpt.letter",
; "hotstrings.autocorrection.accents") it resolves the config.toml {section, key}
; and the in-memory Features node by INTROSPECTING the Features Map — no
; hand-maintained PascalCase rename tables.
;
; FEATURES & RATIONALE:
; 1. Derivation, not translation: the v2 manifest path IS the config section, and
;    the Features node is found by walking Features along that same path. Since
;    Lot 4 dissolved the driver namespaces those two strings are identical, so
;    the walk and the section no longer need to be kept in step by an offset. A
;    node that is a Map carrying "enabled" is a Modelisation-alpha feature (its
;    section IS the path so far; its leaf key is an explicit property or
;    "enabled"); a bool leaf is a plain feature (section = path minus leaf,
;    key = leaf, node = parent Map).
; 2. Single write path: WriteFeatureV2 mutates the Features node and persists to
;    config.toml in lock-step, exactly like the retired translator did, so a tray
;    toggle survives reload. WriteFeatureBatchV2 batches the persistence.
; 3. Migration safety: while call sites are being migrated, the v1 translator
;    functions delegate here (v1 path -> v2 path -> locate), so this core is
;    exercised by every existing toggle and proven equivalent by
;    tests/meta/test_feature_io_locator_parity.ahk before any call site flips.
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ v2-native locator =======
; ====================================
; ====================================

; Join Parts[FromIdx..ToIdx] with ".". Returns "" when the range is empty.
_FeatureJoin(Parts, FromIdx, ToIdx) {
	Out := ""
	if (ToIdx < FromIdx)
		return ""
	Loop ToIdx - FromIdx + 1 {
		I := FromIdx + A_Index - 1
		Out .= (Out == "" ? "" : ".") . Parts[I]
	}
	return Out
}

; Resolve a v2 manifest path to a Map {section, key, v2_node, is_alpha}, or false
; when the path does not resolve against ``FeaturesMap``.
; @param FeaturesMap  The Features Map to resolve against. Always passed explicitly
;                      by the caller (feedback_loader_target_explicit) — this
;                      function never reaches for a global itself.
; @param V2Path  Canonical v2 path (e.g. "layout.ergopti_base").
; @param Prop    Optional explicit alpha property leaf (e.g. "letter"). When set,
;                the path is treated as the alpha feature and Prop is the key.
FeatureLocateV2(FeaturesMap, V2Path, Prop := "") {
	if !(FeaturesMap is Map)
		return false

	Parts := StrSplit(V2Path, ".")
	if (Parts.Length < 1)
		return false

	return _FeatureLocateParts(FeaturesMap, Parts, Prop)
}

; Read-only intent lookup selects one root without cloning the entire view.
FeatureDesiredLocateV2(FeaturesSource, V2Path) {
	if !(FeaturesSource is Map)
		return false
	Parts := StrSplit(V2Path, ".")
	if !Parts.Length
		return false
	Desired := MasterGateState()
	Root := Parts[1]
	Source := Desired["initialized"] && (Root == "layout" || Root == "shortcuts" || Root == "hotstrings")
		&& Desired["features"].Has(Root) ? Desired["features"] : FeaturesSource
	return _FeatureLocateParts(Source, Parts, "")
}

; Canonical traversal keeps plain leaves and alpha-property path semantics alike.
_FeatureLocateParts(Node, Parts, Prop) {
	Parent := false
	LastKey := ""
	Idx := 0
	for _, Seg in Parts {
		Idx += 1
		if (Type(Node) != "Map" or !Node.Has(Seg))
			return false
		Parent := Node
		LastKey := Seg
		Node := Node[Seg]
		; Alpha feature: a Map carrying "enabled". Its section is the path up to
		; and including this segment; the leaf key is the explicit Prop, the next
		; path segment (an alpha property like "letter"), or "enabled".
		if (Type(Node) == "Map" and Node.Has("enabled")) {
			Section := _FeatureJoin(Parts, 1, Idx)
			Key := (Prop != "") ? Prop
				: (Idx < Parts.Length ? Parts[Idx + 1] : "enabled")
			return Map("section", Section, "key", Key, "v2_node", Node, "is_alpha", true)
		}
	}

	; Plain feature: terminal bool leaf. Section = path minus leaf, key = leaf,
	; node = the parent Map that holds it.
	if (Type(Parent) != "Map")
		return false
	Section := _FeatureJoin(Parts, 1, Parts.Length - 1)
	return Map("section", Section, "key", LastKey, "v2_node", Parent, "is_alpha", false)
}





; ===================================
; ===================================
; ======= 2/ v2-native writes =======
; ===================================
; ===================================

; Apply one v2-path mutation to both ``FeaturesMap`` and config.toml.
; @param FeaturesMap  The Features Map to mutate. Always passed explicitly by
;                      the caller (feedback_loader_target_explicit) — this
;                      function never reaches for a global itself.
; @param V2Path  Canonical v2 path (toggle target, e.g. "shortcuts.gpt").
; @param Value   New value (bool, or string for alpha props like a letter/link).
; @param Prop    Optional alpha property leaf (e.g. "letter"); omit for the
;                enabled/plain toggle.
; @param WriterFn Optional strict batch-writer seam used by behavioural tests.
; @param NotifyFn Optional persistence-failure notifier seam.
; @return        true on success, false when the path does not resolve.
WriteFeatureV2(FeaturesMap, V2Path, Value, Prop := "", WriterFn := 0,
		NotifyFn := 0) {
	global ConfigurationFile
	BuildFn := _FeatureBuildSinglePlan.Bind(FeaturesMap, V2Path, Value, Prop)
	return ConfigCommitBuilt(ConfigurationFile, "feature '" . V2Path . "'",
		BuildFn, WriterFn, NotifyFn)
}

; Apply a batch of v2-path mutations to ``FeaturesMap`` in one read-modify-write
; of config.toml. Each entry is a Map("path" => "<v2 path>", "value" => <v>,
; "prop" => "<leaf>"?). Entries that do not resolve are skipped (logged).
; @param FeaturesMap  The Features Map to mutate. Always passed explicitly by
;                      the caller (feedback_loader_target_explicit) — this
;                      function never reaches for a global itself.
; @param WriterFn Optional strict batch-writer seam used by behavioural tests.
; @param NotifyFn Optional persistence-failure notifier seam.
; @return  Number of entries applied.
WriteFeatureBatchV2(FeaturesMap, Entries, WriterFn := 0, NotifyFn := 0) {
	global ConfigurationFile
	CommitState := { applied: 0 }
	BuildFn := _FeatureBuildBatchPlan.Bind(FeaturesMap, Entries, CommitState)
	Committed := ConfigCommitBuilt(ConfigurationFile, "the feature batch",
		BuildFn, WriterFn, NotifyFn)
	return Committed ? CommitState.applied : 0
}

; Builds one detached leaf candidate. TargetNode retains the explicit
; FeaturesMap identity; CandidateNode carries the unpublished value until the
; global transaction gateway confirms that config.toml is durable.
_FeatureBuildCandidate(FeaturesMap, V2Path, Value, Prop, WriterName) {
	Loc := FeatureLocateV2(FeaturesMap, V2Path, Prop)
	if (Loc == false) {
		try LoggerWarn("FeatureIO", "{1}: unresolved v2 path '{2}' — skipped.",
			WriterName, V2Path)
		return false
	}
	TargetNode := Loc["v2_node"]
	Key := Loc["key"]
	CandidateNode := TargetNode.Clone()
	CandidateNode[Key] := Value
	return {
		update: _ConfigSparseOperation(Loc["section"], Key, Value),
		target_node: TargetNode,
		candidate_node: CandidateNode,
		key: Key
	}
}

_FeatureBuildSinglePlan(FeaturesMap, V2Path, Value, Prop) {
	if _FeatureUsesDesiredState(FeaturesMap)
		return _FeatureBuildDesiredPlan(FeaturesMap,
			[Map("path", V2Path, "value", Value, "prop", Prop)], { applied: 0 })
	Candidate := _FeatureBuildCandidate(FeaturesMap, V2Path, Value, Prop,
		"WriteFeatureV2")
	if !(Candidate is Object)
		return false
	return {
		updates: [Candidate.update],
		publish: _FeaturePublishCandidates.Bind([Candidate])
	}
}

_FeatureBuildBatchPlan(FeaturesMap, Entries, CommitState) {
	if _FeatureUsesDesiredState(FeaturesMap)
		return _FeatureBuildDesiredPlan(FeaturesMap, Entries, CommitState)
	Updates := []
	Candidates := []
	for Entry in Entries {
		V2Path := Entry["path"]
		Value := Entry["value"]
		Prop := Entry.Has("prop") ? Entry["prop"] : ""
		Candidate := _FeatureBuildCandidate(FeaturesMap, V2Path, Value, Prop,
			"WriteFeatureBatchV2")
		if !(Candidate is Object)
			continue
		Updates.Push(Candidate.update)
		Candidates.Push(Candidate)
	}
	CommitState.applied := Updates.Length
	if (Updates.Length = 0)
		return { noop: true }
	return {
		updates: Updates,
		publish: _FeaturePublishCandidates.Bind(Candidates)
	}
}

_FeaturePublishCandidates(Candidates) {
	for Candidate in Candidates
		Candidate.target_node[Candidate.key] := Candidate.candidate_node[Candidate.key]
}

; Explicit detached callers retain their own state. Only the initialized live
; feature tree participates in the driver's desired/runtime publication pair.
_FeatureUsesDesiredState(FeaturesMap) {
	global Features
	return MasterGateState()["initialized"] && IsSet(Features) && FeaturesMap == Features
}

; Called after acquiring config.toml ownership. The runtime patch includes only
; edited leaves, so an unrelated session refusal is never silently reactivated.
_FeatureBuildDesiredPlan(FeaturesMap, Entries, CommitState) {
	Desired := _HSDeepCloneMap(MasterGateDesiredFeatures(FeaturesMap))
	Updates := []
	Resolved := []
	for Entry in Entries {
		Path := Entry["path"]
		Prop := Entry.Get("prop", "")
		Loc := FeatureLocateV2(Desired, Path, Prop)
		RuntimeLoc := FeatureLocateV2(FeaturesMap, Path, Prop)
		if !(Loc is Map) || !(RuntimeLoc is Map)
			throw Error("A desired feature path could not resolve: " . Path)
		Loc["v2_node"][Loc["key"]] := Entry["value"]
		Updates.Push(_ConfigSparseOperation(Loc["section"], Loc["key"], Entry["value"]))
		Resolved.Push({ path: Path, prop: Prop, target: RuntimeLoc["v2_node"], key: RuntimeLoc["key"] })
	}
	CommitState.applied := Updates.Length
	if !Updates.Length
		return { noop: true }
	Runtime := _HSDeepCloneMap(Desired)
	ApplyMasterGatesToFeatures(Runtime, Map(), IsCategoryGated)
	for Patch in Resolved {
		Loc := FeatureLocateV2(Runtime, Patch.path, Patch.prop)
		Patch.value := Loc["v2_node"][Loc["key"]]
	}
	return { updates: Updates, publish: _FeaturePublishDesiredPlan.Bind(Desired, Resolved) }
}

; All allocations, manifest reads, and durable writes finish before publication.
_FeaturePublishDesiredPlan(Desired, Patches) {
	PreviousCritical := Critical("On")
	try {
		MasterGateState()["features"] := Desired
		for Patch in Patches
			Patch.target[Patch.key] := Patch.value
	} finally Critical(PreviousCritical)
}

; Read the desired state of a v2 feature. Returns a Map keyed by the v2 property
; names present on the feature node (enabled, letter, link, search_engine, …),
; or an empty Map when the path does not resolve. Mirrors the shape the menu
; needs while dropping the v1 PascalCase property names.
; Read-only accessor — binding the production Features global here is the
; explicit carve-out feedback_loader_target_explicit allows (the mutating
; FeatureLocateV2/WriteFeatureV2/WriteFeatureBatchV2 never do).
ReadFeatureStateV2(V2Path) {
	global Features
	State := Map()
	if !IsSet(Features) or !(Features is Map)
		return State
	Loc := FeatureDesiredLocateV2(Features, V2Path)
	if (Loc == false)
		return State
	Node := Loc["v2_node"]
	if (Type(Node) != "Map")
		return State
	if Loc["is_alpha"] {
		for _, P in ["enabled", "letter", "link", "search_engine", "search_engine_url_query"
			, "dated_notes", "destination_folder", "pattern_max_length"] {
			if Node.Has(P)
				State[P] := (P == "enabled" or P == "dated_notes") ? (Node[P] = true) : Node[P]
		}
	} else {
		K := Loc["key"]
		if Node.Has(K)
			State["enabled"] := (Node[K] = true)
	}
	return State
}
