--- tests/unit/llm/test_token_and_install_quoting.lua

--- ==============================================================================
--- MODULE: Regression — the last un-migrated quoting sites, and a failure
---         sentinel that destroyed the stored token
---         (token-and-install-quoting)
--- DESCRIPTION:
--- Two findings that both turn a transient failure into a permanent one.
---
---   M8  A DENIED KEYCHAIN DESTROYED THE TOKEN. get_active_entry lazily
---       decrypts the stored reference and caches the result on the live entry.
---       TokenCrypto.decrypt reports failure by returning "" — indistinguishable
---       from a legitimately empty value once cached — and a locked or
---       permission-denied Keychain produces exactly that. The empty string
---       replaced the encrypted REFERENCE in memory, and the next
---       persist_api_entries wrote it back to disk. The user's API token was
---       then gone, not merely unavailable: the reference that could have been
---       retried had been overwritten. The async prewarm path cached the same
---       sentinel the same way.
---
---   M3  THE PRIVILEGED INSTALL WAS NOT QUOTED. The shell-quoting campaign
---       routed 41 sites through text_utils.shell_quote, but install_system
---       kept raw %s inside hand-written single quotes and path_exists kept
---       Lua's %q. %q escapes for a LUA literal: it leaves $, backticks and !
---       untouched, every one of which /bin/sh expands. An apostrophe in a
---       relocated bundle path — or a user directory like /Users/O'Brien —
---       closed the quoted run early and broke a command run WITH ADMINISTRATOR
---       PRIVILEGES.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ A failed decrypt never replaces the stored reference =========
-- =========================================================================
-- =========================================================================

helpers.describe("api_remote: a failed Keychain decrypt is not cached", function()
	helpers.it("keeps the encrypted reference when decrypt returns the empty sentinel", function()
		local src = helpers.read_driver_source("get_active_entry")
		helpers.assert_true(src ~= nil and src ~= "",
			"api_remote must be locatable by its get_active_entry symbol")

		-- Anchored on the decrypt CALL rather than the function header:
		-- read_driver_source concatenates every file naming the symbol, so the
		-- header may resolve into a file that merely references it.
		local at = src:find("TokenCrypto.decrypt(entry.token)", 1, true)
		helpers.assert_true(at ~= nil, "the lazy decrypt call must exist")
		-- Comments stripped: the fix's own explanation names the sentinel.
		local body = src:sub(at, at + 1400):gsub("%-%-[^\n]*", "")

		-- The specific variable, not a bare ~= "" anywhere in the window: the
		-- function contains other emptiness checks, and the loose form passed
		-- against the unfixed source.
		helpers.assert_true(
			body:find('cleartext ~= ""', 1, true) ~= nil,
			"the lazy decrypt must cache only a NON-EMPTY result. \"\" is TokenCrypto.decrypt's "
				.. "failure sentinel, and caching it replaces the encrypted reference in the live "
				.. "entry — which the next persist_api_entries then writes to disk, destroying a "
				.. "token that was merely unavailable"
		)
	end)

	helpers.it("the async prewarm applies the same guard", function()
		local src = helpers.read_driver_source("decrypt_async")
		helpers.assert_true(src ~= nil and src ~= "",
			"the prewarm path must be locatable")

		-- Anchored on the CALL SITE, not the name: read_driver_source concatenates
		-- every file containing the symbol, and decrypt_async is defined in
		-- api_token_crypto — so the first match is the definition, whose body has
		-- no cache-back to guard.
		local at = src:find("TokenCrypto.decrypt_async(entry.token", 1, true)
		helpers.assert_true(at ~= nil, "the async prewarm call site must exist")
		local body = src:sub(at, at + 900):gsub("%-%-[^\n]*", "")

		helpers.assert_true(
			body:find('cleartext ~= ""', 1, true) ~= nil,
			"the prewarm caches back on the same field through the same sentinel, so it needs the "
				.. "identical non-empty guard. Fixing only the lazy path leaves the destructive "
				.. "write reachable from the timer that runs on every boot"
		)
	end)

	helpers.it("the sentinel really is the empty string", function()
		-- The guard above is only meaningful because decrypt reports failure this
		-- way. Assert it from the source of truth rather than from memory.
		local src = helpers.read_driver_source("is_encrypted")
		helpers.assert_true(src ~= nil and src ~= "",
			"the token crypto module must be locatable")
		helpers.assert_true(src:find('return ""', 1, true) ~= nil,
			"TokenCrypto must still report a failed decrypt by returning the empty string — if "
				.. "that ever changes to nil, the non-empty guards above must change with it")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ Every shell interpolation is POSIX-quoted ====================
-- =========================================================================
-- =========================================================================

helpers.describe("layout_install: the privileged install is POSIX-quoted", function()
	helpers.it("install_system quotes every interpolated path", function()
		local src = helpers.read_driver_source("install_system")
		helpers.assert_true(src ~= nil and src ~= "",
			"layout_install must be locatable by its install_system symbol")

		local at = src:find("local function install_system", 1, true)
		helpers.assert_true(at ~= nil, "install_system must exist")
		local body = src:sub(at, at + 1600):gsub("%-%-[^\n]*", "")

		helpers.assert_true(body:find("shell_quote", 1, true) ~= nil,
			"install_system must route its interpolated paths through shell_quote. It builds a "
				.. "command run WITH ADMINISTRATOR PRIVILEGES, so an apostrophe in a relocated "
				.. "bundle path closing the quoted run early is the worst possible place for it")

		helpers.assert_true(body:find("'%%s", 1, false) == nil,
			"no raw %s may remain inside hand-written single quotes — that is precisely the shape "
				.. "the quoting campaign replaced everywhere else")
	end)

	helpers.it("path_exists does not shell out with %q", function()
		local src = helpers.read_driver_source("path_exists")
		helpers.assert_true(src ~= nil and src ~= "",
			"layout_install must be locatable by its path_exists symbol")

		local at = src:find("local function path_exists", 1, true)
		helpers.assert_true(at ~= nil, "path_exists must exist")
		local body = src:sub(at, at + 900):gsub("%-%-[^\n]*", "")

		helpers.assert_true(body:find("%%q", 1, false) == nil,
			"path_exists must not quote a shell argument with Lua's %q. It escapes for a LUA "
				.. "literal and leaves $, backticks and ! untouched — all of which /bin/sh expands "
				.. "— so on a user-influenced path it is both wrong and an injection hazard")
		helpers.assert_true(body:find("shell_quote", 1, true) ~= nil,
			"it must use the POSIX quoter instead")
	end)
end)
