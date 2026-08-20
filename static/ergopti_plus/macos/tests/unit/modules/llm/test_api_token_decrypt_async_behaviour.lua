--- tests/unit/modules/llm/test_api_token_decrypt_async_behaviour.lua

--- ==============================================================================
--- MODULE: Regression — bounded Keychain tasks and single-flight resolution
--- DESCRIPTION:
--- Drives hung/failed subprocesses and stale resolver completions through the
--- real production modules. Assertions cover observable completion, ownership,
--- cache placement, and menu/network side effects rather than source spelling.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_crypto_fixture(options, body)
	options = options or {}
	local names = {
		"modules.llm.api_token_crypto", "adapters.shell_runner",
		"adapters.timer_scheduler", "infra.timings", "infra.logger",
		"platform.remap.lease_helper",
	}
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end

	local fixture = {
		done = nil,
		timeout = nil,
		terminate_calls = 0,
		cancel_calls = 0,
		start_calls = 0,
		input = nil,
		process_order = {},
		streaming = nil,
		executable = nil,
		args = nil,
		errors = {},
	}
	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function(_, fmt, ...)
			fixture.errors[#fixture.errors + 1] = string.format(tostring(fmt), ...)
		end,
	}
	package.loaded["infra.timings"] = {
		sec = function(section, key)
			helpers.assert_eq(section, "llm")
			helpers.assert_eq(key, "keychain_operation_timeout_ms")
			return 10
		end,
	}
	package.loaded["platform.remap.lease_helper"] = {
		resolve = function()
			if options.helper_throws then error("helper resolution exploded") end
			if options.helper_unavailable then return nil, "helper missing" end
			return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			helpers.assert_eq(delay, 10)
			fixture.timeout = callback
			if options.timer_fires_synchronously then callback() end
			return { timer = true }, options.timer_commits ~= false
		end,
		cancel = function()
			fixture.cancel_calls = fixture.cancel_calls + 1
			return true
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done, on_chunk)
			if options.spawn_throws then error("spawn exploded") end
			fixture.executable = executable
			fixture.args = args
			fixture.streaming = type(on_chunk) == "function"
			fixture.done = on_done
			return {
				set_input = function(value)
					fixture.input = value
					fixture.process_order[#fixture.process_order + 1] = "input"
					return options.input_accepts ~= false
				end,
				start = function()
					fixture.start_calls = fixture.start_calls + 1
					fixture.process_order[#fixture.process_order + 1] = "start"
					return options.start_succeeds ~= false
				end,
				terminate = function()
					fixture.terminate_calls = fixture.terminate_calls + 1
					if options.done_on_terminate and fixture.done then
						fixture.done(15, "", "terminated")
						return true, "settled"
					end
					if options.terminate_succeeds == false then return false, "refused" end
					return true, "pending"
				end,
			}
		end,
	}
	package.loaded["modules.llm.api_token_crypto"] = nil

	local ok, err = xpcall(function()
		body(require("modules.llm.api_token_crypto"), fixture)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err) end
end

helpers.describe("TokenCrypto async task ownership", function()
	helpers.it("times out a hung read, terminates its exact task, and completes once", function()
		with_crypto_fixture({ done_on_terminate = true }, function(TokenCrypto, fixture)
			local results = {}
			TokenCrypto.decrypt_async("keychain:entry-a", function(...)
				results[#results + 1] = table.pack(...)
			end)
			helpers.assert_eq(#results, 0, "a hung subprocess must not complete synchronously")
			helpers.assert_type(fixture.timeout, "function", "the hard deadline must be armed")
			fixture.timeout()
			helpers.assert_eq(fixture.terminate_calls, 1,
				"deadline must terminate the exact ShellRunner handle")
			helpers.assert_eq(#results, 1, "timeout must complete the caller exactly once")
			helpers.assert_eq(results[1][1], false)
			helpers.assert_eq(results[1][3], "timeout")

			fixture.done(0, "late-secret", "")
			fixture.done(0, "duplicate-secret", "")
			helpers.assert_eq(#results, 1,
				"late and duplicate native completions must be fenced after timeout")
		end)
	end)

	helpers.it("reports start refusal exactly once and never waits for a callback", function()
		with_crypto_fixture({ start_succeeds = false }, function(TokenCrypto, fixture)
			local calls, reason = 0, nil
			TokenCrypto.decrypt_async("keychain:entry-a", function(ok, _value, why)
				calls = calls + 1
				helpers.assert_eq(ok, false)
				reason = why
			end)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(reason, "launch_failed")
			helpers.assert_eq(fixture.terminate_calls, 1)
			helpers.assert_eq(fixture.cancel_calls, 1,
				"launch failure must cancel the already-armed deadline")
		end)
	end)

	helpers.it("does not launch after a deadline fires synchronously during acquisition", function()
		with_crypto_fixture({ timer_fires_synchronously = true, terminate_succeeds = false }, function(TokenCrypto, fixture)
			local results = {}
			TokenCrypto.decrypt_async("keychain:entry-a", function(...)
				results[#results + 1] = table.pack(...)
			end)
			helpers.assert_eq(fixture.start_calls, 0,
				"a terminal timeout must fence the later task start")
			helpers.assert_eq(fixture.terminate_calls, 1,
				"the synchronous deadline must terminate its exact prepared task")
			helpers.assert_eq(fixture.cancel_calls, 1,
				"the timer handle returned after delivery must still be retired")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], false)
			helpers.assert_eq(results[1][3], "timeout")
		end)
	end)

	helpers.it("converts a constructor throw into one explicit launch failure", function()
		with_crypto_fixture({ spawn_throws = true }, function(TokenCrypto)
			local calls, reason = 0, nil
			TokenCrypto.decrypt_async("keychain:entry-a", function(ok, _value, why)
				calls = calls + 1
				helpers.assert_eq(ok, false)
				reason = why
			end)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(reason, "launch_failed")
		end)
	end)

	helpers.it("never returns cleartext as the encryption failure value", function()
		with_crypto_fixture({}, function(TokenCrypto, fixture)
			local delivered = nil
			TokenCrypto.encrypt_async("entry-a", "plain-secret", function(...)
				delivered = table.pack(...)
			end)
			helpers.assert_eq(fixture.input, "plain-secret",
				"the token belongs on stdin, not in the argument vector")
			helpers.assert_eq(table.concat(fixture.process_order, ","), "input,start",
				"the non-streaming task must receive its one-shot stdin before launch")
			helpers.assert_eq(fixture.streaming, false,
				"hs.task setInput closes stdin automatically only in the non-streaming form")
			helpers.assert_eq(fixture.executable,
				"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus")
			helpers.assert_eq(fixture.args[1], "--keychain-token-write")
			helpers.assert_eq(fixture.args[2], "entry-a")
			helpers.assert_eq(#fixture.args, 2,
				"the secret must never be appended to launcher argv")
			for _, argument in ipairs(fixture.args) do
				helpers.assert_true(argument ~= "plain-secret", "secret material leaked into argv")
			end
			fixture.done(51, "", "denied")
			helpers.assert_eq(delivered[1], false)
			helpers.assert_eq(delivered[2], nil,
				"encryption failure must never hand plaintext back for persistence")
		end)
	end)

	helpers.it("does not signal or settle a timed-out Keychain mutation before natural completion", function()
		with_crypto_fixture({}, function(TokenCrypto, fixture)
			local results = {}
			TokenCrypto.encrypt_async("entry-a", "plain-secret", function(...)
				results[#results + 1] = table.pack(...)
			end)

			fixture.timeout()
			helpers.assert_eq(fixture.terminate_calls, 0,
				"a dispatched SecItem mutation cannot be cancelled safely with SIGTERM")
			helpers.assert_eq(#results, 0,
				"logical timeout must not release native mutation ownership")

			fixture.done(0, "", "")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], false,
				"a late native success remains logically timed out")
			helpers.assert_eq(results[1][2], nil)
			helpers.assert_eq(results[1][3], "timeout")
		end)
	end)

	helpers.it("keeps explicit Keychain-mutation cancellation pending until native completion", function()
		with_crypto_fixture({}, function(TokenCrypto, fixture)
			local results = {}
			local operation = TokenCrypto.encrypt_async("entry-a", "plain-secret", function(...)
				results[#results + 1] = table.pack(...)
			end)

			local settled, state = operation.cancel()
			helpers.assert_eq(settled, false)
			helpers.assert_eq(state, "pending")
			helpers.assert_eq(fixture.terminate_calls, 0)
			helpers.assert_eq(#results, 0)

			fixture.done(0, "", "")
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1][1], false)
			helpers.assert_eq(results[1][3], "cancelled")
		end)
	end)

	helpers.it("logs a client callback throw instead of swallowing it", function()
		with_crypto_fixture({}, function(TokenCrypto, fixture)
			TokenCrypto.decrypt_async("keychain:entry-a", function()
				error("consumer exploded")
			end)
			fixture.done(0, "secret", "")
			local joined = table.concat(fixture.errors, "\n")
			helpers.assert_true(joined:find("consumer exploded", 1, true) ~= nil,
				"a throw across the task boundary must reach the file logger")
		end)
	end)
end)

local function with_remote_fixture(body)
	local names = {
		"modules.llm.api_remote", "modules.llm.api_token_crypto",
		"adapters.http_client",
	}
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local fixture = { decrypt_calls = 0, callbacks = {}, cancels = 0, http_gets = 0 }
	package.loaded["modules.llm.api_token_crypto"] = {
		is_encrypted = function(value)
			return type(value) == "string" and value:sub(1, 9) == "keychain:"
		end,
		decrypt_async = function(_stored, callback)
			fixture.decrypt_calls = fixture.decrypt_calls + 1
			fixture.callbacks[#fixture.callbacks + 1] = callback
			return {
				cancel = function()
					fixture.cancels = fixture.cancels + 1
					return true
				end,
			}
		end,
	}
	package.loaded["adapters.http_client"] = {
		new = function()
			return {
				cancel = function() return true end,
				get = function(_url, _headers, _callback)
					fixture.http_gets = fixture.http_gets + 1
				end,
				post = function() end,
			}
		end,
		encodeForQuery = function(value) return value end,
	}
	package.loaded["modules.llm.api_remote"] = nil
	local ok, err = xpcall(function()
		body(helpers.load_with_stubs("modules.llm.api_remote"), fixture)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err) end
end

helpers.describe("ApiRemote asynchronous token resolver", function()
	helpers.it("single-flights waiters, caches outside the entry, and ignores duplicates", function()
		with_remote_fixture(function(ApiRemote, fixture)
			ApiRemote.set_entries({
				{ id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "gpt" },
			})
			ApiRemote.set_active_entry_id("entry-a")
			local results = {}
			ApiRemote.resolve_active_entry(function(...) results[#results + 1] = table.pack(...) end)
			ApiRemote.resolve_active_entry(function(...) results[#results + 1] = table.pack(...) end)
			helpers.assert_eq(fixture.decrypt_calls, 1,
				"concurrent callers for one reference must share one Keychain task")
			helpers.assert_eq(ApiRemote.get_active_entry().token, "keychain:entry-a",
				"menu metadata must retain the persisted reference while resolution is pending")

			fixture.callbacks[1](true, "secret-a", nil)
			helpers.assert_eq(#results, 2, "every single-flight waiter must complete")
			helpers.assert_eq(results[1][1], true)
			helpers.assert_eq(results[1][2].token, "secret-a")
			helpers.assert_eq(ApiRemote.get_active_entry().token, "keychain:entry-a",
				"cleartext cache must never replace the persisted entry field")

			fixture.callbacks[1](true, "duplicate", nil)
			helpers.assert_eq(#results, 2, "duplicate crypto callbacks must not redeliver waiters")
			local cached = nil
			ApiRemote.resolve_active_entry(function(ok, entry) cached = ok and entry.token or nil end)
			helpers.assert_eq(cached, "secret-a")
			helpers.assert_eq(fixture.decrypt_calls, 1, "a valid external cache hit needs no second task")
		end)
	end)

	helpers.it("terminates and fails waiters when identity changes, then discards the late result", function()
		with_remote_fixture(function(ApiRemote, fixture)
			ApiRemote.set_entries({
				{ id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "a" },
				{ id = "entry-b", provider = "openai", token = "keychain:entry-b", model = "b" },
			})
			ApiRemote.set_active_entry_id("entry-a")
			local calls, reason = 0, nil
			ApiRemote.resolve_active_entry(function(ok, _entry, why)
				calls = calls + 1
				helpers.assert_eq(ok, false)
				reason = why
			end)
			ApiRemote.set_active_entry_id("entry-b")
			helpers.assert_eq(fixture.cancels, 1, "identity change must terminate the exact read task")
			helpers.assert_eq(calls, 1, "superseded waiter must receive one explicit failure")
			helpers.assert_eq(reason, "identity_changed")

			fixture.callbacks[1](true, "late-a", nil)
			helpers.assert_eq(calls, 1, "late stale completion must not redeliver")
			helpers.assert_eq(ApiRemote.get_entries()[1].token, "keychain:entry-a")
		end)
	end)

	helpers.it("does zero HTTP work until a cold token resolves", function()
		with_remote_fixture(function(ApiRemote, fixture)
			ApiRemote.PROVIDERS.openai = {
				label = "OpenAI", base_url = "https://example.invalid", default_model = "gpt", format = "openai",
			}
			ApiRemote.set_entries({
				{ id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "gpt" },
			})
			ApiRemote.set_active_entry_id("entry-a")
			ApiRemote.warmup()
			helpers.assert_eq(fixture.http_gets, 0,
				"warmup must return before the Keychain and must not send an unresolved reference")
			fixture.callbacks[1](true, "secret-a", nil)
			helpers.assert_eq(fixture.http_gets, 1,
				"the network request may start only after async credential resolution")
		end)
	end)
end)

helpers.describe("API menu metadata path", function()
	helpers.it("builds before token resolution without starting any shell work", function()
		local names = {
			"modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
			"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel",
		}
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local resolver_calls = 0
		local entry = { id = "entry-a", provider = "openai", token = "keychain:entry-a", model = "gpt" }
		package.loaded["modules.llm"] = {
			api_remote = {
				PROVIDERS = { openai = { label = "OpenAI" } },
				PROVIDER_ORDER = { "openai" },
				get_entries = function() return { entry } end,
				get_active_entry_id = function() return "entry-a" end,
				get_active_entry = function() return entry end,
				resolve_active_entry = function() resolver_calls = resolver_calls + 1 end,
			},
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = { error = function() end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.notifications"] = {}
		package.loaded["infra.manifest_menu"] = { render_rows = function(rows) return rows end }
		package.loaded["ui.menu.menu_llm.api_panel"] = nil
		local ok, err = xpcall(function()
			local panel = require("ui.menu.menu_llm.api_panel")
			local title, rows = panel.build({
				state = { llm_backend = "api" }, paused = true,
				keymap = {}, update_menu = function() end, WarmupCtrl = {},
			})
			helpers.assert_true(type(title) == "string" and type(rows) == "table")
			helpers.assert_eq(resolver_calls, 0,
				"menu build must consume metadata only, even when the token is a Keychain reference")
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err) end
	end)
end)
