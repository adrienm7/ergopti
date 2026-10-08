--- tests/unit/platform/remap/test_runtime_missing_input_admission.lua

--- ==============================================================================
--- MODULE: Native Runtime Input Contract
--- DESCRIPTION:
--- Malformed config-owner results cannot silently become shared admission.
--- Actual A3 default reads precede each deliberately malformed port result.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("native runtime input contract refusal", function()
	for _, control in ipairs({ { name = "missing" }, { name = "boolean", value = false },
		{ name = "table", value = {} }, { name = "empty", value = "" } }) do
		helpers.it("refuses " .. control.name .. " runtime before any native acquisition", function()
			local path = os.tmpname()
			local source = '[karabiner]\nintegration_enabled = true\n'
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local ok, err = pcall(function()
				with_fixture(function(fixture)
					local remap, calls = fixture.load_enabled_remap({ skip_init = true, real_user_config_path = path })
					local port = require("platform.remap.config")
					local load_settings = port.load_user_config
					port.load_user_config = function(...)
						local state, status = load_settings(...)
						helpers.assert_eq(status, "ok")
						helpers.assert_eq(state.runtime, "shared", "genuine admitted A3 default preceded invalid input")
						state.runtime = control.value
						return state, status
					end
					local expanded = 0
					helpers.assert_eq(remap.init({ expand_path = function(value)
						expanded = expanded + 1; return value
					end }), false)
					helpers.assert_eq(calls.lease_init, 0)
					helpers.assert_eq(calls.input_source_watchers, 0)
					helpers.assert_eq(calls.save, 0)
					helpers.assert_eq(#calls.rule_removals, 0)
					helpers.assert_eq(expanded, 0)
					local stream = assert(io.open(path, "rb"))
					helpers.assert_eq(stream:read("*a"), source); assert(stream:close())
				end)
			end)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end
end)

return true
