; tests/unit/layouts/engine/test_system_layout_install.ahk

; ==============================================================================
; MODULE: Ergopti System Layout Install (Windows)
; DESCRIPTION:
; Layout > « Download the Ergopti system layout installer »: the row follows
; where the layout stands, the command explains the installer and opens the
; release asset of this version (or of the update channel in a source run), a
; refused dialog opens nothing, a download that cannot open is told with its
; address, and the driver itself never starts the elevated installer.
; ==============================================================================

#Requires AutoHotkey v2.0




; Status ports: the registry names Klid and System32 holds the DLL or not.
_SLI_Ports(Klid, Installed) {
	return Map("exists", (Path) => Installed, "klid", (Dll) => Klid)
}

/** The status reads the registry and System32, never a shipped build. */
_SLI_Status() {
	Spec := SystemLayout_Spec()
	AssertEqual("not_installed", SystemLayout_Status(Spec, _SLI_Ports("", false))["status"])
	AssertEqual("not_installed", SystemLayout_Status(Spec, _SLI_Ports("", true))["status"],
		"a DLL nobody registered is not an install")
	AssertEqual("not_installed", SystemLayout_Status(Spec, _SLI_Ports("A000040C", false))["status"],
		"a registry entry without its DLL is not an install")
	Status := SystemLayout_Status(Spec, _SLI_Ports("A000040C", true))
	AssertEqual("installed", Status["status"])
	AssertEqual("A000040C", Status["klid"])
}

/** The asset comes from the shared description, a .zip file name. */
_SLI_Spec() {
	Spec := SystemLayout_Spec()
	AssertTrue(RegExMatch(Spec["release_asset"], "^[A-Za-z0-9._-]+\.zip$"), "the asset is a .zip file name")
	AssertThrows(() => SystemLayout_Spec((Path) => '{"dll_name":"kbdergop"}'), "a description without its asset fails")
	AssertThrows(() => SystemLayout_Spec((Path) => '{"dll_name":"kbdergop","release_asset":"../x.zip"}'),
		"an asset name that is a path fails")
}

/** One status row and the download, whatever the state; unreadable says so. */
_SLI_MenuRows() {
	Started := 0
	Download() {
		Started += 1
	}
	Unreadable() {
		throw Error("registry refused")
	}
	Rows := SystemLayout_MenuRows(() => Map("status", "not_installed", "klid", ""), Download)
	AssertEqual(1, Rows.Length)
	AssertEqual(t("menu.layout.system_layout_install"), Rows[1]["label"])
	Rows[1]["action"].Call()
	Rows := SystemLayout_MenuRows(() => Map("status", "installed", "klid", "A000040C"), Download)
	AssertEqual(2, Rows.Length, "an installed layout can be downloaded again to update it")
	AssertEqual(t("menu.layout.system_layout_installed"), Rows[1]["label"])
	AssertFalse(Rows[1].Has("action"), "the installed state is an inert row")
	AssertEqual(t("menu.layout.system_layout_update"), Rows[2]["label"])
	Rows[2]["action"].Call()
	Rows := SystemLayout_MenuRows(Unreadable, Download)
	AssertEqual(t("menu.layout.system_layout_unreadable"), Rows[1]["label"], "an unreadable state says so")
	AssertFalse(Rows[1].Has("action"))
	AssertEqual(2, Started, "the install and the update rows open the download")
	AssertContains(t("menu.layout.system_layout_install"), "…")
}

/** The stamped release, then the stable channel's latest, then the page. */
_SLI_DownloadUrl() {
	Spec := SystemLayout_Spec()
	Releases := Updater_ReleasesPageUrl()
	Asset := Spec["release_asset"]
	AssertEqual(Releases . "/download/v1.2.3/" . Asset,
		SystemLayout_DownloadUrl(Spec, Releases . "/tag/v1.2.3", "dev"), "a release build downloads its own asset")
	AssertEqual(Releases . "/download/v0.0.0-dev.140/" . Asset,
		SystemLayout_DownloadUrl(Spec, Releases . "/tag/v0.0.0-dev.140", "main"))
	Stable := UpdateChannels_Ids()[1]
	AssertFalse(UpdateChannels_Field(Stable, "github_prerelease"))
	AssertEqual(Releases . "/latest/download/" . Asset,
		SystemLayout_DownloadUrl(Spec, "__BUNDLE_RELEASE_URL__", Stable), "a source run on the stable channel")
	for Channel in UpdateChannels_Ids()
		if UpdateChannels_Field(Channel, "github_prerelease")
			AssertEqual(Releases, SystemLayout_DownloadUrl(Spec, "", Channel),
				"a prerelease channel has no stable download URL: the releases page")
	AssertEqual(Releases, SystemLayout_DownloadUrl(Spec, "https://example.com/releases/tag/v1.2.3", "dev"),
		"a foreign release URL is not a tag of this repository")
	AssertEqual(Releases, SystemLayout_DownloadUrl(Spec, Releases . "/tag/v1/../x", "dev"))
	AssertTrue(_Updater_IsAllowedManualUrl(SystemLayout_DownloadUrl(Spec, Releases . "/tag/v1.2.3", "dev")),
		"the download passes the updater's repository allowlist")
}

/** Declined, opened, then not opened: only a failure is told, with its URL. */
_SLI_Download() {
	Opened := []
	Told := []
	Asked := []
	Url := (Spec) => "https://github.com/x/y/releases/download/v1/" . Spec["release_asset"]
	Confirm(Answer) => (Asset) => (Asked.Push(Asset), Answer)
	Tell(Message) {
		Told.Push(Message)
	}
	Open(Result) => (Target) => (Opened.Push(Target), Result)
	AssertFalse(SystemLayout_Download(Confirm(false), Open(true), Tell, Url), "a declined dialog opens nothing")
	AssertEqual(0, Opened.Length)
	AssertEqual(SystemLayout_Spec()["release_asset"], Asked[1], "the dialog names the asset")
	AssertTrue(SystemLayout_Download(Confirm(true), Open(true), Tell, Url))
	AssertEqual(1, Opened.Length)
	AssertContains(Opened[1], "/" . SystemLayout_Spec()["release_asset"])
	AssertEqual(0, Told.Length)
	AssertFalse(SystemLayout_Download(Confirm(true), Open(false), Tell, Url), "a download that did not open")
	AssertEqual(Format(t("dialog.system_layout.open_failed"), Opened[2]), Told[1], "the address is told")
	AssertContains(t("dialog.system_layout.confirm"), "{1}")
}

/** The driver never starts the elevated installer nor reads a shipped build. */
_SLI_NoElevatedInstaller() {
	Source := ""
	for Name in ["SystemLayout_Spec", "_SystemLayout_RegistryKlid", "SystemLayout_Status", "SystemLayout_DownloadUrl",
			"_SystemLayout_LiveDownloadUrl", "SystemLayout_MenuRows", "SystemLayout_Download"]
		Source .= _DriverFuncBody(Name)
	for Needle in ["*RunAs", "install_keyboard_layout.ps1", "add_user_keyboard_layout.ps1", "_VendorDir"]
		AssertFalse(InStr(Source, Needle), "the driver source names " . Needle)
}

Test("system layout install: the status follows the registry and System32", _SLI_Status)
Test("system layout install: the release asset comes from the shared description", _SLI_Spec)
Test("system layout install: one status row and the download command", _SLI_MenuRows)
Test("system layout install: the download URL follows the release and the channel", _SLI_DownloadUrl)
Test("system layout install: asks first, opens the asset, tells a failure", _SLI_Download)
Test("system layout install: the driver runs no elevated installer", _SLI_NoElevatedInstaller)
