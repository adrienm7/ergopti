--- tests/support/ui/menu/llm/manual_profile_selection.lua

--- ==============================================================================
--- MODULE: Manual Profile Selection With Its Actual Menu Owner (Linux)
--- DESCRIPTION:
--- Exercises native row dispatch and conditional persistence together. Extracting
--- only the selection closure omits the source admission captured by its menu.
--- ==============================================================================

local M = {}
local Fixture = require("tests.support.ui.menu.llm.numeric_configuration_fixture")

local function find(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local child = find(row.menu, title)
		if child then return child end
	end
end

--- Preserves every override ACK case while executing the original source owner.
--- @param helpers table Original test assertions.
function M.assert_selection(helpers)
	local scenarios = 0
	for _, kind in ipairs({ "active", "absent", "stop_refused", "stop_throws", "stop_stale",
		"read_throws", "missing", "save_refused", "foreign_root", "foreign_during_stop" }) do
		Fixture.with_configuration(function(f)
			local settings = require("modules.llm.profile_settings")
			assert(settings.save_user_profile({ id = "user_manual", label = "Manual contract",
				system_single = "Continue.", batch = false }, false, false))
			local baseline = f.bytes("a")
			local file = assert(io.open(f.dirs.b .. "/config.toml", "wb"))
			assert(file:write(baseline)); assert(file:close())
			local live
			if kind ~= "absent" then live = { profile_id = "translate_ja" } end
			local stops, commits, refreshes, reads, assignments = 0, 0, 0, 0, 0
			local order, paths = {}, {}
			local owner = { is_enabled = function() return true end,
				get_prediction_model = function() return "owned-model" end }
			owner.get_live = function()
				reads = reads + 1
				if kind == "read_throws" then error("owned read refusal") end
				return live
			end
			owner.set_live = function(value)
				helpers.assert_nil(value, "the exact nil stop argument reaches the existing owner")
				stops = stops + 1; order[#order + 1] = "stop"
				if kind == "stop_throws" then error("owned stop refusal") end
				if kind == "stop_refused" then return false end
				if kind ~= "stop_stale" then live = nil end
				if kind == "foreign_during_stop" then f.switch("b") end
				return true
			end
			if kind == "missing" then owner.get_live = nil end
			local writer, assign = f.writer.batch_write, settings.set
			settings.set = function(name, id, model, admission)
				assignments = assignments + 1
				helpers.assert_eq({ name, id, model }, { "active", "user_manual", "owned-model" },
					"the actual setter receives the chosen setting, identity and prediction model")
				return assign(name, id, model, admission)
			end
			local okay, detail = xpcall(function()
				local rows = require("ui.menu.menu_builder").build({ llm = owner, webview = f.host,
					is_paused = function() return false end,
					on_menu_changed = function() refreshes = refreshes + 1 end })
				local profile = assert(find(rows, "Manual contract"), "actual profile parent exists")
				local row = assert(find(profile.menu, require("infra.i18n").get("menu.profiles.use_profile")))
				f.writer.batch_write = function(path, ...)
					commits = commits + 1; order[#order + 1] = "commit"; paths[#paths + 1] = path
					if kind == "save_refused" then return false, "owned writer refusal" end
					return writer(path, ...)
				end
				if kind == "foreign_root" then f.switch("b") end
				local accepted = row.fn()
				local reaches_writer = kind == "active" or kind == "absent" or kind == "save_refused"
				local saved = kind == "active" or kind == "absent"
				helpers.assert_eq(accepted, saved, kind .. " returns its exact selection ACK")
				helpers.assert_eq(commits, reaches_writer and 1 or 0, kind .. " reaches only its authorized writer")
				helpers.assert_eq(assignments, reaches_writer and 1 or 0, kind .. " reaches the original setting owner")
				helpers.assert_eq(refreshes, saved and 1 or 0, kind .. " redraws only a committed choice")
				if reaches_writer then
					helpers.assert_eq(stops, kind == "absent" and 0 or 1)
					helpers.assert_nil(live, "manual persistence follows the acknowledged override retirement")
					helpers.assert_eq(table.concat(order, ","), kind == "absent" and "commit" or "stop,commit")
					helpers.assert_eq(paths, { f.dirs.a .. "/config.toml" })
				elseif kind == "foreign_root" then
					helpers.assert_eq({ stops, reads }, { 0, 0 }, "a foreign menu cannot inspect or stop the incumbent")
					helpers.assert_eq(live.profile_id, "translate_ja")
				elseif kind == "foreign_during_stop" then
					helpers.assert_eq(stops, 1); helpers.assert_nil(live)
				else
					helpers.assert_eq(stops, (kind == "missing" or kind == "read_throws") and 0 or 1)
					helpers.assert_eq(live.profile_id, "translate_ja", "a refused retirement keeps its live override")
				end
				if saved then
					helpers.assert_eq(f.document("a").llm.profiles.active, "user_manual")
					helpers.assert_eq(f.document("a").independent.keep, "a")
				else helpers.assert_eq(f.bytes("a"), baseline, kind .. " preserves the original source") end
				helpers.assert_eq(f.bytes("b"), baseline, kind .. " never adopts the successor folder")
				scenarios = scenarios + 1
			end, debug.traceback)
			f.writer.batch_write = writer
			settings.set = assign
			if not okay then error(detail, 0) end
		end)
	end
	helpers.assert_eq(scenarios, 10, "all eight override cases and both folder-change cases execute")
	return scenarios
end

return M
