--- tests/unit/modules/llm/test_api_token_decrypt_async_behaviour.lua

--- ==============================================================================
--- MODULE: Regression — async Keychain decrypt never blocks (F-MED-9)
--- DESCRIPTION:
--- ApiRemote.get_active_entry()'s lazy Keychain decrypt (TokenCrypto.decrypt)
--- is a synchronous hs.execute shell-out, reachable from a run-loop timer
--- callback (warmup / first prediction). A locked Keychain there can freeze
--- the whole run loop on a modal unlock prompt.
---
--- Fix: TokenCrypto.decrypt_async() drives the Keychain read through
--- adapters/shell_runner's async hs.task.new instead of a blocking
--- hs.execute, and ApiRemote.prewarm_active_entry_decrypt() calls it right
--- after entries load so the LATER synchronous get_active_entry() call
--- almost always hits an already-cached cleartext token.
---
--- These tests stub hs.task.new to capture (rather than immediately fire)
--- its completion callback, proving decrypt_async() returns control to the
--- caller before the "Keychain" responds, and that the callback correctly
--- delivers the cleartext once the async task completes.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================================
-- =========================================================
-- ======= 1/ TokenCrypto.decrypt_async never blocks =======
-- =========================================================
-- =========================================================

helpers.describe("TokenCrypto.decrypt_async: never blocks on the Keychain (F-MED-9)", function()

	helpers.it("returns control to the caller before the async task completes", function()
		local captured_cb = nil
		local hs_overrides = {
			task = {
				new = function(_exe, cb, _args)
					captured_cb = cb
					return { start = function() end, terminate = function() end }
				end,
			},
		}
		-- adapters.shell_runner captures `local hs = hs` at require-time; it
		-- must be reloaded under THIS test's stub, not a previous test's, or
		-- its wrapped_on_done still calls into the OLD hs.task.new.
		package.loaded["modules.llm.api_token_crypto"] = nil
		package.loaded["adapters.shell_runner"]        = nil
		local TokenCrypto = helpers.load_with_stubs("modules.llm.api_token_crypto", hs_overrides)

		local delivered = nil
		TokenCrypto.decrypt_async("keychain:my-entry", function(cleartext) delivered = cleartext end)

		-- The callback must NOT have fired synchronously — decrypt_async must
		-- return immediately, before the "Keychain" subprocess responds.
		helpers.assert_true(delivered == nil,
			"decrypt_async must not deliver its result synchronously — the caller must not block")
		helpers.assert_true(captured_cb ~= nil, "decrypt_async must spawn an hs.task for the Keychain read")

		-- Simulate the async subprocess completing.
		captured_cb(0, "super-secret-token", "")

		helpers.assert_eq(delivered, "super-secret-token",
			"decrypt_async's callback must deliver the cleartext once the async task completes")
	end)

	helpers.it("delivers empty string when the async Keychain read fails", function()
		local captured_cb = nil
		local hs_overrides = {
			task = {
				new = function(_exe, cb, _args)
					captured_cb = cb
					return { start = function() end, terminate = function() end }
				end,
			},
		}
		package.loaded["modules.llm.api_token_crypto"] = nil
		package.loaded["adapters.shell_runner"]        = nil
		local TokenCrypto = helpers.load_with_stubs("modules.llm.api_token_crypto", hs_overrides)

		local delivered = "not called"
		TokenCrypto.decrypt_async("keychain:my-entry", function(cleartext) delivered = cleartext end)
		captured_cb(44, "", "security: entry not found")

		helpers.assert_eq(delivered, "", "a failed async Keychain read must deliver empty string, not throw")
	end)

	helpers.it("calls back immediately (still async-shaped) for a non-encrypted (cleartext legacy) value", function()
		package.loaded["modules.llm.api_token_crypto"] = nil
		package.loaded["adapters.shell_runner"]        = nil
		local TokenCrypto = helpers.load_with_stubs("modules.llm.api_token_crypto")

		local delivered = nil
		TokenCrypto.decrypt_async("plain-legacy-token", function(cleartext) delivered = cleartext end)

		helpers.assert_eq(delivered, "plain-legacy-token",
			"a non-keychain-prefixed value must be delivered unchanged, no Keychain round-trip needed")
	end)
end)




-- ======================================================================
-- ======================================================================
-- ======= 2/ ApiRemote.prewarm_active_entry_decrypt caches the token ==
-- ======================================================================
-- ======================================================================

helpers.describe("ApiRemote.prewarm_active_entry_decrypt: caches the active entry's token asynchronously (F-MED-9)", function()

	--- Loads a fresh ApiRemote with hs.task.new stubbed to capture (not fire)
	--- its completion callback, so the test controls exactly when the
	--- "Keychain" responds.
	--- @return table ApiRemote, function fire_pending (fires the captured callback with the given cleartext)
	local function load_fresh_api_remote()
		local captured_cb = nil
		local hs_overrides = {
			task = {
				new = function(_exe, cb, _args)
					captured_cb = cb
					return { start = function() end, terminate = function() end }
				end,
			},
		}
		package.loaded["modules.llm.api_remote"]       = nil
		package.loaded["modules.llm.api_token_crypto"] = nil
		package.loaded["adapters.shell_runner"]        = nil
		local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote", hs_overrides)

		local function fire_pending(cleartext)
			if captured_cb then captured_cb(0, cleartext, "") end
		end
		return ApiRemote, fire_pending
	end

	helpers.it("pre-warms the cache so a later get_active_entry() does not need to decrypt again", function()
		local ApiRemote, fire_pending = load_fresh_api_remote()

		ApiRemote.set_entries({
			{ id = "e1", provider = "openai", token = "keychain:e1", model = "gpt-4" },
		})
		ApiRemote.set_active_entry_id("e1")

		ApiRemote.prewarm_active_entry_decrypt()
		-- Simulate the Keychain responding with the cleartext.
		fire_pending("sk-prewarmed-token")

		local entry = ApiRemote.get_active_entry()
		helpers.assert_true(entry ~= nil, "get_active_entry must still resolve an entry")
		helpers.assert_eq(entry.token, "sk-prewarmed-token",
			"prewarm_active_entry_decrypt must cache the decrypted token back into the entry")
	end)

	helpers.it("is a no-op when there are no entries configured", function()
		local ApiRemote, _fire_pending = load_fresh_api_remote()
		local ok = pcall(ApiRemote.prewarm_active_entry_decrypt)
		helpers.assert_true(ok, "prewarm_active_entry_decrypt must not throw with zero entries configured")
	end)

	helpers.it("is a no-op when the active entry's token is already cleartext", function()
		local ApiRemote, fire_pending = load_fresh_api_remote()

		ApiRemote.set_entries({
			{ id = "e1", provider = "openai", token = "already-cleartext", model = "gpt-4" },
		})
		ApiRemote.set_active_entry_id("e1")

		ApiRemote.prewarm_active_entry_decrypt()
		-- No hs.task should have been spawned; firing a phantom callback must
		-- be a safe no-op regardless (nothing captured it).
		fire_pending("should-not-be-used")

		local entry = ApiRemote.get_active_entry()
		helpers.assert_eq(entry.token, "already-cleartext",
			"a cleartext (non-keychain-prefixed) token must be left untouched")
	end)

	helpers.it("discards a stale pre-warm result if the active entry changed while the read was in flight", function()
		local ApiRemote, fire_pending = load_fresh_api_remote()

		ApiRemote.set_entries({
			{ id = "e1", provider = "openai", token = "keychain:e1", model = "gpt-4" },
			{ id = "e2", provider = "openai", token = "keychain:e2", model = "gpt-4o" },
		})
		ApiRemote.set_active_entry_id("e1")

		ApiRemote.prewarm_active_entry_decrypt()

		-- The user switches the active entry BEFORE the async Keychain read
		-- for e1 completes.
		ApiRemote.set_active_entry_id("e2")

		-- Now the stale e1 read resolves.
		fire_pending("sk-e1-cleartext")

		local entries = ApiRemote.get_entries()
		local e1 = nil
		for _, e in ipairs(entries) do if e.id == "e1" then e1 = e end end
		helpers.assert_true(e1 ~= nil, "entry e1 must still exist")
		helpers.assert_eq(e1.token, "keychain:e1",
			"a stale pre-warm result must not overwrite an entry that is no longer active")
	end)
end)
