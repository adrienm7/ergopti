; tests/unit/ui/onboarding/test_onboarding_semantic_current_values.ahk

; ==============================================================================
; MODULE: Onboarding Semantic Current Values Tests
; DESCRIPTION:
; The wizard preview must retain the runtime reader's namespace identities and
; typed Boolean values across table, dotted and inline source representations.
; ==============================================================================

#Requires AutoHotkey v2.0

_TOASC_Source(Shape, Enabled) {
	Metrics := Enabled ? "true" : "false"
	Gestures := Enabled ? "false" : "true"
	switch Shape {
		case "table":
			return '[metrics]`nmetrics_enabled = ' . Metrics . '`n[gestures]`nenabled = ' . Gestures
				. '`n[hotstrings]`ntrigger_char = "0"`n[unrelated]`nenabled = true`n'
		case "dotted":
			return 'metrics.metrics_enabled = ' . Metrics . '`ngestures.enabled = ' . Gestures
				. '`nhotstrings.trigger_char = "0"`nunrelated.enabled = true`n'
		case "inline":
			return 'metrics = { metrics_enabled = ' . Metrics . ' }`ngestures = { enabled = ' . Gestures
				. ' }`nhotstrings = { trigger_char = "0" }`nunrelated = { enabled = true }`n'
		case "quoted":
			return '["metrics"]`n"metrics_enabled" = ' . Metrics . '`n["gestures"]`n"enabled" = ' . Gestures
				. '`n["hotstrings"]`n"trigger_char" = "0"`n["unrelated"]`n"enabled" = true`n'
		default: throw ValueError("Unknown onboarding current-value source shape.")
	}
}

_TOASC_ReadCurrent(Shape, Enabled) {
	Folder := _TOAN_NewFolder()
	Path := Folder . "\config.toml"
	Source := Chr(0xFEFF) . _TOASC_Source(Shape, Enabled)
	try {
		AssertTrue(FSWrite(Path, Source))
		Admitted := ConfigTomlDecodeSnapshot(Source)
		AssertEqual(Enabled, Admitted.Cache["metrics"]["metrics_enabled"],
			"the canonical runtime projection must admit this exact metrics setting")
		AssertEqual(!Enabled, Admitted.Cache["gestures"]["enabled"])
		Values := OnboardingReadCurrentValues(OnboardingCatalogue(), Path)
		AssertTrue(Values is Map, "a valid semantic configuration must remain readable")
		AssertEqual(3, Values.Count, "only actual wizard paths are projected")
		AssertTrue(Values["metrics.metrics_enabled"] is TOML_Bool,
			"preview JSON must carry a Boolean instead of the native cache's numeric flag")
		AssertTrue(Values["gestures.enabled"] is TOML_Bool)
		AssertEqual(Enabled, Values["metrics.metrics_enabled"].Value)
		AssertEqual(!Enabled, Values["gestures.enabled"].Value)
		AssertTrue(Values["hotstrings.trigger_char"] is String)
		AssertEqual("0", Values["hotstrings.trigger_char"])
		Json := OnboardingValuesJson(Values)
		AssertContains(Json, '"metrics.metrics_enabled":' . (Enabled ? "true" : "false"))
		AssertContains(Json, '"gestures.enabled":' . (Enabled ? "false" : "true"))
		AssertContains(Json, '"hotstrings.trigger_char":"0"')
		AssertEqual(Source, FSReadUtf8Exact(Path), "preview must leave authored source bytes untouched")
	} finally _TOAN_DeleteFolder(Folder)
}
for _TOASC_Shape in ["table", "dotted", "inline", "quoted"]
	for _TOASC_Enabled in [false, true]
		Test("onboarding: " . _TOASC_Shape . " preview retains Boolean " . _TOASC_Enabled
			. " semantics (onboarding-semantic-current-values)", _TOASC_ReadCurrent.Bind(_TOASC_Shape, _TOASC_Enabled))

_TOASC_LiteralDotsStayUnrelated() {
	Folder := _TOAN_NewFolder()
	Path := Folder . "\config.toml"
	Source := '"metrics.metrics_enabled" = true`n"gestures.enabled" = true`n'
	try {
		AssertTrue(FSWrite(Path, Source))
		Admitted := ConfigTomlDecodeSnapshot(Source)
		AssertFalse(Admitted.Cache.Has("metrics"), "a literal dotted root key is not a feature namespace")
		Values := OnboardingReadCurrentValues(OnboardingCatalogue(), Path)
		AssertTrue(Values is Map)
		AssertEqual(0, Values.Count, "the wizard must not invent semantic paths by splitting literal keys")
		AssertEqual("{}", OnboardingValuesJson(Values))
	} finally _TOAN_DeleteFolder(Folder)
}
Test("onboarding: literal dotted keys stay outside the wizard (onboarding-semantic-current-values)",
	_TOASC_LiteralDotsStayUnrelated)

_TOASC_InvalidNamespaceIsRefused() {
	Folder := _TOAN_NewFolder()
	Path := Folder . "\config.toml"
	try {
		AssertTrue(FSWrite(Path, 'metrics = { metrics_enabled = true }`nmetrics.metrics_enabled = false`n'))
		AssertTrue(OnboardingReadCurrentValues(OnboardingCatalogue(), Path) is String,
			"invalid duplicate namespace ownership must refuse the preview instead of showing neutral values")
	} finally _TOAN_DeleteFolder(Folder)
}
Test("onboarding: invalid semantic namespace refuses the preview (onboarding-semantic-current-values)",
	_TOASC_InvalidNamespaceIsRefused)
