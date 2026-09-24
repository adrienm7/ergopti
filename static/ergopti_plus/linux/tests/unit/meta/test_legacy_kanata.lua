--- tests/unit/meta/test_legacy_kanata.lua

--- ==============================================================================
--- MODULE: The Kanata Unit Of An Earlier Install Is Retired
--- DESCRIPTION:
--- Earlier installs enabled a kanata user unit that grabbed the keyboard at
--- login. With the tap-holds now in the daemon, that kanata would remap the
--- keyboard before the daemon sees it and every tap-hold would apply twice. The
--- updater does not run install.sh, so the daemon has to retire the unit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Legacy = require("platform.remap.legacy_kanata")

local function write(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

local function exists(path)
	local fh = io.open(path, "r")
	if fh then fh:close() end
	return fh ~= nil
end

local function paths()
	local unit, kbd = os.tmpname(), os.tmpname()
	os.remove(unit)
	return unit, kbd
end

helpers.describe("legacy kanata retirement", function()

	helpers.it("stops, disables and removes the unit Ergopti wrote, and its config", function()
		local unit, kbd = paths()
		write(unit, "[Unit]\n" .. Legacy.ERGOPTI_UNIT_DESCRIPTION .. "\n[Service]\nExecStart=kanata\n")
		local commands = {}
		local result = Legacy.retire({ unit_path = unit, kbd_path = kbd,
			run = function(cmd) commands[#commands + 1] = cmd; return true end })
		helpers.assert_eq(result, "retired")
		helpers.assert_true(commands[1]:find("disable --now kanata.service", 1, true) ~= nil,
			"stopped now, not only at the next login")
		helpers.assert_true(not exists(unit), "the unit cannot start it again")
		helpers.assert_true(not exists(kbd))
	end)

	helpers.it("still removes the unit when no user bus can stop it", function()
		local unit, kbd = paths()
		write(unit, Legacy.ERGOPTI_UNIT_DESCRIPTION .. "\n")
		helpers.assert_eq(Legacy.retire({ unit_path = unit, kbd_path = kbd, run = function() return false end }),
			"retired")
		helpers.assert_true(not exists(unit))
	end)

	helpers.it("leaves a kanata the user set up alone", function()
		local unit, kbd = paths()
		write(unit, "[Unit]\nDescription=my kanata\n")
		local ran = false
		helpers.assert_eq(Legacy.retire({ unit_path = unit, kbd_path = kbd,
			run = function() ran = true; return true end }), "foreign")
		helpers.assert_true(exists(unit) and not ran, "not stopped, not removed")
		os.remove(unit)
		os.remove(kbd)
	end)

	helpers.it("does nothing when there is no unit", function()
		local unit, kbd = paths()
		helpers.assert_eq(Legacy.retire({ unit_path = unit, kbd_path = kbd,
			run = function() error("nothing to run") end }), "absent")
		os.remove(kbd)
	end)

end)

helpers.describe("legacy kanata retirement: the daemon runs it before taking the keyboard", function()
	helpers.it("is called in main() before the keyboard device is resolved", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		local retire = src:find('require("platform.remap.legacy_kanata").retire', 1, true)
		local resolve = src:find("dev_finder.find_keyboard()", 1, true)
		helpers.assert_true(retire ~= nil, "the daemon retires the legacy unit")
		helpers.assert_true(resolve ~= nil and retire < resolve,
			"before the keyboard is chosen: a running kanata would hold it first")
	end)
end)
