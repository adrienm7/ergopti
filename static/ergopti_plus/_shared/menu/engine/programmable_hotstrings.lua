--- _shared/menu/engine/programmable_hotstrings.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu Policy
--- DESCRIPTION:
--- Projects declared source commands and feature controls through native ports.
--- Rendering reads metadata only; source factories run solely on explicit actions.
--- ==============================================================================

local ConfigKeys = require("settings.engine.keys")
local LabelValue = require("core.i18n.engine.label_value")
local ValueCheck = require("settings.engine.value_check")

-- The typed activation delay's shared value schema declaration.
local DELAY_KEY = ValueCheck.KEY.HOTSTRINGS_DYNAMIC_USER_CODE_TIME_ACTIVATION_SECONDS
local M = {}
local FEATURE = ConfigKeys.KEY.HOTSTRINGS_DYNAMIC_USER_CODE

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
--- A typed activation delay its value schema declaration refuses is passed
--- to `ports.refusal` with the localized text naming the range (decided by the
--- agent on 2026-11-14, to review by the maintainer: the 2026-11-13 validation
--- contract asks for that text at entry); every other refusal stays a redraw.
--- @param ports table Manifest, translation, preference, native, problem and
---   refusal(message) ports.
--- @return table menu Native renderer output.
function M.build(ports)
	assert(type(ports.refusal) == "function", "programmable menu needs a refusal port")
	local function refused()
		ports.changed()
		return false
	end
	local problem = ports.problem()
	assert(problem == nil or PROBLEMS[problem], "unknown programmable source problem: " .. tostring(problem))
	local function mutation(enabled, seconds)
		if ports.paused() or ports.master() ~= true or type(enabled) ~= "boolean"
			or not ValueCheck.check_value(ValueCheck.declaration(DELAY_KEY), seconds).ok then return refused() end
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
				{ label = LabelValue.compose(ports.i18n, ports.i18n("hs_config.label_delay"), seconds * 1000), disabled = blocked,
					action = function()
						local live, interval = ports.get()
						local selected = ports.prompt(interval * 1000)
						if selected == nil then return false end
						local current_enabled, current_interval = ports.get()
						if current_enabled ~= live or current_interval ~= interval then return refused() end
						-- A malformed or out-of-range delay is the one refusal
						-- told in words: the driver shows the shared message
						-- naming the range, as for its other delay prompts.
						local typed = ValueCheck.parse_entry(ValueCheck.declaration(DELAY_KEY), selected)
						if not typed.ok then
							ports.refusal(ValueCheck.refusal_text(DELAY_KEY, typed, ports.i18n))
							return refused()
						end
						return mutation(live, typed.value)
					end },
			} }
	end
	local commands = {
		open_user_hotstring_source = command(ports.open),
		reload_user_hotstring_source = command(ports.reload),
		create_user_hotstring_example = command(repair_with_example),
	}
	local rows = ports.manifest.build("programmable_hotstrings", "Hotstrings", nil, nil, {
		feature_rows = feature_rows,
		commands = commands,
	})
	-- A missing source has nothing to open: the example row creates it.
	if problem == "missing" then
		for _, row in ipairs(rows) do
			if row.fn == commands.open_user_hotstring_source then row.disabled = true end
		end
	end
	return rows
end

return M
