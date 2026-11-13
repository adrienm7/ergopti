--- tests/unit/modules/shortcuts/apps/test_app_cloner_no_browser_host.lua

--- ==============================================================================
--- MODULE: App Cloner web clones need no browser (owned-runtimes row "Microsoft
--- Edge, Chrome, Brave")
--- DESCRIPTION:
--- A PWA clone hosts its URL in its own WKWebView launcher. The clone script
--- still threaded a browser path (always empty) into the Dock writer, wrote
--- Space hint files only when that path was set, and its dialogs told the user
--- the clone ran in Edge or "a browser --app=URL". Nothing looks for or starts
--- a browser now, and no user-facing App Cloner string says one is needed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads one file under the driver root.
--- @param relative string
--- @return string text
local function read(relative)
	local file = assert(io.open(helpers.driver_root() .. relative, "rb"), relative)
	local text = file:read("*a")
	file:close()
	return text
end

local RESOURCES = "apps/App Cloner.app/Contents/Resources/"

-- Spellings of the retired browser host.
local BROWSER_SPELLINGS = { "PWA_BROWSER", "pwa_browser", "browser_app_path", "--app=", "Edge.app",
	"Google Chrome.app", "Brave Browser.app" }

helpers.describe("App Cloner web clones", function()
	helpers.it("never look for or start a browser (app-cloner-no-browser)", function()
		local script = read(RESOURCES .. "clone_app.sh")
		helpers.assert_true(script:find("exec \"$CLONE_PYTHON\" \"$BUNDLE_RES/pwa_launcher.py\"", 1, true) ~= nil,
			"the PWA clone is the WKWebView launcher")
		for _, relative in ipairs({ "clone_app.sh", "ShortcutBuilder.applescript" }) do
			local text = read(RESOURCES .. relative)
			for _, spelling in ipairs(BROWSER_SPELLINGS) do
				helpers.assert_nil(text:find(spelling, 1, true), relative .. " still names " .. spelling)
			end
		end
	end)

	helpers.it("tells the user no browser is involved, in every locale (app-cloner-no-browser)", function()
		local JsonCodec = require("adapters.json_codec")
		for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
			"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local catalogue = assert(JsonCodec.decode(read("../_shared/core/i18n/data/locales/" .. code .. ".json")), code)
			for key, value in pairs(catalogue) do
				if key:find("^apps%.cloner%.") then
					helpers.assert_nil(value:find("--app=", 1, true), code .. " " .. key)
					helpers.assert_nil(value:find("Edge", 1, true), code .. " " .. key)
				end
			end
		end
	end)
end)
