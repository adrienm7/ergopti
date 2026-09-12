--- tests/unit/modules/shortcuts/pause_owners/test_prediction_registry.lua

--- ==============================================================================
--- MODULE: Pause Owner prediction registry Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module

local function load_prediction_registry()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	reset_module("ui.menu.menu_llm.prediction_lock_registry")
	local state = { llm_enabled = true }
	local runtime = true
	local mode = "true"
	local calls = {}
	local keymap = {
		get_llm_enabled = function() return runtime end,
		set_llm_enabled = function(enabled)
			calls[#calls + 1] = enabled
			if mode == "false_no_mutation" then return false end
			if mode == "nil_no_mutation" then return nil end
			if mode == "throw_no_mutation" then error("registry setter exploded before mutation") end
			runtime = enabled == true
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "throw" then error("registry setter exploded") end
			return true
		end,
	}
	local registry = require("ui.menu.menu_llm.prediction_lock_registry").new({
		state = state,
		keymap = keymap,
	})
	return {
		registry = registry,
		state = state,
		calls = calls,
		get_runtime = function() return runtime end,
		set_runtime = function(value) runtime = value == true end,
		set_mode = function(value) mode = value end,
	}
end

helpers.describe("HS-012 shared prediction-lock registry", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains acquisition debt after " .. mode .. " without mutation", function()
			local ctx = load_prediction_registry()
			ctx.set_mode(mode .. "_no_mutation")
			helpers.assert_eq(ctx.registry.acquire("startup"), false)
			helpers.assert_true(ctx.registry.held("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
			ctx.set_mode("true")
			helpers.assert_true(ctx.registry.ensure_locked("startup"))
			helpers.assert_eq(ctx.get_runtime(), false)
			helpers.assert_true(ctx.registry.release("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
		end)

		helpers.it("compensates mutate-then-" .. mode .. " acquisition", function()
			local ctx = load_prediction_registry()
			ctx.set_mode(mode)
			helpers.assert_eq(ctx.registry.acquire("startup"), false)
			helpers.assert_true(ctx.registry.held("startup"))
			helpers.assert_eq(ctx.get_runtime(), false)
			ctx.set_mode("true")
			helpers.assert_true(ctx.registry.release("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
		end)
	end

	helpers.it("keeps overlapping startup and model leases locked in both release orders", function()
		for _, order in ipairs({
			{ "startup", "model" },
			{ "model", "startup" },
		}) do
			local ctx = load_prediction_registry()
			helpers.assert_true(ctx.registry.acquire("startup"))
			helpers.assert_true(ctx.registry.acquire("model"))
			helpers.assert_eq(ctx.get_runtime(), false)
			helpers.assert_true(ctx.registry.release(order[1]))
			helpers.assert_eq(ctx.get_runtime(), false,
				"the first completion may not expose the remaining async owner")
			helpers.assert_true(ctx.registry.release(order[2]))
			helpers.assert_eq(ctx.get_runtime(), true)
			helpers.assert_true(ctx.registry.release(order[2]),
				"duplicate terminal delivery is an exact no-op")
		end
	end)

	helpers.it("routes OFF-to-ON preference writes through overlapping leases", function()
		local ctx = load_prediction_registry()
		helpers.assert_true(ctx.registry.acquire("startup"))
		helpers.assert_true(ctx.registry.acquire("model"))
		ctx.state.llm_enabled = false
		helpers.assert_true(ctx.registry.apply_preference(false))
		ctx.state.llm_enabled = true
		helpers.assert_true(ctx.registry.apply_preference(true))
		helpers.assert_eq(ctx.get_runtime(), false,
			"enabled preference intent must remain parked while leases exist")
		ctx.set_runtime(true)
		helpers.assert_true(ctx.registry.release("startup"))
		helpers.assert_eq(ctx.get_runtime(), false,
			"non-final release must reassert against a bypassing writer")
		helpers.assert_true(ctx.registry.release("model"))
		helpers.assert_eq(ctx.get_runtime(), true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the last lease after mutate-then-" .. mode .. " restore", function()
			local ctx = load_prediction_registry()
			helpers.assert_true(ctx.registry.acquire("startup"))
			ctx.set_mode(mode)
			helpers.assert_eq(ctx.registry.release("startup"), false)
			helpers.assert_true(ctx.registry.held("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
			ctx.set_mode("true")
			helpers.assert_true(ctx.registry.ensure_locked("startup"))
			helpers.assert_eq(ctx.get_runtime(), false)
			helpers.assert_true(ctx.registry.release("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
	end)
	end

	helpers.it("never resurrects a preference disabled while a lease is held", function()
		local ctx = load_prediction_registry()
		helpers.assert_true(ctx.registry.acquire("model"))
		ctx.state.llm_enabled = false
		helpers.assert_true(ctx.registry.apply_preference(false))
		helpers.assert_true(ctx.registry.release("model"))
		helpers.assert_eq(ctx.get_runtime(), false)
	end)
end)

helpers.describe("HS-012 real warmup-controller pause snapshot", function()
	local function load_controller()
		local handles = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function() return 1 end }
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_, callback)
				local handle = { callback = callback, live = true }
				handles[#handles + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				handle.live = false
				return true
			end,
		}
		reset_module("modules.llm.warmup_controller")
		local controller = require("modules.llm.warmup_controller")
		helpers.assert_true(controller.init({
			core_llm = {
				get_current_model = function() return "model" end,
				get_backend = function() return "mlx" end,
				get_active_profile = function() return {} end,
				is_backend_ready = function() return false end,
				warmup_model = function() return true end,
			},
			get_llm_enabled = function() return true end,
		}))
		return controller, handles
	end

	helpers.it("does not invent work for a controller inactive before pause", function()
		local controller, handles = load_controller()
		helpers.assert_true(controller.pause_warmup())
		helpers.assert_true(controller.resume_warmup())
		helpers.assert_eq(#handles, 0)
	end)

	helpers.it("re-arms one active retry intent exactly once", function()
		local controller, handles = load_controller()
		helpers.assert_true(controller.schedule_warmup_with_retry("positive control"))
		helpers.assert_eq(#handles, 1)
		helpers.assert_true(controller.pause_warmup())
		helpers.assert_true(controller.resume_warmup())
		helpers.assert_eq(#handles, 2)
		helpers.assert_true(controller.resume_warmup())
		helpers.assert_eq(#handles, 2)
	end)
end)
