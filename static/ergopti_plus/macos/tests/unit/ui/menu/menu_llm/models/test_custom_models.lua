--- tests/unit/ui/menu/menu_llm/models/test_custom_models.lua

--- ==============================================================================
--- MODULE: Custom Model List Transactions
--- DESCRIPTION:
--- The models the user adds by identifier in the model selector page keep the
--- transactions the tray's former custom-model option had: an identifier is
--- validated before anything is written, a refused save rolls the list back,
--- removing the active model disables it first and restores the entry when
--- that refuses, and a cancelled confirmation keeps the model.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = { "ui.menu.menu_llm.custom_models", "infra.dialog_util" }

--- Runs one case with the real module and a scripted confirmation.
local function with_models(opts, body)
	helpers.with_fresh_modules(OWNED, function()
		package.loaded["infra.dialog_util"] = { block_alert = function()
			if opts.confirm == "throw" then error("dialog", 0) end
			return opts.confirm == "cancel" and "Cancel" or require("infra.i18n").get("button.remove")
		end }
		local Custom = require("ui.menu.menu_llm.custom_models")
		local state = { llm_backend = "ollama", llm_model = opts.model or "", llm_user_models = opts.list }
		local calls = { saves = 0, updates = 0, changed = 0 }
		local ops = Custom.new({
			state = state,
			disable_model = function()
				calls.disabled = true
				if opts.disable == "throw" then error("disable", 0) end
				return opts.disable ~= "false"
			end,
			save_prefs = function()
				calls.saves = calls.saves + 1
				if opts.save == "throw" then error("save", 0) end
				if opts.save == "nil" then return nil end
				return opts.save ~= "false"
			end,
			update_menu = function() calls.updates = calls.updates + 1 end,
			on_changed = function() calls.changed = calls.changed + 1 end,
		})
		body(ops, state, calls)
	end)
end

helpers.describe("custom model list transactions", function()
	helpers.it("refuses an invalid identifier before any write", function()
		with_models({}, function(ops, state, calls)
			helpers.assert_eq(ops.add("ollama", "Qwen3 4b"), false)
			helpers.assert_eq(ops.add("mlx", "no-owner"), false)
			helpers.assert_eq(calls.saves, 0)
			helpers.assert_nil(state.llm_user_models)
		end)
	end)

	helpers.it("persists a valid identifier once and lists it for its backend only", function()
		with_models({}, function(ops, state, calls)
			helpers.assert_true(ops.add("ollama", "qwen3:4b"))
			helpers.assert_true(ops.add("ollama", "qwen3:4b"), "a listed name is already added")
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(#ops.list_for_backend("ollama"), 1)
			helpers.assert_eq(#ops.list_for_backend("mlx"), 0)
			helpers.assert_eq(calls.changed, 1)
		end)
	end)

	for _, save in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls back an unpersisted add after save " .. save, function()
			with_models({ save = save }, function(ops, state)
				helpers.assert_eq(ops.add("mlx", "mlx-community/X-4bit"), false)
				helpers.assert_nil(state.llm_user_models, "the list returns to its exact previous value")
			end)
		end)
		helpers.it("restores an unpersisted removal after save " .. save, function()
			local list = { { backend = "ollama", name = "a" }, { backend = "ollama", name = "b" } }
			with_models({ save = save, list = list }, function(ops, state)
				helpers.assert_eq(ops.remove("ollama", "a"), false)
				helpers.assert_eq(state.llm_user_models[1].name, "a", "the entry returns at its index")
				helpers.assert_eq(#state.llm_user_models, 2)
			end)
		end)
	end

	for _, disable in ipairs({ "false", "throw" }) do
		helpers.it("restores the active model's entry when its disable refuses (" .. disable .. ")", function()
			local list = { { backend = "ollama", name = "a" } }
			with_models({ disable = disable, list = list, model = "a" }, function(ops, state, calls)
				helpers.assert_eq(ops.remove("ollama", "a"), false)
				helpers.assert_true(calls.disabled)
				helpers.assert_eq(state.llm_user_models[1].name, "a")
			end)
		end)
	end

	for _, confirm in ipairs({ "cancel", "throw" }) do
		helpers.it("keeps the model when the confirmation is " .. confirm, function()
			local list = { { backend = "ollama", name = "a" } }
			with_models({ confirm = confirm, list = list }, function(ops, state, calls)
				helpers.assert_eq(ops.remove("ollama", "a"), false)
				helpers.assert_eq(#state.llm_user_models, 1)
				helpers.assert_eq(calls.saves, 0)
			end)
		end)
	end

	helpers.it("disables the active model before removing it", function()
		local list = { { backend = "ollama", name = "a" } }
		with_models({ list = list, model = "a" }, function(ops, state, calls)
			helpers.assert_true(ops.remove("ollama", "a"))
			helpers.assert_true(calls.disabled)
			helpers.assert_eq(#state.llm_user_models, 0)
		end)
	end)
end)
