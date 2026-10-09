--- tests/unit/modules/gestures/test_open_app_action.lua

--- ==============================================================================
--- MODULE: open_app and its app parameter (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/app_vectors.json, which the
--- Linux and Windows suites replay too, through the real gesture validator and
--- the /usr/bin/open arguments of _shared/lua/app_parameter, then runs the
--- action with the value stored for its binding against a recording process
--- owner.
---
--- ROOT CAUSE ENCODED:
--- No action could open a chosen application: a user had to bind a shortcut
--- to a script instead.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local AppParameter = require("app_parameter")

local CORPUS = helpers.shared("tests/corpus/action_parameters/app_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the app corpus is not valid JSON")
end

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")

helpers.describe("open_app replays the shared app corpus (macOS)", function()
	local corpus = read_corpus()

	helpers.it("the parameter is declared", function()
		helpers.assert_eq(Actions.get_action_parameter_spec("open_app"), "app")
		helpers.assert_true(#corpus.vectors >= 15, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("app vector '" .. vector.id .. "'", function()
			local valid = vector.valid ~= false
			helpers.assert_eq(Actions.validate_action_parameter("open_app", vector.value), valid,
				vector.id .. ": validation")
			if not valid then
				helpers.assert_eq(AppParameter.macos_open_args(vector.value), nil, vector.id .. ": no arguments")
			elseif vector.macos_open then
				helpers.assert_eq(AppParameter.macos_open_args(vector.value), vector.macos_open,
					vector.id .. ": open arguments")
			end
		end)
	end
end)

helpers.describe("open_app launches the binding's application (macOS)", function()
	--- Replaces the system-actions owner with a recorder for the duration of body.
	--- @param body function fn(calls)
	local function with_recorded_system(body)
		local saved = package.loaded["modules.gestures.system_actions"]
		local calls = {}
		package.loaded["modules.gestures.system_actions"] = {
			open_app = function(value, parent)
				calls[#calls + 1] = { value = value, parent = parent }
				return true
			end,
		}
		local ok, err = pcall(body, calls)
		package.loaded["modules.gestures.system_actions"] = saved
		if not ok then error(err, 0) end
	end

	helpers.it("opens the application stored for the binding, under its parent", function()
		with_recorded_system(function(calls)
			helpers.assert_eq(Actions.set_action_parameter("keyboard__cmd_1", "open_app", "com.apple.Safari"), true)
			helpers.assert_eq(Actions.execute_single("open_app", "keyboard__cmd_1"), true)
			helpers.assert_eq(calls[1], { value = "com.apple.Safari", parent = "shortcut_bindings" })
		end)
	end)

	helpers.it("a binding with no application stored opens nothing", function()
		with_recorded_system(function(calls)
			Actions.execute_single("open_app", "tap_4")
			helpers.assert_eq(#calls, 0)
		end)
	end)
end)
