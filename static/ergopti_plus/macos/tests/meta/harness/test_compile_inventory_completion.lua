--- tests/meta/harness/test_compile_inventory_completion.lua

--- ==============================================================================
--- MODULE: Compile Inventory Completion Regressions
--- DESCRIPTION:
--- Executes the real compile guard over controlled command receipts. One healthy
--- subtree must never conceal an omitted or incomplete production subtree.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the compile guard without executing production code or native commands.
--- @param failure string|nil The controlled inventory failure.
--- @return boolean completed
--- @return any reason
--- @return table facts
local function run_guard(failure)
	local facts = { closes = 0, commands = 0, parsed = 0 }
	local stub_helpers = {
		driver_root = function() return "/owned/driver/" end,
		shared = function() return "/owned/shared/lua" end,
		describe = function(_, callback) callback() end,
		it = function(_, callback) callback() end,
		assert_true = helpers.assert_true,
	}
	local popen = io.popen
	io.popen = function()
		facts.commands = facts.commands + 1
		local selected = facts.commands == 2
		if selected and failure == "open" then return nil, "controlled enumeration refusal" end
		local emitted = false
		return {
			lines = function() return function()
				if selected and failure == "iteration" then error("controlled enumeration iteration") end
				if emitted or (selected and failure == "empty") then return nil end
				emitted = true
				return "/owned/driver/source.lua"
			end end,
			close = function()
				facts.closes = facts.closes + 1
				if selected and failure == "close" then error("controlled enumeration close") end
				if selected and failure == "exit" then return nil, "exit", 7 end
				return true, "exit", 0
			end,
		}
	end
	local environment = setmetatable({
		require = function(name)
			if name == "tests.helpers" then return stub_helpers end
			return require(name)
		end,
		loadfile = function()
			facts.parsed = facts.parsed + 1
			return function() end
		end,
	}, { __index = _G })
	local ok, reason = pcall(function()
		local guard = assert(loadfile(helpers.driver_root() .. "tests/meta/boot/test_lua_sources_compile.lua", "t", environment))
		return guard()
	end)
	io.popen = popen
	return ok, reason, facts
end

helpers.describe("compile inventory completion", function()
	for _, failure in ipairs({ "open", "exit", "iteration", "close", "empty" }) do
		helpers.it("(compile-inventory-completion) rejects a subtree's " .. failure .. " failure", function()
			local ok, reason, facts = run_guard(failure)
			helpers.assert_eq(ok, false, "one healthy subtree cannot certify an incomplete production inventory")
			helpers.assert_type(reason, "string")
			helpers.assert_eq(facts.commands, 2, "stop before scanning unrelated roots")
			helpers.assert_eq(facts.closes, failure == "open" and 1 or 2, "retire every opened enumeration pipe")
			helpers.assert_eq(facts.parsed, 2, "only the two explicit entrypoint checks precede complete inventory admission")
		end)
	end
	helpers.it("(compile-inventory-completion) admits complete nonempty production subtrees", function()
		local ok, reason, facts = run_guard(nil)
		helpers.assert_true(ok, tostring(reason))
		helpers.assert_eq(facts.commands, 8)
		helpers.assert_eq(facts.closes, 8)
		helpers.assert_eq(facts.parsed, 10)
	end)
end)
