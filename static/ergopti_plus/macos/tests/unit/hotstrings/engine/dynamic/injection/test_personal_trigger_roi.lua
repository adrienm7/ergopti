--- tests/unit/hotstrings/engine/dynamic/injection/test_personal_trigger_roi.lua

--- ==============================================================================
--- MODULE: Personal Information Trigger ROI Admission
--- DESCRIPTION:
--- Exercises the actual multi-field interceptor across accepted and refused
--- replacement transactions. The ROI sink receives the full typed trigger and
--- only logical output, excluding the Tabs that navigate between fields.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("personal information trigger ROI", function()
	helpers.it("counts an accepted private multi-field expansion once and refuses failed injection", function()
		helpers.with_stub_scope({ "modules.keystats", "hotstrings.engine.dynamic.personal_info" }, function()
			local calls = {}
			package.loaded["modules.keystats"] = {
				log_private_hotstring = function(trigger, output)
					calls[#calls + 1] = { trigger, output }
					return true
				end,
			}
			local personal = helpers.load_with_stubs("hotstrings.engine.dynamic.personal_info")
			local interceptor, accepted = nil, false
			local keymap = {
				register_interceptor = function(fn) interceptor = fn end,
				register_preview_provider = function() end,
				inject_dynamic = function() return accepted end,
			}
			local path = os.tmpname()
			local file = assert(io.open(path, "w"))
			file:write('[info]\nfirst_name="Alice"\nlast_name="Martin"\n\n[letters]\np="first_name"\nn="last_name"\n')
			file:close()
			local started, result = pcall(personal.start, "", keymap, path, function(_, publish) return publish() end)
			os.remove(path)
			helpers.assert_true(started and result ~= false)
			personal.enable()
			local function event(chars)
				return { getFlags = function() return {} end, getKeyCode = function() return 0 end,
					getCharacters = function() return chars end }
			end
			local function fire()
				interceptor(event("@"), "")
				interceptor(event("p"), "@")
				interceptor(event("n"), "@p")
				return interceptor(event(personal.get_trigger_char()), "@pn")
			end
			helpers.assert_nil(fire())
			helpers.assert_eq(#calls, 0)
			accepted = true
			helpers.assert_eq(fire(), "consume")
			helpers.assert_eq(calls, { { "@pn" .. personal.get_trigger_char(), "AliceMartin" } })
		end)
	end)
end)
