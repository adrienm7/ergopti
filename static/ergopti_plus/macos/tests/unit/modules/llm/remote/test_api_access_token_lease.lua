--- tests/unit/modules/llm/remote/test_api_access_token_lease.lua

--- ==============================================================================
--- MODULE: Access-Token Resolver Lease (macOS)
--- DESCRIPTION:
--- For a provider that exchanges its key for an access token (IBM watsonx,
--- Google Vertex AI), resolve_active_entry hands back a lease that owns the
--- pending exchange: the first request after start or a key change waits for
--- the token and is then sent with it, a cancelled lease never calls back, an
--- identity change settles the wait, and a key change starts the exchange on
--- the next tick. The Keychain, the HTTP clients and the timers are faked.
---
--- ROOT CAUSE ENCODED:
--- deliver_resolved answered synchronously: while the token was being
--- fetched it refused the request with access_token_unavailable, so the first
--- prediction after start or a key change was dropped, and a key change
--- started no exchange at all (access-token-lease).
--- ==============================================================================

local helpers = require("tests.helpers")

-- The shared logger keeps one process identity, as in the canonical runner.
require("logger")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local TOKEN_URL = "https://iam.cloud.ibm.com/identity/token"

--- Loads the real remote backend with faked Keychain, HTTP and timers, and an
--- access-token provider.
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
		local pending, posts, timers = {}, {}, {}
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
				return {
					cancel = function() return true end,
					post = function(url, headers, body, done)
						posts[#posts + 1] = { url = url, headers = headers, body = body, done = done }
						return true
					end,
					get = function() return true end,
				}
			end,
			encodeForQuery = function(value) return value end,
			encodePathSegment = function(value) return value end,
		}
		local remote = helpers.load_with_stubs("modules.llm.api_remote")
		remote.PROVIDERS.ibm_fixture = {
			label = "IBM fixture", base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1", default_model = "",
			format = "openai", model_extras = {}, thinking_dialect = {},
			auth = assert(require("llm.api_token_exchange").parse({
				kind = "token_exchange", token_url = TOKEN_URL,
				body = { grant_type = "urn:ibm:params:oauth:grant-type:apikey", apikey = "{key}" },
				token_field = "access_token", expires_field = "expires_in",
				default_expires_seconds = 3600, refresh_margin_seconds = 300,
			})),
		}
		callback(remote, { pending = pending, posts = posts, timers = timers })
	end)
end

--- Selects one access-token entry and drops the exchange its key change starts.
local function select_entry(remote, io, token)
	remote.set_entries({ { id = "w", provider = "ibm_fixture", token = token, model = "ibm/granite" } })
	remote.set_active_entry_id("w")
	for index = #io.timers, 1, -1 do io.timers[index] = nil end
end

--- The token exchanges posted so far.
local function exchanges(io)
	local found = {}
	for _, post in ipairs(io.posts) do
		if post.url == TOKEN_URL then found[#found + 1] = post end
	end
	return found
end

local function reply(post, status, body)
	post.done({ ok = status >= 200 and status < 300, status = status, body = require("json").encode(body) })
end




-- =========================================
-- =========================================
-- ======= 1/ The lease ====================
-- =========================================
-- =========================================

helpers.describe("api_remote: the resolver lease owns the access-token exchange (access-token-lease)", function()

	helpers.it("the first resolution waits for the token instead of being refused (access-token-lease)", function()
		with_remote(function(remote, io)
			select_entry(remote, io, "ibm-api-key")
			local got = {}
			local lease = remote.resolve_active_entry(function(...) got[#got + 1] = table.pack(...) end)
			helpers.assert_eq(#got, 0, "no answer while the token is fetched: " .. tostring(got[1] and got[1][3]))
			helpers.assert_eq(#exchanges(io), 1, "the exchange is asked")
			helpers.assert_type(lease, "table")
			reply(exchanges(io)[1], 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(#got, 1, "answered once the token arrives")
			helpers.assert_eq(got[1][1], true)
			helpers.assert_eq(got[1][2].token, "iam-token", "the token, never the key")
		end)
	end)

	helpers.it("a Keychain key waits for its decryption, then for the token (access-token-lease)", function()
		with_remote(function(remote, io)
			select_entry(remote, io, "keychain:w")
			local got
			remote.resolve_active_entry(function(...) got = table.pack(...) end)
			helpers.assert_eq(#io.pending, 1)
			io.pending[1].done(true, "ibm-api-key")
			helpers.assert_nil(got, "still waiting for the token")
			helpers.assert_eq(#exchanges(io), 1)
			reply(exchanges(io)[1], 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(got[1], true)
			helpers.assert_eq(got[2].token, "iam-token")
		end)
	end)

	helpers.it("a cancelled lease never calls back (access-token-lease)", function()
		with_remote(function(remote, io)
			select_entry(remote, io, "keychain:w")
			local called = false
			local lease = remote.resolve_active_entry(function() called = true end)
			io.pending[1].done(true, "ibm-api-key")
			helpers.assert_eq(lease.cancel(), true, "the wait is settled by its cancellation")
			reply(exchanges(io)[1], 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(called, false, "no answer after the cancellation")
		end)
	end)

	helpers.it("an identity change settles the wait as superseded (access-token-lease)", function()
		with_remote(function(remote, io)
			select_entry(remote, io, "ibm-api-key")
			local got
			remote.resolve_active_entry(function(...) got = table.pack(...) end)
			remote.set_active_entry_id("")
			helpers.assert_eq(got[1], false)
			helpers.assert_eq(got[3], "identity_changed")
			reply(exchanges(io)[1], 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(got[3], "identity_changed", "never answered twice")
		end)
	end)

	helpers.it("a refused exchange answers the wait, then refuses at once in its pause (access-token-lease)", function()
		with_remote(function(remote, io)
			select_entry(remote, io, "bad-key")
			local got
			remote.resolve_active_entry(function(...) got = table.pack(...) end)
			reply(exchanges(io)[1], 400, { errorMessage = "Provided API key could not be found" })
			helpers.assert_eq(got[1], false)
			helpers.assert_eq(got[3], "access_token_unavailable")
			local again
			remote.resolve_active_entry(function(...) again = table.pack(...) end)
			helpers.assert_eq(again[3], "access_token_unavailable", "no wait during the retry pause")
			helpers.assert_eq(#exchanges(io), 1, "the token service is not asked again")
		end)
	end)

	helpers.it("a key change starts the exchange on the next tick (access-token-lease)", function()
		with_remote(function(remote, io)
			remote.set_entries({ { id = "w", provider = "ibm_fixture", token = "ibm-api-key", model = "ibm/granite" } })
			remote.set_active_entry_id("w")
			helpers.assert_eq(#io.timers, 1, "one prewarm for the settled identity")
			helpers.assert_eq(#exchanges(io), 0, "not before the identity settles")
			io.timers[1].fn()
			helpers.assert_eq(#exchanges(io), 1, "the exchange starts")
			reply(exchanges(io)[1], 200, { access_token = "iam-token", expires_in = 3600 })
			local got
			remote.resolve_active_entry(function(...) got = table.pack(...) end)
			helpers.assert_eq(got[2].token, "iam-token", "the first request finds the token")
		end)
	end)

	helpers.it("a provider without a token exchange schedules nothing (access-token-lease)", function()
		with_remote(function(remote, io)
			remote.set_entries({ { id = "o", provider = "openai", token = "sk-key", model = "gpt-5.1" } })
			remote.set_active_entry_id("o")
			helpers.assert_eq(#io.timers, 0)
		end)
	end)
end)
