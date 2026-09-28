; tests/unit/test_config_scope_manifest.ahk

; Runtime owners supply known identities, never arbitrary keys read from disk.
_ScopeManifestInventory() {
	Providers := Map("packs", (*) => ["hotstrings.modules.ext:ergopti:rolls.fast", "hotstrings.groups.ext:ergopti:rolls",
		"hotstrings.modules.ext:ergopti:rolls.fast", "shortcuts.personal.other", "hotstrings.personal.autocorrection.enabled"])
	Paths := ManifestScopeInventory("hotstrings", Providers)
	AssertEqual(Paths.Length, 2)
	AssertEqual(Paths[1], "hotstrings.groups.ext:ergopti:rolls")
	AssertEqual(Paths[2], "hotstrings.modules.ext:ergopti:rolls.fast")
	Rejected := false
	try ManifestScopeInventory("hotstrings", Map("unknown", (*) => ["private.credentials.token"]))
	catch
		Rejected := true
	Assert(Rejected, "unknown inventory must refuse before persistence")
	Rejected := false
	try ManifestScopeInventory("hotstrings", Map("missing", (*) => 0))
	catch
		Rejected := true
	Assert(Rejected, "an unavailable owner is not an empty inventory")
	Sparse := []
	Sparse.Length := 2
	Sparse[2] := "hotstrings.groups.real"
	Rejected := false
	try ManifestScopeInventory("hotstrings", Map("sparse", (*) => Sparse))
	catch
		Rejected := true
	Assert(Rejected, "an incomplete inventory must refuse")
}
Test("config-scope: explicit inventory validates and separates owners", _ScopeManifestInventory)

_ScopeManifestPlan() {
	for Mode in ["clear", "recommended"] {
		Plan := ManifestScopePlan("global", Mode)
		AssertEqual(Plan.presets.Length, 1)
		AssertEqual(Plan.presets[1].scope, "tap_holds")
		AssertEqual(Plan.presets[1].preset, "tap_hold")
		AssertEqual(Plan.presets[1].mode, Mode)
		AssertEqual(ManifestScopePlan("gestures", Mode).presets.Length, 0)
	}
	Paths := ["hotstrings.groups.ext:ergopti:rolls", "hotstrings.modules.ext:ergopti:rolls.fast",
		"shortcuts.personal.other"]
	Rows := ManifestScopePlan("hotstrings", "recommended", Paths).operations
	Found := 0
	for Row in Rows {
		Assert(Row.Section != "shortcuts.personal", "another scope must never leak into this plan")
		if Row.Section == 'hotstrings.modules."ext:ergopti:rolls"' {
			AssertEqual(Row.Key, "fast")
			AssertEqual(Row.Value, true)
			Found += 1
		}
		Assert(Row.Section . "." . Row.Key != "hotstrings.preview_ai_enabled", "recommendations preserve AI consent")
	}
	AssertEqual(Found, 1)
}
Test("config-scope: plans preserve preset ownership and consent boundaries", _ScopeManifestPlan)

_ScopeManifestQuotedRoundTrip() {
	Path := A_Temp . "\\ergopti-scope-quoted-" . A_TickCount . ".toml"
	try {
		Source := '[hotstrings.modules."ext:ergopti:rolls"]`nfast = true`nneighbor = true`n[private]`ncredential = "keep"`n'
		Assert(FSWriteDurable(Path, Source))
		Rows := [ManifestSparseOperation("hotstrings.modules.ext:ergopti:rolls.fast", false)]
		Assert(TOML_BatchWrite(Path, Rows))
		Parsed := ParseTomlFile(Path)
		Assert(!Parsed['hotstrings.modules."ext:ergopti:rolls"'].Has("fast"))
		AssertEqual(Parsed['hotstrings.modules."ext:ergopti:rolls"']["neighbor"], true)
		AssertEqual(Parsed["private"]["credential"], "keep")
		Row := ManifestSparseOperation("hotstrings.modules.ext:ergopti:rolls.fast", true)
		Assert(TOML_BatchWrite(Path, _ConfigPrepareTypedUpdates([Row])))
		AssertContains(FSReadUtf8Exact(Path), "fast = true", "dynamic Boolean intent must survive admitted serialization")
		Candidate := Map("hotstrings", Map("modules", Map("ext:ergopti:rolls", Map("fast", false))))
		ApplyConfigToml(Candidate, Path)
		AssertEqual(Candidate["hotstrings"]["modules"]["ext:ergopti:rolls"]["fast"], true,
			"real loader must address the same unquoted runtime identity")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("config-scope: quoted extension paths round trip through the real owner", _ScopeManifestQuotedRoundTrip)
