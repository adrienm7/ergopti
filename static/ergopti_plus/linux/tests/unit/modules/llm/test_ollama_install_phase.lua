--- tests/unit/modules/llm/test_ollama_install_phase.lua

--- ==============================================================================
--- MODULE: Owned Ollama Installation Regression Cases
--- DESCRIPTION:
--- Registers independent controlled receipts through the normal Linux helpers.
--- Native archive, HTTP, process and installation acceptance are separate gates.
--- ==============================================================================

local helpers = require("tests.helpers")
local function expect(value, message) assert(value, message) end
local function test(name, body) helpers.it(name .. " (ollama-install)", body) end
helpers.load_module("llm.ollama_archive_installer")
local Phase = helpers.load_module("llm.ollama_install_phase")
local fixture = helpers.load_module("tests.support.ollama_archive_fixture")
local function phase()
	local f = fixture(); f.remaining, f.budget_current, f.cancel_listeners = 1000, true, {}
	f.files.current = function() return f.ancestry_current ~= false end
	f.options.budget = {
		remaining_ms = function() return f.remaining end,
		current = function() return f.budget_current end,
		on_cancel = function(listener)
			f.cancel_listeners[#f.cancel_listeners + 1] = listener
			if f.cancel_on_subscribe then listener() end
			return f.subscribe_refused ~= true
		end,
	}
	function f.start(options)
		return Phase.start(f.ports, options or f.options, function(result) f.completions[#f.completions + 1] = result end)
	end
	function f.withdraw()
		f.budget_current = false
		for _, listener in ipairs(f.cancel_listeners) do listener() end
	end
	return f
end
test("one master budget clamps finite helpers without allocating another timer", function()
	local f = phase(); local op = f.start()
	assert(op.started and #f.calls == 1 and f.calls[1].options.timeout_ms == 1000)
	assert(#f.cancel_listeners == 1 and f.calls[1].options.authorized() == true, "one retained budget cancellation subscription")
	op:cancel(); f.calls[1].retire(); assert(op:is_settled())
end)
test("each successor uses fresh remaining master budget", function()
	local f = phase(); local op = f.start(); local first = f.calls[1]
	f.remaining = 37; first.deliver(); assert(#f.calls == 1, "callback does not admit successor")
	first.retire(); assert(#f.calls == 2 and f.calls[2].options.timeout_ms == 37, "fresh remainder after exact retirement")
	op:cancel(); f.calls[2].retire()
end)
test("archive HTTP uses the same shrinking budget and captured source", function()
	local f = phase(); local op = f.start(); f.through(4); f.remaining = 17; f.through(5)
	assert(#f.calls == 6 and f.calls[6].program == "HTTP" and f.calls[6].options.timeout_ms == 17)
	assert(f.calls[6].options.authorized() == true and #f.cancel_listeners == 1)
	op:cancel(); f.calls[6].retire(); assert(op:is_settled())
end)
test("zero remaining budget cannot dispatch any native helper", function()
	local f = phase(); f.remaining = 0; local op = f.start()
	assert(op:is_settled() and #f.calls == 0 and f.prepare_count == 0 and #f.completions == 0)
	assert(op.result.ok == false and op.result.error == "install_source_stale")
end)
test("unknown remaining budget cannot borrow an independent phase timeout", function()
	local f = phase(); f.remaining = nil; local op = f.start()
	assert(op:is_settled() and #f.calls == 0 and f.prepare_count == 0 and op.result.ok == false)
end)
test("master revocation immediately cancels exact active operation", function()
	local f = phase(); local op = f.start(); local call = f.calls[1]
	f.withdraw(); assert(call.cancelled > 0 and not op:is_settled() and f.cleanup_count == 0)
	assert(#f.completions == 0, "cancellation cannot publish terminal success")
	call.retire(); assert(op:is_settled() and f.cleanup_count == 1 and #f.completions == 0)
end)
test("revocation during cancellation registration prevents acquisition", function()
	local f = phase(); f.cancel_on_subscribe = true; local op = f.start()
	assert(op:is_settled() and not op.started and #f.calls == 0 and f.prepare_count == 0)
	assert(#f.completions == 0, "revoked source cannot publish refusal through old ticket")
end)
test("refused immediate cancellation subscription cannot start installation", function()
	local f = phase(); f.subscribe_refused = true; local op = f.start()
	assert(op:is_settled() and not op.started and #f.calls == 0 and f.prepare_count == 0)
end)
test("budget function replacement cannot change captured deadline authority", function()
	local f = phase(); local original_source = f.options.authorized
	f.options.authorized = function()
		f.options.budget.remaining_ms = function() return 999999 end
		f.options.budget.current = function() return true end
		return original_source()
	end
	local op = f.start(); assert(f.calls[1].options.timeout_ms == 1000)
	f.remaining = 11; f.calls[1].deliver(); f.calls[1].retire()
	assert(f.calls[2].options.timeout_ms == 11, "original master capability remains owner")
	op:cancel(); f.calls[2].retire()
end)
test("local helper budget remains an upper bound inside larger master budget", function()
	local f = phase(); f.remaining = 1800000; f.options.helper_timeout_ms = 73
	local op = f.start(); assert(f.calls[1].options.timeout_ms == 73)
	op:cancel(); f.calls[1].retire()
end)
test("complete installation retains exact original file retirement semantics", function()
	local f = phase(); local op = f.start(); f.through(9)
	assert(op:is_settled() and op.result.ok == true and op.result.installed == true and #f.completions == 1)
	assert(f.cleanup_count == 1 and f.files.published == true and #f.cancel_listeners == 1)
	f.withdraw(); assert(op:is_settled() and f.files.published == true, "late master expiry does not delete verified publication")
end)
test("source revocation cannot admit successor after active operation retirement", function()
	local f = phase(); local op = f.start(); f.current = false
	f.calls[1].deliver(); f.calls[1].retire()
	assert(op:is_settled() and #f.calls == 1 and #f.completions == 0 and f.cleanup_count == 1)
end)
