--- tests/unit/ui/editors/lifecycle/test_physical_shortcuts_pending_diagnostic.lua

--- ==============================================================================
--- MODULE: Physical Shortcuts Pending Fade Diagnostics
--- DESCRIPTION:
--- Composes the real host and factory with the pinned public WebView close model.
--- Public delete always forwards a delay to the native method, so even zero-delay
--- visible deletion retains a fade completion that still needs the native udRef.
--- No Cocoa crash or native GUI execution is claimed by these portable cases.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

local function with_host(scenario)
	helpers.with_stub_scope({ "ui.physical_shortcuts", "shortcuts.physical_editor_window",
		"shortcuts.physical_slots", "shortcuts.physical_availability", "ui.ui_builder", "ui.webview_close_owner",
		"infra.logger", "infra.paths", "infra.i18n", "webview.i18n_seed", "adapters.file_system",
		"window_titles", "json", "adapters.json_codec", "infra.deferred_work", "adapters.timer_scheduler",
		"infra.locale", "locale.core", "webview.presentation", "tests.support.webview_recursive_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, errors = {}, notification_depth = 0,
			bridges = {}, script_refs = {}, retired = 0, received = 0, logs = {}, timers = {}, timer_attempts = 0, retirement_callbacks = {} }
		local make = require("tests.support.webview_recursive_close_fixture")(h)
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...)
			h.logs[#h.logs + 1] = string.format(format, ...)
			if h.on_error then h.on_error() end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = { shared = function(path) return path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["webview.i18n_seed"] = {}
		package.loaded["adapters.file_system"] = { read = function() return "{}" end }
		package.loaded["window_titles"] = { compose = function(key) return key end }
		package.loaded["json"] = { encode = function() return "{}" end }
		package.loaded["shortcuts.physical_slots"] = { new = function() return { candidates = function() return {} end } end }
		package.loaded["shortcuts.physical_editor_window"] = { new = function(options)
			return { retire = function()
				h.retired = h.retired + 1
				if h.on_retire then h.on_retire() end
				return h.retire_refuses ~= true
			end, receive = function()
				if options.page_current() then h.received = h.received + 1; return true end
				return false
			end }
		end }
		local function native_timer(delay, receive)
			h.timer_attempts = h.timer_attempts + 1
			if h.timer_construct_refuses == "throw" then error("native timer allocation refused") end
			if h.timer_construct_refuses then return nil end
			local entry = { delay = delay, receive = receive, running = false }
			local timer = {}
			function timer:start()
				entry.running = true
				if h.timer_start_inline then receive() end
				if h.timer_start_refuses then return false end
				return self
			end
			function timer:stop()
				if h.timer_stop_refuses then return false end
				entry.running = false
				return self
			end
			function timer:running() return entry.running end
			h.timers[#h.timers + 1] = entry
			return timer
		end
		local host = helpers.load_with_stubs("ui.physical_shortcuts", {
			json = { decode = function() return {} end }, focus = function() end,
			timer = { new = native_timer },
			webview = { windowMasks = { titled = 1, closable = 2, resizable = 8 }, new = function()
				local view = make()
				function view:evaluateJavaScript() return self end
				function view:hswindow()
					local window = {}
					for _, name in ipairs({ "moveToScreen", "unminimize", "raise", "focus" }) do
						window[name] = function(self) return self end
					end
					return window
				end
				return view
			end, usercontent = { new = function()
				local bridge = {}
				function bridge:setCallback(callback)
					if callback == nil and h.detach_refuses then return false end
					h.script_refs[self] = callback
					return self
				end
				h.bridges[#h.bridges + 1] = bridge
				return bridge
			end } },
		})
		local scheduler = package.loaded["adapters.timer_scheduler"]
		local after = scheduler.after
		scheduler.after = function(delay, callback)
			h.retirement_callbacks[#h.retirement_callbacks + 1] = callback
			return after(delay, callback)
		end
		local builder = package.loaded["ui.ui_builder"]
		builder.get_app_geometry = function() return { width = 700, height = 600 } end
		builder.get_centered_frame = function() return {} end
		builder.build_injected_html = function() return "<html></html>" end
		local options = { scope = { physical_delivery_available = function() return true end,
			capture_editor_inventory = function() end, editor_source_current = function() end, edit = function() end }, gestures = {} }
		function h.open() return host.open(options) end
		function h.tick()
			for _, entry in ipairs(h.timers) do
				if entry.running then entry.receive(); return true end
			end
			return false
		end
		function h.drain()
			for _ = 1, 24 do
				if #h.deferred > 0 then table.remove(h.deferred, 1)()
				elseif not h.tick() then return end
			end
			error("native fade or retained timer did not settle")
		end
		scenario(host, h)
	end)
end

helpers.describe("physical shortcut pending deletion is not an error", function()
	helpers.it("keeps an accepted visible public fade nonterminal without reporting ERROR", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(#h.logs, 0, "accepted nil result is pending, not a product error")
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(h.open(), false, "pending fade must still block successor admission")
			helpers.assert_eq(#h.logs, 0)
			h.drain()
			helpers.assert_nil(next(h.script_refs))
			helpers.assert_eq(#h.logs, 0, "healthy autonomous retirement must not trigger ErrorDialog")
			helpers.assert_true(h.open())
			helpers.assert_eq(host.close(), false)
			h.drain()
			helpers.assert_eq(#h.logs, 0)
		end)
	end)
	helpers.it("keeps the healthy native user close free from ERROR", function()
		with_host(function(_, h)
			helpers.assert_true(h.open())
			h.windows[1]:user_close()
			h.drain()
			helpers.assert_eq(#h.logs, 0)
			helpers.assert_nil(next(h.script_refs))
		end)
	end)
	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("keeps native delete " .. refusal .. " diagnostic and ownership", function()
			with_host(function(host, h)
				helpers.assert_true(h.open())
				local view = h.windows[1]
				h.delete_refuses = refusal
				helpers.assert_eq(host.close(), false)
				helpers.assert_true(#h.logs > 0, "uncertain request is not a nil acknowledgement")
				helpers.assert_true(getmetatable(view) ~= nil)
				helpers.assert_eq(h.open(), false)
				helpers.assert_eq(view.native.deletes, 1)
				setmetatable(view, nil) -- independent native retirement, not an invented delete retry
				h.delete_refuses = nil
				helpers.assert_true(host.close())
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end
	for _, boundary in ipairs({ "bridge", "timer", "business" }) do
		helpers.it("keeps " .. boundary .. " retirement refusal diagnostic", function()
			with_host(function(host, h)
				helpers.assert_true(h.open())
				if boundary == "bridge" then h.detach_refuses = true
				elseif boundary == "timer" then h.timer_construct_refuses = true
				else h.retire_refuses = true end
				helpers.assert_eq(host.close(), false)
				h.drain()
				helpers.assert_true(#h.logs > 0, "real retirement refusal must remain ERROR")
				h.detach_refuses, h.timer_construct_refuses, h.retire_refuses = nil, nil, nil
				host.close()
				h.drain()
				helpers.assert_true(host.close())
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end
end)
