--- tests/unit/infra/test_input_access.lua

--- ==============================================================================
--- MODULE: Input Access Failure — the first launch after install
--- DESCRIPTION:
--- install.sh grants the input and uinput groups, and they only apply from the
--- next session. The first launch therefore always met an unreadable keyboard:
--- it printed to a console nobody sees, exited 1, and systemd restarted it every
--- three seconds with no tray icon and nothing on screen. These cases pin the
--- replacement: a translated notification, and an exit status the unit does not
--- retry.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads a file from the driver tree.
--- @param rel string
--- @return string
local function read(rel)
	local fh = assert(io.open(helpers.driver_root() .. "/" .. rel, "r"))
	local text = fh:read("*a")
	fh:close()
	return text
end

helpers.describe("input_access: telling the user", function()

	helpers.it("prints an absolute quoted repair command (input-access-repair-path)", function()
		local Access = helpers.load_module("infra.input_access")
		local lines = {}
		Access.report({
			i18n = { init = function() end, get = function(key)
				return key == Access.BODY_KEY and "Repair: {1}" or "Title"
			end },
			script_dir = "/opt/Ergopti user's % directory",
			print = function(line) lines[#lines + 1] = line end,
		}, "denied")
		helpers.assert_eq(lines[2], "Repair: bash '/opt/Ergopti user'\\''s % directory/install.sh' --setup-perms")
	end)

	helpers.it("notifies with the translated title and body", function()
		local Access = helpers.load_module("infra.input_access")
		local sent = {}
		local fake_i18n = {
			init = function() end,
			get = function(key) return "<" .. key .. ">" end,
		}
		local fake_notifier = { send = function(body, opts) sent[#sent + 1] = { body = body, opts = opts } end }
		local status = Access.report({ i18n = fake_i18n, notifier = fake_notifier, print = function() end },
			"/dev/input/event3")
		helpers.assert_eq(#sent, 1, "exactly one on-screen notification")
		helpers.assert_eq(sent[1].body, "<startup.linux_input_access_body>")
		helpers.assert_eq(sent[1].opts.title, "<startup.linux_input_access_label>")
		helpers.assert_eq(sent[1].opts.level, "error")
		helpers.assert_eq(status, 78, "EX_CONFIG, the status the unit refuses to retry")
	end)

	helpers.it("ships the message in every locale", function()
		-- A missing key renders as the raw key on screen, in the one message a
		-- new user reads first.
		local locales = { "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
			"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }
		local Paths = helpers.load_module("infra.paths")
		for _, code in ipairs(locales) do
			local fh = assert(io.open(Paths.shared("data/locales/" .. code .. ".json"), "r"))
			local text = fh:read("*a")
			fh:close()
			for _, key in ipairs({ "startup.linux_input_access_title", "startup.linux_input_access_body", "startup.linux_input_access_label" }) do
				helpers.assert_true(text:find('"' .. key .. '": "', 1, true) ~= nil,
					code .. ".json lacks " .. key)
			end
		end
	end)

	helpers.it("still explains itself on the console when there is no notifier", function()
		local Access = helpers.load_module("infra.input_access")
		local lines = {}
		Access.report({ print = function(line) lines[#lines + 1] = line end }, "detail")
		helpers.assert_true(#lines >= 2, "the console gets both the cause and the fix")
		helpers.assert_contains(lines[1], "detail")
	end)

end)

helpers.describe("input_access: a tray launch stays visible", function()

	--- A tray adapter double that records what the user would see.
	local function fake_tray(backend)
		local tray = { calls = {}, menu = nil, pumps = 0, destroyed = false }
		function tray.setIcon(opts) tray.calls[#tray.calls + 1] = opts end
		function tray.getBackend() return backend end
		function tray.setFallbackMenu(title, quit_label, on_quit)
			tray.menu = { { title = title, disabled = true }, { title = quit_label, fn = on_quit } }
		end
		function tray.pump() tray.pumps = tray.pumps + 1 end
		function tray.destroy() tray.destroyed = true end
		return tray
	end

	helpers.it("keeps the icon, names the failure and exits only on Quit", function()
		-- The AppImage catalogue launches the app without the input group and
		-- fails it when no window or tray icon appears; exiting after the
		-- notification left nothing on screen.
		local Access = helpers.load_module("infra.input_access")
		local tray = fake_tray("appindicator")
		local naps = 0
		local status = Access.report({
			i18n = { init = function() end, get = function(key)
				return key == "menu.global.quit" and "🚪 Leave" or "<" .. key .. ">"
			end },
			tray = tray,
			print = function() end,
			sleep_ms = function()
				naps = naps + 1
				if naps == 3 then tray.menu[2].fn() end
			end,
		}, "denied")
		helpers.assert_eq(status, 78)
		helpers.assert_eq(#tray.calls, 1, "the icon is shown")
		helpers.assert_eq(tray.menu[1].title, "<startup.linux_input_access_label>")
		helpers.assert_eq(tray.menu[1].disabled, true)
		helpers.assert_eq(tray.menu[2].title, "Leave", "the Quit row drops the menu emoji")
		helpers.assert_eq(tray.pumps, 3, "the menu is served until Quit is clicked")
		helpers.assert_true(tray.destroyed, "the icon is removed before the exit")
	end)

	helpers.it("returns at once when no tray backend can show an icon", function()
		local Access = helpers.load_module("infra.input_access")
		local tray = fake_tray(nil)
		local status = Access.report({ tray = tray, print = function() end,
			sleep_ms = function() error("must not wait without an icon") end }, "denied")
		helpers.assert_eq(status, 78)
		helpers.assert_eq(tray.menu, nil)
	end)

end)

helpers.describe("input_access: only a denied node means re-login", function()

	helpers.it("recognises EACCES and nothing else", function()
		local Access = helpers.load_module("infra.input_access")
		local denied = function() return nil, "Permission denied", 13 end
		local absent = function() return nil, "No such file or directory", 2 end
		helpers.assert_eq(Access.is_denied("/dev/input/event3", denied), true)
		helpers.assert_eq(Access.is_denied("/dev/input/event99", absent), false,
			"a mistyped --device must not be told to log out and back in")
		local fh = io.open(os.tmpname(), "rb")
		local readable = function() return fh end
		helpers.assert_eq(Access.is_denied("/tmp/x", readable), false)
	end)

end)

helpers.describe("input_access: the service does not loop on it", function()

	helpers.it("declares the exit status in RestartPreventExitStatus", function()
		local Access = helpers.load_module("infra.input_access")
		local unit = read("ergopti-hotstrings.service")
		local declared = unit:match("\nRestartPreventExitStatus=(%d+)")
		helpers.assert_eq(tonumber(declared), Access.EXIT_ACCESS,
			"systemd would restart the daemon every 3 s and repeat the notification")
	end)

	helpers.it("is what the daemon reports at every access check", function()
		local src = read("ergopti_hotstrings.lua")
		local _, sites = src:gsub('input_access"%)%.report%(', "")
		local _, named = src:gsub("InputAccess%.report%(", "")
		helpers.assert_eq(sites + named, 3,
			"the absent keyboard, the unreadable keyboard and the unwritable /dev/uinput must all report through input_access")
		local _, held = src:gsub("tray = opts%.tray and tray_menu or nil", "")
		helpers.assert_eq(held, 2, "both access exits must keep the tray icon up when --tray is set")
		helpers.assert_true(src:find("InputAccess.is_denied(device)", 1, true) ~= nil,
			"the keyboard check must distinguish a denied node from an absent one")
	end)

end)
