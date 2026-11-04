--- tests/unit/modules/hotstrings/menu/test_shortcuts_menu_dispatch_shortcut_extension_genuine.lua

--- ==============================================================================
--- MODULE: The Shortcuts Submenu Answers by Id
--- DESCRIPTION:
--- That the Linux shortcuts submenu is built from the manifest rather than by
--- hand, and that the rows it owns come out where and how the other two drivers
--- put them.
---
--- WHY BEING HAND-ROLLED WAS A REAL COST, NOT AN AESTHETIC ONE:
--- `extensions_shortcuts` sat at platforms = ["ahk"] with the reason "neither Lua
--- driver has that concept". That was false for both — macOS has walked the
--- extensions tree since its shortcuts menu was written, and Linux since
--- 2026-08-05. The restriction survived a correction attempt anyway, because a
--- menu that dispatches nothing BY ID cannot be promised a row by id: the
--- handler-bijection ratchet would have flagged it the moment the manifest
--- widened. So the manifest went on describing the product wrongly, and the only
--- way out was to make this menu answer by id. That is what is pinned here.
---
--- PARAMETERIZED ACTIONS:
--- Keyboard slots dispatch through the gestures action catalogue. An action such
--- as open_url is incomplete without its binding-scoped parameter, so the menu
--- must persist that parameter before publishing the visible key assignment.
---
--- WHAT IS NOT ASSERTED HERE:
--- That an extension's own rows do what they say. They come from the extension's
--- sandboxed shortcuts/menu.lua and are its author's to get right; what this
--- driver owes is that they appear at all.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.menu.shortcuts_menu_dispatch_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.menu.shortcuts_menu_dispatch_fixture")
local helpers, shortcuts_menu, find_row, with_shortcut_locale =
	Fixture.helpers, Fixture.shortcuts_menu, Fixture.find_row, Fixture.with_shortcut_locale




helpers.describe("Shortcut extension genuine physical failure marker", function()
	for _, code in ipairs({ "en", "fr" }) do
		local language = code
		helpers.it("uses and withdraws the whole declared " .. language .. " marker after the real extension chunk fails", function()
			with_shortcut_locale(language, function()
				local lfs, Paths = require("lfs"), require("infra.paths")
				local directory = os.tmpname(); assert(os.remove(directory)); assert(lfs.mkdir(directory))
				local pack = directory .. "/g1-marker"
				assert(lfs.mkdir(pack)); assert(lfs.mkdir(pack .. "/shortcuts")); assert(lfs.mkdir(pack .. "/hotstrings"))
				local function write(path, bytes)
					local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
				end
				write(pack .. "/manifest.toml", '[extension]\nname = "Native %s $1 50%"\n')
				write(pack .. "/shortcuts/menu.lua", 'error("Actual compiled physical extension failure", 0)\n')
				local original_roots = Paths.extension_roots
				local root = require("infra.manifest_menu").get_root()
				local original_frame = root.shortcut_extension_error_frame
				local expected = language == "fr" and "Native %s $1 50% — Erreur" or "Native %s $1 50% — Error"
				local ok, detail = xpcall(function()
					Paths.extension_roots = function() return { directory } end
					local current = assert(find_row(shortcuts_menu(), expected))
					helpers.assert_eq(current.disabled, true)
					helpers.assert_nil(current.fn, "a real failed extension marker is inert")
					helpers.assert_nil(current.menu)
					root.shortcut_extension_error_frame = nil
					helpers.assert_nil(find_row(shortcuts_menu(), expected), "no raw-label fallback bypasses missing declaration")
					root.shortcut_extension_error_frame = { { type = "command", id = "foreign_marker", i18n = "common.error_title" } }
					helpers.assert_nil(find_row(shortcuts_menu(), expected), "a malformed whole frame cannot borrow an unrelated callback")
					root.shortcut_extension_error_frame = original_frame
					helpers.assert_eq(assert(find_row(shortcuts_menu(), expected)).disabled, true)
					local file = assert(io.open(pack .. "/shortcuts/menu.lua", "rb"))
					helpers.assert_eq(assert(file:read("*a")), 'error("Actual compiled physical extension failure", 0)\n')
					assert(file:close())
				end, debug.traceback)
				Paths.extension_roots = original_roots
				root.shortcut_extension_error_frame = original_frame
				assert(os.remove(pack .. "/manifest.toml")); assert(os.remove(pack .. "/shortcuts/menu.lua"))
				assert(lfs.rmdir(pack .. "/shortcuts")); assert(lfs.rmdir(pack .. "/hotstrings")); assert(lfs.rmdir(pack)); assert(lfs.rmdir(directory))
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)

