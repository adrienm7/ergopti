--- tests/unit/modules/updater/check/test_appimage_release_notice.lua

--- ==============================================================================
--- MODULE: AppImage Release Announcement
--- DESCRIPTION:
--- An AppImage never replaces itself, so the notice announcing a new release
--- names its own way to update and the release page to download it from. An
--- installation that may replace itself keeps the plain announcement.
--- ==============================================================================

local helpers = require("tests.helpers")
local InstallOrigin = require("modules.updater.install_origin")

local PAGE = "https://example.invalid/owner/repo/releases"

--- A locale lookup that names the key it was asked for.
local function get(key)
	if key == "updater.tray_new_version_body" then return "Version {1} is available." end
	return "<" .. key .. ">"
end

helpers.describe("updater (linux): the AppImage release announcement", function()
	helpers.it("(appimage-update-announced) an AppImage notice names the download page", function()
		local body = InstallOrigin.release_notice({ tag = "v1.4.0" }, "appimage", get, PAGE)
		helpers.assert_eq(body, "Version v1.4.0 is available. <changelog_window.install_blocked_appimage> "
			.. PAGE .. "/tag/v1.4.0")
	end)

	helpers.it("(appimage-update-announced) a standalone notice stays the plain announcement", function()
		helpers.assert_eq(InstallOrigin.release_notice({ tag = "v1.4.0" }, "standalone", get, PAGE),
			"Version v1.4.0 is available.")
	end)

	helpers.it("(appimage-update-announced) only a kind that may replace itself or an AppImage checks", function()
		helpers.assert_true(InstallOrigin.checks_for_releases("standalone"))
		helpers.assert_true(InstallOrigin.checks_for_releases("appimage"))
		helpers.assert_eq(InstallOrigin.checks_for_releases("package"), false)
		helpers.assert_eq(InstallOrigin.checks_for_releases("flatpak"), false)
	end)

	helpers.it("(appimage-update-announced) a refused kind's notice without a page is a caller bug", function()
		helpers.assert_eq(pcall(InstallOrigin.release_notice, { tag = "v1.4.0" }, "appimage", get, nil), false)
	end)
end)
