--- tests/unit/modules/llm/test_runtime_bootstrap_budget.lua

--- ==============================================================================
--- MODULE: Registered Ollama Runtime Regression Cases
--- DESCRIPTION:
--- Preserves independent controlled receipts through the normal Linux helpers.
--- Actual filesystem/process/serve/UI acceptance remains a separate gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = {"llm.bootstrap_budget", "llm.runtime_repair", "modules.llm.runtime_source", "modules.llm.owned_timer", "modules.llm.runtime_composition", "infra.logger", "logger.shim", "infra.i18n", "llm.profile_selector", "infra.llm_bridge", "infra.manifest_reader", "infra.config_paths", "config_outdated", "toml_codec.writer", "infra.llm_preferences", "modules.llm.profiles"}
local previous = {}
for _, name in ipairs(names) do previous[name] = package.loaded[name] end
local function run_registered()
local Budget = helpers.load_module("llm.bootstrap_budget")
local function equal(actual, expected, message)
	if actual ~= expected then error((message or 'Mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end
local function case(name, body) helpers.it(name .. " (ollama-runtime-budget)", body) end

local function fixture(options)
	options = options or {}
	local world = { now = 100, cancelled = 0, closed = false, callbacks = {}, signals = {}, constructors = 0 }
	local timer = {}
	function timer:cancel()
		world.cancelled = world.cancelled + 1
		if options.close_on_cancel then world.closed = true end
		return world.closed
	end
	function timer:is_settled() return world.closed end
	function timer:on_settled(callback)
		if options.refuse_observer then return false end
		if world.closed then callback() else world.callbacks[#world.callbacks + 1] = callback end
		return true
	end
	function world.close()
		world.closed = true
		local callbacks = world.callbacks; world.callbacks = {}
		for _, callback in ipairs(callbacks) do callback() end
	end
	local owner, cap = Budget.new(1800000, {
		now_ms = function() if options.clock_throws then error('Independent clock refusal') end; return world.now end,
		after = function(duration, callback)
			world.constructors = world.constructors + 1; world.duration = duration; world.deadline = callback
			if options.constructor_throws then error('Independent unknown timer construction') end
			if options.early_expiry then callback() end
			return timer
		end,
	})
	world.owner, world.cap = owner, cap
	return world
end
case('single shared master duration and immutable capability', function()
	local w = fixture()
	equal(w.constructors, 1); equal(w.duration, 1800000); equal(w.cap.remaining_ms(), 1800000)
	local writable = pcall(function() w.cap.remaining_ms = function() return 9 end end)
	equal(writable, false); equal(next(w.cap), nil)
end)
case('later stages consume remaining original deadline', function()
	local w = fixture(); w.now = 300100
	equal(w.cap.remaining_ms(), 1500000)
	w.now = 900100; equal(w.cap.remaining_ms(), 900000); equal(w.constructors, 1)
end)
case('fresh current holds before deadline', function()
	local w = fixture(); w.now = 1800099
	equal(w.cap.current(), true); equal(w.cap.remaining_ms(), 1)
end)
case('deadline boundary revokes and signals exactly once', function()
	local w = fixture(); local signals = {}
	equal(w.cap.on_cancel(function(reason) signals[#signals + 1] = reason end), true)
	w.now = 1800100; equal(w.cap.remaining_ms(), 0); equal(w.cap.current(), false)
	equal(#signals, 1); equal(signals[1], 'bootstrap_timeout'); equal(w.cap.reason(), 'bootstrap_timeout')
	equal(w.owner:is_settled(), false)
end)
case('timeout requests retirement but false close retains debt', function()
	local w = fixture(); w.deadline()
	equal(w.cap.current(), false); equal(w.owner:is_settled(), false); equal(w.owner.cleanup_error, 'bootstrap_timer_cleanup_pending')
	w.close(); equal(w.owner:is_settled(), true); equal(w.owner.cleanup_error, nil)
end)
case('late cancel subscriber gets originating cancellation', function()
	local w = fixture(); w.owner:cancel('source_changed'); local seen = ''
	equal(w.cap.on_cancel(function(reason) seen = reason end), true); equal(seen, 'source_changed')
end)
case('cancel does not announce native settlement', function()
	local w = fixture(); local settled = 0
	w.owner:on_settled(function() settled = settled + 1 end)
	equal(w.owner:cancel(), false); equal(settled, 0)
	w.close(); equal(settled, 1); equal(w.owner:is_settled(), true)
end)
case('bootstrap timer retires before writer without losing bounded remaining clock', function()
	local w = fixture({ close_on_cancel = true })
	equal(w.owner:retire(), true); equal(w.owner:is_settled(), true); equal(w.cap.current(), true)
	w.now = 400100; equal(w.cap.remaining_ms(), 1400000)
end)
case('completion requires actual timer retirement', function()
	local w = fixture(); equal(w.owner:finish(), false); equal(w.cap.current(), true)
	w.owner:retire(); w.close(); equal(w.owner:finish(), true); equal(w.cap.current(), false); equal(w.cap.remaining_ms(), nil)
end)
case('complete ticket does not notify cancellation observers', function()
	local w = fixture({ close_on_cancel = true }); local signals = 0
	w.cap.on_cancel(function() signals = signals + 1 end)
	w.owner:retire(); w.owner:finish(); w.owner:cancel('later disable'); equal(signals, 0)
end)
case('backward monotonic clock revokes instead of extending deadline', function()
	local w = fixture(); w.now = 99
	equal(w.cap.remaining_ms(), nil); equal(w.cap.reason(), 'bootstrap_clock_invalid'); equal(w.cap.current(), false)
end)
case('noninteger clock revokes instead of rounding availability', function()
	local w = fixture(); w.now = 100.5
	equal(w.cap.current(), false); equal(w.cap.reason(), 'bootstrap_clock_invalid')
end)
case('nonfinite clock refuses', function()
	local w = fixture(); w.now = math.huge
	equal(w.cap.current(), false); equal(w.cap.remaining_ms(), nil)
end)
case('unknown constructor debt is never classified physically empty', function()
	local w = fixture({ constructor_throws = true })
	equal(w.cap.current(), false); equal(w.owner:is_settled(), false)
	equal(w.owner.acquisition_error, 'bootstrap_timer_acquisition_unknown'); equal(w.owner:cancel(), false)
end)
case('synchronous timer expiry preserves returned constructor owner', function()
	local w = fixture({ early_expiry = true })
	equal(w.cap.reason(), 'bootstrap_timeout'); equal(w.owner:is_settled(), false); equal(w.cancelled > 0, true)
	w.close(); equal(w.owner:is_settled(), true)
end)
case('refused observer does not become live bootstrap permission', function()
	local w = fixture({ refuse_observer = true })
	equal(w.cap.current(), false); equal(w.cap.reason(), 'bootstrap_timer_observer_refused'); equal(w.owner:is_settled(), false)
	w.close(); equal(w.owner:retire(), true)
end)
case('observer exceptions are recorded outside protected production callbacks', function()
	local w = fixture(); w.cap.on_cancel(function() error('Independent observer exception') end)
	w.owner:cancel(); equal(w.owner.observer_error, 'bootstrap_observer_refused'); equal(w.owner:is_settled(), false)
end)
case('settlement observers receive physical close once', function()
	local w = fixture(); local count = 0
	w.owner:on_settled(function() count = count + 1 end); w.owner:retire(); w.close(); w.owner:retire()
	equal(count, 1)
end)
case('invalid timing refuses before acquiring native timer', function()
	local acquisitions = 0
	local ok = pcall(Budget.new, 0, { now_ms = function() return 100 end, after = function() acquisitions = acquisitions + 1 end })
	equal(ok, false); equal(acquisitions, 0)
end)
case('unsafe deadline arithmetic refuses before timer', function()
	local acquisitions = 0
	local ok = pcall(Budget.new, 1800000, { now_ms = function() return 9007199254740990 end, after = function() acquisitions = acquisitions + 1 end })
	equal(ok, false); equal(acquisitions, 0)
end)
case('caller cannot replace the captured clock authority', function()
	local closed=false
	local timer={cancel=function()closed=true;return true end,is_settled=function()return closed end,on_settled=function()return true end}
	local now=100
	local ports={now_ms=function()return now end,after=function()return timer end}
	local owner,cap=Budget.new(100,ports)
	ports.now_ms=function()return 0 end
	now=120;equal(cap.remaining_ms(),80);equal(cap.current(),true)
	owner:cancel();equal(owner:is_settled(),true)
end)
case('settlement observer can acknowledge retirement after native-close frame', function()
	local w=fixture();local acknowledged=false
	w.owner:on_settled(function()acknowledged=w.owner:retire()end)
	w.owner:retire();w.close();equal(acknowledged,true)
end)
case('known unstarted timer refusal never grants live bootstrap budget', function()
	local timer={started=false,cancel=function()return true end,is_settled=function()return true end,on_settled=function(_,fn)fn();return true end}
	local owner,cap=Budget.new(100,{now_ms=function()return 100 end,after=function()return timer end})
	equal(cap.current(),false);equal(cap.reason(),'bootstrap_timer_start_refused');equal(owner:is_settled(),true)
end)

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
