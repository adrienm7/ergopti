--- tests/unit/ui/test_healthcheck_phase_a_no_subprocess.lua

--- ==============================================================================
--- MODULE: Diagnostics Phase A Runs No Child Process (macOS)
--- DESCRIPTION:
--- Opening the diagnostics window collected the machine facts through
--- pcall(hs.execute, "sysctl …") and "uname -m" on the main run loop, which
--- also dispatches the event taps: typing stalled while the window opened.
--- The real phase A now runs with every synchronous child API counted
--- (hs.execute, io.popen, os.execute) and must still fill its sections from
--- Hammerspoon queries alone. The adapters phase A reaches are reloaded under
--- the counted runtime too, so a child started one call deeper is caught.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Reloaded under the counted runtime and restored after the case
local FIXTURE_MODULES = {
	"tests.stubs.hs", "infra.logger", "ui.healthcheck.core", "ui.healthcheck.helpers",
	"adapters.system_info", "adapters.key_state", "adapters.network_info",
	"adapters.accessibility_permission", "adapters.screen_capture",
}

-- The machine the stubbed runtime describes
local RAM_BYTES = 17179869184
local USB_KEYBOARD = { productName = "USB Keyboard", vendorID = 0x05ac, productID = 0x024f }

--- Runs the real phase A with every synchronous child API counted.
--- @return table snapshot, table calls The commands phase A tried to run.
local function run_phase_a()
	local calls = {}
	local saved_os_execute, saved_io_popen = os.execute, io.popen
	local ok, snapshot = pcall(helpers.with_stub_scope, FIXTURE_MODULES, function()
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		hs_stub.execute = function(command)
			calls[#calls + 1] = "hs.execute " .. tostring(command)
			return "", false
		end
		hs_stub.host.vmStat = function() return { memSize = RAM_BYTES, pagesFree = 1000, pageSize = 16384 } end
		hs_stub.usb = { attachedDevices = function() return { USB_KEYBOARD } end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		os.execute = function(command)
			calls[#calls + 1] = "os.execute " .. tostring(command)
			return nil
		end
		io.popen = function(command)
			calls[#calls + 1] = "io.popen " .. tostring(command)
			return nil, "counted by the test"
		end
		return require("ui.healthcheck.core").run()
	end)
	os.execute, io.popen = saved_os_execute, saved_io_popen
	if not ok then error(snapshot, 0) end
	return snapshot, calls
end

helpers.describe("healthcheck (macOS): phase A never starts a child process", function()
	helpers.it("collects the snapshot without hs.execute, io.popen or os.execute (phase-a-no-subprocess)", function()
		local snapshot, calls = run_phase_a()
		helpers.assert_eq(#calls, 0, "phase A ran a child process on the run loop: " .. table.concat(calls, "; "))
		-- The guard means nothing unless the collectors actually ran
		helpers.assert_eq(snapshot.schema_version, 2)
		helpers.assert_eq(snapshot.sections.hardware.ram_total, RAM_BYTES)
		helpers.assert_eq(#snapshot.sections.peripherals.items, 1)
		local filled = 0
		for _, section in pairs(snapshot.sections) do
			if type(section) == "table" and next(section) ~= nil then filled = filled + 1 end
		end
		helpers.assert_true(filled >= 8, "phase A filled only " .. filled .. " sections")
	end)
end)
