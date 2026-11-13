--- tests/unit/core/lifecycle/test_gui_stack.lua

--- ==============================================================================
--- MODULE: Desktop Toolkit Start Check
--- DESCRIPTION:
--- GTK 3, libayatana-appindicator3, lgi and WebKitGTK 4.1 are the host's (the
--- owned-runtimes registry decides them SYS). Without the tray libraries a
--- --tray launch ran with no icon and said so only in the log; without
--- WebKitGTK 4.1 the windows never opened and nothing said why. These cases pin
--- the start check: the tray refuses in words with EX_UNAVAILABLE, the windows
--- are told once, and WebKitGTK is required at version 4.1 exactly.
--- ==============================================================================

local helpers = require("tests.helpers")

--- An i18n double answering "<key>" with a {1} slot.
local I18N = { get = function(key) return "<" .. key .. ":{1}>" end }

--- A tray double.
--- @param available boolean
--- @param missing string|nil
--- @return table
local function indicator(available, missing)
	return { is_available = function() return available end, missing_component = function() return missing end }
end

--- An lgi double whose require answers only for the given namespace versions.
--- @param versions table { ["WebKit2"] = "4.1", ... }
--- @return function load_lgi
local function lgi_with(versions)
	return function()
		return true, { require = function(name, version)
			if versions[name] ~= version then error("Typelib file for namespace '" .. name .. "', version '"
				.. tostring(version) .. "' not found") end
			return {}
		end }
	end
end

--- Runs the start check and records what the user is told.
--- @param deps table
--- @return integer|nil status, table lines, table sent
local function run(deps)
	local Stack = helpers.load_module("infra.gui_stack")
	local lines, sent = {}, {}
	deps.i18n = I18N
	deps.print = function(line) lines[#lines + 1] = line end
	deps.notifier = { send = function(body, opts) sent[#sent + 1] = { body = body, opts = opts } end }
	deps.logger = { error = function() end, warn = function() end, debug = function() end }
	return Stack.check_at_start(deps), lines, sent
end

helpers.describe("gui_stack: the desktop toolkit is checked at start", function()

	helpers.it("refuses a tray launch without libayatana-appindicator3, in words (owned-runtimes-gui-stack)", function()
		local status, lines, sent = run({ indicator = indicator(false, "libayatana-appindicator3"),
			load_lgi = lgi_with({ WebKit2 = "4.1" }) })
		helpers.assert_eq(status, 69, "EX_UNAVAILABLE: no restart can install a library")
		helpers.assert_eq(lines[1], "<startup.linux_gui_stack_title:{1}>")
		helpers.assert_eq(lines[2], "<startup.linux_gui_stack_tray_body:libayatana-appindicator3>")
		helpers.assert_eq(#sent, 1)
		helpers.assert_eq(sent[1].opts.level, "error")
	end)

	helpers.it("names GTK 3 when the tray cannot load it (owned-runtimes-gui-stack)", function()
		local status, lines = run({ indicator = indicator(false, "GTK 3"), load_lgi = lgi_with({ WebKit2 = "4.1" }) })
		helpers.assert_eq(status, 69)
		helpers.assert_eq(lines[2], "<startup.linux_gui_stack_tray_body:GTK 3>")
	end)

	helpers.it("starts without a display, which is a session, not a missing package (owned-runtimes-gui-stack)", function()
		local status, lines = run({ indicator = indicator(false, nil), load_lgi = lgi_with({ WebKit2 = "4.1" }) })
		helpers.assert_nil(status)
		helpers.assert_eq(#lines, 0)
	end)

	helpers.it("tells once and starts when lgi is absent (owned-runtimes-gui-stack)", function()
		local status, lines, sent = run({ indicator = indicator(true),
			load_lgi = function() return false, "module 'lgi' not found" end })
		helpers.assert_nil(status, "hotstrings and the tray still work")
		helpers.assert_eq(lines[2], "<startup.linux_gui_stack_windows_body:lgi (Lua GObject Introspection)>")
		helpers.assert_eq(#sent, 1)
		helpers.assert_eq(sent[1].opts.level, "warning")
	end)

	helpers.it("requires WebKitGTK 4.1 by version, not any WebKit2 (owned-runtimes-gui-stack)", function()
		local status, lines = run({ indicator = indicator(true), load_lgi = lgi_with({ WebKit2 = "4.0" }) })
		helpers.assert_nil(status)
		helpers.assert_eq(lines[2], "<startup.linux_gui_stack_windows_body:WebKitGTK 4.1>")
	end)

	helpers.it("says nothing when every component loads (owned-runtimes-gui-stack)", function()
		local status, lines, sent = run({ indicator = indicator(true), load_lgi = lgi_with({ WebKit2 = "4.1" }) })
		helpers.assert_nil(status)
		helpers.assert_eq(#lines, 0)
		helpers.assert_eq(#sent, 0)
	end)

	helpers.it("the tray binding names the library it could not load (owned-runtimes-gui-stack)", function()
		local Indicator = helpers.load_module("platform.tray.appindicator")
		helpers.assert_eq(Indicator.GTK_COMPONENT, "GTK 3")
		helpers.assert_eq(Indicator.INDICATOR_COMPONENT, "libayatana-appindicator3")
		helpers.assert_eq(type(Indicator.missing_component), "function")
	end)

	helpers.it("a --tray launch runs the check before the icon (owned-runtimes-gui-stack)", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local check = source:find('require("infra.gui_stack").check_at_start(', 1, true)
		local icon = source:find('tray_menu.setIcon({ title = "Ergopti" })', 1, true)
		helpers.assert_true(check ~= nil and icon ~= nil and check < icon, "the start check precedes the tray icon")
	end)

	helpers.it("every locale words the three refusal texts with the component slot (owned-runtimes-gui-stack)", function()
		local Json = require("core.text.engine.json")
		for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no",
			"pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
			local fh = assert(io.open(helpers.driver_root() .. "/../_shared/core/i18n/data/locales/" .. code .. ".json", "r"))
			local catalogue = Json.decode(fh:read("*a"))
			fh:close()
			helpers.assert_eq(type(catalogue["startup.linux_gui_stack_title"]), "string", code)
			for _, key in ipairs({ "startup.linux_gui_stack_tray_body", "startup.linux_gui_stack_windows_body" }) do
				helpers.assert_true(type(catalogue[key]) == "string" and catalogue[key]:find("{1}", 1, true) ~= nil,
					code .. " " .. key)
			end
		end
	end)
end)
