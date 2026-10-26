--- _shared/lua/menu/frames/personal_info_source.lua

--- ==============================================================================
--- MODULE: Menu Personal Information Editor Source
--- DESCRIPTION:
--- Retains the actual single personal-information editor declaration of the
--- shared menu manifest through provider projection, so a native builder can
--- offer the editor row only while that exact declaration is still the one it
--- admitted. Native callbacks refuse a withdrawn source before scheduling or
--- opening any UI.
---
--- FEATURES & RATIONALE:
--- 1. Raw reads only: `rawget`, `next` and `getmetatable` keep source
---    metamethods from running while the frame is admitted or rechecked.
--- 2. Facade custody: the renderer must be the module registered as
---    `infra.manifest_menu`, plain, and still expose the same three owners
---    when the returned `current` closure runs again.
--- 3. Pure Lua with no driver dependency: the renderer is injected, so the
---    macOS and Linux menus share one body and one contract. Each driver keeps
---    its own delegating port, which the menu source gates pin.
--- ==============================================================================

local M = {}

local COMMAND = require("config_keys").COMMAND




-- =============================
-- =============================
-- ======= 1/ Admission ========
-- =============================
-- =============================

--- Retains the actual single editor declaration through provider projection.
--- Native callbacks refuse a withdrawn source before scheduling or opening UI.
--- @param renderer table|nil The driver's actual manifest renderer.
--- @return function|nil current
--- @return function|nil template
local function read_source(renderer)
	local modules = rawget(package, "loaded")
	if type(modules) ~= "table" or rawget(modules, "infra.manifest_menu") ~= renderer
		or type(renderer) ~= "table" or getmetatable(renderer) ~= nil then return nil end
	local template, root_owner, array_owner = rawget(renderer, "template_rows"),
		rawget(renderer, "get_root"), rawget(renderer, "get_array")
	if type(template) ~= "function" or type(root_owner) ~= "function" or type(array_owner) ~= "function" then return nil end
	local function facade_current()
		return rawget(package, "loaded") == modules and rawget(modules, "infra.manifest_menu") == renderer
			and getmetatable(renderer) == nil and rawget(renderer, "template_rows") == template
			and rawget(renderer, "get_root") == root_owner and rawget(renderer, "get_array") == array_owner
	end
	local root, source = root_owner(), array_owner("personal_info_editor_frame")
	if not facade_current() or type(root) ~= "table" or getmetatable(root) ~= nil
		or type(source) ~= "table" or getmetatable(source) ~= nil
		or rawget(root, "personal_info_editor_frame") ~= source or rawget(source, 1) == nil then return nil end
	for index in next, source do if index ~= 1 then return nil end end
	local declaration = rawget(source, 1)
	if type(declaration) ~= "table" or getmetatable(declaration) ~= nil
		or rawget(declaration, "type") ~= "command" or rawget(declaration, "id") ~= COMMAND.PERSONAL_INFO_EDITOR_OPEN
		or type(rawget(declaration, "i18n")) ~= "string" or rawget(declaration, "i18n") == ""
		or rawget(declaration, "unavailable") ~= "hide" then return nil end
	local allowed = { type = true, id = true, i18n = true, platforms = true, unavailable = true }
	local fields, count = {}, 0
	for key, value in next, declaration do
		if not allowed[key] then return nil end
		fields[key], count = value, count + 1
	end
	if count ~= 5 then return nil end
	local platforms = rawget(declaration, "platforms")
	if type(platforms) ~= "table" or getmetatable(platforms) ~= nil
		or rawget(platforms, 1) ~= "hs" or rawget(platforms, 2) ~= "linux" then return nil end
	for index in next, platforms do if index ~= 1 and index ~= 2 then return nil end end
	local function current()
		if not facade_current() then return false end
		if root_owner() ~= root or array_owner("personal_info_editor_frame") ~= source or not facade_current()
			or getmetatable(root) ~= nil or rawget(root, "personal_info_editor_frame") ~= source
			or getmetatable(source) ~= nil or rawget(source, 1) ~= declaration
			or getmetatable(declaration) ~= nil or getmetatable(platforms) ~= nil then return false end
		for index in next, source do if index ~= 1 then return false end end
		local actual_count = 0
		for key, value in next, declaration do
			if fields[key] ~= value then return false end
			actual_count = actual_count + 1
		end
		if actual_count ~= count then return false end
		for index in next, platforms do if index ~= 1 and index ~= 2 then return false end end
		return rawget(platforms, 1) == "hs" and rawget(platforms, 2) == "linux"
	end
	if not current() then return nil end
	return current, template
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Retains the actual single editor declaration through provider projection.
--- @param renderer table|nil The driver's actual manifest renderer.
--- @return function|nil current Rechecks the retained declaration, true while unchanged.
--- @return function|nil template The renderer's own `template_rows`.
function M.read(renderer)
	return read_source(renderer)
end

return M
