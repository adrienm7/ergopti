--- tools/lib/layout_export_host_step.lua

--- ==============================================================================
--- MODULE: Layout Editor Export Step, as the App Hosts Run It
--- DESCRIPTION:
--- Runs one export step through the path the macOS and Linux app windows use:
--- the shared manager bridge's lua_export action, answered by the shared
--- export step (_shared/layouts/engine/composer/export_step.lua) with the
--- layout defaults' bounds, under whatever Lua runs this file (Lua 5.4 like
--- Hammerspoon, or LuaJIT like the Linux daemon). The step's input is read
--- from stdin as JSON text and its result written to stdout as the bridge
--- pushed it, so a test can compare the files built from it with the page's.
--- USAGE: lua layout_export_host_step.lua <shared root> <read|xkb> < input.json
--- ==============================================================================

local root, step = arg[1], arg[2]
if type(root) ~= "string" or type(step) ~= "string" then
	io.stderr:write("usage: layout_export_host_step.lua <shared root> <read|xkb> < input.json\n")
	os.exit(2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
-- LuaJIT has no utf8 library; the Linux daemon installs the shared shim first.
if not utf8 then require("core.lifecycle.engine.compat.utf8").install() end

local Json = require("core.text.engine.json")
local ManagerBridge = require("layouts.engine.manager_bridge")
local ExportStep = require("layouts.engine.composer.export_step")

local defaults_file = assert(io.open(root .. "/layouts/data/defaults.json", "rb"))
local settings = assert(ExportStep.settings(Json.decode(defaults_file:read("*a"))))
defaults_file:close()

local pushed = nil
local controller = ManagerBridge.new({
	editor_window = true,
	-- The registries' source_export_step (macOS and Linux layout_registry.lua).
	registry = {
		snapshot = function() return { platform = "test", installed = {} } end,
		refresh = function(on_done) on_done({}) end,
		source_export_step = function(payload, on_done)
			on_done(ExportStep.run(settings, payload.step, payload.input))
		end,
	},
	push = function(name, payload)
		pushed = { name = name, payload = payload }
		return true
	end,
	strings = function() return {} end,
	open_url = function() end,
	close = function() end,
	log = function() end,
})

local handled = controller.on_message({ action = "lua_export", request = 1, step = step, input = io.read("*a") })
if not handled or not pushed or pushed.name ~= "luaExportResult" then
	io.stderr:write("the bridge refused the export step\n")
	os.exit(1)
end
if pushed.payload.ok ~= true then
	io.stderr:write(tostring(pushed.payload.code) .. ": " .. tostring(pushed.payload.detail) .. "\n")
	os.exit(1)
end
io.write(pushed.payload.output)
