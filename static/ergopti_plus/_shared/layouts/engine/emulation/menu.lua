--- _shared/layouts/engine/emulation/menu.lua

--- ==============================================================================
--- MODULE: Layout Emulation Menu Rows (Shared)
--- DESCRIPTION:
--- The row data macOS and Linux draw for the layout emulation in the Keyboard
--- layout menu: the « Layout to emulate » submenu (none, the layouts chosen
--- last, « Others… »), the choices of the picker window « Others… » opens (the
--- built-in Ergopti variants, the registry layouts) and the switch rows of its
--- layers and rows.
--- Pure data: the drivers' renderers materialise the rows and own the writes.
--- ==============================================================================

local LabelValue = require("core.i18n.engine.label_value")
local Recents = require("layouts.engine.emulation.recents")

local M = {}

-- The built-in choices, in menu order, with the onboarding's labels.
M.BUILTIN = {
	{ value = "none", label_key = "onboarding.layout.emulated_none" },
	{ value = "ergopti", label_key = "onboarding.layout.emulated_ergopti" },
	{ value = "ergopti_plus", label_key = "onboarding.layout.emulated_ergopti_plus" },
}

--- The current choice of the settings, in the vocabulary of the choices.
--- @param settings table layouts/engine/emulation/settings.lua's resolve result.
--- @param emulated_layout string|nil The registry id chosen outside the built-in variants.
--- @return string "none", "ergopti", "ergopti_plus" or a registry id.
local function current_choice(settings, emulated_layout)
	if type(emulated_layout) == "string" and emulated_layout ~= "" then return emulated_layout end
	-- The selection alone: the layer switches select no layout.
	if settings.id == nil then return "none" end
	return settings.id == "ergopti_plus" and "ergopti_plus" or "ergopti"
end

--- Every choice, the choice in force and its label.
--- @param opts table { t, settings, snapshot = layout registry snapshot }
--- @return table choices Array of { value, label }, « None » first.
--- @return string current The choice in force.
--- @return string shown The label of the choice in force.
local function all_choices(opts)
	local t, settings, snapshot = opts.t, opts.settings, opts.snapshot or {}
	local registry_ids = {}
	for _, entry in ipairs(type(snapshot.index) == "table" and snapshot.index.layouts or {}) do
		if type(entry) == "table" and type(entry.id) == "string" and entry.id ~= "ergopti" and entry.id ~= "ergopti_plus" then
			registry_ids[#registry_ids + 1] = { id = entry.id, name = type(entry.name) == "string" and entry.name or entry.id }
		end
	end
	for id, entry in pairs(type(snapshot.installed) == "table" and snapshot.installed or {}) do
		local listed = false
		for _, known in ipairs(registry_ids) do listed = listed or known.id == id end
		if not listed and id ~= "ergopti" and id ~= "ergopti_plus" then
			registry_ids[#registry_ids + 1] = { id = id, name = type(entry.name) == "string" and entry.name or id }
		end
	end
	table.sort(registry_ids, function(a, b) return a.name < b.name end)
	-- The id stored in emulated_layout tells a registry choice from a built-in one.
	local emulated_layout = settings.id ~= nil and settings.id ~= "ergopti" and settings.id ~= "ergopti_plus"
		and settings.id or nil
	local current = current_choice(settings, emulated_layout)
	local choices, shown = {}, nil
	local function add(value, label)
		if value == current then shown = label end
		choices[#choices + 1] = { value = value, label = label }
	end
	for _, choice in ipairs(M.BUILTIN) do add(choice.value, t(choice.label_key)) end
	for _, entry in ipairs(registry_ids) do add(entry.id, entry.name) end
	if shown == nil then
		-- A stored layout absent from the catalogue stays named, never "none".
		shown = current
		add(current, current)
	end
	return choices, current, shown
end

--- The « Layout to emulate » submenu: one radio group of « None » and the
--- quick choices (the layout in force and the ones chosen last,
--- layouts/engine/emulation/recents.lua), then « Others… », which opens the
--- picker of every layout (maintainer decision of 2026-11-25).
--- @param opts table { t, settings, status = { active, id, error }, snapshot = layout registry snapshot,
---   choose = function(choice) -> committed, open_picker = function({ choices, choose }),
---   others_rows = function(open) -> rows }: open_picker is the driver's picker window
---   (ui/emulation_picker), handed the choices of M.picker_choices and the same choose
---   the radio rows run; others_rows renders the menu manifest's
---   layout_emulation_others_commands with open as the « Others… » command.
--- @return table rows One row holding the choices.
function M.choice_rows(opts)
	if type(opts.choose) ~= "function" or type(opts.open_picker) ~= "function"
		or type(opts.others_rows) ~= "function" then
		error("The layout to emulate needs its choose and open_picker actions and the menu templates.")
	end
	local t = opts.t
	local choices, current, shown = all_choices(opts)
	local labels = {}
	for _, choice in ipairs(choices) do labels[choice.value] = choice.label end
	local recents = type(opts.settings.recents) == "table" and opts.settings.recents or {}
	local quick = Recents.quick(current, recents, function(id) return labels[id] ~= nil end)
	local items = {}
	local function add(value)
		-- One choice of several: drawn as a radio where the tray has one.
		items[#items + 1] = { label = labels[value], checked = value == current, radio = true,
			action = function() opts.choose(value) end }
	end
	add("none")
	for _, id in ipairs(quick) do add(id) end
	local others = opts.others_rows(function()
		return opts.open_picker({ choices = function() return M.picker_choices(opts) end, choose = opts.choose })
	end)
	if type(others) ~= "table" then error("The menu manifest refused layout_emulation_others_commands.") end
	for _, row in ipairs(others) do items[#items + 1] = row end
	if type(opts.status) == "table" and opts.status.error ~= nil then
		shown = shown .. " — " .. t("menu.layout.emulation_failed")
	end
	return { { label = LabelValue.compose(t, t("menu.layout.emulated_layout"), shown), items = items } }
end

--- The choices of the emulation picker window (_shared/ui/emulation_picker):
--- every layout the menu could emulate, « None » left to the menu's first row.
--- @param opts table { t, settings, snapshot = layout registry snapshot }
--- @return table choices Array of { id, label, current }.
function M.picker_choices(opts)
	local choices, current = all_choices(opts)
	local result = {}
	for _, choice in ipairs(choices) do
		if choice.value ~= "none" then
			result[#result + 1] = { id = choice.value, label = choice.label, current = choice.value == current }
		end
	end
	return result
end

--- One switch row of the emulation.
--- @param opts table { t, label_key, checked, toggle = function(new_value) }
--- @return table row
function M.switch_row(opts)
	local checked = opts.checked == true
	return { label = opts.t(opts.label_key), checked = checked, action = function() opts.toggle(not checked) end }
end

return M
