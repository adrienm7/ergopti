--- tests/unit/modules/hotstrings/test_clipboard_restore_on_throw.lua

--- ==============================================================================
--- MODULE: Regression — every clipboard writer restores when it throws
--- DESCRIPTION:
--- cab63e623 fixed this for adapters/text_sender: between writing our payload to
--- the clipboard and arming the restore timer there is a window where a throw —
--- the write failing, the keystroke raising — leaves the user's clipboard holding
--- our text permanently, with the saved original still set so the next send does
--- not even re-capture it. The enclosing pcall caught and logged the error, which
--- is exactly why nobody noticed the clipboard had been eaten.
---
--- ROOT CAUSE ENCODED:
--- The fix landed on ONE of the two paths with that shape.
--- modules/keymap/utils.perform_paste is the other, and it is the one every real
--- hotstring paste goes through. Asserted as a class: each clipboard-writing
--- function must restore on the failure path, not just the one that was reported.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("clipboard: a write that throws must not keep the user's clipboard", function()

	helpers.it("perform_paste restores the original when the paste raises", function()
		local src = helpers.read_driver_source("local function perform_paste")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the keymap utils source must be readable or this asserts nothing")
		local at = src:find("local function perform_paste", 1, true)
		helpers.assert_not_nil(at, "perform_paste must exist")
		local next_function = src:find("function M.emit_tokens", at, true)
		helpers.assert_not_nil(next_function, "perform_paste must remain a bounded unit")
		local body = src:sub(at, next_function - 1)
		local ownership_at = body:find("_paste_owns_clipboard = true", 1, true)
		local write_at = body:find("pcall(hs.pasteboard.setContents", 1, true)
		local rejected_at = body:find("not ok_write or write_result ~= true", 1, true)
		local restore_at = rejected_at and body:find("restore_owned_clipboard()", rejected_at, true)
		local timer_at = body:find("local restore_armed", 1, true)

		helpers.assert_true(ownership_at ~= nil and write_at ~= nil and rejected_at ~= nil
			and restore_at ~= nil and timer_at ~= nil,
			"the keymap paste must retain ownership, inspect throw/false, restore, then arm output")
		helpers.assert_true(ownership_at < write_at and write_at < rejected_at
			and rejected_at < restore_at and restore_at < timer_at,
			"ownership must precede the possibly mutating native write, whose throw/false path "
			.. "must restore before any Cmd+V restore timer can be committed")
	end)

	helpers.it("the sibling that was already fixed still restores", function()
		helpers.with_stub_scope({
			"adapters.text_sender", "adapters.clipboard", "adapters.synthetic_input",
			"adapters.timer_scheduler", "adapters.event_provenance", "adapters.storage",
			"adapters.json_codec", "infra.logger", "infra.paths", "infra.timings",
		}, function()
			local f = require("tests.support.synthetic_input_fixture").make({ deliver_trigger = false })
			local original = { ["public.utf8-plain-text"] = "USER CLIPBOARD", ["public.html"] = "<b>original</b>" }
			local clipboard, writes, restores, notifications, count = original, 0, 0, 0, 0
			f.hs_overrides.pasteboard = {
				changeCount = function() return count end,
				readAllData = function() return clipboard end,
				setContents = function(text)
					writes = writes + 1
					count = count + 1
					clipboard = { ["public.utf8-plain-text"] = text }
					error("native write raised after changing the pasteboard")
				end,
				writeAllData = function(value)
					restores = restores + 1
					count = count + 1
					clipboard = value
					return true
				end,
				clearContents = function() count = count + 1; clipboard = {} end,
			}
			local synthetic = f.load()
			local sender = require("adapters.text_sender")
			helpers.assert_eq(sender.send("PRIVATE PAYLOAD", { mode = "clipboard" }, function()
				notifications = notifications + 1
			end), false)
			helpers.assert_eq(writes, 1, "the real native write must mutate before throwing")
			helpers.assert_eq(notifications, 1, "the refused request still notifies its caller inline")
			helpers.assert_true(helpers.deep_equal(clipboard, original),
				"all original pasteboard types must return before the failed send returns")
			helpers.assert_eq(restores, 1, "the failed native write owns exactly one restoration")
			helpers.assert_eq(#f.pump_deliveries, 0, "the refused payload must never reach native Cmd+V")
			local stats = synthetic.stats()
			helpers.assert_eq(stats.active_transactions, 0, "no producer may outlive the refused write")
			helpers.assert_eq(stats.pending, 0, "no queued paste may dispatch after the refusal returns")
			helpers.assert_eq(stats.records, 0, "no synthetic key record may remain armed")
		end)
	end)

end)
