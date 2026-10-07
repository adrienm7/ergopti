--- tests/unit/ui/menu/test_automation_inventory.lua

--- Independent shared session controls; no mock result qualifies native catalogue access.
local H = require("tests.helpers")

local function fixture(body)
	local previous = package.loaded.program_provider_picker
	package.loaded.program_provider_picker = nil
	local ok, failure = xpcall(function() body(require("program_provider_picker")) end, debug.traceback)
	package.loaded.program_provider_picker = previous
	if not ok then error(failure, 0) end
end

H.describe("shared readonly automation acquisition", function()
	H.it("reserves the session before a synchronous publication callback can close it", function()
		fixture(function(Picker)
			local state, creations = Picker.capture(nil), 0
			local adapter = { create = function() creations = creations + 1; error("closed session acquired") end }
			H.assert_eq(Picker.capture_automation(state, adapter, function(packet)
				H.assert_eq(packet, { title = "Apple Shortcuts", choices = {}, truncated = false })
				H.assert_true(Picker.close(state))
			end), false)
			H.assert_eq(creations, 0)
		end)
	end)
	H.it("contains construction reentry and retires its returned owner", function()
		fixture(function(Picker)
			local state, nested, invalidations = Picker.capture(nil), nil, 0
			local adapter = { create = function()
				nested = Picker.capture_automation(state, nil, function() error("nested publication") end)
				Picker.close(state)
				return { discover = function() error("closed owner discovered") end,
					invalidate = function() invalidations = invalidations + 1; return true end }
			end }
			H.assert_eq(Picker.capture_automation(state, adapter, function() end), false)
			H.assert_eq(nested, false); H.assert_eq(invalidations, 1)
		end)
	end)
	H.it("rejects forged readonly keys before an ordinary resolver sees them", function()
		fixture(function(Picker)
			local resolutions = 0
			local state = { owner = { resolve = function() resolutions = resolutions + 1; return "forged" end } }
			for _, id in ipairs({ "run_program", "send_text" }) do
				H.assert_eq(Picker.confirm(state, id, { providerKey = "automation:1:1" }), false)
			end
			H.assert_eq(resolutions, 0)
			H.assert_eq(Picker.confirm(state, "run_program", { parameter = "literal manual" }), true)
		end)
	end)
	H.it("keeps native debt fenced until the same exact owner acknowledges retirement", function()
		fixture(function(Picker)
			local state, retired, constructions = Picker.capture(nil), false, 0
			local owner = { discover = function() return true end, invalidate = function() return retired end }
			H.assert_true(Picker.capture_automation(state, { create = function() return owner end }, function() end))
			H.assert_eq(Picker.close(state), false)
			local next_state = Picker.capture(nil)
			local adapter = { create = function() constructions = constructions + 1; return owner end }
			H.assert_eq(Picker.capture_automation(next_state, adapter, function() end), false)
			H.assert_eq(constructions, 0)
			retired = true
			next_state = Picker.capture(nil)
			H.assert_true(Picker.capture_automation(next_state, adapter, function() end))
			H.assert_eq(constructions, 1)
			H.assert_true(Picker.close(next_state))
		end)
	end)
end)
