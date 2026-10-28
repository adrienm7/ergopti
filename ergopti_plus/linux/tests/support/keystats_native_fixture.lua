--- tests/support/keystats_native_fixture.lua

--- ==============================================================================
--- MODULE: Isolated Native Keystats Fixture
--- DESCRIPTION:
--- Gives a scenario independent collector and SQLite owners, waits for exact
--- native retirement, and observes reset/flush acknowledgements through libuv.
--- Business session resets preserve history and cannot serve as test cleanup.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")
local Timings = require("infra.timings")
local uv = require("luv")

local MODULES = { "modules.keystats.keystats", "modules.keystats.metrics_collector", "modules.keystats.sqlite_writer" }

-- Public vocabulary; true marks a physical phase that can own a native child.
-- Unknown phases cannot claim new wait budgets.
local FLUSH_PHASES = {
	idle = false, reservation = true, reservation_retry = false, compose_retry = false,
	commit = true, commit_retry = false, resolve = true, resolve_retry = false,
	cleanup = true, cleanup_retry = false, uncertain = false,
}

--- Returns the canonical SQLite operation deadline on the native clock.
local function deadline()
	return uv.hrtime() + Timings.ms("keystats", "sqlite_operation_timeout_ms") * 1000000
end

--- Observes bounded, non-repeating native phases after their constructors return.
--- Each physical phase gets an execution observation window and, on expiry, one
--- additional canonical window to observe physical retirement. Logical phases
--- get one window. This is a test observation policy, not a product timeout or
--- a hard wall-clock bound: constructors and callbacks may block synchronously.
--- Four physical phases times two windows plus seven logical phases, across
--- at most two generations, admit at most thirty canonical windows per wait.
--- An isolated body owns no continuing producer: it may drain an existing
--- transaction and acquire one closing snapshot, never an unlimited generation.
--- @param collector table Isolated collector.
--- @param advance function Drives one native observation.
--- @param settled boolean Initial admission result.
--- @return boolean acknowledged
local function await_native(collector, advance, settled)
	if settled then return settled end
	local function status()
		local value = collector.get_flush_status()
		assert(type(value) == "table" and FLUSH_PHASES[value.phase] ~= nil, "Unknown native fixture phase")
		assert(type(value.generation) == "number" and value.generation >= 0 and value.generation % 1 == 0,
			"Invalid native fixture generation")
		return value
	end
	local previous = status()
	local seen, closing = { [previous.phase] = true }, true
	local until_ns, retirement_window = deadline(), false
	while not settled do
		if uv.hrtime() >= until_ns then
			if retirement_window or not FLUSH_PHASES[previous.phase] then break end
			retirement_window, until_ns = true, deadline()
			print(string.format("Native fixture observation: execution window expired; observing physical retirement phase=%s generation=%d", previous.phase, previous.generation))
		end
		uv.sleep(1)
		uv.run("nowait")
		settled = advance()
		if not settled then
			local current = status()
			if current.generation ~= previous.generation then
				assert(closing and current.generation == previous.generation + 1,
					"Native fixture acquired more than one closing generation")
				closing, seen = false, {}
			elseif current.phase ~= previous.phase then
				assert(not seen[current.phase], "Native fixture revisited an acknowledged phase")
			end
			if current.generation ~= previous.generation or current.phase ~= previous.phase then
				seen[current.phase], until_ns, retirement_window = true, deadline(), false
			end
			previous = current
		end
	end
	return settled
end

--- Runs a scenario with fresh owners and retires them before restoring caches.
--- @param body function Receives the isolated collector.
function M.with(body)
	local previous = {}
	for _, name in ipairs(MODULES) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local previous_storage = package.loaded["adapters.storage"]
	local collector
	local ok, err = xpcall(function()
		collector = require("modules.keystats.keystats")
		body(collector)
	end, debug.traceback)
	local cleanup_ok, cleanup_err = pcall(function()
		if not collector then return end
		local owners = { collector }
		local current = package.loaded[MODULES[1]]
		if current and current ~= collector then owners[#owners + 1] = current end
		for _, owner in ipairs(owners) do
			local settled = await_native(owner, owner.stop, owner.stop())
			helpers.assert_true(settled, "the scenario must retire its native collector before the next one")
		end
	end)
	for _, name in ipairs(MODULES) do package.loaded[name] = previous[name] end
	package.loaded["adapters.storage"] = previous_storage
	if not ok then error(err, 0) end
	if not cleanup_ok then error(cleanup_err, 0) end
end

--- Observes native COMMIT and cleanup before accepting a business reset.
--- @param collector table Isolated collector.
--- @return boolean acknowledged
function M.reset(collector)
	local acknowledged = await_native(collector, function()
		collector.pump_flush()
		return collector.reset_session()
	end, collector.reset_session())
	helpers.assert_true(acknowledged, "native COMMIT and cleanup must acknowledge the reset")
	return acknowledged
end

--- Waits for a dispatched native flush before reading a merged projection.
--- @param collector table Isolated collector.
function M.flush(collector)
	local committed = collector.flush()
	helpers.assert_true(committed == true or collector.has_flush_debt(),
		"the native flush must commit or acquire an acknowledged operation")
	await_native(collector, function()
		collector.pump_flush()
		return not collector.has_flush_debt()
	end, not collector.has_flush_debt())
	helpers.assert_eq(collector.has_flush_debt(), false, "the snapshot must commit before its projection is readable")
	helpers.assert_true(collector.get_flush_status().committed, "retirement alone is not a successful native COMMIT")
end

return M
