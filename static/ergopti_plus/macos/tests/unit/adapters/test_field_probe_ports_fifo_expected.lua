--- tests/unit/adapters/test_field_probe_ports_fifo_expected.lua

--- ==============================================================================
--- MODULE: Field Run FIFO Check Owns Its Expected Refusals
--- DESCRIPTION:
--- The fifo_safety check writes to a named pipe so the file writers refuse it.
--- Those refusals are the check's expected outcome, yet each run logged them as
--- ERRORs of the session (field run 2026-10-31 14:14:55). The check's writers
--- now hand them to the check as a category (fifo-expected-refusal).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("field run FIFO check writers (fifo-expected-refusal)", function()
	helpers.it("passes the writers a refusal owner, so no ERROR line is written", function()
		helpers.with_stub_scope({ "adapters.field_probe_ports", "adapters.file_system" }, function()
			local owners = {}
			package.loaded["adapters.file_system"] = {
				followed_mode = function() return "present", "named pipe" end,
				exists = function() return true end,
				append = function() error("the check must not log its expected refusal") end,
				write = function() error("the check must not log its expected refusal") end,
				append_reporting_to = function(_, _, on_error) owners.append = on_error; return false end,
				write_reporting_to = function(_, _, on_error) owners.write = on_error; return false, "not a regular file" end,
			}
			package.loaded["adapters.field_probe_ports"] = nil
			local Ports = helpers.load_with_stubs("adapters.field_probe_ports")
			local fifo = Ports.new().fifo()
			helpers.assert_eq(fifo.append(fifo.dir .. "/pipe", "x"), false)
			helpers.assert_eq(fifo.write(fifo.dir .. "/pipe", "x"), false)
			helpers.assert_eq(type(owners.append), "function", "append must not log the expected refusal")
			helpers.assert_eq(type(owners.write), "function", "write must not log the expected refusal")
		end)
	end)
end)
