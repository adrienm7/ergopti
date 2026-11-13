--- tests/unit/metrics/engine/test_init_spawns_nothing.lua

--- ==============================================================================
--- MODULE: Keystats Init Without A Fork
--- DESCRIPTION:
--- A store recorded before the ledger keeps the identifier derived from the
--- machine's hostname. It was read by forking `hostname` on every start; the
--- kernel's nodename is a file. The counted shell-outs (not wall-clock) pin that
--- init forks nothing for it and that the identifier is unchanged. A new store
--- takes the UUID of this host's by_device/ folder, which macOS and Windows import.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

helpers.describe("keystats init: device identifier", function()
	helpers.it("derives the device id from the kernel hostname without a shell-out", function()
		local writer_name, module_name = "metrics.engine.journal.sqlite_writer", "metrics.engine.keystats"
		local previous_writer, previous_module = package.loaded[writer_name], package.loaded[module_name]
		local writer = Fakes.sqlite_writer()
		package.loaded[writer_name] = writer
		package.loaded[module_name] = nil
		local real_popen, real_execute = io.popen, os.execute
		local spawned = {}
		io.popen = function(command, ...) spawned[#spawned + 1] = tostring(command); return real_popen(command, ...) end
		os.execute = function(command, ...) spawned[#spawned + 1] = tostring(command); return real_execute(command, ...) end
		local uv = require("luv")
		local metrics = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-device-XXXXXX")) .. "/metrics"
		local ok, failure = pcall(function()
			local keystats = require(module_name)
			keystats.init({ sqlite_path = "/tmp/ergopti_init_spawn_probe.sqlite", metrics_dir = metrics })
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

	helpers.it("linux-ledger-device-id: a new store takes this host's by_device identity and publishes it", function()
		local writer_name, module_name = "metrics.engine.journal.sqlite_writer", "metrics.engine.keystats"
		local previous_writer, previous_module = package.loaded[writer_name], package.loaded[module_name]
		local writer = Fakes.sqlite_writer({ fresh_store = true })
		package.loaded[writer_name] = writer
		package.loaded[module_name] = nil
		local uv = require("luv")
		local metrics = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-device-XXXXXX")) .. "/metrics"
		local ok, failure = pcall(function()
			local keystats = require(module_name)
			keystats.init({ sqlite_path = "/tmp/ergopti_init_spawn_probe.sqlite", metrics_dir = metrics })
			local device = writer.devices[1].device_id
			helpers.assert_true(device:match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$") ~= nil, device)
			local handle = assert(io.open(metrics .. "/by_device/" .. device .. "/device.json", "rb"))
			local identity = require("core.text.engine.json").decode(handle:read("*a"))
			handle:close()
			helpers.assert_eq(identity.device_id, device)
			helpers.assert_eq(identity.os, "linux")
			helpers.assert_eq(writer.devices[1].signature, identity.host_signature)
			helpers.assert_eq(keystats.ledger_status().available, true)
		end)
		package.loaded[writer_name], package.loaded[module_name] = previous_writer, previous_module
		if not ok then error(failure, 0) end
	end)

	helpers.it("linux-keystats-boot-defer: the ledger starts on the deferred tick, not inside init", function()
		-- Each sqlite3 query is a process (about 4 ms); the ledger export and the
		-- text migration used to run inside the boot's keystats stage.
		local writer_name, module_name = "metrics.engine.journal.sqlite_writer", "metrics.engine.keystats"
		local previous_writer, previous_module = package.loaded[writer_name], package.loaded[module_name]
		local writer = Fakes.sqlite_writer({ fresh_store = true })
		package.loaded[writer_name] = writer
		package.loaded[module_name] = nil
		local uv = require("luv")
		local metrics = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-device-XXXXXX")) .. "/metrics"
		local ok, failure = pcall(function()
			local keystats = require(module_name)
			local queued = {}
			keystats.init({ sqlite_path = "/tmp/ergopti_init_spawn_probe.sqlite", metrics_dir = metrics,
				defer = function(fn) queued[#queued + 1] = fn end })
			helpers.assert_eq(#queued, 1, "one deferred task carries the background work")
			helpers.assert_eq(keystats.ledger_status().available, false, "the ledger waits for the loop")
			queued[1]()
			helpers.assert_eq(keystats.ledger_status().available, true, "the deferred tick starts the ledger")
		end)
		package.loaded[writer_name], package.loaded[module_name] = previous_writer, previous_module
		if not ok then error(failure, 0) end
	end)
end)
