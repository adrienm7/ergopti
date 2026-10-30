--- tests/unit/modules/llm/remote/test_api_remote_thinking_off.lua

--- ==============================================================================
--- MODULE: Thinking Off In Every macOS Cloud Request
--- DESCRIPTION:
--- Every body macOS posts to a cloud provider carries the provider's
--- thinking_off rule of api_providers.json: the predictions and the Test-API
--- probe (post_and_parse_resolved), the AI agent (request_chat) and the screen
--- reading (request_vision), in the openai, anthropic and gemini formats.
---
--- ROOT CAUSE ENCODED:
--- Only Cerebras' default model had its reasoning turned off, in OpenAI-shape
--- prediction bodies only; request_vision merged nothing at all, not even a
--- local server's request_fields. A Claude 5, Gemini 2.5 or gpt-5.x model
--- spent the small budget thinking and answered late or not at all.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared logger keeps one process identity, as in the canonical runner.
require("logger")

local function with_remote(callback)
	helpers.with_stub_scope({
		"modules.llm.api_remote", "modules.llm.api_token_crypto", "modules.keystats",
		"modules.shortcuts.script_control", "adapters.http_client",
		"llm.remote_response_classifier", "modules.llm.local_servers",
		"modules.llm.provider_uses", "modules.llm.progressive_reveal",
		"modules.llm.api_common", "modules.llm.profiles", "modules.llm.parser",
		"infra.logger", "adapters.timer_scheduler", "adapters.file_system",
		"adapters.json_codec", "adapters.storage", "infra.manifest_reader",
		"llm.provider_config_policy", "llm.remote_formats", "llm.profile_selector",
		"llm.parser", "llm.prompt_builder", "llm.local_server_auth", "llm.thinking_off", "llm.local_server_discovery",
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
			encodePathSegment = function(value) return value end,
		}
		local remote = helpers.load_with_stubs("modules.llm.api_remote")
		callback(remote, pending, posts)
	end)
end

--- Resolves the pending key read and returns the decoded posted body.
--- @return table body
local function posted_body(pending, posts)
	if pending[1] then pending[1].done(true, "cleartext-key") end
	helpers.assert_eq(#posts, 1, "exactly one request is posted")
	return require("json").decode(posts[1].body)
end




-- =========================================
-- =========================================
-- ======= 1/ Prebuilt bodies ==============
-- =========================================
-- =========================================

helpers.describe("api_remote: prebuilt bodies turn thinking off (thinking-off-everywhere)", function()

	helpers.it("the agent's Claude Opus 5 chat is sent thinking disabled", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "a", provider = "anthropic", token = "keychain:k" } })
			remote.request_chat("anthropic", "claude-opus-5", { model = "claude-opus-5", max_tokens = 64,
				messages = {} }, function() end, function() end)
			local body = posted_body(pending, posts)
			helpers.assert_eq(type(body.thinking), "table", "a thinking field is sent")
			helpers.assert_eq(body.thinking.type, "disabled")
		end)
	end)

	helpers.it("the screen reading's Gemini 2.5 Flash keeps its budget and thinks for none", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "g", provider = "gemini", token = "keychain:k" } })
			remote.request_vision("gemini", "gemini-2.5-flash",
				{ contents = {}, generationConfig = { maxOutputTokens = 1200 } }, function() end, function() end)
			local body = posted_body(pending, posts)
			helpers.assert_eq(body.generationConfig.thinkingConfig.thinkingBudget, 0)
			helpers.assert_eq(body.generationConfig.maxOutputTokens, 1200, "the body's own field survives")
		end)
	end)

	helpers.it("a field the caller set wins over the rule", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "o", provider = "openai", token = "keychain:k" } })
			remote.request_chat("openai", "gpt-5.1", { model = "gpt-5.1", messages = {}, reasoning_effort = "high" },
				function() end, function() end)
			helpers.assert_eq(posted_body(pending, posts).reasoning_effort, "high")
		end)
	end)

	helpers.it("a model no rule names is sent as it is", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "o", provider = "openai", token = "keychain:k" } })
			remote.request_vision("openai", "gpt-4o-mini", { model = "gpt-4o-mini", messages = {} },
				function() end, function() end)
			helpers.assert_eq(posted_body(pending, posts).reasoning_effort, nil)
		end)
	end)

end)




-- =========================================
-- =========================================
-- ======= 2/ Predictions ==================
-- =========================================
-- =========================================

helpers.describe("api_remote: the prediction payload turns thinking off", function()

	helpers.it("the Test-API probe of Claude Sonnet 5.5 is sent its lowest thinking", function()
		with_remote(function(remote, _, posts)
			local entry = { id = "s", provider = "anthropic", token = "plain-key", model = "claude-sonnet-5-5" }
			remote.set_entries({ entry })
			helpers.assert_true(remote.test_request(entry, remote.get_test_request_spec(), function() end,
				function() end))
			helpers.assert_eq(#posts, 1, "the probe is posted")
			local body = require("json").decode(posts[1].body)
			helpers.assert_eq(body.thinking.type, "between_tools")
			helpers.assert_eq(body.max_tokens, remote.get_test_request_spec().max_tokens)
		end)
	end)

end)
