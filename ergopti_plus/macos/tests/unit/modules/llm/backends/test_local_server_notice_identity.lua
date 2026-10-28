--- tests/unit/modules/llm/backends/test_local_server_notice_identity.lua

--- ==============================================================================
--- MODULE: Local Server Notification Identity
--- DESCRIPTION:
--- Drives real panel, remote-entry and persistence admission through the existing
--- owned backend fixture. Native notification delivery and dialogs are controlled;
--- no request reaches a real server and no native notification or dialog is shown.
--- ==============================================================================

local helpers = require("tests.helpers")
local FIXTURE = "tests.support.modules.llm.backends.local_openai_backends_fixture"

-- The backend also imports its optional keystats parent at require time. Own
-- that real consumer tree, shared policies and direct injections with the panel;
-- load_with_stubs separately tracks every cache write made by the loader.
local OWNED_MODULES = {
	"_generated.logger_sub_files",
	"adapters.crypto",
	"adapters.event_clock",
	"adapters.event_provenance",
	"adapters.file_system",
	"adapters.http_client",
	"adapters.input_source_broker",
	"adapters.json_codec",
	"adapters.keyboard_hook",
	"adapters.ledger_append",
	"adapters.log_transport",
	"adapters.process_lifecycle",
	"adapters.running_application",
	"adapters.secure_field_detector",
	"adapters.shell_runner",
	"adapters.storage",
	"adapters.synthetic_input",
	"adapters.task_environment",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"app_dirs",
	"compat.utf8",
	"config_defaults",
	"diagnostics.operation_reporter",
	"diagnostics.redact",
	"diagnostics.runtime_log",
	"error_description",
	"hotstrings.personal_files",
	"infra.config_paths",
	"infra.deferred_work",
	"infra.dialog_util",
	"infra.fs_dir",
	"infra.launcher_environment",
	"infra.log_folders",
	"infra.logger",
	"infra.manifest_menu",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.teardown_transaction",
	"infra.text_utils",
	"infra.timings",
	"infra.toml.reader",
	"json",
	"keystats.aggregator_helpers",
	"keystats.media_identity",
	"keystats.media_store",
	"keystats.metrics",
	"keystats.physical_lifecycle_observation",
	"keystats.physical_release",
	"keystats.private_window",
	"keystats.text_crypto",
	"keystats.text_migration",
	"keystats.utils",
	"llm.api_entry_identity",
	"llm.api_entry_names",
	"llm.local_server_auth",
	"llm.local_server_discovery",
	"llm.local_server_menu",
	"llm.parser",
	"llm.profile_selector",
	"llm.prompt_builder",
	"llm.provider_config_policy",
	"llm.remote_formats",
	"logger",
	"logger.shim",
	"menu.renderer",
	"modules.keystats",
	"modules.keystats.aggregator",
	"modules.keystats.aggregator.core",
	"modules.keystats.aggregator.events",
	"modules.keystats.aggregator.physical",
	"modules.keystats.aggregator.sql",
	"modules.keystats.aggregator.state",
	"modules.keystats.context_tracker",
	"modules.keystats.export",
	"modules.keystats.ingest_trace",
	"modules.keystats.kc_bridge",
	"modules.keystats.log_manager",
	"modules.keystats.physical_accounting_mode",
	"modules.keystats.physical_wire",
	"modules.keystats.privacy_context",
	"modules.keystats.rotation",
	"modules.keystats.sqlite_writer",
	"modules.keystats.text_cipher",
	"modules.keystats.timestamp",
	"modules.keystats.watchers",
	"modules.llm",
	"modules.llm.api_common",
	"modules.llm.api_remote",
	"modules.llm.api_token_crypto",
	"modules.llm.local_servers",
	"modules.llm.parser",
	"modules.llm.profiles",
	"modules.llm.progressive_reveal",
	"modules.llm.provider_uses",
	"modules.llm.remote_response_classifier",
	"native_path",
	"number_policy",
	"platform.remap.lease_helper",
	"sqlite.literal",
	FIXTURE,
	"text_utils",
	"toml_codec.basic_string",
	"toml_codec.bom",
	"toml_codec.key_path",
	"toml_codec.reader",
	"toml_codec.record_scanner",
	"toml_codec.source_open",
	"ui.menu.menu_llm.api_panel",
	"ui.menu.menu_llm.local_server_panel",
	"window_titles",
}

--- Installs one original entry and the normal public menu failure handler.
--- @param scenario function Receives fixture, panel, API, server owner, ports and context.
local function with_notice(scenario)
	helpers.with_stub_scope(OWNED_MODULES, function()
		local fixture = require(FIXTURE)
		fixture.with_panel(function(panel, api, servers, world, ctx)
			api.set_entries({ { id = "original", provider = "omlx", base_url = "", token = "", model = "missing" } })
			api.set_active_entry_id("original")
			panel.rows(ctx)
			fixture.answer_sweep(world, { omlx = fixture.models_answer({ "replacement" }) })
			scenario(fixture, panel, api, servers, world, ctx)
		end)
	end)
end

--- Replaces a normal menu build's context without changing the native entry.
--- @param panel table Real menu panel.
--- @param ctx table Original menu context.
local function replace_context(panel, ctx)
	local successor = {}
	for key, value in pairs(ctx) do successor[key] = value end
	panel.rows(successor)
end

helpers.describe("local server notifications retain their originating view (local-notice-identity)", function()
	for _, status in ipairs({ 401, 404, 0 }) do
		for _, transition in ipairs({ "entries", "context" }) do
			helpers.it("refuses retained HTTP " .. status .. " click after " .. transition .. " replacement", function()
				with_notice(function(_, panel, api, servers, world, ctx)
					servers.report_failure("omlx", status, "owned fixture failure", "missing")
					local notice = world.notices[#world.notices]
					helpers.assert_type(notice and notice.on_click, "function")
					if transition == "entries" then
						api.set_entries({ { id = "successor", provider = "omlx", base_url = "",
							token = "successor-token", model = "successor-model" } })
						api.set_active_entry_id("successor")
					else
						replace_context(panel, ctx)
					end
					local probes = #world.probes
					world.dialog_answer = { "OK", "obsolete-choice" }
					notice.on_click()
					helpers.assert_eq(world.last_default, nil, "a stale notice must acquire no prompt")
					helpers.assert_eq(#world.probes, probes, "a stale notice must acquire no rescan")
					helpers.assert_eq(world.persists, 0, "a stale notice must publish no entry mutation")
					local entry = api.get_active_entry()
					helpers.assert_eq(entry.model, transition == "entries" and "successor-model" or "missing")
					helpers.assert_eq(entry.token, transition == "entries" and "successor-token" or "")
				end)
			end)
		end
	end

	helpers.it("a current key notice still stores the explicitly entered key", function()
		with_notice(function(_, _, api, servers, world)
			servers.report_failure("omlx", 401, "owned fixture refusal", "missing")
			world.dialog_answer = { "OK", "fixture-key" }
			world.notices[#world.notices].on_click()
			helpers.assert_eq(world.last_default, "")
			helpers.assert_eq(world.persists, 1)
			helpers.assert_eq(api.get_active_entry().token, "fixture-key")
		end)
	end)

	helpers.it("a current missing-model notice still replaces the original model", function()
		with_notice(function(fixture, panel, api, servers, world)
			local state, writes = { llm_agent_system1 = "omlx|missing", llm_agent_system2 = "omlx|missing" }, {}
			panel.set_agent_context({ state = state, settings_mgr = {
				apply_setting_transaction = function(request)
					writes[#writes + 1] = { key = request.key, value = request.value }
					state[request.key] = request.value
					return true
				end,
			} })
			servers.report_failure("omlx", 404, "owned fixture missing model", "missing")
			world.dialog_answer = { "OK", "replacement" }
			world.notices[#world.notices].on_click()
			fixture.answer_sweep(world, { omlx = fixture.models_answer({ "replacement" }) })
			helpers.assert_eq(world.last_default, "replacement")
			helpers.assert_eq(world.persists, 1)
			helpers.assert_eq(api.get_active_entry().model, "replacement")
			helpers.assert_eq(writes, {
				{ key = "llm_agent_system1", value = "omlx|replacement" },
				{ key = "llm_agent_system2", value = "omlx|replacement" },
			})
		end)
	end)

	helpers.it("an unrelated agent replacement does not expire a current key notice", function()
		with_notice(function(_, panel, api, servers, world)
			panel.set_agent_context({ state = {} })
			servers.report_failure("omlx", 401, "owned fixture refusal", "missing")
			local notice = world.notices[#world.notices]
			panel.set_agent_context({ state = {} })
			world.dialog_answer = { "OK", "fixture-key" }
			notice.on_click()
			helpers.assert_eq(world.last_default, "")
			helpers.assert_eq(world.persists, 1)
			helpers.assert_eq(api.get_active_entry().token, "fixture-key")
		end)
	end)

	helpers.it("a current stopped-server notice still starts its repair rescan", function()
		with_notice(function(_, _, _, servers, world)
			servers.report_failure("omlx", 0, "owned fixture absent server", "missing")
			local probes = #world.probes
			world.notices[#world.notices].on_click()
			helpers.assert_eq(#world.probes, probes + 4)
		end)
	end)

	helpers.it("a missing-model rescan cannot acquire a prompt for a replaced menu", function()
		with_notice(function(fixture, panel, _, servers, world, ctx)
			servers.report_failure("omlx", 404, "owned fixture missing model", "missing")
			world.notices[#world.notices].on_click()
			replace_context(panel, ctx)
			fixture.answer_sweep(world, { omlx = fixture.models_answer({ "replacement" }) })
			helpers.assert_eq(world.last_default, nil)
			helpers.assert_eq(world.persists, 0)
		end)
	end)

	helpers.it("a model prompt cannot publish after its native entry is replaced", function()
		with_notice(function(fixture, _, api, servers, world)
			servers.report_failure("omlx", 404, "owned fixture missing model", "missing")
			local port = package.loaded["infra.dialog_util"]
			port.text_prompt = function(_, _, _, ok_label)
				api.set_entries({ { id = "successor", provider = "omlx", base_url = "",
					token = "", model = "missing" } })
				api.set_active_entry_id("successor")
				return ok_label, "replacement"
			end
			world.notices[#world.notices].on_click()
			fixture.answer_sweep(world, { omlx = fixture.models_answer({ "replacement" }) })
			helpers.assert_eq(world.persists, 0)
			helpers.assert_eq(api.get_active_entry().id, "successor")
			helpers.assert_eq(api.get_active_entry().model, "missing")
		end)
	end)

	helpers.it("a missing-model notice cannot borrow a replacement agent context", function()
		with_notice(function(_, panel, _, servers, world)
			panel.set_agent_context({ state = { llm_agent_system1 = "omlx|missing" } })
			servers.report_failure("omlx", 404, "owned fixture missing model", "missing")
			local notice = world.notices[#world.notices]
			local writes = 0
			panel.set_agent_context({
				state = { llm_agent_system1 = "omlx|missing" },
				settings_mgr = { apply_setting_transaction = function() writes = writes + 1 end },
			})
			local probes = #world.probes
			notice.on_click()
			helpers.assert_eq(#world.probes, probes, "an obsolete notice acquires no replacement agent repair")
			helpers.assert_eq(world.last_default, nil)
			helpers.assert_eq(world.persists, 0)
			helpers.assert_eq(writes, 0)
		end)
	end)

	for _, stage in ipairs({ "rescan", "prompt" }) do
		helpers.it("the model repair refuses agent replacement during " .. stage, function()
			with_notice(function(fixture, panel, api, servers, world)
				panel.set_agent_context({ state = { llm_agent_system1 = "omlx|missing" } })
				servers.report_failure("omlx", 404, "owned fixture missing model", "missing")
				world.dialog_answer = { "OK", "replacement" }
				local writes = 0
				local function replace_agent()
					panel.set_agent_context({
						state = { llm_agent_system1 = "omlx|missing" },
						settings_mgr = { apply_setting_transaction = function() writes = writes + 1 end },
					})
				end
				if stage == "prompt" then
					package.loaded["infra.dialog_util"].text_prompt = function(_, _, _, ok_label)
						replace_agent()
						return ok_label, "replacement"
					end
				end
				world.notices[#world.notices].on_click()
				if stage == "rescan" then replace_agent() end
				fixture.answer_sweep(world, { omlx = fixture.models_answer({ "replacement" }) })
				helpers.assert_eq(world.persists, 0)
				helpers.assert_eq(api.get_active_entry().model, "missing")
				helpers.assert_eq(writes, 0)
			end)
		end)
	end

	helpers.it("an invalid address from an old row cannot emit a retry for another engine owner", function()
		with_notice(function(_, panel, _, _, world, ctx)
			replace_context(panel, ctx)
			local notices = #world.notices
			world.dialog_answer = { "OK", "not a URL" }
			helpers.assert_eq(panel.prompt_address(ctx, "omlx"), false)
			helpers.assert_eq(#world.notices, notices, "the old prompt must not transfer retry authority")
			helpers.assert_eq(world.persists, 0)
		end)
	end)

	for _, transition in ipairs({ "entries", "context" }) do
		helpers.it("the invalid-address retry refuses " .. transition .. " replacement", function()
			with_notice(function(_, panel, api, _, world, ctx)
				local port = package.loaded["infra.dialog_util"]
				local original, prompts = port.text_prompt, 0
				port.text_prompt = function(...)
					prompts = prompts + 1
					return original(...)
				end
				world.dialog_answer = { "OK", "not a URL" }
				helpers.assert_eq(panel.prompt_address(ctx, "omlx"), false)
				helpers.assert_eq(prompts, 1)
				local notice = world.notices[#world.notices]
				helpers.assert_type(notice and notice.on_click, "function")
				if transition == "entries" then
					api.set_entries({ { id = "successor", provider = "omlx", base_url = "",
						token = "successor-token", model = "successor-model" } })
					api.set_active_entry_id("successor")
				else
					replace_context(panel, ctx)
				end
				local probes = #world.probes
				notice.on_click()
				helpers.assert_eq(prompts, 1, "the stale retry must not prompt for the new owner")
				helpers.assert_eq(#world.probes, probes)
				helpers.assert_eq(world.persists, 0)
			end)
		end)
	end
end)
