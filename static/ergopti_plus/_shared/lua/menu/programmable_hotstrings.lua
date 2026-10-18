--- _shared/lua/menu/programmable_hotstrings.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu Policy
--- DESCRIPTION:
--- Projects declared source commands and feature controls through native ports.
--- Rendering reads metadata only; source factories run solely on explicit actions.
--- ==============================================================================

local M = {}
local FEATURE = "hotstrings.dynamic.user_code"

--- Projects the declared parent around already rendered native child controls.
--- @param manifest table Driver-bound manifest renderer.
--- @param build function Native source-control builder.
--- @return table rows Declared parent rows.
function M.build_entry(manifest, build)
	return manifest.build("programmable_hotstring_entry", "Hotstrings", nil, {
		programmable_hotstrings = build,
	}, {})
end

--- Supplies the declared parent as data for a category list provider.
--- The child subtree is already rendered; `submenu` preserves its native
--- callbacks without handing a finished parent row to a second renderer.
--- @param manifest table Driver-bound actual manifest renderer.
--- @param build function Native source-control builder.
--- @return table rows Provider data around the declared parent.
function M.build_entry_rows(manifest, build)
	local rows = {}
	for _, parent in ipairs(M.build_entry(manifest, build)) do
		rows[#rows + 1] = { label = parent.title, submenu = parent.menu,
			checked = parent.checked, disabled = parent.disabled }
	end
	return rows
end

-- The source problems the native owner reports, each shown on the feature row.
local PROBLEMS = { missing = true, failed = true }

--- Builds equivalent menu controls around one exact native runtime owner.
---
--- A source problem is never a dialog: the feature row names it (« — source
--- missing »), opening a missing source is greyed, and creating the example
--- loads it at once when the option is on. A refused action redraws the menu
--- so the row shows the state the owner now reports.
--- @param ports table Manifest, translation, preference, native and problem ports.
--- @return table menu Native renderer output.
function M.build(ports)
	local function refused()
		ports.changed()
		return false
	end
	local problem = ports.problem()
	assert(problem == nil or PROBLEMS[problem], "unknown programmable source problem: " .. tostring(problem))
	local function mutation(enabled, seconds)
		if ports.paused() or ports.master() ~= true or type(enabled) ~= "boolean"
			or type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds >= math.huge then return refused() end
		if ports.set(enabled, seconds) ~= true then return refused() end
		ports.changed()
		return true
	end
	local function command(operation)
		return function()
			local ok, committed = pcall(operation)
			if not ok or committed ~= true then return refused() end
			ports.changed()
			return true
		end
	end
	--- Creates the example (never over an existing source), then, when the
	--- option is on, enables it at once so the problem the row showed is gone.
	--- @return boolean repaired
	local function repair_with_example()
		if ports.create() ~= true then return false end
		local enabled, seconds = ports.get()
		if enabled ~= true or ports.paused() or ports.master() ~= true then return true end
		return ports.set(true, seconds) == true
	end
	local feature_rows = {}
	feature_rows[FEATURE] = function()
		local enabled, seconds = ports.get()
		local blocked = ports.paused() or ports.master() ~= true
		local label = ports.i18n("menu.hotstrings.user_code.title")
		if problem then label = label .. " — " .. ports.i18n("menu.hotstrings.user_code.problem_" .. problem) end
		return { label = label, checked = enabled,
			items = {
				{ label = ports.i18n("menu.hotstrings.user_code.title"), checked = enabled, disabled = blocked,
					action = function()
						local live, interval = ports.get()
						return mutation(not live, interval)
					end },
				{ label = ports.i18n("hs_config.label_delay") .. ": " .. tostring(seconds * 1000), disabled = blocked,
					action = function()
						local live, interval = ports.get()
						local selected = ports.prompt(interval * 1000)
						if selected == nil then return false end
						local current_enabled, current_interval = ports.get()
						if current_enabled ~= live or current_interval ~= interval then return refused() end
						local milliseconds = tonumber(selected)
						if not milliseconds or milliseconds < 0 or milliseconds ~= milliseconds
							or milliseconds >= math.huge or milliseconds % 1 ~= 0 then return refused() end
						return mutation(live, milliseconds / 1000)
					end },
			} }
	end
	local open = command(ports.open)
	local rows = ports.manifest.build("programmable_hotstrings", "Hotstrings", nil, nil, {
		feature_rows = feature_rows,
		commands = {
			open_user_hotstring_source = open,
			reload_user_hotstring_source = command(ports.reload),
			create_user_hotstring_example = command(repair_with_example),
		},
	})
	-- A missing source has nothing to open: the example row creates it.
	if problem == "missing" then
		for _, row in ipairs(rows) do
			if row.fn == open then row.disabled = true end
		end
	end
	return rows
end

return M
