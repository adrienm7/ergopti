--- tests/support/keymap/multi_paste_fifo_fixture.lua

--- ==============================================================================
--- MODULE: Multi-Paste Native FIFO Fixture
--- DESCRIPTION:
--- Drives actual expansion, Terminal pacing and clipboard handoff through native ports.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")
local M = {}
local OWNED = {
	"adapters.clipboard", "adapters.event_provenance", "adapters.python_interpreter",
	"adapters.secure_field_detector", "adapters.storage", "adapters.synthetic_input",
	"adapters.text_sender", "adapters.timer_scheduler", "adapters.tooltip_renderer",
	"compat.utf8", "hotstring_engine", "hotstrings.personal_files",
	"hs", "hs.application", "hs.canvas",
	"hs.dialog", "hs.distributednotifications", "hs.eventtap",
	"hs.fnutils", "hs.fs", "hs.host",
	"hs.hotkey", "hs.http", "hs.image",
	"hs.inspect", "hs.json", "hs.keycodes",
	"hs.logger", "hs.menubar", "hs.notify",
	"hs.osascript", "hs.pasteboard", "hs.pathwatcher",
	"hs.settings", "hs.spaces", "hs.sqlite3",
	"hs.styledtext", "hs.task", "hs.timer",
	"hs.urlevent", "hs.webview", "hs.window",
	"infra.capsword_output", "infra.hotstring_engine", "infra.i18n",
	"infra.logger", "infra.paths", "infra.text_utils",
	"infra.timings", "infra.toml.reader", "json",
	"keymap.terminators", "keymap.terminators_catalogue", "keymap.utils",
	"logger.shim", "modules.keylogger", "modules.keymap.expander",
	"modules.keymap.state", "modules.keymap.terminator_replay", "modules.keymap.terminators",
	"modules.keymap.utils", "tests.stubs.hs", "text_utils",
	"toml_codec.basic_string", "toml_codec.bom", "toml_codec.key_path",
	"toml_codec.reader", "toml_codec.record_scanner",
}

--- Runs one exact expansion world and restores all owned modules and native globals.
--- @param options table Native target and deletion options.
--- @param scenario function Receives the actual expansion driver.
function M.with_world(options, scenario)
	local previous_lfs = rawget(_G, "lfs")
	_G.lfs = nil
	local ok, err = xpcall(function()
		helpers.with_stub_scope(OWNED, function()
			local f = Fixture.make({ absolute_time = 0, epoch = 1900000000 })
			local synthetic = f.load()
			local target = {
				pid = function() return 222 end,
				isRunning = function() return true end,
				bundleID = function() return options.terminal and "com.apple.Terminal" or "com.apple.TextEdit" end,
				name = function() return options.terminal and "Terminal" or "TextEdit" end,
			}
			f.frontmost_app = target
			f.live_applications = { [222] = target }
			hs.window.focusedWindow = function() return { application = function() return target end } end
			local original = { ["public.utf8-plain-text"] = "ORIGINAL", ["public.html"] = "<b>ORIGINAL</b>" }
			local w = { native = f, synthetic = synthetic, now = 0, board = original,
				original = original, generation = 0, restores = 0, writes = {}, pastes = {}, keys = {} }
			hs.pasteboard = {
				readAllData = function() return w.board end,
				writeAllData = function(saved)
					w.board = saved; w.generation = w.generation + 1; w.restores = w.restores + 1
					return true
				end,
				clearContents = function() w.board = {}; w.generation = w.generation + 1 end,
				setContents = function(value)
					w.board = { ["public.utf8-plain-text"] = value }; w.generation = w.generation + 1
					w.writes[#w.writes + 1] = { at = w.now, value = value }
					return true
				end,
				changeCount = function() return w.generation end,
			}
			local function observe(event)
				if not event.isDown then return end
				w.keys[#w.keys + 1] = event.key
				if w.on_key then w.on_key(event) end
				if event.key == "v" and table.concat(event.modifiers or {}, "+") == "cmd" then
					w.pastes[#w.pastes + 1] = { at = w.now, value = w.board["public.utf8-plain-text"] }
				end
			end
			f.key_observer = observe
			package.loaded["modules.keylogger"] = {}
			local utils = require("modules.keymap.utils")
			local sender = require("adapters.text_sender")
			helpers.assert_eq(sender.terminalInputTarget() ~= nil, options.terminal == true)
			local expander = require("modules.keymap.expander")
			local scheduler = require("adapters.timer_scheduler")
			local state = { buffer = "abcdefghijkl", magic_key = "star" }
			helpers.assert_true(expander.init(state, {}, { get_llm_enabled = function() return false end }))
			function w.start(replacement)
				f.callback_active = true
				synthetic.enter_callback()
				local accepted, tx = expander.perform_text_replacement(options.deletes or 12, function()
					return utils.emit_tokens(utils.tokens_from_repl(replacement))
				end, function() state.buffer = replacement end, false, true, "hotstring", "unit.multi-paste")
				local consume, returned = synthetic.leave_callback(accepted)
				f.callback_active = false
				helpers.assert_true(accepted and consume)
				for _, event in ipairs(returned or {}) do observe(event) end
				w.tx = tx
				return tx
			end
			function w.standalone(replacement)
				return utils.emit_tokens(utils.tokens_from_repl(replacement))
			end
			local applied = 0
			function w.advance(until_time)
				for _ = 1, 2000 do
					local index, deadline
					for i, timer in ipairs(f.timers) do
						if not timer.stopped then
							timer.due = timer.due or (w.now + timer.delay)
							if not deadline or timer.due < deadline then index, deadline = i, timer.due end
						end
					end
					if not index or deadline > until_time then return end
					local timer = table.remove(f.timers, index)
					w.now = deadline
					f.options.absolute_time = math.floor(w.now * 1e9)
					f.options.epoch = 1900000000 + w.now
					timer.callback()
					if timer.recurring and not timer.stopped then
						timer.due = w.now + timer.delay
						f.timers[#f.timers + 1] = timer
					end
					while applied < #f.pump_deliveries do
						applied = applied + 1
						for _, event in ipairs(f.pump_deliveries[applied].events or {}) do observe(event) end
					end
				end
				error("bounded actual timer drain exhausted")
			end
			function w.assert_retired()
				local stats = synthetic.stats()
				helpers.assert_eq(stats.pending, 0)
				helpers.assert_eq(stats.active_transactions, 0)
				helpers.assert_eq(scheduler.activeCount(), 0)
				helpers.assert_true(rawequal(w.board, original))
				helpers.assert_eq(w.restores, 1)
			end
			scenario(w)
		end)
	end, debug.traceback)
	_G.lfs = previous_lfs
	if not ok then error(err, 0) end
end

return M
