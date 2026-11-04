; tests/unit/infra/config/persistence/test_config_typed_transactions.ahk

; ==============================================================================
; MODULE: Configuration Typed Transaction Tests
; DESCRIPTION:
; Covers full-save and detached LLM boundaries that bypass targeted commits.
; Injected persistence callbacks receive the same typed contract as real I/O.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Full-save Boundaries =======
; =======================================
; =======================================

_CTT_FullSave(Injected) {
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	Path := _CTU_NewPath()
	Updates := [{ Section: "layout", Key: "ergopti_base", Value: false }]
	Seen := []
	Writer := (Target, Typed) => (Seen.Push(Typed), TOML_BatchWrite(Target, Typed))
	try {
		_CFGFS_Prepare(Path)
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(Injected ? Writer : 0,
			(*) => true, true, 0, () => Updates))
		AssertTrue(RegExMatch(FSRead(Path), "m)^ergopti_base = false$"),
			"full-save must preserve schema intent even with an injected collector")
		AssertTrue(Updates[1].Value is Integer)
		AssertEqual(Injected ? 1 : 0, Seen.Length)
		if Injected
			AssertTrue(Seen[1][1].Value is TOML_Bool)
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		FSDelete(Path)
	}
}
Test("config: full-save types new Boolean values before real publication "
	. "(config-typed-full-save-real)", _CTT_FullSave.Bind(false))
Test("config: full-save types new Boolean values before injected writer "
	. "(config-typed-full-save-injected)", _CTT_FullSave.Bind(true))

_CTT_RealCollector(OnboardingSeen) {
	global Features, _LLM_Menu, _LLM_Menu_Loaded
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	OldFeatures := Features
	OldMenu := _LLM_Menu
	HadLoaded := IsSet(_LLM_Menu_Loaded)
	OldLoaded := HadLoaded ? _LLM_Menu_Loaded : false
	Path := _CTU_NewPath()
	try {
		Features := ManifestBuildFeaturesMap()
		_LLM_Menu := _HSDeepCloneMap(OldMenu)
		_LLM_Menu["onboarding_seen"] := OnboardingSeen
		_LLM_Menu["app_profile_overrides"] := Map()
		_LLM_Menu["user_profiles"] := []
		_LLM_Menu_Loaded := true
		Legacy := '# unowned dashboard shortcuts`n[metrics]`nmetrics_shortcut_typing = "ctrl+alt+m" # keep typing`nmetrics_shortcut_apps = { future = "keep" } # keep apps`n'
		Legacy := _CMJFixtureCurrentSource(Legacy)
		AssertTrue(FSWrite(Path, Legacy))
		; The actual subject exists before the fixture completes its one native Boot.
		_CFGFS_Prepare(Path)
		AssertTrue(FSUtf8ExactMatches(Path, Legacy))
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true),
			"the real full-save collector must produce valid typed updates")
		for Line in StrSplit(Legacy, "`n") {
			if Line != ""
				AssertContains(FSRead(Path), Line . "`n", "the real full-save owns no retired binding bytes")
		}
		Target := ManifestBuildFeaturesMap()
		if !OnboardingSeen
			AssertEqual("absent", TOML_Read(Path, "llm", "onboarding_seen", "absent"),
				"a neutral onboarding value is persisted as deletion")
		ApplyConfigToml(Target, Path)
		AssertEqual(OnboardingSeen, Target["llm"]["onboarding_seen"],
			"the final collector override must preserve the loaded onboarding Boolean")
	} finally {
		Features := OldFeatures
		_LLM_Menu := OldMenu
		_LLM_Menu_Loaded := HadLoaded ? OldLoaded : unset
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		FSDelete(Path)
	}
}
Test("config: real full-save collector persists unseen onboarding state "
	. "(config-typed-real-collector-false)", _CTT_RealCollector.Bind(false))
Test("config: real full-save collector persists seen onboarding state "
	. "(config-typed-real-collector-true)", _CTT_RealCollector.Bind(true))





; ==========================================
; ==========================================
; ======= 2/ Detached LLM Boundaries =======
; ==========================================
; ==========================================

_CTT_DetachedLlm(Injected) {
	global ConfigurationFile
	Previous := _LMT_InstallApiFixture()
	Seen := []
	Build := (Path, Updates) => (Seen.Push(Updates), TOML_BuildConfigUpdatedContent(Path, Updates))
	Collect := (CandidateFeatures, CandidateMenu) => [
		{ Section: "llm", Key: "enabled", Value: CandidateMenu["enabled"] },
		{ Section: "llm", Key: "api_entry_id", Value: CandidateMenu["api_entry_id"] }
	]
	try {
		AssertTrue(LLM_Menu_CommitApiEntriesMutation("typed detached regression",
			_LMT_ApiMutate, _LMT_Apply, ConfigTransitionProductionPort(),
			_LMT_Notify, _LMT_Acquire, _LMT_Settle, Collect,
			Injected ? Build : 0, _LMT_ApiSerialize))
		Target := ManifestBuildFeaturesMap()
		Target["llm"]["enabled"] := false
		AssertEqual(1, ApplyConfigToml(Target, ConfigurationFile),
			"enabled is manifest-owned; api_entry_id is loaded separately by LLMMenu")
		AssertEqual(true, Target["llm"]["enabled"])
		AssertEqual("api_new", TOML_ParseFreshFile(ConfigurationFile)["llm"]["api_entry_id"])
		AssertEqual(Injected ? 1 : 0, Seen.Length)
		if Injected
			AssertTrue(Seen[1][1].Value is TOML_Bool)
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("config: detached LLM transaction types Boolean values before real rendering "
	. "(config-typed-llm-real)", _CTT_DetachedLlm.Bind(false))
Test("config: detached LLM transaction types Boolean values before injected builder "
	. "(config-typed-llm-injected)", _CTT_DetachedLlm.Bind(true))





; =========================================
; =========================================
; ======= 3/ Parses per Transaction =======
; =========================================
; =========================================

; Every document-mode write parsed its source twice (once for the source model,
; once again for the expected model it then mutates) before parsing the final
; candidate. The expected model now starts from the one source parse
; (config-parse-per-transaction).
_CTT_ParsesPerWrite() {
	global _TOML_DocumentParses
	Runtime := _CFGFS_CaptureRuntime()
	Path := _CTU_NewPath()
	try {
		AssertTrue(FSWrite(Path, _CMJFixtureCurrentSource("[layout]`nergopti_base = true`n[metrics]`nenabled = true`n")))
		_CFGFS_Prepare(Path)
		Source := FSReadUtf8Exact(Path)
		Before := _TOML_DocumentParses
		Built := TOML_BuildConfigDocumentCandidate(Source, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }], [])
		AssertEqual(2, _TOML_DocumentParses - Before, "one source parse and one final candidate parse")
		AssertFalse(Built["preserve_source"])
		AssertEqual(false, TOML_ParseDocument(Built["content"])["layout"]["ergopti_base"].Value)
		AssertEqual(true, TOML_ParseDocument(Source)["layout"]["ergopti_base"].Value, "the source model is never the mutated one")
		Before := _TOML_DocumentParses
		TOML_BuildConfigDocumentCandidate(Source, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }], [])
		AssertEqual(1, _TOML_DocumentParses - Before, "an unchanged source needs its one source parse only")
		Before := _TOML_DocumentParses
		AssertTrue(TOML_ConfigBatchWrite(Path, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }]))
		; The schema journal admits the final candidate with its own parse: it is
		; an independent admission owner and never trusts the builder model.
		AssertEqual(3, _TOML_DocumentParses - Before, "one real write: source, candidate, journal admission")
		AssertEqual(false, TOML_ParseDocument(FSReadUtf8Exact(Path))["layout"]["ergopti_base"].Value)
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		FSDelete(Path)
	}
}
Test("config: one document-mode write spends one source parse "
	. "(config-parse-per-transaction)", _CTT_ParsesPerWrite)
