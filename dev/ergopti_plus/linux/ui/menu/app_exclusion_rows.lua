--- ui/menu/app_exclusion_rows.lua

--- ==============================================================================
--- MODULE: Excluded Applications Rows (Linux tray)
--- DESCRIPTION:
--- The submenu that edits a list of applications: one row per excluded
--- application (clicking removes it), the application last typed in, then any
--- other chosen from the windows on screen or typed.
---
--- FEATURES & RATIONALE:
--- 1. Row data only: the shared renderer draws it, so the submenu looks like the
---    macOS one, built from the same translated strings.
--- 2. The list lives in its owner. This module reads it at build time and again
---    at click time, so a list changed since the menu was drawn is never
---    overwritten by a stale copy.
--- 3. Dialogs are handed in by the menu builder, so this module never opens a
---    window the keyboard grab would starve (ui/modal.lua).
--- ==============================================================================

local M = {}
local TextUtils = require("text_utils")

--- A translated string, or its key when the catalogue cannot answer.
--- @param key string
--- @return string
local function tr(key)
	local ok, i18n = pcall(require, "infra.i18n")
	local value = ok and type(i18n.get) == "function" and i18n.get(key) or nil
	return type(value) == "string" and value ~= "" and value or key
end

--- The applications a user may exclude without typing their identifier: the
--- ones with a window on screen, when the session can list them.
--- @param excluded table Set of excluded identifiers.
--- @return table Array of identifiers.
local function running_apps(excluded)
	local ok, WindowInfo = pcall(require, "adapters.window_info")
	if not ok then return {} end
	local list, seen = {}, {}
	for _, info in ipairs(WindowInfo.getAll()) do
		local app = type(info) == "table" and info.appId or nil
		if type(app) == "string" and app ~= "" and not seen[app] and not excluded[app] then
			seen[app] = true
			list[#list + 1] = app
		end
	end
	table.sort(list)
	return list
end

--- The caption of the row that opens the submenu.
--- @param count integer Number of excluded applications.
--- @param keys table|nil { none = locale key of the empty caption, counted = locale key of the
---   "%d application%s" caption }; the metrics exclusion list's when absent.
--- @return string
function M.caption(count, keys)
	keys = keys or { none = "menu.metrics.exclude_apps", counted = "menu.metrics.disabled_in_label" }
	if count <= 0 then return tr(keys.none) end
	return string.format(tr(keys.counted), count, count > 1 and "s" or "")
end

--- Builds the rows of the submenu.
--- @param options table {
---   get = function() -> list, set = function(list) -> boolean,
---   current = function() -> string|nil, prompt = function(title, text, initial, hidden, choices),
---   title = string, changed = function() }
--- @return table rows Row data { label, action? }.
function M.rows(options)
	local apps = options.get()
	local excluded = {}
	for _, app in ipairs(apps) do excluded[app] = true end

	local function store(list)
		if options.set(list) then options.changed() end
	end
	local function add(app)
		local list = options.get()
		for _, existing in ipairs(list) do
			if existing == app then return end
		end
		list[#list + 1] = app
		store(list)
	end

	local rows = {}
	for _, app in ipairs(apps) do
		rows[#rows + 1] = {
			label = tr("app_picker.agent_remove_marker") .. "  " .. app,
			action = function()
				local list = {}
				for _, existing in ipairs(options.get()) do
					if existing ~= app then list[#list + 1] = existing end
				end
				store(list)
			end,
		}
	end
	local last = options.current()
	if type(last) == "string" and last ~= "" and not excluded[last] then
		rows[#rows + 1] = {
			label = string.format(tr("app_picker.agent_exclude_current_caption"), last),
			action = function() add(last) end,
		}
	end
	rows[#rows + 1] = {
		label = tr("app_picker.add_another_app"),
		action = function()
			local answer = options.prompt(options.title, tr("app_picker.search_placeholder"), "", false,
				running_apps(excluded))
			if answer == nil then return end
			answer = TextUtils.trim(answer)
			if answer == "" then return end
			add(answer)
		end,
	}
	return rows
end

return M
