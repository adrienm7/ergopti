--- tests/unit/shortcuts/engine/text_actions/test_plain_paste_focus_real.lua

--- Exercises real focus tracker, clipboard owner and deferred synthetic broker.
local helpers = require("tests.helpers")
local with_sender = require("tests.support.core.text_sender_fixture")
require("core.logger.engine")

local function tick(f, delay)
	for index, timer in ipairs(f.timers) do
		if not timer.stopped and timer.delay <= delay then
			table.remove(f.timers, index)
			f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
			timer.callback()
			if timer.recurring and not timer.stopped then f.timers[#f.timers + 1] = timer end
			return true
		end
	end
	return false
end

local function emitted(f)
	local total = f.key_posts
	for _, delivery in ipairs(f.pump_deliveries) do total = total + #(delivery.events or {}) end
	return total
end

local function with_focus(callback)
	helpers.with_stub_scope({ "hotstrings.engine.expander.utils", "platform.focus.secure_field_detector",
		"shortcuts.engine.actions.text", "shortcuts.engine.actions.text_continuation",
		"shortcuts.engine.actions.text_dispatch", "shortcuts.engine.actions.text_transform_grace" }, function()
		with_sender(function(f)
			local focus = { element = {}, reads = 0, callbacks = {} }
			local function watcher(kind, receive)
				focus.callbacks[kind] = receive
				return { start = function(self) return self end, stop = function(self) return self end }
			end
			local app = { pid = function() focus.reads = focus.reads + 1; return 7 end,
				name = function() focus.reads = focus.reads + 1; return "Editor" end,
				newWatcher = function(_, receive) return watcher("focus", receive) end }
			local window = { id = function() focus.reads = focus.reads + 1; return 42 end,
				title = function() focus.reads = focus.reads + 1; return "Editor" end,
				application = function() focus.reads = focus.reads + 1; return app end,
				newWatcher = function(_, receive) return watcher("title", receive) end }
			hs.application = { watcher = { activated = 1, deactivated = 2,
				new = function(receive) return watcher("app", receive) end } }
			hs.window = { focusedWindow = function() focus.reads = focus.reads + 1; return window end }
			package.loaded["platform.focus.secure_field_detector"] = {
				isSecureApp = function() return false end,
				inspectFocusedElementWithReceipt = function()
					focus.reads = focus.reads + 1
					return false, nil, focus.element
				end,
				watchFocusedElementChanges = function(_, receive) return watcher("secure", receive), nil, true end,
			}
			local board = f.hs_overrides.pasteboard
			board.getContents = function() return f.clipboard()["public.utf8-plain-text"] end
			hs.pasteboard.getContents = board.getContents
			local utils = require("hotstrings.engine.expander.utils")
			utils.start_ignored_win_tracking({}, {})
			helpers.assert_true(utils.prewarm_ignored_win_watchers({}, {}))
			package.loaded["core.fs.engine.paths"] = { shared = function() return nil end }
			package.loaded["core.timing.engine.timings"] = { sec = function() return 0.01 end }
			local text = require("shortcuts.engine.actions.text")
			local ok, err = xpcall(function() callback(f, focus, text) end, debug.traceback)
			pcall(utils.stop)
			if not ok then error(err, 0) end
		end)
	end)
end

helpers.describe("native destination guard for clipboard actions", function()
	for _, action in ipairs({ "plain", "wrap" }) do
		helpers.it(action .. " refuses an unclassified destination without synchronous AX", function()
			with_focus(function(f, focus, text)
				assert(focus.callbacks.focus)()
				local before = focus.reads
				local accepted
				if action == "plain" then accepted = text.paste_as_plain_text()
				else accepted = text.wrap_selection("selected", "(", ")") end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(focus.reads, before)
				helpers.assert_eq(emitted(f), 0)
				helpers.assert_eq(f.clipboard(), f.initial)
			end)
		end)
		helpers.it(action .. " restores the clipboard after focus changes following a committed paste", function()
			with_focus(function(f, focus, text)
				local accepted
				if action == "plain" then accepted = text.paste_as_plain_text()
				else accepted = text.wrap_selection("selected", "(", ")") end
				helpers.assert_eq(accepted, true)
				if action == "plain" then helpers.assert_true(tick(f, 0.01)) end
				f.finish_broker()
				helpers.assert_eq(emitted(f), 2)
				focus.element = {}
				for _ = 1, 8 do if not tick(f, 1) then break end end
				helpers.assert_eq(f.clipboard(), f.initial, "focus revocation must not block cleanup")
			end)
		end)
		for _, change in ipairs({ false, true }) do
			helpers.it(action .. (change and " refuses changed focus" or " accepts stable focus"), function()
				with_focus(function(f, focus, text)
					local before = focus.reads
					local accepted
					if action == "plain" then accepted = text.paste_as_plain_text()
					else accepted = text.wrap_selection("selected", "(", ")") end
					helpers.assert_eq(accepted, true)
					helpers.assert_eq(focus.reads, before, "input callback must not synchronously query AX")
					if action == "plain" then helpers.assert_true(tick(f, 0.01)) end
					if change then focus.element = {} end
					f.finish_broker()
					if change then
						helpers.assert_eq(emitted(f), 0, "old clipboard transaction cannot paste into a different field")
					else
						helpers.assert_eq(emitted(f), 2)
					end
					for _ = 1, 8 do if not tick(f, 1) then break end end
					helpers.assert_eq(f.clipboard(), f.initial, "all original clipboard formats must be restored")
				end)
			end)
		end
	end
end)
