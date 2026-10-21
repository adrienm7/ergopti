--- tests/unit/modules/shortcuts/text_actions/clipboard/test_initial_clipboard_capture.lua

--- ==============================================================================
--- MODULE: Initial Clipboard Capture Regression
--- DESCRIPTION:
--- Snapshot capture and the first owned mutation must share one native clipboard
--- generation; refusal preserves a newer copy before any document work starts.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.shortcuts.initial_clipboard_fixture")

helpers.describe("initial-clipboard-capture", function()
	for _, kind in ipairs({ "plain", "wrap", "transform" }) do
		for _, original in ipairs({ "all-types", "empty", "nil-snapshot" }) do
			helpers.it("(initial-clipboard-capture) " .. kind .. " preserves healthy " .. original, function()
				Fixture.run(kind, { empty = original == "empty", nil_snapshot = original == "nil-snapshot" }, function(state)
					helpers.assert_eq(state.start(), true)
					state.finish()
					helpers.assert_eq(state.fixture.clipboard(), state.initial)
					helpers.assert_eq(state.text.has_pending_text_action(), false)
					helpers.assert_true(state.emitted() >= 2)
					if original == "all-types" then helpers.assert_eq(state.fixture.restore_calls, 1) end
				end)
			end)
		end
		local boundaries = kind == "plain" and { "snapshot", "plain", "timer" }
			or kind == "transform" and { "snapshot", "timer" } or { "snapshot" }
		for _, boundary in ipairs(boundaries) do
			for _, identical in ipairs({ false, true }) do
				helpers.it("(initial-clipboard-capture) " .. kind .. " preserves copy at " .. boundary
					.. ", identical=" .. tostring(identical), function()
					Fixture.run(kind, { copy_at = boundary, identical = identical }, function(state)
						helpers.assert_eq(state.start(), false)
						helpers.assert_eq(state.copies, 1)
						state.assert_refused()
						helpers.assert_true(rawequal(state.fixture.clipboard(), state.foreign))
						helpers.assert_eq(state.fixture.change_count, state.foreign_count)
					end)
				end)
			end
		end
		for read = 1, 3 do
			for _, refusal in ipairs({ "nil", "throw" }) do
				helpers.it("(initial-clipboard-capture) " .. kind .. " refuses count " .. read .. " " .. refusal, function()
					Fixture.run(kind, { refuse_count_at = read, count_refusal = refusal }, function(state)
						helpers.assert_eq(state.start(), false)
						state.assert_refused()
						helpers.assert_true(rawequal(state.fixture.clipboard(), state.initial))
						helpers.assert_eq(state.fixture.change_count, state.initial_count)
					end)
				end)
			end
		end
		for _, read in ipairs({ 1, 3 }) do
			helpers.it("(initial-clipboard-capture) " .. kind .. " fences PAUSE from count " .. read, function()
				Fixture.run(kind, { pause_on_count = read }, function(state)
					helpers.assert_eq(state.start(), false)
					helpers.assert_eq(state.pause_attempted, true)
					state.assert_refused()
					helpers.assert_eq(state.fixture.change_count, state.initial_count)
					helpers.assert_eq(state.text.resume_text_actions(), true)
				end)
			end)
		end
		helpers.it("(initial-clipboard-capture) " .. kind .. " finally retires an interrupted healthy action", function()
			local text
			local ok, detail = pcall(function()
				Fixture.run(kind, {}, function(state)
					text = state.text
					if state.start() ~= true then error("healthy action failed before forced assertion") end
					error("controlled initial clipboard fixture assertion")
				end)
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("controlled initial clipboard fixture assertion", 1, true) ~= nil)
			helpers.assert_eq(text.has_pending_text_action(), false)
		end)
	end
end)
