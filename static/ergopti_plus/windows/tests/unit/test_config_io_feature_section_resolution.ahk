; tests/unit/test_config_io_feature_section_resolution.ahk

; ==============================================================================
; MODULE: Config I/O Feature Section Resolution Tests
; DESCRIPTION:
; Validates that flattening the in-memory Features tree back into TOML
; {section, key, value} writes puts every leaf in the ONE section the loader
; will read it back from. Covers the call site that flattens Features:
; _CollectFeatureUpdates (SaveFullConfig, the boot-time full-config flush). The
; second one, the bulk flip behind the retired « Tout activer » / « Tout
; désactiver » rows, is gone with them.
;
; ROOT CAUSE:
; A leaf written to TWO sections is the defect. TOML_BatchWrite sorts sections
; alphabetically and ApplyConfigToml applies them in file order, so whichever
; duplicate lands later silently overwrites the other on the next reload — the
; user's hand edit reverts and nothing reports it.
;
; The original form of this bug came from the driver namespaces: the Features
; tree was built with the "ahk." prefix stripped, so "shortcuts" merged a shared
; manifest section with an AHK-only one and the walked nesting could no longer
; say which of the two a leaf came from. Both walkers reused the stripped path
; verbatim and emitted a bare duplicate of every AHK-only section. Lot 4 removed
; the silos, so the walked nesting IS the section and the per-leaf manifest
; lookup that used to repair it is gone.
;
; That makes the assertion below stronger rather than weaker: instead of pinning
; one hand-listed prefix per leaf, it pins the two properties that made the
; original bug a bug — every (section, key) is emitted at most once, and every
; emitted section is one the loader can resolve. A reintroduced namespace split
; breaks both.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================================
; ==============================================================
; ======= 1/ Shared fixture ====================================
; ==============================================================
; ==============================================================

; A Features fixture shaped like the real manifest output: the sub-trees that
; used to live in the AHK silo (layout, shortcuts.personal, gestures,
; category_enabled) alongside the ones that never did (shortcuts.microsoft_bold,
; shortcuts.gpt) inside the SAME top-level "shortcuts" key — the collision that
; a naive per-top-level-key prefix heuristic got wrong.
_CFP_Fixture() {
	return Map(
		"layout", Map("ergopti_base", false),
		"gestures", Map("enabled", false, "swipe_3_down", "tab_close"),
		"shortcuts", Map(
			"microsoft_bold", false,
			"gpt", Map("enabled", false, "link", "https://example"),
			"personal", Map("laptop_broken_key", false)
		),
		"category_enabled", Map("hotstrings", false)
	)
}

; Returns true when Updates contains an entry matching Section/Key/Value exactly.
_CFP_HasUpdate(Updates, Section, Key, Value) {
	for U in Updates {
		if (U.Section = Section and U.Key = Key and U.Value = Value)
			return true
	}
	return false
}

; Render Updates as a sorted, comparable "section|key" multiset. Comparing the
; WHOLE emission against an expected list is what makes the duplicate visible:
; the original bug added a second section for a leaf that already had one, so
; every per-leaf spot check still passed and only the total was wrong.
;
; Counting by key alone would not do: "enabled" legitimately appears in several
; sections at once (gestures, shortcuts.gpt), and a test that forbade that would
; be asserting something untrue about the config format.
_CFP_Emission(Updates) {
	Lines := []
	for U in Updates
		Lines.Push(U.Section . "|" . U.Key)
	; Insertion sort — the arrays here are a handful of entries and AHK v2 has no
	; built-in sort for a plain Array of strings.
	Loop Lines.Length - 1 {
		I := A_Index + 1
		V := Lines[I]
		J := I - 1
		while (J >= 1 and StrCompare(Lines[J], V) > 0) {
			Lines[J + 1] := Lines[J]
			J -= 1
		}
		Lines[J + 1] := V
	}
	Out := ""
	for L in Lines
		Out .= (Out == "" ? "" : "`n") . L
	return Out
}





; ===============================================================
; ===============================================================
; ======= 2/ _CollectFeatureUpdates (SaveFullConfig path) =======
; ===============================================================
; ===============================================================

_CFP_CollectFeatureUpdates_SectionsMatchNesting() {
	ManifestEnsureLoaded()
	Updates := []
	_CollectFeatureUpdates(Updates, "", _CFP_Fixture())

	AssertTrue(_CFP_HasUpdate(Updates, "layout", "ergopti_base", false),
		"layout.ergopti_base must be written to [layout]")
	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts.personal", "laptop_broken_key", false),
		"shortcuts.personal.laptop_broken_key must be written to [shortcuts.personal]")
	AssertTrue(_CFP_HasUpdate(Updates, "category_enabled", "hotstrings", false),
		"category_enabled.hotstrings must be written to [category_enabled]")
	AssertTrue(_CFP_HasUpdate(Updates, "gestures", "enabled", false),
		"gestures.enabled must be written to [gestures]")
	AssertTrue(_CFP_HasUpdate(Updates, "gestures", "swipe_3_down", "tab_close"),
		"gestures.swipe_3_down must be written to [gestures]")

	; Leaves that never lived in a silo must be unaffected by its removal.
	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts", "microsoft_bold", false),
		"shortcuts.microsoft_bold must stay at [shortcuts]")
	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts.gpt", "enabled", false),
		"shortcuts.gpt.enabled must stay at [shortcuts.gpt]")
	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts.gpt", "link", "https://example"),
		"shortcuts.gpt.link must stay at [shortcuts.gpt]")
}
Test("config_io: _CollectFeatureUpdates writes each leaf to its walked section",
	_CFP_CollectFeatureUpdates_SectionsMatchNesting)

_CFP_CollectFeatureUpdates_EmitsExactlyTheseWrites() {
	ManifestEnsureLoaded()
	Updates := []
	_CollectFeatureUpdates(Updates, "", _CFP_Fixture())

	; The complete emission, not a sample of it. An extra line is the clobber
	; (two sections for one leaf, the later applied write silently reverting the
	; earlier); a missing line is a setting that stops being persisted at all.
	Expected := "category_enabled|hotstrings`n"
		. "gestures|enabled`n"
		. "gestures|swipe_3_down`n"
		. "layout|ergopti_base`n"
		. "shortcuts.gpt|enabled`n"
		. "shortcuts.gpt|link`n"
		. "shortcuts.personal|laptop_broken_key`n"
		. "shortcuts|microsoft_bold"
	AssertEqual(Expected, _CFP_Emission(Updates),
		"the 8 fixture leaves must produce exactly these 8 section|key writes")
}
Test("config_io: _CollectFeatureUpdates emits exactly one write per leaf",
	_CFP_CollectFeatureUpdates_EmitsExactlyTheseWrites)

_CFP_CollectFeatureUpdates_SectionsAreLoadable() {
	; Every section emitted must be one ApplyConfigToml can resolve, otherwise
	; the write round-trips into an "unknown section path" error on next boot.
	ManifestEnsureLoaded()
	Updates := []
	_CollectFeatureUpdates(Updates, "", _CFP_Fixture())

	Tree := ManifestBuildFeaturesMap()
	for U in Updates {
		Node := Tree
		Ok := true
		for Part in StrSplit(U.Section, ".") {
			if (Part == "")
				continue
			if (Type(Node) == "Map" and Node.Has(Part)) {
				Node := Node[Part]
			} else {
				Ok := false
				break
			}
		}
		AssertTrue(Ok or TomlSectionIsDynamicPersonalNamespace(U.Section),
			"section '[" . U.Section . "]' is not resolvable against the manifest tree")
	}
}
Test("config_io: every section _CollectFeatureUpdates emits is loadable back",
	_CFP_CollectFeatureUpdates_SectionsAreLoadable)
