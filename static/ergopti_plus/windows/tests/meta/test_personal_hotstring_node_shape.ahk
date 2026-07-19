; tests/meta/test_personal_hotstring_node_shape.ahk

; ==============================================================================
; MODULE: Personal-Hotstring Node-Shape Guard Meta Test
; DESCRIPTION:
; Static source guard for findings personal-hotstring-node-shape +
; toml-loader-shape-mismatch (F-L06).
;
; Personal-section nodes are manifest-seeded as Map("enabled", ...). A hand-edited
; flat [hotstrings.personal] block with a colliding bool leaf
; (autocorrection = false) makes the v2 config loader overwrite that Map node with a
; scalar (Node[Key] := Value), and the tray personal-count helper then indexes
; ["enabled"] on the bool — which throws in AHK v2, crashing the menu build. Two
; defences: the menu helper verifies the node is a Map before indexing, and the
; loader refuses a leaf assignment that would change a node's Map/scalar shape.
;
; Source-scan because both fixes are about guarding a deref/assignment the headless
; runner cannot reach with a malformed live config.
; ==============================================================================

#Requires AutoHotkey v2.0


_PHNS_AssertNodeShapeGuards() {
	; Scan the whole driver source (move-resilient) — both guards live in unique
	; top-level functions, so a file move never breaks these presence checks.
	DriverSource := _DriverSourceConcat()
	Assert(InStr(DriverSource, "[PV2Id] is Map") > 0,
		"the personal-hotstrings count helper must verify the section node is a Map before indexing [enabled] — a hand-edited flat [hotstrings.personal] bool leaf can clobber the seeded Map and throw (personal-hotstring-node-shape)")
	Assert(InStr(DriverSource, "(Node[Key] is Map) != (Value is Map)") > 0,
		"the v2 config loader must skip (with a WARN) a leaf assignment that would change a node's Map/scalar shape, so a flat-form key cannot flatten a seeded {enabled:...} Map node (toml-loader-shape-mismatch)")
}
Test("config: personal-hotstring node shape is guarded against flat-form clobber (personal-hotstring-node-shape)", _PHNS_AssertNodeShapeGuards)
