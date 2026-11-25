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

--- An i18n double answering "<key>" with a {1} slot, and {2}/{3} for the
--- package wording.
local I18N = { get = function(key)
	if key == "startup.linux_gui_stack_windows_package_body" or key == "startup.linux_gui_stack_lgi_other_lua" then
		return "<" .. key .. ":{1}|{2}|{3}>"
	end
	return "<" .. key .. ":{1}>"
end }

--- The /etc/os-release of the field report's machine.
local ARCH_OS_RELEASE = 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\nBUILD_ID=rolling\n'


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
--- @return integer|nil status, table lines, table sent, table reported
local function run(deps)
	local Stack = helpers.load_module("core.ui.engine.gui_stack")
	local lines, sent, reported = {}, {}, {}
	deps.i18n = I18N
	if deps.os_release == nil then deps.os_release = "" end
	deps.file_exists = deps.file_exists or function() return false end
	deps.status = { report = function(problem, options)
		reported[#reported + 1] = problem
		if options.notifier then options.notifier.send(problem.body, { title = problem.title, level = "error", persistent = true }) end
		return true
	end }
	deps.print = function(line) lines[#lines + 1] = line end
	deps.notifier = { send = function(body, opts) sent[#sent + 1] = { body = body, opts = opts } end }
	deps.logger = { error = function() end, warn = function() end, debug = function() end }
	return Stack.check_at_start(deps), lines, sent, reported
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
		helpers.assert_true(sent[1].opts.persistent, "the notice stays until closed")
	end)

	helpers.it("names Arch's LuaJIT lgi package and command when lgi is absent", function()
		local status, lines, _, reported = run({ indicator = indicator(true), os_release = ARCH_OS_RELEASE,
			load_lgi = function() return false, "module 'lgi' not found" end })
		helpers.assert_nil(status)
		helpers.assert_eq(lines[2], "<startup.linux_gui_stack_windows_package_body:lgi (Lua GObject Introspection)"
			.. "|lua51-lgi|sudo pacman -S --needed lua51-lgi>")
		helpers.assert_eq(#reported, 1, "the problem stays in the tray")
		helpers.assert_eq(reported[1].code, "windows_lgi")
		helpers.assert_eq(reported[1].label, "<startup.linux_gui_stack_windows_label:{1}>")
	end)

	helpers.it("says that an lgi built for Lua 5.4 does not serve LuaJIT (field report, Arch's lua-lgi)", function()
		local _, lines = run({ indicator = indicator(true), os_release = ARCH_OS_RELEASE,
			file_exists = function(path) return path == "/usr/lib/lua/5.4/lgi/corelgilua51.so" end,
			load_lgi = function() return false, "module 'lgi' not found" end })
		helpers.assert_true(lines[2]:find("<startup.linux_gui_stack_lgi_other_lua:5.4|lua51-lgi|{3}>", 1, true) ~= nil,
			lines[2])
	end)

	helpers.it("names the WebKitGTK typelib package of Debian and Ubuntu", function()
		local _, lines = run({ indicator = indicator(true), load_lgi = lgi_with({ WebKit2 = "4.0" }),
			os_release = 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n' })
		helpers.assert_eq(lines[2], "<startup.linux_gui_stack_windows_package_body:WebKitGTK 4.1"
			.. "|gir1.2-webkit2-4.1|sudo apt install gir1.2-webkit2-4.1>")
	end)

	helpers.it("names Leap's lgi, which is not Tumbleweed's", function()
		-- Leap 15.6 has lua51-lgi and no luajit-lgi: the Tumbleweed name found nothing.
		local Stack = helpers.load_module("core.ui.engine.gui_stack")
		local i18n = { get = function(key) return "<" .. key .. ":{2}>" end }
		local function body(os_release)
			return Stack.windows_body({ i18n = i18n, os_release = os_release, file_exists = function() return false end },
				Stack.LGI_COMPONENT, "lgi")
		end
		helpers.assert_contains(body('ID="opensuse-leap"\nID_LIKE="suse opensuse"\nVERSION_ID="15.6"\n'), "lua51-lgi")
		helpers.assert_contains(body('ID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'), "luajit-lgi")
		-- VERSION_ID, PRETTY_NAME and ID_LIKE never stand for ID.
		helpers.assert_contains(body('VERSION_ID="15.6"\nID_LIKE="opensuse-leap suse"\nID=sles\n'), "luajit-lgi")
		local fh = assert(io.open(helpers.driver_root() .. "/install.sh", "r"))
		local installer = fh:read("*a")
		fh:close()
		helpers.assert_true(installer:find('zypper:lgi)   echo "luajit-lgi lua51-lgi"', 1, true) ~= nil,
			"install.sh tries both openSUSE names")
	end)

	helpers.it("maps derivatives through ID_LIKE", function()
		local Stack = helpers.load_module("core.ui.engine.gui_stack")
		helpers.assert_eq(Stack.distro_family('ID=endeavouros\nID_LIKE=arch\n'), "arch")
		helpers.assert_eq(Stack.distro_family('ID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'), "suse")
		helpers.assert_eq(Stack.distro_family('ID=linuxmint\nID_LIKE="ubuntu debian"\n'), "debian")
		helpers.assert_nil(Stack.distro_family('ID=nixos\n'))
	end)

	helpers.it("names the same first package as install.sh for every manager", function()
		local Stack = helpers.load_module("core.ui.engine.gui_stack")
		local fh = assert(io.open(helpers.driver_root() .. "/install.sh", "r"))
		local installer = fh:read("*a")
		fh:close()
		for family, manager in pairs(Stack.FAMILY_MANAGERS) do
			for what, packages in pairs(Stack.HOST_PACKAGES) do
				local first = installer:match("\n%s*" .. manager .. ":" .. what .. "%)%s*echo \"([^\" ]+)")
				helpers.assert_eq(packages[family], first, manager .. ":" .. what)
			end
		end
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
		local Indicator = helpers.load_module("tray.adapters.appindicator")
		helpers.assert_eq(Indicator.GTK_COMPONENT, "GTK 3")
		helpers.assert_eq(Indicator.INDICATOR_COMPONENT, "libayatana-appindicator3")
		helpers.assert_eq(type(Indicator.missing_component), "function")
	end)

	helpers.it("a --tray launch runs the check before the icon (owned-runtimes-gui-stack)", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local check = source:find('require("core.ui.engine.gui_stack").check_at_start(', 1, true)
		local icon = source:find("tray_menu.start()", 1, true)
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
			for _, key in ipairs({ "startup.linux_gui_stack_windows_package_body", "startup.linux_gui_stack_lgi_other_lua" }) do
				for _, slot in ipairs({ "{1}", "{2}" }) do
					helpers.assert_true(type(catalogue[key]) == "string" and catalogue[key]:find(slot, 1, true) ~= nil,
						code .. " " .. key .. " " .. slot)
				end
			end
			helpers.assert_true(catalogue["startup.linux_gui_stack_windows_package_body"]:find("{3}", 1, true) ~= nil,
				code .. " names the command")
			helpers.assert_eq(type(catalogue["startup.linux_gui_stack_windows_label"]), "string", code)
		end
	end)
end)
