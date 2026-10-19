--- tests/unit/adapters/processes/test_owned_process_deadline.lua
local helpers = require("tests.helpers")

helpers.describe("owned-process-deadline", function()
	for _, mode in ipairs({ "cold", "callback", "existing" }) do
		helpers.it("owned-process-deadline: " .. mode .. " preserves a newly armed native budget", function()
			local Shell = require("adapters.shell_runner")
			local executable = assert(require("luv").exepath())
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_owned_deadline.lua"
			local command = Shell.quote(executable) .. " " .. Shell.quote(fixture) .. " " .. Shell.quote(mode)
			local status = os.execute(command)
			helpers.assert_true(status == true or status == 0, "actual child deadline and cleanup must pass: " .. mode)
		end)
	end
end)
