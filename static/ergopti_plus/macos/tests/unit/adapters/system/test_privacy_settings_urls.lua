--- tests/unit/adapters/system/test_privacy_settings_urls.lua

--- ==============================================================================
--- MODULE: Privacy Settings URL Tests
--- DESCRIPTION:
--- Pins the version-aware privacy pane URL (ledger L29): macOS 26 refused the
--- legacy com.apple.preference.security form for Screen Recording, so from the
--- declared major version on the PrivacySecurity extension form is opened, and
--- every privacy pane of the driver comes from the one table.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local LEGACY = "x-apple.systempreferences:com.apple.preference.security?"
local EXTENSION = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"

local function load()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.privacy_settings"] = nil
	return require("adapters.privacy_settings")
end

helpers.describe("privacy settings URLs: one version-aware table", function()
	helpers.it("opens the extension form from macOS 26 on and the legacy form before", function()
		local Privacy = load()
		helpers.assert_eq(Privacy.url_for("screen_recording", 26), EXTENSION .. "Privacy_ScreenCapture")
		helpers.assert_eq(Privacy.url_for("screen_recording", 27), EXTENSION .. "Privacy_ScreenCapture")
		helpers.assert_eq(Privacy.url_for("screen_recording", 15), LEGACY .. "Privacy_ScreenCapture")
		helpers.assert_eq(Privacy.url_for("input_monitoring", nil), LEGACY .. "Privacy_ListenEvent")
		helpers.assert_eq(Privacy.url_for("accessibility", 26), EXTENSION .. "Privacy_Accessibility")
		helpers.assert_eq(Privacy.url_for("automation", 26), EXTENSION .. "Privacy_Automation")
	end)

	helpers.it("reads the running major version", function()
		local Privacy = load()
		local saved = rawget(_G, "hs")
		_G.hs = { host = { operatingSystemVersion = function() return { major = 26, minor = 6, patch = 2 } end } }
		local ok, url = pcall(Privacy.url, "screen_recording")
		_G.hs = saved
		helpers.assert_true(ok, tostring(url))
		helpers.assert_eq(url, EXTENSION .. "Privacy_ScreenCapture")
	end)

	helpers.it("refuses an unknown pane", function()
		local Privacy = load()
		helpers.assert_true(not pcall(Privacy.url_for, "camera", 26))
	end)

	helpers.it("leaves no privacy pane URL spelled outside the table", function()
		local root = helpers.driver_root()
		for _, relative in ipairs({ "adapters/screen_capture.lua", "adapters/accessibility_permission.lua",
			"platform/remap/onboarding.lua", "modules/llm/agent_connectors.lua" }) do
			local src = assert(SourceFile.read(root .. "/" .. relative), relative)
			helpers.assert_true(src:find("?Privacy_", 1, true) == nil, relative .. " spells a privacy pane URL")
		end
	end)
end)
