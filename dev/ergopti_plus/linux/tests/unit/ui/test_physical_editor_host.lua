--- tests/unit/ui/test_physical_editor_host.lua

--- Checks the actual native host through controlled constructor and cleanup ports.
local helpers = require("tests.helpers")
local Json = require("json")
helpers.describe("Physical shortcut native host ownership", function()
	helpers.it("(physical-editor-ui) refuses stale pages and retains failed native cleanup", function()
		local loaded, original_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local called, detail = pcall(function()
			require("test.physical_editor_host_contract")(helpers, Json,
				function(relative) return helpers.driver_root() .. "/../_shared/" .. relative end,
				function() package.loaded["ui.physical_shortcuts.bridge"] = nil; return require("ui.physical_shortcuts.bridge") end, "linux")
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		_G.hs = original_hs
		if not called then error(detail, 0) end
	end)
end)
