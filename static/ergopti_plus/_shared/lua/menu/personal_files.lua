--- _shared/lua/menu/personal_files.lua

--- ==============================================================================
--- MODULE: Personal File Menu Policy
--- DESCRIPTION:
--- Renders declared controls around captured native source and preference owners.
--- Metadata dialogs reuse the application configuration window; blocked fields
--- remain individually unavailable without closing authoritative file gates.
--- ==============================================================================

local M = {}
local FIELDS = { personal_file_delay = "delay", personal_file_priority = "priority",
	personal_file_color = "color", personal_file_tooltip = "show_tooltip" }

--- Builds actual declared per-file controls around native publication callbacks.
--- @param ports table Manifest, exact source admission, state and mutation ports.
--- @return table rows Native renderer output.
function M.build(ports)
	local function ready(field)
		return ports.current() == true and (field == nil or ports.available(field) == true)
	end
	local function mutation(field, callback)
		return function()
			if not ready(field) then return false end
			local called, accepted = pcall(callback)
			if not called or accepted ~= true then return false end
			ports.changed()
			return true
		end
	end
	local commands = {
		["personal_file_enabled"] = mutation(nil, function() return ports.enable(not ports.enabled()) end),
		["personal_file_delay"] = mutation("delay", function() return ports.edit("delay") end),
		["personal_file_priority"] = mutation("priority", function() return ports.edit("priority") end),
		["personal_file_color"] = mutation("color", function() return ports.edit("color") end),
		["personal_file_tooltip"] = mutation("show_tooltip", function() return ports.tooltip(not ports.tooltip_enabled()) end),
	}
	local rows = ports.manifest.build("personal_file_controls", "Hotstrings", nil, nil, {
		commands = commands,
		state_getters = {
			["personal_file_owner_ready"] = function() return ready() end,
			["personal_file_enabled"] = ports.enabled,
			["personal_file_tooltip"] = ports.tooltip_enabled,
		},
	})
	for index, declared in ipairs(ports.manifest.get_array("personal_file_controls")) do
		local field, row = FIELDS[declared.id], rows[index]
		if field and row and not ready(field) and ready() then
			row.disabled, row.fn = true, nil
			row.title = row.title .. " — " .. ports.metadata_reason()
		end
	end
	if not ready() then
		for _, row in ipairs(M.unavailable(ports.manifest)) do rows[#rows + 1] = row end
	end
	return rows
end

--- Displays an unavailable file without deriving any input or output authority.
--- @param manifest table Actual driver-bound renderer.
--- @return table rows Native disabled rows.
function M.unavailable(manifest)
	return manifest.build("personal_file_unavailable", "Hotstrings", nil, nil, {
		commands = { ["personal_file_unavailable"] = function() return false end },
		state_getters = { ["personal_file_owner_ready"] = function() return false end },
	})
end

--- Displays one actually skipped native directory as a read-only diagnostic.
--- @param manifest table Actual driver-bound renderer.
--- @return table rows Native disabled rows.
function M.directory_unavailable(manifest)
	return manifest.build("personal_directory_unavailable", "Hotstrings", nil, nil, {
		commands = { ["personal_directory_unavailable"] = function() return false end },
		state_getters = { ["personal_directory_ready"] = function() return false end },
	})
end

--- Closes generic native category commands when exact file ownership refuses.
--- Declared command labels identify the renderer's own scope rows; unrelated
--- native sections and file actions keep their original callbacks and state.
--- @param rows table Actual native category renderer output.
--- @param ports table Manifest, translation and exact source-admission ports.
--- @return table rows The same native array with unavailable scope controls closed.
function M.apply_category_admission(rows, ports)
	if ports.readonly ~= true and (ports.current == nil or ports.current() == true) then return rows end
	local scope_titles = {}
	for _, declared in ipairs(ports.manifest.get_array("hotstring_category_menu")) do
		if declared.id == "hotstring_category_enable_all" or declared.id == "hotstring_category_disable_all" then
			scope_titles[ports.translate(declared.i18n)] = true
		end
	end
	for _, row in ipairs(rows) do
		if scope_titles[row.title] then row.disabled, row.fn = true, nil end
	end
	return rows
end

return M
