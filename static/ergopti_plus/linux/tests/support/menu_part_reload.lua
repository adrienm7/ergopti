--- tests/support/menu_part_reload.lua

--- ==============================================================================
--- MODULE: Tray Section Module Reload
--- DESCRIPTION:
--- Reloads the tray root's section modules whenever the root itself reloads.
---
--- ui/menu/builder.lua binds each section builder from its own module
--- (ui/menu/menu_<section>.lua) when it loads, and each module captures its
--- dependencies at its own load. Tests swap a dependency, reload the root and
--- expect it to render with the swap; a section module still cached from an
--- earlier load would keep the previous dependency instead — a stub another
--- test module installed, for instance. The root must not write package.loaded
--- itself, so the test process does it: a searcher placed after the preload
--- searcher forgets every cached section module just before the root's file
--- runs, whatever way a test reloads it.
---
--- The sections are read from the root itself: each is bound there as
--- `require("<module>").build` (the contract tools/lib/linux-menu-parts.cjs
--- enforces), so the set follows every section wherever its feature folder
--- puts it, instead of a module-name prefix the feature-first tree no longer
--- shares. The native dialogs the sections import are listed by name.
--- ==============================================================================

local M = {}

local ROOT = "ui.menu.builder"
-- Modules every section imports that the root does not bind as a section.
local SHARED_PARTS = { "ui.menu.menu_dialogs" }

local _installed = false

--- Reads the modules the root binds as sections, from the root's own source.
--- @return table names The section module names, at least one.
local function section_names()
	local path = assert(package.searchpath(ROOT, package.path), "the tray root " .. ROOT .. " is not on package.path")
	local handle = assert(io.open(path, "rb"))
	local source = handle:read("*a")
	handle:close()
	local names, seen = {}, {}
	for name in source:gmatch('require%("([%w_%.]+)"%)%.build') do
		if not seen[name] then seen[name], names[#names + 1] = true, name end
	end
	assert(#names > 0, "the tray root " .. path .. " binds no section module")
	return names
end

--- Forgets every cached tray section module, never the root itself. A test
--- that runs the root's file with loadfile, bypassing require, calls it first.
function M.forget_parts()
	for _, name in ipairs(section_names()) do
		if name ~= ROOT then package.loaded[name] = nil end
	end
	for _, name in ipairs(SHARED_PARTS) do
		assert(package.searchpath(name, package.path), "the shared tray part " .. name .. " is not on package.path")
		package.loaded[name] = nil
	end
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
