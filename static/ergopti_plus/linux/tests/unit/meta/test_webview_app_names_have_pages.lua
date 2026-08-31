--- tests/unit/meta/test_webview_app_names_have_pages.lua

--- ==============================================================================
--- MODULE: Every Window This Driver Opens Has a Page to Show
--- DESCRIPTION:
--- Asserts that each app name the driver passes to `webview.show()` resolves to a
--- real `_shared/ui/<name>/index.html`, and that every bridge registered in
--- `webview_manager` is registered under such a name.
---
--- THE BUG THIS ENCODES:
--- `webview_manager.BRIDGE_MODULES` mapped "hotstrings_config" to the
--- `ui.hotstrings_config_window.bridge` module, and two call sites opened the
--- settings window by that name. The bridge resolved fine. The PAGE did not:
--- `webkit_host.resolve_app_dir()` builds `_shared/ui/<app_name>/index.html` and
--- there has never been a `_shared/ui/hotstrings_config`. So the window opened
--- and rendered "Error: app 'hotstrings_config' not found", and the hotstrings
--- delays-and-colours settings window — the one the whole "Délais et couleurs"
--- row exists to reach, and the only way to add a custom word delimiter on this
--- driver — had never once opened.
---
--- WHY NOTHING CAUGHT IT:
--- The bridge half was correct and is what every existing gate looked at. The
--- name appeared in a lookup table whose comment explicitly said four of its
--- names "do not equal their directory", which read as a deliberate aliasing
--- feature; it is instead the precise condition under which the page cannot be
--- found. Two halves that are each individually defensible, and a window that
--- shows an error page.
---
--- The check is on the NAME, not on the window: opening a real GTK window needs a
--- display, and the failure is entirely decided before any of that.
--- ==============================================================================

local helpers = require("tests.helpers")

local driver_root = helpers.driver_root()
local shared_root = driver_root .. "/../_shared"

-- =============================================================
-- =============================================================
-- ======= 1/ Reading the driver's own source ==================
-- =============================================================
-- =============================================================

--- Reads a file relative to the driver root.
--- @param relative string
--- @return string
local function read_driver_file(relative)
	local fh = io.open(driver_root .. "/" .. relative, "r")
	helpers.assert_true(fh ~= nil, "cannot open " .. tostring(relative))
	local content = fh:read("*a")
	fh:close()
	return content or ""
end

--- Whether a shared UI page exists for an app name.
--- @param app_name string
--- @return boolean
local function page_exists(app_name)
	local fh = io.open(shared_root .. "/ui/" .. app_name .. "/index.html", "r")
	if not fh then return false end
	fh:close()
	return true
end




-- =============================================================
-- =============================================================
-- ======= 2/ Every show() target has a page ===================
-- =============================================================
-- =============================================================

print("=== webview app names resolve to real pages ===")

-- The two files that open windows. Listed rather than walked so that a new
-- caller in a third file is a deliberate addition here, and so the test cannot
-- quietly stop covering a file that gets renamed.
local CALLER_FILES = {
	"ergopti_hotstrings.lua",
	"ui/menu/menu_builder.lua",
}

local seen = {}
local call_count = 0
for _, relative in ipairs(CALLER_FILES) do
	local source = read_driver_file(relative)
	-- Matches `show("name")` on either receiver spelling the driver uses
	-- (ctx.webview.show / webview_manager.show); both end in `.show("`.
	for app_name in source:gmatch('%.show%("([%a_][%w_]*)"%)') do
		call_count = call_count + 1
		if not seen[app_name] then
			seen[app_name] = true
			helpers.assert_true(
				page_exists(app_name),
				string.format(
					"%s opens the window '%s', but _shared/ui/%s/index.html does not exist — "
						.. "that window renders \"Error: app '%s' not found\"",
					relative, app_name, app_name, app_name))
			print(string.format("  ok   '%s' has _shared/ui/%s/index.html", app_name, app_name))
		end
	end
end

helpers.assert_true(call_count > 0,
	"no show() call sites were found at all — the pattern stopped matching and this test now proves nothing")




-- =============================================================
-- =============================================================
-- ======= 3/ Every registered bridge names a page =============
-- =============================================================
-- =============================================================

print("=== registered bridges are keyed by a page name ===")

-- Parsed out of the source rather than required: webview_manager pulls in GTK
-- and the whole daemon state at load time, and this assertion is about a literal
-- table in a file.
local manager_source = read_driver_file("ui/webview_manager.lua")
local block = manager_source:match("local BRIDGE_MODULES = {(.-)\n}")
helpers.assert_true(block ~= nil,
	"could not find the BRIDGE_MODULES table in ui/webview_manager.lua — this test cannot check what it cannot read")

local bridge_count = 0
for key in block:gmatch("([%a_][%w_]*)%s*=%s*\"ui%.") do
	bridge_count = bridge_count + 1
	helpers.assert_true(
		page_exists(key),
		string.format(
			"BRIDGE_MODULES registers '%s', but _shared/ui/%s/index.html does not exist. "
				.. "A name with a bridge and no page looks supported everywhere anyone checks, "
				.. "and opens a window showing an error.",
			key, key))
end

helpers.assert_true(bridge_count >= 10,
	string.format("only %d bridge(s) parsed out of BRIDGE_MODULES — the pattern has stopped matching", bridge_count))
print(string.format("  ok   %d registered bridge(s), each keyed by a real page", bridge_count))
