--- tests/support/modules/shortcuts/initial_clipboard_fixture.lua

--- ==============================================================================
--- MODULE: Initial Clipboard Capture Fixture
--- DESCRIPTION:
--- Composes real text actions and native handoff owners around one initial
--- clipboard generation, before any action-owned write or clear is permitted.
--- Native-shaped ports model foreign copies without claiming Cocoa delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_sender = require("tests.support.text_sender_fixture")
local M = {}

--- Runs one public text action with exact module and native-state restoration.
--- @param kind string plain|wrap|transform.
--- @param options table Initial ownership fault controls.
--- @param callback function Receives the real action and boundary observations.
function M.run(kind, options, callback)
	helpers.with_stub_scope({
		"modules.shortcuts.actions.text", "modules.shortcuts.actions.text_continuation",
		"modules.shortcuts.actions.text_dispatch", "modules.shortcuts.actions.text_transform_grace",
		"unicode_case", "unicode_case.data", "infra.capsword_output",
	}, function()
		with_sender(function(f)
			local board = f.hs_overrides.pasteboard
			local native_read, native_write = board.readAllData, board.setContents
			local native_clear, native_count = board.clearContents, board.changeCount
			if options.empty or options.nil_snapshot then native_clear() end
			local state = { kind = kind, fixture = f, writes = 0, clears = 0, copies = 0,
				count_reads = 0, initial = f.clipboard(), initial_count = f.change_count,
				faults_open = true }
			package.loaded["infra.paths"] = { shared = function() return nil end }
			package.loaded["infra.timings"] = { sec = function() return 0.01 end }
			board.getContents = function() return f.clipboard()["public.utf8-plain-text"] end
			hs.pasteboard.getContents = board.getContents
			state.text = require("modules.shortcuts.actions.text")
			local scheduler = require("adapters.timer_scheduler")
			local native_after = scheduler.after
			local function external_copy(boundary)
				if not state.faults_open or options.copy_at ~= boundary or state.copies > 0 then return end
				state.copies = state.copies + 1
				assert(native_write(options.identical and "USER CLIPBOARD" or "NEWER FOREIGN COPY") == true)
				state.foreign, state.foreign_count = f.clipboard(), f.change_count
			end
			board.readAllData = function()
				local snapshot = native_read()
				external_copy("snapshot")
				if options.nil_snapshot then return nil end
				return snapshot
			end
			board.getContents = function()
				local plain = f.clipboard()["public.utf8-plain-text"]
				external_copy("plain")
				return plain
			end
			board.changeCount = function()
				state.count_reads = state.count_reads + 1
				if state.faults_open and state.count_reads == options.pause_on_count then
					state.pause_attempted = true
					state.pause_result = state.text.pause_text_actions()
				end
				if state.faults_open and state.count_reads == options.refuse_count_at then
					if options.count_refusal == "throw" then error("controlled initial clipboard count refusal") end
					return nil
				end
				return native_count()
			end
			board.setContents = function(value)
				state.writes = state.writes + 1
				return native_write(value)
			end
			board.clearContents = function()
				state.clears = state.clears + 1
				return native_clear()
			end
			hs.pasteboard.readAllData, hs.pasteboard.getContents = board.readAllData, board.getContents
			hs.pasteboard.changeCount = board.changeCount
			hs.pasteboard.setContents, hs.pasteboard.clearContents = board.setContents, board.clearContents
			scheduler.after = function(...)
				local result = table.pack(native_after(...))
				external_copy("timer")
				return table.unpack(result, 1, result.n)
			end
			function state.start()
				if kind == "plain" then return state.text.paste_as_plain_text() end
				if kind == "wrap" then return state.text.wrap_selection("hello", "(", ")") end
				assert(kind == "transform")
				return state.text.toggle_uppercase()
			end
			function state.stage()
				for index, timer in ipairs(f.timers) do
					if not timer.stopped and timer.delay > f.synthetic.PERIODIC_OWNER_TICK_SEC
						and timer.delay <= 0.01 + 1e-9 then
						table.remove(f.timers, index)
						f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
						timer.callback()
						return true
					end
				end
				return false
			end
			function state.emitted()
				local total = f.key_posts
				for _, delivery in ipairs(f.pump_deliveries) do total = total + #(delivery.events or {}) end
				return total
			end
			function state.finish()
				if kind == "transform" then
					f.finish_broker()
					assert(native_write("hello") == true)
					assert(state.stage())
					assert(f.clipboard()["public.utf8-plain-text"] == "HELLO")
					assert(state.stage())
					f.finish_broker()
					assert(state.stage())
					f.finish_broker()
					assert(state.stage())
				elseif kind == "plain" then
					assert(state.stage()); f.finish_broker(); assert(state.stage())
				else
					f.finish_broker(); assert(state.stage())
				end
			end
			function state.assert_refused()
				f.finish_broker()
				helpers.assert_eq(state.writes, 0, "refusal precedes the first owned write")
				helpers.assert_eq(state.clears, 0, "refusal precedes the first owned clear")
				helpers.assert_eq(f.restore_calls, 0, "unmutated snapshots never authorize restoration")
				helpers.assert_eq(state.emitted(), 0, "a refused initial owner never emits a key")
				helpers.assert_eq(state.text.has_pending_text_action(), false, "initial owner retires completely")
				for _, timer in ipairs(f.timers) do helpers.assert_eq(timer.stopped, true) end
				helpers.assert_true(table.concat(f.logs, "\n"):find("error:", 1, true) ~= nil,
					"initial clipboard refusal must be diagnosed")
			end
			local ok, detail = xpcall(function() callback(state) end, debug.traceback)
			state.faults_open = false
			local cleanup_ok, cleanup_detail = pcall(function()
				for _ = 1, 64 do
					local settled = state.text.pause_text_actions()
					if settled and not state.text.has_pending_text_action() then return end
					f.finish_broker()
					state.stage()
				end
				error("Initial clipboard fixture cleanup retained an unsettled owner")
			end)
			if not ok then error(detail, 0) end
			if not cleanup_ok then error(cleanup_detail, 0) end
		end)
	end)
end

return M
