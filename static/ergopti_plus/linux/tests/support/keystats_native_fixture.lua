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

--- Returns the canonical SQLite operation deadline on the native clock.
local function deadline()
	return uv.hrtime() + Timings.ms("keystats", "sqlite_operation_timeout_ms") * 1000000
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
			local until_ns, settled = deadline(), owner.stop()
			while not settled and uv.hrtime() < until_ns do
				uv.run("nowait")
				uv.sleep(1)
				settled = owner.stop()
			end
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
	local until_ns, acknowledged = deadline(), collector.reset_session()
	while not acknowledged and uv.hrtime() < until_ns do
		uv.run("nowait")
		collector.pump_flush()
		acknowledged = collector.reset_session()
		if not acknowledged then uv.sleep(1) end
	end
	helpers.assert_true(acknowledged, "native COMMIT and cleanup must acknowledge the reset")
	return acknowledged
end

--- Waits for a dispatched native flush before reading a merged projection.
--- @param collector table Isolated collector.
function M.flush(collector)
	local committed = collector.flush()
	helpers.assert_true(committed == true or collector.has_flush_debt(),
		"the native flush must commit or acquire an acknowledged operation")
	local until_ns = deadline()
	while collector.has_flush_debt() and uv.hrtime() < until_ns do
		uv.run("nowait")
		collector.pump_flush()
		if collector.has_flush_debt() then uv.sleep(1) end
	end
	helpers.assert_eq(collector.has_flush_debt(), false, "the snapshot must commit before its projection is readable")
	helpers.assert_true(collector.get_flush_status().committed, "retirement alone is not a successful native COMMIT")
end

return M
