--- ui/menu/branch_rows.lua

--- ==============================================================================
--- MODULE: Menu Branch Rows
--- DESCRIPTION:
--- Lets a menu refresh rebuild one top-level submenu alone. hs.menubar has no
--- per-row update, so every toggle re-pushes the whole tree; the Lua build of
--- the branches the click did not touch is the part that can be skipped.
---
--- FEATURES & RATIONALE:
--- 1. A decorator, not a second builder: wrap() returns the menu modules with
---    each admitted module's build() remembering the rows it returned. While a
---    branch is requested, the other admitted modules answer with those rows;
---    the builder still renders, gates and badges every row afresh.
--- 2. Only a module whose choices change its own rows alone may be requested
---    (BRANCH_LOCAL). The layout, AI, configuration, language and About choices
---    reach the whole tray: a click there rebuilds everything. The layout and
---    About rows still read only their own state, so a click elsewhere reuses
---    them (REUSED); the AI, configuration, language and debug rows are built
---    by the builder itself and always rebuilt.
--- 3. Fail towards the full build: no remembered rows yet, a pause state that
---    differs from the one they were built under, or no request, and every
---    module builds as before.
--- 4. A click names its branch by the title of its top-level row; a title two
---    modules share belongs to neither.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "menu.branch_rows"

--- Menu module keys whose rows read only that module's state.
M.BRANCH_LOCAL = { keystats = true, shortcuts = true, tap_holds = true, gestures = true, apps = true }

--- Menu module keys whose rows a branch-local refresh may reuse.
M.REUSED = {
	keystats = true, shortcuts = true, tap_holds = true, gestures = true, apps = true,
	keyboard_layout = true, about = true,
}

--- Creates the decorator for one menubar.
--- @return table branch_rows { wrap, request, settle, branch_of }
function M.new()
	local self = {}
	-- Rows each admitted module last built, and the pause state they carry.
	local remembered = {}
	-- Top-level title -> module key, false when two modules share it.
	local titles = {}
	-- The module asked to rebuild alone, nil for a full build.
	local requested = nil

	--- Remembers the titles of the rows a module built.
	local function note_titles(key, result)
		local rows = type(result) == "table" and result[1] ~= nil and result or { result }
		for _, row in ipairs(rows) do
			local title = type(row) == "table" and row.label or nil
			if type(title) == "string" then
				local owner = titles[title]
				titles[title] = (owner == nil or owner == key) and key or false
			end
		end
	end

	--- Wraps one module's build.
	local function wrap_build(key, build)
		return function(arg, ...)
			local paused = type(arg) == "table" and arg.paused == true
			local kept = remembered[key]
			if requested ~= nil and requested ~= key and kept ~= nil and kept.paused == paused then
				return kept.result
			end
			local result = build(arg, ...)
			remembered[key] = { result = result, paused = paused }
			note_titles(key, result)
			return result
		end
	end

	--- Returns the menu modules with every admitted module's build decorated.
	--- @param mods table Menu modules by key, as ui/menu/builder.lua reads them.
	--- @return table proxy Same keys; admitted modules read through to the original.
	function self.wrap(mods)
		assert(type(mods) == "table", "branch_rows.wrap needs the menu modules")
		local proxy = {}
		for key, mod in pairs(mods) do
			if M.REUSED[key] and type(mod) == "table" and type(mod.build) == "function" then
				proxy[key] = setmetatable({ build = wrap_build(key, mod.build) }, { __index = mod })
			else
				proxy[key] = mod
			end
		end
		return proxy
	end

	--- Asks the next build to rebuild one module's rows alone.
	--- @param key string Module key branch_of returned.
	function self.request(key)
		assert(M.BRANCH_LOCAL[key] == true, "not a branch-local menu module: " .. tostring(key))
		requested = key
		Logger.debug(LOG, "The next menu build rebuilds the '%s' branch alone.", key)
	end

	--- Ends the request once its build has run, whatever its outcome.
	function self.settle() requested = nil end

	--- Returns the requestable module a top-level row title belongs to.
	--- @param title string|nil Title of a clicked row's top-level ancestor.
	--- @return string|nil key Module key, nil when the whole tray must be rebuilt.
	function self.branch_of(title)
		local key = type(title) == "string" and titles[title] or nil
		return (type(key) == "string" and M.BRANCH_LOCAL[key] == true) and key or nil
	end

	return self
end

return M
