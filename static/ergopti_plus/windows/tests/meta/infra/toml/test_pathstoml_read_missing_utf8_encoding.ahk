; tests/meta/infra/toml/test_pathstoml_read_missing_utf8_encoding.ahk

; ==============================================================================
; MODULE: paths.toml UTF-8 Read Guard Regression
; DESCRIPTION:
; Exercises the actual Unicode locator/boot-selector pipeline. The historical
; registration remains stable without pinning one particular FileRead spelling.
; ==============================================================================

#Requires AutoHotkey v2.0

_PRMUE_ReadPathsTomlUsesUtf8() {
	_PBAD_Case(false)
}
Test("toml_helpers: ReadPathsToml reads paths.toml as UTF-8 (pathstoml-read-missing-utf8-encoding)", _PRMUE_ReadPathsTomlUsesUtf8)
