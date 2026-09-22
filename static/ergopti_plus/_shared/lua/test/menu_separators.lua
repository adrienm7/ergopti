--- _shared/lua/test/menu_separators.lua

--- ==============================================================================
--- MODULE: Shared Menu Separator Check
--- DESCRIPTION:
--- Renders every menu the shared manifest declares and reports any separator
--- that does not sit between two real rows: two in a row, or one at either end.
---
--- WHY THE PROBES PUT SEPARATORS AT THE EDGES:
--- The manifest's own `---` entries are deferred by the renderer, so they never
--- double up by themselves. The lines that did double came from rows the driver
--- supplies — a list provider, a dynamic handler, a group — landing next to a
--- manifest `---`. Every probe here returns a separator, a row and a separator,
--- which is the worst case any driver row can produce.
---
--- USAGE (one call per driver suite, with that driver's platform):
---   local check = require("test.menu_separators")
---   local defects = check.render_every_menu(require("menu.renderer"), {
---       platform = "linux", manifest_path = "...", json_decode = json.decode,
---       logger = logger_stub })
--- ==============================================================================

local M = {}

local SEPARATOR = "-"





-- ====================================
-- ====================================
-- ======= 1/ Separator Walk ==========
-- ====================================
-- ====================================

--- Returns every misplaced separator in a rendered menu, submenus included.
--- @param items table Array of menu item tables; `{ title = "-" }` is a separator.
--- @param path string Name of this menu, used in each defect.
--- @param defects table|nil Accumulator.
--- @return table Array of human-readable defects, empty when the menu is clean.
function M.find_defects(items, path, defects)
	defects = defects or {}
	local previous_was_separator = true -- a leading separator counts as doubled
	for index, entry in ipairs(items) do
		local is_separator = type(entry) == "table" and entry.title == SEPARATOR
		if is_separator and previous_was_separator then
			defects[#defects + 1] = string.format("%s: separator at position %d follows %s",
				path, index, index == 1 and "nothing" or "another separator")
		end
		if type(entry) == "table" and type(entry.menu) == "table" then
			M.find_defects(entry.menu, path .. " > " .. tostring(entry.title), defects)
		end
		previous_was_separator = is_separator
	end
	if #items > 0 and previous_was_separator then
		defects[#defects + 1] = string.format("%s: ends with a separator", path)
	end
	return defects
end





-- =====================================
-- =====================================
-- ======= 2/ Worst-Case Probes ========
-- =====================================
-- =====================================

--- A table answering every id with the same probe.
--- @param probe any
--- @return table
local function answer_every_id(probe)
	return setmetatable({}, { __index = function() return probe end })
end

--- Provider rows with a separator on each side of one real row.
--- @return table
local function probe_rows()
	return { { separator = true }, { label = "Probe row" }, { separator = true } }
end

--- The dynamic-handler twin of probe_rows, appending finished menu items.
--- @param items table
local function probe_dynamic(items)
	items[#items + 1] = { title = SEPARATOR }
	items[#items + 1] = { title = "Probe row" }
	items[#items + 1] = { title = SEPARATOR }
end

--- Renders every menu array in the manifest with worst-case probes.
--- @param Renderer table The shared renderer module (menu.renderer).
--- @param opts table { platform, manifest_path, json_decode, logger, i18n?, on_rendered? }.
---   i18n         optional { get, section }; defaults to returning the key itself.
---   on_rendered  optional function(key, rendered) called with each built menu.
--- @return table defects, number menus_rendered
function M.render_every_menu(Renderer, opts)
	local R = Renderer.new({
		platform      = opts.platform,
		manifest_path = function() return opts.manifest_path end,
		json_decode   = opts.json_decode,
		i18n          = opts.i18n or {
			get     = function(key) return key end,
			section = function(key) return key end,
		},
		logger        = opts.logger,
	})
	local root = R.get_root()
	assert(type(root) == "table", "the shared menu manifest must load from " .. tostring(opts.manifest_path))

	local ctx = {
		commands      = answer_every_id(function() end),
		state_getters = answer_every_id(function() return false end),
	}
	local defects, menu_count = {}, 0
	local keys = {}
	for key, value in pairs(root) do
		-- Only arrays of typed entries are renderer menus; top_level is checked
		-- by top_level_defects below, and the other keys are lookup tables.
		if type(value) == "table" and type(value[1]) == "table" and value[1].type ~= nil then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local rendered = R.build(key, key,
			answer_every_id(probe_dynamic),
			answer_every_id(function() return { items = probe_rows() } end),
			ctx,
			answer_every_id(probe_rows))
		M.find_defects(rendered, opts.platform .. " " .. key, defects)
		if opts.on_rendered then opts.on_rendered(key, rendered) end
		menu_count = menu_count + 1
	end
	return defects, menu_count
end

--- Returns the misplaced separators of the tray's first level on one platform.
---
--- The drivers build that level themselves from `top_level`, where a separator
--- is an entry whose id is "---", so the declaration is what can double up: two
--- separators around a block of rows that all belong to other platforms.
--- @param root table Parsed menu manifest.
--- @param platform string "ahk", "hs" or "linux".
--- @return table Array of human-readable defects.
function M.top_level_defects(root, platform)
	local visible = {}
	for _, entry in ipairs(root.top_level or {}) do
		local shown = type(entry.platforms) ~= "table"
		for _, name in ipairs(type(entry.platforms) == "table" and entry.platforms or {}) do
			if name == platform then shown = true end
		end
		if shown then
			visible[#visible + 1] = { title = entry.id == "---" and SEPARATOR or tostring(entry.id) }
		end
	end
	return M.find_defects(visible, platform .. " top_level")
end

return M
