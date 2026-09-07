--- tests/unit/modules/shortcuts/pause_owners/test_model_switch.lua

--- ==============================================================================
--- MODULE: Pause Owner model switch Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local startup_fixture = require("tests.unit.modules.shortcuts.pause_owners.startup_fixture")
local load_real_startup_owner = startup_fixture.load_real_startup_owner
local fire_timer_delay = startup_fixture.fire_timer_delay

local function load_real_model_switch_owner(options)
	options = options or {}
	local epoch = 0
	local paused = false
	local owner = nil
	local state = options.state or {
		llm_backend = "mlx",
		llm_enabled = true,
		llm_active_profile = "basic",
		llm_model = "old-model",
	}
	local control = {
		get_pause_epoch = function() return epoch end,
		is_paused = function() return paused end,
		register_pause_owner = function(name, candidate)
			helpers.assert_eq(name, "llm_model_switcher")
			owner = candidate
			return true
		end,
	}
	local prediction_box = options.prediction_box or { value = true }
	local prediction_calls = options.prediction_calls or {}
	local prediction_mode = options.prediction_mode or "true"
	local probe = nil
	local dispatch_calls = 0
	local requirement_owner = {}
	local models_mgr = {
		create_requirement_owner = function(label)
			helpers.assert_eq(label, "model_switcher")
			return requirement_owner
		end,
		pause_requirements = function(owner_identity)
			helpers.assert_true(owner_identity == requirement_owner,
				"model switching must join only its exact requirement capability")
			return true
		end,
		check_requirements = function(model, on_ok, on_fail, opts)
			helpers.assert_true(opts.requirement_owner == requirement_owner,
				"model probes must carry their opaque requirement capability")
			dispatch_calls = dispatch_calls + 1
			probe = { model = model, on_ok = on_ok, on_fail = on_fail, opts = opts }
			if options.sync_terminal == "ok" then on_ok() end
			if options.sync_terminal == "fail" then on_fail("sync") end
			if options.dispatch_mode == "false" then return false end
			if options.dispatch_mode == "nil" then return nil end
			if options.dispatch_mode == "throw" then error("model dispatch exploded") end
			return true
		end,
		get_presets = function() return {} end,
		get_model_info = function() return {} end,
		get_actual_model_name = function(name) return name end,
	}
	local keymap = options.keymap or {
		get_llm_enabled = function() return prediction_box.value end,
		set_llm_enabled = function(enabled)
			prediction_box.value = enabled == true
			prediction_calls[#prediction_calls + 1] = enabled
			if prediction_mode == "false" then return false end
			if prediction_mode == "nil" then return nil end
			if prediction_mode == "throw" then error("prediction setter exploded") end
			return true
		end,
		set_llm_model = function() return true end,
		set_llm_display_model_name = function() return true end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
	package.loaded["infra.notifications"] = { notify = function() return true end }
	package.loaded["ui.menu.menu_llm.profile_label"] = {
		format = function(label) return label end,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_num_predictions = 1 },
		get_active_profile = function() return { id = "basic" } end,
		set_active_profile = function() return true end,
		set_llm_model_mlx = function() return true end,
		set_llm_model_ollama = function() return true end,
	}
	reset_module("ui.menu.menu_llm.model_switcher")
	local ModelSwitcher = require("ui.menu.menu_llm.model_switcher")
	local switcher = ModelSwitcher.new({
		state = state,
		models_mgr = models_mgr,
		keymap = keymap,
		script_control = control,
		prediction_locks = options.prediction_locks,
		save_prefs = function() return true end,
		update_menu = function() return true end,
		runtime_gate = function() return paused ~= true end,
		pause_epoch = function() return epoch end,
	})
	helpers.assert_not_nil(owner)
	return {
		switcher = switcher,
		owner = owner,
		state = state,
		prediction_calls = prediction_calls,
		get_probe = function() return probe end,
		get_prediction_state = function() return keymap.get_llm_enabled() end,
		get_dispatch_calls = function() return dispatch_calls end,
		set_prediction_mode = function(value) prediction_mode = value end,
		set_epoch = function(value) epoch = value end,
		set_paused = function(value) paused = value == true end,
	}
end

helpers.describe("HS-012 real ordinary model-switch pause epoch", function()
	helpers.it("rejects switch and No Model before any mutation while PAUSED", function()
		local ctx = load_real_model_switch_owner()
		ctx.set_paused(true)
		helpers.assert_eq(ctx.switcher.switch_model("model-A"), false)
		helpers.assert_eq(ctx.switcher.disable_model(), false)
		helpers.assert_eq(ctx.get_dispatch_calls(), 0)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, {}),
			"paused preflight must run before prediction-lock acquisition")
		helpers.assert_eq(ctx.state.llm_model, "old-model")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates a " .. mode .. " model requirements dispatch once", function()
			local ctx = load_real_model_switch_owner({ dispatch_mode = mode })
			helpers.assert_eq(ctx.switcher.switch_model("model-A"), false)
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
				"a refused dispatch must release the exact prediction lease")
			local probe = ctx.get_probe()
			helpers.assert_not_nil(probe,
				"the positive dispatch boundary must receive real continuations")
			probe.on_ok()
			probe.on_fail()
			helpers.assert_eq(ctx.state.llm_model, "old-model")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
				"late and duplicate terminals may not restore or publish twice")
		end)

		helpers.it("discards a synchronous success before " .. mode .. " dispatch refusal", function()
			local ctx = load_real_model_switch_owner({
				dispatch_mode = mode,
				sync_terminal = "ok",
			})
			helpers.assert_eq(ctx.switcher.switch_model("model-A"), false)
			helpers.assert_eq(ctx.state.llm_model, "old-model",
				"a synchronous callback cannot publish before dispatch ownership commits")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
			local probe = ctx.get_probe()
			probe.on_ok()
			probe.on_fail("late")
			helpers.assert_eq(ctx.state.llm_model, "old-model")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
		end)
	end

	helpers.it("delivers one synchronous success after dispatch acceptance", function()
		local ctx = load_real_model_switch_owner({ sync_terminal = "ok" })
		helpers.assert_true(ctx.switcher.switch_model("model-A"))
		helpers.assert_eq(ctx.state.llm_model, "model-A")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
		local probe = ctx.get_probe()
		probe.on_ok()
		probe.on_fail("late")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"duplicate synchronous and late terminals must settle once")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("reasserts the model lock after mutate-then-" .. mode .. " resume", function()
			local ctx = load_real_model_switch_owner()
			helpers.assert_true(ctx.switcher.switch_model("model-A"))
			ctx.set_epoch(1)
			helpers.assert_true(ctx.owner.pause())
			ctx.set_paused(true)
			ctx.set_epoch(2)
			ctx.set_prediction_mode(mode)
			helpers.assert_eq(ctx.owner.resume(), false)
			helpers.assert_eq(ctx.get_prediction_state(), true,
				"the refusing enable mutates first in this adverse fixture")
			ctx.set_epoch(3)
			ctx.set_prediction_mode("true")
			helpers.assert_true(ctx.owner.pause(),
				"resume rollback must retain and reassert the same lease")
			helpers.assert_eq(ctx.get_prediction_state(), false)
			ctx.set_epoch(4)
			helpers.assert_true(ctx.owner.resume())
			helpers.assert_eq(ctx.get_prediction_state(), true)
		end)
	end

	helpers.it("abandons the old manager guard and restores its MLX lock exactly once", function()
		local ctx = load_real_model_switch_owner()
		helpers.assert_true(ctx.switcher.switch_model("model-A"))
		local probe = ctx.get_probe()
		helpers.assert_not_nil(probe)
		helpers.assert_true(probe.opts.is_current(),
			"positive control must prove the real manager guard starts current")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }))

		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)
		helpers.assert_eq(probe.opts.is_current(), false,
			"the manager-side operation token must remain stale after resume")
		probe.on_ok()
		helpers.assert_eq(ctx.state.llm_model, "old-model",
			"the abandoned model may never publish after the pause epoch")
		helpers.assert_true(ctx.owner.resume(),
			"duplicate resume delivery is an idempotent no-op")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"one retained lock must produce exactly one successful restoration")
	end)

	helpers.it("does not resurrect predictions disabled in live preferences", function()
		local ctx = load_real_model_switch_owner()
		helpers.assert_true(ctx.switcher.switch_model("model-A"))
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.state.llm_enabled = false
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, false }),
			"resume must exactly reassert the disabled preference before consuming its lease")
		ctx.state.llm_enabled = true
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, false }),
			"a consumed disabled lock cannot be restored later by duplicate delivery")
	end)
end)

helpers.describe("HS-012 real startup/model shared prediction leases", function()
	local function build_overlap()
		local state = {
			llm_backend = "mlx",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "shared-model",
		}
		local runtime = true
		local calls = {}
		local keymap = {
			get_llm_enabled = function() return runtime end,
			set_llm_enabled = function(enabled)
				runtime = enabled == true
				calls[#calls + 1] = enabled
				return true
			end,
			set_llm_backend_name = function() return true end,
			set_llm_model = function() return true end,
			set_llm_display_model_name = function() return true end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		reset_module("ui.menu.menu_llm.prediction_lock_registry")
		local registry = require("ui.menu.menu_llm.prediction_lock_registry").new({
			state = state,
			keymap = keymap,
		})
		local startup = load_real_startup_owner(nil, {
			state = state,
			keymap = keymap,
			prediction_locks = registry,
			prediction_calls = calls,
		})
		local model = load_real_model_switch_owner({
			state = state,
			keymap = keymap,
			prediction_locks = registry,
			prediction_calls = calls,
		})
		fire_timer_delay(startup, 1)
		helpers.assert_true(model.switcher.switch_model("candidate"))
		return {
			state = state,
			registry = registry,
			startup = startup,
			model = model,
			calls = calls,
			get_runtime = function() return runtime end,
		}
	end

	for _, first in ipairs({ "startup", "model" }) do
		helpers.it("restores only after the last real owner when " .. first
			.. " completes first", function()
			local ctx = build_overlap()
			helpers.assert_eq(ctx.get_runtime(), false)
			if first == "startup" then
				ctx.startup.probes[1].on_ok()
				helpers.assert_eq(ctx.get_runtime(), false)
				ctx.model.get_probe().on_fail()
			else
				ctx.model.get_probe().on_fail()
				helpers.assert_eq(ctx.get_runtime(), false)
				ctx.startup.probes[1].on_ok()
			end
			helpers.assert_eq(ctx.get_runtime(), true)
			ctx.startup.probes[1].on_ok()
			ctx.model.get_probe().on_fail()
			helpers.assert_eq(ctx.get_runtime(), true)
		end)
	end

	helpers.it("keeps the gate disabled when preference turns off during overlap", function()
		local ctx = build_overlap()
		ctx.state.llm_enabled = false
		helpers.assert_true(ctx.registry.apply_preference(false))
		ctx.model.get_probe().on_fail()
		ctx.startup.probes[1].on_ok()
		helpers.assert_eq(ctx.get_runtime(), false)
	end)
end)
