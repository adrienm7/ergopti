--- tests/unit/ai/engine/remote/test_api_remote_capabilities.lua

--- ==============================================================================
--- MODULE: Capability Listings In macOS Cloud Requests
--- DESCRIPTION:
--- A provider whose model listing says which reasoning controls each model
--- takes (thinking_off.json capability_listing) has that listing fetched off
--- the request path: a request only schedules the fetch on a zero-delay timer,
--- through a client of its own, with the largest page; the parsed listing then
--- makes later requests skip a control the model lacks. A pending or fresh
--- listing is not fetched again.
---
--- ROOT CAUSE ENCODED:
--- A control a model does not take went out anyway and came back as an HTTP
--- 400, then a retry: the listing that says so was never read.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared logger keeps one process identity, as in the canonical runner.
require("core.logger.engine")

--- The recorded listing answers of the shared corpus.
--- @return table answers listing -> decoded body
local function answers()
	local fh = assert(io.open(helpers.shared("tests/corpus/llm/model_capabilities_vectors.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(require("core.text.engine.json").decode(raw)).answers
end

local function with_remote(callback)
	helpers.with_stub_scope({
		"ai.engine.api.remote", "ai.engine.api.token_crypto", "metrics.engine",
		"modules.shortcuts.script_control", "core.network.adapters.http_client",
		"ai.engine.policy.remote_response_classifier", "ai.engine.local_servers.local_servers",
		"ai.engine.api.provider_uses", "ai.engine.prediction.progressive_reveal",
		"ai.engine.api.common", "ai.engine.settings.profiles", "ai.engine.api.parser",
		"core.logger.engine.logger", "core.events.timer_scheduler", "core.fs.adapters.file_system",
		"core.fs.adapters.json_codec", "core.fs.adapters.storage", "menu.engine.manifest_reader",
		"ai.engine.policy.provider_config_policy", "ai.engine.api.remote_formats", "ai.engine.settings.profile_selector",
		"ai.engine.api.parser_core", "ai.engine.prediction.prompt_builder_core", "ai.engine.local_servers.auth", "ai.engine.policy.thinking_off", "ai.engine.local_servers.discovery",
		"ai.engine.local_servers.model_capabilities", "ai.engine.api.thinking_families",
		"core.lifecycle.engine.compat.utf8", "settings.engine.publication.defaults", "diagnostics.engine.operation_reporter",
		"hotstrings.engine.catalogue.personal_files", "core.fs.engine.dir", "core.text.engine.toml.reader",
		"core.text.engine.json", "lfs", "core.logger.engine.shim", "core.text.engine.utils_core", "core.text.engine.toml_codec.basic_string",
		"core.text.engine.toml_codec.bom", "core.text.engine.toml_codec.key_path", "core.text.engine.toml_codec.reader", "core.text.engine.toml_codec.record_scanner",
	}, function()
		local pending, posts, gets, timers, clients = {}, {}, {}, {}, 0
		package.loaded["core.logger.engine.logger"] = {
			debug = function() end, info = function() end,
			warn = function() end, error = function() end,
			trace = function() end, done = function() end,
			start = function() end, success = function() end,
			pcall = function(_, fn, ...) return pcall(fn, ...) end,
			callback = function(_, _, fn, ...) return pcall(fn, ...) end,
		}
		package.loaded["metrics.engine"] = {}
		package.loaded["modules.shortcuts.script_control"] = {
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
		package.loaded["core.events.timer_scheduler"] = {
			now = function() return 0 end,
			after = function(delay, fn)
				timers[#timers + 1] = { delay = delay, fn = fn }
				return {}, true
			end,
			cancel = function() return true end,
			onSettled = function() return true end,
		}
		package.loaded["core.network.adapters.http_client"] = {
			new = function()
				clients = clients + 1
				local id = clients
				return {
					cancel = function() return true end,
					post = function(url, headers, body, done)
						posts[#posts + 1] = { url = url, headers = headers, body = body, done = done }
						return true
					end,
					get = function(url, headers, done)
						gets[#gets + 1] = { url = url, headers = headers, done = done, client = id }
						return true
					end,
				}
			end,
			encodeForQuery = function(value) return value end,
			encodePathSegment = function(value) return value end,
		}
		local remote = helpers.load_with_stubs("ai.engine.api.remote")
		callback(remote, { pending = pending, posts = posts, gets = gets, timers = timers })
	end)
end

--- Sends one agent chat and returns its decoded body.
--- @return table body
local function chat(remote, io, provider, model)
	local before = #io.posts
	remote.request_chat(provider, model, { model = model, max_tokens = 16, messages = {} }, function() end, function() end)
	while io.pending[1] do table.remove(io.pending, 1).done(true, "cleartext-key") end
	helpers.assert_eq(#io.posts, before + 1, "one request is posted")
	return require("core.text.engine.json").decode(io.posts[#io.posts].body)
end

--- Runs the scheduled timers once.
local function tick(timers)
	local due = {}
	for index, entry in ipairs(timers) do due[index] = entry end
	for index = #timers, 1, -1 do timers[index] = nil end
	for _, entry in ipairs(due) do entry.fn() end
end

helpers.describe("api_remote: capability listings skip what a model lacks (thinking-off-capabilities)", function()

	helpers.it("a request only schedules the fetch; the listing then skips a lacking control", function()
		with_remote(function(remote, io)
			remote.set_entries({ { id = "a", provider = "anthropic", token = "keychain:k" } })
			helpers.assert_eq(chat(remote, io, "anthropic", "claude-opus-5").thinking.type, "disabled",
				"no listing yet: the control is sent")
			helpers.assert_eq(#io.gets, 0, "nothing is fetched before the request goes out")
			helpers.assert_eq(#io.timers, 1, "the fetch waits for a zero-delay timer")
			helpers.assert_eq(io.timers[1].delay, 0, "zero delay")
			chat(remote, io, "anthropic", "claude-opus-5")
			helpers.assert_eq(#io.timers, 1, "a pending fetch is not scheduled twice")
			tick(io.timers)
			helpers.assert_eq(#io.gets, 1, "one listing request")
			helpers.assert_true(io.gets[1].url:find("/models?limit=1000", 1, true) ~= nil, io.gets[1].url)
			helpers.assert_eq(io.gets[1].headers["x-api-key"], "cleartext-key", "the entry's key reads it")
			io.gets[1].done({ ok = true, status = 200, body = require("core.text.engine.json").encode(answers().anthropic) })
			helpers.assert_eq(chat(remote, io, "anthropic", "claude-opus-5").thinking, nil,
				"the listing says disabled is not supported")
			helpers.assert_eq(chat(remote, io, "anthropic", "claude-sonnet-5").thinking.type, "disabled",
				"an unlisted model is unchanged")
			helpers.assert_eq(#io.timers, 0, "a fresh listing is not fetched again")
		end)
	end)

	helpers.it("each provider's listing has its own client", function()
		with_remote(function(remote, io)
			remote.set_entries({ { id = "a", provider = "anthropic", token = "keychain:k" },
				{ id = "g", provider = "gemini", token = "keychain:k" } })
			chat(remote, io, "anthropic", "claude-opus-5")
			chat(remote, io, "gemini", "gemini-2.5-flash")
			tick(io.timers)
			helpers.assert_eq(#io.gets, 2, "one listing per provider")
			helpers.assert_true(io.gets[1].client ~= io.gets[2].client, "two clients: neither cancels the other")
			helpers.assert_true(io.gets[2].url:find("&pageSize=1000", 1, true) ~= nil, "gemini page size after its key")
		end)
	end)

	helpers.it("a provider without a listing never fetches one", function()
		with_remote(function(remote, io)
			remote.set_entries({ { id = "o", provider = "openai", token = "keychain:k" } })
			chat(remote, io, "openai", "gpt-5.1")
			helpers.assert_eq(#io.timers, 0, "openai has no capability listing")
		end)
	end)
end)
