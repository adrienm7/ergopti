; static/ergopti_plus/windows/tests/unit/ui/bundled_apps/test_bundled_apps.ahk

; ==============================================================================
; MODULE: Bundled Apps Tests (Windows)
; DESCRIPTION:
; Pins the Windows App Cloner and Encryptor (windows/apps/) to the shared
; contracts. The Encryptor decrypts every shared container the macOS and Linux
; Encryptors write (_shared/tests/corpus/encryptor/vectors.json) and, with the
; same salt, writes the same bytes; a wrong password is refused and leaves an
; approved destination intact; destinations follow the macOS names. App Cloner
; detects the shared families, quotes arguments as CommandLineToArgvW reads
; them, isolates each family's profile and says when a program cannot be
; isolated. The dialog flows and the tray launch run with scripted ports.
; ==============================================================================




; ==================================
; ==================================
; ======= 1/ Helpers ===============
; ==================================
; ==================================

_BAT_Hex(Bytes) {
	Out := ""
	loop Bytes.Size
		Out .= Format("{:02x}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Out
}

_BAT_Bytes(Hex) {
	Out := Buffer(StrLen(Hex) // 2)
	loop Out.Size
		NumPut("UChar", Integer("0x" . SubStr(Hex, A_Index * 2 - 1, 2)), Out, A_Index - 1)
	return Out
}

_BAT_Vectors() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\encryptor\vectors.json", "UTF-8"))
}

_BAT_Format() {
	global _SharedDir
	return Encryptor_LoadFormat(_SharedDir)
}

_BAT_Strings() {
	global _SharedDir
	if !BundledAppStrings.loaded
		BundledAppStrings_Load(_SharedDir . "\data\locales", "en")
}

_BAT_WorkDir() {
	Dir := A_Temp . "\ergopti_bundled_apps_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Dir)
	return Dir
}

_BAT_WriteBytes(Path, Bytes) {
	File := FileOpen(Path, "w")
	File.RawWrite(Bytes, Bytes.Size)
	File.Close()
}




; ==================================
; ==================================
; ======= 2/ Encryptor =============
; ==================================
; ==================================

_BAT_DecryptsSharedContainers() {
	Envelope := _BAT_Format()
	for Vector in _BAT_Vectors()["containers"] {
		Plain := Encryptor_Open(Envelope, _BAT_Bytes(Vector["container_hex"]), Vector["password"])
		AssertTrue(Plain is Buffer, Vector["id"] . ": the shared container must open")
		AssertEqual(Vector["plaintext_hex"], _BAT_Hex(Plain), Vector["id"])
	}
}
Test("(bundled-apps-encryptor-vectors) decrypts every shared container the other drivers write", _BAT_DecryptsSharedContainers)

_BAT_SealsSharedBytes() {
	Envelope := _BAT_Format()
	for Vector in _BAT_Vectors()["containers"] {
		Sealed := Encryptor_Seal(Envelope, _BAT_Bytes(Vector["plaintext_hex"]), Vector["password"], _BAT_Bytes(Vector["salt_hex"]))
		AssertEqual(Vector["container_hex"], _BAT_Hex(Sealed), Vector["id"] . ": same salt, same bytes")
	}
}
Test("(bundled-apps-encryptor-vectors) writes the shared container byte for byte", _BAT_SealsSharedBytes)

_BAT_RefusesWrongPassword() {
	Vectors := _BAT_Vectors()
	Opened := Encryptor_Open(_BAT_Format(), _BAT_Bytes(Vectors["containers"][1]["container_hex"]), Vectors["wrong_password"])
	AssertFalse(Opened is Buffer, "a wrong password must not decode to garbage")
}
Test("(bundled-apps-encryptor-vectors) refuses a wrong password", _BAT_RefusesWrongPassword)

_BAT_NamesDestinations() {
	Envelope := _BAT_Format()
	for Vector in _BAT_Vectors()["names"] {
		Target := Encryptor_Destination(Envelope, StrReplace(Vector["source"], "/", "\"))
		AssertEqual(Vector["mode"], Target["mode"], Vector["source"])
		AssertEqual(StrReplace(Vector["destination"], "/", "\"), Target["destination"], Vector["source"])
	}
}
Test("(bundled-apps-encryptor-names) names destinations as the macOS Encryptor does", _BAT_NamesDestinations)

_BAT_ConvertsFilesSafely() {
	Envelope := _BAT_Format()
	Dir := _BAT_WorkDir()
	try {
		Plain := _BAT_Bytes("00ff10e2889a0a")
		_BAT_WriteBytes(Dir . "\note.bin", Plain)
		AssertTrue(Encryptor_ConvertFile(Envelope, "encrypt", Dir . "\note.bin", Dir . "\note.bin.enc", "pässwörd"))
		AssertTrue(Encryptor_ConvertFile(Envelope, "decrypt", Dir . "\note.bin.enc", Dir . "\back.bin", "pässwörd"))
		AssertEqual(_BAT_Hex(Plain), _BAT_Hex(FileRead(Dir . "\back.bin", "RAW")))
		FileAppend("previous", Dir . "\kept.bin")
		AssertFalse(Encryptor_ConvertFile(Envelope, "decrypt", Dir . "\note.bin.enc", Dir . "\kept.bin", "wrong"))
		AssertEqual("previous", FileRead(Dir . "\kept.bin"), "a refused password leaves the destination intact")
		Count := 0
		loop files Dir . "\*", "F"
			Count += 1
		AssertEqual(4, Count, "no stage survives a refused conversion")
	} finally DirDelete(Dir, true)
}
Test("(bundled-apps-encryptor-files) round-trips a file and keeps an approved destination on refusal", _BAT_ConvertsFilesSafely)

_BAT_EncryptorFlow() {
	_BAT_Strings()
	Dir := _BAT_WorkDir()
	try {
		FileAppend("pdf bytes", Dir . "\doc.pdf")
		Answers := ["one", "two", "pw", "pw"]
		Seen := []
		State := Map("revealed", "")
		Ports := Map("format", _BAT_Format(),
			"entry", (Title, Prompt, Initial := "", Hidden := false) => (Seen.Push("entry"), Answers.RemoveAt(1)),
			"message", (Kind, Title, Text) => Seen.Push(Kind . ":" . Text),
			"choice", (Title, Text, Ok, Cancel) => true,
			"reveal", (Path) => (State["revealed"] := Path))
		AssertEqual("done", Encryptor_ProcessFile(Dir . "\doc.pdf", Ports))
		AssertEqual("warning:" . AppText("apps.encryptor.err_password_mismatch"), Seen[3])
		AssertTrue(Encryptor_ConvertFile(Ports["format"], "decrypt", Dir . "\doc.pdf.enc", Dir . "\check", "pw"))
		AssertEqual("pdf bytes", FileRead(Dir . "\check"))
		AssertEqual(Dir . "\doc.pdf.enc", State["revealed"], "Show in folder reveals the result")
	} finally DirDelete(Dir, true)
}
Test("(bundled-apps-encryptor-flow) confirms the password, retries a mismatch and converts", _BAT_EncryptorFlow)




; ==================================
; ==================================
; ======= 3/ App Cloner ============
; ==================================
; ==================================

_BAT_QuotesArguments() {
	AssertEqual("plain", BundledAppsNative_QuoteArg("plain"))
	AssertEqual('""', BundledAppsNative_QuoteArg(""))
	AssertEqual('"C:\Program Files\App"', BundledAppsNative_QuoteArg("C:\Program Files\App"))
	AssertEqual('"a \"b\""', BundledAppsNative_QuoteArg('a "b"'))
	AssertEqual('"C:\x y\\"', BundledAppsNative_QuoteArg("C:\x y\"))
	AssertEqual('"a\\\"b c"', BundledAppsNative_QuoteArg('a\"b c'))
}
Test("(bundled-apps-quoting) quotes each argument as CommandLineToArgvW reads it back", _BAT_QuotesArguments)

_BAT_ShortcutRoundTrip() {
	Dir := _BAT_WorkDir()
	try {
		Target := A_WinDir . "\System32\notepad.exe"
		Icons := A_WinDir . "\System32\shell32.dll"
		for Icon in [Icons . ",0", Icons . ",3", ""] {
			Link := Dir . "\clone_" . A_Index . ".lnk"
			BundledAppsNative_WriteShortcut(Link, Map("target", Target, "arguments", '--profile "a b"',
				"working_directory", Dir, "icon", Icon, "description", "Ergopti clone"))
			Read := BundledAppsNative_ReadShortcut(Link)
			; The shell stores the target in the folder's on-disk case (C:\Windows)
			; while A_WinDir can read C:\WINDOWS: one path, compared as Windows does.
			AssertEqual(StrLower(Target), StrLower(Read["target"]))
			AssertEqual('--profile "a b"', Read["arguments"])
			AssertEqual(Icon, Read["icon"], "the IconLocation index survives the native shortcut round trip")
		}
		AssertThrows(() => BundledAppsNative_WriteShortcut(Dir . "\bad.lnk", Map("target", Target, "icon", Icons)))
	} finally DirDelete(Dir, true)
}
Test("(bundled-apps-shortcut) writes and reads a shortcut's target, arguments and icon index", _BAT_ShortcutRoundTrip)

_BAT_Request(Program, Extra := 0) {
	global _SharedDir
	Request := Map("program", Program, "arguments", [], "name", "Work Browser", "open_item", "",
		"catalogue", AppCloner_LoadFamilies(_SharedDir), "data_home", "C:\Users\u\AppData\Local",
		"roaming", "C:\Users\u\AppData\Roaming", "home", "C:\Users\u", "programs", "C:\Start\Programs",
		"taken", (Id, Shortcut) => false)
	if IsObject(Extra)
		for Key, Value in Extra
			Request[Key] := Value
	return Request
}

_BAT_ChromiumPlan() {
	Plan := AppCloner_Plan(_BAT_Request("C:\Apps\Google\chrome.exe", Map("open_item", "https://mail.example.com/")))
	AssertEqual("chromium", Plan["family"])
	AssertTrue(Plan["isolated"])
	AssertEqual("--user-data-dir=C:\Users\u\AppData\Local\Ergopti\app_cloner\work-browser\profile --app=https://mail.example.com/",
		Plan["arguments"], "the Linux-only --class is not passed on Windows")
	AssertEqual("C:\Start\Programs\Ergopti\Work Browser.lnk", Plan["shortcut"])
	AssertEqual("C:\Apps\Google\chrome.exe,0", Plan["icon"])
}
Test("(bundled-apps-cloner-plan) gives a Chromium clone its own profile and web-app window", _BAT_ChromiumPlan)

_BAT_VsCodeAndFirefoxPlans() {
	Code := AppCloner_Plan(_BAT_Request("C:\Code\Code.exe"))
	AssertEqual("vscode", Code["family"])
	AssertContains(Code["arguments"], '--extensions-dir=C:\Users\u\.vscode\extensions')
	AssertEqual("C:\Users\u\AppData\Roaming\Code\User", Code["links"][1]["target"])
	Fox := AppCloner_Plan(_BAT_Request("C:\Mozilla\firefox.exe"))
	AssertEqual("firefox", Fox["family"])
	AssertContains(Fox["arguments"], "--no-remote --profile C:\Users\u\AppData\Local\Ergopti\app_cloner\work-browser\profile")
	Spaced := AppCloner_Plan(_BAT_Request("C:\Mozilla\firefox.exe", Map("data_home", "C:\Users\A B\Local")))
	AssertContains(Spaced["arguments"], '--profile "C:\Users\A B\Local\Ergopti\app_cloner\work-browser\profile"')
}
Test("(bundled-apps-cloner-plan) shares VS Code settings and gives Firefox its own profile", _BAT_VsCodeAndFirefoxPlans)

_BAT_NativeAndTaken() {
	Native := AppCloner_Plan(_BAT_Request("C:\Windows\notepad.exe", Map("has_marker", (P, M) => false)))
	AssertEqual("native", Native["family"])
	AssertFalse(Native["isolated"], "a native program's clone is not presented as isolated")
	AssertEqual("", Native["arguments"])
	Electron := AppCloner_Plan(_BAT_Request("C:\Obsidian\Obsidian.exe",
		Map("has_marker", (P, M) => M == "resources\app.asar")))
	AssertEqual("electron", Electron["family"])
	Second := AppCloner_Plan(_BAT_Request("C:\Apps\chrome.exe", Map("taken", (Id, Shortcut) => Id == "work-browser")))
	AssertEqual("work-browser-2", Second["id"])
	AssertEqual("C:\Start\Programs\Ergopti\Work Browser (2).lnk", Second["shortcut"])
}
Test("(bundled-apps-cloner-plan) detects Electron by marker, names native clones and suffixes taken names", _BAT_NativeAndTaken)

_BAT_ClonerFlow() {
	global _SharedDir
	_BAT_Strings()
	Answers := ["Firefox Work", "C:\does\not\exist", "https://example.com"]
	Messages := []
	State := Map("written", 0)
	Ports := Map("catalogue", AppCloner_LoadFamilies(_SharedDir),
		"pick_source", (Title) => "C:\Start\Firefox.lnk",
		"read_shortcut", (Path) => Map("target", "C:\Mozilla\firefox.exe", "arguments", "", "icon", ""),
		"entry", (Title, Prompt, Initial := "", Hidden := false) => Answers.RemoveAt(1),
		"choice", (Title, Text, Ok, Cancel) => true,
		"message", (Kind, Title, Text) => Messages.Push(Kind . ":" . Text),
		"pick_icon", (Title) => "",
		"exists", (Path) => false,
		"write", (Plan) => (State["written"] := Plan),
		"data_home", "C:\L", "roaming", "C:\R", "home", "C:\H", "programs", "C:\P", "has_marker", 0)
	AssertEqual("created", AppCloner_Run(Ports))
	AssertEqual("warning:" . AppText("apps.cloner.err_path_missing", "C:\does\not\exist"), Messages[1])
	AssertEqual("firefox", State["written"]["family"])
	AssertContains(State["written"]["arguments"], "https://example.com")
}
Test("(bundled-apps-cloner-flow) reads the shortcut, refuses a missing path and writes the clone", _BAT_ClonerFlow)

; The item to open follows macOS validateOpenArg and the Linux invalid_open_item
; (maintainer decision, 2026-11-12): « ~ » is the profile folder, and a URL needs
; « :// » or a Teams link, so « https:/x » and « localhost:3000 » are refused.
_BAT_OpenItemValidation() {
	Exists := (Path) => (Path == "C:\H" || Path == "C:\H\Docs")
	for Row in [
			["https://example.com", [], "https://example.com"],
			["msteams:/l/meetup-join/x", [], "msteams:/l/meetup-join/x"],
			["msteams:/calendar", [], "msteams:/calendar"],
			["~", [], "C:\H"],
			["~\Docs", [], "C:\H\Docs"],
			["~/Docs", [], "C:\H\Docs"],
			["C:\H\Docs", [], "C:\H\Docs"],
			["~\Missing", ["apps.cloner.err_path_missing", "~\Missing"], ""],
			["https:/x", ["apps.cloner.err_url_format", ""], ""],
			["localhost:3000", ["apps.cloner.err_url_format", ""], ""],
			["msteams:/other", ["apps.cloner.err_url_format", ""], ""]] {
		Invalid := _AppCloner_InvalidOpenItem(Row[1], Exists, "C:\H", &Resolved)
		AssertEqual(Row[2].Length, Invalid.Length, "verdict for '" . Row[1] . "'")
		if Row[2].Length {
			AssertEqual(Row[2][1], Invalid[1], "error key for '" . Row[1] . "'")
			AssertEqual(Row[2][2], Invalid[2], "error value for '" . Row[1] . "'")
		} else {
			AssertEqual(Row[3], Resolved, "item to open for '" . Row[1] . "'")
		}
	}
}
Test("(bundled-apps-cloner-open-item) expands ~ and refuses an item without :// as macOS and Linux", _BAT_OpenItemValidation)




; ==================================
; ==================================
; ======= 4/ Entry and tray ========
; ==================================
; ==================================

_BAT_ParsesArguments() {
	Options := BundledApp_ParseArguments(["--bundled-app", "encryptor", "--locales-dir", "C:\l", "--locale", "fr",
		"--", "--locale", "C:\a b.pdf"])
	AssertEqual("encryptor", Options["app"])
	AssertEqual("fr", Options["locale"])
	AssertEqual(2, Options["files"].Length, "files after -- stay files")
	AssertThrows(() => BundledApp_ParseArguments(["--bundled-app", "other", "--locales-dir", "C:\l"]))
	AssertThrows(() => BundledApp_ParseArguments(["--bundled-app", "encryptor"]))
}
Test("(bundled-apps-entry) reads the app, the locale and the files of its command line", _BAT_ParsesArguments)

_BAT_TrayLaunch() {
	Env := Map("compiled", false, "script_path", "C:\E\ErgoptiPlus.ahk", "ahk_path", "C:\AHK\AutoHotkey64.exe",
		"entry", "C:\E\apps\bundled_app_entry.ahk", "locales_dir", "C:\S\data\locales", "locale", "fr")
	Started := [], Shortcuts := []
	AssertTrue(BundledApps_Launch(BUNDLED_APPS[2], Env, (Exe, Args) => Started.Push([Exe, Args]),
		(Path, Fields) => Shortcuts.Push([Path, Fields])))
	AssertEqual("C:\AHK\AutoHotkey64.exe", Started[1][1])
	AssertEqual("/force C:\E\apps\bundled_app_entry.ahk --bundled-app encryptor --locales-dir C:\S\data\locales --locale fr",
		BundledAppsNative_CommandLine(Started[1][2]))
	AssertContains(Shortcuts[1][1], "\Microsoft\Windows\SendTo\Encryptor.lnk")
	AssertEqual("/force C:\E\apps\bundled_app_entry.ahk --bundled-app encryptor --locales-dir C:\S\data\locales --locale fr --",
		Shortcuts[1][2]["arguments"])
	Env["compiled"] := true
	Command := BundledApps_Command(BUNDLED_APPS[1], Env)
	AssertEqual("C:\E\ErgoptiPlus.ahk", Command["executable"])
	AssertEqual("/force --bundled-app app-cloner --locales-dir C:\S\data\locales --locale fr",
		BundledAppsNative_CommandLine(Command["args"]))
	Rows := BundledApps_Rows()
	AssertEqual(2, Rows.Length)
	AssertEqual("App Cloner — " . t("menu.apps.clone_desc"), Rows[1]["label"])
	AssertEqual("Encryptor — " . t("menu.apps.encrypt_desc"), Rows[2]["label"])
	AssertEqual(0, Rows[1]["action"].MinParams, "a menu action takes the menu's own arguments")
}
Test("(bundled-apps-tray) starts each app in its own process and writes the Encryptor drop target", _BAT_TrayLaunch)
