--- tests/unit/infra/test_app_picker_presentation_handoff.lua

--- ==============================================================================
--- MODULE: Application Picker Native Presentation Handoff
--- DESCRIPTION:
--- Models willOpen before native focus and keeps reentrant presentations bounded.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

local function with_native_show(run)
	with_picker(function(picker, state)
		local original_new = _G.hs.chooser.new
		_G.hs.chooser.new = function(callback)
			local chooser = original_new(callback)
			function chooser:show()
				state.show_depth = (state.show_depth or 0) + 1
				state.max_depth = math.max(state.max_depth or 0, state.show_depth)
				if state.will_open then state.will_open(self) end
				state.show_depth = state.show_depth - 1
				if state.throw_show == self then error("injected native presentation failure") end
				local previous = state.focused
				state.focused = self
				self.shown = self.shown + 1
				if previous and previous ~= self then previous.callback(nil) end
				return self
			end
			return chooser
		end
		local function action(on_change)
			return picker.build_menu({}, on_change or function() end)[1].action
		end
		local function finish_scan()
			state.pending[1].callback(0, "/Applications/Editor.app\0")
		end
		local function tick()
			local callback = table.remove(state.deferred, 1)
			helpers.assert_type(callback, "function", "a handoff must be scheduled")
			callback()
		end
		run(state, action, finish_scan, tick)
	end)
end

helpers.describe("app_picker: native presentation handoff", function()
	helpers.it("keeps the successor usable after willOpen reentry", function()
		with_native_show(function(state, action, finish_scan, tick)
			local changes = 0
			local successor = action(function() changes = changes + 1 end)
			state.will_open = function() state.will_open = nil; successor() end
			action()(); finish_scan()
			helpers.assert_eq(#state.choosers, 1, "successor must wait for the native stack to unwind")
			tick()
			helpers.assert_eq(state.max_depth, 1)
			helpers.assert_true(state.focused == state.choosers[2])
			state.choosers[2].callback({ text = "Editor", appPath = "/Applications/Editor.app" })
			helpers.assert_eq(changes, 1)
		end)
	end)

	helpers.it("coalesces B then C while A is presenting", function()
		with_native_show(function(state, action, finish_scan, tick)
			local applied = {}
			local b = action(function() applied[#applied + 1] = "B" end)
			local c = action(function() applied[#applied + 1] = "C" end)
			state.will_open = function() state.will_open = nil; b(); c() end
			action()(); finish_scan()
			helpers.assert_eq(#state.deferred, 1)
			tick()
			helpers.assert_eq(#state.choosers, 2)
			state.choosers[2].callback({ text = "Editor", appPath = "/Applications/Editor.app" })
			helpers.assert_eq(applied, { "C" })
		end)
	end)

	helpers.it("releases presentation ownership after a native show exception", function()
		with_native_show(function(state, action, finish_scan, tick)
			local successor = action()
			state.will_open = function(chooser)
				state.will_open = nil; state.throw_show = chooser; successor()
			end
			action()(); finish_scan(); tick()
			helpers.assert_true(state.focused == state.choosers[2])
			helpers.assert_eq(state.choosers[1].deleted, 1)
		end)
	end)

	helpers.it("replaces queued B with ready C after A returns but before timer delivery", function()
		with_native_show(function(state, action, finish_scan, tick)
			local applied = {}
			local b = action(function() applied[#applied + 1] = "B" end)
			local c = action(function() applied[#applied + 1] = "C" end)
			state.will_open = function() state.will_open = nil; b() end
			action()(); finish_scan()
			c()
			helpers.assert_eq(#state.choosers, 1)
			helpers.assert_eq(#state.deferred, 1, "the latest result must reuse the existing handoff")
			tick()
			helpers.assert_eq(#state.choosers, 2)
			helpers.assert_eq(#state.deferred, 0)
			state.choosers[2].callback({ text = "Editor", appPath = "/Applications/Editor.app" })
			helpers.assert_eq(applied, { "C" })
		end)
	end)

	helpers.it("does not let an obsolete scan replace the queued latest request", function()
		with_native_show(function(state, action, _, tick)
			local applied = {}
			local latest = action(function() applied[#applied + 1] = "latest" end)
			action(function() applied[#applied + 1] = "obsolete" end)()
			state.will_open = function() state.will_open = nil; latest() end
			action()()
			state.pending[2].callback(0, "/Applications/Current.app\0")
			state.pending[1].callback(0, "/Applications/Obsolete.app\0")
			tick()
			helpers.assert_eq(#state.choosers, 2)
			state.choosers[2].callback({ text = "Current", appPath = "/Applications/Current.app" })
			helpers.assert_eq(applied, { "latest" })
		end)
	end)

	helpers.it("releases the queue before propagating an unexpected cleanup diagnostic error", function()
		with_native_show(function(state, action, finish_scan, tick)
			local successor = action()
			state.will_open = function() state.will_open = nil; successor() end
			state.on_log = function(_, message)
				if message:find("cleanup completed", 1, true) then
					state.on_log = nil
					error("injected diagnostic failure")
				end
			end
			action()()
			local ok, failure = pcall(finish_scan)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(failure):find("injected diagnostic failure", 1, true) ~= nil)
			tick()
			helpers.assert_true(state.focused == state.choosers[2])
		end)
	end)

	helpers.it("refuses synchronous timer delivery instead of recursively draining presentations", function()
		with_native_show(function(state, action, finish_scan, tick)
			local successor = action()
			state.defer_synchronous = true
			state.will_open = function() state.will_open = nil; successor() end
			action()(); finish_scan()
			helpers.assert_eq(#state.choosers, 1)
			tick()
			helpers.assert_eq(#state.choosers, 1)
			state.defer_synchronous = false
			successor()
			helpers.assert_eq(#state.choosers, 2)
		end)
	end)

	helpers.it("runs at most one chained presentation per timer delivery", function()
		with_native_show(function(state, action, finish_scan, tick)
			local successor = action()
			state.will_open = function()
				if #state.choosers < 4 then successor() end
			end
			action()(); finish_scan()
			helpers.assert_eq(#state.choosers, 1)
			for count = 2, 4 do tick(); helpers.assert_eq(#state.choosers, count) end
			helpers.assert_eq(state.max_depth, 1)
			helpers.assert_eq(#state.deferred, 0)
		end)
	end)

	helpers.it("fences a refused handoff and its late callback, then permits retry", function()
		with_native_show(function(state, action, finish_scan, tick)
			local successor = action()
			state.defer_started = false
			state.will_open = function() state.will_open = nil; successor() end
			action()(); finish_scan()
			helpers.assert_eq(#state.choosers, 1)
			tick()
			helpers.assert_eq(#state.choosers, 1, "refused timer must not present later")
			local refused = false
			for _, log in ipairs(state.logs) do
				if log.level == "error" and log.text:find("handoff refused", 1, true) then refused = true end
			end
			helpers.assert_true(refused, "timer refusal must be diagnosed")
			state.defer_started = true
			successor()
			helpers.assert_eq(#state.choosers, 2)
			helpers.assert_true(state.focused == state.choosers[2])
		end)
	end)
end)
