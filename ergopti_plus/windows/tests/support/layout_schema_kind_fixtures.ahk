; tests/support/layout_schema_kind_fixtures.ahk

; ==============================================================================
; MODULE: Layout Schema Source-Kind Fixtures
; DESCRIPTION:
; Shares schema-token and duplicate-member controls between installed layout
; metadata and composition admission. Positive numeric forms retain the
; existing JSON-number contract; booleans and numeric strings cannot alias it.
; ==============================================================================

#Requires AutoHotkey v2.0

_LayoutSchemaKindFixtures(Version) {
	Number := String(Version)
	First := '"schema_version":' . Number
	return [
		{ Label: "boolean-true", Members: '"schema_version":true', Refused: true },
		{ Label: "quoted-number", Members: '"schema_version":' . JsonStringLiteral(Number), Refused: true },
		{ Label: "last-boolean", Members: First . ',"schema_version":true', Refused: true },
		{ Label: "escaped-last-boolean", Members: First . ',"schema_\u0076ersion":true', Refused: true },
		{ Label: "number", Members: First, Refused: false },
		{ Label: "decimal-number", Members: First . ".0", Refused: false },
		{ Label: "exponent-number", Members: First . "e0", Refused: false },
		{ Label: "last-number", Members: '"schema_version":true,' . First, Refused: false },
		{ Label: "boolean-false", Members: '"schema_version":false', Refused: true },
		{ Label: "zero", Members: '"schema_version":0', Refused: true }
	]
}
