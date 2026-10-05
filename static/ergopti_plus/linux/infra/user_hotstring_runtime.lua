--- infra/user_hotstring_runtime.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Runtime (Linux)
--- DESCRIPTION:
--- Owns exact input receipts around the daemon matcher, privacy guards and native
--- focused accessible. Unknown focus identity cannot authorize user callbacks.
--- ==============================================================================
local M = {}
local Destination = require("adapters.user_hotstring_destination")
local Engine = require("modules.hotstrings.engine")
local Utf8 = require("compat.utf8")
local Monotonic = require("infra.monotonic")

--- Creates native ports around the daemon's existing matcher and privacy owners.
--- @param options table Daemon engine, injector, magic, focus, capture and control owners.
--- @return table native
function M.new(options)
	local engine, injector = options.engine, options.injector
	local input_epoch = {}
	local native = {}

	--- Advances before any physical character, control, pointer or pause boundary.
	function native.observe_input() input_epoch = {} end

	--- Captures source text and its native cursor before scheduling user code.
	--- @param rule table Admitted source descriptor.
	--- @param seconds number Canonical activation interval.
	--- @return table|nil capture
	function native.capture(rule, seconds)
		local destination = Destination.capture()
		if not destination then return nil end
		local buffer, magic = engine:current_buffer(), options.magic.get()
		if buffer:sub(-(#rule.suffix + #magic)) ~= rule.suffix .. magic then return nil end
		local count = Utf8.len(rule.suffix) + 1
		local timing = engine:tail_timing_receipt(count)
		if not Engine.within_interkey_delay(timing, seconds, Monotonic.resolution_ms()) then return nil end
		return { destination = destination, input = input_epoch, buffer = buffer,
			magic = magic, focus_epoch = options.detector.currentEpoch() }
	end

	--- Rechecks real focus and existing daemon controls before invoking or emitting.
	--- @param capture table Original native input receipt.
	--- @return boolean current
	function native.current(capture)
		if injector._is_injecting() or options.paused() or options.capture_gate.blocks_text()
			or options.focus_guard.blocks_text() or not options.dynamic.is_enabled()
			or capture.input ~= input_epoch or capture.buffer ~= engine:current_buffer()
			or capture.magic ~= options.magic.get()
			or capture.focus_epoch ~= options.detector.currentEpoch() then return false end
		local foreground = options.window_info and options.window_info.getFocused()
		if not foreground or foreground.appId == "" or options.keylogger.is_password_app(foreground.appId)
			or options.keylogger.is_private_window(foreground.windowTitle) then return false end
		return Destination.current(capture.destination) == true
	end

	--- Checks publication after its own injection has changed the matcher buffer.
	--- @param capture table Original physical input and native destination owner.
	--- @return boolean current
	function native.publication_cached(capture)
		return not options.paused() and not options.capture_gate.blocks_text()
			and not options.focus_guard.blocks_text() and options.dynamic.is_enabled() == true
			and capture.input == input_epoch and capture.magic == options.magic.get()
			and capture.focus_epoch == options.detector.currentEpoch()
	end

	--- Re-proves native focus off the hook for each output phase.
	--- @param capture table Original physical input and native destination owner.
	--- @return boolean current
	function native.publication_current(capture)
		if native.publication_cached(capture) ~= true then return false end
		local foreground = options.window_info and options.window_info.getFocused()
		if not foreground or foreground.appId == "" or options.keylogger.is_password_app(foreground.appId)
			or options.keylogger.is_private_window(foreground.windowTitle) then return false end
		return Destination.current(capture.destination) == true and native.publication_cached(capture) == true
	end

	--- Commits only driver-owned output; acknowledged actions add no text mutation.
	--- @param result string|boolean Replacement, action acknowledgement or cancellation.
	--- @param capture table Captured cursor owner.
--- @param rule table Original source descriptor.
	--- @param admit function Full retained source/generation/destination guard.
--- @return boolean committed
	function native.commit(result, capture, rule, admit, publication)
		if type(admit) ~= "function" or admit() ~= true then return false end
		if result == false then return true end
		if result == true then engine:reset(); return true end
		injector._begin_injection()
		local delivered, delivery = pcall(injector.inject, Utf8.len(rule.suffix) + 1, result, true, nil, publication)
		local queued = injector._end_injection()
		engine:reset()
		if not delivered or type(delivery) ~= "table" or delivery.ok ~= true then return false end
		-- Queue ownership ends before replay, and the replacement cannot chain
		-- into physical characters that arrived while its output was in flight.
		return options.replay_input(queued) == true
	end
	return native
end

return M
