--- tests/unit/modules/shortcuts/text_actions/clipboard/test_plain_paste_ownership.lua

--- ==============================================================================
--- MODULE: Plain Paste Clipboard Generations
--- DESCRIPTION:
--- Drives real Text, TimerScheduler and SyntheticInput owners through
--- successful native-shaped handoff, external copies and refused restoration.
--- These controls do not qualify Cocoa or physical keyboard delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_sender = require("tests.support.text_sender_fixture")
require("logger")

local function with_plain(callback)
	helpers.with_stub_scope({
		"modules.shortcuts.actions.text", "modules.shortcuts.actions.text_continuation",
		"modules.shortcuts.actions.text_dispatch", "modules.shortcuts.actions.text_transform_grace",
	}, function()
		with_sender(function(f)
			local board = f.hs_overrides.pasteboard
			board.getContents = function() return f.clipboard()["public.utf8-plain-text"] end
			hs.pasteboard.getContents = board.getContents
			package.loaded["infra.paths"] = { shared = function() return nil end }
			package.loaded["infra.timings"] = { sec = function() return 0.01 end }
			f.text = require("modules.shortcuts.actions.text")
			function f.step()
				for _, timer in ipairs(f.timers) do
					if timer.delay == 0.01 and not timer.stopped then
						f.options.absolute_time = f.options.absolute_time + 10000000
						timer.callback()
						return
					end
				end
				error("plain paste owner has no due native timer")
			end
			function f.handoff()
				helpers.assert_true(f.text.paste_as_plain_text())
				f.step(); f.finish_broker()
				local emitted = f.key_posts
				for _, delivery in ipairs(f.pump_deliveries) do emitted = emitted + #(delivery.events or {}) end
				helpers.assert_eq(emitted, 2, "actual SyntheticInput must deliver the complete Cmd+V pair")
			end
			function f.copy(value) helpers.assert_true(board.setContents(value)) end
			callback(f, board)
		end)
	end)
end

helpers.describe("plain paste restores only its own native clipboard generation", function()
	helpers.it("restores every original type after a healthy handoff", function()
		with_plain(function(f)
			f.handoff(); f.step()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.restore_calls, 1)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	helpers.it("preserves the native void clear contract for an empty original", function()
		with_plain(function(f, board)
			board.clearContents()
			f.handoff(); f.step()
			helpers.assert_eq(f.clipboard(), {})
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	for _, identical in ipairs({ false, true }) do
		helpers.it("preserves a later copy after handoff, identical text=" .. tostring(identical), function()
			with_plain(function(f)
				f.handoff()
				local value = identical and "USER CLIPBOARD" or "FOREIGN COPY"
				f.copy(value)
				local foreign, count = f.clipboard(), f.change_count
				f.step()
				helpers.assert_eq(f.clipboard(), foreign)
				helpers.assert_eq(f.change_count, count)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
				helpers.assert_true(f.text.paste_as_plain_text(), "revoked snapshot must not block the next owner")
				f.step(); f.finish_broker(); f.step()
				helpers.assert_eq(f.clipboard(), foreign)
			end)
		end)
	end

	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("retains cleanup debt while native count is " .. mode, function()
			with_plain(function(f)
				f.handoff(); f.count_failure = mode
				f.step()
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.text.has_pending_text_action())
				helpers.assert_eq(f.text.paste_as_plain_text(), false)
				f.count_failure = nil; f.step()
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)
	end

	helpers.it("revokes retained debt when a new copy arrives during count refusal", function()
		with_plain(function(f)
			f.handoff(); f.count_failure = "nil"; f.step()
			f.copy("COPY DURING RETRY")
			f.count_failure = nil
			local count = f.change_count
			f.step()
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "COPY DURING RETRY")
			helpers.assert_eq(f.change_count, count)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	helpers.it("never adopts a later count when the initial mutation receipt was unavailable", function()
		with_plain(function(f)
			f.count_failure = "nil"
			helpers.assert_eq(f.text.paste_as_plain_text(), false)
			f.count_failure = nil
			f.copy("NEW COPY")
			local foreign = f.clipboard()
			f.step()
			helpers.assert_eq(f.clipboard(), foreign)
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_true(f.text.has_pending_text_action(), "unknown initial ownership remains explicit debt")
			helpers.assert_eq(f.text.paste_as_plain_text(), false)
		end)
	end)

	helpers.it("retries a partial refused restore using its own post-mutation receipt", function()
		with_plain(function(f, board)
			f.handoff()
			local native_restore, first = board.writeAllData, true
			board.writeAllData = function(snapshot)
				if first then
					first = false
					native_restore({ ["public.utf8-plain-text"] = "PARTIAL RESTORE" })
					return false
				end
				return native_restore(snapshot)
			end
			hs.pasteboard.writeAllData = board.writeAllData
			f.step()
			helpers.assert_true(f.text.has_pending_text_action())
			helpers.assert_eq(f.restore_calls, 1)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PARTIAL RESTORE")
			f.step()
			helpers.assert_eq(f.restore_calls, 2)
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("captures restore " .. refusal .. " receipt before its diagnostic copies new data", function()
			with_plain(function(f, board)
				f.handoff()
				if refusal == "false" then f.restore_refusal = "false"
				else
					local native_restore = board.writeAllData
					board.writeAllData = function(value)
						native_restore(value)
						error("native restore threw after mutation")
					end
					hs.pasteboard.writeAllData = board.writeAllData
				end
				local diagnostic, original = false, f.logger.error
				f.logger.error = function(...)
					original(...)
					if not diagnostic then diagnostic = true; f.copy("COPY DURING ERROR") end
				end
				f.step()
				helpers.assert_true(diagnostic)
				helpers.assert_eq(f.restore_calls, 1)
				f.restore_refusal = nil
				local count = f.change_count
				f.step()
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "COPY DURING ERROR")
				helpers.assert_eq(f.change_count, count)
				helpers.assert_eq(f.restore_calls, 1)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)
	end

	helpers.it("refuses a reentrant successor during ownership-revocation diagnostics", function()
		with_plain(function(f)
			f.handoff(); f.copy("FOREIGN")
			local admitted, original = {}, f.logger.info
			f.logger.info = function(...)
				original(...)
				admitted[#admitted + 1] = f.text.paste_as_plain_text()
			end
			f.step()
			helpers.assert_eq(admitted, { false })
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "FOREIGN")
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)
end)
