--- tests/unit/llm/test_sync_refs_respects_reset.lua

--- ==============================================================================
--- MODULE: Regression - a superseded response must not resurrect dead state
--- DESCRIPTION:
--- A non-streaming response can arrive after reset(). The StreamingHandler may
--- reject it correctly while a wrapper above it still copies the old refs back
--- into engine state. The next Tab would then type a prediction the user cannot
--- see. The callback wrappers now share one helper that checks ownership both
--- before and after the caller callback; this test follows that indirection.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("prediction_engine: sync_refs is staleness-aware", function()
	helpers.it("all callback wrappers use the doubly-fenced helper", function()
		local src = helpers.read_driver_source("sync_refs")
		helpers.assert_true(src ~= nil and src ~= "",
			"the prediction engine must be locatable by its sync_refs symbol")

		local helper_at = src:find("local function run_async_callback", 1, true)
		helpers.assert_true(helper_at ~= nil, "the guarded async callback helper must exist")
		local helper_body = src:sub(helper_at, helper_at + 900)
		local first_guard = helper_body:find("if not is_current_fetch() then return end", 1, true)
		local callback_at = helper_body:find("callback(table.unpack", 1, true)
		local sync_at = helper_body:find("if is_current_fetch() then sync_refs() end", 1, true)
		helpers.assert_true(first_guard ~= nil and callback_at ~= nil and sync_at ~= nil
			and first_guard < callback_at and callback_at < sync_at,
			"run_async_callback must fence request ownership before and after the caller callback")

		local wrappers = {
			{ name = "on_success", anchor = "local function on_success(" },
			{ name = "on_fail", anchor = "local function on_fail(" },
			{ name = "on_partial", anchor = "local on_partial = on_partial_cb and function" },
		}
		for _, wrapper in ipairs(wrappers) do
			local at = src:find(wrapper.anchor, 1, true)
			helpers.assert_true(at ~= nil, "the " .. wrapper.name .. " wrapper must exist")
			local body = src:sub(at, at + 300)
			helpers.assert_true(body:find("run_async_callback", 1, true) ~= nil,
				wrapper.name .. " must delegate through the doubly-fenced helper")
			helpers.assert_true(body:find("sync_refs()", 1, true) == nil,
				wrapper.name .. " must not bypass the helper with a direct sync_refs call")
		end
	end)

	helpers.it("the staleness predicate compares the live counter to this request", function()
		local src = helpers.read_driver_source("is_current_fetch")
		helpers.assert_true(src ~= nil and src ~= "", "the engine must define the staleness predicate")
		local at = src:find("local function is_current_fetch", 1, true)
		helpers.assert_true(at ~= nil, "is_current_fetch must exist")
		local body = src:sub(at, at + 200)
		helpers.assert_true(body:find("fetch_request_counter", 1, true) ~= nil,
			"the predicate must read the live counter that reset bumps")
		helpers.assert_true(body:find("my_fetch_id", 1, true) ~= nil,
			"the predicate must compare the counter with this request's captured id")
	end)
end)

helpers.describe("prediction_engine: reset invalidates in-flight responses", function()
	helpers.it("reset bumps the counter before the next public operation", function()
		local src = helpers.read_driver_source("fetch_request_counter")
		helpers.assert_true(src ~= nil and src ~= "", "the engine must expose its fetch counter")
		local at = src:find("function M.reset", 1, true)
		local next_public = at and src:find("\nfunction M.consume", at, true)
		helpers.assert_true(at ~= nil and next_public ~= nil, "M.reset must end before M.consume")
		local body = src:sub(at, next_public - 1)
		helpers.assert_true(body:find("fetch_request_counter%s*=%s*fetch_request_counter%s*%+%s*1") ~= nil,
			"reset must bump the fetch counter so uncancelled responses become stale")
	end)

	helpers.it("the accept path still trusts the visibility state", function()
		local src = helpers.read_driver_source("handle_llm_keys")
		helpers.assert_true(src ~= nil and src ~= "", "the LLM key handler must be locatable")
		helpers.assert_true(src:find("is_visible", 1, true) ~= nil,
			"the accept path still makes resurrected visibility security-relevant")
	end)
end)
