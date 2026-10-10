--- tests/unit/ui/menu/test_optional_runtime_recovery_context.lua

--- ==============================================================================
--- MODULE: Optional Runtime Recovery Controller Admission
--- DESCRIPTION:
--- The actual menu must retain its ordinary owners when no valid remap controller
--- is supplied, while recovery remains unavailable without native prerequisites.
--- ==============================================================================

local helpers = require("tests.helpers")
local boot = require("tests.support.menu_boot_fixture").boot

local function boot_with_controller(controller)
	local original_require = _G.require
	local touched, original_start
	_G.require = function(name, ...)
		local module = original_require(name, ...)
		if name == "ui.menu.init" and touched == nil then
			touched, original_start = module, module.start
			module.start = function(...)
				local args = table.pack(...)
				args[7] = controller
				return original_start(table.unpack(args, 1, args.n))
			end
		end
		return module
	end
	local ok, fixture = pcall(boot, {})
	_G.require = original_require
	if touched then touched.start = original_start end
	if not ok then error(fixture, 0) end
	return fixture
end

helpers.describe("optional remap context keeps recovery fail-closed", function()
	for _, case in ipairs({
		{ label = "absent" },
		{ label = "false", value = false },
		{ label = "true", value = true },
		{ label = "number", value = 31 },
		{ label = "string", value = "unavailable" },
		{ label = "function", value = function() error("invalid controller must not be called", 0) end },
		{ label = "empty table", value = {} },
	}) do
		helpers.it("retains ordinary menu and refuses recovery for " .. case.label, function()
			local fixture = boot_with_controller(case.value)
			helpers.assert_not_nil(fixture.menu, "optional remap context must not abort menu startup")
			helpers.assert_type(fixture.program_admission, "function", "ordinary gesture admission remains wired")
			helpers.assert_type(fixture.global_actions().quit, "function", "ordinary Quit remains wired")
			helpers.assert_eq(fixture.ctx.karabiner, case.value, "only the bounded recovery scope normalizes its controller")
			helpers.assert_type(fixture.ctx.can_recover_shared_runtime, "function")
			helpers.assert_type(fixture.ctx.recover_shared_runtime, "function")
			helpers.assert_eq(fixture.ctx.can_recover_shared_runtime(), false)
			helpers.assert_eq(fixture.ctx.recover_shared_runtime(), false)
			helpers.assert_eq(fixture.boot_saves, 0, "constructing recovery must not persist preferences")
			helpers.assert_eq(#fixture.saves, 0, "refused recovery must not persist preferences")
		end)
	end
end)

helpers.describe("native recovery refuses an absent global transaction owner", function()
	helpers.it("uses the authentic constructor refusal before recovery reads or writes", function()
		local source = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'
		local recovery = require("tests.support.runtime_recovery_fixture")
		recovery.with_source(source, function(remap, _calls, _lease, read, _initialized, path)
			helpers.with_stub_scope({ "infra.termination_coordinator", "ui.menu.global_actions_transaction", "ui.menu.init" }, function()
				package.loaded["infra.termination_coordinator"] = nil
				local terminal = require("infra.termination_coordinator")
				local original_require = _G.require
				local creator, original_create, refusals
				refusals = 0
				_G.require = function(name, ...)
					local module = original_require(name, ...)
					if name == "ui.menu.global_actions_transaction" and creator == nil then
						creator, original_create = module, module.create
						module.create = function(deps)
							deps.reset_journal = nil
							local owner = original_create(deps)
							helpers.assert_nil(owner, "authentic constructor must refuse the absent required journal")
							refusals = refusals + 1
							return owner
						end
					end
					return module
				end
				local ok, fixture = pcall(require("tests.support.runtime_recovery_menu_fixture").boot,
					{ karabiner = remap, terminal = terminal, runtime_path = function() return path end })
				_G.require = original_require
				if creator then creator.create = original_create end
				if not ok then error(fixture, 0) end
				helpers.assert_eq(refusals, 1, "the real native global constructor must return nil once")
				helpers.assert_not_nil(fixture.menu)
				fixture.menu_provider()
				helpers.assert_eq(fixture.ctx.can_recover_shared_runtime(), false)
				helpers.assert_eq(fixture.ctx.recover_shared_runtime(), false)
				helpers.assert_eq(read(), source, "refused owner cannot rewrite runtime intent")
				helpers.assert_eq(#fixture.saves, 0)
			end)
		end)
	end)
end)
return true
