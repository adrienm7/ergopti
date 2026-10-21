--- tests/support/modules/gestures/search_fifo_fixture.lua
--- Actual Search, Clipboard, SyntheticInput and Scheduler over explicit native ports.
local helpers = require("tests.helpers")
local Gesture = require("tests.support.gesture_actions_fixture")
local Native = require("tests.support.synthetic_input_fixture")
require("infra.logger")
local M = {}
function M.with_world(options, callback)
	return helpers.with_stub_scope({ "adapters.window_manager", "native_app_switcher_owner",
		"adapters.storage", "adapters.event_provenance", "tests.stubs.hs", "hs", "logger.shim" }, function()
		return Gesture.with_fixture(function(fresh)
			fresh()
			local f = Native.make({ absolute_time = 0, epoch = 1900000000 })
			local syn = f.load()
			local original = { ["public.utf8-plain-text"] = "ORIGINAL", ["public.html"] = "<b>ORIGINAL</b>" }
			local board, generation, copies, restores, reads, now = original, 0, 0, 0, 0, 0
			local urls, trace = {}, {}
			local w = { fixture = f, synthetic = syn, original = original }
			local function copy(event)
				if event.isDown and event.key == "c" and table.concat(event.modifiers or {}, "+") == "cmd" then
					copies = copies + 1; generation = generation + 1
					board = { ["public.utf8-plain-text"] = "SELECTED WORDS" }
					trace[#trace+1] = { kind = "copy", at = now }
				end
			end
			f.key_observer = copy
			hs.pasteboard = {
				readAllData = function() return board end,
				changeCount = function() if w.count_unavailable then return nil end; return generation end,
				clearContents = function() board = {}; generation = generation + 1 end,
				getContents = function() reads = reads + 1; trace[#trace+1] = { kind="read", at=now }; return board["public.utf8-plain-text"] end,
				writeAllData = function(value)
					restores = restores + 1
					if w.restore_refuses then return false end
					generation = generation + 1; board = value
					trace[#trace+1] = { kind="restore", at=now }; return true
				end,
			}
			hs.urlevent = { openURL = function(value) urls[#urls+1] = value; return true end }
			local after = hs.timer.doAfter
			hs.timer.doAfter = function(delay, action)
				local native = after(delay, action); local stop = native.stop
				native.stop = function(self) stop(self); return self end
				return native
			end
			package.loaded["adapters.clipboard"] = nil
			package.loaded["modules.gestures.actions"] = nil
			local actions = require("modules.gestures.actions")
			actions.init({ action_params = {} })
			assert(actions.set_action_parameter("keyboard__cmd_1", "search_web", "https://example.test/?q=%s"))
			if options.backlog then
				f.callback_active = true; syn.enter_callback()
				local tx = syn.begin("test.search.paced", "replacement")
				syn.with_transaction(tx, function()
					for _=1,options.pairs or 20 do assert(syn.emit_key_stroke({}, "delete", 0)) end
					assert(syn.emit_key_strokes("X"))
				end)
				syn.on_complete(tx, function(_,status) trace[#trace+1] = { kind="head_terminal", at=now, status=status } end)
				local app = { pid=function() return 222 end, isRunning=function() return true end }
				f.live_applications = { [222] = app }
				local owner = assert(syn.prepare_collected_paced(tx, options.pairs or 20, 20000, app))
				assert(syn.seal(tx)); assert(syn.authorize_collected_paced(owner)); assert(syn.commit_collected_paced(owner))
				syn.leave_callback(true); f.callback_active = false
			end
			local applied = 0
			function w.advance(until_time)
				for _=1,2000 do
					local index, deadline
					for i,timer in ipairs(f.timers) do if not timer.stopped then
						timer.due = timer.due or (now + timer.delay)
						if not deadline or timer.due < deadline then index,deadline = i,timer.due end
					end end
					if not index or deadline > until_time then return end
					local timer = table.remove(f.timers,index); now = deadline
					f.options.absolute_time = math.floor(now * 1e9); f.options.epoch = 1900000000 + now
					timer.callback()
					if timer.recurring and not timer.stopped then timer.due = now + timer.delay; f.timers[#f.timers+1] = timer end
					while applied < #f.pump_deliveries do
						applied = applied + 1
						for _,event in ipairs(f.pump_deliveries[applied].events or {}) do copy(event) end
					end
				end
				error("bounded Search timer turns exceeded")
			end
			w.actions, w.trace, w.urls = actions, trace, urls
			function w.start() return actions.execute_single("search_web", "keyboard__cmd_1") end
			function w.counts() return copies, restores, reads end
			function w.clipboard() return board end
			function w.external(text) generation = generation + 1; board = { ["public.utf8-plain-text"] = text } end
			local outcome = table.pack(xpcall(function() return callback(w) end, debug.traceback))
			w.restore_refuses, w.count_unavailable = false, false
			actions.force_cleanup("shortcut_bindings"); w.advance(2)
			assert(actions.force_cleanup("shortcut_bindings") == true, "Search cleanup debt remains")
			assert(syn.stats().pending == 0 and syn.stats().active_transactions == 0, "broker debt remains")
			for _,timer in ipairs(f.timers) do assert(timer.stopped, "native timer remains") end
			if not outcome[1] then error(outcome[2], 0) end
			return table.unpack(outcome, 2, outcome.n)
		end)
	end)
end
return M
