; infra/feature_io.ahk

; ==============================================================================
; MODULE: Feature I/O (v2-native)
; DESCRIPTION:
; v2-native feature locator + write/batch for the tray menu, replacing the
; v1->v2 path translator (infra/path_translator.ahk). Given a canonical v2 manifest
; path (e.g. "ahk.layout.ergopti_base", "shortcuts.gpt", "shortcuts.gpt.letter",
; "hotstrings.autocorrection.accents") it resolves the config.toml {section, key}
; and the in-memory Features node by INTROSPECTING the Features Map — no
; hand-maintained PascalCase rename tables.
;
; FEATURES & RATIONALE:
; 1. Derivation, not translation: the v2 manifest path already encodes the full
;    config section (incl. the ahk. driver-namespace prefix). The Features node is
;    found by walking Features along the (ahk-stripped) path. A node that is a Map
;    carrying "enabled" is a Modelisation-alpha feature (its section IS the path so
;    far; its leaf key is an explicit property or "enabled"); a bool leaf is a
;    plain feature (section = path minus leaf, key = leaf, node = parent Map).
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
; @param V2Path  Canonical v2 path; may carry a leading "ahk." driver prefix.
; @param Prop    Optional explicit alpha property leaf (e.g. "letter"). When set,
;                the path is treated as the alpha feature and Prop is the key.
FeatureLocateV2(FeaturesMap, V2Path, Prop := "") {
	if !(FeaturesMap is Map)
		return false

	SecParts := StrSplit(V2Path, ".")
	if (SecParts.Length < 1)
		return false

	; Features keys carry no ahk. namespace — that prefix lives only in the TOML
	; section. WalkParts drives the Features descent; SecParts builds the section.
	WalkParts := SecParts
	if (SecParts[1] == "ahk") {
		WalkParts := []
		Loop SecParts.Length - 1 {
			WalkParts.Push(SecParts[A_Index + 1])
		}
	}
	Offset := SecParts.Length - WalkParts.Length   ; 1 when an ahk. prefix was stripped
	if (WalkParts.Length < 1)
		return false

	Node := FeaturesMap
	Parent := false
	LastKey := ""
	Idx := 0
	for _, Seg in WalkParts {
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
			Section := _FeatureJoin(SecParts, 1, Idx + Offset)
			Key := (Prop != "") ? Prop
				: (Idx < WalkParts.Length ? WalkParts[Idx + 1] : "enabled")
			return Map("section", Section, "key", Key, "v2_node", Node, "is_alpha", true)
		}
	}

	; Plain feature: terminal bool leaf. Section = path minus leaf, key = leaf,
	; node = the parent Map that holds it.
	if (Type(Parent) != "Map")
		return false
	Section := _FeatureJoin(SecParts, 1, SecParts.Length - 1)
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
; @return        true on success, false when the path does not resolve.
WriteFeatureV2(FeaturesMap, V2Path, Value, Prop := "") {
	global ConfigurationFile
	Loc := FeatureLocateV2(FeaturesMap, V2Path, Prop)
	if (Loc == false) {
		; Mirror WriteFeatureBatchV2's logging so a single-path write on an
		; unresolved/unseeded feature is never silent (personal-hotstring-live-
		; toggle-seed) — previously this returned false with zero logging.
		try LoggerWarn("FeatureIO", "WriteFeatureV2: unresolved v2 path '{1}' — skipped.", V2Path)
		return false
	}
	Node := Loc["v2_node"]
	K := Loc["key"]
	; Persistence is the commit point. Mutating the live Features Map first leaves
	; an enabled-but-not-durable feature when the write fails (read-only disk,
	; antivirus lock, interrupted profile sync).
	if !TOML_Write(Value, ConfigurationFile, Loc["section"], K) {
		try LoggerError("FeatureIO", "WriteFeatureV2: persistence failed for '{1}'.", V2Path)
		return false
	}
	if (Type(Node) == "Map")
		Node[K] := Value
	return true
}

; Apply a batch of v2-path mutations to ``FeaturesMap`` in one read-modify-write
; of config.toml. Each entry is a Map("path" => "<v2 path>", "value" => <v>,
; "prop" => "<leaf>"?). Entries that do not resolve are skipped (logged).
; @param FeaturesMap  The Features Map to mutate. Always passed explicitly by
;                      the caller (feedback_loader_target_explicit) — this
;                      function never reaches for a global itself.
; @return  Number of entries applied.
WriteFeatureBatchV2(FeaturesMap, Entries) {
	global ConfigurationFile
	Updates := []
	for Entry in Entries {
		V2Path := Entry["path"]
		Value  := Entry["value"]
		Prop   := Entry.Has("prop") ? Entry["prop"] : ""
		Loc := FeatureLocateV2(FeaturesMap, V2Path, Prop)
		if (Loc == false) {
			try LoggerWarn("FeatureIO", "WriteFeatureBatchV2: unresolved v2 path '{1}' — skipped.", V2Path)
			continue
		}
		Node := Loc["v2_node"]
		K := Loc["key"]
		Updates.Push({ Section: Loc["section"], Key: K, Value: Value, Node: Node })
	}
	if (Updates.Length > 0 and !TOML_BatchWrite(ConfigurationFile, Updates)) {
		try LoggerError("FeatureIO", "WriteFeatureBatchV2: persistence failed; live features were not changed.")
		return 0
	}
	for _, Update in Updates {
		if (Type(Update.Node) == "Map")
			Update.Node[Update.Key] := Update.Value
	}
	return Updates.Length
}

; Read the runtime state of a v2 feature. Returns a Map keyed by the v2 property
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
	Loc := FeatureLocateV2(Features, V2Path)
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





; ===========================================
; ===========================================
; ======= 3/ Mutex sibling resolution =======
; ===========================================
; ===========================================

; The three Shortcuts modifier-combo sub-Maps are mutually exclusive: a single
; chord (AltGr+LAlt, AltGr+CapsLock, LAlt+CapsLock) can be bound to exactly one
; action, so enabling one key must force every sibling key in the same group
; off. Their v2 ids match the manifest section headers consumed below.
global _FEATURE_MUTEX_GROUPS := Map(
	"alt_gr_lalt",      true,
	"alt_gr_caps_lock", true,
	"lalt_caps_lock",   true,
)

; Return the v2 paths of the sibling keys that must be forced false when the
; user enables ``V2Path``. Empty list = no mutex semantics (independent toggle).
; Siblings are enumerated from the manifest section itself, so the set is always
; exactly the group's declared keys — no hand-maintained sibling table.
; @param V2Path  Canonical v2 path; may carry a leading "ahk." prefix.
; @return        Array of sibling v2 paths (ahk.shortcuts.<group>.<key>).
_MutexSiblingPathsForV2(V2Path) {
	global _FEATURE_MUTEX_GROUPS
	Parts := StrSplit(V2Path, ".")
	; Strip the ahk. driver prefix so the shortcuts sub-Map shape is uniform.
	if (Parts.Length >= 1 and Parts[1] == "ahk") {
		Stripped := []
		Loop Parts.Length - 1 {
			Stripped.Push(Parts[A_Index + 1])
		}
		Parts := Stripped
	}
	if (Parts.Length != 3 or Parts[1] != "shortcuts" or !_FEATURE_MUTEX_GROUPS.Has(Parts[2])) {
		return []
	}
	GroupSection := "ahk.shortcuts." . Parts[2]
	CurrentKey := Parts[3]
	Siblings := []
	for _, Entry in ManifestFeaturesForSection(GroupSection) {
		EParts := StrSplit(Entry["path"], ".")
		SibKey := EParts[EParts.Length]
		if (SibKey != CurrentKey) {
			Siblings.Push(GroupSection . "." . SibKey)
		}
	}
	return Siblings
}
