--- tests/meta/test_init_fsdir_pcall.lua

--- ==============================================================================
--- MODULE: init.lua hs.fs.dir pcall Guard
--- DESCRIPTION:
--- Static source guard for the "init-fsdir-pcall" audit finding in
--- static/ergopti_plus/macos/init.lua.
---
--- ROOT CAUSE ENCODED:
--- has_common_hotstring_groups() wrapped the hs.fs.attributes() check in pcall,
--- but called hs.fs.dir() directly without protection. If the directory was
--- inaccessible (permissions denied, deleted between the attribute check and the
--- iteration, or a race on first launch), hs.fs.dir() would throw a native Lua
--- error that propagated uncaught through the top-level init sequence, silently
--- aborting Hammerspoon initialisation.
---
--- The fix wraps the call: `local ok_iter, dir_iter = pcall(hs.fs.dir, dir)` and
--- returns false on failure, so a broken hotstrings directory is logged as ERROR
--- but never crashes the driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. "/" .. rel, "r")
	if not fh then
		-- init.lua lives one level above the driver root (macos/ parent)
		fh = io.open(DRIVER_ROOT .. "/../" .. rel, "r")
	end
	assert(fh, "cannot open " .. rel .. " from driver root " .. tostring(DRIVER_ROOT))
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ==============================================================
-- ==============================================================
-- ======= 1/ hs.fs.dir wrapped in pcall (source guard) =========
-- ==============================================================
-- ==============================================================

helpers.describe("init.lua: hs.fs.dir() is wrapped in pcall (init-fsdir-pcall)", function()

	helpers.it("hs.fs.dir is called via pcall, not bare", function()
		local src = read_source("init.lua")
		helpers.assert_true(
			src:match("pcall%(hs%.fs%.dir") ~= nil,
			"init.lua must call hs.fs.dir() via pcall to survive an inaccessible directory (init-fsdir-pcall)")
	end)

	helpers.it("bare hs.fs.dir() call is absent from has_common_hotstring_groups", function()
		local src = read_source("init.lua")
		-- Acceptable forms: pcall(hs.fs.dir, ...) — the old bare `for fname in hs.fs.dir(dir)`
		-- must not appear.
		helpers.assert_true(
			src:match("for%s+%w+%s+in%s+hs%.fs%.dir%(") == nil,
			"init.lua must NOT call hs.fs.dir() bare (unprotected) — use pcall (init-fsdir-pcall)")
	end)

end)
