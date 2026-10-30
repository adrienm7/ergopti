--- tests/unit/platform/remap/lease/test_lease_memory_snapshot.lua

--- ==============================================================================
--- MODULE: Memory Pressure At A Lease Failure (lease-memory-snapshot)
--- DESCRIPTION:
--- Silent PONG and READY timeouts on Apple silicon have one open explanation,
--- starvation. A lease failure reads the free memory once per window and logs
--- it with the failure kind; a reading that fails says so.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "adapters.shell_runner", "adapters.timer_scheduler",
	"platform.remap.lease_memory_snapshot" }

--- Loads the module over a scripted runner, clock and logger.
--- @param scenario function fn(Snapshot, world).
local function with_snapshot(scenario)
	helpers.with_stub_scope(MODULES, function()
		local world = { now_ns = 0, spawns = {}, lines = {}, start_result = true }
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "start", "success", "warn", "debug", "info", "error" }) do
			logger[level] = function(_, fmt, ...)
				world.lines[#world.lines + 1] = { level = level, text = string.format(fmt, ...) }
			end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.timer_scheduler"] = { now_ns = function() return world.now_ns end }
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local spawn = { executable = executable, args = args, on_done = on_done }
				world.spawns[#world.spawns + 1] = spawn
				return { start = function() return world.start_result end }
			end,
		}
		package.loaded["platform.remap.lease_memory_snapshot"] = nil
		scenario(require("platform.remap.lease_memory_snapshot"), world)
	end)
end

local function lines_at(world, level)
	local found = {}
	for _, line in ipairs(world.lines) do
		if line.level == level then found[#found + 1] = line.text end
	end
	return found
end

helpers.describe("lease memory snapshot (lease-memory-snapshot)", function()
	helpers.it("parses the summary line of memory_pressure", function()
		with_snapshot(function(Snapshot)
			helpers.assert_eq(Snapshot.parse_free_percent("Pages free: 1\nSystem-wide memory free percentage: 8%\n"), 8)
			helpers.assert_nil(Snapshot.parse_free_percent("no summary"))
			helpers.assert_nil(Snapshot.parse_free_percent(nil))
		end)
	end)

	helpers.it("reads the tool once and logs the free memory with the failure kind", function()
		with_snapshot(function(Snapshot, world)
			helpers.assert_true(Snapshot.note_failure("pong"))
			helpers.assert_eq(#world.spawns, 1)
			helpers.assert_eq(world.spawns[1].executable, "/usr/bin/memory_pressure")
			helpers.assert_eq(#world.spawns[1].args, 0, "the bare tool only reports; it applies no pressure")
			world.spawns[1].on_done(0, "System-wide memory free percentage: 12%\n", "")
			helpers.assert_eq(lines_at(world, "success"), { "Memory free when the Karabiner lease failed (pong): 12%." })
			helpers.assert_eq(#lines_at(world, "start"), 1, "the reading is a paired lifecycle")
		end)
	end)

	helpers.it("reads once per window, then again after it", function()
		with_snapshot(function(Snapshot, world)
			helpers.assert_true(Snapshot.note_failure("ready"))
			world.now_ns = (Snapshot.MIN_INTERVAL_SECONDS - 1) * 1e9
			helpers.assert_eq(Snapshot.note_failure("ready"), false, "a failure storm reads once")
			world.now_ns = (Snapshot.MIN_INTERVAL_SECONDS + 1) * 1e9
			helpers.assert_true(Snapshot.note_failure("ready"))
			helpers.assert_eq(#world.spawns, 2)
		end)
	end)

	helpers.it("names a reading that failed or could not start", function()
		with_snapshot(function(Snapshot, world)
			Snapshot.note_failure("pong")
			world.spawns[1].on_done(1, "", "boom")
			helpers.assert_eq(lines_at(world, "warn"),
				{ "The free memory at a Karabiner lease failure (pong) could not be read: exit 1." })
			Snapshot.reset()
			world.start_result = false
			helpers.assert_eq(Snapshot.note_failure("ready"), false)
			helpers.assert_eq(#lines_at(world, "warn"), 2, "a tool that did not start is a WARNING too")
		end)
	end)
end)
