; tests/unit/hotstrings/engine/magic_key/test_star_slot.ahk

; ==============================================================================
; MODULE: The ★ Key's Win Slot Tests
; DESCRIPTION:
; Replays the independent shared policy vectors (star_slot_vectors.json) and
; actual Win32 layouts: Win+★ follows the key that types the real ★ at its base
; level, never the configured magic key (maintainer's decision of 2026-11-21). Native
; cohort tests exercise acknowledged handoff and exact compensation on refusal.
; No test injects host input or replaces an assertion with a source-only check.
; ==============================================================================

#Requires AutoHotkey v2.0

; These native fixtures require exact DLL output even when the layout is absent
; from the user's installed list. Loading must preserve both active owners.
_MET_Layout(Klid) {
	Caller := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
	Window := DllCall("GetForegroundWindow", "Ptr")
	ForegroundProcess := 0
	ForegroundThread := DllCall("GetWindowThreadProcessId", "Ptr", Window, "UInt*", &ForegroundProcess, "UInt")
	Assert(Window != 0 && ForegroundThread != 0 && ForegroundProcess != 0,
		"the native layout fixture requires an acknowledged foreground owner")
	Assert(ForegroundProcess != DllCall("GetCurrentProcessId", "UInt"),
		"a fixture with keyboard focus must refuse loading before it can change the user's layout")
	Foreground := DllCall("GetKeyboardLayout", "UInt", ForegroundThread, "Ptr")
	Hkl := DllCall("LoadKeyboardLayoutW", "Str", Klid, "UInt", 0x80, "Ptr")
	Assert(Hkl != 0, "the native ★ slot fixture requires keyboard layout " . Klid)
	Wanted := Integer("0x" . Klid)
	AssertEqual((Wanted << 16) | Wanted, Hkl & 0xFFFFFFFF,
		"the exact requested native layout must not be replaced by the system's default language")
	AssertEqual(Caller, DllCall("GetKeyboardLayout", "UInt", 0, "Ptr"),
		"loading a native fixture must not activate or reorder its caller layout")
	AssertEqual(Foreground, DllCall("GetKeyboardLayout", "UInt", ForegroundThread, "Ptr"),
		"the exact foreground thread retains its native layout")
	return Hkl
}

_MET_ActualDefaultCatalogue() {
	global _SharedDir
	Root := _SharedDir
	State := StarSlotState(), Saved := State.Clone()
	try {
		Catalogue := StarSlotPhysicalCatalogue(), Keys := Map()
		for Key in Catalogue["keys"]
			Keys[Key["code"]] := Key["ahk"]
		for Code, Scan in Map("KeyA", "SC01E", "KeyC", "SC02E", "Semicolon", "SC027", "Quote", "SC028")
			AssertEqual(Scan, Keys[Code], "the zero-argument production reader uses the actual physical registry")
		AssertTrue(Catalogue == StarSlotPhysicalCatalogue(Root),
			"default and explicit production roots share one catalogue owner")
		State["initialized"] := false, State["legacy"] := Map()
		Callback := (*) => 0
		AssertTrue(StarSlotRecordLegacy("sc1e", Callback),
			"top-level legacy registration resolves the production root without an injected catalogue")
		AssertTrue(State["legacy"]["SC01E"] == Callback,
			"the actual legacy callback retains its canonical physical identity")
		AssertEqual(Root, _SharedDir, "catalogue registration cannot replace the initialized shared root")
	} finally {
		_SharedDir := Root
		State.Clear()
		for Key, Value in Saved
			State[Key] := Value
	}
}
Test("★ key slot: zero-argument catalogue and legacy registration use the actual shared root", _MET_ActualDefaultCatalogue)

_MET_Options(Changes := unset) {
	if !IsSet(Changes)
		Changes := Map()
	Known := Map()
	for Key in StarSlotPhysicalCatalogue(_SharedDir)["keys"]
		Known[Key["code"]] := true
	Candidates := Changes.Get("candidates", [Map("code", "KeyC", "native_code", 8,
		"identity", "physical:KeyC", "text", Chr(0x2605), "direct", true, "dead", false)])
	Claims := Map()
	if Changes.Has("claim")
		Claims["physical:KeyC"] := Map("action", Changes["claim"])
	if Changes.Has("unrelated_claim")
		Claims["physical:KeyA"] := Map("action", Changes["unrelated_claim"])
	Options := Map("default_action", "open_hotstrings_editor",
		"is_action", (Id) => Id == "open_hotstrings_editor" || Id == "copy",
		"known_codes", Known, "explicit_claims", Claims,
		"source", Map("generation", 11, "status", Changes.Get("status", "ready"), "candidates", Candidates),
		"configuration_generation", 23, "admission", Map("master", Changes.Get("master", true),
			"paused", Changes.Get("paused", false), "inhibited", Changes.Get("inhibited", false)))
	if Changes.Has("stored_action")
		Options["stored_action"] := Changes["stored_action"]
	return Options
}

_MET_SharedVectors() {
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\shortcuts\star_slot_vectors.json", "UTF-8"))
	Assert(Corpus["vectors"].Length >= 20, "the policy corpus must retain all independent behavior cases")
	for Vector in Corpus["vectors"] {
		Decision := StarSlotResolve(_MET_Options(Vector["changes"]))
		Expected := Vector["expected"]
		AssertEqual(Expected["active"], Decision["active"], Vector["id"])
		AssertEqual(Expected["action"], Decision["action"], Vector["id"])
		AssertEqual(Expected.Get("reason", ""), Decision["reason"], Vector["id"])
		ExpectedCode := Expected.Get("source_code", "")
		if !(ExpectedCode is String)
			ExpectedCode := ""
		AssertEqual(ExpectedCode, Decision["source"] is Map ? Decision["source"]["code"] : "", Vector["id"])
		AssertEqual("shortcuts.keyboard.meta_star", Decision["path"])
		AssertEqual("keyboard__meta_star", Decision["binding_id"])
	}
	Options := _MET_Options(), Decision := StarSlotResolve(Options)
	Options["source"]["candidates"][1]["native_code"] := 999
	AssertEqual(8, Decision["source"]["native_code"], "receipt mutation cannot retarget a published decision")
	Live := Map("source_generation", 11, "configuration_generation", 23,
		"action", "open_hotstrings_editor", "master", true, "paused", false, "inhibited", false)
	AssertTrue(StarSlotCanDeliver(Decision, Live))
	for Key, Value in Map("source_generation", 12, "configuration_generation", 24,
		"action", "copy", "master", false, "paused", true, "inhibited", true) {
		Changed := Live.Clone(), Changed[Key] := Value
		AssertFalse(StarSlotCanDeliver(Decision, Changed), "queued delivery rechecks " . Key)
	}
	Unknown := _MET_Options()
	Unknown["source"]["candidates"][1]["code"] := "SC999"
	AssertThrows(() => StarSlotResolve(Unknown), "fabricated physical slots are not catalogue evidence")
}
Test("★ key slot: independent shared vectors and stale-delivery fences", _MET_SharedVectors)

_MET_FreshProvenance() {
	global _IniCache, KeyboardShortcutAssignments
	SavedCache := IsSet(_IniCache) ? _IniCache : unset
	SavedKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	try {
		KeyboardShortcutAssignments := Map("meta_c", "none", "meta_d", "none", "meta_star", "open_hotstrings_editor")
		Defaults := KeyboardShortcutAssignments.Clone()
		Raw := Map(), Updates := []
		CollectKeyboardShortcutUpdates(Updates, KeyboardShortcutAssignments, Raw, Defaults)
		AssertEqual(1, Updates.Length, "a fresh save does not fabricate personal neutral chord assignments")
		AssertEqual("meta_star", Updates[1].Key, "the runnable ★ key default remains ordinary configuration")
		Source := Map("code", "KeyC", "native_code", 0x2E, "identity", "win:SC02E", "text", Chr(0x2605))
		_IniCache := Map("shortcuts.keyboard", Raw)
		AssertFalse(_StarSlotExplicitClaim(Source, _MET_Layout("00000409")) is Map,
			"merged neutral defaults are not raw personal provenance")
		Raw["meta_c"] := "none", Updates := []
		CollectKeyboardShortcutUpdates(Updates, KeyboardShortcutAssignments, Raw, Defaults)
		AssertEqual(2, Updates.Length, "an actual personal none remains durable on every full save")
		Claim := _StarSlotExplicitClaim(Source, _MET_Layout("00000409"))
		AssertEqual("meta_c", Claim["slot"])
		AssertEqual("none", Claim["action"], "stored none owns the resolved physical chord")
		AssertEqual(1, Claim["slots"].Length)
		Raw["meta_c"] := "copy", KeyboardShortcutAssignments["meta_c"] := "copy"
		AssertEqual("copy", _StarSlotExplicitClaim(Source, _MET_Layout("00000409"))["action"],
			"a personal action is never replaced by the default editor")
	} finally {
		_IniCache := IsSet(SavedCache) ? SavedCache : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboard) ? SavedKeyboard : unset
	}
}
Test("★ key slot: fresh default provenance differs from actual personal none", _MET_FreshProvenance)

_MET_ExistingPhysicalSlots() {
	State := StarSlotState(), Saved := State.Clone()
	try {
		State["initialized"] := false, State["ordinary_physical"] := Map()
		Catalogue := StarSlotPhysicalCatalogue(_SharedDir)
		AssertFalse(StarSlotRecordOrdinaryPhysical("meta_d", "copy", Catalogue),
			"ordinary Win+VK slots keep their existing registrar owner")
		AssertTrue(StarSlotRecordOrdinaryPhysical("meta_sc029", "copy", Catalogue),
			"the existing supported physical Backquote slot joins the sole broker")
		AssertEqual("meta_sc029", State["ordinary_physical"]["SC029"]["slot"])
		AssertEqual("copy", State["ordinary_physical"]["SC029"]["action"])
		AssertThrows(() => StarSlotRecordOrdinaryPhysical("meta_sc1ff", "copy", Catalogue),
			"an invented scan outside the actual physical catalogue cannot acquire input")
		State["layouts"] := Map(), State["legacy"] := Map()
		LegacyCalls := 0, LayoutCalls := 0
		StarSlotRecordLegacy("sc1e", (*) => LegacyCalls += 1, Catalogue)
		StarSlotRecordLayoutFallback("SC01E", (*) => LayoutCalls += 1, 0, Catalogue)
		AssertEqual(1, State["legacy"].Count)
		AssertTrue(State["legacy"].Has("SC01E"), "native unpadded source aliases canonicalize before priority lookup")
		Scans := Map()
		for Scan in State["legacy"]
			Scans[Scan] := true
		for Scan in State["layouts"]
			Scans[Scan] := true
		Scans[StarSlotNormalizeScan("sc01e", Catalogue)] := true
		AssertEqual(1, Scans.Count, "legacy, fallback and source aliases acquire one native variant")
		AssertThrows(() => StarSlotRecordLegacy("sc1ff", (*) => 0, Catalogue),
			"legacy native producers cannot invent a scan outside the actual physical inventory")
		State["initialized"] := true
		AssertThrows(() => StarSlotRecordOrdinaryPhysical("meta_sc029", "copy", Catalogue),
			"an acquired physical owner cannot be silently replaced")
	} finally {
		State.Clear()
		for Key, Value in Saved
			State[Key] := Value
	}
}
Test("★ key slot: existing physical slots join once while ordinary VK slots stay owned", _MET_ExistingPhysicalSlots)

_MET_RealLayouts() {
	Us := _MET_Layout("00000409"), French := _MET_Layout("0000040C")
	Known := _MET_Options()["known_codes"]
	UsSource := StarSlotProbeSource(Us, 1, StarSlotPhysicalCatalogue(_SharedDir))
	AssertEqual("source_missing", StarSlotSelectSource(UsSource, Known)["reason"],
		"US QWERTY has no key typing ★: no Win+★ default ships there")
	FrenchSource := StarSlotProbeSource(French, 2, StarSlotPhysicalCatalogue(_SharedDir))
	AssertEqual("source_missing", StarSlotSelectSource(FrenchSource, Known)["reason"],
		"French AZERTY has no key typing ★, whatever magic key is configured")
	Quote := 0
	for Candidate in FrenchSource["candidates"] {
		if Candidate["code"] == "Quote"
			Quote := Candidate
	}
	AssertTrue(Quote is Map && Quote["text"] == Chr(0xF9), "the French ù key is probed, yet it is no ★ key")
	Projected := StarSlotProbeSource(Us, 3, StarSlotPhysicalCatalogue(_SharedDir),
		(Scan, Hkl) => { Count: 0, Text: "" },
		(Code, Scan, Native) => (Code == "KeyJ" || Code == "KeyC")
			? { Count: 1, Text: Chr(0x2605) } : Native)
	AssertEqual("source_ambiguous", StarSlotSelectSource(Projected, Known)["reason"],
		"two keys typing ★ give no single Win+★ key")
	Single := []
	for Candidate in Projected["candidates"] {
		if Candidate["code"] == "KeyJ"
			Single.Push(Candidate)
	}
	Projected["candidates"] := Single
	AssertEqual("KeyJ", StarSlotSelectSource(Projected, Known)["source"]["code"],
		"the one key typing ★ at its base level is the slot's key")
}
Test("★ key slot: real neutral US and French source receipts", _MET_RealLayouts)

_MET_UnavailableNativeSource() {
	Receipt := StarSlotProbeSource(0, 1, StarSlotPhysicalCatalogue(_SharedDir))
	AssertEqual("unavailable", Receipt["status"], "HKL zero cannot authorize native probing")
	AssertEqual(0, Receipt["candidates"].Length, "an unavailable layout supplies no physical evidence")
	Selected := StarSlotSelectSource(Receipt, _MET_Options()["known_codes"])
	AssertEqual("source_unavailable", Selected["reason"])
	AssertFalse(Selected["source"] is Map, "the real source owner cannot fabricate a fallback physical key")
	AssertFalse(_StarSlotExplicitClaim(Selected["source"], 0) is Map,
		"unavailable native evidence cannot acquire an ordinary Win owner")
}
Test("★ key slot: unavailable native layouts retain strict source refusal (magic-editor-native-layout-fixture)",
	_MET_UnavailableNativeSource)

_MET_ActualSourceOwner() {
	global Features, ScriptInformation, KLE_Model, TapHold
	Saved := [Features, ScriptInformation, KLE_Model, TapHold]
	try {
		Features := Map("layout", Map("ergopti_base", false, "direct_access_digits", "native", "emulated_layout", ""),
			"hotstrings", Map("magic_key", Map("replace", Map("enabled", true))))
		ScriptInformation := Map("MagicKey", Chr(0x2605), "MagicKeySourceScan", "SC024")
		KLE_Model := 0, TapHold := Map("keys", Map())
		Table := StarSlotPhysicalCatalogue(_SharedDir), Known := _MET_Options()["known_codes"]
		Us := _MET_Layout("00000409")
		Receipt := _StarSlotCurrentSource(1, Table, Us)
		AssertEqual("KeyJ", StarSlotSelectSource(Receipt, Known)["source"]["code"],
			"the declared key the remap turns into ★ is the slot's key")
		Features["hotstrings"]["magic_key"]["replace"]["enabled"] := false
		Receipt := _StarSlotCurrentSource(2, Table, Us)
		AssertEqual("source_missing", StarSlotSelectSource(Receipt, Known)["reason"],
			"without the remap the US layout types no ★")
		Features["hotstrings"]["magic_key"]["replace"]["enabled"] := true
		ScriptInformation["MagicKey"] := Chr(0xF9)
		Receipt := _StarSlotCurrentSource(3, Table, Us)
		AssertEqual("source_missing", StarSlotSelectSource(Receipt, Known)["reason"],
			"a configured ù moves no Win+★: the slot follows the real ★")
	} finally {
		Features := Saved[1], ScriptInformation := Saved[2], KLE_Model := Saved[3], TapHold := Saved[4]
	}
}
Test("★ key slot: effective physical owner priority and native retargeting", _MET_ActualSourceOwner)

; Both Ergopti base tables are built from the whole layer, so they are built once
; per probe; rebuilding them for every catalogue key made the boot probe quadratic.
_MET_BaseTableBuilds() {
	Counts := _PerfCountersOwner().Counts
	return Counts.Get("ergopti_layout.base_mapping_build", 0) + Counts.Get("ergopti_layout.base_dead_keys_build", 0)
}

_MET_BaseTablesOncePerProbe() {
	global Features, ScriptInformation, KLE_Model, TapHold
	_TestEnsureErgoptiLayout()
	Saved := [Features, ScriptInformation, KLE_Model, TapHold]
	try {
		Features := Map("layout", Map("ergopti_base", true, "direct_access_digits", "native", "emulated_layout", ""),
			"hotstrings", Map("magic_key", Map("replace", Map("enabled", false))))
		ScriptInformation := Map("MagicKey", ";", "MagicKeySourceScan", "SC024")
		KLE_Model := 0, TapHold := Map("keys", Map())
		Hkl := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
		Full := StarSlotPhysicalCatalogue(_SharedDir)
		One := 0
		for Key in Full["keys"]
			if Key["code"] == "KeyA"
				One := Map("keys", [Key])
		AssertTrue(One is Map, "the physical registry names KeyA")
		Before := _MET_BaseTableBuilds()
		_StarSlotCurrentSource(1, One, Hkl)
		OneBuilds := _MET_BaseTableBuilds() - Before
		AssertTrue(OneBuilds > 0, "control: a key of the built-in base layer reads the Ergopti base tables")
		Before := _MET_BaseTableBuilds()
		Receipt := _StarSlotCurrentSource(2, Full, Hkl)
		AssertEqual(OneBuilds, _MET_BaseTableBuilds() - Before,
			"a probe of every physical key builds the base tables as often as a probe of one key")
		Entry := ErgoptiBaseMapping()[0x1E]
		Expected := (Entry is String) ? Entry : Entry.alt
		Typed := ""
		for Candidate in Receipt["candidates"]
			if Candidate["code"] == "KeyA"
				Typed := Candidate["text"]
		AssertEqual(Expected, Typed, "the shared tables still answer what the built-in base layer types on KeyA")
	} finally {
		Features := Saved[1], ScriptInformation := Saved[2], KLE_Model := Saved[3], TapHold := Saved[4]
	}
}
Test("★ key slot: one probe builds the Ergopti base tables once (magic-probe-base-tables-once)",
	_MET_BaseTablesOncePerProbe)

_MET_CohortRefusals() {
	for Refuse in ["", "reserve", "disable", "activate", "retire"]
		_MET_CohortRefusal(Refuse)
}

_MET_CohortRefusal(Refuse) {
	Native := Map(), Personal := Map("personal-vk", true, "personal-sc", true)
	Events := [], Handles := Map(), Debt := "", ContractThrew := false
	Reserve(Scan) {
		Events.Push("reserve " . Scan)
		if Refuse == "reserve" && Scan == "SC028"
			return ""
		Native[Scan] := false
		return Scan
	}
	SetEnabled(Handle, Enabled) {
		Events.Push((Enabled ? "restore " : "disable ") . Handle)
		if Refuse == "disable" && !Enabled && Handle == "personal-sc"
			return false
		Personal[Handle] := Enabled
		return true
	}
	Activate(Handle) {
		Events.Push("activate " . Handle)
		if (Refuse == "activate" || Refuse == "retire") && Handle == "SC028"
			return false
		Native[Handle] := true
		return true
	}
	Retire(Handle) {
		Events.Push("retire " . Handle)
		if Refuse == "retire" && Handle == "SC027"
			return false
		Native.Delete(Handle)
		return true
	}
	try StarSlotAcquireCohort(Map("SC027", true, "SC028", true),
		["personal-vk", "personal-sc"], Handles,
		Map("reserve", Reserve, "activate", Activate, "retire", Retire, "set_enabled", SetEnabled))
	catch as Err {
		ContractThrew := true
		Debt := Err.Message
	}
	if Refuse == "" {
		AssertFalse(ContractThrew, "The complete native cohort must not throw: " . Debt)
		AssertEqual(2, Handles.Count)
		AssertTrue(Native["SC027"] && Native["SC028"], "the complete native cohort is acknowledged")
		AssertFalse(Personal["personal-vk"] || Personal["personal-sc"], "both aliases yield to the sole broker")
		AssertEqual("disable personal-sc", Events[4], "all personal handoffs precede native activation")
	} else {
		Assert(Debt != "", "a native refusal cannot report successful boot")
		AssertTrue(Personal["personal-vk"] && Personal["personal-sc"], "exact previous personal owners recover")
		if Refuse == "retire" {
			AssertEqual(1, Handles.Count, "retirement debt remains owned and inspectable")
			AssertTrue(Handles.Has("SC027"))
			Assert(InStr(Debt, "Unacknowledged compensation"), "retirement refusal is never hidden")
		} else {
			AssertEqual(0, Handles.Count)
			AssertEqual(0, Native.Count, "all acquired native handles retire before failure returns")
		}
	}
}
Test("★ key slot: cohort acquisition compensates every native handoff refusal", _MET_CohortRefusals)

_MET_RegistrarRetainsCriterion() {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS, HOTKEY_REGISTRAR_NEXT_TOKEN
	Saved := [HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS, HOTKEY_REGISTRAR_NEXT_TOKEN]
	Native := Map(), Events := [], Context := 0, RefuseOff := false, Deliveries := 0
	Criterion := (*) => true
	Select(*) {
		Context := Criterion
	}
	Probe(Name) {
		Events.Push(Map("kind", "probe", "context", Context))
		return Native.Has(Name)
	}
	HotkeyPort(Name, Action, Options := unset) {
		Events.Push(Map("kind", IsSet(Options) ? "install" : Action, "context", Context))
		if IsSet(Options) {
			Native[Name] := Map("callback", Action, "enabled", false)
			return true
		}
		if Action == "Off" && RefuseOff
			throw Error("injected exact-context Off refusal")
		Native[Name]["enabled"] := Action == "On"
		return true
	}
	try {
		HOTKEY_REGISTRAR_BINDINGS := Map(), HOTKEY_REGISTRAR_SPECS := Map(), HOTKEY_REGISTRAR_NEXT_TOKEN := 0
		Descriptor := HotkeyRegistrarResolvedNativeDescriptor("#SC027")
		Handle := HotkeyRegistrarReservePhysicalBroker("Cmd+SC027", (*) => Deliveries += 1,
			"test-physical-broker", Descriptor, Criterion,
			Map("hotkey", HotkeyPort, "hotif", Select, "probe", Probe))
		Assert(Handle != "", "the actual registrar must reserve an inert physical owner")
		AssertEqual("#sc027", Descriptor["native_spec"], "the actual descriptor canonicalizes its named scan")
		AssertTrue(Native.Has(Descriptor["native_spec"]), "the exact installed native spelling owns the callback")
		Native[Descriptor["native_spec"]]["callback"].Call()
		AssertEqual(0, Deliveries, "reserved native callbacks lack action authority")
		AssertTrue(_HotkeyRegistrarActivate(Handle), "activation uses the retained physical context")
		Native[Descriptor["native_spec"]]["callback"].Call()
		AssertEqual(1, Deliveries)
		RefuseOff := true
		AssertFalse(HotkeyRegistrarUnbind(Handle), "a native Off refusal retains the exact owner")
		Native[Descriptor["native_spec"]]["callback"].Call()
		AssertEqual(2, Deliveries, "refusal preserves prior active authority")
		RefuseOff := false
		AssertTrue(HotkeyRegistrarSetEnabled(Handle, false))
		Native[Descriptor["native_spec"]]["callback"].Call()
		AssertEqual(2, Deliveries, "disabled native callbacks cannot deliver")
		AssertTrue(HotkeyRegistrarSetEnabled(Handle, true))
		AssertTrue(HotkeyRegistrarUnbind(Handle))
		Native[Descriptor["native_spec"]]["callback"].Call()
		AssertEqual(2, Deliveries, "acknowledged retirement rejects stale callback delivery")
		for Event in Events
			AssertTrue(Event["context"] == Criterion, "every native probe/On/Off retains the identical criterion")
	} finally {
		HOTKEY_REGISTRAR_BINDINGS := Saved[1], HOTKEY_REGISTRAR_SPECS := Saved[2]
		HOTKEY_REGISTRAR_NEXT_TOKEN := Saved[3]
	}
}
Test("★ key slot: actual registrar retains exact physical context through refusal", _MET_RegistrarRetainsCriterion)

_MET_PrivateNativeRegistry() {
	Receipt := { Calls: 0, Code: -1, Output: "", Errors: "" }
	Done(Code, Output, Errors) {
		Receipt.Calls += 1, Receipt.Code := Code, Receipt.Output := Output, Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\support\star_slot_native.ahk"], Done)
	AssertTrue(IsObject(Handle), "the actual native probe has an acknowledged process owner")
	try {
		AssertTrue(Handle.start(), "the exact inert native process owner acknowledges publication")
		Started := A_TickCount
		while Receipt.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the native registry probe completes exactly once")
		AssertEqual(0, Receipt.Code, "real AHK physical/VK aliases acknowledge the cohort: " . Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "no native-context errors are hidden")
		AssertEqual("vk-aliases|context-retained|unknown-refused", Receipt.Output,
			"the actual native registry preserves ordinary aliases, exact criteria and unknown owners")
	} finally {
		AssertTrue(Handle.terminate(), "the exact native probe process tree is acknowledged before returning")
	}
}
Test("★ key slot: private actual AHK registry proves physical and VK variant handoff", _MET_PrivateNativeRegistry)

/** Existing handle custody must refuse reacquisition before any native effect. */
_MET_CohortRetainedNativeCannotBeOverwritten() {
	Handles := Map("SC027", "original-native-token"), Calls := 0
	Reserve(Scan) {
		Calls += 1
		return "replacement-native-token"
	}
	Ports := Map("reserve", Reserve, "activate", (*) => true, "retire", (*) => true,
		"set_enabled", (*) => true)
	Refused := false
	try StarSlotAcquireCohort(Map("SC027", true), [], Handles, Ports)
	catch as Failure
		Refused := InStr(Failure.Message, "unsettled cohort compensation") > 0
	AssertTrue(Refused, "retained native debt must refuse before another cohort can start")
	AssertEqual(0, Calls, "the old native owner forbids even a replacement reservation")
	AssertEqual(1, Handles.Count)
	AssertEqual("original-native-token", Handles["SC027"], "reacquisition must retain the exact first token")
}
Test("★ key slot custody: retained native handles fence replacement (todo108-custody)",
	_MET_CohortRetainedNativeCannotBeOverwritten)

/** A native disable may take effect before it refuses or throws its receipt. */
_MET_CohortUnacknowledgedDisableCase(Mode) {
	Handles := Map(), Enabled := true, Restores := 0
	SetEnabled(Handle, Desired) {
		AssertEqual("exact-personal-token", Handle)
		Enabled := Desired
		if Desired {
			Restores += 1
			return true
		}
		if Mode == "throw"
			throw Error("native disable mutated before its exception")
		return Mode == "malformed" ? "1" : false
	}
	Ports := Map("reserve", (Scan) => "exact-native-token", "activate", (*) => true,
		"retire", (*) => true, "set_enabled", SetEnabled)
	Refused := false
	try StarSlotAcquireCohort(Map("SC027", true), ["exact-personal-token"], Handles, Ports)
	catch
		Refused := true
	AssertTrue(Refused, "a missing exact disable acknowledgement cannot publish a broker")
	AssertTrue(Enabled, "even a disable that mutated before refusal must restore its exact personal owner")
	AssertEqual(1, Restores, "restoration custody must be captured before the native disable call")
	AssertEqual(0, Handles.Count, "the rejected native broker must retire before returning")
}
Test("★ key slot custody: false disable after mutation restores its owner (todo108-custody)",
	_MET_CohortUnacknowledgedDisableCase.Bind("false"))
Test("★ key slot custody: throwing disable after mutation restores its owner (todo108-custody)",
	_MET_CohortUnacknowledgedDisableCase.Bind("throw"))
Test("★ key slot custody: malformed disable cannot acknowledge handoff (todo108-custody)",
	_MET_CohortUnacknowledgedDisableCase.Bind("malformed"))

/** Failed native retire and personal restoration survive as exact retry duties. */
_MET_CohortRetainedCompensationCase(Mode) {
	Handles := Map(), RestoreDebt := Map(), Enabled := true, Reservations := 0
	RefuseRestore := true, RefuseRetire := true, Restores := [], Retirements := []
	Reserve(Scan) {
		Reservations += 1
		return "native-first-token"
	}
	SetEnabled(Handle, Desired) {
		if !Desired {
			Enabled := false
			return true
		}
		Restores.Push(Handle)
		if RefuseRestore {
			if Mode == "throw"
				throw Error("controlled native personal restore exception")
			return Mode == "malformed" ? "1" : false
		}
		Enabled := true
		return true
	}
	Retire(Handle) {
		Retirements.Push(Handle)
		if RefuseRetire {
			if Mode == "throw"
				throw Error("controlled native retirement exception")
			return Mode == "malformed" ? "1" : false
		}
		return true
	}
	Ports := Map("reserve", Reserve, "activate", (*) => false, "retire", Retire,
		"set_enabled", SetEnabled)
	AssertThrows(() => StarSlotAcquireCohort(Map("SC027", true), ["personal-first-token"],
		Handles, Ports, RestoreDebt))
	AssertEqual("native-first-token", Handles["SC027"], "failed retirement keeps the exact native capability")
	AssertTrue(RestoreDebt.Has("personal-first-token"), "failed restoration keeps the exact personal capability")
	AssertFalse(Enabled, "a refused restoration must never be represented as accepted")
	Before := Reservations
	AssertThrows(() => StarSlotAcquireCohort(Map("SC027", true), ["another-personal-token"],
		Handles, Ports, RestoreDebt))
	AssertEqual(Before, Reservations, "retained compensation forbids another native reservation")
	Receipt := StarSlotSettleCohortDebt(Handles, RestoreDebt, Ports)
	AssertEqual("retained", Receipt["status"], "repeated false, malformed or throwing acknowledgements retain custody")
	AssertEqual("native-first-token", Handles["SC027"])
	AssertTrue(RestoreDebt.Has("personal-first-token"))
	RefuseRetire := false, RefuseRestore := false
	Receipt := StarSlotSettleCohortDebt(Handles, RestoreDebt, Ports)
	AssertEqual("settled", Receipt["status"])
	AssertEqual(0, Handles.Count)
	AssertEqual(0, RestoreDebt.Count)
	AssertTrue(Enabled, "only a genuine restoration acknowledgement reopens personal delivery")
	for Handle in Retirements
		AssertEqual("native-first-token", Handle, "every retry addresses only the first native capability")
	for Handle in Restores
		AssertEqual("personal-first-token", Handle, "every retry addresses only the first personal capability")
}
Test("★ key slot custody: false compensation retains exact retry duties (todo108-custody)",
	_MET_CohortRetainedCompensationCase.Bind("false"))
Test("★ key slot custody: throwing compensation retains exact retry duties (todo108-custody)",
	_MET_CohortRetainedCompensationCase.Bind("throw"))
Test("★ key slot custody: malformed compensation retains exact retry duties (todo108-custody)",
	_MET_CohortRetainedCompensationCase.Bind("malformed"))

/** Boot retry cannot change a source epoch before retained owners are settled. */
_MET_CohortBootRetryKeepsSourceEpoch() {
	State := StarSlotState(), Saved := State.Clone()
	try {
		State["initialized"] := false
		State["native_handles"] := Map("SC027", "first-native-token")
		State["ordinary_restore"] := Map("first-personal-token", true)
		State["source_generation"] := 77
		State["hkl"] := 1234
		State["source_signature"] := "first-source-recipe"
		Refused := false
		try StarSlotStart()
		catch as Failure
			Refused := InStr(Failure.Message, "unsettled cohort compensation") > 0
		AssertTrue(Refused, "boot reentry refuses the exact retained compensation owner")
		AssertEqual(77, State["source_generation"], "cleanup debt cannot gain another source epoch")
		AssertEqual(1234, State["hkl"])
		AssertEqual("first-source-recipe", State["source_signature"])
		AssertEqual("first-native-token", State["native_handles"]["SC027"])
		AssertTrue(State["ordinary_restore"].Has("first-personal-token"))
	} finally {
		State.Clear()
		for Key, Value in Saved
			State[Key] := Value
	}
}
Test("★ key slot custody: boot retry preserves the retained source epoch (todo108-custody)",
	_MET_CohortBootRetryKeepsSourceEpoch)

/** Runs the exact production cohort bodies over genuine private AHK variants. */
_MET_CohortRealNativeCustody() {
	Root := A_Temp . "\ergopti_magic_custody_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "native cohort custody requires an exclusive fixture directory")
	DirCreate(Root)
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}, Handle := 0, Settled := false
	Done(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	try {
		Source := '#Requires AutoHotkey v2.0' . "`n" . '#SingleInstance Off' . "`n"
			. '#NoTrayIcon' . "`n" . '#Warn All, StdOut' . "`n" . '#ErrorStdOut' . "`n"
			. '#Include ' . _DriverProductionFileForSymbol("ChordParse") . "`n"
			. '#Include ' . _DriverProductionFileForSymbol("HotkeyRegistrarReservePhysicalBroker") . "`n"
			. 'LoggerDebug(*) => 0' . "`n" . 'LoggerWarn(*) => 0' . "`n" . 'LoggerError(*) => 0' . "`n"
		for Name in ["StarSlotState", "StarSlotAcquireCohort", "StarSlotSettleCohortDebt"] {
			Body := _DriverFuncBody(Name)
			Assert(Body != "", "the native child must execute each actual production cohort body")
			Source .= Body . "`n"
		}
		Source .= _MET_CohortNativeProbeSource()
		Probe := Root . "\native_custody.ahk"
		FileAppend(Source, Probe, "UTF-8")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Probe], Done)
		AssertTrue(Handle.start(), "the exact native cohort probe must start")
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the native cohort child must complete exactly once")
		AssertEqual(0, Receipt.Code, "the genuine registrar/cohort probe must run: " . Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "native cohort errors cannot be hidden")
		AssertEqual("native-retired|personal-restored|retry-fenced", Receipt.Output)
	} finally {
		if Handle is Object
			Settled := Handle.terminate()
		else
			Settled := true
		if Settled
			DirDelete(Root, true)
		AssertTrue(Settled, "the exact native cohort process tree must retire before fixture removal")
	}
}

/** Produces assertions over actual retained registrar capabilities, without input. */
_MET_CohortNativeProbeSource() {
	return '
	(
_MCC_Require(Value, Message) {
	if !Value
		throw Error(Message)
}
_MCC_Run() {
	global HOTKEY_REGISTRAR_BINDINGS
	Criterion := (*) => false
	Ordinary := _HotkeyRegistrarReserveResolvedOwned("Cmd+D", (*) => 0, "custody-personal",
		HotkeyRegistrarResolvedNativeDescriptor("#d"))
	_MCC_Require(Ordinary != "" && _HotkeyRegistrarActivate(Ordinary), "The exact personal owner must acquire.")
	Entry := HOTKEY_REGISTRAR_BINDINGS[Ordinary]
	Handles := Map(), RestoreDebt := Map(), RefuseCleanup := true, Reservations := 0
	Reserve(Scan) {
		Reservations += 1
		return HotkeyRegistrarReservePhysicalBroker("Cmd+" . Scan, (*) => 0, "custody-broker",
			HotkeyRegistrarResolvedNativeDescriptor("#" . Scan), Criterion)
	}
	Activate(Token) {
		_MCC_Require(_HotkeyRegistrarActivate(Token), "The real broker native On must acknowledge.")
		return false
	}
	Retire(Token) => RefuseCleanup ? false : HotkeyRegistrarUnbind(Token)
	SetEnabled(Token, Enabled) => Enabled && RefuseCleanup ? false : HotkeyRegistrarSetEnabled(Token, Enabled)
	Ports := Map("reserve", Reserve, "activate", Activate, "retire", Retire, "set_enabled", SetEnabled)
	try {
		Refused := false
		try StarSlotAcquireCohort(Map("SC020", true), [Ordinary], Handles, Ports, RestoreDebt)
		catch as Failure
			Refused := InStr(Failure.Message, "Unacknowledged compensation") > 0
		_MCC_Require(Refused && Handles.Count == 1 && RestoreDebt.Has(Ordinary), "Both exact obligations must survive refusal.")
		Broker := Handles["SC020"]
		_MCC_Require(HOTKEY_REGISTRAR_BINDINGS[Broker]["state"]["phase"] == "active", "The retained broker must be genuinely native active.")
		_MCC_Require(HOTKEY_REGISTRAR_BINDINGS[Ordinary]["state"]["phase"] == "disabled", "The retained personal owner must be genuinely disabled.")
		try StarSlotAcquireCohort(Map("SC020", true), [], Handles, Ports, RestoreDebt)
		catch as Failure
			_MCC_Require(InStr(Failure.Message, "unsettled cohort compensation"), "Only retained custody may refuse the retry.")
		_MCC_Require(Reservations == 1 && Handles["SC020"] == Broker, "Retry cannot replace the original native token.")
		RefuseCleanup := false
		Result := StarSlotSettleCohortDebt(Handles, RestoreDebt, Ports)
		_MCC_Require(Result["status"] == "settled" && !Handles.Count && !RestoreDebt.Count, "Exact native compensation must settle.")
		_MCC_Require(!HOTKEY_REGISTRAR_BINDINGS.Has(Broker), "Only the exact broker token must retire.")
		_MCC_Require(HOTKEY_REGISTRAR_BINDINGS[Ordinary] == Entry && Entry["state"]["phase"] == "active", "The same personal owner must regain native On.")
	} finally {
		RefuseCleanup := false
		Result := StarSlotSettleCohortDebt(Handles, RestoreDebt, Ports)
		_MCC_Require(Result["status"] == "settled", "Native cleanup debt must settle before exit.")
		_MCC_Require(HotkeyRegistrarUnbind(Ordinary), "The exact restored personal owner must retire.")
	}
	FileAppend("native-retired|personal-restored|retry-fenced", "*", "UTF-8-RAW")
}
try {
	_MCC_Run()
	ExitApp(0)
} catch as CustodyProbeTerminalFailure {
	FileAppend(CustodyProbeTerminalFailure.Message, "**", "UTF-8-RAW")
	ExitApp(2)
}
	)'
}
Test("★ key slot custody: actual native variants retain and settle exact owners (todo108-custody)",
	_MET_CohortRealNativeCustody)
