; modules/keymap/keylayout/game_keys.ahk

; ==============================================================================
; MODULE: Game Keys
; DESCRIPTION:
; « Touches de jeu » (maintainer decision of 2026-11-26): which key identity a
; game reads while Ergopti types, the character staying Ergopti's. "physical"
; keeps the physical key's scan code, "letters" sends the key of the system
; layout that types the Ergopti character. The Windows twin of
; _shared/layouts/engine/emulation/game_keys.lua: both replay
; _shared/tests/corpus/layouts/game_keys_vectors.json.
;
; FEATURES & RATIONALE:
; 1. One source for the settings: layout.game_keys and layout.game_keys_apps
;    (executable name to choice, case ignored). A listed executable is a
;    game: its held keys skip the tap-hold delays (GameKeys_IsGame).
; 2. One route table per OS, Ergopti mode and choice (GameKeys_Route), with
;    the reason key when a choice cannot be honoured.
; 3. One rule for the held key (GameKeys_HeldAdmissible): one character the
;    system layout types with exactly the modifiers the hand holds goes out
;    held; any other keeps the text route.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk
#Include %A_LineFile%\..\..\..\..\_generated\game_keys_names.ahk





; ======================================
; ======================================
; ======= 1/ Settings and routes =======
; ======================================
; ======================================

; The choices, modes, strategies and reason keys are GameKeysName
; (_generated/game_keys_names.ahk, from _shared/layouts/data/game_keys.json),
; the names _shared/layouts/engine/emulation/game_keys.lua reads.

/**
 * The choices, in the manifest's order: its enum is the one source.
 * @returns {Array}
 */
GameKeys_Choices() {
	static Cached := 0
	if IsObject(Cached)
		return Cached
	Entry := ManifestFindEntryByPath(ConfigKey.LAYOUT_GAME_KEYS)
	if !(Entry is Map) || !Entry.Has("enum_values") || !(Entry["enum_values"] is Array) || !Entry["enum_values"].Length
		throw Error("The manifest declares no layout.game_keys choices.")
	Cached := Entry["enum_values"]
	return Cached
}

/**
 * Whether a value is one of the choices.
 * @param {Any} Value
 * @returns {Boolean}
 */
GameKeys_ValidChoice(Value) {
	if !(Value is String)
		return false
	for Choice in GameKeys_Choices()
		if Value == Choice
			return true
	return false
}

/**
 * Whether a value is a map of application identities to choices.
 * @param {Any} Value
 * @returns {Boolean}
 */
GameKeys_ValidApps(Value) {
	if !(Value is Map)
		return false
	for App, Choice in Value
		if !(App is String) || App == "" || !GameKeys_ValidChoice(Choice)
			return false
	return true
}

/**
 * The key an application identity is stored under on its OS: an executable
 * and a Linux WM class ignore case, a macOS bundle identifier is exact.
 * @param {String} Platform "windows", "macos" or "linux".
 * @param {Any} App
 * @returns {String} "" for no identity.
 */
GameKeys_AppKey(Platform, App) {
	if !(Platform == "windows" || Platform == "macos" || Platform == "linux")
		throw ValueError("Unknown platform for the game keys: " . Platform)
	if !(App is String)
		return ""
	Trimmed := Trim(App, " `t`r`n")
	return Platform == "macos" ? Trimmed : StrLower(Trimmed)
}

/**
 * The game-key settings of a Features map. A value in another shape is
 * outdated configuration: it reads as its default, reported once.
 * @param {Map} FeaturesSource Feature preferences.
 * @returns {Map} "choice" and "apps" (a new Map).
 */
GameKeys_Resolve(FeaturesSource) {
	static Reported := Map()
	Layout := FeaturesSource.Has("layout") && FeaturesSource["layout"] is Map ? FeaturesSource["layout"] : Map()
	Choice := Layout.Get(ConfigLeaf.GAME_KEYS, ManifestDefaultFor(ConfigKey.LAYOUT_GAME_KEYS))
	if Choice is String {
		for Allowed in GameKeys_Choices()
			if StrCompare(Choice, Allowed, false) == 0
				Choice := Allowed
	}
	if !GameKeys_ValidChoice(Choice) {
		if !Reported.Has("choice") {
			Reported["choice"] := true
			try LoggerWarn("Layout", "layout.game_keys is not physical or letters — read as its default.")
		}
		Choice := ManifestDefaultFor(ConfigKey.LAYOUT_GAME_KEYS)
	}
	Apps := Layout.Get(ConfigLeaf.GAME_KEYS_APPS, Map())
	if !GameKeys_ValidApps(Apps) {
		if !Reported.Has("apps") {
			Reported["apps"] := true
			try LoggerWarn("Layout", "layout.game_keys_apps is not a table of applications to physical or letters — read as none.")
		}
		Apps := Map()
	}
	Copy := Map()
	for App, Value in Apps
		Copy[App] := Value
	return Map("choice", Choice, "apps", Copy)
}

; The stored key of an application, whatever case it was written in on an OS
; whose identities ignore case; "" when it has none.
_GameKeys_StoredKey(Settings, Platform, Key) {
	if Settings["apps"].Has(Key)
		return Key
	if Platform == "macos"
		return ""
	for App in Settings["apps"]
		if StrLower(App) == Key
			return App
	return ""
}

/**
 * The choice in force for an application.
 * @param {Map} Settings GameKeys_Resolve's result.
 * @param {String} Platform
 * @param {Any} App The application's identity.
 * @returns {Map} "choice" and "overridden".
 */
GameKeys_ChoiceFor(Settings, Platform, App) {
	Key := GameKeys_AppKey(Platform, App)
	if Key != "" {
		Stored := _GameKeys_StoredKey(Settings, Platform, Key)
		if Stored != ""
			return Map("choice", Settings["apps"][Stored], "overridden", true)
	}
	return Map("choice", Settings["choice"], "overridden", false)
}

/**
 * Whether an application is a game: it has its own choice.
 * @param {Map} Settings
 * @param {String} Platform
 * @param {Any} App
 * @returns {Boolean}
 */
GameKeys_IsGame(Settings, Platform, App) {
	return GameKeys_ChoiceFor(Settings, Platform, App)["overridden"]
}

/**
 * The application table after an application's choice changes.
 * @param {Map} Settings
 * @param {String} Platform
 * @param {String} App
 * @param {String} Choice Its own choice; "" to follow the global choice again.
 * @returns {Map} A new table.
 */
GameKeys_AppsWith(Settings, Platform, App, Choice) {
	Key := GameKeys_AppKey(Platform, App)
	if Key == ""
		throw ValueError("An application identity is required to set its game keys.")
	if Choice != "" && !GameKeys_ValidChoice(Choice)
		throw ValueError("Not a game-key choice: " . Choice)
	Stored := _GameKeys_StoredKey(Settings, Platform, Key)
	Apps := Map()
	for Name, Value in Settings["apps"]
		if Name !== Stored
			Apps[Name] := Value
	if Choice != ""
		Apps[Key] := Choice
	return Apps
}

; One route row.
_GameKeys_RouteRow(Available, Identity, Strategy, ReasonKey := "", NoteKey := "") {
	return Map("available", Available, "identity", Identity, "strategy", Strategy,
		"reason_key", ReasonKey, "note_key", NoteKey)
}

/**
 * How a driver honours a choice, as the shared route table says.
 * @param {String} Platform "windows", "macos" or "linux".
 * @param {String} Mode "emulation", "installed" or "system".
 * @param {String} Choice "physical" or "letters".
 * @param {Map} Caps "installed_layout" (a listed system layout types what the emulation
 *   types) and "game" (the application has its own choice) booleans, absent false.
 * @returns {Map} available, identity, strategy, reason_key ("" for none) and note_key.
 */
GameKeys_Route(Platform, Mode, Choice, Caps) {
	if !(Platform == "windows" || Platform == "macos" || Platform == "linux")
		throw ValueError("Unknown platform for the game keys: " . Platform)
	if !GameKeys_ValidChoice(Choice)
		throw ValueError("Not a game-key choice: " . Choice)
	if !(Caps is Map)
		Caps := Map()
	if Mode == GameKeysName.Mode.SYSTEM
		return _GameKeys_RouteRow(true, GameKeysName.Choice.PHYSICAL, GameKeysName.Strategy.NATIVE)
	if Mode != GameKeysName.Mode.EMULATION && Mode != GameKeysName.Mode.INSTALLED
		throw ValueError("Unknown Ergopti mode: " . Mode)
	VkNote := Platform == "windows" ? GameKeysName.Reason.VK_GAMES_FOLLOW_LETTERS : ""
	if Platform == "macos" {
		if Choice == GameKeysName.Choice.LETTERS
			return _GameKeys_RouteRow(true, GameKeysName.Choice.LETTERS, GameKeysName.Strategy.REWRITE_KEYCODE, "",
				GameKeysName.Reason.HID_GAMES_ARE_PHYSICAL)
		return _GameKeys_RouteRow(true, GameKeysName.Choice.PHYSICAL, GameKeysName.Strategy.NATIVE)
	}
	if Mode == GameKeysName.Mode.INSTALLED {
		if Choice == GameKeysName.Choice.PHYSICAL
			return _GameKeys_RouteRow(true, GameKeysName.Choice.PHYSICAL, GameKeysName.Strategy.NATIVE, "", VkNote)
		return _GameKeys_RouteRow(false, GameKeysName.Choice.PHYSICAL, GameKeysName.Strategy.NATIVE,
			GameKeysName.Reason.LETTERS_NEEDS_BASE_LAYOUT)
	}
	if Choice == GameKeysName.Choice.LETTERS
		return _GameKeys_RouteRow(true, GameKeysName.Choice.LETTERS, GameKeysName.Strategy.HELD_BASE_KEY)
	; A game switches its window to the installed layout: same text, keys at
	; their place, nothing injected.
	if Caps.Get("installed_layout", false) && Caps.Get("game", false)
		return _GameKeys_RouteRow(true, GameKeysName.Choice.PHYSICAL, GameKeysName.Strategy.SWITCH_TO_INSTALLED, "", VkNote)
	if Platform == "windows"
		return _GameKeys_RouteRow(true, GameKeysName.Choice.PHYSICAL, GameKeysName.Strategy.SPLIT_EVENT, "", VkNote)
	if Caps.Get("installed_layout", false)
		return _GameKeys_RouteRow(true, GameKeysName.Choice.LETTERS, GameKeysName.Strategy.HELD_BASE_KEY)
	return _GameKeys_RouteRow(false, GameKeysName.Choice.LETTERS, GameKeysName.Strategy.HELD_BASE_KEY,
		GameKeysName.Reason.PHYSICAL_NEEDS_INSTALLED_LAYOUT)
}

/**
 * Whether an emulated text goes out as a held key: one character the system
 * layout types with exactly the level modifiers the hand holds, Caps Lock off
 * and no modifier a tap-hold holds on the hand's behalf.
 * @param {String} Text The emulated text of the press.
 * @param {Map|Integer} Step The system layout's keystroke, Map("mods", ["shift"?, "altgr"?]);
 *   0 when the layout cannot type it.
 * @param {Map} Held "shift", "altgr", "caps_lock", "virtual" booleans (absent false).
 * @returns {Boolean}
 */
GameKeys_HeldAdmissible(Text, Step, Held) {
	if !(Text is String) || Text == "" || !(Step is Map) || !Step.Has("mods") || !(Step["mods"] is Array)
		return false
	; One character: a surrogate pair is one, a dead key's leftover plus a character is two.
	if StrLen(Text) > 2 || (StrLen(Text) == 2 && !(Ord(Text) >= 0x10000))
		return false
	if !(Held is Map)
		Held := Map()
	if Held.Get("caps_lock", false) || Held.Get("virtual", false)
		return false
	Wants := Map("shift", false, "altgr", false)
	for Level in Step["mods"] {
		if !Wants.Has(Level)
			return false
		Wants[Level] := true
	}
	return Wants["shift"] == (Held.Get("shift", false) ? true : false)
		&& Wants["altgr"] == (Held.Get("altgr", false) ? true : false)
}





; ============================
; ============================
; ======= 2/ Held keys =======
; ============================
; ============================

; The keys the emulation holds for the user, by physical scan code name
; ("SC012"): Map("keys", "vk45" or "vk45sc020", "char", "e"). Each down sent
; here gets its up from the physical key's release (GameKeys_Release), a
; suspend or a reload (GameKeys_ReleaseAll): no key is left held.
global _GK_Held := Map()
; The scan code names whose release hotkey is registered (GameKeys_RegisterReleases).
global _GK_ReleaseScans := Map()
; The foreground window the last decision read, and the executable it runs.
global _GK_Foreground := Map("hwnd", -1, "app", "")
; The Ergopti system layout this driver switched a game window to, and the
; layout to give back when that window leaves the foreground.
global _GK_Switched := Map("active", false, "previous", "")
; The foreground window GameKeys_PassThrough last decided, and its answer.
global _GK_Pass := Map("hwnd", -1, "passing", false)
; The foreground window GameKeys_ForegroundIsGame last decided, its answer,
; and the settings it decides by (GameKeys_Invalidate publishes them; 0 until
; then): a tap-hold #HotIf criterion asks it, so it reads no manifest itself.
global _GK_Game := Map("hwnd", -1, "game", false, "settings", 0)
; The KLID of the installed Ergopti layout, read again when the foreground
; window changes (GameKeys_PassThrough), so a keystroke reads no registry.
global _GK_InstalledKlid := ""

; Keys whose release must never be a hotkey: Backspace, Tab, Enter, Left Ctrl
; and Left Shift, which the hand's own state and the hotstrings read.
global GAME_KEYS_RELEASE_EXCLUDED := Map(0x0E, true, 0x0F, true, 0x1C, true, 0x1D, true, 0x2A, true)

/**
 * The send primitive: SendEvent, or the recorder a test harness installs in
 * _SendHook (as the number row and the hotstring engine use it).
 * @param {String} Keys The SendEvent argument.
 */
_GameKeys_Send(Keys) {
	global _SendHook
	if IsSet(_SendHook) && _SendHook {
		Hook := _SendHook
		Hook.Call("SendEvent", Keys)
		return
	}
	SendEvent(Keys)
}

/**
 * The executable in front, lower case: read again only when the foreground
 * window changes, so a keystroke costs one foreground-window read. Both reads
 * go through the window_info adapter.
 * @returns {String} "" when it cannot be read, or before this module's
 *   globals exist (a key pressed while the boot pumps messages).
 */
GameKeys_ForegroundApp() {
	global _GK_Foreground
	if !IsSet(_GK_Foreground)
		return ""
	Hwnd := WIGetForegroundHwnd()
	if Hwnd == _GK_Foreground["hwnd"]
		return _GK_Foreground["app"]
	App := Hwnd ? StrLower(WIGetProcessName(Hwnd)) : ""
	if Hwnd && App == ""
		try LoggerDebug("Layout", "The foreground executable is unreadable: it follows the global game keys.")
	_GK_Foreground["hwnd"] := Hwnd, _GK_Foreground["app"] := App
	return App
}

/**
 * Whether the application in front is a game: it has its own choice. Read on
 * every tap-hold criterion, parse-time #HotIf included, so the answer is kept
 * per foreground window and decided by the settings GameKeys_Invalidate
 * published: no manifest read here. Before this module's globals exist or its
 * settings are published (a key pressed while the boot pumps messages), no
 * application is a game yet.
 * @returns {Boolean}
 */
GameKeys_ForegroundIsGame() {
	global _GK_Game
	if !IsSet(_GK_Game)
		return false
	Hwnd := WIGetForegroundHwnd()
	if Hwnd == _GK_Game["hwnd"]
		return _GK_Game["game"]
	if !(_GK_Game["settings"] is Map)
		return false
	Game := GameKeys_IsGame(_GK_Game["settings"], "windows", GameKeys_ForegroundApp())
	_GK_Game["hwnd"] := Hwnd, _GK_Game["game"] := Game
	return Game
}

/**
 * The Ergopti system layout's KLID when it is installed and listed for this
 * user, "" otherwise.
 * @returns {String}
 */
GameKeys_InstalledKlid() {
	; Read at most every adapters.game_keys_installed_layout_ttl_ms: a press
	; criterion asks it on a foreground change and must not read the registry
	; each time; installing the layout is rare.
	static Spec := 0, Klid := "", ReadAt := 0, TtlMs := 0
	if !TtlMs
		TtlMs := TimingsGet("adapters", "game_keys_installed_layout_ttl_ms")
	if ReadAt && ((A_TickCount - ReadAt) & 0xFFFFFFFF) < TtlMs
		return Klid
	ReadAt := A_TickCount, Klid := ""
	try {
		if !IsObject(Spec)
			Spec := SystemLayout_Spec()
		Status := SystemLayout_Status(Spec)
		if Status["status"] != "installed"
			return ""
		for Choice in KLS_Choices(0, 0, (Id) => Id)
			if Choice["id"] == Status["klid"]
				Klid := Status["klid"]
	} catch as Err {
		try LoggerWarn("Layout", "The Ergopti system layout could not be looked up for the game keys: {1}.", Err.Message)
	}
	return Klid
}

/**
 * The route of the application in front while the emulation types.
 * @param {String} App The executable in front.
 * @param {String} InstalledKlid The installed Ergopti layout's KLID, "" for none.
 * @returns {Map} GameKeys_Route's result.
 */
GameKeys_EmulationRoute(App, InstalledKlid) {
	global Features
	Settings := GameKeys_Resolve(IsSet(Features) && Features is Map ? Features : Map())
	Chosen := GameKeys_ChoiceFor(Settings, "windows", App)
	return GameKeys_Route("windows", GameKeysName.Mode.EMULATION, Chosen["choice"],
		Map("installed_layout", InstalledKlid != "" && GameKeys_EmulatesErgopti(), "game", Chosen["overridden"]))
}

/**
 * Whether the emulation types an Ergopti layout, the one the Ergopti system
 * layout types too: the built-in base, or a registry layout of its family.
 * @returns {Boolean}
 */
GameKeys_EmulatesErgopti() {
	global KLE_Model, KLE_Ergopti, Features
	if IsSet(KLE_Model) && IsObject(KLE_Model)
		return IsSet(KLE_Ergopti) && KLE_Ergopti ? true : false
	return IsSet(Features) && Features is Map && Features.Has("layout") && Features["layout"] is Map
		&& Features["layout"].Get(ConfigLeaf.ERGOPTI_BASE, false) ? true : false
}

/**
 * The system layout's keystroke for one character: its virtual key and the
 * level modifiers VkKeyScanExW names ("shift", "altgr" for Ctrl+Alt; any
 * other combination is a modifier the hold cannot reproduce).
 * @param {String} Char One character.
 * @param {Integer} Hkl The foreground layout.
 * @returns {Map|Integer} Map("vk", Vk, "mods", Mods), 0 when the layout has no key for it.
 */
GameKeys_WindowsStep(Char, Hkl) {
	if !(Char is String) || Char == "" || Ord(Char) > 0xFFFF || !Hkl
		return 0
	Result := KS_KeyScanForChar(Hkl, Char)
	if Result == -1
		return 0
	State := (Result >> 8) & 0xFF
	Mods := []
	if State & 0x01
		Mods.Push("shift")
	Level := State & 0x06
	if Level == 0x06
		Mods.Push("altgr")
	else if Level != 0 || (State & 0xF8)
		Mods.Push("other")
	return Map("vk", Result & 0xFF, "mods", Mods)
}

/**
 * What the hand holds, through the key-state owner: AltGr held (its Ctrl+Alt
 * included) is a level the hold cannot reproduce on a suppressed prefix, so
 * only a step without AltGr can match while it is up.
 * @returns {Map} shift, altgr, caps_lock and virtual (Ctrl, Alt or Win is down).
 */
_GameKeys_HeldState() {
	AltGr := KS_IsDown("SC138")
	Other := KS_IsDown("LWin") || KS_IsDown("RWin") || (!AltGr && (KS_IsDown("Ctrl") || KS_IsDown("Alt")))
	return Map("shift", KS_ShiftIsHeld() ? true : false, "altgr", AltGr ? true : false,
		"caps_lock", KS_CapsLockToggleState(), "virtual", Other ? true : false)
}

/**
 * Sends an emulated character as a key held for as long as the physical key
 * is: down now (and again on each auto-repeat of the physical key), up on its
 * release. "letters" sends the system layout's key that types it; "physical"
 * sends one event whose scan code is the physical key and whose virtual key
 * types the character (the split event, to confirm by the Windows field check
 * of TODO.md). A character the system layout cannot type as the hand holds
 * returns false: the caller keeps the text route.
 * @param {String} Sc The physical key ("SC012").
 * @param {String} Text The emulated text of the press.
 * @param {Map} Ports Test seam: "step" (Text => GameKeys_WindowsStep's answer), "held",
 *   "app" and "klid" callables.
 * @returns {Boolean} True when the key was sent held.
 */
GameKeys_TryHold(Sc, Text, Ports := 0) {
	global _GK_Held, _GK_InstalledKlid, _GK_ReleaseScans
	; Without its release hotkey a held down would never get its up.
	if !_GK_ReleaseScans.Count
		return false
	if !(Ports is Map)
		Ports := Map()
	Step := Ports.Has("step") ? Ports["step"].Call(Text) : GameKeys_WindowsStep(Text, GetForegroundKeyboardLayout())
	if !GameKeys_HeldAdmissible(Text, Step, Ports.Has("held") ? Ports["held"].Call() : _GameKeys_HeldState())
		return false
	App := Ports.Has("app") ? Ports["app"].Call() : GameKeys_ForegroundApp()
	Route := GameKeys_EmulationRoute(App, Ports.Has("klid") ? Ports["klid"].Call() : _GK_InstalledKlid)
	Keys := Format("vk{:02X}", Step["vk"])
	; « physical »: the split event, on its own path. With an Ergopti system
	; layout to switch to, GameKeys_PassThrough lets the keys through once the
	; switch applies; the split event covers the presses before it does.
	if Route["strategy"] != GameKeysName.Strategy.HELD_BASE_KEY
		Keys .= "sc" . SubStr(Sc, 3)
	if _GK_Held.Has(Sc) && _GK_Held[Sc]["keys"] != Keys
		GameKeys_Release(Sc)
	_GameKeys_Send("{Blind}{" . Keys . " down}")
	_GK_Held[Sc] := Map("keys", Keys, "char", Text)
	if !IsSet(_EmitReachedScreen) || _EmitReachedScreen()
		UpdateLastSentCharacter(Text)
	return true
}

/**
 * Sends the up of a key held for a physical key, once.
 * @param {String} Sc The physical key.
 * @returns {Boolean} True when a held key was released.
 */
GameKeys_Release(Sc, *) {
	global _GK_Held
	if !_GK_Held.Has(Sc)
		return false
	Keys := _GK_Held[Sc]["keys"]
	_GK_Held.Delete(Sc)
	_GameKeys_Send("{Blind}{" . Keys . " up}")
	return true
}

/**
 * Releases every key held for the user: a suspend or a reload leaves none down.
 * @returns {Integer} How many were released.
 */
GameKeys_ReleaseAll() {
	global _GK_Held
	Scans := []
	for Sc in _GK_Held
		Scans.Push(Sc)
	Count := 0
	for Sc in Scans
		Count += GameKeys_Release(Sc) ? 1 : 0
	return Count
}

; The release hotkey's criterion: only while this driver holds a key for Sc,
; so every other release of the key keeps its own owner.
_GameKeys_HeldCriterion(Sc, *) {
	global _GK_Held
	return _GK_Held.Has(Sc)
}

/**
 * Registers the release hotkey of every physical key the emulation can hold:
 * the letter and number rows and the ISO key, never a modifier. Exempt from
 * Suspend, so a key held when the driver pauses still gets its up.
 * @param {Func} HotkeyFn Test seam, Hotkey by default.
 * @param {Func} HotIfFn Test seam, HotIf by default.
 * @returns {Integer} How many were registered.
 */
GameKeys_RegisterReleases(HotkeyFn := Hotkey, HotIfFn := HotIf) {
	global _GK_ReleaseScans, GAME_KEYS_RELEASE_EXCLUDED
	if _GK_ReleaseScans.Count
		throw Error("The game-key release hotkeys are already registered.")
	Codes := []
	Loop 0x35 - 0x02 + 1
		Codes.Push(0x02 + A_Index - 1)
	Codes.Push(0x56)
	try {
		for Code in Codes {
			if GAME_KEYS_RELEASE_EXCLUDED.Has(Code)
				continue
			Sc := Format("SC{:03X}", Code)
			HotIfFn.Call(_GameKeys_HeldCriterion.Bind(Sc))
			HotkeyFn.Call("*" . Sc . " Up", GameKeys_Release.Bind(Sc), "I2 S")
			_GK_ReleaseScans[Sc] := true
		}
	} finally {
		HotIfFn.Call()
	}
	GameKeys_Invalidate()
	try LoggerInfo("Layout", "Game-key release hotkeys registered ({1} keys).", _GK_ReleaseScans.Count)
	return _GK_ReleaseScans.Count
}





; ==================================
; ==================================
; ======= 3/ Native physical =======
; ==================================
; ==================================

/**
 * Whether the emulation lets the keys of the application in front through to
 * the installed Ergopti layout: the « physical » choice with the Ergopti
 * system layout installed (the switch_to_installed route, the fallback of the
 * split event). On a foreground change it asks Windows for that layout in the
 * game's window, and gives the previous one back when the game leaves the
 * foreground. Read by LayoutRowIsEmulated on every press; the first press
 * after a change can still be typed by the emulation while Windows applies
 * the switch (the Windows field check of TODO.md).
 * @param {Map} Ports Test seam: "hwnd", "app", "klid", "active", "select" callables.
 * @returns {Boolean}
 */
GameKeys_PassThrough(Ports := 0) {
	global _GK_Switched, _GK_InstalledKlid, _GK_ReleaseScans, _GK_Pass
	; A driver that holds no key (a test harness before registration) switches nothing.
	if !_GK_ReleaseScans.Count
		return false
	if !(Ports is Map)
		Ports := Map()
	Hwnd := Ports.Has("hwnd") ? Ports["hwnd"].Call() : WIGetForegroundHwnd()
	if Hwnd == _GK_Pass["hwnd"]
		return _GK_Pass["passing"]
	_GK_Pass["hwnd"] := Hwnd
	App := Ports.Has("app") ? Ports["app"].Call() : GameKeys_ForegroundApp()
	_GK_InstalledKlid := Ports.Has("klid") ? Ports["klid"].Call() : GameKeys_InstalledKlid()
	Passing := GameKeys_EmulationRoute(App, _GK_InstalledKlid)["strategy"] == GameKeysName.Strategy.SWITCH_TO_INSTALLED
	Select := Ports.Has("select") ? Ports["select"] : KLS_Select
	if Passing && !_GK_Switched["active"] {
		Previous := Ports.Has("active") ? Ports["active"].Call() : KLS_ActiveId()
		if Select.Call(_GK_InstalledKlid) {
			_GK_Switched["active"] := true, _GK_Switched["previous"] := Previous
			try LoggerInfo("Layout", "Game keys at their physical place in {1}: the Ergopti system layout types there.", App)
		} else
			Passing := false
	} else if !Passing && _GK_Switched["active"] {
		Previous := _GK_Switched["previous"]
		_GK_Switched["active"] := false
		if Previous != "" && Previous != _GK_InstalledKlid && !Select.Call(Previous)
			try LoggerWarn("Layout", "The layout {1} could not be given back after a game.", Previous)
	}
	_GK_Pass["passing"] := Passing
	return Passing
}

/**
 * Publishes the game-key settings of Features and decides the application in
 * front again on its next press: called at registration and after a choice
 * changes.
 */
GameKeys_Invalidate() {
	global _GK_Pass, _GK_Game, Features
	_GK_Pass["hwnd"] := -1
	_GK_Game := Map("hwnd", -1, "game", false,
		"settings", GameKeys_Resolve(IsSet(Features) && Features is Map ? Features : Map()))
}

/** Forgets the held keys, the registration and the foreground (test seam). */
_GameKeys_ResetForTest() {
	global _GK_Held, _GK_ReleaseScans, _GK_Foreground, _GK_Switched, _GK_InstalledKlid
	_GK_Held := Map(), _GK_ReleaseScans := Map(), _GK_InstalledKlid := ""
	_GK_Foreground := Map("hwnd", -1, "app", "")
	_GK_Switched := Map("active", false, "previous", "")
	GameKeys_Invalidate()
}
