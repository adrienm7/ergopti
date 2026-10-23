--- tests/unit/adapters/runtime_owner_ports/test_runtime_owner_ports.lua

--- ==============================================================================
--- MODULE: Owned Runtime Ports
--- DESCRIPTION:
--- Pins how adapters/runtime_owner_ports.lua turns command results into the
--- owner's answers: only read-only commands run, an unknown exit status is an
--- unknown answer (never "not loaded" or "none running"), and the artifact is
--- reported as not shipped.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the ports over a scripted command runner.
--- @param script function fn(executable, args) -> code, output.
--- @return table ports
--- @return table calls Recorded { executable, args }.
local function load_ports(script)
	local calls = {}
	package.loaded["adapters.field_check_ports"] = {
		exec = function(executable, args, _, callback)
			calls[#calls + 1] = { executable = executable, args = args }
			callback(script(executable, args))
		end,
	}
	package.loaded["adapters.runtime_owner_ports"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local ports = helpers.load_with_stubs("adapters.runtime_owner_ports", {
		processInfo = { processID = 777 },
	}).new()
	return ports, calls
end

--- Captures a callback's single argument.
--- @param register function fn(callback).
--- @return any value
local function answer(register)
	local value = "never called"
	register(function(result) value = result end)
	return value
end

helpers.describe("owned runtime ports", function()
	helpers.it("reads a job with a read-only print and maps the unknown-service status to not loaded", function()
		local ports, calls = load_ports(function() return 113, "" end)
		helpers.assert_eq(answer(function(cb) ports.launchd.loaded("com.ergoptiplus.runtime.core", cb) end), false)
		helpers.assert_eq(calls[1], { executable = "/bin/launchctl", args = { "print", "system/com.ergoptiplus.runtime.core" } })
	end)

	helpers.it("reports a loaded job and treats any other status or a timeout as unknown", function()
		local ports = load_ports(function() return 0, "" end)
		helpers.assert_eq(answer(function(cb) ports.launchd.loaded("x", cb) end), true)
		for _, code in ipairs({ 1, 5 }) do
			local other = load_ports(function() return code, "" end)
			helpers.assert_eq(answer(function(cb) other.launchd.loaded("x", cb) end), nil)
		end
		local timed_out = load_ports(function() return nil, "" end)
		helpers.assert_eq(answer(function(cb) timed_out.launchd.loaded("x", cb) end), nil)
	end)

	helpers.it("returns the extension listing only when the tool succeeded", function()
		local ports, calls = load_ports(function() return 0, "listing" end)
		helpers.assert_eq(answer(ports.system_extensions.listing), "listing")
		helpers.assert_eq(calls[1].args, { "list" })
		local failed = load_ports(function() return 1, "listing" end)
		helpers.assert_eq(answer(failed.system_extensions.listing), nil)
	end)

	helpers.it("counts other Karabiner processes and distinguishes none from unknown", function()
		local several = load_ports(function() return 0, "11\n12\n" end)
		helpers.assert_eq(answer(several.coexistence.detect), 2)
		local none = load_ports(function() return 1, "" end)
		helpers.assert_eq(answer(none.coexistence.detect), 0)
		local broken = load_ports(function() return 2, "" end)
		helpers.assert_eq(answer(broken.coexistence.detect), nil)
		local timed_out = load_ports(function() return nil, "" end)
		helpers.assert_eq(answer(timed_out.coexistence.detect), nil)
	end)

	helpers.it("binds no closer for another Karabiner and no capture owner", function()
		local ports = load_ports(function() return 0, "" end)
		helpers.assert_nil(ports.coexistence.close)
		helpers.assert_nil(ports.capture)
	end)

	helpers.it("says plainly that no artifact manifest ships yet, and exposes the owner pid", function()
		local ports = load_ports(function() return 0, "" end)
		local pinned, reason = ports.artifact.pinned()
		helpers.assert_nil(pinned)
		helpers.assert_contains(reason, "no runtime artifact manifest")
		helpers.assert_eq(ports.process.owner_pid(), 777)
	end)
end)
