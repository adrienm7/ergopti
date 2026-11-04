--- tests/unit/modules/llm/ollama/test_ollama_runtime_choice.lua
--- Literal shared consent and actual selection-caller controls. Native ports
--- remain controlled; these checks cannot qualify an installer or daemon.
local helpers = require("tests.helpers")
local Choice = require("core.llm.ollama_runtime_choice")
local target = "/fixture/ollama-native-http"

helpers.describe("Shared Ollama migration decision", function()
	helpers.it("(ollama-consent-brand) consumes only an explicitly selected issued choice once", function()
		local decision = assert(Choice.new_migration("/fixture/ollama", "homebrew", target, nil, function() return true end))
		helpers.assert_eq(Choice.consume({}, "/fixture/ollama", "homebrew", target, nil), false)
		helpers.assert_eq(Choice.consume(decision, "/fixture/ollama", "homebrew", target, nil), false)
		helpers.assert_true(Choice.choose(decision, "install_native"))
		helpers.assert_eq(Choice.consume(decision, "/fixture/ollama", "path", target, nil), false)
		helpers.assert_true(Choice.consume(decision, "/fixture/ollama", "homebrew", target, nil))
		helpers.assert_eq(Choice.consume(decision, "/fixture/ollama", "homebrew", target, nil), false)
	end)

	helpers.it("(ollama-consent-store) preserves unset, empty and relative raw model-store bindings", function()
		for _, store in ipairs({ {}, { "" }, { "../models" }, { "/fixture/models" } }) do
			local raw = store[1]
			local decision = assert(Choice.new_migration("", nil, target, raw, function() return true end))
			helpers.assert_true(Choice.choose(decision, "install_native"))
			helpers.assert_eq(Choice.consume(decision, "", nil, target, "foreign"), false)
			helpers.assert_true(Choice.consume(decision, "", nil, target, raw))
		end
	end)

	helpers.it("(ollama-consent-currency) refuses a stale choice and cancellation does not grant process authority", function()
		local current = true
		local decision = assert(Choice.new_migration("/fixture/ollama", "app", target, nil, function() return current end))
		helpers.assert_true(Choice.choose(decision, "install_native"))
		current = false
		helpers.assert_eq(Choice.consume(decision, "/fixture/ollama", "app", target, nil), false)
		helpers.assert_true(Choice.cancel(decision))
		current = true
		helpers.assert_eq(Choice.choose(decision, "install_native"), false)
		helpers.assert_eq(Choice.classify("app"), "foreign")
		helpers.assert_eq(Choice.classify("native_managed"), "native")
		helpers.assert_eq(Choice.classify("unknown"), "unknown")
	end)

	helpers.it("(ollama-consent-reentry) blocks synchronous repeated consumption and honors cancellation during callback", function()
		local decision
		local selected = false
		decision = assert(Choice.new_migration("", nil, target, nil, function()
			if selected then
				helpers.assert_eq(Choice.consume(decision, "", nil, target, nil), false)
				Choice.cancel(decision)
			end
			return true
		end))
		helpers.assert_true(Choice.choose(decision, "install_native"))
		selected = true
		helpers.assert_eq(Choice.consume(decision, "", nil, target, nil), false)
	end)
end)

-- Ergopti always uses its own pinned Ollama (maintainer decision, issue #104):
-- a user's own Ollama is never selected, reused, run or stopped. `user_ollama`
-- installs one at the stock app path; `native` installs Ergopti's own.
local function with_offer(selected, callback, native, user_ollama)
	if user_ollama == nil then user_ollama = true end
	helpers.with_stub_scope({ "ui.menu.menu_llm.runtime_install_offer", "modules.llm.ollama_binary",
		"modules.llm.ollama_deps_checker", "infra.dialog_util", "infra.i18n", "infra.logger",
		"infra.notifications", "modules.llm.api_ollama",
		"ui.menu.menu_llm.models_manager_ollama" }, function()
		local fixture = { stock_calls = 0, stock_installs = 0, native_calls = 0, dialogs = 0, idle = true,
			bodies = {}, pinned_calls = 0 }
		package.loaded["modules.llm.ollama_binary"] = {
			resolve = function()
				if native then return target .. "/ollama", nil, "native_managed" end
				return nil, "Ergopti's own Ollama runtime is not installed", nil
			end,
			find_user_installation = function()
				if user_ollama then return "/Applications/Ollama.app/Contents/Resources/ollama", "app" end
				return nil
			end,
			pinned_version = function() fixture.pinned_calls = fixture.pinned_calls + 1; return "0.40.4" end,
			native_managed_install_dir = function() return target end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.dialog_util"] = { block_alert = function(_, body)
			fixture.dialogs = fixture.dialogs + 1
			fixture.bodies[#fixture.bodies + 1] = body
			if fixture.dialog_hook then fixture.dialog_hook() end
			return selected
		end }
		package.loaded["modules.llm.ollama_deps_checker"] = {
			runtime_available = function() return native == true end,
			is_task_running = function() return false end,
			provisioning_idle = function() return fixture.idle end,
			check_and_install_deps = function() fixture.stock_calls = fixture.stock_calls + 1; return true end,
			install_for_selection = function()
				error("the official on-demand Ollama download is no longer a selection path")
			end,
			install_native_for_selection = function(decision, source_path, source_kind, native_target, raw_store)
				fixture.native_calls = fixture.native_calls + 1
				helpers.assert_eq(source_path, "", "a user's own Ollama is never the migration source")
				helpers.assert_eq(source_kind, nil)
				helpers.assert_eq(native_target, target)
				helpers.assert_eq(raw_store, os.getenv("OLLAMA_MODELS"))
				helpers.assert_true(Choice.consume(decision, source_path, source_kind, native_target, raw_store))
				return true
			end,
		}
		package.loaded["modules.llm.api_ollama"] = { migration_idle = function() return fixture.idle end }
		package.loaded["ui.menu.menu_llm.models_manager_ollama"] = { migration_idle = function() return fixture.idle end }
		callback(helpers.load_with_stubs("ui.menu.menu_llm.runtime_install_offer"), fixture)
	end)
end

helpers.describe("Actual Ollama selection caller (ollama-owned-runtime)", function()
	helpers.it("(ollama-offer-native) installs Ergopti's own pinned Ollama beside a user's own", function()
		with_offer("ollama.native_offer_install", function(offer, fixture)
			helpers.assert_true(offer.select_ollama())
			helpers.assert_eq(fixture.dialogs, 1)
			helpers.assert_eq(fixture.pinned_calls, 1, "the offer names Ergopti's pinned version")
			helpers.assert_eq(fixture.native_calls, 1)
			helpers.assert_eq(fixture.stock_calls, 0, "the user's own Ollama is never reused")
		end)
	end)
	for _, selected in ipairs({ "ollama.native_offer_keep", "foreign-choice" }) do
		helpers.it("(ollama-offer-declined) never falls back to a user's own Ollama on choice " .. selected, function()
			with_offer(selected, function(offer, fixture)
				helpers.assert_eq(offer.select_ollama(), false)
				helpers.assert_eq(fixture.dialogs, 1)
				helpers.assert_eq(fixture.native_calls, 0)
				helpers.assert_eq(fixture.stock_calls, 0, "declining leaves the AI off, never on the user's Ollama")
			end)
		end)
	end
	helpers.it("(ollama-offer-owned-reused) reuses Ergopti's own installed runtime without asking", function()
		with_offer("foreign-choice", function(offer, fixture)
			helpers.assert_true(offer.select_ollama())
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_eq(fixture.stock_calls, 1)
		end, true)
	end)
end)

helpers.describe("Migration currency and ordinary availability", function()
	helpers.it("(ollama-consent-continuation) spends once and retains only the exact current predicate", function()
		local current = true
		local decision = assert(Choice.new_migration("/fixture/ollama", "app", target, nil, function() return current end))
		helpers.assert_true(Choice.choose(decision, "install_native"))
		local consumed, guard = Choice.consume(decision, "/fixture/ollama", "app", target, nil)
		helpers.assert_true(consumed)
		helpers.assert_eq(type(guard), "function")
		helpers.assert_true(guard())
		current = false
		helpers.assert_eq(guard(), false)
		helpers.assert_eq(Choice.consume(decision, "/fixture/ollama", "app", target, nil), false)
	end)

	helpers.it("(ollama-offer-install-button) the install button installs Ergopti's own Ollama without asking again", function()
		with_offer("ollama.native_offer_keep", function(offer, fixture)
			helpers.assert_true(offer.install_ollama())
			helpers.assert_eq(fixture.dialogs, 0, "the pressed install button is the user's choice")
			helpers.assert_eq(fixture.native_calls, 1)
			helpers.assert_eq(fixture.stock_calls, 0)
		end, false, false)
	end)

	helpers.it("(ollama-offer-joined) refuses migration while an original operation retains debt", function()
		with_offer("ollama.native_offer_install", function(offer, fixture)
			fixture.idle = false
			helpers.assert_eq(offer.select_ollama(), false)
			helpers.assert_eq(fixture.dialogs, 0)
			helpers.assert_eq(fixture.native_calls, 0)
		end)
	end)

	helpers.it("(ollama-offer-reentered) rechecks joint admission after the actual dialog callback", function()
		with_offer("ollama.native_offer_install", function(offer, fixture)
			fixture.dialog_hook = function() fixture.idle = false end
			helpers.assert_eq(offer.select_ollama(), false)
			helpers.assert_eq(fixture.dialogs, 1)
			helpers.assert_eq(fixture.native_calls, 0)
		end)
	end)
end)
