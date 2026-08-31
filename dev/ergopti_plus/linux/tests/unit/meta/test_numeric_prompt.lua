--- tests/unit/meta/test_numeric_prompt.lua

--- ==============================================================================
--- MODULE: A Tray That Can Ask For A Number
--- DESCRIPTION:
--- The window that closes the last LLM gap between this driver and macOS.
---
--- WHAT IT IS FOR:
--- macOS sets its numeric LLM settings through a free-text dialog. The Linux
--- tray has no text input at all, so its menu offered presets and nothing else.
--- The two obvious ways to converge were both wrong: forcing presets onto macOS
--- REMOVES a capability, and leaving the gap means the same setting is more
--- expressive on one platform. This adds the capability to Linux, so both have
--- presets for the common values and free entry for anything else.
---
--- WHY THE BOUNDS ARE CHECKED TWICE:
--- The page checks them so the user gets an answer immediately; the bridge
--- checks them because it is reachable by anything that can post to it, and the
--- caller\'s setter should never see a value its own range forbids. The page is
--- the convenience, the bridge is the guarantee.
---
--- WHAT IS NOT TESTED HERE:
--- That the window renders. There is no display on the CI runner and none on
--- the maintainer\'s machine either, which is true of every webview this driver
--- ships. The seam that CAN be tested is the bridge, and that is what these
--- cases exercise.
--- ==============================================================================

local helpers = require("tests.helpers")

local Prompt = helpers.load_module("ui.numeric_prompt.bridge")

--- A webview manager that records what it was asked to show.
--- @return table
local function fake_webview()
	local shown = {}
	local pushed = {}
	local hidden = 0
	local visible = false
	local fake = {
		shown = shown,
		pushed = pushed,
		show = function(name)
			shown[#shown + 1] = name
			visible = true
			return true
		end,
		eval_js = function(name, code)
			pushed[#pushed + 1] = { name = name, code = code }
			return true
		end,
		hide = function(name)
			helpers.assert_eq(name, "numeric_prompt")
			hidden = hidden + 1
			visible = false
		end,
		is_visible = function() return visible end,
	}
	function fake.hidden_count() return hidden end
	return fake
end




-- =================================================================
-- =================================================================
-- ======= 1/ Asking ===============================================
-- =================================================================
-- =================================================================

helpers.describe("numeric prompt: opening it", function()

	helpers.it("shows the window and carries the request to the page", function()
		Prompt._reset()
		local webview = fake_webview()
		local opened = Prompt.ask({
			title = "Température", value = 0.3, min = 0.0, max = 1.3,
			on_save = function() end,
		}, webview)

		helpers.assert_true(opened)
		helpers.assert_eq(webview.shown[1], "numeric_prompt")

		helpers.assert_eq(#webview.pushed, 1,
			"ask must refresh a retained page without waiting for another load event")
		local result = Prompt.on_message("ready", {})
		helpers.assert_true(result.pushed)
		local payload = result.request
		helpers.assert_eq(payload.value, 0.3,
			"the field must open on the value already in force; an empty box makes "
				.. "the user retype what they already had")
		helpers.assert_eq(payload.min, 0.0)
		helpers.assert_eq(payload.max, 1.3)
		Prompt._reset()
	end)

	helpers.it("refuses a request with no range", function()
		Prompt._reset()
		local webview = fake_webview()
		local opened = Prompt.ask({ title = "x", value = 1, on_save = function() end }, webview)
		helpers.assert_true(not opened,
			"an unbounded numeric field accepts anything, and the caller then has "
				.. "to reject it after the user has typed it")
		helpers.assert_eq(#webview.shown, 0)
	end)

	helpers.it("refuses a request with no callback", function()
		Prompt._reset()
		local webview = fake_webview()
		local opened = Prompt.ask({ title = "x", min = 0, max = 1 }, webview)
		helpers.assert_true(not opened,
			"a prompt whose answer goes nowhere is a window that wastes the user's "
				.. "time and reports success")
	end)

	helpers.it("refuses success when the request cannot reach the page", function()
		Prompt._reset()
		local webview = fake_webview()
		webview.eval_js = function() return false end
		local opened = Prompt.ask({
			title = "x", value = 1, min = 0, max = 2, on_save = function() end,
		}, webview)
		helpers.assert_eq(opened, false)
		helpers.assert_eq(Prompt.is_pending(), false)
		helpers.assert_eq(webview.hidden_count(), 1,
			"a registered but unreachable page must be closed, not reported as ready")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Answering ============================================
-- =================================================================
-- =================================================================

helpers.describe("numeric prompt: the value that comes back", function()

	helpers.it("hands an in-range value to the caller", function()
		Prompt._reset()
		local received = nil
		local webview = fake_webview()
		Prompt.ask({
			title = "t", value = 0.3, min = 0.0, max = 1.3,
			on_save = function(value) received = value end,
		}, webview)

		local epoch = Prompt.on_message("ready", {}).request.request_epoch
		local result = Prompt.on_message({
			action = "save", value = 0.8, request_epoch = epoch,
		}, {})
		helpers.assert_true(result.saved)
		helpers.assert_true(result.closed)
		helpers.assert_eq(received, 0.8)
		helpers.assert_eq(webview.hidden_count(), 1)
	end)

	helpers.it("refuses a value outside the range the caller declared", function()
		Prompt._reset()
		local received = nil
		Prompt.ask({
			title = "t", value = 0.3, min = 0.0, max = 1.3,
			on_save = function(value) received = value end,
		}, fake_webview())

		local epoch = Prompt.on_message("ready", {}).request.request_epoch
		local result = Prompt.on_message({
			action = "save", value = 99, request_epoch = epoch,
		}, {})
		helpers.assert_true(not result.saved,
			"the page checks this too, but the bridge is reachable by anything that "
				.. "can post to it — the caller's setter must never see a value its "
				.. "own range forbids")
		helpers.assert_true(received == nil)
		Prompt._reset()
	end)

	helpers.it("refuses a value that is not a number", function()
		Prompt._reset()
		local received = nil
		Prompt.ask({
			title = "t", value = 1, min = 0, max = 10,
			on_save = function(value) received = value end,
		}, fake_webview())
		local epoch = Prompt.on_message("ready", {}).request.request_epoch
		local result = Prompt.on_message({
			action = "save", value = "beaucoup", request_epoch = epoch,
		}, {})
		helpers.assert_true(not result.saved)
		helpers.assert_true(received == nil)
		Prompt._reset()
	end)

	helpers.it("delivers nothing when the user cancels", function()
		Prompt._reset()
		local received = nil
		local webview = fake_webview()
		Prompt.ask({
			title = "t", value = 1, min = 0, max = 10,
			on_save = function(value) received = value end,
		}, webview)

		local epoch = Prompt.on_message("ready", {}).request.request_epoch
		local result = Prompt.on_message({ action = "cancel", request_epoch = epoch }, {})
		helpers.assert_true(result.closed)
		helpers.assert_eq(webview.hidden_count(), 1)
		helpers.assert_true(received == nil)
		helpers.assert_true(not Prompt.is_pending(),
			"a cancelled prompt must release its request, or the next window opens "
				.. "showing the previous question")
	end)

	helpers.it("ignores a value that arrives with nothing waiting for it", function()
		Prompt._reset()
		local result = Prompt.on_message({ action = "save", value = 5, request_epoch = 1 }, {})
		helpers.assert_true(not result.saved,
			"a stale page, or anything else posting to this bridge, must not reach "
				.. "a callback that has already run")
	end)

	helpers.it("survives a callback that raises", function()
		Prompt._reset()
		local webview = fake_webview()
		Prompt.ask({
			title = "t", value = 1, min = 0, max = 10,
			on_save = function() error("the setter blew up") end,
		}, webview)

		local epoch = Prompt.on_message("ready", {}).request.request_epoch
		local result = Prompt.on_message({
			action = "save", value = 5, request_epoch = epoch,
		}, {})
		helpers.assert_true(not result.saved,
			"the window must report the failure rather than close as if it had "
				.. "worked — and the daemon must not go down with it")
		helpers.assert_true(Prompt.is_pending(), "a failed setter must remain retryable")
		helpers.assert_eq(webview.hidden_count(), 0)
		Prompt._reset()
	end)

	helpers.it("reuses one page with fresh data and rejects its previous request epoch", function()
		Prompt._reset()
		local webview = fake_webview()
		local received = {}
		Prompt.ask({
			title = "Temperature", value = 0.3, min = 0.0, max = 1.3,
			on_save = function(value) received[#received + 1] = { "temperature", value } end,
		}, webview)
		local first_epoch = Prompt.on_message("ready", {}).request.request_epoch

		Prompt.ask({
			title = "Context", value = 500, min = 100, max = 1000,
			on_save = function(value) received[#received + 1] = { "context", value } end,
		}, webview)
		local second_epoch = Prompt.on_message("ready", {}).request.request_epoch
		helpers.assert_true(second_epoch > first_epoch)
		helpers.assert_eq(#webview.shown, 2)
		helpers.assert_true(#webview.pushed >= 4,
			"each show and each ready event must deliver the current request")
		helpers.assert_contains(webview.pushed[#webview.pushed].code, "Context")

		local stale = Prompt.on_message({
			action = "save", value = 0.8, request_epoch = first_epoch,
		}, {})
		helpers.assert_true(stale.stale)
		helpers.assert_eq(#received, 0)
		local current = Prompt.on_message({
			action = "save", value = 700, request_epoch = second_epoch,
		}, {})
		helpers.assert_true(current.saved and current.closed)
		helpers.assert_eq(received, { { "context", 700 } })
	end)

end)

helpers.describe("numeric prompt: shipped page contract", function()
	helpers.it("echoes the host request epoch on both completion actions", function()
		local path = helpers.driver_root() .. "/../_shared/ui/numeric_prompt/script.js"
		local fh = assert(io.open(path, "r"))
		local source = fh:read("*a")
		fh:close()
		helpers.assert_contains(source, "request.request_epoch",
			"receive_prompt must retain the host request identity")
		local echoes = 0
		for _ in source:gmatch("request_epoch: requestEpoch") do echoes = echoes + 1 end
		helpers.assert_eq(echoes, 2,
			"save and cancel must both identify the request they are completing")
	end)
end)
