--- tests/unit/ai/engine/remote/test_api_remote_thinking_off.lua

--- ==============================================================================
--- MODULE: Thinking Off In Every macOS Cloud Request
--- DESCRIPTION:
--- Every body macOS posts to a cloud provider carries its model family's
--- reasoning control (thinking_off.json) through the provider's
--- thinking_dialect: the predictions and the Test-API probe
--- (post_and_parse_resolved), the AI agent (request_chat) and the screen
--- reading (request_vision), in the openai, anthropic and gemini formats. A
--- provider refusing an added field with HTTP 400 gets the request once more
--- without it, and never again for that model.
---
--- ROOT CAUSE ENCODED:
--- Only Cerebras' default model had its reasoning turned off, in OpenAI-shape
--- prediction bodies only; request_vision merged nothing at all, not even a
--- local server's request_fields. A Claude 5, Gemini 2.5 or gpt-5.x model
--- spent the small budget thinking and answered late or not at all.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared logger keeps one process identity, as in the canonical runner.
require("core.logger.engine")

local function with_remote(callback)
	helpers.with_stub_scope({
		"ai.engine.api.remote", "ai.engine.api.token_crypto", "metrics.engine",
		"shortcuts.engine.script_control", "core.network.adapters.http_client",
		"ai.engine.policy.remote_response_classifier", "ai.engine.local_servers.local_servers",
		"ai.engine.api.provider_uses", "ai.engine.prediction.progressive_reveal",
		"ai.engine.api.common", "ai.engine.settings.profiles", "ai.engine.api.parser",
		"core.logger.engine.logger", "core.events.timer_scheduler", "core.fs.adapters.file_system",
		"core.fs.adapters.json_codec", "core.fs.adapters.storage", "menu.engine.manifest_reader",
		"ai.engine.policy.provider_config_policy", "ai.engine.api.remote_formats", "ai.engine.settings.profile_selector",
		"ai.engine.api.parser_core", "ai.engine.prediction.prompt_builder_core", "ai.engine.local_servers.auth", "ai.engine.policy.thinking_off", "ai.engine.local_servers.discovery",
		"core.lifecycle.engine.compat.utf8", "settings.engine.publication.defaults", "diagnostics.engine.operation_reporter",
		"hotstrings.engine.catalogue.personal_files", "core.fs.engine.dir", "core.text.engine.toml.reader",
		"core.text.engine.json", "lfs", "core.logger.engine.shim", "core.text.engine.utils_core", "core.text.engine.toml_codec.basic_string",
		"core.text.engine.toml_codec.bom", "core.text.engine.toml_codec.key_path", "core.text.engine.toml_codec.reader", "core.text.engine.toml_codec.record_scanner",
	}, function()
		local pending, posts = {}, {}
		package.loaded["core.logger.engine.logger"] = {
			debug = function() end, info = function() end,
			warn = function() end, error = function() end,
			trace = function() end, done = function() end,
			start = function() end, success = function() end,
			pcall = function(_, callback, ...) return pcall(callback, ...) end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["metrics.engine"] = {}
		package.loaded["shortcuts.engine.script_control"] = {
			is_paused = function() return false end,
			get_pause_epoch = function() return 0 end,
		}
		package.loaded["ai.engine.api.token_crypto"] = {
			is_encrypted = function(value) return value:sub(1, 9) == "keychain:" end,
			decrypt_async = function(stored, done)
				pending[#pending + 1] = { stored = stored, done = done }
				return { cancel = function() return true end }
			end,
		}
		package.loaded["core.network.adapters.http_client"] = {
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
		local remote = helpers.load_with_stubs("ai.engine.api.remote")
		callback(remote, pending, posts)
	end)
end

--- Resolves the pending key read and returns the decoded posted body.
--- @return table body
local function posted_body(pending, posts)
	if pending[1] then pending[1].done(true, "cleartext-key") end
	helpers.assert_eq(#posts, 1, "exactly one request is posted")
	return require("core.text.engine.json").decode(posts[1].body)
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
			local body = require("core.text.engine.json").decode(posts[1].body)
			helpers.assert_eq(body.thinking.type, "between_tools")
			helpers.assert_eq(body.max_tokens, remote.get_test_request_spec().max_tokens)
		end)
	end)

end)




-- =========================================
-- =========================================
-- ======= 3/ Refused fields ===============
-- =========================================
-- =========================================

--- An HTTP 400 answer whose message names a field.
local function refusal(message)
	return { ok = false, status = 400, body = require("core.text.engine.json").encode({ error = { message = message } }) }
end

helpers.describe("api_remote: a refused thinking field is dropped once and remembered", function()

	helpers.it("the agent's request is sent once more without the field, then never with it", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "d", provider = "deepseek", token = "keychain:k" } })
			local texts, failures = {}, 0
			remote.request_chat("deepseek", "deepseek-chat", { model = "deepseek-chat", messages = {} },
				function(text) texts[#texts + 1] = text end, function() failures = failures + 1 end)
			local first = posted_body(pending, posts)
			helpers.assert_eq(first.thinking.type, "disabled", "the generic family turns thinking off")
			posts[1].done(refusal("Unknown parameter: thinking"))
			helpers.assert_eq(#posts, 2, "the request is sent once more")
			helpers.assert_eq(require("core.text.engine.json").decode(posts[2].body).thinking, nil, "without the refused field")
			helpers.assert_eq(failures, 0, "a correction is not a failure")
			posts[2].done(refusal("Unknown parameter: thinking"))
			helpers.assert_eq(#posts, 2, "only once")
			helpers.assert_eq(failures, 1, "the second refusal fails the request")
			remote.request_chat("deepseek", "deepseek-chat", { model = "deepseek-chat", messages = {} },
				function() end, function() end)
			pending[2].done(true, "cleartext-key")
			helpers.assert_eq(require("core.text.engine.json").decode(posts[3].body).thinking, nil, "the refusal is remembered")
		end)
	end)

	helpers.it("the refusal survives a restart", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "d", provider = "deepseek", token = "keychain:k" } })
			remote.request_chat("deepseek", "deepseek-flash", { model = "deepseek-flash", messages = {} },
				function() end, function() end)
			posted_body(pending, posts)
			posts[1].done(refusal("thinking is not supported"))
			local ok, stored = require("core.fs.adapters.storage").read_exact(remote.THINKING_REFUSED_KEY)
			helpers.assert_true(ok and type(stored) == "table", "the refusal is stored")
			helpers.assert_eq(type(stored["deepseek|deepseek-flash"].thinking), "number", "with the time it was refused")
			-- A restart: a fresh module over the same storage
			package.loaded["ai.engine.api.remote"] = nil
			local fresh = require("ai.engine.api.remote")
			fresh.set_entries({ { id = "d", provider = "deepseek", token = "keychain:k" } })
			fresh.request_chat("deepseek", "deepseek-flash", { model = "deepseek-flash", messages = {} },
				function() end, function() end)
			pending[#pending].done(true, "cleartext-key")
			helpers.assert_eq(require("core.text.engine.json").decode(posts[#posts].body).thinking, nil,
				"a fresh module reads the stored refusal")
			require("core.fs.adapters.storage").set(fresh.THINKING_REFUSED_KEY, nil)
		end)
	end)

	helpers.it("an unrelated HTTP 400 is not a refusal", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "o", provider = "openai", token = "keychain:k" } })
			local failures = 0
			remote.request_chat("openai", "gpt-5.1", { model = "gpt-5.1", messages = {} },
				function() end, function() failures = failures + 1 end)
			posted_body(pending, posts)
			posts[1].done(refusal("max_tokens is too large"))
			helpers.assert_eq(#posts, 1, "nothing is sent again")
			helpers.assert_eq(failures, 1)
		end)
	end)

	helpers.it("a prediction is sent once more without the refused field", function()
		with_remote(function(remote, _, posts)
			local entry = { id = "s", provider = "openai", token = "plain-key", model = "gpt-5.1" }
			remote.set_entries({ entry })
			remote.test_request(entry, remote.get_test_request_spec(), function() end, function() end)
			helpers.assert_eq(require("core.text.engine.json").decode(posts[1].body).reasoning_effort, "none")
			posts[1].done(refusal("Unrecognized request argument supplied: reasoning_effort"))
			helpers.assert_eq(#posts, 2, "the probe is sent once more")
			helpers.assert_eq(require("core.text.engine.json").decode(posts[2].body).reasoning_effort, nil)
		end)
	end)

end)




-- =========================================
-- =========================================
-- ======= 4/ Default sampling =============
-- =========================================
-- =========================================

helpers.describe("api_remote: models that accept only the default sampling get no temperature", function()

	helpers.it("the agent's Claude Opus 5 body loses its temperature", function()
		with_remote(function(remote, pending, posts)
			remote.set_entries({ { id = "a", provider = "anthropic", token = "keychain:k" } })
			remote.request_chat("anthropic", "claude-opus-5", { model = "claude-opus-5", temperature = 0.7, messages = {} },
				function() end, function() end)
			helpers.assert_eq(posted_body(pending, posts).temperature, nil, "a non-default temperature is an HTTP 400")
		end)
	end)

	helpers.it("a prediction to Claude Opus 4.8 is sent no temperature; Claude Haiku 4.5 keeps it", function()
		with_remote(function(remote, _, posts)
			local opus = { id = "o", provider = "anthropic", token = "plain-key", model = "claude-opus-4-8" }
			local haiku = { id = "h", provider = "anthropic", token = "plain-key", model = "claude-haiku-4-5" }
			remote.set_entries({ opus, haiku })
			remote.test_request(opus, remote.get_test_request_spec(), function() end, function() end)
			remote.test_request(haiku, remote.get_test_request_spec(), function() end, function() end)
			helpers.assert_eq(require("core.text.engine.json").decode(posts[1].body).temperature, nil)
			helpers.assert_true(require("core.text.engine.json").decode(posts[2].body).temperature ~= nil, "Claude 4.5 keeps it")
		end)
	end)

end)

helpers.describe("api_remote: empty system prompt", function()
	for _, provider in ipairs({ "anthropic", "gemini" }) do
		helpers.it("omits empty instructions for " .. provider, function()
			with_remote(function(remote, _, posts)
				local entry = { id = "raw", provider = provider, token = "plain-key", model = "fixture-model" }
				remote.set_entries({ entry })
				remote.set_active_entry_id(entry.id)
				remote.request_raw(entry.model, "", "typed context", "", 0.2, 8,
					function() end, function() end)
				helpers.assert_eq(#posts, 1)
				local body = require("core.text.engine.json").decode(posts[1].body)
				if provider == "anthropic" then
					helpers.assert_nil(body.system)
					helpers.assert_eq(body.messages[1].content, "typed context")
				else
					helpers.assert_nil(body.systemInstruction)
					helpers.assert_eq(body.contents[1].parts[1].text, "typed context")
				end
			end)
		end)
	end
end)
