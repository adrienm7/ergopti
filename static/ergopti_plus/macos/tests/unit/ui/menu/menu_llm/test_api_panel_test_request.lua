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
	package.loaded["infra.manifest_menu"] = {
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
			helpers.assert_true(notifications[1].body:find("Prod", 1, true) ~= nil,
				"the success body must name the entry")
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
			helpers.assert_true(notifications[1].body:find("Prod", 1, true) ~= nil)
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

	helpers.it("reports the active API entry display model", function()
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
			helpers.assert_true(type(panel.active_entry_display_model) == "function",
				"the panel must expose the entry display model")
			helpers.assert_eq(panel.active_entry_display_model(), "probe-model",
				"the row shows the entry model, never the local slot")
			entry.model = ""
			helpers.assert_eq(panel.active_entry_display_model(), "openai-default",
				"an entry without model falls back to the provider default")
			entry.id = "ghost"
			helpers.assert_true(panel.active_entry_display_model() == nil,
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
