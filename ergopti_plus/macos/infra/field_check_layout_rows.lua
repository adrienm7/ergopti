--- infra/field_check_layout_rows.lua

--- ==============================================================================
--- MODULE: Field Check, Layout Rows Live Replace
--- DESCRIPTION:
--- The field run's proof of the number-row options on macOS
--- (docs/design/layout-option-emulation.md, section 3.1), with no person: it
--- builds a layout that types the symbols first from the Ergo-L file shipped with
--- the app, installs, selects and reads it back (modules/keymap/
--- layout_rows_build.lua), replaces it live by a second build that also moves the
--- edge keys, then puts back the user's exact input sources.
---
--- FEATURES & RATIONALE:
--- 1. The steps are the questions the Mac must answer: rows_build is M4 (a new
---    name types its cells at once, no logout), rows_replace is the live replace
---    with the previous build retired, rows_restore is the guarantee that the
---    user's selected source and enabled list are back byte for byte.
--- 2. Its own record and file prefix: the user's own builds are never touched,
---    and the counter persists across runs, because macOS keeps the cells of a
---    name it has seen until logout (probe M3).
--- 3. The restore always runs once a build was attempted, whatever failed.
--- ==============================================================================

local Report = require("field_check_report")
local Logger = require("infra.logger")

local M = {}

local LOG = "field_check.layout_rows"
local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

-- The two builds: symbols first, then the same with the edge keys.
M.FIRST_ROWS = { order = "symbols", edges = false }
M.SECOND_ROWS = { order = "symbols", edges = true }

--- Runs the check.
--- ports.layout_rows_env() -> env | nil, err, where env has: source { id,
--- keyboard_name, text, convention }, replace(source, rows, on_done),
--- retire_all(on_done(ok, left)), exists(path), sources_state(on_done(ok, state,
--- reason)) with state { selected, enabled_json }, select_id(id, on_done(ok, reason)).
--- @param ports table
--- @param report table
--- @param finish function
function M.layout_rows(ports, report, finish)
	local env, env_err = ports.layout_rows_env()
	if type(env) ~= "table" then
		Logger.error(LOG, "The layout rows check has no environment: %s.", tostring(env_err))
		report.step("rows_env", FAIL, "unusable")
		return finish()
	end
	env.sources_state(function(read, before, read_reason)
		if not read or type(before.selected) ~= "string" or type(before.enabled_json) ~= "string" then
			report.step("rows_snapshot", FAIL, read_reason or "unreadable")
			return finish()
		end
		Logger.evidence(LOG, "Input sources before the check: selected %s.", before.selected)
		report.step("rows_snapshot", INFO, "read")

		local function restore()
			env.select_id(before.selected, function(selected, select_reason)
				if not selected then
					Logger.error(LOG, "The user's input source %s was not selected again: %s.", before.selected,
						tostring(select_reason))
				end
				env.retire_all(function(retired, left)
					report.step("rows_retire", retired and PASS or FAIL, retired and nil or ("left_" .. tostring(left)))
					env.sources_state(function(again, after)
						if not again then
							report.step("rows_restore", FAIL, "unreadable")
							return finish()
						end
						local same_selected = after.selected == before.selected
						local same_enabled = after.enabled_json == before.enabled_json
						Logger.evidence(LOG, "Input sources after the check: selected %s, enabled list %s.",
							tostring(after.selected), same_enabled and "identical" or "different")
						if not same_enabled then
							-- Input-source entries name layouts only: the difference is the evidence.
							Logger.evidence(LOG, "Enabled input sources before: %s", before.enabled_json)
							Logger.evidence(LOG, "Enabled input sources after: %s", tostring(after.enabled_json))
						end
						if same_selected and same_enabled then
							report.step("rows_restore", PASS)
						else
							report.step("rows_restore", FAIL, same_selected and "enabled_differs" or "selection_differs")
						end
						finish()
					end)
				end)
			end)
		end

		env.replace(env.source, M.FIRST_ROWS, function(ok, first, detail)
			if not ok then
				Logger.evidence(LOG, "The first build failed (%s): %s.", tostring(first), tostring(detail))
				report.step("rows_build", FAIL, first)
				report.step("rows_replace", SKIP, "no_first_build")
				return restore()
			end
			if first.build == nil then
				report.step("rows_build", FAIL, "nothing_moved")
				report.step("rows_replace", SKIP, "no_first_build")
				return restore()
			end
			Logger.evidence(LOG, "Build '%s' selected and read back from %s (%s).", first.build.name,
				tostring(first.readback.source_id), tostring(first.readback.detail))
			report.step("rows_build", PASS, "keys_" .. tostring(first.readback.keys))
			env.replace(env.source, M.SECOND_ROWS, function(replaced, second, second_detail)
				if not replaced or second.build == nil then
					Logger.evidence(LOG, "The live replace failed (%s): %s.", tostring(second), tostring(second_detail))
					report.step("rows_replace", FAIL, replaced and "nothing_moved" or second)
					return restore()
				end
				Logger.evidence(LOG, "Build '%s' replaced '%s' live (%s); %d earlier build(s) still listed.",
					second.build.name, first.build.name, tostring(second.readback.detail), second.ghosts or 0)
				if env.exists(first.build.path) then
					report.step("rows_replace", FAIL, "previous_left")
				else
					report.step("rows_replace", PASS, "edges_" .. tostring(second.report.edges.applies))
				end
				report.step("rows_ghosts", INFO, second.ghosts or 0)
				restore()
			end)
		end)
	end)
end

return M
