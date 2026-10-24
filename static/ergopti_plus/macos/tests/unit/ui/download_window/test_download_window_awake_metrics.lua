--- tests/unit/ui/download_window/test_download_window_awake_metrics.lua

--- The real progress host must not spend a civil-clock correction as download
--- time. Native page submissions are recorded; no download or Cocoa is run.
local helpers = require("tests.helpers")

local OWNED = {
	"ui.download_window", "ui.download_window.javascript",
	"ui.download_window.pending_queue", "adapters.webview_result",
	"infra.deferred_work", "adapters.timer_scheduler", "error_description", "number_policy",
	"infra.logger", "infra.paths", "infra.i18n", "infra.text_utils",
	"adapters.shell_runner", "adapters.own_window", "ui.ui_builder",
}

--- Composes real presentation/queue/scheduler owners over independent clocks.
--- The factory is a rendering/focus port, not native window delivery proof.
local function with_window(scenario)
	return helpers.with_stub_scope(OWNED, function()
		local w = { awake = 0, wall = 1000000, codes = {}, timers = {},
			bridges = {}, errors = {}, creates = 0, deletes = 0 }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...)
			w.errors[#w.errors + 1] = string.format(format, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = { shared = function() return "/virtual/download-assets" end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.text_utils"] = {}
		package.loaded["adapters.shell_runner"] = {}
		package.loaded["adapters.own_window"] = {}
		_G.hs = {
			timer = {
				absoluteTime = function() return w.awake * 1e9 end,
				secondsSinceEpoch = function() return w.wall end,
				new = function(delay, callback)
					local timer = { active = false, delay = delay }
					function timer:start() self.active = true; return self end
					function timer:stop() self.active = false; return self end
					function timer:running() return self.active end
					function timer:deliver() if self.active then callback() end end
					function timer:deliver_retained_native_callback() callback() end
					w.timers[#w.timers + 1] = timer
					return timer
				end,
			},
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1200, h = 900 } end }
			end },
			webview = { usercontent = { new = function()
				local bridge = {}
				function bridge:setCallback(callback) self.callback = callback; return self end
				w.bridges[#w.bridges + 1] = bridge
				return bridge
			end } },
		}
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 460, height = 380 } end,
			show_webview = function(options)
				w.creates = w.creates + 1
				local view = {}
				function view:evaluateJavaScript(code)
					w.codes[#w.codes + 1] = code
					return self
				end
				function view:delete() w.deletes = w.deletes + 1; return self end
				w.options = options
				helpers.assert_eq(options.on_webview_created(view), true)
				return view
			end,
		}
		local window = require("ui.download_window")
		local scheduler = require("adapters.timer_scheduler")
		function w.sample(awake, step)
			helpers.assert_true(awake >= w.awake, "the independent awake clock never regresses")
			w.awake, w.wall = awake, 1000000 + awake + (step or 0)
		end
		function w.show()
			helpers.assert_eq(window.show({ kind = "mlx_model", model = "fixture/model",
				terminal_cmd = "tail -f '/virtual/download.log'" }), true)
		end
		function w.ready() w.options.on_navigation("didFinishNavigation") end
		function w.last_update()
			local result
			for _, code in ipairs(w.codes) do if code:match("^update%(") then result = code end end
			return result
		end
		local outcome = table.pack(xpcall(scenario, debug.traceback, window, w))
		local cleanup = table.pack(xpcall(function()
			helpers.assert_eq(window.hide(), true, "real window owner releases its bridge and view")
			scheduler.cancelAll()
			helpers.assert_eq(scheduler.activeCount(), 0, "real deferred timer registry is empty")
			for _, timer in ipairs(w.timers) do helpers.assert_eq(timer.active, false) end
			for _, bridge in ipairs(w.bridges) do helpers.assert_eq(bridge.callback, nil) end
		end, debug.traceback))
		local failures = {}
		if not outcome[1] then failures[#failures + 1] = tostring(outcome[2]) end
		if not cleanup[1] then failures[#failures + 1] = "CLEANUP: " .. tostring(cleanup[2]) end
		for _, message in ipairs(w.errors) do failures[#failures + 1] = "CALLBACK LOG: " .. message end
		if #failures > 0 then error(table.concat(failures, "\n"), 0) end
	end)
end

helpers.describe("download progress uses the active operation awake duration", function()
	helpers.it("keeps speed and ETA hidden at the exact two-second warmup boundary", function()
		with_window(function(window, w)
			w.show(); w.ready(); w.sample(2)
			window.update(33, 4000000, 12000000)
			helpers.assert_eq(w.last_update(), 'update(33,"4 Mo / 12 Mo",null,null,null)')
		end)
	end)

	helpers.it("publishes normal byte speed and ETA immediately after the warmup", function()
		with_window(function(window, w)
			w.show(); w.ready(); w.sample(2.5)
			window.update(33, 5000000, 15000000)
			helpers.assert_eq(w.last_update(), 'update(33,"5 Mo / 15 Mo","2 Mo/s","5s",null)')
		end)
	end)

	helpers.it("keeps current download speed and ETA after a civil rollback", function()
		with_window(function(window, w)
			w.show(); w.ready(); w.sample(10, -60)
			window.update(33, 20000000, 60000000)
			helpers.assert_eq(w.last_update(), 'update(33,"20 Mo / 60 Mo","2 Mo/s","20s",null)',
				"civil rollback must not remove speed and ETA from valid progress")
		end)
	end)

	helpers.it("does not count a civil advance as elapsed download time", function()
		with_window(function(window, w)
			w.show(); w.ready(); w.sample(10, 60)
			window.update(33, 20000000, 60000000)
			helpers.assert_eq(w.last_update(), 'update(33,"20 Mo / 60 Mo","2 Mo/s","20s",null)',
				"civil advance must not inflate ETA or reduce byte speed")
		end)
	end)

	helpers.it("starts a fresh warmup and duration when the native window is reused", function()
		with_window(function(window, w)
			w.show(); w.ready(); w.sample(100)
			local first_session = window.session_id()
			w.show()
			helpers.assert_eq(w.creates, 1, "the second occupant uses the same native window")
			helpers.assert_eq(window.session_id(), first_session + 1)
			window.update(33, 4000000, 12000000)
			helpers.assert_eq(w.last_update(), 'update(33,"4 Mo / 12 Mo",null,null,null)')
			w.sample(102.5)
			window.update(33, 5000000, 15000000)
			helpers.assert_eq(w.last_update(), 'update(33,"5 Mo / 15 Mo","2 Mo/s","5s",null)')
		end)
	end)

	helpers.it("does not publish queued metrics from a retired readiness timer", function()
		with_window(function(window, w)
			w.show(); w.sample(2.5)
			window.update(33, 5000000, 15000000)
			helpers.assert_eq(#w.codes, 0, "progress waits for the actual page readiness callback")
			helpers.assert_eq(window.hide(), true)
			for _, timer in ipairs(w.timers) do timer:deliver_retained_native_callback() end
			w.ready()
			window.update(33, 5000000, 15000000)
			helpers.assert_eq(#w.codes, 0, "retired timer/navigation cannot publish queued progress")
		end)
	end)
end)
