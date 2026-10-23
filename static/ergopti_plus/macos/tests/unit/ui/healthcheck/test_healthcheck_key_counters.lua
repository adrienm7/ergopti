--- tests/unit/ui/healthcheck/test_healthcheck_key_counters.lua

--- ==============================================================================
--- MODULE: Healthcheck reports the key-event counters (macOS)
--- DESCRIPTION:
--- The session's key_event_health counters (key-ups without key-down, lost
--- key-ups, stuck and long-held keys, late callbacks, late keys passed
--- untouched, lease failures) were only written to the driver log, so a
--- Markdown diagnostics report of a swallowed-key complaint carried none of
--- them (key-event-counters-in-report). They are now fields of the input
--- section: counts only, never a key code or a character.
--- ==============================================================================

local helpers = require("tests.helpers")

local SCHEMA_PATH = "../_shared/modules/diagnostics/schema.json"

-- The input-section ids the schema declares for the counters, in its order
local COUNTER_IDS = {
	"key_downs", "key_ups", "key_ups_orphaned", "key_ups_lost", "key_stuck",
	"key_long_holds", "key_late", "key_late_passed", "key_lease_failures",
}

--- Runs body with the real collector over the real counters.
--- @param body function Receives (H, Health).
local function with_collector(body)
	local saved, prior_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, err = xpcall(function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "running", { phase = "running" } end,
		}
		package.loaded["infra.key_event_health"] = nil
		package.loaded["ui.healthcheck.helpers"] = nil
		body(require("ui.healthcheck.helpers"), require("infra.key_event_health"))
	end, debug.traceback)
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("healthcheck: key-event counters in the input section (key-event-counters-in-report)", function()
	helpers.it("reports every counter the session recorded, and no key identity", function()
		with_collector(function(H, Health)
			Health.reset()
			-- A lost key-up, an orphan key-up, a press and a release, a lease failure.
			Health.observe("down", 11, false, true)
			Health.observe("down", 11, false, true)
			Health.observe("up", 12, false, true)
			Health.observe("down", 13, false, true)
			Health.observe("up", 13, false, true)
			Health.note_stale_pass()
			Health.note_lease_failure("timeout waiting for PONG 4")
			local input = H.collect_input()
			helpers.assert_eq(input.key_downs, 3)
			helpers.assert_eq(input.key_ups, 2)
			helpers.assert_eq(input.key_ups_orphaned, 1)
			helpers.assert_eq(input.key_ups_lost, 1)
			helpers.assert_eq(input.key_late_passed, 1)
			helpers.assert_eq(input.key_lease_failures, 1)
			helpers.assert_eq(input.key_stuck, 0)
			for _, id in ipairs(COUNTER_IDS) do
				helpers.assert_eq(math.type(input[id]), "integer", id .. " is a plain count")
			end
		end)
	end)

	helpers.it("declares each counter in the schema's input section and in the share projection", function()
		local handle = assert(io.open(SCHEMA_PATH, "rb"))
		local schema = handle:read("a")
		handle:close()
		for _, id in ipairs(COUNTER_IDS) do
			local pattern = '"id": "' .. id .. '",\n%s*"type": "count"'
			helpers.assert_true(schema:find(pattern) ~= nil, id .. " is a section field")
			helpers.assert_true(schema:find('"' .. id .. '": {\n%s*"kind": "integer"') ~= nil,
				id .. " is in the closed share projection")
		end
	end)
end)
