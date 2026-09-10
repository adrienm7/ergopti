--- tests/unit/modules/llm/test_streaming_ui_scope.lua

--- ==============================================================================
--- MODULE: Streaming UI Scenario Isolation
--- DESCRIPTION:
--- Exercises a real registered scenario across exact cache and native boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")
local SUBJECT = "tests.unit.modules.llm.test_streaming_handler_ui_commit_gate"
local OWNERS = { "modules.llm.parser", "modules.llm.streaming_handler", "adapters.timer_scheduler" }

local function capture_scenario()
	local register = helpers.it
	local selected
	helpers.it = function(name, callback)
		if name == "withholds accumulated thinking output until the visible answer arrives" then
			selected = callback
		end
	end
	local ok, err = pcall(require, SUBJECT)
	helpers.it = register
	if not ok then error(err, 0) end
	assert(type(selected) == "function", "real streaming scenario must register")
	return selected
end

helpers.describe("Streaming UI scenario isolation", function()
	for _, prior in ipairs({ "absent", "false", "instance" }) do
		for _, fail in ipairs({ false, true }) do
			helpers.it("(streaming-ui-scope) restores " .. prior .. " after "
				.. (fail and "assertion failure" or "success"), function()
				helpers.with_stub_scope({ SUBJECT, table.unpack(OWNERS) }, function()
					local scenario = capture_scenario()
					local saved = {}
					for index, name in ipairs(OWNERS) do
						if prior == "false" then saved[index] = false end
						if prior == "instance" then saved[index] = {} end
						package.loaded[name] = saved[index]
					end
					local native = rawget(_G, "hs")
					local assertion = helpers.assert_eq
					local marker = "streaming fixture assertion failure"
					if fail then helpers.assert_eq = function() error(marker, 0) end end
					local ok, result = pcall(scenario)
					helpers.assert_eq = assertion
					for index, name in ipairs(OWNERS) do
						helpers.assert_true(rawequal(package.loaded[name], saved[index]),
							name .. " must restore its exact prior owner")
					end
					helpers.assert_true(rawequal(rawget(_G, "hs"), native), "native host must restore")
					helpers.assert_eq(ok, not fail)
					if fail then helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil) end
				end)
			end)
		end
	end
end)
