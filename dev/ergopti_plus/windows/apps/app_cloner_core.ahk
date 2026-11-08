; apps/app_cloner_core.ahk

; ==============================================================================
; MODULE: App Cloner Core (Windows)
; DESCRIPTION:
; Builds an isolated copy of an installed program, the Windows counterpart of
; the macOS App Cloner's stub bundle: a Start menu shortcut of its own (name,
; icon) that starts the untouched program with a private profile folder.
;
; FEATURES & RATIONALE:
; 1. Nothing of the source is copied or patched, as on macOS: the profile goes
;    through the program's own options, chosen by its family in
;    _shared/data/app_cloner/families.json (Chromium and Electron
;    --user-data-dir, Firefox -profile, VS Code with the shared extensions).
; 2. A program of no family cannot be isolated on Windows: a shortcut cannot
;    give one process its own %APPDATA%, and redirecting it through a wrapper
;    would break the program's single-instance and update logic. Its clone is a
;    second shortcut only, and App Cloner says so before writing it.
; 3. Pure where it can be: detection, quoting and the plan take their
;    filesystem through ports, so the tests drive them directly.
; ==============================================================================

#Requires AutoHotkey v2.0+




; ==================================
; ==================================
; ======= 1/ Families ==============
; ==================================
; ==================================

/**
 * Reads the shared family catalogue.
 * @param {String} SharedDir
 * @returns {Map}
 */
AppCloner_LoadFamilies(SharedDir) {
	Catalogue := JsonParse(FileRead(SharedDir . "\data\app_cloner\families.json", "UTF-8"))
	for Key in ["detection_order", "families", "profile_folder", "window_class_prefix"] {
		if !Catalogue.Has(Key)
			throw ValueError("The shared App Cloner families lack " . Key . ".")
	}
	return Catalogue
}

/**
 * The family of a program, or "native".
 * @param {Map} Catalogue
 * @param {String} Program Path to the executable.
 * @param {Func} HasMarker HasMarker(Program, Marker) -> Boolean, or 0.
 * @returns {String}
 */
AppCloner_Family(Catalogue, Program, HasMarker := 0) {
	SplitPath(Program, &FileName)
	Name := StrLower(RegExReplace(FileName, "i)\.exe$"))
	for Family in Catalogue["detection_order"] {
		for Executable in Catalogue["families"][Family]["executables"] {
			if (Name == Executable)
				return Family
		}
	}
	if HasMethod(HasMarker, "Call") {
		for Family in Catalogue["detection_order"] {
			Definition := Catalogue["families"][Family]
			if !Definition.Has("markers")
				continue
			for Marker in Definition["markers"] {
				if HasMarker.Call(Program, StrReplace(Marker, "/", "\"))
					return Family
			}
		}
	}
	return "native"
}

/**
 * The family's Windows arguments with their placeholders filled.
 * @param {Map} Catalogue
 * @param {String} Family
 * @param {Map} Values profile, window_class, home.
 * @returns {Array}
 */
AppCloner_Arguments(Catalogue, Family, Values) {
	Words := []
	if !Catalogue["families"].Has(Family)
		return Words
	for Argument in Catalogue["families"][Family]["arguments"] {
		if Argument.Has("platforms") {
			Wanted := false
			for Platform in Argument["platforms"]
				Wanted := Wanted || Platform == "windows"
			if !Wanted
				continue
		}
		Template := Argument["value"]
		; The catalogue spells folders with "/"; Windows programs read "\".
		if RegExMatch(Template, "\{(home|profile)\}")
			Template := StrReplace(Template, "/", "\")
		; One left-to-right pass: a filled value is never read as a placeholder.
		Value := "", At := 1
		while (Found := RegExMatch(Template, "\{([a-z_]+)\}", &Hole, At)) {
			if !Values.Has(Hole[1])
				throw ValueError("No value for {" . Hole[1] . "}.")
			Value .= SubStr(Template, At, Found - At) . Values[Hole[1]]
			At := Found + Hole.Len[0]
		}
		Words.Push(Value . SubStr(Template, At))
	}
	return Words
}

/**
 * A file-name-safe identifier for a clone name.
 * @param {String} Name
 * @returns {String}
 */
AppCloner_Slug(Name) {
	Slug := Trim(RegExReplace(StrLower(Name), "[^a-z0-9]+", "-"), "-")
	if Slug == ""
		Slug := "clone"
	return SubStr(Slug, 1, 48)
}

/**
 * The clone name as a shortcut file name.
 * @param {String} Name
 * @returns {String}
 */
AppCloner_ShortcutName(Name) {
	Safe := Trim(RegExReplace(Name, '[\\/:*?"<>|\x00-\x1F]', "-"), " .")
	return (Safe == "" ? "Clone" : Safe) . ".lnk"
}




; ==================================
; ==================================
; ======= 2/ Plan ==================
; ==================================
; ==================================

/**
 * Plans a clone.
 * @param {Map} Request program, arguments (Array, the source shortcut's), name,
 *   open_item, icon, catalogue, data_home (%LOCALAPPDATA%), roaming (%APPDATA%),
 *   home, programs (Start menu Programs folder), has_marker, taken (Func(Id, Shortcut)).
 * @returns {Map} id, family, isolated, profile, shortcut, target, arguments,
 *   icon, folders, links.
 */
AppCloner_Plan(Request) {
	Catalogue := Request["catalogue"]
	Family := AppCloner_Family(Catalogue, Request["program"], Request.Get("has_marker", 0))
	Base := AppCloner_Slug(Request["name"])
	Id := Base, Suffix := 1
	Folder := Request["programs"] . "\Ergopti\"
	Shortcut := Folder . AppCloner_ShortcutName(Request["name"])
	; A name already taken gets a suffix on both its profile and its shortcut, so
	; a second clone never shares the first one's profile or overwrites its entry.
	Taken := Request["taken"]
	while Taken.Call(Id, Shortcut) {
		Suffix += 1
		Id := Base . "-" . Suffix
		Shortcut := Folder . AppCloner_ShortcutName(Request["name"] . " (" . Suffix . ")")
	}
	Root := Request["data_home"] . "\Ergopti\" . Catalogue["profile_folder"] . "\" . Id
	Profile := Root . "\profile"
	Plan := Map("id", Id, "family", Family, "isolated", Family != "native", "profile", Profile,
		"folders", Family != "native" ? [Profile] : [], "links", [],
		"shortcut", Shortcut,
		"target", Request["program"])
	Words := []
	for Word in Request.Get("arguments", [])
		Words.Push(Word)
	for Word in AppCloner_Arguments(Catalogue, Family,
			Map("profile", Profile, "window_class", Catalogue["window_class_prefix"] . Id, "home", Request["home"]))
		Words.Push(Word)
	Definition := Catalogue["families"].Has(Family) ? Catalogue["families"][Family] : Map()
	if Definition.Get("share_user_settings", false) {
		; As macOS does: the clone reads the main instance's settings, keybindings
		; and snippets, while its windows, state and accounts stay its own.
		Plan["links"].Push(Map("link", Profile . "\User", "target", Request["roaming"] . "\Code\User"))
	}
	OpenItem := Request.Get("open_item", "")
	if OpenItem != "" {
		if Definition.Has("web_app") && RegExMatch(OpenItem, "i)^https?://")
			Words.Push(StrReplace(Definition["web_app"], "{url}", OpenItem))
		else
			Words.Push(OpenItem)
	}
	Plan["arguments"] := BundledAppsNative_CommandLine(Words)
	Plan["icon"] := Request.Get("icon", "") != "" ? Request["icon"] : Request["program"] . ",0"
	return Plan
}

/**
 * Writes a planned clone.
 * @param {Map} Plan
 * @returns {Boolean}
 */
AppCloner_Write(Plan) {
	for Folder in Plan["folders"]
		DirCreate(Folder)
	for Link in Plan["links"] {
		if DirExist(Link["target"]) && !FileExist(Link["link"]) {
			if !BundledAppsNative_Junction(Link["link"], Link["target"])
				throw OSError(0, -1, "Cannot link " . Link["link"] . ".")
		}
	}
	SplitPath(Plan["shortcut"], , &Folder)
	DirCreate(Folder)
	SplitPath(Plan["target"], , &WorkingDirectory)
	BundledAppsNative_WriteShortcut(Plan["shortcut"], Map("target", Plan["target"], "arguments", Plan["arguments"],
		"working_directory", WorkingDirectory, "icon", Plan["icon"]))
	return true
}
