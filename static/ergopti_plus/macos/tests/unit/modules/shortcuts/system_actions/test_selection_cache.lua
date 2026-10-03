--- tests/unit/modules/shortcuts/system_actions/test_selection_cache.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local load_system = fixture.load_system
local with_fixture = fixture.with_fixture
local as_physical = fixture.as_physical
local extend_contract = fixture.extend_contract
local fresh_hs_contract = fixture.fresh_hs_contract

helpers.describe("shortcuts.actions.system: bind_wrap_text_if_selected AX cache (shortcuts-wrap-ax-uncached regression)", function()

	-- Builds a fresh system module with hs.eventtap.new stubbed to capture the wrap
	-- callback, hs.timer.secondsSinceEpoch stubbed to a controllable fake clock, and
	-- modules.shortcuts.actions.text's read_ax_selection replaced with a call counter.
	-- @param selection string|nil What read_ax_selection returns. nil is the COMMON
	--   real-world result (nothing selected, or an app hiding AXSelectedText such as
	--   VS Code/Electron) and was the case the original spy could not express.
	local function make_sys_with_ax_spy(selection)
		if selection == nil then selection = "selected text" end
		if selection == "" then selection = nil end
		package.loaded["infra.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["modules.shortcuts.actions.text"]   = nil
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.event_provenance"] = nil

		local ax_call_count = 0
		local clock = { now = 1000 }

		-- Stub text.lua fully (system.lua only needs read_ax_selection + WRAP_PAIRS +
		-- wrap_selection for this path) so the real AX-dependent implementation is
		-- never exercised — we only care about call-count caching behaviour here.
		package.loaded["modules.shortcuts.actions.text"] = {
			WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
			read_ax_selection = function()
				ax_call_count = ax_call_count + 1
				return selection
			end,
			wrap_selection = function() return true end,
		}

		local captured = { cb = nil }
		local contract = fresh_hs_contract()
		local eventtap = extend_contract(contract.eventtap, {
			new = function(_types, cb)
				captured.cb = cb
				local tap = { enabled = false }
				function tap:start() self.enabled = true; return self end
				function tap:stop() self.enabled = false; return self end
				function tap:isEnabled() return self.enabled end
				return tap
			end,
		})
		local timer = extend_contract(contract.timer, {
			secondsSinceEpoch = function() return clock.now end,
		})
		local sys = load_system({
			eventtap = eventtap,
			timer    = timer,
		})

		sys.bind_wrap_text_if_selected(nil)
		local function invoke(event)
			return captured.cb(event)
		end
		return sys, captured, clock, function() return ax_call_count end, invoke, _G.hs
	end

	-- A fake keyDown event typing the wrap symbol "(" with no modifiers.
	local function fake_wrap_key_event()
		return as_physical({
			getFlags      = function() return {} end,
			getCharacters = function() return "(" end,
		})
	end

	helpers.it("N rapid wrap-key presses within the TTL trigger at most 1 real AX call", function()
		with_fixture(function()
			local _sys, captured, _clock, get_count, invoke = make_sys_with_ax_spy()
			helpers.assert_true(type(captured.cb) == "function", "bind_wrap_text_if_selected must register an eventtap callback")

			local REPEAT_COUNT = 10
			for _ = 1, REPEAT_COUNT do
				invoke(fake_wrap_key_event())
			end

			helpers.assert_eq(get_count(), 1,
				string.format("%d rapid wrap-key presses must trigger at most 1 real read_ax_selection() call", REPEAT_COUNT))
		end)
	end)

	helpers.it("a press after the TTL window elapses triggers a second real AX call", function()
		with_fixture(function()
			local _sys, _captured, clock, get_count, invoke = make_sys_with_ax_spy()

			invoke(fake_wrap_key_event())
			helpers.assert_eq(get_count(), 1, "first press must call read_ax_selection")

			clock.now = clock.now + 0.05  -- still within the TTL window
			invoke(fake_wrap_key_event())
			helpers.assert_eq(get_count(), 1, "a press within the TTL window must reuse the cached selection")

			clock.now = clock.now + 1.0  -- past the TTL window
			invoke(fake_wrap_key_event())
			helpers.assert_eq(get_count(), 2, "a press after the TTL window must trigger a fresh AX call")
		end)
	end)

	-- Regression: freshness was keyed on the cached VALUE
	-- (`_wrap_ax_selection_cache ~= nil`), so a nil selection was never cached and
	-- every wrap-key press re-paid both synchronous cross-process AX calls inline on
	-- the CGEventTap thread. nil is the COMMON result — nothing selected, or an app
	-- that hides AXSelectedText — so the cache was effectively inert exactly when it
	-- mattered. Same defect and same fix as infra/vscode_bridge.lua (3e403b254), whose
	-- sibling site this is. The spy above could not express it: it hardcoded a
	-- positive selection.
	helpers.it("N rapid presses with NO selection also trigger at most 1 real AX call", function()
		with_fixture(function()
			local _sys, _captured, _clock, get_count, invoke = make_sys_with_ax_spy("")

			local REPEAT_COUNT = 10
			for _ = 1, REPEAT_COUNT do
				invoke(fake_wrap_key_event())
			end

			helpers.assert_eq(get_count(), 1,
				string.format("%d rapid wrap-key presses with nothing selected must still trigger at "
					.. "most 1 real read_ax_selection() call — a negative result must be cached like "
					.. "any other, or the cache is inert in the most common case", REPEAT_COUNT))
		end)
	end)


	-- Accepted physical taps retire either AX cache state without changing this
	-- suite's dependency-free registration boundary.
	local function observe_tap(mode)
		local observed
		with_fixture(function()
			helpers.with_stub_scope({ "hs.axuielement" }, function()
				local native_text = helpers.load_with_stubs("modules.shortcuts.actions.text")
				local read_ax = native_text.read_ax_selection
				local state = {
					now = 1000, live = "selected", reads = 0, runs = 0,
					attributes = {}, attempts = {}, refuse_queue = false,
					failed_starts = 0, failed_zero_delays = 0, allow_wrap = false,
				}
				if mode == "accepted negative" then state.live = nil end
				package.loaded["hs.axuielement"] = {
					systemWideElement = function()
						return { attributeValue = function(_, name)
							state.attributes[#state.attributes + 1] = name
							return { attributeValue = function(_, attribute)
								state.attributes[#state.attributes + 1] = attribute
								return state.live
							end }
						end }
					end,
				}
				local contract = fresh_hs_contract()
				local delayed = extend_contract(contract.timer.delayed, {
					new = function(delay, callback)
						local timer = contract.timer.delayed.new(delay, callback)
						local start = timer.start
						timer.start = function(self, ...)
							if state.refuse_queue then
								state.failed_starts = state.failed_starts + 1
								return false
							end
							return start(self, ...)
						end
						return timer
					end,
				})
				local ctx = fixture.load_h01_system({
					hs_overrides = { timer = extend_contract(contract.timer, {
						secondsSinceEpoch = function() return state.now end,
						delayed = delayed,
						doAfter = function(delay, callback)
							if state.refuse_queue then
								state.failed_zero_delays = state.failed_zero_delays + 1
								return nil
							end
							return contract.timer.doAfter(delay, callback)
						end,
					}) },
					text_actions = {
						WRAP_PAIRS = native_text.WRAP_PAIRS,
						read_ax_selection = function()
							state.reads = state.reads + 1
							return read_ax()
						end,
						wrap_selection = function(text)
							state.attempts[#state.attempts + 1] = text
							return state.allow_wrap
						end,
					},
				})
				ctx.system.bind_wrap_text_if_selected(nil)
				local wrap = ctx.hs.eventtap.__taps[#ctx.hs.eventtap.__taps]
				local function wrap_key()
					return wrap.fn(fixture.physical_key_down(ctx, 25, "(", {}))
				end
				state.first_wrap = wrap_key()
				local admission = function() return mode ~= "closed admission" end
				ctx.system.bind_tap_keys(admission, function(key)
					if mode == "unassigned" or key ~= 10 then return nil end
					return function()
						state.runs = state.runs + 1
						state.live = mode == "accepted negative" and "fresh" or nil
						state.allow_wrap = true
						return true
					end
				end)
				local tap = ctx.hs.eventtap.__taps[#ctx.hs.eventtap.__taps]
				state.now = 1000.05
				state.refuse_queue = mode == "refused queue"
				local event = fixture.physical_key_down(ctx, 10, "`",
					mode == "modified" and { shift = true } or {})
				if mode == "owned" then event = fixture.owned_key_down(ctx, "`", 10, "`", {}) end
				if mode == "unreadable provenance" then event.getProperty = function() error("unreadable Quartz property") end end
				if mode == "autorepeat" then
					local get_property = event.getProperty
					event.getProperty = function(self, property)
						if property == ctx.hs.eventtap.event.properties.keyboardEventAutorepeat then return 1 end
						return get_property(self, property)
					end
				end
				state.accepted = tap.fn(event)
				state.runs_before_dispatch = state.runs
				state.reads_before_dispatch = state.reads
				state.pending_before_dispatch = ctx.synthetic.stats().pending_post_callback_actions
				state.refuse_queue = false
				if state.pending_before_dispatch > 0 then fixture.fire_post_callback_actions(ctx.hs) end
				state.now = 1000.10
				state.second_wrap = wrap_key()
				state.now = 1000.15
				state.third_wrap = wrap_key()
				state.pending_after_dispatch = ctx.synthetic.stats().pending_post_callback_actions
				observed = state
			end)
		end)
		return observed
	end

	for _, mode in ipairs({ "accepted negative", "accepted positive" }) do
		helpers.it(mode .. " tap refreshes the real AX reader inside the selection TTL", function()
			local state = observe_tap(mode)
			helpers.assert_true(state.accepted)
			helpers.assert_eq(state.first_wrap, false)
			helpers.assert_eq(state.runs_before_dispatch, 0, "accepted actions remain deferred")
			helpers.assert_eq(state.reads_before_dispatch, 1, "tap acceptance must not query AX inline")
			helpers.assert_eq(state.pending_before_dispatch, 1)
			helpers.assert_eq(state.runs, 1)
			helpers.assert_eq(state.pending_after_dispatch, 0)
			helpers.assert_eq(state.reads, 2, "accepted tap retires either cached selection state")
			helpers.assert_eq(table.concat(state.attributes, ","),
				"AXFocusedUIElement,AXSelectedText,AXFocusedUIElement,AXSelectedText")
			helpers.assert_eq(#state.attempts, 1, "retired positive selection must never be reused")
			helpers.assert_eq(state.attempts[1], mode == "accepted negative" and "fresh" or "selected")
			helpers.assert_eq(state.second_wrap, mode == "accepted negative")
			helpers.assert_eq(state.third_wrap, false, "fresh negative results retain the original TTL cache")
			helpers.assert_eq(state.failed_starts, 0)
			helpers.assert_eq(state.failed_zero_delays, 0)
		end)
	end

	for _, mode in ipairs({ "refused queue", "modified", "unassigned", "closed admission",
		"owned", "unreadable provenance", "autorepeat" }) do
		helpers.it(mode .. " tap preserves the existing AX selection cache", function()
			local state = observe_tap(mode)
			helpers.assert_eq(state.accepted, mode == "autorepeat")
			helpers.assert_eq(state.first_wrap, false)
			helpers.assert_eq(state.second_wrap, false)
			helpers.assert_eq(state.third_wrap, false)
			helpers.assert_eq(state.runs_before_dispatch, 0)
			helpers.assert_eq(state.runs, 0)
			helpers.assert_eq(state.pending_before_dispatch, 0)
			helpers.assert_eq(state.pending_after_dispatch, 0)
			helpers.assert_eq(state.reads, 1, "unaccepted tap must not retire eligible selection")
			helpers.assert_eq(table.concat(state.attributes, ","), "AXFocusedUIElement,AXSelectedText")
			helpers.assert_eq(table.concat(state.attempts, ","), "selected,selected,selected")
			helpers.assert_eq(state.failed_starts, mode == "refused queue" and 2 or 0)
			helpers.assert_eq(state.failed_zero_delays, mode == "refused queue" and 2 or 0,
				"native fallback and its deferred refusal diagnostic each attempt one timer")
		end)
	end
end)
