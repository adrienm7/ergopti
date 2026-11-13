--- _shared/layouts/engine/emulation/menu.lua

--- ==============================================================================
--- MODULE: Layout Emulation Menu Rows (Shared)
--- DESCRIPTION:
--- The row data macOS and Linux draw for the layout emulation in the Keyboard
--- layout menu: the « Layout to emulate » submenu (none, the built-in Ergopti
--- variants, the registry layouts) and the switch rows of its layers and rows.
--- Pure data: the drivers' renderers materialise the rows and own the writes.
--- ==============================================================================

local LabelValue = require("core.i18n.engine.label_value")

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
	if settings.base ~= true and settings.alt_gr ~= true then return "none" end
	return settings.id == "ergopti_plus" and "ergopti_plus" or "ergopti"
end

--- The « Layout to emulate » submenu.
--- @param opts table { t, settings, status = { active, id, error }, snapshot = layout registry snapshot,
---   choose = function(choice) }
--- @return table rows One row holding the choices.
function M.choice_rows(opts)
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
	local items, shown = {}, nil
	local function add(value, label)
		if value == current then shown = label end
		items[#items + 1] = { label = label, checked = value == current, action = function() opts.choose(value) end }
	end
	for _, choice in ipairs(M.BUILTIN) do add(choice.value, t(choice.label_key)) end
	for _, entry in ipairs(registry_ids) do add(entry.id, entry.name) end
	if shown == nil then
		-- A stored layout absent from the catalogue stays named, never "none".
		shown = current
		add(current, current)
	end
	if type(opts.status) == "table" and opts.status.error ~= nil then
		shown = shown .. " — " .. t("menu.layout.emulation_failed")
	end
	return { { label = LabelValue.compose(t, t("menu.layout.emulated_layout"), shown), items = items } }
end

--- One switch row of the emulation.
--- @param opts table { t, label_key, checked, toggle = function(new_value) }
--- @return table row
function M.switch_row(opts)
	local checked = opts.checked == true
	return { label = opts.t(opts.label_key), checked = checked, action = function() opts.toggle(not checked) end }
end

return M
