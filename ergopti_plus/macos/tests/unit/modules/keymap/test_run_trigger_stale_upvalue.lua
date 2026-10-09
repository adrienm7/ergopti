--- tests/unit/modules/keymap/test_run_trigger_stale_upvalue.lua

--- ==============================================================================
--- MODULE: Ignored-window hot-path ownership guard
--- DESCRIPTION:
--- The keyDown callback once queried ignored-window state twice and retained an
--- unreachable asynchronous trigger branch below an unconditional early return.
--- A replica-only test exercised that dead closure and could stay green after the
--- production path became impossible. The behavioral companion test drives the
--- real tap; this guard makes the root cause explicit: one query, one total
--- pass-through boundary, and no ignored-window trigger scheduling below it.
--- ==============================================================================

local helpers = require("tests.helpers")

local function raw_handler_source()
	local src = helpers.read_driver_source("local function invalidate_observed_context")
	helpers.assert_not_nil(src, "modules/keymap/init.lua source must be locatable")
	local raw_at = src:find("local function onKeyDownRaw", 1, true)
	local wrapper_at = src:find("local function onKeyDown(e)", raw_at or 1, true)
	helpers.assert_true(raw_at ~= nil and wrapper_at ~= nil and raw_at < wrapper_at,
		"the production raw keyDown handler must be bounded")
	return src:sub(raw_at, wrapper_at - 1)
end

helpers.describe("ignored-window hot-path ownership", function()
	helpers.it("queries ignored-window state exactly once before text processing", function()
		local raw = raw_handler_source()
		local _, query_count = raw:gsub("km_utils%.is_ignored_window%(", "")
		helpers.assert_eq(query_count, 1,
			"a second cached query is dead work and can recreate an impossible split contract")

		local query_at = raw:find("km_utils.is_ignored_window", 1, true)
		local pass_at = raw:find("return internal_loopback == true", query_at, true)
		local flags_at = raw:find("e:getFlags()", query_at, true)
		local chars_at = raw:find("e:getCharacters(false)", query_at, true)
		helpers.assert_true(query_at < pass_at and pass_at < flags_at and pass_at < chars_at,
			"the ignored-window return must precede flags, characters, interceptors, and buffers")
	end)

	helpers.it("contains no deferred trigger branch below the pass-through gate", function()
		local raw = raw_handler_source()
		helpers.assert_true(raw:find("_tc_is_ignored", 1, true) == nil,
			"ignored state must not be copied into trigger context that cannot legally run")
		helpers.assert_true(raw:find("if is_ignored then", 1, true) == nil,
			"the handler must not retain an unreachable second ignored-window branch")
		helpers.assert_true(raw:find("buf_snapshot", 1, true) == nil,
			"dead deferred-buffer snapshot machinery must not return")
		helpers.assert_true(raw:find("hs.timer.doAfter(0", 1, true) == nil,
			"trigger matching must not be scheduled from the keyDown handler")

		local _, trigger_calls = raw:gsub("run_trigger_checks%(%)", "")
		helpers.assert_eq(trigger_calls, 1,
			"reachable non-ignored input must execute one synchronous trigger pass")
	end)
end)
