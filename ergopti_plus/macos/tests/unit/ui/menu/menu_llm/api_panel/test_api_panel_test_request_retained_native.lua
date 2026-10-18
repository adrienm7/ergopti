--- tests/unit/ui/menu/menu_llm/api_panel/test_api_panel_test_request_retained_native.lua

--- ==============================================================================
--- MODULE: API Panel Test-Request Regression
--- DESCRIPTION:
--- The Test-active-entry row sends the shared minimal probe to the active
--- entry and surfaces the verdict. Success notifies the reply excerpt and
--- latency; failure notifies without leaking the token; stale completions
--- (entry switched or deleted mid-flight) and a missing probe spec stay
--- silent or fail closed without dispatching.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.api_panel.api_panel_test_request_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.api_panel.api_panel_test_request_fixture")
local fixture_context = Fixture.fixture_context
local install_doubles = Fixture.install_doubles
local with_api_add_locale = Fixture.with_api_add_locale





helpers.describe("API Add: retained native admission", function()
	local owned = { "modules.keymap.llm_bridge", "modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
		"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel" }
	local function install_add(provider_id)
		local entry = { id = "old", provider = "openai", model = "old-model", token = "inert-old-secret" }
		local remote, _, notices = install_doubles({ entries = { entry }, active_id = entry.id, spec = {} })
		if provider_id then
			local file = assert(io.open(helpers.driver_root() .. "../_shared/modules/llm/api_providers.json", "rb"))
			local raw = file:read("*a"); assert(file:close())
			local catalogue = assert(require("adapters.json_codec").decode(raw))
			remote.PROVIDER_ORDER = { provider_id }
			remote.PROVIDERS[provider_id] = assert(catalogue.providers[provider_id])
		end
		local ctx = fixture_context()
		local observed = { prompts = 0, resets = 0, writes = 0, probes = 0, paused = false }
		ctx.is_paused = function() return observed.paused end
		ctx.keymap.reset_predictions_for_configuration = function() observed.resets = observed.resets + 1; return true end
		package.loaded["infra.dialog_util"].text_prompt = function(_, _, _, affirmative)
			observed.prompts = observed.prompts + 1
			if observed.on_prompt then observed.on_prompt(observed.prompts) end
			if observed.cancel_at == observed.prompts then return "button.cancel", "" end
			return affirmative, ({ observed.endpoint or (provider_id and "http://127.0.0.1:8000/v1" or "https://example.invalid/v1"),
				observed.token or "inert-new-secret", "new-model" })[observed.prompts]
		end
		remote.check_availability = function(_, callback)
			observed.probes = observed.probes + 1
			callback()
			return true
		end
		package.loaded["modules.llm"].persist_api_entries = function(callback)
			observed.writes = observed.writes + 1
			callback(true, nil, true)
		end
		local _, rows = require("ui.menu.menu_llm.api_panel").build(ctx)
		local action
		for _, row in ipairs(rows) do
			if type(row.label) == "string" and row.label:find("menu.llm.api_add_entry", 1, true) then
				action = row.items[1].action
			end
		end
		return action, ctx, remote, observed, entry, notices
	end
	local BridgeFixture = require("tests.support.llm_bridge_fixture")
	for _, provider_id in ipairs({ "openai", "openai_compat" }) do
		helpers.it("publishes accepted API fields through real quarantined cleanup " .. provider_id .. " (api-add-quarantined-config)", function()
			helpers.with_fresh_modules(owned, function()
				BridgeFixture.with_bridge_fixture(function(f)
					local action, ctx, remote, observed, entry = install_add(provider_id)
					local resets, inference = 0, 0
					f.engine.perform_check = function() inference = inference + 1 end
					f.engine.start_timer = function() inference = inference + 1 end
					f.engine.reset = function() resets = resets + 1; return true end
					ctx.keymap.reset_predictions = f.bridge.reset_predictions
					ctx.keymap.reset_predictions_for_configuration = f.bridge.reset_quarantined_context
					f.bridge.set_runtime_quarantined(true)
					helpers.assert_eq(f.bridge.is_runtime_available(), false)
					action()
					helpers.assert_eq(observed.prompts, 3)
					helpers.assert_eq(resets, 1, "configuration must retire the real prediction owner")
					helpers.assert_eq(observed.probes, 1, "all accepted fields reach the exact validation owner")
					helpers.assert_eq(observed.writes, 1, "the accepted validation must enter persistence")
					helpers.assert_eq(#remote.get_entries(), 2)
					helpers.assert_eq(remote.get_entries()[1], entry)
					helpers.assert_eq(remote.get_entries()[2].token, "inert-new-secret")
					helpers.assert_eq(remote.get_entries()[2].provider, provider_id)
					helpers.assert_eq(remote.get_entries()[2].base_url, "http://127.0.0.1:8000/v1")
					helpers.assert_eq(ctx.state.llm_model, "new-model")
					helpers.assert_eq(f.bridge.is_runtime_available(), false,
						"configuration cleanup must never reopen quarantined inference")
					helpers.assert_eq(inference, 0, "configuration cleanup cannot start document inference")
				end)
			end)
		end)
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("reports exact API configuration cleanup " .. mode .. " " .. provider_id .. " (api-add-quarantined-config)", function()
				helpers.with_fresh_modules(owned, function()
					BridgeFixture.with_bridge_fixture(function(f)
						local action, ctx, remote, observed, entry, notices = install_add(provider_id)
						f.engine.reset = function()
							if mode == "throw" then error("inert cleanup refusal") end
							if mode == "false" then return false end
						end
						ctx.keymap.reset_predictions = f.bridge.reset_predictions
						ctx.keymap.reset_predictions_for_configuration = f.bridge.reset_quarantined_context
						f.bridge.set_runtime_quarantined(true)
						helpers.assert_eq(action(), false)
						helpers.assert_eq(observed.prompts, 3)
						helpers.assert_eq(observed.probes, 0)
						helpers.assert_eq(observed.writes, 0)
						helpers.assert_eq(#remote.get_entries(), 1)
						helpers.assert_eq(remote.get_entries()[1], entry)
						helpers.assert_eq(remote.get_active_entry_id(), entry.id)
						helpers.assert_eq(#notices, 1, "operational refusal must be visible")
						helpers.assert_eq(notices[1].level, "error")
						helpers.assert_eq(f.bridge.is_runtime_available(), false)
					end)
				end)
			end)
		end

	end

	for _, provider_id in ipairs({ "openai", "openai_compat" }) do
		helpers.it("accepts explicit keyless loopback through " .. provider_id .. " Add (api-add-local-keyless)", function()
			helpers.with_fresh_modules(owned, function()
				local action, _, remote, observed = install_add(provider_id)
				observed.token = ""
				action()
				helpers.assert_eq(observed.prompts, 3, "an absent local key must still collect the user's model")
				helpers.assert_eq(observed.probes, 1, "keyless local credentials still require a real availability verdict")
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(#remote.get_entries(), 2)
				helpers.assert_eq(remote.get_entries()[2].token, "")
				helpers.assert_eq(remote.get_entries()[2].base_url, "http://127.0.0.1:8000/v1")
				helpers.assert_eq(remote.get_entries()[2].provider, provider_id)
			end)
		end)
	end

	for _, provider_id in ipairs({ "openai", "openai_compat" }) do
		helpers.it("reports a missing remote key through " .. provider_id .. " Add (api-add-local-keyless)", function()
			helpers.with_fresh_modules(owned, function()
				local action, ctx, remote, observed, entry, notices = install_add(provider_id)
				observed.token = ""
				observed.endpoint = "https://remote.example.invalid/v1"
				helpers.assert_eq(action(), false)
				helpers.assert_eq(observed.prompts, 2)
				helpers.assert_eq(observed.probes, 0)
				helpers.assert_eq(observed.writes, 0)
				helpers.assert_eq(#remote.get_entries(), 1)
				helpers.assert_eq(remote.get_entries()[1], entry)
				helpers.assert_eq(remote.get_active_entry_id(), entry.id)
				helpers.assert_eq(ctx.state.llm_model, "probe-model")
				helpers.assert_eq(#notices, 1, "missing remote authentication must never silently disappear")
				helpers.assert_eq(notices[1].level, "error")
			end)
		end)
	end

	local function assert_no_staging(ctx, remote, observed, entry)
		helpers.assert_eq(observed.resets, 0, "no prediction owner is reset")
		helpers.assert_eq(observed.writes, 0, "no Keychain publication owner is entered")
		helpers.assert_eq(observed.probes, 0, "no request owner is acquired")
		helpers.assert_eq(#remote.get_entries(), 1)
		helpers.assert_eq(remote.get_entries()[1], entry, "original record and secret identity remain exact")
		helpers.assert_eq(remote.get_active_entry_id(), entry.id)
		helpers.assert_eq(ctx.state.llm_model, "probe-model")
	end
	for _, provider_id in ipairs({ "openai", "openai_compat" }) do
		for field = 1, 3 do
			for _, boundary in ipairs({ "cancel", "pause" }) do
				helpers.it("preserves " .. provider_id .. " Add after " .. boundary .. " at field " .. field
					.. " (api-add-native-field-custody)", function()
					helpers.with_fresh_modules(owned, function()
						local action, ctx, remote, observed, entry, notices = install_add(provider_id)
						if boundary == "cancel" then observed.cancel_at = field
						else observed.on_prompt = function(index) if index == field then observed.paused = true end end end
						helpers.assert_eq(action(), false)
						helpers.assert_eq(observed.prompts, field)
						assert_no_staging(ctx, remote, observed, entry)
						helpers.assert_eq(#notices, 0, "cancellation cannot invent an operational error")
					end)
				end)
			end
		end
	end
	for _, fault in ipairs({ "paused", "missing", "nil", "number", "table", "throw", "backend" }) do
		helpers.it("refuses retained Add before a prompt after native admission becomes " .. fault, function()
			helpers.with_fresh_modules(owned, function()
				local action, ctx, remote, observed, entry = install_add()
				if fault == "paused" then observed.paused = true
				elseif fault == "missing" then ctx.is_paused = nil
				elseif fault == "backend" then ctx.state.llm_backend = "ollama"
				else ctx.is_paused = function()
					if fault == "nil" then return nil end
					if fault == "number" then return 0 end
					if fault == "table" then return {} end
					error("inert native pause refusal")
				end end
				local result = action()
				helpers.assert_eq(observed.prompts, 0)
				assert_no_staging(ctx, remote, observed, entry)
				helpers.assert_eq(result, false)
			end)
		end)
	end
	for revoked_at = 1, 3 do
		helpers.it("rechecks native pause after accepted Add field " .. revoked_at, function()
			helpers.with_fresh_modules(owned, function()
				local action, ctx, remote, observed, entry = install_add()
				observed.on_prompt = function(index) if index == revoked_at then observed.paused = true end end
				local result = action()
				assert_no_staging(ctx, remote, observed, entry)
				helpers.assert_eq(observed.prompts, revoked_at)
				helpers.assert_eq(result, false)
			end)
		end)
	end
	for cancelled_at = 1, 3 do
		helpers.it("keeps cancellation before Add field " .. cancelled_at .. " free of native staging", function()
			helpers.with_fresh_modules(owned, function()
				local action, ctx, remote, observed, entry = install_add()
				observed.cancel_at = cancelled_at
				local result = action()
				helpers.assert_eq(result, false)
				helpers.assert_eq(observed.prompts, cancelled_at)
				assert_no_staging(ctx, remote, observed, entry)
			end)
		end)
	end
	for _, format in ipairs({ "openai", "decisions" }) do
		helpers.it("rechecks Add after the native reset ACK for " .. format, function()
			helpers.with_fresh_modules(owned, function()
				local action, ctx, remote, observed, entry = install_add()
				remote.PROVIDERS.openai.format = format
				remote.test_request = function() observed.probes = observed.probes + 1; return true end
				ctx.keymap.reset_predictions_for_configuration = function()
					observed.resets = observed.resets + 1
					observed.paused = true
					return true
				end
				local result = action()
				helpers.assert_eq(observed.probes, 0)
				helpers.assert_eq(observed.writes, 0)
				helpers.assert_eq(observed.resets, 1, "the exact native reset ACK occurred before revocation")
				helpers.assert_eq(result, false)
				helpers.assert_eq(#remote.get_entries(), 1)
				helpers.assert_eq(remote.get_entries()[1], entry)
				helpers.assert_eq(remote.get_active_entry_id(), entry.id)
				helpers.assert_eq(ctx.state.llm_model, "probe-model")
			end)
		end)
	end
	helpers.it("refuses an accepted provider prompt after the visible backend changes", function()
		helpers.with_fresh_modules(owned, function()
			local action, ctx, remote, observed, entry = install_add()
			observed.on_prompt = function() ctx.state.llm_backend = "ollama" end
			local result = action()
			assert_no_staging(ctx, remote, observed, entry)
			helpers.assert_eq(observed.prompts, 1)
			helpers.assert_eq(result, false)
			helpers.assert_eq(ctx.state.llm_backend, "ollama", "the new backend remains owned by its existing setter")
		end)
	end)
	helpers.it("keeps the admitted Add validation and publication callback ABI", function()
		helpers.with_fresh_modules(owned, function()
			local action, ctx, remote, observed, entry = install_add()
			action()
			helpers.assert_eq(observed.prompts, 3)
			helpers.assert_eq(observed.resets, 1)
			helpers.assert_eq(observed.probes, 1)
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(remote.get_entries()[1], entry)
			helpers.assert_eq(#remote.get_entries(), 2)
			helpers.assert_eq(remote.get_entries()[2].token, "inert-new-secret")
			helpers.assert_eq(ctx.state.llm_model, "new-model")
		end)
	end)
end)


--- Loads the hand-authored API Add contract from physical shared data.
local function api_add_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/api_add_controls.json", "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

--- Holds the genuine translator/backend/renderer cohort without persisting a locale.

--- Retains the native collaborators while injecting the genuine English translator.
local function install_api_add_doubles(args, native)
	install_doubles(args)
	package.loaded["infra.i18n"] = native
	local renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
		json_decode = require("adapters.json_codec").decode,
		i18n = native,
		logger = helpers.make_logger_stub(),
	}))
	package.loaded["infra.manifest_menu"] = {
		command_row = renderer.command_row, template_rows = renderer.template_rows,
		get_array = renderer.get_array, render_rows = function(rows) return rows end,
	}
end

helpers.describe("Shared API Add frame (api-add-controls)", function()
	local owned = { "modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
		"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel" }
	helpers.it("uses the shared Add label and retains the genuine provider action (api-add-controls)", function()
		helpers.with_fresh_modules(owned, function()
			with_api_add_locale(function(native)
			local corpus = api_add_corpus()
			install_api_add_doubles({ entries = {}, active_id = "" }, native)
			local menu = package.loaded["infra.manifest_menu"]
			local declaration = menu.get_array(corpus.group_section)[1]
			local original = declaration.i18n
			local panel = require("ui.menu.menu_llm.api_panel")
			local observations
			local ok, err = pcall(function()
				local _, rows = panel.build(fixture_context())
				helpers.assert_eq(rows[1].label, corpus.mac_decoration .. corpus.label)
				helpers.assert_type(rows[1].items[1].action, "function")
				declaration.i18n = corpus.mutated_key
				_, rows = panel.build(fixture_context())
				observations = rows[1]
			end)
			declaration.i18n = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(observations.label, corpus.mac_decoration .. corpus.mutated_label)
			helpers.assert_eq(observations.disabled, nil)
			helpers.assert_type(observations.items[1].action, "function")
			end)
		end)
	end)
	helpers.it("uses the conditional separator declaration and preserves native pause (api-add-controls)", function()
		helpers.with_fresh_modules(owned, function()
			with_api_add_locale(function(native)
			local corpus = api_add_corpus()
			local entry = { id = "prod", provider = "openai", token = "inert", model = "probe" }
			install_api_add_doubles({ entries = { entry }, active_id = "prod" }, native)
			local menu = package.loaded["infra.manifest_menu"]
			local declaration = menu.get_array(corpus.separator_section)
			local original = declaration[1]
			local panel = require("ui.menu.menu_llm.api_panel")
			local observations
			local ok, err = pcall(function()
				declaration[1] = { type = "label", id = "api_add_marker", i18n = corpus.mutated_key }
				local _, rows = panel.build(fixture_context())
				local position
				for index, row in ipairs(rows) do if row.label == corpus.mac_decoration .. corpus.label then position = index end end
				helpers.assert_type(position, "number")
				observations = rows[position + 1]
				local context = fixture_context(); context.paused = true
				_, rows = panel.build(context)
				helpers.assert_eq(rows[position].disabled, true)
				helpers.assert_nil(rows[position].items[1].action, "native paused provider has no action")
			end)
			declaration[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(observations.label, corpus.mutated_label)
			helpers.assert_eq(observations.disabled, true)
			helpers.assert_nil(observations.action)
			package.loaded["modules.llm"].api_remote.set_entries({})
			local _, rows = panel.build(fixture_context())
			for _, row in ipairs(rows) do helpers.assert_nil(row.separator, "empty entries keep no dangling Add separator") end
			end)
		end)
	end)
end)

helpers.describe("API Add locale scope failure inverse (api-add-controls)", function()
	helpers.it("restores the actual prior locale cohort after a raised case (api-add-controls)", function()
		local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local raised = {}
		local ok, err = pcall(function()
			with_api_add_locale(function(native)
				helpers.assert_eq(native.get("menu.llm.api_add_entry"), "+ Add an API")
				error(raised, 0)
			end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(rawequal(err, raised), true)
		for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], previous[name]), true, name) end
	end)
end)
