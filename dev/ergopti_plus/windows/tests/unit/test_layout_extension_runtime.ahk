; tests/unit/test_layout_extension_runtime.ahk

_L4R_WithPack(Body) {
	global _HotstringExtensionPaths, HotstringGroupConfig
	SavedPaths := _HotstringExtensionPaths.Clone(), SavedGroups := HotstringGroupConfig.Clone()
	Directory := _LCT_TempDir()
	try {
		Root := Directory . "packs", Pack := Root . "\sample"
		DirCreate(Pack . "\hotstrings")
		Assert(FSWriteDurable(Pack . "\manifest.toml", '[extension]`nname = "Sample"`n'))
		Source := '[_meta.sections.wanted]`ndescription = "Wanted"`ndelay = 0.25`npriority = 73`n[[wanted]]`n'
			. '"l4wanted" = { output = "Wanted", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }`n'
			. '"l4simple" = "Simple"`n[[hidden]]`n"l4hidden" = "Hidden"`n'
		Path := Pack . "\hotstrings\words.toml"
		Assert(FSWriteDurable(Path, Source))
		Body.Call(Root, Path)
	} finally {
		_HotstringExtensionPaths := SavedPaths
		HotstringGroupConfig := SavedGroups
		HotstringsResolveBumpGen()
		DirDelete(Directory, true)
	}
}

_L4R_BootSeed() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		Target := ManifestBuildFeaturesMap()
		Packs := HotstringExtensions_Prepare(Target, [Root])
		AssertEqual(Packs.Length, 1)
		AssertEqual(Packs[1].toml_files[1].category, "ext:sample:words")
		AssertEqual(Target["hotstrings"]["groups"]["ext:sample:words"], false)
		AssertEqual(Target["hotstrings"]["modules"]["ext:sample:words"]["wanted"], false)
		Target["hotstrings"]["groups"]["ext:sample:words"] := true
		Target["hotstrings"]["modules"]["ext:sample:words"]["wanted"] := true
		HotstringExtensions_Prepare(Target, [Root])
		AssertEqual(Target["hotstrings"]["modules"]["ext:sample:words"]["wanted"], true)
	}
}
Test("layout-extension-runtime: boot discovery preserves explicit opt-in and seeds absence off", _L4R_BootSeed)

_L4R_Registration() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		global _HotstringRegistrar, HSE_RegistryByGroup
		OldRegistrar := _HotstringRegistrar
		try {
			_HotstringRegistrar := 0
			HSE_RegistryClear()
			Target := ManifestBuildFeaturesMap()
			Packs := HotstringExtensions_Scan([Root])
			HotstringExtensions_Seed(Target, Packs, ManifestDefaultFor)
			AssertEqual(HotstringExtensions_Register(Target, Packs, true), 0)
			Target["hotstrings"]["groups"]["ext:sample:words"] := true
			Target["hotstrings"]["modules"]["ext:sample:words"]["wanted"] := true
			AssertEqual(HotstringExtensions_Register(Target, Packs, false), 0)
			AssertEqual(HotstringExtensions_Register(Target, Packs, true), 2)
			Assert(HSE_RegistryByGroup.Has("ext:sample:words.wanted"), "real engine receives canonical category and section")
			Assert(!HSE_RegistryByGroup.Has("ext:sample:words.hidden"))
			for Group, Specs in HSE_RegistryByGroup {
				AssertEqual(Group, "ext:sample:words.wanted")
				for Spec in Specs
					AssertEqual(Spec.Priority, 73, "the source metadata reaches the real engine")
			}
			AssertEqual(Target["hotstrings"]["modules"]["ext:sample:words"]["wanted"], true)
		} finally {
			_HotstringRegistrar := OldRegistrar
			HSE_RegistryClear()
		}
	}
}
Test("layout-extension-runtime: registration filters sections and attributes both TOML entry shapes", _L4R_Registration)

_L4R_Preview() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		global CategoryEnabled
		Old := CategoryEnabled
		try {
			CategoryEnabled := Map("Hotstrings", true)
			Index := Map(), Set := Map(), Register := _RegisterExtPackTriggers
			AssertEqual(Register.Call(Path, "ext:sample:words", Index, Set, "wanted"), 2)
			Assert(Set.Has("l4wanted"))
			Assert(Set.Has("l4simple"))
			Assert(!Set.Has("l4hidden"))
		} finally CategoryEnabled := Old
	}
}
Test("layout-extension-runtime: preview selects the same enabled section as registration", _L4R_Preview)

_L4R_ConfigRoundTrip() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		ConfigPath := Root . "\config.toml"
		Group := "ext:sample:words"
		Rows := [ManifestSparseOperation("hotstrings.groups." . Group, true),
			ManifestSparseOperation("hotstrings.modules." . Group . ".wanted", true)]
		Assert(TOML_BatchWrite(ConfigPath, Rows))
		Target := ManifestBuildFeaturesMap()
		Packs := HotstringExtensions_Prepare(Target, [Root])
		AssertEqual(ApplyConfigToml(Target, ConfigPath), 2)
		AssertEqual(HotstringExtensions_RegistrationPlan(Target, Packs, true).Length, 1)
		AssertEqual(HotstringExtensions_RegistrationPlan(Target, Packs, false).Length, 0)
		Assert(Target["hotstrings"]["modules"][Group]["wanted"], "master gating never edits desired choices")
		Assert(!Target["hotstrings"]["modules"][Group]["hidden"])
		Assert(TOML_BatchWrite(ConfigPath, [ManifestSparseOperation("hotstrings.groups." . Group, false)]))
		Assert(!ParseTomlFile(ConfigPath)["hotstrings.groups"].Has(Group), "the neutral override is absent on disk")
		; A replacement process has an empty raw-file cache. A fresh private path
		; exercises those exact published bytes without changing live cache policy.
		RestartPath := Root . "\restart.toml"
		Assert(FSWriteDurable(RestartPath, FSReadUtf8Exact(ConfigPath)))
		Restarted := ManifestBuildFeaturesMap()
		Packs := HotstringExtensions_Prepare(Restarted, [Root])
		AssertEqual(ApplyConfigToml(Restarted, RestartPath), 1)
		AssertEqual(HotstringExtensions_RegistrationPlan(Restarted, Packs, true).Length, 0)
		Assert(Restarted["hotstrings"]["modules"][Group]["wanted"], "clearing a group retains its desired children")
	}
}
Test("layout-extension-runtime: quoted sparse preferences survive fresh discovery and owner reload", _L4R_ConfigRoundTrip)

_L4R_InstalledDiscovery() {
	Directory := _LCT_TempDir()
	try {
		LocalDir := LayoutRegistry_LocalDir(Directory)
		Assert(_LCT_Install("ergol", LocalDir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())[1])
		Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", Directory . "missing-registry\")
		AssertEqual(Roots.Length, 3, "bundled, committed generation, user root")
		Target := ManifestBuildFeaturesMap()
		Packs := HotstringExtensions_Prepare(Target, Roots)
		AssertEqual(Packs.Length, 1)
		AssertEqual(Packs[1].id, "ergol")
		AssertEqual(HotstringExtensions_RegistrationPlan(Target, Packs, true).Length, 0)
		Assert(LayoutCatalogue_Uninstall("ergol", LocalDir)["ok"])
		Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", Directory . "missing-registry\")
		AssertEqual(HotstringExtensions_Prepare(ManifestBuildFeaturesMap(), Roots).Length, 0,
			"an unpublished generation left on disk is never discovered")
	} finally DirDelete(Directory, true)
}
Test("layout-extension-runtime: installed record owns discovery and uninstall removes visibility", _L4R_InstalledDiscovery)

_L4R_DamagedRecordNeverStopsStartup() {
	Directory := _LCT_TempDir()
	try {
		LocalDir := LayoutRegistry_LocalDir(Directory)
		DirCreate(LocalDir)
		_LCT_WriteRaw(LocalDir . LayoutRegistry_Settings()["installed_file"], "{ damaged")
		Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", Directory . "missing-registry\")
		AssertEqual(Roots.Length, 2, "the bundled and user roots still load when the installed record is damaged")
		Assert(Roots[2] == RTrim(Directory, "\/") . "\extensions", "the user root follows the installed generations")
	} finally DirDelete(Directory, true)
}
Test("layout-extension-runtime: a damaged installed record never stops startup (config-outdated-installed)",
	_L4R_DamagedRecordNeverStopsStartup)
