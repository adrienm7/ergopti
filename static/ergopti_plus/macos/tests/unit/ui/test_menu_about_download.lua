--- tests/unit/ui/test_menu_about_download.lua

--- ==============================================================================
--- MODULE: Regression — menu_about download_to_file fixes (F10 + F58)
--- DESCRIPTION:
--- Guards against two bugs in download_to_file and the install path:
---
--- F10: hs.fs.pathComponent(dest, "parentDirectory") does not exist in
---      Hammerspoon's hs.fs. Calling it throws inside the asyncGet callback
---      (swallowed to the HS Console), so cb never fires and the update state
---      machine stays stuck at "installing" forever.
---
--- F58: os.tmpname() creates an orphaned /tmp/lua_XXXXXX file as a side effect.
---      The code only used the path suffix (:gsub) but the empty file was never
---      cleaned up. All three call sites suffered from this.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================================================
-- ==========================================================================
-- ======= 1/ No hs.fs.pathComponent in download_to_file ===================
-- ==========================================================================
-- ==========================================================================

helpers.describe("menu_about: download_to_file fixes", function()
	helpers.it("download_to_file does not call hs.fs.pathComponent", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/ui/menu/menu_about.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open menu_about.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The function does not exist in HS; only a comment may reference it.
		-- Scan line by line: a non-comment line must not call pathComponent.
		local has_call = false
		for line in src:gmatch("[^\n]+") do
			local stripped = line:match("^%s*(.-)%s*$") or line
			if not stripped:match("^%-%-") and stripped:find("hs.fs.pathComponent(", 1, true) then
				has_call = true
				break
			end
		end
		helpers.assert_true(
			not has_call,
			"menu_about.lua must not call hs.fs.pathComponent() (it does not exist in Hammerspoon)"
		)
	end)

	helpers.it("zip temp paths use hs.fs.temporaryDirectory, not os.tmpname", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/ui/menu/menu_about.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open menu_about.lua")
		local src = fh:read("*a")
		fh:close()

		-- os.tmpname() must not appear as a CALL (parentheses) — comments explaining
		-- the removed bug are allowed
		local call_count = 0
		local pos = 1
		while true do
			local s = src:find("= os.tmpname()", pos, true)
			if not s then break end
			call_count = call_count + 1
			pos = s + 1
		end
		helpers.assert_true(
			call_count == 0,
			"menu_about.lua must not assign from os.tmpname() (creates orphan /tmp files): " ..
			call_count .. " call(s) found"
		)

		-- hs.fs.temporaryDirectory must be used instead
		helpers.assert_true(
			src:find("hs.fs.temporaryDirectory", 1, true) ~= nil,
			"menu_about.lua must use hs.fs.temporaryDirectory() for temp file paths"
		)
	end)
end)
