--- tests/unit/infra/lifecycle/test_reload_timing.lua

--- ==============================================================================
--- MODULE: Reload Duration Across The Restart Tests
--- DESCRIPTION:
--- A Linux Reload restarts the daemon, so its duration runs from the request
--- in one process to the successor's boot completion in the next. The stamp
--- between them is real bytes on disk, the clock is injected, and the lines are
--- the delivered log lines the field log analyser reads (linux-reload-budget).
--- ==============================================================================

local helpers = require("tests.support.logger_fixture").helpers({ "infra.reload_timing", "perf_budget" })

--- Loads a fresh module whose stamp lives in a private folder, with the real logger.
--- @param budget_ms number The driver_reload_ms the judge reads.
--- @return table timing, table lines, table clock, function cleanup
local function fixture(budget_ms)
	package.loaded["logger"] = nil
	package.loaded["logger.shim"] = nil
	local logger = require("logger")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(20)
	local root = assert(require("luv").fs_mkdtemp("/var/tmp/eg-reload-XXXXXX"))
	local Storage = require("adapters.storage")
	local Timings = require("infra.timings")
	local held_path, held_ms = Storage.path, Timings.ms
	Storage.path = function() return root .. "/store/state.json" end
	Timings.ms = function(section, key)
		if section == "budgets" and key == "driver_reload_ms" then return budget_ms end
		return held_ms(section, key)
	end
	local timing = helpers.load_module("infra.reload_timing")
	local clock = { now = 1700000000000 }
	timing._use_clock(function() return clock.now end)
	local function cleanup()
		timing._use_clock(nil)
		Storage.path, Timings.ms = held_path, held_ms
		os.remove(root .. "/store/state.json.reload-requested")
		os.remove(root .. "/store")
		assert(os.remove(root))
	end
	return timing, lines, clock, cleanup
end

--- The delivered lines that contain a text.
local function matching(lines, text)
	local found = {}
	for _, line in ipairs(lines) do if line:find(text, 1, true) then found[#found + 1] = line end end
	return found
end

helpers.describe("Linux reload duration across the restart (linux-reload-budget)", function()
	helpers.it("(linux-reload-budget) measures a reload from its request to the successor's boot and judges its budget", function()
		local timing, lines, clock, cleanup = fixture(4000)
		local ok, failure = pcall(function()
			helpers.assert_eq(timing.mark(), true, "the request is stamped")
			clock.now = clock.now + 4321
			helpers.assert_eq(timing.complete(), 4321)
			helpers.assert_eq(#matching(lines, "Reload completed in 4321 ms (reload request to boot complete)."), 1)
			helpers.assert_eq(#matching(lines, "Over budget: reload took 4321 ms (budget 4000 ms)."), 1)
			helpers.assert_eq(timing.complete(), nil, "the stamp is one-shot: the next boot follows no reload")
		end)
		cleanup()
		if not ok then error(failure, 0) end
	end)

	helpers.it("(linux-reload-budget) stays silent on a reload within its budget and on a boot that follows none", function()
		local timing, lines, clock, cleanup = fixture(4000)
		local ok, failure = pcall(function()
			helpers.assert_eq(timing.complete(), nil, "an ordinary start reports no reload")
			timing.mark()
			clock.now = clock.now + 900
			helpers.assert_eq(timing.complete(), 900)
			helpers.assert_eq(#matching(lines, "Reload completed in 900 ms"), 1)
			helpers.assert_eq(#matching(lines, "Over budget"), 0)
		end)
		cleanup()
		if not ok then error(failure, 0) end
	end)

	helpers.it("(linux-reload-budget) a refused restart's stamp is cleared, so the next start reports no reload", function()
		local timing, lines, _, cleanup = fixture(4000)
		local ok, failure = pcall(function()
			timing.mark()
			helpers.assert_eq(timing.clear(), true)
			helpers.assert_eq(timing.complete(), nil)
			helpers.assert_eq(#matching(lines, "Reload completed"), 0)
		end)
		cleanup()
		if not ok then error(failure, 0) end
	end)

	helpers.it("(linux-reload-budget) a malformed stamp or a clock that moved back is logged and retired, never reported", function()
		local timing, lines, clock, cleanup = fixture(4000)
		local ok, failure = pcall(function()
			timing.mark()
			local handle = assert(io.open(timing.path(), "w")); assert(handle:write("garbage\n")); assert(handle:close())
			helpers.assert_eq(timing.complete(), nil)
			helpers.assert_eq(#matching(lines, "unreadable or malformed"), 1)
			helpers.assert_eq(io.open(timing.path(), "r"), nil, "the malformed stamp is retired")
			timing.mark()
			clock.now = clock.now - 50
			helpers.assert_eq(timing.complete(), nil)
			helpers.assert_eq(#matching(lines, "the clock moved back"), 1)
			helpers.assert_eq(#matching(lines, "Reload completed"), 0)
		end)
		cleanup()
		if not ok then error(failure, 0) end
	end)
end)
