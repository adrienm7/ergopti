; layouts/engine/system_layout_install.ahk

; ==============================================================================
; MODULE: Ergopti System Layout Install (Windows)
; DESCRIPTION:
; Layout > « Download the Ergopti system layout installer »: says whether the
; Ergopti keyboard layout is installed as a Windows system layout and, when
; asked, opens the download of the stand-alone installer the release publishes
; (release_asset of _shared/layouts/data/windows_system_layout.json, built
; by tools/build/build_windows_keyboard_layout.ps1 -PackagePath). The user runs
; its install.cmd; from then on the layout is one of the user's layouts:
; Layout > « Input sources » and the pause and resume switch (also at the driver
; start) select it like any other.
;
; FEATURES & RATIONALE:
; 1. The driver never runs the elevated installer and ships neither it nor the
;    DLL (maintainer decision of 2026-11-08, maintainer
;    decisions): an exe that carries a UAC launch and an inline P/Invoke stage
;    is what proxies and antivirus engines block (tools/ci/windows-exe-av-
;    surface.json). The installer stays in the release asset.
; 2. The download is the asset of the release this exe was built from, so the
;    layout matches the running version; a source run asks its update channel:
;    the stable channel's latest release has a stable download URL, the others
;    open the releases page. Every URL goes through the updater's repository
;    allowlist (_Updater_OpenManualUrl).
; 3. The row says where the layout stands: installed (its DLL in System32 and
;    a registered KLID naming it) or not. Without the shipped build there is
;    no build to compare with, so an installed layout always offers the
;    download again, to update it.
; 4. Fail fast: an unreadable state or a download that cannot be opened is
;    logged and told, with the address to open by hand.
; ==============================================================================

#Requires AutoHotkey v2.0

; The generated menu-command constants; #Include skips a file the entry script
; already loaded.
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk
; KLS_LAYOUTS_KEY: the registry root of installed layouts, owned by the adapter
; the entry script loads before its boot. This file is included after the boot
; tail, so a global initialized here would still be unset for a boot menu read.
#Include %A_LineFile%\..\..\adapters\keyboard_layout_switch.ahk

/**
 * The shared description of the layout Windows installs.
 * @param {Func} ReadFn Optional port: ReadFn(Path) returns the text or false.
 * @returns {Map} windows_system_layout.json.
 */
SystemLayout_Spec(ReadFn := 0) {
	global _SharedDir
	if !HasMethod(ReadFn, "Call")
		ReadFn := FSRead
	Path := _SharedDir . "\layouts\data\windows_system_layout.json"
	Text := ReadFn.Call(Path)
	if !(Text is String)
		throw Error("the Windows system layout description is unreadable: " . Path)
	Spec := JsonParse(Text)
	if !(Spec is Map)
		throw Error("the Windows system layout description is not an object")
	for Key in ["dll_name", "release_asset"]
		if !Spec.Has(Key) || !(Spec[Key] is String) || Spec[Key] == ""
			throw Error("the Windows system layout description has no " . Key)
	if !RegExMatch(Spec["release_asset"], "^[A-Za-z0-9._-]+\.zip$")
		throw Error("the Windows system layout release_asset is not a .zip file name: " . Spec["release_asset"])
	return Spec
}

; System32 as this process reaches it: a 32-bit AutoHotkey reads SysWOW64 there.
_SystemLayout_System32() => A_WinDir . ((A_Is64bitOS && A_PtrSize == 4) ? "\Sysnative" : "\System32")

; The KLID whose Layout File is DllFile, "" when none.
_SystemLayout_RegistryKlid(DllFile) {
	global KLS_LAYOUTS_KEY
	Loop Reg, KLS_LAYOUTS_KEY, "K" {
		; Not every layout key names a file (an IME may not): absence is ordinary.
		LayoutFile := RegRead(A_LoopRegKey . "\" . A_LoopRegName, "Layout File", "")
		if (StrLower(LayoutFile) == StrLower(DllFile))
			return StrUpper(A_LoopRegName)
	}
	return ""
}

/**
 * Where the Ergopti system layout stands.
 * @param {Map} Spec SystemLayout_Spec().
 * @param {Map} Ports Optional "exists" and "klid" ports (tests); the live
 *   system when omitted.
 * @returns {Map} "status": "not_installed" or "installed"; "klid" when
 *   registered.
 */
SystemLayout_Status(Spec, Ports := 0) {
	if !(Ports is Map)
		Ports := Map()
	ExistsFn := Ports.Get("exists", (Path) => FileExist(Path) != "")
	KlidFn := Ports.Get("klid", _SystemLayout_RegistryKlid)
	DllFile := Spec["dll_name"] . ".dll"
	Klid := KlidFn.Call(DllFile)
	if (Klid == "") || !ExistsFn.Call(_SystemLayout_System32() . "\" . DllFile)
		return Map("status", "not_installed", "klid", Klid)
	return Map("status", "installed", "klid", Klid)
}

/**
 * Where the installer of the matching release downloads from.
 * @param {Map} Spec SystemLayout_Spec().
 * @param {String} ReleaseUrl The stamped release of this exe
 *   (BUNDLE_RELEASE_URL, ".../releases/tag/<tag>"); anything else is a source
 *   run.
 * @param {String} Channel The update channel a source run follows.
 * @returns {String} The asset of that release, the stable channel's latest
 *   asset, or the releases page.
 */
SystemLayout_DownloadUrl(Spec, ReleaseUrl, Channel) {
	Releases := Updater_ReleasesPageUrl()
	Asset := Spec["release_asset"]
	if (ReleaseUrl is String)
		&& (SubStr(ReleaseUrl, 1, StrLen(Releases) + 5) == Releases . "/tag/")
		&& RegExMatch(SubStr(ReleaseUrl, StrLen(Releases) + 6), "^[A-Za-z0-9._+-]+$", &Tag)
		return Releases . "/download/" . Tag[0] . "/" . Asset
	; GitHub's /releases/latest names the newest release that is no prerelease.
	if UpdateChannels_IsKnown(Channel) && !UpdateChannels_Field(Channel, "github_prerelease")
		return Releases . "/latest/download/" . Asset
	return Releases
}

; The live inputs of SystemLayout_DownloadUrl.
_SystemLayout_LiveDownloadUrl(Spec) {
	global BUNDLE_RELEASE_URL, UPDATER_CHANNEL
	return SystemLayout_DownloadUrl(Spec, IsSet(BUNDLE_RELEASE_URL) ? BUNDLE_RELEASE_URL : "",
		IsSet(UPDATER_CHANNEL) ? UPDATER_CHANNEL : "")
}

/**
 * Layout > « Download the Ergopti system layout installer »: one row for
 * where the layout stands and the download command.
 * @param {Func} StatusFn Optional port: StatusFn() returns SystemLayout_Status.
 * @param {Func} DownloadFn Optional port started by the command.
 * @returns {Array} Provider rows.
 */
SystemLayout_MenuRows(StatusFn := 0, DownloadFn := 0) {
	if !HasMethod(DownloadFn, "Call")
		DownloadFn := SystemLayout_Download
	if !HasMethod(StatusFn, "Call")
		StatusFn := () => SystemLayout_Status(SystemLayout_Spec())
	try Status := StatusFn.Call()
	catch as Err {
		try LoggerError("SystemLayout", "The Ergopti system layout state could not be read: {1}.", Err.Message)
		return _SystemLayout_DeclaredRows(MenuRenderer_StatusRows("layout_menu", "layout_system_install", "unreadable"))
	}
	switch Status["status"] {
		case "installed":
			; A fresh array: the renderer's own row lists are never mutated.
			Rows := []
			for Row in _SystemLayout_DeclaredRows(MenuRenderer_StatusRows("layout_menu", "layout_system_install", "installed"))
				Rows.Push(Row)
			for Row in _SystemLayout_DeclaredRows(MenuRenderer_TemplateRows("layout_system_update_commands",
				Map(MenuCommand.SYSTEM_LAYOUT_UPDATE, (*) => DownloadFn.Call()), Map(), Map()))
				Rows.Push(Row)
			return Rows
		case "not_installed":
			return _SystemLayout_DeclaredRows(MenuRenderer_TemplateRows("layout_system_install_commands",
				Map(MenuCommand.SYSTEM_LAYOUT_INSTALL, (*) => DownloadFn.Call()), Map(), Map()))
	}
	throw ValueError("unknown system layout status " . Status["status"])
}

; A refused declaration publishes no row rather than a partial one; the
; renderer already logged why.
_SystemLayout_DeclaredRows(Rows) => Rows is Array ? Rows : []

/**
 * Explains the installer, then opens its download.
 * @param {Func} ConfirmFn Optional port: ConfirmFn(Asset) is true when the user agrees.
 * @param {Func} OpenFn Optional port: OpenFn(Url) opens it and returns true.
 * @param {Func} TellFn Optional port: TellFn(Message) shows an error.
 * @param {Func} UrlFn Optional port: UrlFn(Spec) returns the download URL.
 * @returns {Boolean} true once the download is open.
 */
SystemLayout_Download(ConfirmFn := 0, OpenFn := 0, TellFn := 0, UrlFn := 0) {
	if !HasMethod(ConfirmFn, "Call")
		ConfirmFn := (Asset) => Ui_MsgBox(Format(t("dialog.system_layout.confirm"), Asset),
			t("dialog.system_layout.window_title"), "OKCancel Default1 Iconi") == "OK"
	if !HasMethod(OpenFn, "Call")
		OpenFn := (Url) => _Updater_OpenManualUrl(() => Url)
	if !HasMethod(TellFn, "Call")
		TellFn := (Message) => Ui_MsgBox(Message, t("dialog.system_layout.window_title"), "Icon!")
	if !HasMethod(UrlFn, "Call")
		UrlFn := _SystemLayout_LiveDownloadUrl
	Spec := SystemLayout_Spec()
	if !ConfirmFn.Call(Spec["release_asset"]) {
		try LoggerInfo("SystemLayout", "The Ergopti system layout download was declined.")
		return false
	}
	Url := UrlFn.Call(Spec)
	if !OpenFn.Call(Url) {
		try LoggerError("SystemLayout", "The Ergopti system layout download did not open: {1}.", Url)
		; A paused driver refuses every manual URL and already said so.
		if !A_IsSuspended
			TellFn.Call(Format(t("dialog.system_layout.open_failed"), Url))
		return false
	}
	try LoggerInfo("SystemLayout", "Opened the Ergopti system layout download: {1}.", Url)
	return true
}
