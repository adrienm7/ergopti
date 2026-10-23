--- tests/unit/modules/llm/remote/test_api_remote_prebuilt_entry_ownership.lua

--- ==============================================================================
--- MODULE: Remote Prebuilt Request Credential Ownership Regression
--- DESCRIPTION:
--- A delayed credential read must not dispatch private agent or vision input
--- after its configured API entry was removed, replaced or changed. The same
--- request remains independent of the prediction menu's active provider.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared logger keeps one process identity, as in the canonical runner.
-- Native adapter fixtures below own their shim, never a fresh shared core.
require("logger")

local function with_remote(callback)
	helpers.with_stub_scope({
		"modules.llm.api_remote", "modules.llm.api_token_crypto", "modules.keystats",
		"modules.shortcuts.script_control", "adapters.http_client",
		"modules.llm.remote_response_classifier", "modules.llm.local_servers",
		"modules.llm.provider_uses", "modules.llm.progressive_reveal",
		"modules.llm.api_common", "modules.llm.profiles", "modules.llm.parser",
		"infra.logger", "adapters.timer_scheduler", "adapters.file_system",
		"adapters.json_codec", "adapters.storage", "infra.manifest_reader",
		"llm.provider_config_policy", "llm.remote_formats", "llm.profile_selector",
		"llm.parser", "llm.prompt_builder", "llm.local_server_auth", "llm.local_server_discovery",
		"compat.utf8", "config_defaults", "diagnostics.operation_reporter",
		"hotstrings.personal_files", "infra.fs_dir", "infra.toml.reader",
		"json", "lfs", "logger.shim", "text_utils", "toml_codec.basic_string",
		"toml_codec.bom", "toml_codec.key_path", "toml_codec.reader", "toml_codec.record_scanner",
	}, function()
		local pending, posts = {}, {}
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end,
			warn = function() end, error = function() end,
			trace = function() end, done = function() end,
			start = function() end, success = function() end,
			pcall = function(_, callback, ...) return pcall(callback, ...) end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["modules.keystats"] = {}
		package.loaded["modules.shortcuts.script_control"] = {
			is_paused = function() return false end,
			get_pause_epoch = function() return 0 end,
		}
		package.loaded["modules.llm.api_token_crypto"] = {
			is_encrypted = function(value) return value:sub(1, 9) == "keychain:" end,
			decrypt_async = function(stored, done)
				pending[#pending + 1] = { stored = stored, done = done }
				return { cancel = function() return true end }
			end,
		}
		package.loaded["adapters.http_client"] = {
			new = function()
				return {
					cancel = function() return true end,
					post = function(url, headers, body, done)
						posts[#posts + 1] = { url = url, headers = headers, body = body, done = done }
						return true
					end,
					get = function() error("no availability request belongs to this fixture") end,
				}
			end,
			encodeForQuery = function(value) return value end,
		}
		local remote = helpers.load_with_stubs("modules.llm.api_remote")
		callback(remote, pending, posts)
	end)
end

local REQUESTS = {
	{
		name = "chat", provider = "openai",
		send = function(remote, done, fail)
			return remote.request_chat("openai", "gpt-4o-mini", { messages = {} }, done, fail)
		end,
	},
	{
		name = "vision", provider = "openai",
		send = function(remote, done, fail)
			return remote.request_vision("openai", "gpt-4o-mini", { messages = {} }, done, fail)
		end,
	},
	{
		name = "Backboard", provider = "backboard",
		send = function(remote, done, fail)
			return remote.request_backboard("backboard", { model = "openai/gpt-4o-mini", text = "private input" }, done, fail)
		end,
	},
	{
		name = "decisions", provider = "typesafe",
		send = function(remote, done, fail)
			return remote.request_decisions("typesafe", "jev-latest", "private input",
				{ one = { type = "text", instructions = "Answer" } }, done, fail)
		end,
	},
}

helpers.describe("remote prebuilt requests retain their credential identity", function()
	for _, request in ipairs(REQUESTS) do
		helpers.it(request.name .. " refuses a late key after its entry was removed", function()
			with_remote(function(remote, pending, posts)
				local entry = { id = "configured", provider = request.provider, token = "keychain:original" }
				remote.set_entries({ entry })
				local failures = {}
				helpers.assert_true(request.send(remote, function() error("no answer was received") end,
					function(reason) failures[#failures + 1] = reason end))
				helpers.assert_eq(#pending, 1)
				helpers.assert_eq(#posts, 0, "the native key read is still pending")
				remote.set_entries({})
				pending[1].done(true, "original-cleartext-key")
				helpers.assert_eq(#posts, 0, "deleted credentials cannot dispatch the captured private request")
				helpers.assert_eq(#failures, 1, "the caller must leave its pending state")
				helpers.assert_eq(failures[1], "stale_identity")
			end)
		end)

		helpers.it(request.name .. " dispatches a current resolved key", function()
			with_remote(function(remote, pending, posts)
				remote.set_entries({ { id = "configured", provider = request.provider, token = "keychain:original" } })
				local failures = 0
				helpers.assert_true(request.send(remote, function() end, function() failures = failures + 1 end))
				pending[1].done(true, "current-cleartext-key")
				helpers.assert_eq(#posts, 1, "current credentials still dispatch exactly one first request")
				helpers.assert_eq(failures, 0)
			end)
		end)
	end

	helpers.it("chat refuses a key resolved for an entry that was replaced", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "configured", provider = "openai", token = "keychain:original" } })
			local reason
			REQUESTS[1].send(remote, function() end, function(value) reason = value end)
			remote.set_entries({ { id = "configured", provider = "openai", token = "keychain:replacement" } })
			pending[1].done(true, "original-cleartext-key")
			helpers.assert_eq(#posts, 0)
			helpers.assert_eq(reason, "stale_identity")
		end)
	end)

	helpers.it("chat refuses a key after the stored reference changes in place", function()
		with_remote(function(remote, pending, posts)
			local entry = { id = "configured", provider = "openai", token = "keychain:original" }
			remote.set_entries({ entry })
			local reason
			REQUESTS[1].send(remote, function() end, function(value) reason = value end)
			entry.token = "keychain:replacement"
			pending[1].done(true, "original-cleartext-key")
			helpers.assert_eq(#posts, 0)
			helpers.assert_eq(reason, "stale_identity")
		end)
	end)

	helpers.it("chat remains independent of the prediction provider selection", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({
				{ id = "configured", provider = "openai", token = "keychain:original" },
				{ id = "other", provider = "anthropic", token = "other-key" },
			})
			local failures = 0
			REQUESTS[1].send(remote, function() end, function() failures = failures + 1 end)
			remote.set_active_entry_id("other")
			pending[1].done(true, "original-cleartext-key")
			helpers.assert_eq(#posts, 1)
			helpers.assert_eq(posts[1].headers.Authorization, "Bearer original-cleartext-key")
			helpers.assert_eq(failures, 0)
		end)
	end)
end)
