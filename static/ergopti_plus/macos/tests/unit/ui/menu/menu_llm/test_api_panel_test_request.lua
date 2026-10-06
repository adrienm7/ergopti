--- tests/unit/ui/menu/menu_llm/test_api_panel_test_request.lua

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


local function fixture_context()
	return {
		state = { llm_backend = "api", llm_model = "probe-model" },
		paused = false,
		is_paused = function() return false end,
		keymap = { reset_predictions = function() return true end },
		update_menu = function() end,
		WarmupCtrl = { warmup = function() end },
	}
end

local function install_doubles(args)
	local entries = args.entries
	local active_id = args.active_id
	local spec = args.spec
	local calls = {}
	local 	api_remote = {
		PROVIDER_ORDER = { "openai" },
		PROVIDERS = {
			openai = { label = "OpenAI", default_model = "openai-default" },
		},
		get_entries = function() return entries end,
		set_entries = function(value) entries = value end,
		get_active_entry_id = function() return active_id end,
		set_active_entry_id = function(value) active_id = value end,
		get_active_entry = function()
			for _, entry in ipairs(entries) do
				if entry.id == active_id then return entry end
			end
			return nil
		end,
		get_test_request_spec = function() return spec end,
		test_request = function(entry, request_spec, on_ok, on_fail)
			calls[#calls + 1] = {
				entry = entry, spec = request_spec,
				on_ok = on_ok, on_fail = on_fail,
			}
			return true
		end,
	}
	package.loaded["modules.llm"] = { api_remote = api_remote }
	-- The two body templates mirror the en.json shapes so the substitution
	-- wiring is exercised; every other key echoes itself.
	package.loaded["infra.i18n"] = { get = function(key)
		if args.locale_strings then return args.locale_strings[key] or key end
		if key == "menu.llm.api_test_ok_body" then
			return '"{1}" answered in {2} ms: {3}'
		end
		if key == "menu.llm.api_unreachable_body" then
			return '"%s" did not respond'
		end
		return key
	end }
	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function() end,
	}
	package.loaded["infra.dialog_util"] = {}
	local notifications = {}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, level)
			notifications[#notifications + 1] = {
				title = title, body = body, level = level,
			}
			return true
		end,
	}
	local command_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
		json_decode = require("adapters.json_codec").decode,
		i18n = {
			get = package.loaded["infra.i18n"].get,
			-- These command rows never request a translated section.
			section = function() return {} end,
		},
		logger = helpers.make_logger_stub(),
	}))
	package.loaded["infra.manifest_menu"] = {
		command_row = command_renderer.command_row,
		template_rows = command_renderer.template_rows,
		get_array = command_renderer.get_array,
		render_rows = function(rows) return rows end,
	}
	package.loaded["ui.menu.menu_llm.api_panel"] = nil
	return api_remote, calls, notifications
end

local function test_row(rows)
	for _, row in ipairs(rows) do
		if row.label == "menu.llm.api_test_entry" then return row end
	end
	return nil
end


helpers.describe("API panel test request", function()

	helpers.it("dispatches the shared probe to the active entry", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			local _, calls, _ = install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			local row = test_row(rows)
			helpers.assert_not_nil(row, "the entries menu must offer a test row")
			helpers.assert_eq(row.disabled, nil, "the row stays live with an active entry")
			helpers.assert_type(row.action, "function")
			helpers.assert_true(row.action())
			helpers.assert_eq(#calls, 1, "exactly one probe must dispatch")
			helpers.assert_eq(calls[1].entry.id, "prod")
			helpers.assert_eq(calls[1].entry.token, "live-secret",
				"the probe authenticates with the entry token")
			helpers.assert_true(calls[1].spec == spec,
				"the probe travels with the shared spec object, not a restatement")
		end)
	end)

	helpers.it("notifies reply excerpt and latency on success", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			local _, calls, notifications = install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			test_row(rows).action()
			helpers.assert_eq(#calls, 1)
			calls[1].on_ok("OK", 42)
			helpers.assert_eq(#notifications, 1, "one success notification must surface")
			helpers.assert_eq(notifications[1].title, "menu.llm.api_test_ok_title")
			helpers.assert_true(notifications[1].body:find("openai/probe-model", 1, true) ~= nil,
				"the success body must name the entry automatically")
			helpers.assert_true(notifications[1].body:find("Prod", 1, true) == nil,
				"the label an earlier build stored is never shown")
			helpers.assert_true(notifications[1].body:find("42", 1, true) ~= nil,
				"the success body must carry the latency")
			helpers.assert_true(notifications[1].body:find("OK", 1, true) ~= nil,
				"the success body must carry the reply excerpt")
			helpers.assert_true(notifications[1].body:find("live-secret", 1, true) == nil,
				"the token must never reach a notification")
			helpers.assert_eq(notifications[1].level, "success")
		end)
	end)

	helpers.it("notifies failure without the token", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			local _, calls, notifications = install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			test_row(rows).action()
			calls[1].on_fail("request_failed")
			helpers.assert_eq(#notifications, 1, "one failure notification must surface")
			helpers.assert_eq(notifications[1].title, "menu.llm.api_unreachable_title")
			helpers.assert_true(notifications[1].body:find("openai/probe-model", 1, true) ~= nil,
				"the failure body names the entry automatically")
			helpers.assert_true(notifications[1].body:find("live-secret", 1, true) == nil,
				"the token must never reach a notification")
			helpers.assert_eq(notifications[1].level, "error")
		end)
	end)

	helpers.it("appends the server verdict to the failure notification", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			local _, calls, notifications = install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			test_row(rows).action()
			calls[1].on_fail("request_failed",
				{ status = 402, message = "Payment required to access this resource." })
			helpers.assert_eq(#notifications, 1, "one failure notification must surface")
			helpers.assert_eq(notifications[1].level, "error")
			helpers.assert_true(notifications[1].body:find("402", 1, true) ~= nil,
				"the failure body must carry the server status")
			helpers.assert_true(notifications[1].body:find("Payment required", 1, true) ~= nil,
				"the failure body must carry the server message")
			helpers.assert_true(notifications[1].body:find("live-secret", 1, true) == nil,
				"the token must never reach a notification")
		end)
	end)

	helpers.it("reports the active API entry display name", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			helpers.assert_true(type(panel.active_entry_display_name) == "function",
				"the panel must expose the entry display name")
			helpers.assert_eq(panel.active_entry_display_name(), "openai/probe-model",
				"the row shows the automatic name, never the label an earlier build stored")
			entry.label = nil
			helpers.assert_eq(panel.active_entry_display_name(), "openai/probe-model",
				"an entry without a stored label reads the same")
			entry.model = ""
			helpers.assert_eq(panel.active_entry_display_name(), "openai/openai-default",
				"an entry without a model is named after the provider default")
			entry.id = "ghost"
			helpers.assert_true(panel.active_entry_display_name() == nil,
				"an unknown entry never resurrects a stale model")
		end)
	end)

	helpers.it("lists Add before the separator", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			local add_at, sep_at = 0, 0
			for i, row in ipairs(rows) do
				if type(row.label) == "string"
					and row.label:find("menu.llm.api_add_entry", 1, true) ~= nil
					and add_at == 0 then
					add_at = i
				end
				if row.separator and sep_at == 0 then sep_at = i end
			end
			helpers.assert_true(add_at > 0, "the Add row must exist with entries present")
			helpers.assert_true(sep_at > add_at,
				"the Add row must sit before the separator")
		end)
	end)

	helpers.it("lists Test before Remove, Delete last", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			install_doubles({
				entries = { entry }, active_id = "prod", spec = spec,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			local pos = {}
			for i, row in ipairs(rows) do
				if type(row.label) == "string" then
					for _, key in ipairs({ "api_test_entry", "api_remove_entry" }) do
						if row.label:find(key, 1, true) ~= nil and pos[key] == nil then
							pos[key] = i
						end
					end
				end
			end
			helpers.assert_true(pos.api_test_entry ~= nil, "the Test row must exist")
			helpers.assert_true(pos.api_remove_entry ~= nil, "the Remove row must exist")
			helpers.assert_true(pos.api_test_entry < pos.api_remove_entry,
				"Test must come before Delete (destructive last)")
		end)
	end)

	helpers.it("discards a stale completion after entry switch", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local first = {
				id = "first", provider = "openai", token = "secret-a",
				model = "model-a", label = "First",
				base_url = "https://api.example.invalid/v1",
			}
			local second = {
				id = "second", provider = "openai", token = "secret-b",
				model = "model-b", label = "Second",
				base_url = "https://api.example.invalid/v1",
			}
			local spec = {
				system_prompt = "probe sys", user_text = "ping",
				temperature = 0, max_tokens = 16,
			}
			local _, calls, notifications = install_doubles({
				entries = { first, second }, active_id = "first", spec = spec,
			})
			local api_remote = package.loaded["modules.llm"].api_remote
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			test_row(rows).action()
			helpers.assert_eq(#calls, 1)
			api_remote.set_active_entry_id("second")
			calls[1].on_ok("OK", 9)
			helpers.assert_eq(#notifications, 0,
				"a completion for a deselected entry must stay silent")
			api_remote.set_entries({ second })
			calls[1].on_ok("OK", 9)
			helpers.assert_eq(#notifications, 0,
				"a completion for a deleted entry must stay silent")
		end)
	end)

	-- api-entry-auto-name: every row names its entry <provider>/<model>, the
	-- label a user typed in an earlier build is not read, and two entries of
	-- one provider and model read apart by their host.
	helpers.it("names every entry after its provider and model (api-entry-auto-name)", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local entries = {
				{ id = "a", provider = "openai", token = "t-a", model = "m1", label = "Ma clé",
					base_url = "https://api.example.invalid/v1" },
				{ id = "b", provider = "openai", token = "t-b", model = "m1", label = "Autre",
					base_url = "http://localhost:8080/v1" },
				{ id = "c", provider = "openai", token = "t-c", model = "m2", label = "Troisième" },
			}
			install_doubles({ entries = entries, active_id = "a", spec = nil })
			local panel = require("ui.menu.menu_llm.api_panel")
			local expected = { "openai/m1 (api.example.invalid)", "openai/m1 (localhost:8080)", "openai/m2" }
			local title, rows = panel.build(fixture_context())
			for index, name in ipairs(expected) do
				helpers.assert_eq(rows[index].label, name, "entry row " .. index)
			end
			helpers.assert_eq(title, "API — openai/m1 (api.example.invalid)",
				"the parent row names the active entry without repeating its provider")
			local picker = panel.build_model_picker(fixture_context())
			for index, name in ipairs(expected) do
				-- The picker opens with « No model » and a separator
				helpers.assert_eq(picker[index + 2].label, name, "picker row " .. index)
			end
			helpers.assert_eq(panel.active_entry_display_name(), expected[1])
		end)
	end)

	helpers.it("disables the row with no active entry and refuses without a spec", function()
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local _, calls, notifications = install_doubles({
				entries = {}, active_id = "", spec = nil,
			})
			local panel = require("ui.menu.menu_llm.api_panel")
			local _, rows = panel.build(fixture_context())
			local row = test_row(rows)
			helpers.assert_not_nil(row, "the test row is still listed with no entries")
			helpers.assert_true(row.disabled ~= nil, "the row is disabled with no active entry")
			helpers.assert_true(row.action == nil, "a disabled row carries no action")

			local entry = {
				id = "prod", provider = "openai", token = "live-secret",
				model = "probe-model", label = "Prod",
				base_url = "https://api.example.invalid/v1",
			}
			local _, calls2, notifications2 = install_doubles({
				entries = { entry }, active_id = "prod", spec = nil,
			})
			-- The panel captures its llm module at require time, so re-require
			-- it against the second double like a fresh menu build would.
			package.loaded["ui.menu.menu_llm.api_panel"] = nil
			panel = require("ui.menu.menu_llm.api_panel")
			local _, rows2 = panel.build(fixture_context())
			local row2 = test_row(rows2)
			helpers.assert_type(row2.action, "function")
			helpers.assert_eq(row2.action(), false,
				"a missing shared spec refuses before dispatching")
			helpers.assert_eq(#calls2, 0, "nothing may reach the wire without the shared spec")
			helpers.assert_eq(#notifications2, 1)
			helpers.assert_eq(notifications2[1].level, "error")
		end)
	end)

end)

helpers.describe("Active API commands: canonical labels and retained owner", function()
	local owned = { "modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
		"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel" }
	for _, locale in ipairs({ "ar", "da", "de", "en", "es", "cs", "fr", "he", "hi", "it",
		"ja", "ko", "no", "nl", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("uses the actual shared active commands in " .. locale, function()
			helpers.with_fresh_modules(owned, function()
				local file = assert(io.open(helpers.driver_root() .. "../_shared/data/locales/" .. locale .. ".json", "rb"))
				local raw = file:read("*a"); assert(file:close())
				local labels = require("adapters.json_codec").decode(raw)
				local entry = { id = "chosen", provider = "openai", model = "test-model", token = "inert" }
				install_doubles({ entries = { entry }, active_id = entry.id, spec = {}, locale_strings = labels })
				local declaration = package.loaded["infra.manifest_menu"].get_array("llm_api_active_commands")
				-- A real shared-data change must reach the actual provider, not its old hardcoded caption.
				declaration[1].i18n = "button.cancel"
				local _, rows = require("ui.menu.menu_llm.api_panel").build(fixture_context())
				local positions = {}
				for index, row in ipairs(rows) do
					if row.label == labels["button.cancel"] then positions[1] = index end
					if type(row.label) == "string" and row.label:find(labels["menu.llm.api_remove_entry"], 1, true) then positions[2] = index end
				end
				helpers.assert_type(positions[1], "number")
				helpers.assert_eq(positions[2], positions[1] + 1, "the shared Test/Remove ordering is native")
				helpers.assert_type(rows[positions[1]].action, "function")
				helpers.assert_type(rows[positions[2]].action, "function")
			end)
		end)
	end
	for _, revoked in ipairs({ "paused", "selection" }) do
		helpers.it("a retained Test refuses a revoked " .. revoked .. " owner before request creation", function()
			helpers.with_fresh_modules(owned, function()
				local entry = { id = "chosen", provider = "openai", model = "test-model", token = "inert" }
				local remote, calls = install_doubles({ entries = { entry }, active_id = entry.id, spec = {} })
				local ctx = fixture_context()
				local live_paused = false
				ctx.is_paused = function() return live_paused end
				local _, rows = require("ui.menu.menu_llm.api_panel").build(ctx)
				local held = test_row(rows).action
				if revoked == "paused" then live_paused = true else remote.set_active_entry_id("other") end
				local observed = held()
				helpers.assert_eq(observed, false)
				helpers.assert_eq(#calls, 0, "no stale HTTP owner is acquired")
				helpers.assert_eq(remote.get_entries()[1], entry, "the secret/entry record remains untouched")
			end)
		end)
	end
end)

helpers.describe("Active API commands: strict native pause receipt", function()
	local owned = { "modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
		"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel" }
	for _, fault in ipairs({ "missing", "nil", "number", "table", "throw" }) do
		helpers.it("refuses a retained request after the native pause reader becomes " .. fault, function()
			helpers.with_fresh_modules(owned, function()
				local entry = { id = "chosen", provider = "openai", model = "test-model", token = "inert" }
				local _, calls = install_doubles({ entries = { entry }, active_id = entry.id, spec = {} })
				local ctx, failed = fixture_context(), false
				ctx.is_paused = function()
					if not failed then return false end
					if fault == "nil" then return nil end
					if fault == "number" then return 0 end
					if fault == "table" then return {} end
					if fault == "throw" then error("inert native pause-read refusal") end
				end
				local _, rows = require("ui.menu.menu_llm.api_panel").build(ctx)
				local held = test_row(rows).action
				failed = true
				if fault == "missing" then ctx.is_paused = nil end
				local observed = held()
				helpers.assert_eq(observed, false)
				helpers.assert_eq(#calls, 0)
			end)
		end)
	end
	helpers.it("rechecks native pause after confirmation before reset, entry mutation or persistence", function()
		helpers.with_fresh_modules(owned, function()
			local entry = { id = "chosen", provider = "openai", model = "test-model", token = "inert" }
			local remote = install_doubles({ entries = { entry }, active_id = entry.id, spec = {} })
			local ctx, paused, resets, writes = fixture_context(), false, 0, 0
			ctx.is_paused = function() return paused end
			ctx.keymap.reset_predictions = function() resets = resets + 1; return true end
			package.loaded["modules.llm"].persist_api_entries = function() writes = writes + 1 end
			package.loaded["infra.dialog_util"].block_alert = function(_, _, affirmative)
				paused = true
				return affirmative
			end
			local _, rows = require("ui.menu.menu_llm.api_panel").build(ctx)
			local remove
			for _, row in ipairs(rows) do
				if type(row.label) == "string" and row.label:find("menu.llm.api_remove_entry", 1, true) then remove = row.action end
			end
			local observed = remove()
			helpers.assert_eq(observed, false)
			helpers.assert_eq(resets, 0)
			helpers.assert_eq(writes, 0)
			helpers.assert_eq(remote.get_entries()[1], entry)
			helpers.assert_eq(remote.get_active_entry_id(), entry.id)
		end)
	end)
end)

helpers.describe("API Add: retained native admission", function()
	local owned = { "modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
		"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel" }
	local function install_add()
		local entry = { id = "old", provider = "openai", model = "old-model", token = "inert-old-secret" }
		local remote = install_doubles({ entries = { entry }, active_id = entry.id, spec = {} })
		local ctx = fixture_context()
		local observed = { prompts = 0, resets = 0, writes = 0, probes = 0, paused = false }
		ctx.is_paused = function() return observed.paused end
		ctx.keymap.reset_predictions = function() observed.resets = observed.resets + 1; return true end
		package.loaded["infra.dialog_util"].text_prompt = function(_, _, _, affirmative)
			observed.prompts = observed.prompts + 1
			if observed.on_prompt then observed.on_prompt(observed.prompts) end
			if observed.cancel_at == observed.prompts then return "button.cancel", "" end
			return affirmative, ({ "https://example.invalid/v1", "inert-new-secret", "new-model" })[observed.prompts]
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
		return action, ctx, remote, observed, entry
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
				ctx.keymap.reset_predictions = function()
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
local function with_api_add_locale(scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local native, owner, receipt, acquired
	local ok, err = pcall(function()
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, "en"), true)
		helpers.assert_eq(native.get_locale(), "en")
		helpers.assert_eq(require("infra.locale").current_locale(), "en")
		scenario(native)
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], previous[name]), true, name) end
	helpers.assert_eq(restored, true, "the genuine runtime inverse restores its previous locale")
	helpers.assert_eq(released, true, "the temporary locale owner is released on every exit")
	helpers.assert_eq(forgotten, true, "the temporary locale receipt is forgotten on every exit")
	if not ok then error(err, 0) end
end

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
