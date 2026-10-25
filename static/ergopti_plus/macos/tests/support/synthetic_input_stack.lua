--- tests/support/synthetic_input_stack.lua

--- ==============================================================================
--- MODULE: Synthetic Input Stack Test Support
--- DESCRIPTION:
--- Reloads the real modules that capture one Hammerspoon stub and one synthetic
--- ledger at require-time. Tests that exercise exact Quartz provenance use this
--- helper so every scenario has a coherent producer, timer, and event-tap stack.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

local CAPTURED_STACK = {
	"modules.keymap.utils",
	"modules.keymap.terminator_replay",
	"adapters.text_sender",
	"adapters.clipboard",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
}


--- Loads a subject and the real SyntheticInput adapter under the same fresh hs.
--- Deliberately does not clear optional collaborators such as modules.keystats:
--- callers may have installed a dependency double before reaching this seam.
--- @param module_name string Subject module name.
--- @param hs_overrides table|nil Optional Hammerspoon stub overrides.
--- @return table subject
--- @return table synthetic_input
function M.load(module_name, hs_overrides)
	for _, name in ipairs(CAPTURED_STACK) do
		package.loaded[name] = nil
	end
	local subject = helpers.load_with_stubs(module_name, hs_overrides)
	return subject, require("adapters.synthetic_input")
end


--- Couples manual timer delivery to its native monotonic deadline.
--- Parallel timers share elapsed time, and each start replaces its own deadline.
--- @param hs_stub table Fresh Hammerspoon stub owned by one fixture.
--- @return table clock Fixture-owned monotonic clock and deadline reader.
function M.install_timer_clock(hs_stub)
	local timer = hs_stub.timer
	assert(timer.__native_test_clock == nil, "fixture timer clock is already installed")
	local now = 0
	local deadlines, tracked = {}, {}
	local clock = {}
	function clock.now() return now end
	function clock.next_deadline(handle)
		if handle.running ~= true then return nil end
		return assert(deadlines[handle], "a running fixture timer must own its deadline")
	end
	local function track(handle)
		if tracked[handle] then return end
		tracked[handle] = true
		assert(type(handle.delay) == "number", "fixture timer delay must be declared")
		if handle.running == true then deadlines[handle] = now + handle.delay end
		local native_start, native_fire = handle.start, handle.fire
		handle.start = function(self, ...)
			local results = table.pack(native_start(self, ...))
			if self.running == true then deadlines[self] = now + self.delay end
			return table.unpack(results, 1, results.n)
		end
		handle.fire = function(self, ...)
			if self.running ~= true then return native_fire(self, ...) end
			now = math.max(now, (assert(deadlines[self], "fixture delivery has no native deadline")))
			deadlines[self] = nil
			local results = table.pack(native_fire(self, ...))
			if self.running ~= true then deadlines[self] = nil
			elseif deadlines[self] == nil then deadlines[self] = now + self.delay end
			return table.unpack(results, 1, results.n)
		end
	end
	local function wrap_constructor(owner, key)
		local native = owner[key]
		owner[key] = function(...)
			local before = #timer.__timers
			local results = table.pack(native(...))
			local entries = {}
			for index = before + 1, #timer.__timers do
				local entry = timer.__timers[index]
				track(entry)
				entries[#entries + 1] = entry
			end
			local handle = results[1]
			if type(handle) == "table" and not tracked[handle] and type(handle.start) == "function" then
				-- Delayed timers expose a separate handle that rearms their native entry.
				local native_start = handle.start
				handle.start = function(self, ...)
					local started = table.pack(native_start(self, ...))
					for _, entry in ipairs(entries) do
						if entry.running == true then deadlines[entry] = now + entry.delay end
					end
					return table.unpack(started, 1, started.n)
				end
			end
			return table.unpack(results, 1, results.n)
		end
	end
	for _, entry in ipairs(timer.__timers) do track(entry) end
	for _, key in ipairs({ "new", "doAfter", "doEvery" }) do wrap_constructor(timer, key) end
	wrap_constructor(timer.delayed, "new")
	timer.absoluteTime = function() return math.floor(now * 1e9) end
	timer.__native_test_clock = clock
	return clock
end

return M
