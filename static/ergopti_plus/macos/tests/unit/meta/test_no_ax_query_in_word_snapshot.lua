--- tests/unit/meta/test_no_ax_query_in_word_snapshot.lua

--- ==============================================================================
--- MODULE: Regression — the per-word context snapshot queries nothing
--- DESCRIPTION:
--- `handle_key` takes a context snapshot on the first keystroke of every new
--- buffer, i.e. once per word, inside the keyDown eventtap callback. It used to
--- build that snapshot by QUERYING: `frontmostApplication():title()` and
--- `mainWindow():title()` are cross-process accessibility calls that block on the
--- target application answering, and `hs.keycodes.currentLayout()` is a Carbon/TIS
--- query. Three OS round trips per word, on the one callback whose overrun makes
--- macOS disable the tap.
---
--- ROOT CAUSE ENCODED:
--- A snapshot written as a query when every value it wants is already maintained
--- elsewhere. The context tracker's app watcher sets active_app_name on every
--- activation and its window handler has the focused title in hand on every window
--- change; the layout changes only when the OS says so. The assertion is that the
--- snapshot READS rather than ASKS.
---
--- PROVENANCE: source invariant. The snapshot is a few lines inside the keyDown
--- handler, reached only from a live eventtap with a populated CoreState, and what
--- must be proven is the absence of a call.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The snapshot is anchored on the field it fills.
local ANCHOR = "session_win_title"

-- The queries it must not make.
local FORBIDDEN = {
	"frontmostApplication()",
	":mainWindow()",
	"keycodes.currentLayout()",
}




-- ==================================================================
-- ==================================================================
-- ======= 1/ The snapshot reads, it does not ask ===================
-- ==================================================================
-- ==================================================================

helpers.describe("keylogger: the per-word snapshot makes no OS query", function()

	helpers.it("queries neither the frontmost app, its window, nor the layout", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the keylogger must be locatable by '" .. ANCHOR .. "'; an empty corpus would "
			.. "make every assertion below vacuous")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("CoreState.session_app_name%s*=")
		helpers.assert_true(at ~= nil, "the snapshot must still be findable")
		-- The snapshot block only: a generous window that still ends well before the
		-- rest of the handler.
		local block = code:sub(math.max(1, at - 400), at + 600)

		local offenders = {}
		for _, q in ipairs(FORBIDDEN) do
			if block:find(q, 1, true) then table.insert(offenders, q) end
		end

		helpers.assert_eq(#offenders, 0,
			"this block runs on the first keystroke of every WORD, inside the keyDown "
			.. "eventtap callback. The two title reads are cross-process accessibility "
			.. "calls that block on the target application answering, and a tap whose "
			.. "callback overruns is disabled outright by macOS. Every value is already "
			.. "maintained elsewhere: " .. table.concat(offenders, ", "))
	end)

	helpers.it("still fills all three fields", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Without this case the assertion above would pass against a snapshot that
		-- simply stopped recording the context, which every log row depends on.
		for _, field in ipairs({ "session_app_name", "session_win_title", "session_layout" }) do
			helpers.assert_true(code:find("CoreState." .. field .. " ", 1, true) ~= nil
				or code:find("CoreState." .. field .. "=", 1, true) ~= nil,
				"the snapshot must still record " .. field)
		end
	end)

	helpers.it("the layout cache is refreshed, not frozen", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Caching without invalidation would be worse than the query: every row after
		-- a layout switch would carry the wrong layout, silently and forever.
		helpers.assert_true(code:find("inputSourceChanged", 1, true) ~= nil,
			"the cached layout must be refreshed from the OS notification, or a layout "
			.. "switch would mislabel every subsequent row for the rest of the session")
	end)

end)
