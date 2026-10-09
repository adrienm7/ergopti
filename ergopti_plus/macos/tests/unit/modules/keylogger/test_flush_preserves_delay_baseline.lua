--- tests/unit/modules/keylogger/test_flush_preserves_delay_baseline.lua

--- ==============================================================================
--- MODULE: Regression — a keystroke-driven flush must not zero the next delay
--- DESCRIPTION:
--- Corrupted timing data: roughly one keystroke in six was logged with delay 0.
---
--- ROOT CAUSE ENCODED:
--- LogManager.flush_buffer() resets CoreState.last_time to 0. handle_key computes
--- the inter-keystroke delay as `now - CoreState.last_time`, so the FIRST keystroke
--- after any flush measured against 0 and recorded a delay of 0 — losing exactly
--- the inter-word gap, which is the most meaningful pause in typing telemetry.
--- Every space and sentence-ending punctuation flushes, so the loss was systematic
--- rather than occasional, and it silently skewed every WPM and n-gram timing
--- statistic derived from the data.
---
--- The file already knew: the metrics-webview flush re-seeds `CoreState.last_time =
--- now` immediately after flushing, with a comment naming this exact hazard. The
--- seven keystroke-driven flush sites — Tab, Escape, Enter, F-keys, nav keys, and
--- the two space/punctuation branches — did not. This is the repo's signature
--- shape: the invariant was written down once and applied at one site.
---
--- The behavioral matrix lives in test_eventtap_persistence_deferred.lua and drives
--- every boundary through the real event callback. This companion guard asserts
--- that all event producers still share the same append owner, so a future sibling
--- cannot bypass either the delay re-seed or the stuck-key memory watermark.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Removes Lua line and long-bracket comments before executable-token scans.
--- @param source string Production Lua source.
--- @return string code Comment-free source.
local function strip_lua_comments(source)
	local code = source
	local cursor = 1
	while true do
		local open_at, open_end, equals = code:find("%-%-%[(=*)%[", cursor)
		if not open_at then break end
		local close_token = "]" .. equals .. "]"
		local _, close_end = code:find(close_token, open_end + 1, true)
		if not close_end then
			code = code:sub(1, open_at - 1)
			break
		end
		local block = code:sub(open_at, close_end)
		local newlines = block:gsub("[^\n]", "")
		code = code:sub(1, open_at - 1) .. newlines .. code:sub(close_end + 1)
		cursor = open_at + #newlines
	end
	return (code:gsub("%-%-[^\n]*", ""))
end

--- Counts non-overlapping Lua-pattern matches.
--- @param source string Source to scan.
--- @param pattern string Lua pattern.
--- @return number count
local function count_pattern(source, pattern)
	local count = 0
	for _ in source:gmatch(pattern) do count = count + 1 end
	return count
end




-- ==============================================
-- ==============================================
-- ======= 1/ Every Flush Re-seeds ==============
-- ==============================================
-- ==============================================

helpers.describe("keystroke-driven flushes preserve the inter-key delay baseline", function()
	helpers.it("routes every buffered event through one bounded baseline owner", function()
		local src = helpers.read_driver_source("local function append_buffer_event")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")
		if not src then return end
		local code = strip_lua_comments(src)

		local helper_at = code:find("local function append_buffer_event", 1, true)
		local declaration_end = code:find("\n", helper_at, true)
		local first_call = code:find("append_buffer_event%(", declaration_end + 1)
		helpers.assert_not_nil(first_call, "the append owner must have real call sites")
		local helper_body = code:sub(helper_at, first_call - 1)
		helpers.assert_true(helper_body:find("LogManager%.flush_buffer%(%)") ~= nil,
			"the shared append owner must detach completed or full typing runs")
		helpers.assert_true(helper_body:find("CoreState%.last_time%s*=%s*now") ~= nil,
			"the shared append owner must re-seed the next inter-key delay")
		helpers.assert_eq(count_pattern(code,
			"table%.insert%(CoreState%.buffer_events"), 1,
			"no event-producing sibling may append outside the bounded owner")
		helpers.assert_true(count_pattern(code, "append_buffer_event%(") >= 10,
			"the source guard must cover the owner plus every event-producing branch")
	end)
end)
