--- tests/unit/modules/llm/remote/test_api_remote_capabilities.lua

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
require("logger")

--- The recorded listing answers of the shared corpus.
--- @return table answers listing -> decoded body
local function answers()
	local fh = assert(io.open(helpers.shared("tests/corpus/llm/model_capabilities_vectors.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(require("json").decode(raw)).answers
end

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
		"llm.model_capabilities", "modules.llm.thinking_families",
		"compat.utf8", "config_defaults", "diagnostics.operation_reporter",
		"hotstrings.personal_files", "infra.fs_dir", "infra.toml.reader",
		"json", "lfs", "logger.shim", "text_utils", "toml_codec.basic_string",
		"toml_codec.bom", "toml_codec.key_path", "toml_codec.reader", "toml_codec.record_scanner",
	}, function()
		local pending, posts, gets, timers, clients = {}, {}, {}, {}, 0
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end,
			warn = function() end, error = function() end,
			trace = function() end, done = function() end,
			start = function() end, success = function() end,
			pcall = function(_, fn, ...) return pcall(fn, ...) end,
			callback = function(_, _, fn, ...) return pcall(fn, ...) end,
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
		package.loaded["adapters.timer_scheduler"] = {
			now = function() return 0 end,
			after = function(delay, fn)
				timers[#timers + 1] = { delay = delay, fn = fn }
				return {}, true
			end,
			cancel = function() return true end,
			onSettled = function() return true end,
		}
		package.loaded["adapters.http_client"] = {
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
		local remote = helpers.load_with_stubs("modules.llm.api_remote")
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
	return require("json").decode(io.posts[#io.posts].body)
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
			io.gets[1].done({ ok = true, status = 200, body = require("json").encode(answers().anthropic) })
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
