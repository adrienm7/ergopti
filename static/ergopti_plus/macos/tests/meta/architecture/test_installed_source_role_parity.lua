--- tests/meta/architecture/test_installed_source_role_parity.lua

--- ==============================================================================
--- MODULE: Installed Source Role Parity Guard
--- DESCRIPTION:
--- Keeps the three spellings of the owned runtime's capture role identical: the
--- Lua task port that requests it, the native module that spawns the launcher
--- with it, and the launcher that dispatches it. It also pins the single Console
--- owner decision (ADR 011, decision 8): the Lua side must never spawn a Console.
---
--- ROOT CAUSE ENCODED: the role string was written in three languages and the
--- launcher's dispatch was missing altogether, so the native module would have
--- started a launcher that opened the GUI instead of the capture bridge.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

--- Reads a driver-relative source file.
--- @param relative string Path under the driver root.
--- @return string source
local function read(relative)
	return assert(SourceFile.read(helpers.driver_root() .. "/" .. relative), relative)
end

local ROLE = "--installed-physical-source"

helpers.describe("installed source role: one spelling in three languages", function()
	helpers.it("is the Lua port's stream role, the bridge's role and the launcher's dispatch", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.installed_physical_source"] = nil
		helpers.assert_eq(require("adapters.installed_physical_source").STREAM_ROLE, ROLE)
		helpers.assert_true(read("launcher/Sources/ErgoptiPlus/InstalledPhysicalSourceBridge.swift")
			:find('static let role = "' .. ROLE .. '"', 1, true) ~= nil)
		local main = read("launcher/Sources/ErgoptiPlus/main.swift")
		helpers.assert_true(main:find("InstalledPhysicalSourceBridge.handles(arguments: CommandLine.arguments)", 1, true) ~= nil,
			"the launcher must dispatch the bridge before it boots the GUI")
		helpers.assert_true(main:find("Darwin.exit(InstalledPhysicalSourceBridge.run())", 1, true) ~= nil)
		local gui = assert(main:find("Write MJConfigFile via CFPreferences", 1, true), "the GUI boot marker moved")
		local dispatch = main:find("InstalledPhysicalSourceBridge.handles", 1, true)
		helpers.assert_true(dispatch < gui, "the dispatch must precede the GUI boot")
	end)

	helpers.it("is the role the native module starts the launcher with", function()
		local file = assert(io.open(helpers.driver_root() .. "/../../../tools/build/owned-runtime-native/installed_physical_source.mm", "rb"))
		local native = file:read("*a")
		file:close()
		helpers.assert_true(native:find('@"' .. ROLE .. '"', 1, true) ~= nil)
	end)
end)

helpers.describe("installed source role: the Lua side owns no Console", function()
	helpers.it("never names the Console executable outside the install checks", function()
		local owner = read("platform/remap/runtime_owner.lua")
		local ports = read("adapters/runtime_owner_ports.lua")
		local capture = read("adapters/runtime_capture_port.lua")
		local source = read("adapters/installed_physical_source.lua")
		for name, text in pairs({ owner = owner, ports = ports, capture = capture, source = source }) do
			helpers.assert_true(text:find("OWNED.CONSOLE", 1, true) == nil or name == "owner",
				name .. " must not reference the Console executable")
			helpers.assert_true(text:find("owner-pid", 1, true) == nil, name .. " must not start a Console with an owner PID")
			helpers.assert_true(text:find("XDG_CONFIG_HOME", 1, true) == nil, name .. " must not configure a Console")
		end
		-- The owner may only check that the Console is installed.
		local uses = 0
		for _ in owner:gmatch("%.CONSOLE%f[%W]") do uses = uses + 1 end
		helpers.assert_eq(uses, 1, "the owner names the Console only in its installed-files check")
	end)
end)
