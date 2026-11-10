--- tests/unit/adapters/compositor_focus/test_compositor_focus_assets.lua

--- ==============================================================================
--- MODULE: Compositor focus — the desktop-side files agree with the daemon
--- DESCRIPTION:
--- The GNOME Shell extension, the KWin script, the worker and the installer
--- each spell the bus name, the interface or the package identity, because
--- JavaScript and bash cannot read the Lua owner. A rename on one side would
--- leave every call unanswered and the focus silently unknown, so each copy is
--- pinned here to adapters/compositor_focus.lua and to the package metadata.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read(relative)
	local handle = assert(io.open(helpers.driver_root() .. "/" .. relative, "rb"), relative)
	local text = handle:read("*a")
	handle:close()
	return text
end

local function constant(text, name)
	return text:match("const " .. name .. " = '([^']+)';")
end

helpers.describe("compositor_focus: shipped desktop files", function()
	helpers.it("(wayland-desktop-focus) the extension and the KWin script call the daemon's name", function()
		local Focus = helpers.load_module("adapters.compositor_focus")
		for _, path in ipairs({ "desktop_focus/gnome/extension.js", "desktop_focus/kwin/contents/code/main.js" }) do
			local text = read(path)
			helpers.assert_eq(constant(text, "BUS_NAME"), Focus.BUS_NAME, path)
			helpers.assert_eq(constant(text, "OBJECT_PATH"), Focus.OBJECT_PATH, path)
			helpers.assert_eq(constant(text, "INTERFACE"), Focus.INTERFACE, path)
			helpers.assert_true(text:find("'Activated'", 1, true) ~= nil and text:find("'Cleared'", 1, true) ~= nil, path)
		end
		local worker = read("adapters/compositor_focus_worker.lua")
		helpers.assert_true(worker:find('<interface name="' .. Focus.INTERFACE .. '">', 1, true) ~= nil,
			"the worker exports the interface the desktops call")
	end)

	helpers.it("(wayland-desktop-focus) the installer and the worker name the shipped packages", function()
		local json = require("json")
		local gnome = json.decode(read("desktop_focus/gnome/metadata.json"))
		local kwin = json.decode(read("desktop_focus/kwin/metadata.json"))
		local installer = read("install/compositor_focus.sh")
		helpers.assert_eq(installer:match('\nGNOME_FOCUS_UUID="([^"]+)"'), gnome.uuid)
		helpers.assert_eq(installer:match('\nKWIN_FOCUS_ID="([^"]+)"'), kwin.KPlugin.Id)
		helpers.assert_eq(read("adapters/compositor_focus_worker.lua"):match('KWIN_SCRIPT_ID = "([^"]+)"'), kwin.KPlugin.Id)
		helpers.assert_eq(kwin["X-Plasma-MainScript"], "code/main.js")
		helpers.assert_eq(kwin.KPackageStructure, "KWin/Script")
		-- GNOME refuses to load an extension that does not list the running
		-- version; the module syntax the extension uses needs 45 or later.
		helpers.assert_eq(gnome["shell-version"][1], "45")
	end)
end)
