--- tests/unit/modules/keystats/test_keystats_init_spawns_nothing.lua

--- ==============================================================================
--- MODULE: Keystats Init Without A Fork
--- DESCRIPTION:
--- The device identifier comes from the machine's hostname. It was read by
--- forking `hostname` on every start; the kernel's nodename is a file. The
--- counted shell-outs (not wall-clock) pin that init forks nothing and that the
--- identifier is unchanged.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

helpers.describe("keystats init: device identifier", function()
	helpers.it("derives the device id from the kernel hostname without a shell-out", function()
		local writer_name, module_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
		local previous_writer, previous_module = package.loaded[writer_name], package.loaded[module_name]
		local writer = Fakes.sqlite_writer()
		package.loaded[writer_name] = writer
		package.loaded[module_name] = nil
		local real_popen, real_execute = io.popen, os.execute
		local spawned = {}
		io.popen = function(command, ...) spawned[#spawned + 1] = tostring(command); return real_popen(command, ...) end
		os.execute = function(command, ...) spawned[#spawned + 1] = tostring(command); return real_execute(command, ...) end
		local ok, failure = pcall(function()
			local keystats = require(module_name)
			keystats.init({ sqlite_path = "/tmp/ergopti_init_spawn_probe.sqlite" })
			local handle = assert(io.open("/proc/sys/kernel/hostname", "rb"))
			local hostname = handle:read("*l"):gsub("%s+", "")
			handle:close()
			helpers.assert_eq(#writer.devices, 1)
			helpers.assert_eq(writer.devices[1].device_id, "linux-" .. hostname)
			helpers.assert_eq(writer.devices[1].name, hostname)
		end)
		io.popen, os.execute = real_popen, real_execute
		package.loaded[writer_name], package.loaded[module_name] = previous_writer, previous_module
		if not ok then error(failure, 0) end
		for _, command in ipairs(spawned) do
			helpers.assert_true(not command:find("hostname", 1, true), "init forked: " .. command)
		end
	end)
end)
