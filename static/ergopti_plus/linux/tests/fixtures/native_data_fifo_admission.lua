--- tests/fixtures/native_data_fifo_admission.lua
--- Real FIFO admission for independent read-only native data sources.
local root, mode = assert(arg[1]), assert(arg[2])
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver = assert(source:match("^(.*)/tests/fixtures/native_data_fifo_admission%.lua$"))
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. driver .. "/../_shared/?.lua;"
	.. driver .. "/../_shared/?/init.lua;" .. package.path
require("core.lifecycle.engine.compat.utf8").install()
local Paths = require("infra.paths")
local original = Paths.shared
Paths.shared = function(path)
	if mode == "locale" and path == "data" then return root end
	if mode == "network" and path == "updater/data/defaults.json" then return root .. "/source" end
	return original(path)
end
if mode == "layout" then
	local display = require("infra.display_server")
	display._set_for_test(display.UNKNOWN, "")
	assert(require("adapters.keyboard_layout").refresh(root .. "/source") == false)
elseif mode == "locale" then
	assert(#require("infra.i18n").list_locales() > 0)
elseif mode == "network" then
	local delivered = false
	require("adapters.network_check_ports").new().chain(function(status)
		assert(status == nil)
		delivered = true
	end)
	assert(delivered)
else error("unknown fixture mode") end
