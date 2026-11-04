--- _shared/lua/test/logger_volume_contract.lua

--- ==============================================================================
--- MODULE: Logger Volume Counters Contract
--- DESCRIPTION:
--- Proves the log-volume counters of the shared logger core (spec § 5.3), which
--- the macOS and Linux loggers both run: lines written per level, and the lines
--- that never were (filtered by level, suppressed by the consecutive dedup,
--- collapsed by the repeat collapser), plus the interval report both drivers put
--- in their evidence record.
--- ==============================================================================

return function(helpers, shared_root)
	--- Loads a fresh core with a driven clock and a counting sink.
	--- @return table core, table state { now = number, lines = table }
	local function fresh()
		local core = dofile(shared_root .. "/lua/logger/init.lua")
		local state = { now = 0, lines = {} }
		core.clock_fn = function() return state.now end
		core.timestamp_fn = function() return "2026-10-25 10:00:00:000" end
		core.set_level("debug")
		core.set_sink(function(line) state.lines[#state.lines + 1] = line end)
		return core, state
	end

	helpers.describe("Logger volume counters", function()
		helpers.it("counts written lines under the four levels, lifecycle variants included", function()
			local core = fresh()
			core.debug("m", "a"); core.trace("m", "b"); core.done("m", "c")
			core.info("m", "d"); core.start("m", "e"); core.success("m", "f")
			core.warn("m", "g"); core.error("m", "h")
			local volume = core.volume()
			helpers.assert_eq({ volume.debug, volume.info, volume.warn, volume.error }, { 3, 3, 1, 1 })
			helpers.assert_eq({ volume.dropped, volume.suppressed, volume.collapsed }, { 0, 0, 0 })
		end)

		helpers.it("counts a line removed by the severity threshold as dropped and writes nothing", function()
			local core, state = fresh()
			core.set_level("warning")
			core.debug("m", "a"); core.info("m", "b"); core.warn("m", "c")
			local volume = core.volume()
			helpers.assert_eq({ volume.dropped, volume.warn, volume.debug, volume.info }, { 2, 1, 0, 0 })
			helpers.assert_eq(#state.lines, 1)
		end)

		helpers.it("counts a driver-side refusal through note_dropped", function()
			local core = fresh()
			core.note_dropped(); core.note_dropped()
			helpers.assert_eq(core.volume().dropped, 2)
		end)

		helpers.it("counts consecutive duplicates as suppressed and their summary as one written line", function()
			local core = fresh()
			core.info("m", "same"); core.info("m", "same"); core.info("m", "same")
			helpers.assert_eq({ core.volume().info, core.volume().suppressed }, { 1, 2 })
			core.info("m", "other")
			-- The first line, the summary of the two swallowed ones, and the new line.
			helpers.assert_eq({ core.volume().info, core.volume().suppressed }, { 3, 2 })
		end)

		helpers.it("counts repeats the collapser withheld as collapsed", function()
			local core, state = fresh()
			core.enable_repeat_collapsing()
			core.info("m", "poll %d", 1)
			state.now = 10; core.info("m", "other"); core.info("m", "poll %d", 2)
			state.now = 20; core.info("m", "other2"); core.info("m", "poll %d", 3)
			helpers.assert_eq(core.volume().collapsed, 2)
			core.flush_repeats(true)
			-- poll(1), other, other2 and the one repeat summary.
			helpers.assert_eq({ core.volume().info, core.volume().collapsed }, { 4, 2 })
			core.disable_repeat_collapsing()
		end)

		helpers.it("never withholds an evidence record and counts it as an info line", function()
			local core = fresh()
			core.evidence("m", "same"); core.evidence("m", "same")
			helpers.assert_eq({ core.volume().info, core.volume().suppressed }, { 2, 0 })
		end)

		helpers.it("reports intervals without disturbing the totals", function()
			local core = fresh()
			core.info("m", "a"); core.warn("m", "b")
			local first = core.volume_interval()
			helpers.assert_eq({ first.info, first.warn }, { 1, 1 })
			core.error("m", "c")
			local second = core.volume_interval()
			helpers.assert_eq({ second.info, second.warn, second.error }, { 0, 0, 1 })
			local total = core.volume()
			helpers.assert_eq({ total.info, total.warn, total.error }, { 1, 1, 1 })
		end)

		helpers.it("renders the counters in the one documented order", function()
			local core = fresh()
			helpers.assert_eq(core.VOLUME_FIELDS,
				{ "debug", "info", "warn", "error", "dropped", "suppressed", "collapsed" })
			helpers.assert_eq(core.volume_text({ debug = 1, info = 2, warn = 3, error = 4, dropped = 5,
				suppressed = 6, collapsed = 7 }),
				"debug=1 info=2 warn=3 error=4 dropped=5 suppressed=6 collapsed=7")
			helpers.assert_eq(core.volume_text({}), "debug=0 info=0 warn=0 error=0 dropped=0 suppressed=0 collapsed=0")
		end)

		helpers.it("zeroes everything on reset", function()
			local core = fresh()
			core.info("m", "a"); core.note_dropped(); core.volume_interval()
			core.reset_volume()
			helpers.assert_eq(core.volume_text(core.volume()), core.volume_text({}))
			helpers.assert_eq(core.volume_text(core.volume_interval()), core.volume_text({}))
		end)
	end)
end
