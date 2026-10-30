--- tests/support/menu_part_reload.lua

--- ==============================================================================
--- MODULE: Tray Section Module Reload
--- DESCRIPTION:
--- Reloads the tray root's section modules whenever the root itself reloads.
---
--- ui/menu/menu_builder.lua binds each section builder from its own module
--- (ui/menu/menu_<section>.lua) when it loads, and each module captures its
--- dependencies at its own load. Tests swap a dependency, reload the root and
--- expect it to render with the swap; a section module still cached from an
--- earlier load would keep the previous dependency instead — a stub another
--- test module installed, for instance. The root must not write package.loaded
--- itself, so the test process does it: a searcher placed after the preload
--- searcher forgets every cached section module just before the root's file
--- runs, whatever way a test reloads it.
--- ==============================================================================

local M = {}

local ROOT = "ui.menu.menu_builder"
local PART = "^ui%.menu%.menu_"

local _installed = false

--- Forgets every cached tray section module, never the root itself. A test
--- that runs the root's file with loadfile, bypassing require, calls it first.
function M.forget_parts()
	local cached = {}
	for name in pairs(package.loaded) do
		if type(name) == "string" and name ~= ROOT and name:match(PART) then cached[#cached + 1] = name end
	end
	for _, name in ipairs(cached) do package.loaded[name] = nil end
end

--- Installs the searcher once, before any test module loads.
function M.install()
	assert(not _installed, "the tray section module reload is already installed")
	-- LuaJIT keeps Lua 5.1's package.loaders; Lua 5.2+ renamed it searchers.
	local searchers = assert(package.searchers or package.loaders, "require has no searcher list")
	local file_searcher = assert(searchers[2], "require has no Lua file searcher")
	table.insert(searchers, 2, function(name)
		if name ~= ROOT then return nil end
		local loader, extra = file_searcher(name)
		if type(loader) ~= "function" then return loader end
		return function(...)
			M.forget_parts()
			return loader(...)
		end, extra
	end)
	_installed = true
end

return M
