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
--- change; the input-source broker multiplexes the OS notification to every
--- subscriber. The assertion is that the snapshot READS rather than ASKS.
---
--- PROVENANCE: source invariant. The snapshot is a few lines inside the keyDown
--- handler, reached only from a live eventtap with a populated CoreState, and what
--- must be proven is the absence of a call.
--- ==============================================================================

local helpers = require("tests.helpers")

-- This declaration is unique to the keylogger translation unit.
local KEYLOGGER_SELECTOR = "local function ensure_browser_window_filter"

-- The queries it must not make.
local FORBIDDEN = {
	"frontmostApplication()",
	":mainWindow()",
	"keycodes.currentLayout()",
}

--- Reads the one keylogger translation unit for meaningful position checks.
--- @return string Production source without line comments.
local function keylogger_source()
	local source, err = helpers.read_driver_unit(KEYLOGGER_SELECTOR)
	helpers.assert_not_nil(source, err)
	return source:gsub("%-%-[^\n]*", "")
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ The snapshot reads, it does not ask ===================
-- ==================================================================
-- ==================================================================

helpers.describe("keylogger: the per-word snapshot makes no OS query", function()

	helpers.it("queries neither the frontmost app, its window, nor the layout", function()
		local code = keylogger_source()

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
		local code = keylogger_source()

		-- Without this case the assertion above would pass against a snapshot that
		-- simply stopped recording the context, which every log row depends on.
		for _, field in ipairs({ "session_app_name", "session_win_title", "session_layout" }) do
			helpers.assert_true(code:find("CoreState." .. field .. " ", 1, true) ~= nil
				or code:find("CoreState." .. field .. "=", 1, true) ~= nil,
				"the snapshot must still record " .. field)
		end
	end)

	helpers.it("the layout cache is refreshed, not frozen", function()
		local code = keylogger_source()

		-- Caching without invalidation would be worse than the query: every row after
		-- a layout switch would carry the wrong layout, silently and forever. The
		-- broker is the process-wide native owner, so this consumer must subscribe
		-- instead of replacing a sibling through the setter-only Hammerspoon API.
		local subscribe_pos = code:find(
			"InputSourceBroker.subscribe(INPUT_SOURCE_SUBSCRIBER_ID", 1, true)
		helpers.assert_true(subscribe_pos ~= nil,
			"the keylogger must subscribe its layout cache to the input-source broker")
		local callback_block = code:sub(subscribe_pos, subscribe_pos + 700)
		helpers.assert_contains(callback_block, "pcall(hs.keycodes.currentLayout)")
		helpers.assert_contains(callback_block, "_cached_layout = new_layout")
		helpers.assert_true(not callback_block:find("inputSourceChanged", 1, true),
			"the keylogger consumer must not replace the broker's native callback")
	end)

end)
