--- tests/unit/ui/menu/test_icon_refresh_not_doubled.lua

--- ==============================================================================
--- MODULE: Regression — no site refreshes the menubar icon twice in a row
--- DESCRIPTION:
--- `update_icon` is not a cheap setter: it probes for a disabled-logo PNG with
--- io.open, decodes an image off disk, and re-renders it through an off-screen
--- hs.canvas round-trip to the window server. The pause listener ran it and then
--- called `updateMenu()` on the next line — and `updateMenu`'s own first statement
--- is `pcall(update_icon)`. So every pause toggle paid for it twice, from inside
--- the script-control eventtap callback: the same tap that carries the key needed
--- to un-pause.
---
--- ROOT CAUSE ENCODED:
--- A caller that does the work its callee already does. The memo added earlier
--- makes the second call cheap, so this is now about the redundancy itself rather
--- than the cost — but the redundancy is what hid the cost, and a future change to
--- the memo key would bring the double render straight back.
---
--- Removing the bare call also makes the refresh strictly SAFER: updateMenu wraps
--- it in pcall and the bare call did not, so a throw inside the icon render used to
--- propagate out of the pause listener.
---
--- WHAT THIS IS NOT: the theme watcher's copy of the same pair looked like a case
--- where the memo would wrongly suppress a needed re-render. It is not. The icon is
--- chosen from `paused` alone, and it is pushed with `setIcon(icon, false)` — the
--- non-template form, so macOS never re-tints it for light or dark either. A theme
--- change has never altered this icon; what the theme watcher actually needs is the
--- menu rebuild that follows.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by the memo key, which lives immediately above update_icon.
local ANCHOR = "_last_icon_key"




-- ==================================================================
-- ==================================================================
-- ======= 1/ No adjacent update_icon + updateMenu pair =============
-- ==================================================================
-- ==================================================================

helpers.describe("menubar icon: no caller refreshes it twice", function()

	helpers.it("no site calls update_icon immediately before updateMenu", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the menu module must be locatable by '" .. ANCHOR .. "'; an empty corpus would "
			.. "make every assertion below vacuous")

		-- Comments stripped so this file's own prose — and the module's, which names
		-- the pair while explaining it — is not read as a call site.
		local code = src:gsub("%-%-[^\n]*", "")

		local offenders = {}
		local prev, line_no = nil, 0
		for line in (code .. "\n"):gmatch("([^\n]*)\n") do
			line_no = line_no + 1
			local trimmed = line:gsub("^%s+", "")
			if prev and trimmed:match("^updateMenu%(%)")
				and prev:match("^update_icon%(%)") then
				table.insert(offenders, (line_no - 1) .. ": update_icon() then updateMenu()")
			end
			-- Also the guarded spelling the theme watcher used.
			if prev and trimmed:find("updateMenu", 1, true)
				and prev:find("update_icon()", 1, true)
				and prev:find("function", 1, true) then
				table.insert(offenders, (line_no - 1) .. ": guarded update_icon then updateMenu")
			end
			if trimmed ~= "" then prev = trimmed end
		end

		helpers.assert_eq(#offenders, 0,
			"updateMenu's first statement is pcall(update_icon), so a bare update_icon() "
			.. "immediately before it renders the icon twice — off disk, through an "
			.. "off-screen canvas, from inside the script-control eventtap callback that "
			.. "carries the key needed to un-pause. Dropping the bare call also puts the "
			.. "refresh under updateMenu's pcall, where a throw in the render can no longer "
			.. "escape the pause listener: " .. table.concat(offenders, " | "))
	end)

	helpers.it("updateMenu still refreshes the icon itself", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Without this case the assertion above would pass against a change that
		-- deleted the refresh from BOTH places, leaving the icon frozen on the
		-- previous pause state.
		local at = code:find("updateMenu = function", 1, true)
		helpers.assert_true(at ~= nil, "updateMenu must still be defined")
		helpers.assert_true(code:sub(at, at + 200):find("update_icon", 1, true) ~= nil,
			"updateMenu must keep refreshing the icon — it is the single place that does, "
			.. "and every caller relies on that")
	end)

	helpers.it("the memo still short-circuits an unchanged render", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- The redundancy is cheap only because of the memo. If it were removed, the
		-- double render would come straight back, so the two belong in one guard.
		helpers.assert_true(code:find("icon_key == " .. ANCHOR, 1, true) ~= nil,
			"the icon depends on exactly two inputs; when neither moved there is nothing "
			.. "to redraw, and this early return is what makes a stray extra call harmless")
	end)

end)
