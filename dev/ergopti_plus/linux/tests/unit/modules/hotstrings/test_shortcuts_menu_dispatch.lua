--- tests/unit/modules/hotstrings/test_shortcuts_menu_dispatch.lua

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
--- WHAT THE MANIFEST OWES BACK:
--- `keyboard_slots` is declared for every platform that can bind a chord, and
--- Linux cannot: its shortcuts module is toggles, selection transforms and wrap
--- pairs, with no capture and no assignment store. The renderer logs a warning
--- for a list with no provider — so once this menu dispatched, that row became a
--- warning on every menu build. It is restricted now, which is the manifest
--- recording a gap that already existed rather than one this change created.
---
--- WHAT IS NOT ASSERTED HERE:
--- That an extension's own rows do what they say. They come from the extension's
--- sandboxed shortcuts/menu.lua and are its author's to get right; what this
--- driver owes is that they appear at all.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A shortcuts module with the surface the menu reads.
--- @param log table|nil Records what the rows called.
--- @return table
local function fake_shortcuts(log)
	log = log or {}
	local enabled, caps = true, false
	return {
		is_enabled          = function() return enabled end,
		toggle              = function() enabled = not enabled ; log.toggled = true end,
		is_caps_word_active = function() return caps end,
		toggle_caps_word    = function() caps = not caps ; log.caps = true end,
		transform_uppercase = function() log.upper = true end,
		transform_lowercase = function() log.lower = true end,
		transform_titlecase = function() log.title = true end,
		select_word         = function() log.word = true end,
		select_line         = function() log.line = true end,
		paste_plain         = function() log.paste = true end,
		wrap_selection      = function(l, r) log.wrapped = l .. r end,
		get_wrap_pairs      = function()
			return {
				["("] = { left = "(", right = ")" },
				[")"] = { left = "(", right = ")" },
				["«"] = { left = "«", right = "»" },
				["»"] = { left = "«", right = "»" },
			}
		end,
	}
end

--- The shortcuts submenu, as the tray builder returns it.
--- @param ctx_extra table|nil
--- @return table|nil rows
local function shortcuts_menu(ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { _version = "9.9.9", shortcuts = fake_shortcuts() }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	local wanted = require("infra.i18n").get("menu.shortcuts.select_word")
	for _, item in ipairs(mb.build(ctx)) do
		if type(item.menu) == "table" then
			for _, row in ipairs(item.menu) do
				if row.title == wanted then return item.menu end
			end
		end
	end
	return nil
end




-- =================================================================
-- =================================================================
-- ======= 1/ The rows this driver owns ============================
-- =================================================================
-- =================================================================

helpers.describe("shortcuts menu: this driver's own rows", function()

	helpers.it("draws the master toggle the renderer refuses to", function()
		local rows = shortcuts_menu()
		helpers.assert_not_nil(rows, "the shortcuts submenu must exist")
		helpers.assert_true(type(rows[1].fn) == "function",
			"row 1 of the manifest is a `toggle`, which the shared renderer skips by "
				.. "contract — so this caller has to build it, and a submenu whose "
				.. "first row is missing has no way to switch shortcuts off at all")
	end)

	helpers.it("labels every row from the catalogue, not from a French literal", function()
		for _, row in ipairs(shortcuts_menu() or {}) do
			if type(row.title) == "string" and row.title ~= "-" then
				helpers.assert_true(not row.title:find("texte", 1, true),
					"a translated label followed by an untranslated one is worse than "
						.. "either: it tells a Japanese user the row was localised and "
						.. "then hands them French")
			end
		end
	end)

	helpers.it("orders the wrapping pairs, so a rebuild does not shuffle them", function()
		local rows = shortcuts_menu()
		-- By its label, not by "the last submenu with more than one row". That
		-- shortcut passed here and failed in CI, where the bundled demo extension's
		-- shortcuts/menu.lua resolves and adds a second submenu after this one —
		-- so the test was asserting the ordering of an extension's rows, which are
		-- its author's to order.
		local wanted = require("infra.i18n").get("menu.shortcuts.wrap_symbols")
		local wrap = nil
		for _, row in ipairs(rows) do
			if row.title == wanted and type(row.menu) == "table" then wrap = row.menu end
		end
		helpers.assert_not_nil(wrap, "the wrapping-symbols submenu is present")

		local seen = {}
		for _, row in ipairs(wrap) do seen[#seen + 1] = row.title end
		local sorted = {}
		for index, title in ipairs(seen) do sorted[index] = title end
		table.sort(sorted)
		for index, title in ipairs(seen) do
			helpers.assert_eq(title, sorted[index],
				"get_wrap_pairs returns a map, and `pairs` would give the user a "
					.. "different order on every menu rebuild")
		end
		helpers.assert_eq(#wrap, 2,
			"one row per PAIR, not per character — each pair is stored under both "
				.. "of its ends and listing both would double the submenu")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The rows the manifest owns ===========================
-- =================================================================
-- =================================================================

helpers.describe("shortcuts menu: dispatched by id", function()

	helpers.it("renders an extension's rows through the manifest handler", function()
		-- The handler is reached only if the menu dispatches by id at all, which is
		-- the whole point: before this, the manifest could not promise Linux this
		-- row, and the restriction said no Lua driver had the concept while both
		-- did.
		local mb = helpers.load_module("ui.menu.menu_builder")
		helpers.assert_true(mb ~= nil)

		local source = nil
		for _, path in ipairs({ "ui/menu/menu_builder.lua" }) do
			local fh = io.open("./" .. path, "r")
			if fh then source = fh:read("*a") ; fh:close() end
		end
		helpers.assert_not_nil(source, "the builder's source must be readable")
		helpers.assert_contains(source, 'ManifestMenu.build("shortcuts_menu"',
			"the submenu must go through the shared renderer — a hand-rolled one "
				.. "cannot be handed a row by id, and that is exactly what kept "
				.. "extensions_shortcuts restricted to Windows in the manifest")
		helpers.assert_contains(source, '["extensions_shortcuts"]',
			"and it must register the handler the manifest names, or the renderer "
				.. "logs a warning and renders one row short, permanently")
	end)

	helpers.it("keeps the rest of the tray when the shortcuts module is absent", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local tree = mb.build({ _version = "9.9.9" })

		-- Not "it did not throw": that would pass just as well if build returned an
		-- empty list. What the user must still get is every OTHER submenu, and a
		-- shortcuts entry that says it is unavailable rather than vanishing.
		-- Compared against the resolved key, not against a substring of the French
		-- label: the label became a catalogue entry on 2026-08-05 and a test that
		-- pinned its spelling would have reported that improvement as a defect.
		local unavailable = require("infra.i18n").get("menu.shortcuts.unavailable")
		local top_level, placeholder = 0, false
		for _, item in ipairs(tree) do
			if type(item.menu) == "table" then
				top_level = top_level + 1
				for _, row in ipairs(item.menu) do
					if row.title == unavailable then placeholder = row.disabled == true end
				end
			end
		end
		helpers.assert_true(top_level >= 5,
			"a missing shortcuts module costs the user that submenu, never their menu")
		helpers.assert_true(placeholder,
			"and the entry stays, greyed: a row that disappears reads as a bug, and "
				.. "the user has no way to tell it apart from a feature they never had")
	end)

end)
