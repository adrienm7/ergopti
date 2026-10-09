; modules/keymap/keylayout/layout_registry.ahk

; ==============================================================================
; MODULE: Layout Registry (Windows client)
; DESCRIPTION:
; Where the Windows driver finds registry layouts: the shared registry
; settings (_shared/modules/layouts/defaults.json), the shared keycode table
; (_shared/modules/layouts/mac_keycodes.json), the verification of a layout
; against its index entry, the local folder that keeps each installed
; <id>.keylayout (verified against the entry its installation recorded,
; layout_catalogue.ahk), the copy of the registry folder shipped with the
; driver, which the Ergopti emulation reads its layout from, and the one
; request every registry download goes through.
;
; FEATURES & RATIONALE:
; 1. One source for the registry location: the folder, branch, URL template,
;    bounds and local folder come from the shared defaults file, and owner/repo
;    from the updater defaults, like every other driver and the index builder.
; 2. A layout is only ever read after its size and checksum match the index
;    entry it was downloaded with: a truncated or edited file fails loudly
;    instead of emulating something else.
; 3. A download lands under a temporary name; the catalogue publishes it only
;    once the layout matches its index entry.
; 4. The transfer runs in a curl child (CurlAsyncRequest) polled from a timer,
;    so the keyboard thread never waits on the network. Every collaborator is
;    injectable so tests replay a download without a network.
; 5. The physical magic key follows one order: the user's configured key, the
;    key the active layout's extension declares, then — with no layout
;    emulated — the key typing the source character on the OS layout.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; A registry id is also a file name: a lowercase letter, then lowercase letters,
; digits and underscores, the rule tools/build/build-layouts-index.cjs enforces
; on the registry folder (tools/test/test-layouts-defaults-single-source.cjs
; pins this copy to it).
global LAYOUT_REGISTRY_ID_PATTERN := "^[a-z][a-z0-9_]*$"

; Suffix of a file being downloaded; it is renamed only once verified.
global LAYOUT_REGISTRY_PARTIAL_SUFFIX := ".download"

; User agent of every registry request: the one of the shared Lua client
; (_shared/lua/layouts/registry.lua), pinned by test-layouts-defaults-single-source.cjs.
global LAYOUT_REGISTRY_USER_AGENT := "ErgoptiPlus-Layouts/1.0"

; How often a running download is polled. Short enough that a layout is ready a
; tenth of a second after curl exits, long enough to cost nothing while it runs.
global LAYOUT_REGISTRY_POLL_MS := 100

; Extra polls allowed past the transfer budget before a download that curl
; never reported finished is abandoned (curl enforces the budget itself).
global LAYOUT_REGISTRY_POLL_GRACE := 20





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

; Parsed shared files, loaded on first use (they never change while running).
global _LayoutRegistryDefaults := 0
global _LayoutRegistryKeycodes := 0
global _LayoutRegistryGithub := 0





; ===========================
; ===========================
; ======= 3/ Settings =======
; ===========================
; ===========================

_LayoutRegistryReadJson(RelativePath) {
	global _SharedDir
	Path := _SharedDir . "\" . RelativePath
	if !FileExist(Path)
		throw Error("Required shared file is missing: " . Path)
	return JsonParse(FSReadStrict(Path))
}

/**
 * The [registry] table of _shared/modules/layouts/defaults.json.
 * @returns {Map}
 */
LayoutRegistry_Settings() {
	global _LayoutRegistryDefaults
	if !IsObject(_LayoutRegistryDefaults)
		_LayoutRegistryDefaults := _LayoutRegistryReadJson("modules\layouts\defaults.json")["registry"]
	return _LayoutRegistryDefaults
}

/**
 * The shared physical-key table every consumer converts a .keylayout with.
 * @returns {Map} Parsed mac_keycodes.json.
 */
LayoutRegistry_Keycodes() {
	global _LayoutRegistryKeycodes
	if !IsObject(_LayoutRegistryKeycodes)
		_LayoutRegistryKeycodes := _LayoutRegistryReadJson("modules\layouts\mac_keycodes.json")
	return _LayoutRegistryKeycodes
}

/**
 * Whether ``Id`` can name a registry layout (and therefore a local file).
 * @param {string} Id - Candidate id.
 * @returns {boolean}
 */
LayoutRegistry_IsValidId(Id) {
	global LAYOUT_REGISTRY_ID_PATTERN
	return (Id is String) && RegExMatch(Id, LAYOUT_REGISTRY_ID_PATTERN) > 0
}

/**
 * Download URL of a file of the registry folder.
 * @param {string} RelativePath - Path inside the registry ("index.json", "ergol/ergol.keylayout").
 * @returns {string}
 */
LayoutRegistry_RawUrl(RelativePath) {
	global _LayoutRegistryGithub
	if !IsObject(_LayoutRegistryGithub)
		_LayoutRegistryGithub := _LayoutRegistryReadJson("modules\updater\defaults.json")["github"]
	Settings := LayoutRegistry_Settings()
	Url := Settings["raw_url_template"]
	for Name, Value in Map("owner", _LayoutRegistryGithub["owner"], "repo", _LayoutRegistryGithub["repo"],
		"branch", _Updater_InstalledChannel(), "folder", Settings["folder"], "path", RelativePath)
		Url := StrReplace(Url, "{" . Name . "}", Value)
	return Url
}

/**
 * Folder holding the downloaded layouts, inside the configuration folder.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {string} Folder path with a trailing backslash.
 */
LayoutRegistry_LocalDir(ConfigDir) {
	return ConfigDir . LayoutRegistry_Settings()["local_folder"] . "\"
}

/**
 * Registry folder shipped with the driver: the repository folder in a source
 * checkout, and its copy under the same path in the extracted bundle of the
 * compiled driver (tools/build/build_static_bundle.py). _StaticDir is the
 * "static" folder of either tree, so the folder resolves from its parent.
 * @returns {string} Folder path with a trailing backslash.
 */
LayoutRegistry_BundledDir() {
	global _StaticDir
	return _StaticDir . "\..\" . StrReplace(LayoutRegistry_Settings()["folder"], "/", "\") . "\"
}





; ================================
; ================================
; ======= 4/ Local layouts =======
; ================================
; ================================

/**
 * Entry of ``Id`` in a parsed registry index.
 * @param {Map} Index - Parsed index.json.
 * @param {string} Id - Registry id.
 * @returns {Map}
 * @throws {Error} When the index does not list the layout.
 */
LayoutRegistry_FindEntry(Index, Id) {
	if !(Index is Map) || !Index.Has("layouts") || !(Index["layouts"] is Array)
		throw Error("The registry index has no layouts list.")
	for Entry in Index["layouts"] {
		if (Entry is Map) && Entry.Has("id") && (Entry["id"] == Id)
			return Entry
	}
	throw Error("The layout '" . Id . "' is not in the registry index.")
}

/**
 * Throws unless ``Text`` is exactly the file the index entry describes.
 * @param {Map} Entry - Registry index entry.
 * @param {string} Text - .keylayout content, read as UTF-8 without conversion.
 */
LayoutRegistry_Verify(Entry, Text) {
	Size := StrPut(Text, "UTF-8") - 1
	if (Size != Entry["size"])
		throw Error(Format("The layout '{1}' has {2} bytes instead of {3}.", Entry["id"], Size, Entry["size"]))
	Digest := CryptoSha256(Text)
	if (Digest != Entry["sha256"])
		throw Error(Format("The layout '{1}' does not match its registry checksum.", Entry["id"]))
}

_LayoutRegistryReadText(Path) {
	Text := FSReadBounded(Path, LayoutRegistry_Settings()["max_file_bytes"])
	if !(Text is String)
		throw Error("Cannot read " . Path . " (missing, unreadable or larger than the download bound).")
	return Text
}

/**
 * Reads an installed layout and verifies it against the entry its installation
 * recorded (installed.json, layout_catalogue.ahk), so a catalogue refreshed
 * since never invalidates it.
 * @param {string} Id - Registry id.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @returns {Map} Text (the .keylayout) and Entry (its recorded entry).
 * @throws {Error} When the layout is not installed or fails verification.
 */
LayoutRegistry_ReadLocal(Id, LocalDir) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	Installed := LayoutCatalogue_ReadInstalled(LocalDir)
	if !Installed.Has(Id)
		throw Error("The layout '" . Id . "' is not installed in " . LocalDir)
	LayoutPath := LocalDir . Id . ".keylayout"
	if !FileExist(LayoutPath)
		throw Error("The installed '" . Id . "' layout is missing from " . LocalDir)
	Entry := Installed[Id]
	Text := _LayoutRegistryReadText(LayoutPath)
	LayoutRegistry_Verify(Entry, Text)
	return Map("Text", Text, "Entry", Entry)
}

/**
 * Reads a layout shipped with the driver and verifies it against the shipped
 * index, like a downloaded one: a damaged installation fails here instead of
 * emulating something else.
 * @param {string} Id - Registry id.
 * @param {string} RegistryDir - Folder from LayoutRegistry_BundledDir.
 * @returns {Map} Text (the .keylayout) and Entry (its index entry).
 * @throws {Error} When the layout is missing, misplaced or fails verification.
 */
LayoutRegistry_ReadBundled(Id, RegistryDir) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	Index := JsonParse(_LayoutRegistryReadText(RegistryDir . LayoutRegistry_Settings()["index_file"]))
	Entry := LayoutRegistry_FindEntry(Index, Id)
	; The index builder always files a layout as <id>/<id>.keylayout; anything
	; else would read outside the layout's own folder.
	if (Entry["file"] !== Id . "/" . Id . ".keylayout")
		throw Error("The registry index files the layout '" . Id . "' at an unexpected path: " . Entry["file"])
	Text := _LayoutRegistryReadText(RegistryDir . StrReplace(Entry["file"], "/", "\"))
	LayoutRegistry_Verify(Entry, Text)
	return Map("Text", Text, "Entry", Entry)
}





; ===========================
; ===========================
; ======= 5/ Download =======
; ===========================
; ===========================

_LayoutRegistryDefaultTransport() {
	return Map(
		"request", () => CurlAsyncRequest(),
		"managed", true,
		"schedule", (Fn, DelayMs) => SetTimer(Fn, -DelayMs)
	)
}

/**
 * Downloads one URL of the registry into ``Partial`` in a curl child polled
 * from a timer, never on the keyboard thread, and calls
 * OnSettled(Status, Etag, Error) exactly once: Status 0 when no HTTP response
 * arrived, Error then saying why; Etag is the response's, "" when none.
 * @param {string} Url
 * @param {string} Partial - Output file; a stale one is removed first.
 * @param {Map} Headers - Request headers.
 * @param {Integer} TimeoutMs - Budget of the whole transfer, connection included.
 * @param {Map} Transport - "request" (a CurlAsyncRequest-like object),
 *   "resolve_proxy" (SystemProxy_ResolveAsync) and "schedule" (Fn, DelayMs);
 *   the curl transport when 0.
 * @param {Func} OnSettled
 */
LayoutRegistry_Request(Url, Partial, Headers, TimeoutMs, Transport, OnSettled) {
	Started := A_TickCount
	if !(Transport is Map)
		Transport := _LayoutRegistryDefaultTransport()
	Job := { Url: Url, Partial: Partial, Headers: Headers, TimeoutMs: TimeoutMs, Transport: Transport,
		OnSettled: OnSettled, Settled: false, Started: Started, Request: 0 }
	LoggerDebug("LayoutRegistry", "Fetching {1}", Url)
	if Transport.Get("managed", false)
		_LayoutRegistrySend(Job)
	else
		Transport["resolve_proxy"].Call([Url], (Resolved) => _LayoutRegistrySend(Job, Resolved[Url]))
	return Job
}

_LayoutRegistrySettle(Job, Status, Etag, Err) {
	if Job.Settled
		return
	Job.Settled := true
	Job.Request := 0
	Job.OnSettled.Call(Status, Etag, Err)
}

_LayoutRegistrySend(Job, Proxy := unset) {
	if Job.Settled
		return
	try {
		if !FSDelete(Job.Partial)
			throw Error("Cannot remove the stale partial download " . Job.Partial)
		Req := Job.Transport["request"].Call()
		Job.Request := Req
		if Job.Transport.Get("managed", false) {
			Req.SetManagedRouting(0, () => !Job.Settled && Job.Request == Req)
			Req.SetDeadline(Job.Started, Job.TimeoutMs)
		}
		Req.Open("GET", Job.Url, true)
		for Name, Value in Job.Headers
			Req.SetRequestHeader(Name, Value)
		if IsSet(Proxy)
			Req.SetProxy(Proxy)
		; One budget for the whole transfer, connection included.
		Req.SetTimeouts(0, Job.TimeoutMs, 0, 0)
		Req.SetOutputFile(Job.Partial)
		if !Req.Send()
			throw Error("The managed registry request refused dispatch.")
	} catch as Err {
		if IsObject(Job.Request)
			Job.Request.Abort()
		_LayoutRegistrySettle(Job, 0, "", "cannot download " . Job.Url . ": " . Err.Message)
		return
	}
	_LayoutRegistryPoll(Job, Req, 0)
}

_LayoutRegistryPoll(Job, Req, Polls) {
	if Job.Settled {
		Req.Abort()
		return
	}
	global LAYOUT_REGISTRY_POLL_MS, LAYOUT_REGISTRY_POLL_GRACE
	try {
		Ready := Req.WaitForResponse(0)
	} catch as Err {
		try Req.Abort()
		_LayoutRegistrySettle(Job, 0, "", "download of " . Job.Url . " failed: " . Err.Message)
		return
	}
	if !Ready {
		if (Polls > Ceil(Job.TimeoutMs / LAYOUT_REGISTRY_POLL_MS) + LAYOUT_REGISTRY_POLL_GRACE) {
			try Req.Abort()
			_LayoutRegistrySettle(Job, 0, "", "download of " . Job.Url . " did not finish in time")
			return
		}
		Job.Transport["schedule"].Call(_LayoutRegistryPoll.Bind(Job, Req, Polls + 1), LAYOUT_REGISTRY_POLL_MS)
		return
	}
	Status := Req.Status
	_LayoutRegistrySettle(Job, Status, (Status == 0) ? "" : Req.GetResponseHeader("ETag"),
		(Status == 0) ? "no HTTP response for " . Job.Url . " (network, proxy or timeout)" : "")
}





; ============================
; ============================
; ======= 6/ Magic key =======
; ============================
; ============================

/**
 * The AutoHotkey scan code of a key registry layouts define.
 * @param {String} Code - W3C KeyboardEvent.code.
 * @param {Map} KeycodeTable - Parsed _shared/modules/layouts/mac_keycodes.json.
 * @returns {String} "SCnnn".
 * @throws {ValueError} When no layout key has that code.
 */
LayoutRegistry_KeyScan(Code, KeycodeTable) {
	for Key in KeycodeTable["keys"] {
		if Key["code"] == Code
			return Key["ahk"]
	}
	throw ValueError("No registry layout key has the code '" . Code . "'.")
}

/**
 * The physical magic key the active layout's extension declares.
 * The discovered packs win, as they do for its hotstrings: an installed
 * generation or the user's own copy. A layout nobody installed, such as the
 * built-in Ergopti emulation, is read from the registry the driver ships.
 * @param {String} ExtensionId - Extension of the active layout, "" for none.
 * @param {Array} Packs - Discovered extension packs.
 * @param {String} BundledDir - Shipped registry folder, with its trailing backslash.
 * @returns {String} KeyboardEvent.code, or "" when the layout declares none.
 */
LayoutRegistry_DeclaredMagicKey(ExtensionId, Packs, BundledDir) {
	if ExtensionId == ""
		return ""
	for Pack in Packs {
		if Pack.id == ExtensionId
			return Pack.magic_key
	}
	Path := BundledDir . ExtensionId . "\manifest.toml"
	if !FileExist(Path)
		throw Error("The '" . ExtensionId . "' layout extension ships no manifest: " . Path)
	Manifest := ParseTomlFile(Path)
	if TOML_UnreadableFile(Path)
		throw Error("The '" . ExtensionId . "' layout extension manifest cannot be read: " . Path)
	return HotstringExtensions_MagicKey(Manifest)
}

/**
 * The extension of the layout that types, whose declaration names the magic key.
 * The emulation types only while its base layer (ErgoptiBase) is on: then a
 * selected registry layout is the one it installed and, with none selected,
 * the built-in Ergopti layout. With the base layer off the user types on their
 * own OS layout, which declares nothing, whatever layout stays selected. A
 * damaged installed record is logged and declares nothing: the emulation
 * reports the same record on its own boot path.
 * @param {String} SelectedId - Selected registry layout id, "" for none.
 * @param {Boolean} ErgoptiBase - Whether the emulation's base layer is on.
 * @param {String} ErgoptiId - Registry id of the built-in Ergopti layout.
 * @param {Func} ReadInstalled - Returns the installed-layouts record.
 * @returns {String} Extension id, or "" when no layout extension types.
 */
LayoutRegistry_ActiveLayoutExtension(SelectedId, ErgoptiBase, ErgoptiId, ReadInstalled) {
	if !ErgoptiBase
		return ""
	if SelectedId == ""
		return ErgoptiId
	try {
		Installed := ReadInstalled.Call()
	} catch as Err {
		LoggerError("LayoutRegistry", "The magic key of the '{1}' layout is unknown: {2}", SelectedId, Err.Message)
		return ""
	}
	if !Installed.Has(SelectedId) || !Installed[SelectedId].Has("extension")
		return ""
	return Installed[SelectedId]["extension"]["id"]
}

/**
 * The scan code of the key that types a character on the OS layout, probed with
 * no modifier through ToUnicodeEx (adapters/key_state.ahk). VkKeyScanExW is not
 * used: it fails on layouts such as bépo where the character sits behind a
 * driver-level remapping the API cannot see.
 * @param {Integer} Hkl - Keyboard layout handle, 0 when none could be read.
 * @param {String} Char - Source character.
 * @param {Func} ScanFn - KS_ScanScancodeForChar implementation.
 * @returns {String} "SCnnn", or "" when the layout or the character is not found.
 */
LayoutRegistry_DetectMagicKeyScan(Hkl, Char, ScanFn := KS_ScanScancodeForChar) {
	if Hkl == 0 {
		LoggerWarn("LayoutRegistry", "Magic-key source detection skipped: no keyboard layout could be read.")
		return ""
	}
	Found := ScanFn.Call(Hkl, Char)
	if Found["scan"] == 0 {
		LoggerWarn("LayoutRegistry", "Magic-key source: '{1}' is on no base key of layout HKL=0x{2:X}.", Char, Hkl)
		return ""
	}
	Scan := Format("SC{:03X}", Found["scan"])
	LoggerInfo("LayoutRegistry", "Magic-key source detected on the OS layout: '{1}' at {2} (VK=0x{3:X}, HKL=0x{4:X}).",
		Char, Scan, Found["vk"], Hkl)
	return Scan
}

/**
 * The physical magic key the built-in Ergopti layout declares, read from the
 * registry the driver ships rather than from a discovered pack, so a user's own
 * copy of the extension cannot take the last-resort key away.
 * @returns {String} KeyboardEvent.code.
 * @throws {Error} When the shipped manifest declares no magic key.
 */
LayoutRegistry_ShippedMagicKey() {
	global ERGOPTI_LAYOUT_ID
	Code := LayoutRegistry_DeclaredMagicKey(ERGOPTI_LAYOUT_ID, [], LayoutRegistry_BundledDir())
	if Code == ""
		throw Error("The shipped '" . ERGOPTI_LAYOUT_ID . "' layout extension declares no magic key.")
	return Code
}

/**
 * Chooses the physical key that types the magic key. The key the user
 * configured always wins; then the key the active layout declares; then, with
 * no layout emulated, the key that types the source character on the OS
 * layout; then the key the shipped Ergopti layout declares. A detection never
 * replaces a choice, and an emulated layout is never probed through the OS
 * layout it replaces.
 * @param {Map} Inputs - "chosen" (whether the user configured a key),
 *   "configured" (that KeyboardEvent.code, from [hotstrings] magic_key_source),
 *   "declared" (KeyboardEvent.code or ""), "emulated" (whether a layout is
 *   emulated), "keycodes" (parsed mac_keycodes.json), "detect" (callable
 *   returning the scan code probed on the OS layout, or "") and "shipped"
 *   (callable returning the KeyboardEvent.code of the last resort).
 * @returns {Map} "scan", "origin" (user, layout, detected or default),
 *   "follows_os_layout", whether an OS layout switch can move the key, and
 *   "overrides_emulation", whether an emulated layout yields that key's
 *   unshifted level to the magic key: only for a key the user chose or the
 *   active layout declares. An emulated layout that declares none (Ergo-L)
 *   keeps its own character there, the magic key being an Ergopti feature.
 */
LayoutRegistry_MagicKeySource(Inputs) {
	if Inputs["chosen"]
		return Map("scan", LayoutRegistry_KeyScan(Inputs["configured"], Inputs["keycodes"]),
			"origin", "user", "follows_os_layout", false, "overrides_emulation", true)
	if Inputs["declared"] != ""
		return Map("scan", LayoutRegistry_KeyScan(Inputs["declared"], Inputs["keycodes"]),
			"origin", "layout", "follows_os_layout", false, "overrides_emulation", true)
	if Inputs["emulated"]
		return Map("scan", LayoutRegistry_KeyScan(Inputs["shipped"].Call(), Inputs["keycodes"]),
			"origin", "default", "follows_os_layout", false, "overrides_emulation", false)
	Detected := Inputs["detect"].Call()
	if Detected != ""
		return Map("scan", Detected, "origin", "detected", "follows_os_layout", true,
			"overrides_emulation", false)
	return Map("scan", LayoutRegistry_KeyScan(Inputs["shipped"].Call(), Inputs["keycodes"]),
		"origin", "default", "follows_os_layout", true, "overrides_emulation", false)
}

/**
 * The hotkeys that make the physical magic key type the magic key
 * (modules/keymap/layout.ahk registers them). The key a layout declares,
 * detected or shipped, is the layout's own magic-key position: its other levels
 * follow the source character (Shift types its capital, Ctrl and Alt its
 * shortcuts), and Ctrl+★ may save. Editor shortcuts belong to the ordinary
 * user-owned keyboard slots, never the physical magic-key owner. A key the
 * user chose is a key of the layout they type on: only its plain press becomes
 * the magic key, and every level and chord stays the layout's, as on macOS and
 * Linux (_shared/lua/keymap/magic_key_source.lua).
 * @param {String} Scan - "SCnnn" of the physical magic key.
 * @param {Boolean} Chosen - Whether the user chose it ([hotstrings] magic_key_source).
 * @param {Boolean} CtrlSave - Whether [layout] ctrl_magic_save is on.
 * @returns {Array} Maps of "kind" ("remap": every level through RemapKey,
 *   "magic": the plain press alone, "ctrl_save": Ctrl+S) and "hotkey".
 */
LayoutRegistry_MagicKeyHotkeys(Scan, Chosen, CtrlSave) {
	if Chosen
		return [Map("kind", "magic", "hotkey", Scan)]
	Hotkeys := [Map("kind", "remap", "hotkey", Scan)]
	if CtrlSave
		Hotkeys.Push(Map("kind", "ctrl_save", "hotkey", "^" . Scan))
	return Hotkeys
}

/**
 * The KeyboardEvent.code of a scan code, among the keys registry layouts define:
 * the reverse of LayoutRegistry_KeyScan, for a key the user just pressed.
 * @param {String} Scan - "SCnnn", any case.
 * @param {Map} KeycodeTable - Parsed _shared/modules/layouts/mac_keycodes.json.
 * @returns {String} The code, or "" when no layout key has that scan code.
 */
LayoutRegistry_KeyCode(Scan, KeycodeTable) {
	for Key in KeycodeTable["keys"] {
		if (Key["ahk"] = Scan)
			return Key["code"]
	}
	return ""
}
