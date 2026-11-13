--- tests/unit/ai/engine/test_managed_pyobjc.lua

--- ==============================================================================
--- MODULE: Managed PyObjC For App Cloner
--- DESCRIPTION:
--- Pins ai/engine/bootstrap/managed_pyobjc.lua with fake ports: readiness is a stat of
--- the versionless link; the install runs the PyObjC installer under the
--- native PTY guardian, settles its receipt before reporting, and succeeds
--- only on the installer's exact success line for that link.
---
--- ROOT CAUSE ENCODED: App Cloner read PyObjC from /usr/bin/python3, which a Mac
--- without the Command Line Tools lacks. The managed replacement must be
--- installed by the guardian that owns every bootstrap child, never reported
--- ready on an exit code alone, and never install without being asked.
--- ==============================================================================

local helpers = require("tests.helpers")

local LINK = "/Users/test/Library/Application Support/Ergopti/native-bootstrap/app-cloner/python3"

--- Builds an owner over fake ports.
--- @param options table|nil { prepared, bind, start, exists }.
--- @return table owner
--- @return table world
local function fake(options)
	options = options or {}
	package.loaded["ai.engine.bootstrap.managed_pyobjc"] = nil
	local Owner = require("ai.engine.bootstrap.managed_pyobjc")
	local world = { prepared = {}, settled = {}, rolled_back = 0, started = 0, exists = options.exists or false }
	local handle = {
		executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
		arguments = { "--managed-pty-worker", "1800000" },
		rollback = function() world.rolled_back = world.rolled_back + 1; return true end,
		bind_input = function() return options.bind ~= false end,
		mark_start_attempted = function() return true end,
		settle = function(code) world.settled[#world.settled + 1] = code; return options.receipt ~= false end,
	}
	local owner = Owner.new({
		expand = function(path) return (path:gsub("^~", "/Users/test")) end,
		exists = function(path) return path == LINK and world.exists end,
		driver_root = function() return "/driver" end,
		timeout_ms = function() return 1800000 end,
		prepare = function(source, environment, timeout)
			world.prepared[#world.prepared + 1] = { source = source, environment = environment, timeout = timeout }
			return handle, options.prepared ~= false
		end,
		task = function(executable, arguments, on_exit)
			world.task = { executable = executable, arguments = arguments, on_exit = on_exit }
			return world.task
		end,
		start = function() world.started = world.started + 1; return options.start ~= false end,
	})
	return owner, world, Owner
end

helpers.describe("managed PyObjC for App Cloner", function()
	helpers.it("is ready only when the versionless link resolves", function()
		local owner = fake()
		helpers.assert_eq(owner.link(), LINK)
		helpers.assert_eq(owner.ready(), false)
		local present = fake({ exists = true })
		helpers.assert_eq(present.ready(), true)
	end)

	helpers.it("runs the installer under the guardian and reports the link after the receipt settles", function()
		local owner, world = fake()
		local result
		owner.install(function(ok, value) result = { ok = ok, value = value } end)
		helpers.assert_eq(world.prepared[1].source, "/driver/modules/llm/ensure-managed-pyobjc.sh")
		helpers.assert_eq(world.prepared[1].environment, {})
		helpers.assert_eq(world.task.arguments, { "--managed-pty-worker", "1800000" })
		helpers.assert_eq(world.started, 1)
		helpers.assert_nil(result, "nothing is reported before the installer exits")
		world.exists = true
		world.task.on_exit(0, "[PYOBJC] stage: install\r\nPYOBJC_READY\t" .. LINK .. "\r\n")
		helpers.assert_eq(world.settled, { 0 })
		helpers.assert_eq(result, { ok = true, value = LINK })
	end)

	helpers.it("never calls an exit 0 without the exact success line a success", function()
		local owner, world, Owner = fake()
		local result
		owner.install(function(ok, value) result = { ok = ok, value = value } end)
		world.exists = true
		world.task.on_exit(0, "PYOBJC_READY\t/tmp/elsewhere/python3\n")
		helpers.assert_eq(result, { ok = false, value = Owner.REASON.OUTPUT })
	end)

	helpers.it("names a failed install, an unsettled receipt and a refused preparation", function()
		local owner, world, Owner = fake()
		local result
		owner.install(function(ok, value) result = { ok = ok, value = value } end)
		world.task.on_exit(1, "[PYOBJC] ERROR: stage install ended with exit 1.\n")
		helpers.assert_eq(result.value, Owner.REASON.FAILED)
		local unsettled, unsettled_world = fake({ receipt = false })
		unsettled.install(function(ok, value) result = { ok = ok, value = value } end)
		unsettled_world.exists = true
		unsettled_world.task.on_exit(0, "PYOBJC_READY\t" .. LINK .. "\n")
		helpers.assert_eq(result.value, Owner.REASON.RECEIPT, "the receipt is settled before success")
		local refused, refused_world = fake({ prepared = false })
		refused.install(function(ok, value) result = { ok = ok, value = value } end)
		helpers.assert_eq(result.value, Owner.REASON.PREPARE)
		helpers.assert_eq(refused_world.rolled_back, 1)
		helpers.assert_eq(refused_world.started, 0)
	end)

	helpers.it("runs one install at a time and settles every caller", function()
		local owner, world = fake()
		local results = {}
		owner.install(function(ok) results[#results + 1] = ok end)
		owner.install(function(ok) results[#results + 1] = ok end)
		helpers.assert_eq(#world.prepared, 1, "a second caller prepared a second install")
		world.exists = true
		world.task.on_exit(0, "PYOBJC_READY\t" .. LINK .. "\n")
		helpers.assert_eq(results, { true, true })
	end)
end)
