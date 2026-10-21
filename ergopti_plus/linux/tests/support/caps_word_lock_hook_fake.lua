--- tests/support/caps_word_lock_hook_fake.lua

--- ==============================================================================
--- MODULE: CapsWord Lock Hook Fake
--- DESCRIPTION:
--- Stands in for adapters/keyboard_hook's CapsWord lock API
--- (lock_caps_for_word, release_caps_word_lock) in manager tests, which run
--- with no captured keyboard. It records every call, keeps the emitter and
--- the loss callback the manager handed over, and can refuse the lock or end
--- the hold the way the hook does. The real hook's behaviour is proven by
--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_caps_word_lock.lua.
--- ==============================================================================

local M = {}

--- Builds a fake hook.
--- @param opts table|nil { refuse = string|nil } a refusal reason to answer.
--- @return table fake
function M.new(opts)
	opts = opts or {}
	local fake = { held = false, locks = 0, releases = 0, refuse = opts.refuse }

	--- @param emit function
	--- @param on_lost function
	--- @return boolean ok, string|nil reason
	function fake.lock_caps_for_word(emit, on_lost)
		assert(type(emit) == "function" and type(on_lost) == "function", "the manager hands an emitter and a loss callback")
		assert(not fake.held, "the manager never locks twice")
		fake.locks = fake.locks + 1
		if fake.refuse then return false, fake.refuse end
		fake.held, fake.emit, fake.on_lost = true, emit, on_lost
		return true
	end

	--- @return boolean ok
	function fake.release_caps_word_lock()
		fake.releases = fake.releases + 1
		fake.held, fake.on_lost = false, nil
		return true
	end

	--- Ends the hold as the hook does on a CapsLock press or a stop.
	--- @param reason string
	function fake.lose(reason)
		local callback = assert(fake.on_lost, "no hold to lose")
		fake.held, fake.on_lost = false, nil
		callback(reason)
	end

	return fake
end

return M
