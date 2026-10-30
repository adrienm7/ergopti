; tests/unit/modules/llm/servers/test_ollama_owned_only.ahk

; ==============================================================================
; MODULE: Ergopti Runs Only Its Own Ollama
; DESCRIPTION:
; A user's own Ollama is never selected, reused, started or stopped: the stock
; port is refused, a listener Ergopti does not own never reads as ready, and the
; installed owned runtime restarts silently for an AI already on.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Runs Body with the real shared defaults file loaded into LLM_Defaults. */
_OOO_WithSharedDefaults(Body) {
	global LLM_Defaults
	HadDefaults := IsSet(LLM_Defaults)
	Saved := HadDefaults ? LLM_Defaults : 0
	try {
		LLM_Defaults := Map("llm_ollama_port", 11434, "llm_ollama_owned_port", 11435, "llm_ollama_keep_alive", "7m")
		Body.Call()
	} finally {
		if HadDefaults
			LLM_Defaults := Saved
		else
			LLM_Defaults := unset
	}
}

_OOO_SharedDefaultsDifferAndOwnedLoads() {
	global _SharedDir
	Raw := JsonParse(FileRead(_SharedDir . "\modules\llm\defaults.json", "UTF-8"))
	Assert(Raw["llm_ollama_owned_port"] != Raw["llm_ollama_port"], "the owned port differs from the stock port")
	_OOO_WithSharedDefaults(Run)
	Run() {
		Calls := []
		AssertTrue(LLM_Ollama_LoadDefaults((Port) => (Calls.Push(Port), 1)))
		AssertEqual(1, Calls.Length)
		AssertEqual(11435, Calls[1], "the client boots on the owned port, never the stock one")
	}
}
Test("Ollama owned only: the client boots on llm_ollama_owned_port (ollama-owned-only)", _OOO_SharedDefaultsDifferAndOwnedLoads)

_OOO_StockPortRefused() {
	_OOO_WithSharedDefaults(Run)
	Run() {
		global LLM_Defaults
		AssertFalse(LLM_Option_TryNormalizeOllamaPort(11434, &Normalized), "the stock port is refused as an override")
		AssertFalse(LLM_Option_TryNormalize("ollama_port", "11434", &Normalized), "also through the public option")
		AssertTrue(LLM_Option_TryNormalizeOllamaPort(11435, &Normalized))
		AssertEqual(11435, Normalized)
		LLM_Defaults["llm_ollama_owned_port"] := 11434
		AssertFalse(LLM_Ollama_LoadDefaults((*) => 1), "a shared default on the stock port fails at boot")
	}
}
Test("Ollama owned only: the stock port is never an override (ollama-owned-only)", _OOO_StockPortRefused)

_OOO_SavedStockPortDropped() {
	_OOO_WithSharedDefaults(Run)
	Run() {
		Path := A_Temp . "\ergopti_ollama_owned_saved_port.toml"
		try {
			try FileDelete(Path)
			FileAppend("[llm]`nollama_port = 11434`n", Path, "UTF-8")
			Opts := LLM_Menu_BuildSavedOpts(ParseTomlFile(Path))
			AssertFalse(Opts.Has("ollama_port"), "a saved 11434 never reaches the menu")
		} finally {
			try FileDelete(Path)
		}
	}
}
Test("Ollama owned only: a saved stock port is refused (ollama-owned-only)", _OOO_SavedStockPortDropped)

/** Calls the real dependency owner with a controlled reachability and owner. */
_OOO_DoCheck(Running, Owned, ShowUi) {
	global _LLM_Deps_Epoch, _LLM_Deps_State, _LLM_Deps_Checking
	Saved := [_LLM_Deps_State, _LLM_Deps_Checking]
	Seen := Map("ready", 0, "installer", 0, "silent", "", "state", "", "checking", "")
	try {
		_LLM_Deps_State := "pending", _LLM_Deps_Checking := true
		_LLM_Deps_DoCheck_Result(Running, A_TickCount, _LLM_Deps_Epoch, "model",
			(*) => Seen["ready"] += 1, (*) => 0, ShowUi, Installer, (*) => Owned)
		Seen["state"] := _LLM_Deps_State, Seen["checking"] := _LLM_Deps_Checking
	} finally {
		_LLM_Deps_State := Saved[1], _LLM_Deps_Checking := Saved[2]
	}
	return Seen
	Installer(Model, Epoch, OnReady?, OnFailed?, Silent := false) {
		Seen["installer"] += 1
		Seen["silent"] := Silent
		return true
	}
}

_OOO_ForeignListenerNeverReady() {
	; A system Ollama answering is the original gap: it read as ready.
	Boot := _OOO_DoCheck(true, false, false)
	AssertEqual(0, Boot["ready"], "a foreign server at boot is not ready")
	AssertEqual("pending", Boot["state"])
	AssertEqual(0, Boot["installer"], "nor does it start anything at boot")
	AssertFalse(Boot["checking"])
	Click := _OOO_DoCheck(true, false, true)
	AssertEqual(0, Click["ready"], "an explicit click is not ready either")
	AssertEqual(1, Click["installer"], "it goes to the owned runtime, which names the occupied port")
	AssertFalse(Click["silent"])
	Own := _OOO_DoCheck(true, true, false)
	AssertEqual(1, Own["ready"], "only the owned listener is ready")
	AssertEqual("ready", Own["state"])
}
Test("Ollama owned only: a listener Ergopti does not own is never ready (ollama-owned-only)", _OOO_ForeignListenerNeverReady)

_OOO_BootRestartsOwnedSilently() {
	Boot := _OOO_DoCheck(false, false, false)
	AssertEqual(1, Boot["installer"], "an AI already on restarts its own runtime at boot")
	AssertTrue(Boot["silent"], "with no window and no question")
}
Test("Ollama owned only: boot restarts the owned runtime silently (ollama-owned-only)", _OOO_BootRestartsOwnedSilently)

_OOO_SilentFlowExisting() {
	F := _G4B_Fixture()
	try {
		F.Existing := true
		F.Model := "qwen3:0.6b"
		F.Start(true)
		F.Runtime.PublishReady()
		AssertEqual(0, F.Consents.Length, "a silent restart asks nothing")
		AssertEqual(0, F.Pulls, "and downloads nothing")
		AssertTrue(F.Flow.Ready, "a missing model leaves the daemon up for the model offer")
		AssertEqual(1, F.ReadyCalls)
		F.Flow.Port["pull"] := (Target, Model, Done) => (Done.Call(0), true)
		F.Flow.PullModel("qwen3:0.6b")
		AssertEqual(1, F.Consents.Length, "a later explicit pull consents again")
		AssertEqual("model", F.Consents[1])
	} finally F.Close()
}
Test("Ollama owned only: a silent restart asks nothing and pulls nothing (ollama-owned-only)", _OOO_SilentFlowExisting)

_OOO_SilentFlowMissing() {
	F := _G4B_Fixture()
	try {
		F.Start(true)
		AssertEqual(0, F.Consents.Length)
		for Call in F.Calls
			Assert(Call != "download", "a silent restart never installs")
		AssertEqual(0, F.ReadyCalls)
		AssertEqual(0, F.FailedCalls, "a missing runtime is not a failure at boot")
	} finally F.Close()
}
Test("Ollama owned only: a silent restart never installs (ollama-owned-only)", _OOO_SilentFlowMissing)

_OOO_ReadyIntentIgnoresSaves() {
	F := _G4B_Fixture()
	try {
		F.Existing := true
		F.Start()
		F.Runtime.PublishReady()
		F.Flow.MenuIntent := Map("model", "m", "enabled", true)
		F.Flow.AuxGeneration := 7
		AssertTrue(F.Flow._ReadyIntentCurrent(Map("model", "m", "enabled", true, "other", 1), 7),
			"another setting saved leaves the running daemon current")
		AssertFalse(F.Flow._ReadyIntentCurrent(Map("model", "other", "enabled", true), 7))
		AssertFalse(F.Flow._ReadyIntentCurrent(Map("model", "m", "enabled", false), 7))
		AssertFalse(F.Flow._ReadyIntentCurrent(Map("model", "m", "enabled", true), 8))
	} finally F.Close()
}
Test("Ollama owned only: an ordinary save never retires the READY daemon (ollama-owned-only)", _OOO_ReadyIntentIgnoresSaves)

/** The shipped enable probe with the daemon admitted as Ergopti's own: real curl. */
_LLM_Menu_EnableOwnedProbe(Callback, Owner) {
	return _LLM_Menu_EnableProbe(Callback, Owner, , , (*) => true)
}

_OOO_EnableStartsOwnedInsteadOfProbing() {
	global _LLM_ManagedBootstrap
	Saved := _LLM_ManagedBootstrap
	Probes := 0, Starts := 0
	try {
		_LLM_ManagedBootstrap := 0
		_LLM_Menu_EnableProbe((*) => 0, 0, (*) => Probes += 1, (*) => Starts += 1)
		AssertEqual(0, Probes, "with no owner nothing at that port is consulted")
		AssertEqual(1, Starts, "enabling starts Ergopti's own daemon first")
	} finally {
		_LLM_ManagedBootstrap := Saved
	}
}
Test("Ollama owned only: enabling never probes a foreign listener (ollama-owned-only)", _OOO_EnableStartsOwnedInsteadOfProbing)
