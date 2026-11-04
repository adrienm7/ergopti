--- tests/unit/modules/gestures/actions/clipboard/test_search_clear_contract.lua

--- ==============================================================================
--- MODULE: Search Clipboard Void Clear Contract
--- DESCRIPTION:
--- The pinned pasteboard clear primitive returns no Lua values. Drive its real
--- search consumer with that contract while retaining restore failures and scope
--- cleanup. These portable native-shaped ports do not claim physical Cmd+C.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local function it(name, callback)
	helpers.it(name, function()
		helpers.with_stub_scope({ "adapters.window_manager", "native_app_switcher_owner" }, function()
			Fixture.with_fixture(callback)
		end)
	end)
end

local function native_void_clear(calls)
	local primitive = calls.hs.pasteboard.clearContents
	calls.hs.pasteboard.clearContents = function()
		primitive()
		-- libpasteboard.m:158-162 returns zero Lua values after its side effect.
	end
end

local function initialize(actions)
	actions.init({ action_params = {} })
	helpers.assert_true(actions.set_action_parameter("tap_3", "search_web", "https://example.test/?q=%s"))
end

local function deliver_capture(calls)
	local timer = calls.hs.timer.__timers[1]
	helpers.assert_not_nil(timer, "a healthy clear must admit the retained copy continuation")
	timer:fire()
end

helpers.describe("search clipboard clear has no native success return", function()
	it("keeps the real Clipboard adapter healthy over the same zero-result primitive", function(fresh_actions)
		local _, calls = fresh_actions()
		native_void_clear(calls)
		helpers.assert_eq(calls.clipboard_text(), "original")
		helpers.with_stub_scope({ "adapters.clipboard" }, function()
			local Clipboard = require("adapters.clipboard")
			helpers.assert_true(Clipboard.restore(nil))
		end)
		helpers.assert_nil(calls.clipboard_text(), "the native-shaped primitive actually cleared the board")
		helpers.assert_eq(#calls.errors, 0)
	end)

	it("copies and opens the selected text after a healthy zero-result clear", function(fresh_actions)
		local actions, calls = fresh_actions()
		native_void_clear(calls)
		initialize(actions)
		helpers.assert_true(actions.execute_single("search_web", "tap_3"))
		helpers.assert_eq(#calls.keys, 1, "void return must not reject the Cmd+C acquisition")
		deliver_capture(calls)
		helpers.assert_eq(calls.opened_urls, { "https://example.test/?q=selected%20words" })
		helpers.assert_eq(calls.clipboard_text(), "original")
		helpers.assert_eq(#calls.errors, 0)
		helpers.assert_true(actions.force_cleanup("gestures"))
	end)

	it("restores an initially empty clipboard and retires its owner on cleanup", function(fresh_actions)
		local actions, calls = fresh_actions()
		native_void_clear(calls)
		helpers.assert_eq(select("#", calls.hs.pasteboard.clearContents()), 0)
		initialize(actions)
		actions.execute_single("search_web", "tap_3")
		helpers.assert_true(actions.force_cleanup("gestures"), "empty snapshot clear is an acknowledged native effect")
		helpers.assert_nil(calls.clipboard_text())
		helpers.assert_eq(calls.clipboard_restore_calls, 0, "an empty snapshot uses the void native clear")
		helpers.assert_eq(#calls.errors, 0)
	end)

	it("keeps a throwing clear visible and rolls back before copying", function(fresh_actions)
		local actions, calls = fresh_actions()
		calls.hs.pasteboard.clearContents = function() error("CONTROLLED_CLEAR_EXCEPTION") end
		initialize(actions)
		actions.execute_single("search_web", "tap_3")
		helpers.assert_eq(#calls.keys, 0)
		helpers.assert_eq(#calls.opened_urls, 0)
		helpers.assert_eq(calls.clipboard_text(), "original")
		helpers.assert_true(#calls.errors > 0)
		helpers.assert_true(actions.force_cleanup("gestures"))
	end)

	for _, refusal in ipairs({ "false", "nil", "throw" }) do
		it("keeps writeAllData " .. refusal .. " refusal pending and diagnostic", function(fresh_actions)
			local controls = { search_restore_mode = refusal }
			local actions, calls = fresh_actions(controls)
			native_void_clear(calls)
			initialize(actions)
			actions.execute_single("search_web", "tap_3")
			actions.force_cleanup("gestures")
			helpers.assert_true(calls.clipboard_restore_calls > 0)
			helpers.assert_true(#calls.errors > 0, "nonvoid restoration refusal remains an error")
			if refusal ~= "throw" then
				local detailed = false
				for _, entry in ipairs(calls.errors) do
					if entry.message:find("clipboard restore returned " .. refusal, 1, true) then detailed = true end
				end
				helpers.assert_true(detailed, "the original false/nil refusal detail must remain visible")
			end
			helpers.assert_eq(actions.force_cleanup("gestures"), false)
			controls.search_restore_mode = nil
			helpers.assert_true(actions.force_cleanup("gestures"))
			helpers.assert_eq(calls.clipboard_text(), "original", "the original snapshot survived the refused restore")
		end)
	end
end)
