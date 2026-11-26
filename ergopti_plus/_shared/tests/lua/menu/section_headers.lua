--- _shared/tests/lua/menu/section_headers.lua

--- ==============================================================================
--- MODULE: Shared Menu Section Header Check
--- DESCRIPTION:
--- Renders every menu the shared manifest declares for one platform and reports
--- any section header that titles nothing: one followed by a separator, by
--- another header, or by the end of its menu. A header is recognised as the
--- renderer draws it: a disabled row framed by the one shared format
--- (menu.section_header_data), so a header framed any other way is not one.
---
--- WHY THE PROBES BRING NO SEPARATOR:
--- A driver row under a header is the content the header titles, so each probe
--- is one plain row. Menus that are only fragments of another (the targets of an
--- `include`, the templates a driver splices into its rows) are never checked as
--- a root, because their content sits around them.
---
--- USAGE (one call per Lua driver suite, with that driver's platform):
---   local headers = require("tests.lua.menu.section_headers")
---   local defects, rendered = headers.render_every_menu(require("menu.engine.renderer"), {
---       platform = "linux", manifest_path = "...", json_decode = json.decode,
---       logger = logger_stub })
--- ==============================================================================

local Format = require("menu.engine.section_header_data")
local Labels = require("menu.engine.labels")
local Separators = require("tests.lua.menu.separators")

local M = {}

local SEPARATOR = "-"





-- ====================================
-- ====================================
-- ======= 1/ Header Walk =============
-- ====================================
-- ====================================

--- Whether a built row is a section header drawn by the shared format.
--- @param entry any
--- @return boolean
function M.is_header(entry)
	if type(entry) ~= "table" or entry.disabled ~= true or type(entry.title) ~= "string" then return false end
	local title = entry.title
	return #title > #Format.prefix + #Format.suffix
		and title:sub(1, #Format.prefix) == Format.prefix
		and title:sub(-#Format.suffix) == Format.suffix
end

--- Returns every header of a built menu that titles nothing, submenus included.
--- @param items table Array of built menu items; `{ title = "-" }` is a separator.
--- @param path string Name of this menu, used in each defect.
--- @param defects table|nil Accumulator.
--- @return table Array of human-readable defects, empty when the menu is clean.
function M.find_defects(items, path, defects)
	defects = defects or {}
	for index, entry in ipairs(items) do
		if M.is_header(entry) then
			local after = items[index + 1]
			local cause = (after == nil and "the end of the menu")
				or (type(after) == "table" and after.title == SEPARATOR and "a separator")
				or (M.is_header(after) and "another header")
			if cause then
				defects[#defects + 1] = string.format("%s: header %q at position %d is followed by %s",
					path, entry.title, index, cause)
			end
		end
		if type(entry) == "table" and type(entry.menu) == "table" then
			M.find_defects(entry.menu, path .. " > " .. tostring(entry.title), defects)
		end
	end
	return defects
end





-- ========================================
-- ========================================
-- ======= 2/ Every Manifest Menu =========
-- ========================================
-- ========================================

--- Whether a manifest row is drawn on a platform, greyed stand-ins included.
--- @param entry table
--- @param platform string
--- @return boolean
local function drawn_on(entry, platform)
	if type(entry.platforms) ~= "table" or entry.unavailable == "grey" then return true end
	for _, name in ipairs(entry.platforms) do
		if name == platform then return true end
	end
	return false
end

--- The menus that are only fragments of another: the targets of an `include`
--- row, and the templates a driver splices into its own rows, which declare an
--- inert `label` (drawn by template_rows only) or end with their header.
--- tools/test/test-section-decoration-parity.cjs checks their declarations.
--- @param root table Decoded manifest.
--- @param platform string
--- @return table set Menu key -> true.
local function fragments(root, platform)
	local set = {}
	for key, value in pairs(root) do
		if type(value) == "table" then
			local last
			for _, entry in ipairs(value) do
				if type(entry) == "table" then
					if entry.type == "include" and type(entry.section) == "string" then set[entry.section] = true end
					if entry.type == "label" then set[key] = true end
					if drawn_on(entry, platform) then last = entry end
				end
			end
			if last and last.type == "section_header" then set[key] = true end
		end
	end
	return set
end

--- Renders every root menu of the manifest and returns its header defects.
--- @param Renderer table The shared renderer module (menu.renderer).
--- @param opts table { platform, manifest_path, json_decode, logger }.
--- @return table defects, number menus_rendered, number headers_seen
function M.render_every_menu(Renderer, opts)
	local fh = assert(io.open(opts.manifest_path, "r"))
	local root = opts.json_decode(fh:read("*a"))
	fh:close()
	local defects, headers = {}, 0
	local function count(items)
		for _, entry in ipairs(items) do
			if M.is_header(entry) then headers = headers + 1 end
			if type(entry) == "table" and type(entry.menu) == "table" then count(entry.menu) end
		end
	end
	local _, rendered = Separators.render_every_menu(Renderer, {
		platform      = opts.platform,
		manifest_path = opts.manifest_path,
		json_decode   = opts.json_decode,
		logger        = opts.logger,
		i18n          = {
			get     = function(key) return key end,
			section = function(key) return Labels.decorate_section(key) end,
		},
		provider_rows = function() return { { label = "Probe row" } } end,
		dynamic       = function(items) items[#items + 1] = { title = "Probe row" } end,
		skip          = fragments(root, opts.platform),
		on_rendered   = function(key, built)
			M.find_defects(built, opts.platform .. " " .. key, defects)
			count(built)
		end,
	})
	return defects, rendered, headers
end

return M
